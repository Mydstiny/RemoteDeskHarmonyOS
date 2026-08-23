import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ExtensionLoader } from './ExtensionLoader';
import {
  SftpFileEntry,
  SftpListAsyncResult,
  SftpMutationAsyncResult,
  SftpReadAsyncResult,
  SftpWriteAsyncResult
} from '../types/rdpnapi';
import {
  SshSftpConflictPolicy,
  SshSftpTreeItem,
  nextSshSftpKeepBothName,
  resolveSshSftpConflict
} from './SshSftpBatchPolicy';
import {
  SshSftpFileIdentity,
  sshSftpCommitSizeMatches,
  sshSftpIdentityMatches,
  sshSftpOffsetIsValid,
  sshSftpPartialSuffix
} from './SshSftpIntegrityPolicy';
import {
  SshSftpCommitRecoveryDecision,
  SshSftpTaskDirection,
  SshSftpTaskRecord,
  SshSftpTaskStage,
  SftpEndpoint,
  sshSftpCommitRecoveryDecision,
  sshSftpSessionSnapshotCanAttach
} from './SshSftpTaskPolicy';
import { SshSftpTaskStore } from './SshSftpTaskStore';
import { SshLocalFileEntry, SshLocalFileProvider } from './SshLocalFileProvider';
import {
  SshSftpEngineSession,
  SshSftpSessionOwnerPolicy,
  SshSftpTrackedSession
} from './SshSftpSessionOwnerPolicy';

export { SshSftpEngineSession } from './SshSftpSessionOwnerPolicy';
export { SshSftpTrackedSession } from './SshSftpSessionOwnerPolicy';

const MAX_TRANSFER_BYTES: number = 512 * 1024 * 1024;
const UPLOAD_CHUNK_BYTES: number = 64 * 1024;
const DOWNLOAD_CHUNK_BYTES: number = 64 * 1024;
const DURABILITY_UNSUPPORTED: number = -56;
const CONFLICT_ERROR: number = -409;
const SSH_STATE_CONNECTED: number = 2;

export type SshSftpTaskEngineEventKind =
  | 'taskChanged'
  | 'conflict'
  | 'batchCompleted'
  | 'batchBlocked';

export interface SshSftpTaskEngineEvent {
  kind: SshSftpTaskEngineEventKind;
  batchId: string;
  record: SshSftpTaskRecord | null;
  reason: string;
}

export type SshSftpTaskEngineListener = (event: SshSftpTaskEngineEvent) => void;

/** Keep provider bindings only when the SSH page explicitly survives in background. */
export function shouldReleaseSshSftpRuntimeOnPageTeardown(
  preserveSshInBackground: boolean): boolean {
  return !preserveSshInBackground;
}

export interface SshSftpStagingDiscardPlan {
  accepted: boolean;
  deferUntilWorkerStops: boolean;
  cleanupStagingRoot: boolean;
}

export function planSshSftpStagingDiscard(bindingFound: boolean, workerRunning: boolean,
  cleanupLocalRoot: boolean, sourceKind: string): SshSftpStagingDiscardPlan {
  if (!bindingFound) {
    return { accepted: false, deferUntilWorkerStops: false, cleanupStagingRoot: false };
  }
  return {
    accepted: true,
    deferUntilWorkerStops: workerRunning,
    cleanupStagingRoot: cleanupLocalRoot && sourceKind === 'local'
  };
}

export function reconcileSshSftpStoppedUploadCheckpoint(current: SshSftpTaskRecord,
  offset: number, partialIdentity: SshSftpFileIdentity, sequence: number,
  updatedAt: number): SshSftpTaskRecord | null {
  if ((current.stage !== 'paused' && current.stage !== 'cancelled') ||
    !sshSftpOffsetIsValid(offset, current.sourceSize >= 0 ? current.sourceSize : current.totalBytes) ||
    partialIdentity.size !== offset || partialIdentity.mtime < 0) {
    return null;
  }
  return {
    taskId: current.taskId,
    schemaVersion: current.schemaVersion,
    batchId: current.batchId,
    relativePath: current.relativePath,
    hostId: current.hostId,
    direction: current.direction,
    isDirectory: current.isDirectory,
    remotePath: current.remotePath,
    fileName: current.fileName,
    totalBytes: current.totalBytes,
    verifiedOffset: offset,
    sourceSize: current.sourceSize,
    sourceMtime: current.sourceMtime,
    partialSize: partialIdentity.size,
    partialMtime: partialIdentity.mtime,
    sessionGeneration: current.sessionGeneration,
    sequence,
    stage: current.stage,
    updatedAt,
    sourceEndpoint: current.sourceEndpoint,
    targetEndpoint: current.targetEndpoint,
    sourcePath: current.sourcePath,
    targetPath: current.targetPath,
    partialIdentity: { size: partialIdentity.size, mtime: partialIdentity.mtime },
    checksumPolicy: current.checksumPolicy,
    commitState: current.commitState
  };
}

interface SshSftpBatchBinding {
  batchId: string;
  hostId: string;
  direction: SshSftpTaskDirection;
  localRoot: string;
  remoteRoot: string;
  sourceEndpoint: SftpEndpoint;
  targetEndpoint: SftpEndpoint;
  conflictPolicy: SshSftpConflictPolicy;
  cleanupLocalRootOnComplete: boolean;
}

interface SshSftpResolvedSessions {
  source: SshSftpTrackedSession | null;
  target: SshSftpTrackedSession | null;
}

interface SshSftpEngineConflictPlan {
  action: 'ready' | 'skip' | 'waiting' | 'failed';
  targetPath: string;
  fileName: string;
}

interface SshSftpEngineIdentity {
  size: number;
  mtime: number;
}

interface SshSftpEngineIdentityResult {
  identity: SshSftpFileIdentity | null;
  errorCode: number;
  transportLost: boolean;
}

/**
 * Page-independent SFTP batch owner. It keeps only live session handles and
 * provider bindings in memory; task metadata remains in SshSftpTaskStore.
 * Picker grants and credentials are never written by this class.
 */
export class SshSftpTaskEngine {
  private static instance: SshSftpTaskEngine | null = null;
  private readonly loader: ExtensionLoader = ExtensionLoader.getInstance();
  private readonly store: SshSftpTaskStore = SshSftpTaskStore.getInstance();
  private readonly provider: SshLocalFileProvider = SshLocalFileProvider.getInstance();
  private readonly bindings: Map<string, SshSftpBatchBinding> = new Map<string, SshSftpBatchBinding>();
  private readonly sessionOwners: SshSftpSessionOwnerPolicy =
    new SshSftpSessionOwnerPolicy();
  private readonly conflictPolicies: Map<string, SshSftpConflictPolicy> =
    new Map<string, SshSftpConflictPolicy>();
  private readonly running: Set<string> = new Set<string>();
  /** A queued batch can be admitted before one of its SSH endpoints is ready. */
  private readonly pendingBatches: Set<string> = new Set<string>();
  private readonly activeTasks: Map<string, string> = new Map<string, string>();
  /** Final user discard is deferred until an active file operation releases the staging root. */
  private readonly discardRequested: Set<string> = new Set<string>();
  /** Page teardown releases provider grants without deleting durable task records. */
  private readonly runtimeReleaseRequested: Set<string> = new Set<string>();
  private readonly listeners: SshSftpTaskEngineListener[] = [];
  /** Sessions can be adopted while local-provider authorization restores. */
  private readonly pendingSessions: Map<string, SshSftpEngineSession> =
    new Map<string, SshSftpEngineSession>();
  private context: common.UIAbilityContext | null = null;
  private initialized: boolean = false;
  private sequence: number = 0;

  static getInstance(): SshSftpTaskEngine {
    if (SshSftpTaskEngine.instance === null) {
      SshSftpTaskEngine.instance = new SshSftpTaskEngine();
    }
    return SshSftpTaskEngine.instance;
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized && this.context === context) { return; }
    this.logDiagnostic('init begin');
    this.context = context;
    this.provider.init(context);
    await this.provider.restoreAuthorization();
    this.initialized = true;
    this.logDiagnostic('init ready pendingSessions=' + this.pendingSessions.size.toString() +
      ' pendingBatches=' + this.pendingBatches.size.toString());
    const pending: SshSftpEngineSession[] = Array.from(this.pendingSessions.values());
    this.pendingSessions.clear();
    for (let index = 0; index < pending.length; index++) {
      this.attachSession(pending[index]);
    }
  }

  subscribe(listener: SshSftpTaskEngineListener): () => void {
    this.listeners.push(listener);
    let active: boolean = true;
    return (): void => {
      if (!active) { return; }
      active = false;
      const remaining: SshSftpTaskEngineListener[] = this.listeners.filter(
        (candidate: SshSftpTaskEngineListener): boolean => candidate !== listener);
      this.listeners.splice(0, this.listeners.length, ...remaining);
    };
  }

  bindBatch(batchId: string, hostId: string, localRoot: string, remoteRoot: string,
    conflictPolicy: SshSftpConflictPolicy = 'ask',
    cleanupLocalRootOnComplete: boolean = false): boolean {
    const id: string = batchId.trim();
    const owner: string = hostId.trim();
    const local: string = localRoot.trim();
    const remote: string = remoteRoot.trim();
    if (id.length === 0 || owner.length === 0 || local.length === 0 || remote.length === 0) {
      return false;
    }
    const records: SshSftpTaskRecord[] = this.store.listBatch(owner, id);
    if (records.length === 0) { return false; }
    const first: SshSftpTaskRecord = records[0];
    const sourceEndpoint: SftpEndpoint = first.sourceEndpoint === undefined
      ? (first.direction === 'upload'
        ? { kind: 'local' } as SftpEndpoint
        : { kind: 'ssh', hostId: owner } as SftpEndpoint)
      : first.sourceEndpoint;
    const targetEndpoint: SftpEndpoint = first.targetEndpoint === undefined
      ? (first.direction === 'upload'
        ? { kind: 'ssh', hostId: owner } as SftpEndpoint
        : { kind: 'local' } as SftpEndpoint)
      : first.targetEndpoint;
    this.runtimeReleaseRequested.delete(id);
    this.bindings.set(id, {
      batchId: id,
      hostId: owner,
      direction: first.direction,
      localRoot: local,
      remoteRoot: remote,
      sourceEndpoint,
      targetEndpoint,
      conflictPolicy,
      cleanupLocalRootOnComplete
    });
    this.logDiagnostic('bind batch=' + id +
      ' source=' + this.endpointDiagnostic(sourceEndpoint) +
      ' target=' + this.endpointDiagnostic(targetEndpoint) +
      ' records=' + records.length.toString());
    return true;
  }

  unbindBatch(batchId: string): void {
    const id: string = batchId.trim();
    if (this.running.has(id)) { return; }
    this.runtimeReleaseRequested.delete(id);
    const binding: SshSftpBatchBinding | undefined = this.bindings.get(id);
    this.bindings.delete(id);
    this.pendingBatches.delete(id);
    this.activeTasks.delete(id);
    if (binding !== undefined) {
      const tasks: SshSftpTaskRecord[] = this.store.listBatch(binding.hostId, id);
      for (let index = 0; index < tasks.length; index++) {
        this.conflictPolicies.delete(tasks[index].taskId);
      }
    }
  }

  /**
   * Release page-only provider bindings while retaining durable task records.
   * An active worker finishes its current operation before the binding is
   * dropped, so a later page must bind fresh local/remote roots explicitly.
   */
  releaseBatchRuntime(batchId: string): void {
    const id: string = batchId.trim();
    if (id.length === 0 || this.discardRequested.has(id)) { return; }
    const binding: SshSftpBatchBinding | undefined = this.bindings.get(id);
    if (binding === undefined) { return; }
    this.pendingBatches.delete(id);
    this.runtimeReleaseRequested.add(id);
    if (!this.running.has(id)) { this.finalizeBatchRuntimeRelease(binding); }
  }

  /** Release every page-only provider binding that is not being discarded. */
  releaseAllBatchRuntimes(): void {
    const bindings: SshSftpBatchBinding[] = Array.from(this.bindings.values());
    for (let index = 0; index < bindings.length; index++) {
      this.releaseBatchRuntime(bindings[index].batchId);
    }
  }

  attachSession(session: SshSftpEngineSession): SshSftpTrackedSession | null {
    const hostId: string = session.hostId.trim();
    if (hostId.length === 0 || session.sessionId <= 0 || session.generation <= 0) { return null; }
    let nativeState: number = -1;
    let recoveryEpoch: number = 0;
    try {
      nativeState = this.loader.getConnectionState(session.sessionId);
      const snapshot = this.loader.getSshSessionSnapshot(session.sessionId, session.generation);
      if (!sshSftpSessionSnapshotCanAttach(
        session.sessionId, session.generation, nativeState, snapshot)) {
        this.logDiagnostic('stale session attach rejected session=' + session.sessionId.toString() +
          ' generation=' + session.generation.toString() +
          ' snapshotError=' + snapshot.errorCode.toString(), true);
        return null;
      }
      recoveryEpoch = snapshot.eventSequence;
    } catch (_err) {
      return null;
    }
    this.logDiagnostic('attach session=' + session.sessionId.toString() +
      ' generation=' + session.generation.toString() +
      ' recoveryEpoch=' + recoveryEpoch.toString() +
      ' initialized=' + this.initialized.toString());
    if (!this.initialized) {
      this.pendingSessions.set(hostId, {
        hostId,
        sessionId: session.sessionId,
        generation: session.generation
      });
      return null;
    }
    const ownerToken: SshSftpTrackedSession = this.sessionOwners.attach(
      hostId, session.sessionId, session.generation, recoveryEpoch);
    const batchIds: string[] = [];
    this.bindings.forEach((binding: SshSftpBatchBinding): void => {
      if (this.bindingUsesHost(binding, hostId)) { batchIds.push(binding.batchId); }
    });
    for (let index = 0; index < batchIds.length; index++) {
      const binding: SshSftpBatchBinding | undefined = this.bindings.get(batchIds[index]);
      if (binding !== undefined) {
        // Remote-to-remote records are owned by the target host even when the
        // source endpoint is the one that reconnects. Resolve through the
        // batch owner so either endpoint can resume the durable task.
        const waiting: SshSftpTaskRecord[] = this.store.listBatch(binding.hostId, binding.batchId)
          .filter((task: SshSftpTaskRecord): boolean => task.stage === 'waitingForConnection');
        for (let taskIndex = 0; taskIndex < waiting.length; taskIndex++) {
          this.store.command(waiting[taskIndex].taskId, { kind: 'resume' });
        }
      }
      this.startBatch(batchIds[index]);
    }
    return ownerToken;
  }

  detachSession(ownerToken: SshSftpTrackedSession): void {
    const owner: string = ownerToken.hostId.trim();
    const pending: SshSftpEngineSession | undefined = this.pendingSessions.get(owner);
    if (pending !== undefined && pending.sessionId === ownerToken.sessionId &&
      pending.generation === ownerToken.generation) {
      this.pendingSessions.delete(owner);
    }
    if (!this.sessionOwners.detach(ownerToken)) { return; }
    this.bindings.forEach((binding: SshSftpBatchBinding): void => {
      if (!this.bindingUsesHost(binding, owner)) { return; }
      const activeTaskId: string | undefined = this.activeTasks.get(binding.batchId);
      if (activeTaskId === undefined) { return; }
      const task: SshSftpTaskRecord | null = this.store.get(activeTaskId);
      if (task !== null && task.stage !== 'completed' && task.stage !== 'cancelled') {
        this.store.command(task.taskId, { kind: 'detach' });
        this.publish('taskChanged', binding.batchId, this.store.get(task.taskId), 'waiting-for-connection');
      }
    });
  }

  startBatch(batchId: string): void {
    const id: string = batchId.trim();
    if (id.length === 0 || this.running.has(id)) { return; }
    const binding: SshSftpBatchBinding | undefined = this.bindings.get(id);
    if (binding === undefined) {
      this.pendingBatches.delete(id);
      this.logDiagnostic('start ignored batch=' + id + ' reason=binding-missing', true);
      return;
    }
    this.logDiagnostic('start requested batch=' + id +
      ' pending=' + this.pendingBatches.has(id).toString());
    const resolved: SshSftpResolvedSessions | null = this.resolveBindingSessions(binding);
    if (resolved === null) {
      this.pendingBatches.add(id);
      this.logDiagnostic('start waiting batch=' + id +
        ' sourceReady=' + this.endpointSessionReady(binding.sourceEndpoint).toString() +
        ' targetReady=' + this.endpointSessionReady(binding.targetEndpoint).toString(), true);
      this.publish('batchBlocked', id, null, 'waiting-for-connection');
      return;
    }
    this.pendingBatches.delete(id);
    this.logDiagnostic('start admitted batch=' + id +
      ' source=' + this.sessionDiagnostic(resolved.source) +
      ' target=' + this.sessionDiagnostic(resolved.target));
    void this.pumpBatch(binding, resolved);
  }

  resolveBatchConflict(batchId: string, policy: SshSftpConflictPolicy,
    taskId: string = '', applyToBatch: boolean = true): void {
    const id: string = batchId.trim();
    const binding: SshSftpBatchBinding | undefined = this.bindings.get(id);
    if (binding === undefined) { return; }
    if (applyToBatch) { binding.conflictPolicy = policy; }
    const tasks: SshSftpTaskRecord[] = this.store.listBatch(binding.hostId, id);
    for (let index = 0; index < tasks.length; index++) {
      if (tasks[index].stage === 'awaitingConflictDecision' &&
        (taskId.trim().length === 0 || tasks[index].taskId === taskId.trim())) {
        this.conflictPolicies.set(tasks[index].taskId, policy);
        this.store.command(tasks[index].taskId, { kind: 'retry' });
      }
    }
    this.startBatch(id);
  }

  cancelBatch(batchId: string): void {
    const id: string = batchId.trim();
    const binding: SshSftpBatchBinding | undefined = this.bindings.get(id);
    if (binding === undefined) { return; }
    this.pendingBatches.delete(id);
    const tasks: SshSftpTaskRecord[] = this.store.listBatch(binding.hostId, id);
    for (let index = 0; index < tasks.length; index++) {
      if (tasks[index].stage !== 'completed' && tasks[index].stage !== 'cancelled') {
        const result = this.store.command(tasks[index].taskId, { kind: 'cancel' });
        if (result.accepted) {
          this.publish('taskChanged', id, result.record, 'cancelled');
        }
      }
    }
  }

  /**
   * Permanently discard a terminal batch. Cancel keeps staging retryable;
   * clearing the final history record calls this method to release it.
   */
  discardBatch(batchId: string): void {
    const id: string = batchId.trim();
    const binding: SshSftpBatchBinding | undefined = this.bindings.get(id);
    const plan: SshSftpStagingDiscardPlan = planSshSftpStagingDiscard(
      binding !== undefined, this.running.has(id),
      binding?.cleanupLocalRootOnComplete === true, binding?.sourceEndpoint.kind || '');
    if (!plan.accepted || binding === undefined) { return; }
    this.runtimeReleaseRequested.delete(id);
    this.discardRequested.add(id);
    this.pendingBatches.delete(id);
    if (!plan.deferUntilWorkerStops) { void this.finalizeBatchDiscard(binding); }
  }

  pauseBatch(batchId: string): void {
    const id: string = batchId.trim();
    const binding: SshSftpBatchBinding | undefined = this.bindings.get(id);
    if (binding === undefined) { return; }
    const activeTaskId: string | undefined = this.activeTasks.get(id);
    if (activeTaskId === undefined) { return; }
    const result = this.store.command(activeTaskId, { kind: 'pause' });
    if (result.accepted) {
      this.publish('taskChanged', id, result.record, 'paused');
    }
  }

  resumeBatch(batchId: string): void {
    this.retryBatch(batchId, 'resume');
  }

  retryBatch(batchId: string, commandKind: 'retry' | 'resume' = 'retry'): void {
    const id: string = batchId.trim();
    const binding: SshSftpBatchBinding | undefined = this.bindings.get(id);
    if (binding === undefined) { return; }
    const tasks: SshSftpTaskRecord[] = this.store.listBatch(binding.hostId, id)
      .filter((task: SshSftpTaskRecord): boolean =>
        commandKind === 'resume'
          ? task.stage === 'paused' || task.stage === 'waitingForConnection'
          : task.stage === 'failed' || task.stage === 'cancelled' ||
            task.stage === 'paused' || task.stage === 'waitingForConnection');
    for (let index = 0; index < tasks.length; index++) {
      const result = this.store.command(tasks[index].taskId, { kind: commandKind });
      if (result.accepted) {
        this.publish('taskChanged', id, result.record, 'queued');
        break;
      }
    }
    this.startBatch(id);
  }

  private async pumpBatch(binding: SshSftpBatchBinding,
    initialSessions: SshSftpResolvedSessions): Promise<void> {
    if (this.running.has(binding.batchId)) { return; }
    this.running.add(binding.batchId);
    this.logDiagnostic('pump begin batch=' + binding.batchId +
      ' source=' + this.sessionDiagnostic(initialSessions.source) +
      ' target=' + this.sessionDiagnostic(initialSessions.target));
    try {
      while (true) {
        const sessions: SshSftpResolvedSessions | null = this.resolveBindingSessions(binding);
        if (sessions === null || !this.resolvedSessionsMatch(sessions, initialSessions)) {
          this.pendingBatches.add(binding.batchId);
          this.logDiagnostic('pump paused batch=' + binding.batchId + ' reason=session-changed', true);
          return;
        }
        const tasks: SshSftpTaskRecord[] = this.store.listBatch(binding.hostId, binding.batchId)
          .filter((task: SshSftpTaskRecord): boolean => task.stage === 'queued')
          .sort((left: SshSftpTaskRecord, right: SshSftpTaskRecord): number =>
            left.sequence - right.sequence);
        if (tasks.length === 0) {
          const remaining: SshSftpTaskRecord[] = this.store.listBatch(binding.hostId, binding.batchId)
            .filter((task: SshSftpTaskRecord): boolean =>
              task.stage !== 'completed' && task.stage !== 'cancelled');
          if (remaining.length === 0) {
            this.logDiagnostic('pump completed batch=' + binding.batchId);
            if (binding.cleanupLocalRootOnComplete && binding.sourceEndpoint.kind === 'local') {
              const cleaned: boolean = await this.provider.remove(binding.localRoot, true);
              this.logDiagnostic('staging cleanup batch=' + binding.batchId +
                ' accepted=' + cleaned.toString(), !cleaned);
            }
            this.publish('batchCompleted', binding.batchId, null, 'completed');
          }
          return;
        }
        const task: SshSftpTaskRecord = tasks[0];
        this.activeTasks.set(binding.batchId, task.taskId);
        this.logDiagnostic('pump task batch=' + binding.batchId + ' task=' + task.taskId +
          ' stage=' + task.stage + ' remoteToRemote=' + this.isRemoteToRemote(task).toString());
        const sessionTask: SshSftpTaskRecord = this.updateTask(task, task.stage,
          task.verifiedOffset, task.partialSize, task.partialMtime, task.remotePath,
          task.fileName, this.sessionGenerationForUpdate(sessions), task.targetPath,
          task.sourcePath);
        let completed: boolean = false;
        if (this.isRemoteToRemote(sessionTask)) {
          if (sessions.source === null || sessions.target === null) { return; }
          completed = await this.executeRemoteCopy(binding, sessions.source, sessions.target, sessionTask);
        } else if (sessionTask.isDirectory) {
          const session: SshSftpEngineSession | null = sessions.source !== null
            ? sessions.source : sessions.target;
          if (session === null) { return; }
          completed = await this.executeDirectory(binding, session, sessionTask);
        } else if (sessionTask.direction === 'upload') {
          if (sessions.target === null) { return; }
          completed = await this.executeUpload(binding, sessions.target, sessionTask);
        } else {
          if (sessions.source === null) { return; }
          completed = await this.executeDownload(binding, sessions.source, sessionTask);
        }
        this.activeTasks.delete(binding.batchId);
        if (!completed) { return; }
      }
    } finally {
      const discardAfterCleanup: boolean = this.discardRequested.has(binding.batchId);
      const releaseAfterCleanup: boolean = !discardAfterCleanup &&
        this.runtimeReleaseRequested.has(binding.batchId);
      const restartAfterCleanup: boolean = !discardAfterCleanup && !releaseAfterCleanup &&
        this.pendingBatches.has(binding.batchId) &&
        this.bindings.has(binding.batchId);
      this.activeTasks.delete(binding.batchId);
      this.running.delete(binding.batchId);
      this.logDiagnostic('pump end batch=' + binding.batchId +
        ' pending=' + this.pendingBatches.has(binding.batchId).toString());
      if (discardAfterCleanup) {
        void this.finalizeBatchDiscard(binding);
      } else if (releaseAfterCleanup) {
        this.finalizeBatchRuntimeRelease(binding);
      } else if (restartAfterCleanup) {
        this.logDiagnostic('pump restart batch=' + binding.batchId + ' after lifecycle change');
        this.startBatch(binding.batchId);
      }
    }
  }

  private async finalizeBatchDiscard(binding: SshSftpBatchBinding): Promise<void> {
    const current: SshSftpBatchBinding | undefined = this.bindings.get(binding.batchId);
    if (current !== binding || this.running.has(binding.batchId)) { return; }
    const plan: SshSftpStagingDiscardPlan = planSshSftpStagingDiscard(
      true, false, binding.cleanupLocalRootOnComplete, binding.sourceEndpoint.kind);
    if (plan.cleanupStagingRoot) {
      const cleaned: boolean = await this.provider.remove(binding.localRoot, true);
      this.logDiagnostic('staging discard batch=' + binding.batchId +
        ' accepted=' + cleaned.toString(), !cleaned);
    }
    this.discardRequested.delete(binding.batchId);
    this.unbindBatch(binding.batchId);
  }

  private finalizeBatchRuntimeRelease(binding: SshSftpBatchBinding): void {
    const current: SshSftpBatchBinding | undefined = this.bindings.get(binding.batchId);
    if (current !== binding || this.running.has(binding.batchId)) { return; }
    this.logDiagnostic('runtime release batch=' + binding.batchId);
    this.unbindBatch(binding.batchId);
  }

  private bindingUsesHost(binding: SshSftpBatchBinding, hostId: string): boolean {
    const owner: string = hostId.trim();
    return binding.hostId === owner ||
      (binding.sourceEndpoint.kind === 'ssh' && binding.sourceEndpoint.hostId === owner) ||
      (binding.targetEndpoint.kind === 'ssh' && binding.targetEndpoint.hostId === owner);
  }

  private sessionForEndpoint(endpoint: SftpEndpoint): SshSftpTrackedSession | null {
    if (endpoint.kind !== 'ssh') { return null; }
    const hostId: string = (endpoint.hostId || '').trim();
    if (hostId.length === 0) { return null; }
    return this.sessionOwners.current(hostId);
  }

  private endpointDiagnostic(endpoint: SftpEndpoint): string {
    return endpoint.kind;
  }

  private sessionDiagnostic(session: SshSftpEngineSession | null): string {
    return session === null ? 'none' : session.sessionId.toString() + '/' +
      session.generation.toString();
  }

  private endpointSessionReady(endpoint: SftpEndpoint): boolean {
    return endpoint.kind === 'local' || this.sessionForEndpoint(endpoint) !== null;
  }

  private resolveBindingSessions(binding: SshSftpBatchBinding): SshSftpResolvedSessions | null {
    const source: SshSftpTrackedSession | null = this.sessionForEndpoint(binding.sourceEndpoint);
    const target: SshSftpTrackedSession | null = this.sessionForEndpoint(binding.targetEndpoint);
    if (binding.sourceEndpoint.kind === 'ssh' && source === null) { return null; }
    if (binding.targetEndpoint.kind === 'ssh' && target === null) { return null; }
    return { source, target };
  }

  private resolvedSessionsMatch(left: SshSftpResolvedSessions,
    right: SshSftpResolvedSessions): boolean {
    const matches = (leftSession: SshSftpTrackedSession | null,
      rightSession: SshSftpTrackedSession | null): boolean => {
      if (leftSession === null || rightSession === null) { return leftSession === rightSession; }
      return leftSession === rightSession;
    };
    return matches(left.source, right.source) && matches(left.target, right.target);
  }

  private sessionGenerationForUpdate(sessions: SshSftpResolvedSessions): number {
    return Math.max(sessions.source === null ? 0 : sessions.source.generation,
      sessions.target === null ? 0 : sessions.target.generation);
  }

  private isRemoteToRemote(task: SshSftpTaskRecord): boolean {
    return task.sourceEndpoint !== undefined && task.targetEndpoint !== undefined &&
      task.sourceEndpoint.kind === 'ssh' && task.targetEndpoint.kind === 'ssh';
  }

  private remoteSessionsActive(source: SshSftpEngineSession, target: SshSftpEngineSession): boolean {
    return this.sessionActive(source.hostId, source) && this.sessionActive(target.hostId, target);
  }

  private markTransportLost(session: SshSftpEngineSession, reason: string): void {
    const tracked: SshSftpTrackedSession = session as SshSftpTrackedSession;
    // A CONNECTED reattach publishes a new object/recovery epoch. A callback
    // captured by the old transport must not invalidate that recovered owner.
    if (!this.sessionOwners.markTransportLost(tracked)) {
      this.logDiagnostic('stale transport loss ignored session=' + session.sessionId.toString() +
        ' reason=' + reason, true);
      return;
    }
    this.logDiagnostic('transport lost session=' + session.sessionId.toString() +
      ' generation=' + session.generation.toString() + ' reason=' + reason, true);
  }

  private failOperationOrWait(binding: SshSftpBatchBinding, task: SshSftpTaskRecord,
    session: SshSftpEngineSession, reason: string, transportLost: boolean = false): boolean {
    if (transportLost) { this.markTransportLost(session, reason); }
    if (!this.sessionActive(session.hostId, session)) {
      return this.waitForConnection(binding, task);
    }
    return this.failTask(binding, task, reason);
  }

  private failRemoteOperationOrWait(binding: SshSftpBatchBinding, task: SshSftpTaskRecord,
    source: SshSftpEngineSession, target: SshSftpEngineSession, reason: string,
    transportLostSession: SshSftpEngineSession | null = null): boolean {
    if (transportLostSession !== null) {
      this.markTransportLost(transportLostSession, reason);
    }
    if (!this.remoteSessionsActive(source, target)) {
      hilog.warn(0x0017, 'SshTerminal', '[sftp-remote] operation interrupted; waiting reason=' + reason);
      return this.waitForConnection(binding, task);
    }
    return this.failTask(binding, task, reason);
  }

  private async recoverRemoteCommit(binding: SshSftpBatchBinding, task: SshSftpTaskRecord,
    targetSession: SshSftpEngineSession, partialPath: string, targetPath: string,
    expectedSize: number, diagnosticPrefix: string): Promise<boolean | null> {
    if (task.commitState === undefined) { return null; }
    const partialResult: SshSftpEngineIdentityResult = await this.readRemoteIdentityResult(
      targetSession.sessionId, partialPath, targetSession.generation);
    if (this.taskIsStopped(task.taskId)) { return false; }
    if (partialResult.transportLost) {
      return this.failOperationOrWait(binding, task, targetSession,
        diagnosticPrefix + '-commit-partial-stat-lost', true);
    }
    // identity=null only proves absence after a successful parent listing.
    // Permission/server failures must not be interpreted as a completed rename.
    if (partialResult.errorCode < 0) {
      return this.failOperationOrWait(binding, task, targetSession,
        diagnosticPrefix + '-commit-partial-stat-failed');
    }
    const targetResult: SshSftpEngineIdentityResult = await this.readRemoteIdentityResult(
      targetSession.sessionId, targetPath, targetSession.generation);
    if (this.taskIsStopped(task.taskId)) { return false; }
    if (targetResult.transportLost) {
      return this.failOperationOrWait(binding, task, targetSession,
        diagnosticPrefix + '-commit-target-stat-lost', true);
    }
    if (targetResult.errorCode < 0) {
      return this.failOperationOrWait(binding, task, targetSession,
        diagnosticPrefix + '-commit-target-stat-failed');
    }
    const recoveryDecision: SshSftpCommitRecoveryDecision = sshSftpCommitRecoveryDecision(
      task.commitState, expectedSize,
      targetResult.identity === null ? null : targetResult.identity.size,
      partialResult.identity === null ? null : partialResult.identity.size,
      targetResult.errorCode, partialResult.errorCode);
    if (recoveryDecision === 'complete') {
      return this.completeFileTask(binding, task, 'completed-after-reconnect');
    }
    if (recoveryDecision === 'failed' || partialResult.identity === null) {
      return this.failOperationOrWait(binding, task, targetSession,
        diagnosticPrefix + (task.commitState === 'renamed'
          ? '-committed-target-missing' : '-uncertain-commit-missing'));
    }
    return await this.commitRemotePartial(binding, task, targetSession, partialPath,
      targetPath, expectedSize, partialResult.identity, diagnosticPrefix + '-recovered');
  }

  private async commitRemotePartial(binding: SshSftpBatchBinding, task: SshSftpTaskRecord,
    targetSession: SshSftpEngineSession, partialPath: string, targetPath: string,
    expectedSize: number, partialIdentity: SshSftpFileIdentity,
    diagnosticPrefix: string): Promise<boolean> {
    if (this.taskIsStopped(task.taskId)) { return false; }
    let committing: SshSftpTaskRecord = this.updateTask(task, 'committing', expectedSize,
      partialIdentity.size, partialIdentity.mtime, targetPath, task.fileName,
      targetSession.generation, targetPath, task.sourcePath, 'renaming');
    if (committing.stage === 'paused' || committing.stage === 'cancelled') { return false; }
    // The pre-rename marker must be durable before crossing the atomic point of no return.
    if (!await this.store.flushNow()) {
      return this.failOperationOrWait(binding, committing, targetSession,
        diagnosticPrefix + '-commit-marker-persist-failed');
    }
    if (this.taskIsStopped(task.taskId)) { return false; }
    const renamed: SftpMutationAsyncResult = await this.loader.renameRemotePathAsync(
      targetSession.sessionId, partialPath, targetPath, true, targetSession.generation);
    if (this.taskIsStopped(task.taskId)) { return false; }
    if (renamed.transportLost === true) {
      return this.failOperationOrWait(binding, committing, targetSession,
        diagnosticPrefix + '-atomic-commit-unconfirmed', true);
    }
    if (renamed.errorCode < 0 || renamed.atomic === false) {
      return this.failOperationOrWait(binding, committing, targetSession,
        diagnosticPrefix + '-atomic-commit-failed');
    }
    committing = this.updateTask(committing, 'committing', expectedSize, -1, -1,
      targetPath, committing.fileName, targetSession.generation, targetPath,
      committing.sourcePath, 'renamed');
    if (committing.stage === 'paused' || committing.stage === 'cancelled') { return false; }
    const targetResult: SshSftpEngineIdentityResult = await this.readRemoteIdentityResult(
      targetSession.sessionId, targetPath, targetSession.generation);
    if (this.taskIsStopped(task.taskId)) { return false; }
    if (targetResult.transportLost) {
      return this.failOperationOrWait(binding, committing, targetSession,
        diagnosticPrefix + '-target-stat-lost', true);
    }
    if (targetResult.identity === null ||
      !sshSftpCommitSizeMatches(targetResult.identity.size, expectedSize)) {
      return this.failOperationOrWait(binding, committing, targetSession,
        diagnosticPrefix + '-target-unverified');
    }
    return this.completeFileTask(binding, committing, 'completed');
  }

  /** Copy directly between two SSH SFTP channels without staging credentials or bytes locally. */
  private async executeRemoteCopy(binding: SshSftpBatchBinding,
    sourceSession: SshSftpEngineSession, targetSession: SshSftpEngineSession,
    task: SshSftpTaskRecord): Promise<boolean> {
    const diagnosticPrefix: string = '[sftp-remote] batch=' + binding.batchId +
      ' task=' + task.taskId + ' sourceSession=' + sourceSession.sessionId.toString() + '/' +
      sourceSession.generation.toString() + ' targetSession=' +
      targetSession.sessionId.toString() + '/' + targetSession.generation.toString();
    hilog.info(0x0017, 'SshTerminal', diagnosticPrefix + ' remote-copy begin');
    if (this.taskIsStopped(task.taskId)) { return false; }
    if (!this.remoteSessionsActive(sourceSession, targetSession)) {
      hilog.warn(0x0017, 'SshTerminal', diagnosticPrefix + ' sessions inactive before copy');
      return this.waitForConnection(binding, task);
    }
    const sourcePath: string = (task.sourcePath || task.remotePath).trim();
    let targetPath: string = (task.targetPath || task.remotePath).trim();
    if (sourcePath.length === 0 || targetPath.length === 0) {
      hilog.warn(0x0017, 'SshTerminal', diagnosticPrefix + ' remote-copy-path-invalid');
      return this.failTask(binding, task, 'remote-copy-path-invalid');
    }
    if (task.isDirectory) {
      if (!await this.ensureRemoteDirectory(targetSession.sessionId, targetPath,
        targetSession.hostId, targetSession)) {
        hilog.warn(0x0017, 'SshTerminal', diagnosticPrefix +
          ' remote-copy-directory-prepare-failed');
        return this.failRemoteOperationOrWait(binding, task, sourceSession, targetSession,
          'remote-copy-directory-prepare-failed');
      }
      if (!this.remoteSessionsActive(sourceSession, targetSession) || this.taskIsStopped(task.taskId)) {
        return this.waitForConnection(binding, task);
      }
      const completed = this.store.command(task.taskId, { kind: 'complete' });
      if (completed.accepted) {
        hilog.info(0x0017, 'SshTerminal', diagnosticPrefix + ' directory completed');
        this.publish('taskChanged', binding.batchId, this.store.get(task.taskId), 'completed');
        return true;
      }
      hilog.warn(0x0017, 'SshTerminal', diagnosticPrefix +
        ' remote-copy-directory-complete-rejected');
      return this.failTask(binding, task, 'remote-copy-directory-complete-rejected');
    }

    let partialPath: string = targetPath + sshSftpPartialSuffix(task.taskId);
    const expectedCommitSize: number = task.sourceSize >= 0 ? task.sourceSize : task.totalBytes;
    const recoveredCommit: boolean | null = await this.recoverRemoteCommit(
      binding, task, targetSession, partialPath, targetPath, expectedCommitSize,
      'remote-copy');
    if (recoveredCommit !== null) { return recoveredCommit; }

    const sourceIdentityResult: SshSftpEngineIdentityResult = await this.readRemoteIdentityResult(
      sourceSession.sessionId, sourcePath, sourceSession.generation);
    if (sourceIdentityResult.transportLost) {
      return this.failRemoteOperationOrWait(binding, task, sourceSession, targetSession,
        'remote-copy-source-stat-lost', sourceSession);
    }
    const sourceIdentity: SshSftpFileIdentity | null = sourceIdentityResult.identity;
    if (sourceIdentity === null || sourceIdentity.size > MAX_TRANSFER_BYTES ||
      (task.sourceSize >= 0 && !sshSftpIdentityMatches(
        { size: task.sourceSize, mtime: task.sourceMtime }, sourceIdentity))) {
      hilog.warn(0x0017, 'SshTerminal', diagnosticPrefix +
        ' remote-copy-source-identity-changed');
      return this.failRemoteOperationOrWait(binding, task, sourceSession, targetSession,
        'remote-copy-source-identity-changed');
    }
    let effectiveTask: SshSftpTaskRecord = task;
    if (task.verifiedOffset <= 0) {
      const conflict: SshSftpEngineConflictPlan = await this.prepareRemoteConflict(
        binding, targetSession, task, targetPath);
      if (conflict.action === 'waiting' || conflict.action === 'failed') { return false; }
      if (conflict.action === 'skip') { return this.completeFileTask(binding, task, 'conflict-skipped'); }
      if (conflict.fileName !== task.fileName || conflict.targetPath !== targetPath) {
        targetPath = conflict.targetPath;
        partialPath = targetPath + sshSftpPartialSuffix(task.taskId);
        effectiveTask = this.updateTask(task, 'queued', task.verifiedOffset,
          task.partialSize, task.partialMtime, targetPath, conflict.fileName,
          task.sessionGeneration, targetPath, sourcePath);
      }
    }

    const offset: number = effectiveTask.verifiedOffset >= 0 ? effectiveTask.verifiedOffset : 0;
    if (!sshSftpOffsetIsValid(offset, sourceIdentity.size) ||
      !this.remoteSessionsActive(sourceSession, targetSession)) {
      hilog.warn(0x0017, 'SshTerminal', diagnosticPrefix +
        ' remote-copy-offset-or-session-invalid offset=' + offset.toString() +
        ' sourceSize=' + sourceIdentity.size.toString());
      return this.remoteSessionsActive(sourceSession, targetSession)
        ? this.failTask(binding, effectiveTask, 'remote-copy-offset-invalid')
        : this.waitForConnection(binding, effectiveTask);
    }
    let partialIdentity: SshSftpFileIdentity | null = null;
    if (offset > 0) {
      const partialResult: SshSftpEngineIdentityResult = await this.readRemoteIdentityResult(
        targetSession.sessionId, partialPath, targetSession.generation);
      if (partialResult.transportLost) {
        return this.failRemoteOperationOrWait(binding, effectiveTask, sourceSession, targetSession,
          'remote-copy-resume-partial-stat-lost', targetSession);
      }
      partialIdentity = partialResult.identity;
      if (partialIdentity === null || partialIdentity.size !== offset || partialIdentity.mtime < 0 ||
        effectiveTask.partialSize !== offset || effectiveTask.partialMtime < 0 ||
        effectiveTask.partialMtime !== partialIdentity.mtime) {
        hilog.warn(0x0017, 'SshTerminal', diagnosticPrefix +
          ' remote-copy-partial-identity-mismatch offset=' + offset.toString());
        return this.failRemoteOperationOrWait(binding, effectiveTask, sourceSession, targetSession,
          'remote-copy-partial-identity-mismatch');
      }
    }
    effectiveTask = this.updateTask(effectiveTask, 'transferring', offset,
      partialIdentity === null ? -1 : partialIdentity.size,
      partialIdentity === null ? -1 : partialIdentity.mtime,
      targetPath, effectiveTask.fileName, targetSession.generation, targetPath, sourcePath);
    try {
      let copied: number = offset;
      if (sourceIdentity.size === 0) {
        const empty: SftpWriteAsyncResult = await this.loader.writeRemoteFileChunkAsync(
          targetSession.sessionId, partialPath, new ArrayBuffer(0), 0, true,
          targetSession.generation);
        if (empty.errorCode < 0 || empty.bytesWritten !== 0) {
          hilog.warn(0x0017, 'SshTerminal', diagnosticPrefix +
            ' remote-copy-empty-partial-failed ret=' + empty.errorCode.toString());
          return this.failRemoteOperationOrWait(binding, effectiveTask, sourceSession, targetSession,
            'remote-copy-empty-partial-failed', empty.transportLost === true ? targetSession : null);
        }
        const identityResult: SshSftpEngineIdentityResult = await this.readRemoteIdentityResult(
          targetSession.sessionId, partialPath, targetSession.generation);
        if (identityResult.transportLost) {
          return this.failRemoteOperationOrWait(binding, effectiveTask, sourceSession, targetSession,
            'remote-copy-empty-partial-stat-lost', targetSession);
        }
        const identity: SshSftpFileIdentity | null = identityResult.identity;
        if (identity === null || identity.size !== 0 || identity.mtime < 0) {
          hilog.warn(0x0017, 'SshTerminal', diagnosticPrefix +
            ' remote-copy-empty-partial-unverified');
          return this.failRemoteOperationOrWait(binding, effectiveTask, sourceSession, targetSession,
            'remote-copy-empty-partial-unverified');
        }
        effectiveTask = this.updateTask(effectiveTask, 'transferring', 0,
          identity.size, identity.mtime, targetPath, effectiveTask.fileName,
          targetSession.generation, targetPath, sourcePath);
      }
      while (copied < sourceIdentity.size) {
        if (!this.remoteSessionsActive(sourceSession, targetSession)) {
          hilog.warn(0x0017, 'SshTerminal', diagnosticPrefix +
            ' sessions lost at offset=' + copied.toString());
          return this.waitForConnection(binding, effectiveTask);
        }
        if (this.taskIsStopped(effectiveTask.taskId)) { return false; }
        const chunkSize: number = Math.min(UPLOAD_CHUNK_BYTES, sourceIdentity.size - copied);
        const read: SftpReadAsyncResult = await this.loader.readRemoteFileChunkAsync(
          sourceSession.sessionId, sourcePath, copied, chunkSize, sourceSession.generation);
        if (read.errorCode < 0 || read.data.byteLength <= 0 ||
          read.data.byteLength > sourceIdentity.size - copied) {
          hilog.warn(0x0017, 'SshTerminal', diagnosticPrefix +
            ' remote-copy-source-read-failed ret=' + read.errorCode.toString() +
            ' offset=' + copied.toString());
          return this.failRemoteOperationOrWait(binding, effectiveTask, sourceSession, targetSession,
            'remote-copy-source-read-failed', read.transportLost === true ? sourceSession : null);
        }
        const written: SftpWriteAsyncResult = await this.loader.writeRemoteFileChunkAsync(
          targetSession.sessionId, partialPath, read.data, copied, copied === 0,
          targetSession.generation);
        if (written.errorCode < 0 || written.bytesWritten !== read.data.byteLength) {
          hilog.warn(0x0017, 'SshTerminal', diagnosticPrefix +
            ' remote-copy-target-write-unconfirmed ret=' + written.errorCode.toString() +
            ' written=' + written.bytesWritten.toString());
          return this.failRemoteOperationOrWait(binding, effectiveTask, sourceSession, targetSession,
            'remote-copy-target-write-unconfirmed', written.transportLost === true ? targetSession : null);
        }
        copied += read.data.byteLength;
        const identityResult: SshSftpEngineIdentityResult = await this.readRemoteIdentityResult(
          targetSession.sessionId, partialPath, targetSession.generation);
        if (identityResult.transportLost) {
          return this.failRemoteOperationOrWait(binding, effectiveTask, sourceSession, targetSession,
            'remote-copy-partial-stat-lost', targetSession);
        }
        const identity: SshSftpFileIdentity | null = identityResult.identity;
        if (identity === null || identity.size !== copied || identity.mtime < 0) {
          hilog.warn(0x0017, 'SshTerminal', diagnosticPrefix +
            ' remote-copy-partial-unverified offset=' + copied.toString());
          return this.failRemoteOperationOrWait(binding, effectiveTask, sourceSession, targetSession,
            'remote-copy-partial-unverified');
        }
        effectiveTask = this.updateTask(effectiveTask, 'transferring', copied,
          identity.size, identity.mtime, targetPath, effectiveTask.fileName,
          targetSession.generation, targetPath, sourcePath);
      }
      if (this.taskIsStopped(effectiveTask.taskId)) { return false; }
      effectiveTask = this.updateTask(effectiveTask, 'verifying', sourceIdentity.size,
        effectiveTask.partialSize, effectiveTask.partialMtime, targetPath,
        effectiveTask.fileName, targetSession.generation, targetPath, sourcePath);
      const finalSourceResult: SshSftpEngineIdentityResult = await this.readRemoteIdentityResult(
        sourceSession.sessionId, sourcePath, sourceSession.generation);
      const finalPartialResult: SshSftpEngineIdentityResult = await this.readRemoteIdentityResult(
        targetSession.sessionId, partialPath, targetSession.generation);
      if (finalSourceResult.transportLost || finalPartialResult.transportLost) {
        return this.failRemoteOperationOrWait(binding, effectiveTask, sourceSession, targetSession,
          'remote-copy-final-stat-lost', finalSourceResult.transportLost ? sourceSession : targetSession);
      }
      const finalSource: SshSftpFileIdentity | null = finalSourceResult.identity;
      const finalPartial: SshSftpFileIdentity | null = finalPartialResult.identity;
      if (finalSource === null || !sshSftpIdentityMatches(sourceIdentity, finalSource) ||
        finalPartial === null || !sshSftpCommitSizeMatches(finalPartial.size, sourceIdentity.size)) {
        hilog.warn(0x0017, 'SshTerminal', diagnosticPrefix +
          ' remote-copy-final-identity-mismatch');
        return this.failRemoteOperationOrWait(binding, effectiveTask, sourceSession, targetSession,
          'remote-copy-final-identity-mismatch');
      }
      if (!this.remoteSessionsActive(sourceSession, targetSession)) {
        hilog.warn(0x0017, 'SshTerminal', diagnosticPrefix +
          ' sessions lost before commit');
        return this.waitForConnection(binding, effectiveTask);
      }
      return await this.commitRemotePartial(binding, effectiveTask, targetSession,
        partialPath, targetPath, sourceIdentity.size, finalPartial,
        'remote-copy');
    } catch (_err) {
      hilog.error(0x0017, 'SshTerminal', diagnosticPrefix + ' remote-copy-exception');
      return this.failRemoteOperationOrWait(binding, effectiveTask, sourceSession, targetSession,
        'remote-copy-exception');
    }
  }

  private async executeDirectory(binding: SshSftpBatchBinding,
    session: SshSftpEngineSession, task: SshSftpTaskRecord): Promise<boolean> {
    if (this.taskIsStopped(task.taskId)) { return false; }
    if (!this.sessionActive(binding.hostId, session)) { return this.waitForConnection(binding, task); }
    const relative: string = this.batchTaskSourceRelativePath(task);
    if (task.direction === 'upload') {
      const source: string | null = await this.ensureLocalBatchPath(binding.localRoot, relative, true);
      if (source === null || !await this.ensureRemoteDirectory(session.sessionId, task.remotePath,
        binding.hostId, session)) {
        return this.failOperationOrWait(binding, task, session, 'directory-prepare-failed');
      }
    } else if (await this.ensureLocalBatchPath(binding.localRoot, relative, true) === null) {
      return this.failTask(binding, task, 'local-directory-prepare-failed');
    }
    if (!this.sessionActive(binding.hostId, session)) { return this.waitForConnection(binding, task); }
    if (this.taskIsStopped(task.taskId)) { return false; }
    const result = this.store.command(task.taskId, { kind: 'complete' });
    if (result.accepted) {
      this.publish('taskChanged', binding.batchId, this.store.get(task.taskId), 'completed');
      return true;
    }
    return this.failTask(binding, task, 'directory-complete-rejected');
  }

  private async executeUpload(binding: SshSftpBatchBinding,
    session: SshSftpEngineSession, task: SshSftpTaskRecord): Promise<boolean> {
    if (this.taskIsStopped(task.taskId)) { return false; }
    let partialPath: string = task.remotePath + sshSftpPartialSuffix(task.taskId);
    const expectedCommitSize: number = task.sourceSize >= 0 ? task.sourceSize : task.totalBytes;
    const recoveredCommit: boolean | null = await this.recoverRemoteCommit(
      binding, task, session, partialPath, task.remotePath, expectedCommitSize, 'upload');
    if (recoveredCommit !== null) { return recoveredCommit; }
    const relative: string = this.batchTaskSourceRelativePath(task);
    const sourceUri: string | null = await this.provider.resolveRelative(binding.localRoot, relative);
    if (sourceUri === null) { return this.failTask(binding, task, 'local-source-missing'); }
    const sourceIdentity: SshSftpFileIdentity | null = await this.readLocalIdentity(sourceUri);
    if (sourceIdentity === null || sourceIdentity.size > MAX_TRANSFER_BYTES ||
      (task.sourceSize >= 0 && !sshSftpIdentityMatches(
        { size: task.sourceSize, mtime: task.sourceMtime }, sourceIdentity))) {
      return this.failTask(binding, task, 'local-source-identity-changed');
    }
    let effectiveTask: SshSftpTaskRecord = task;
    if (task.verifiedOffset <= 0) {
      const conflict: SshSftpEngineConflictPlan = await this.prepareRemoteConflict(
        binding, session, task);
      if (conflict.action === 'waiting' || conflict.action === 'failed') { return false; }
      if (conflict.action === 'skip') { return this.completeFileTask(binding, task, 'conflict-skipped'); }
      if (conflict.fileName !== task.fileName || conflict.targetPath !== task.remotePath) {
        effectiveTask = this.retargetTask(task, conflict.targetPath, conflict.fileName);
        partialPath = effectiveTask.remotePath + sshSftpPartialSuffix(effectiveTask.taskId);
      }
    }
    const offset: number = effectiveTask.verifiedOffset >= 0 ? effectiveTask.verifiedOffset : 0;
    if (!sshSftpOffsetIsValid(offset, sourceIdentity.size) ||
      !this.sessionActive(binding.hostId, session)) {
      return this.sessionActive(binding.hostId, session)
        ? this.failTask(binding, effectiveTask, 'upload-offset-invalid')
        : this.waitForConnection(binding, effectiveTask);
    }
    let partialIdentity: SshSftpFileIdentity | null = null;
    if (offset > 0) {
      const partialResult: SshSftpEngineIdentityResult = await this.readRemoteIdentityResult(
        session.sessionId, partialPath, session.generation);
      if (partialResult.transportLost) {
        return this.failOperationOrWait(binding, effectiveTask, session,
          'upload-resume-partial-stat-lost', true);
      }
      partialIdentity = partialResult.identity;
      if (partialIdentity === null || partialIdentity.size !== offset || partialIdentity.mtime < 0 ||
        effectiveTask.partialSize !== offset || effectiveTask.partialMtime < 0 ||
        effectiveTask.partialMtime !== partialIdentity.mtime) {
        return this.failTask(binding, effectiveTask, 'upload-partial-identity-mismatch');
      }
    }
    this.updateTask(effectiveTask, 'transferring', offset,
      partialIdentity === null ? -1 : partialIdentity.size,
      partialIdentity === null ? -1 : partialIdentity.mtime);
    let source: fileIo.File | null = null;
    try {
      // Resumed async I/O against a re-opened authorized docs URI can remain
      // pending on API 24 after pause closes the original descriptor. A task
      // with a verified offset uses deterministic local I/O around its seek.
      source = offset > 0
        ? fileIo.openSync(sourceUri, fileIo.OpenMode.READ_ONLY)
        : await fileIo.open(sourceUri, fileIo.OpenMode.READ_ONLY);
      if (fileIo.lseek(source.fd, offset) !== offset) {
        return this.failTask(binding, effectiveTask, 'upload-local-seek-failed');
      }
      let uploaded: number = offset;
      if (sourceIdentity.size === 0) {
        const empty: SftpWriteAsyncResult = await this.loader.writeRemoteFileChunkAsync(
          session.sessionId, partialPath, new ArrayBuffer(0), 0, true, session.generation);
        if (empty.errorCode < 0 || empty.bytesWritten !== 0) {
          return this.failOperationOrWait(binding, effectiveTask, session,
            empty.errorCode === DURABILITY_UNSUPPORTED ? 'upload-durability-unsupported' :
              'upload-empty-partial-failed', empty.transportLost === true);
        }
        const identityResult: SshSftpEngineIdentityResult = await this.readRemoteIdentityResult(
          session.sessionId, partialPath, session.generation);
        if (identityResult.transportLost) {
          return this.failOperationOrWait(binding, effectiveTask, session,
            'upload-empty-partial-stat-lost', true);
        }
        const identity: SshSftpFileIdentity | null = identityResult.identity;
        if (identity === null || identity.size !== 0 || identity.mtime < 0) {
          return this.failTask(binding, effectiveTask, 'upload-empty-partial-unverified');
        }
        const checkpointed: SshSftpTaskRecord | null =
          this.checkpointConfirmedUploadWrite(effectiveTask, 0, identity);
        if (checkpointed === null) { return false; }
        effectiveTask = checkpointed;
        if (this.taskIsStopped(effectiveTask.taskId)) { return false; }
      }
      while (uploaded < sourceIdentity.size) {
        if (!this.sessionActive(binding.hostId, session)) {
          return this.waitForConnection(binding, effectiveTask);
        }
        if (this.taskIsStopped(effectiveTask.taskId)) { return false; }
        const chunkSize: number = Math.min(UPLOAD_CHUNK_BYTES, sourceIdentity.size - uploaded);
        const chunk = new ArrayBuffer(chunkSize);
        const readLength: number = offset > 0
          ? fileIo.readSync(source.fd, chunk)
          : await fileIo.read(source.fd, chunk);
        if (readLength <= 0) { return this.failTask(binding, effectiveTask, 'upload-local-read-failed'); }
        const payload: ArrayBuffer = readLength === chunkSize ? chunk : chunk.slice(0, readLength);
        const written: SftpWriteAsyncResult = await this.loader.writeRemoteFileChunkAsync(
          session.sessionId, partialPath, payload, uploaded, uploaded === 0, session.generation);
        if (written.errorCode < 0 || written.bytesWritten !== payload.byteLength) {
          return this.failOperationOrWait(binding, effectiveTask, session,
            written.errorCode === DURABILITY_UNSUPPORTED ? 'upload-durability-unsupported' :
              'upload-write-unconfirmed', written.transportLost === true);
        }
        uploaded += payload.byteLength;
        const identityResult: SshSftpEngineIdentityResult = await this.readRemoteIdentityResult(
          session.sessionId, partialPath, session.generation);
        if (identityResult.transportLost) {
          return this.failOperationOrWait(binding, effectiveTask, session,
            'upload-partial-stat-lost', true);
        }
        const identity: SshSftpFileIdentity | null = identityResult.identity;
        if (identity === null || identity.size !== uploaded || identity.mtime < 0) {
          return this.failTask(binding, effectiveTask, 'upload-partial-unverified');
        }
        const checkpointed: SshSftpTaskRecord | null =
          this.checkpointConfirmedUploadWrite(effectiveTask, uploaded, identity);
        if (checkpointed === null) { return false; }
        effectiveTask = checkpointed;
        if (this.taskIsStopped(effectiveTask.taskId)) { return false; }
      }
      if (this.taskIsStopped(effectiveTask.taskId)) { return false; }
      const finalSource: SshSftpFileIdentity | null = await this.readLocalIdentity(sourceUri);
      if (finalSource === null || !sshSftpIdentityMatches(sourceIdentity, finalSource)) {
        return this.failTask(binding, effectiveTask, 'upload-source-changed');
      }
      const partialFinalResult: SshSftpEngineIdentityResult = await this.readRemoteIdentityResult(
        session.sessionId, partialPath, session.generation);
      if (partialFinalResult.transportLost) {
        return this.failOperationOrWait(binding, effectiveTask, session,
          'upload-final-partial-stat-lost', true);
      }
      const partialFinal: SshSftpFileIdentity | null = partialFinalResult.identity;
      if (partialFinal === null || !sshSftpCommitSizeMatches(partialFinal.size, sourceIdentity.size)) {
        return this.failTask(binding, effectiveTask, 'upload-partial-size-mismatch');
      }
      if (this.taskIsStopped(effectiveTask.taskId)) { return false; }
      return await this.commitRemotePartial(binding, effectiveTask, session, partialPath,
        effectiveTask.remotePath, sourceIdentity.size, partialFinal, 'upload');
    } catch (_err) {
      return this.failTask(binding, effectiveTask, 'upload-exception');
    } finally {
      if (source !== null) {
        try { await fileIo.close(source); } catch (_err) { /* best effort */ }
      }
    }
  }

  private async executeDownload(binding: SshSftpBatchBinding,
    session: SshSftpEngineSession, task: SshSftpTaskRecord): Promise<boolean> {
    if (this.taskIsStopped(task.taskId)) { return false; }
    const remoteIdentityResult: SshSftpEngineIdentityResult = await this.readRemoteIdentityResult(
      session.sessionId, task.remotePath, session.generation);
    if (remoteIdentityResult.transportLost) {
      return this.failOperationOrWait(binding, task, session,
        'download-remote-stat-lost', true);
    }
    const remoteIdentity: SshSftpFileIdentity | null = remoteIdentityResult.identity;
    if (remoteIdentity === null || remoteIdentity.size > MAX_TRANSFER_BYTES ||
      (task.sourceSize >= 0 && !sshSftpIdentityMatches(
        { size: task.sourceSize, mtime: task.sourceMtime }, remoteIdentity))) {
      return this.failTask(binding, task, 'download-remote-identity-changed');
    }
    const relative: string = this.batchTaskSourceRelativePath(task);
    const slash: number = relative.lastIndexOf('/');
    const parentRelative: string = slash >= 0 ? relative.substring(0, slash) : '';
    const localParent: string | null = await this.ensureLocalBatchPath(
      binding.localRoot, parentRelative, true);
    const finalUri: string | null = await this.provider.resolveRelative(binding.localRoot, relative);
    if (localParent === null || finalUri === null) {
      return this.failTask(binding, task, 'download-local-target-invalid');
    }
    let targetUri: string = finalUri;
    if (task.verifiedOffset <= 0) {
      const conflict: SshSftpEngineConflictPlan = await this.prepareLocalConflict(
        localParent, task, binding.conflictPolicy);
      if (conflict.action === 'waiting' || conflict.action === 'failed') { return false; }
      if (conflict.action === 'skip') { return this.completeFileTask(binding, task, 'conflict-skipped'); }
      targetUri = conflict.targetPath;
    }
    const partialPath: string = await this.partialPath(task.taskId);
    if (partialPath.length === 0) { return this.failTask(binding, task, 'download-partial-path-invalid'); }
    const offset: number = task.verifiedOffset >= 0 ? task.verifiedOffset : 0;
    if (!sshSftpOffsetIsValid(offset, remoteIdentity.size)) {
      return this.failTask(binding, task, 'download-offset-invalid');
    }
    let partialIdentity: SshSftpFileIdentity | null = null;
    if (offset > 0) {
      partialIdentity = await this.readLocalIdentity(partialPath);
      if (partialIdentity === null || partialIdentity.size !== offset || partialIdentity.mtime < 0 ||
        task.partialSize !== offset || task.partialMtime < 0 || task.partialMtime !== partialIdentity.mtime) {
        return this.failTask(binding, task, 'download-partial-identity-mismatch');
      }
    }
    this.updateTask(task, 'transferring', offset,
      partialIdentity === null ? -1 : partialIdentity.size,
      partialIdentity === null ? -1 : partialIdentity.mtime);
    let target: fileIo.File | null = null;
    try {
      const openMode: number = fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE |
        (offset === 0 ? fileIo.OpenMode.TRUNC : 0);
      target = await fileIo.open(partialPath, openMode);
      if (fileIo.lseek(target.fd, offset) !== offset) {
        return this.failTask(binding, task, 'download-local-seek-failed');
      }
      let downloaded: number = offset;
      while (downloaded < remoteIdentity.size) {
        if (!this.sessionActive(binding.hostId, session)) {
          return this.waitForConnection(binding, task);
        }
        if (this.taskIsStopped(task.taskId)) { return false; }
        const chunkSize: number = Math.min(DOWNLOAD_CHUNK_BYTES, remoteIdentity.size - downloaded);
        const result: SftpReadAsyncResult = await this.loader.readRemoteFileChunkAsync(
          session.sessionId, task.remotePath, downloaded, chunkSize, session.generation);
        if (result.errorCode < 0 || result.data.byteLength <= 0 ||
          result.data.byteLength > remoteIdentity.size - downloaded) {
          return this.failOperationOrWait(binding, task, session,
            'download-read-failed', result.transportLost === true);
        }
        const written: number = await fileIo.write(target.fd, result.data);
        if (written !== result.data.byteLength) {
          return this.failTask(binding, task, 'download-local-write-failed');
        }
        downloaded += written;
        const identity: SshSftpFileIdentity | null = await this.readLocalIdentity(partialPath);
        if (identity === null || identity.size !== downloaded || identity.mtime < 0) {
          return this.failTask(binding, task, 'download-partial-unverified');
        }
        task = this.updateTask(task, 'transferring', downloaded, identity.size, identity.mtime);
        if (this.taskIsStopped(task.taskId)) { return false; }
      }
      if (this.taskIsStopped(task.taskId)) { return false; }
      await fileIo.fsync(target.fd);
      await fileIo.close(target);
      target = null;
      const finalRemoteResult: SshSftpEngineIdentityResult = await this.readRemoteIdentityResult(
        session.sessionId, task.remotePath, session.generation);
      if (finalRemoteResult.transportLost) {
        return this.failOperationOrWait(binding, task, session,
          'download-final-stat-lost', true);
      }
      const finalRemote: SshSftpFileIdentity | null = finalRemoteResult.identity;
      const finalPartial: SshSftpFileIdentity | null = await this.readLocalIdentity(partialPath);
      if (finalRemote === null || !sshSftpIdentityMatches(remoteIdentity, finalRemote) ||
        finalPartial === null || !sshSftpCommitSizeMatches(finalPartial.size, remoteIdentity.size)) {
        return this.failTask(binding, task, 'download-final-identity-mismatch');
      }
      if (this.taskIsStopped(task.taskId)) { return false; }
      if (!await this.exportPartial(partialPath, targetUri, remoteIdentity.size)) {
        return this.failTask(binding, task, 'download-atomic-export-failed');
      }
      return this.completeFileTask(binding, task, 'completed');
    } catch (_err) {
      return this.failTask(binding, task, 'download-exception');
    } finally {
      if (target !== null) {
        try { await fileIo.close(target); } catch (_err) { /* best effort */ }
      }
    }
  }

  private async prepareRemoteConflict(binding: SshSftpBatchBinding,
    session: SshSftpEngineSession, task: SshSftpTaskRecord,
    requestedPath: string = task.remotePath): Promise<SshSftpEngineConflictPlan> {
    const remotePath: string = requestedPath.trim();
    const parent: string = this.parentRemotePath(remotePath);
    const listed: SftpListAsyncResult = await this.loader.listRemoteDirAsync(
      session.sessionId, parent, session.generation);
    if (listed.errorCode < 0) {
      if (listed.transportLost === true) {
        this.markTransportLost(session, 'remote-conflict-list');
        this.waitForConnection(binding, task);
        return { action: 'waiting', targetPath: remotePath, fileName: task.fileName };
      }
      this.failTask(binding, task, 'remote-conflict-list-failed');
      return { action: 'failed', targetPath: remotePath, fileName: task.fileName };
    }
    let existing: SftpFileEntry | null = null;
    for (let index = 0; index < listed.entries.length; index++) {
      if (listed.entries[index].path === remotePath) { existing = listed.entries[index]; break; }
    }
    if (existing === null) {
      return { action: 'ready', targetPath: remotePath, fileName: task.fileName };
    }
    if (existing.isDirectory || existing.isSymbolicLink || existing.isSpecialFile) {
      return { action: 'failed', targetPath: remotePath, fileName: task.fileName };
    }
    const resolution = resolveSshSftpConflict(true, false, this.conflictPolicyFor(binding, task));
    if (resolution.requiresDecision) {
      this.markConflict(binding, task, 'remote-conflict');
      return { action: 'waiting', targetPath: remotePath, fileName: task.fileName };
    }
    if (resolution.action === 'skip') {
      return { action: 'skip', targetPath: remotePath, fileName: task.fileName };
    }
    if (resolution.action === 'keepBoth') {
      const names: string[] = listed.entries.map((entry: SftpFileEntry): string => entry.name);
      const name: string = nextSshSftpKeepBothName(task.fileName, names);
      const target: string = this.joinRemotePath(parent, name);
      if (name.length === 0) {
        return { action: 'failed', targetPath: remotePath, fileName: task.fileName };
      }
      return { action: 'ready', targetPath: target, fileName: name };
    }
    return { action: 'ready', targetPath: remotePath, fileName: task.fileName };
  }

  private async prepareLocalConflict(parentUri: string, task: SshSftpTaskRecord,
    policy: SshSftpConflictPolicy): Promise<SshSftpEngineConflictPlan> {
    const target: string | null = await this.provider.resolveRelative(parentUri, task.fileName);
    if (target === null) { return { action: 'failed', targetPath: '', fileName: task.fileName }; }
    const existing: SshLocalFileEntry | null = await this.provider.stat(target);
    if (existing === null) { return { action: 'ready', targetPath: target, fileName: task.fileName }; }
    if (existing.isDirectory || existing.isSymbolicLink || existing.isSpecialFile) {
      return { action: 'failed', targetPath: target, fileName: task.fileName };
    }
    const binding: SshSftpBatchBinding | undefined = this.bindings.get(task.batchId);
    const resolution = resolveSshSftpConflict(true, false,
      binding === undefined ? policy : this.conflictPolicyFor(binding, task));
    if (resolution.requiresDecision) {
      this.markConflict(this.bindings.get(task.batchId) as SshSftpBatchBinding, task, 'local-conflict');
      return { action: 'waiting', targetPath: target, fileName: task.fileName };
    }
    if (resolution.action === 'skip') {
      return { action: 'skip', targetPath: target, fileName: task.fileName };
    }
    if (resolution.action === 'keepBoth') {
      const siblings: SshLocalFileEntry[] = await this.provider.list(parentUri);
      const names: string[] = siblings.map((entry: SshLocalFileEntry): string => entry.name);
      const name: string = nextSshSftpKeepBothName(task.fileName, names);
      const keepBoth: string | null = name.length === 0 ? null :
        await this.provider.resolveRelative(parentUri, name);
      return keepBoth === null
        ? { action: 'failed', targetPath: target, fileName: task.fileName }
        : { action: 'ready', targetPath: keepBoth, fileName: name };
    }
    if (!await this.provider.remove(target, false)) {
      return { action: 'failed', targetPath: target, fileName: task.fileName };
    }
    return { action: 'ready', targetPath: target, fileName: task.fileName };
  }

  private markConflict(binding: SshSftpBatchBinding, task: SshSftpTaskRecord, reason: string): void {
    this.updateTask(task, 'awaitingConflictDecision', task.verifiedOffset,
      task.partialSize, task.partialMtime);
    this.publish('conflict', binding.batchId, this.store.get(task.taskId), reason);
  }

  private conflictPolicyFor(binding: SshSftpBatchBinding,
    task: SshSftpTaskRecord): SshSftpConflictPolicy {
    const taskPolicy: SshSftpConflictPolicy | undefined = this.conflictPolicies.get(task.taskId);
    return taskPolicy === undefined ? binding.conflictPolicy : taskPolicy;
  }

  private retargetTask(task: SshSftpTaskRecord, remotePath: string,
    fileName: string): SshSftpTaskRecord {
    return this.updateTask(task, 'queued', task.verifiedOffset, task.partialSize,
      task.partialMtime, remotePath, fileName, task.sessionGeneration,
      remotePath, task.sourcePath);
  }

  private completeFileTask(binding: SshSftpBatchBinding, task: SshSftpTaskRecord,
    reason: string): boolean {
    const completed: SshSftpTaskRecord = this.updateTask(task, 'completed', task.totalBytes, -1, -1);
    if (completed.stage !== 'completed') {
      this.publish('taskChanged', binding.batchId, completed, completed.stage);
      return false;
    }
    this.publish('taskChanged', binding.batchId, completed, reason);
    return true;
  }

  private failTask(binding: SshSftpBatchBinding, task: SshSftpTaskRecord, reason: string): boolean {
    const current: SshSftpTaskRecord | null = this.store.get(task.taskId);
    if (current !== null && (current.stage === 'paused' || current.stage === 'cancelled')) {
      this.publish('taskChanged', binding.batchId, current, current.stage);
      return false;
    }
    const failed: SshSftpTaskRecord = this.updateTask(task, 'failed', task.verifiedOffset,
      task.partialSize, task.partialMtime);
    this.publish('batchBlocked', binding.batchId, failed, reason);
    return false;
  }

  private waitForConnection(binding: SshSftpBatchBinding, task: SshSftpTaskRecord): boolean {
    if (this.taskIsStopped(task.taskId)) { return false; }
    this.store.command(task.taskId, { kind: 'detach' });
    this.publish('taskChanged', binding.batchId, this.store.get(task.taskId), 'waiting-for-connection');
    return false;
  }

  private updateTask(task: SshSftpTaskRecord, stage: SshSftpTaskStage, offset: number,
    partialSize: number, partialMtime: number, remotePath: string = task.remotePath,
    fileName: string = task.fileName,
    sessionGeneration: number = task.sessionGeneration,
    targetPath: string = task.targetPath || remotePath,
    sourcePath: string = task.sourcePath || task.relativePath,
    commitState: 'renaming' | 'renamed' | undefined = task.commitState): SshSftpTaskRecord {
    const current: SshSftpTaskRecord | null = this.store.get(task.taskId);
    if (current !== null && (current.stage === 'paused' || current.stage === 'cancelled')) {
      return current;
    }
    this.sequence = Math.max(this.sequence + 1, Date.now(), task.sequence + 1);
    const now: number = Date.now();
    const next: SshSftpTaskRecord = {
      taskId: task.taskId,
      batchId: task.batchId,
      relativePath: task.relativePath,
      hostId: task.hostId,
      direction: task.direction,
      isDirectory: task.isDirectory,
      remotePath,
      fileName,
      totalBytes: task.totalBytes,
      verifiedOffset: offset,
      sourceSize: task.sourceSize,
      sourceMtime: task.sourceMtime,
      partialSize,
      partialMtime,
      sessionGeneration,
      sequence: this.sequence,
      stage,
      updatedAt: now,
      sourceEndpoint: task.sourceEndpoint,
      targetEndpoint: task.targetEndpoint,
      sourcePath,
      targetPath,
      partialIdentity: partialSize >= 0 && partialMtime >= 0
        ? {
          size: partialSize,
          mtime: partialMtime,
          checksum: task.partialIdentity === undefined ? undefined : task.partialIdentity.checksum
        }
        : undefined,
      checksumPolicy: task.checksumPolicy,
      commitState
    };
    this.store.upsert(next);
    const stored: SshSftpTaskRecord | null = this.store.get(task.taskId);
    return stored === null ? next : stored;
  }

  private checkpointConfirmedUploadWrite(task: SshSftpTaskRecord, offset: number,
    partialIdentity: SshSftpFileIdentity): SshSftpTaskRecord | null {
    const current: SshSftpTaskRecord | null = this.store.get(task.taskId);
    if (current === null) { return null; }
    if (current.stage !== 'paused' && current.stage !== 'cancelled') {
      return this.updateTask(task, 'transferring', offset,
        partialIdentity.size, partialIdentity.mtime);
    }
    this.sequence = Math.max(this.sequence + 1, Date.now(), current.sequence + 1);
    const reconciled: SshSftpTaskRecord | null = reconcileSshSftpStoppedUploadCheckpoint(
      current, offset, partialIdentity, this.sequence, Date.now());
    if (reconciled === null || !this.store.upsert(reconciled)) { return current; }
    const stored: SshSftpTaskRecord | null = this.store.get(task.taskId);
    return stored === null ? reconciled : stored;
  }

  private taskIsStopped(taskId: string): boolean {
    const current: SshSftpTaskRecord | null = this.store.get(taskId);
    // Removing the final cancelled history row must also stop an in-flight
    // worker; otherwise a stale worker could recreate the discarded record.
    return current === null || current.stage === 'paused' || current.stage === 'cancelled';
  }

  private publish(kind: SshSftpTaskEngineEventKind, batchId: string,
    record: SshSftpTaskRecord | null, reason: string): void {
    const event: SshSftpTaskEngineEvent = { kind, batchId, record, reason };
    const listeners: SshSftpTaskEngineListener[] = this.listeners.slice();
    for (let index = 0; index < listeners.length; index++) {
      try { listeners[index](event); } catch (_err) { /* observers cannot stop the engine */ }
    }
  }

  private logDiagnostic(message: string, warning: boolean = false): void {
    if (warning) {
      hilog.warn(0x0017, 'SshTerminal', '[sftp-engine] ' + message);
    } else {
      hilog.info(0x0017, 'SshTerminal', '[sftp-engine] ' + message);
    }
  }

  private sessionActive(hostId: string, session: SshSftpEngineSession): boolean {
    const tracked: SshSftpTrackedSession = session as SshSftpTrackedSession;
    if (!this.sessionOwners.isCurrent(hostId, tracked)) { return false; }
    let nativeState: number = -1;
    try {
      nativeState = this.loader.getConnectionState(session.sessionId);
    } catch (_err) {
      nativeState = -1;
    }
    if (nativeState !== SSH_STATE_CONNECTED) {
      this.sessionOwners.discardIfCurrent(hostId, tracked);
      return false;
    }
    return true;
  }

  private async ensureRemoteDirectory(sessionId: number, path: string,
    hostId: string, session: SshSftpEngineSession): Promise<boolean> {
    const normalized: string = this.normalizeRemoteDir(path);
    if (normalized === '/' || normalized === '.') { return true; }
    const parent: string = this.parentRemotePath(normalized);
    if (!await this.ensureRemoteDirectory(sessionId, parent, hostId, session)) { return false; }
    if (!this.sessionActive(hostId, session)) { return false; }
    const name: string = this.remoteBaseName(normalized);
    const listed: SftpListAsyncResult = await this.loader.listRemoteDirAsync(
      sessionId, parent, session.generation);
    if (listed.errorCode < 0) {
      if (listed.transportLost === true) { this.markTransportLost(session, 'directory-list'); }
      return false;
    }
    for (let index = 0; index < listed.entries.length; index++) {
      const entry: SftpFileEntry = listed.entries[index];
      if (entry.isDirectory && (entry.path === normalized || entry.name === name)) { return true; }
    }
    const created: SftpMutationAsyncResult = await this.loader.makeRemoteDirAsync(
      sessionId, normalized, session.generation);
    if (created.errorCode === 0) { return true; }
    if (created.transportLost === true) {
      this.markTransportLost(session, 'directory-create');
      return false;
    }
    const confirmed: SftpListAsyncResult = await this.loader.listRemoteDirAsync(
      sessionId, parent, session.generation);
    if (confirmed.errorCode < 0) {
      if (confirmed.transportLost === true) { this.markTransportLost(session, 'directory-confirm'); }
      return false;
    }
    for (let index = 0; index < confirmed.entries.length; index++) {
      const entry: SftpFileEntry = confirmed.entries[index];
      if (entry.isDirectory && (entry.path === normalized || entry.name === name)) { return true; }
    }
    return false;
  }

  private async readRemoteIdentityResult(sessionId: number, path: string,
    expectedGeneration: number = 0): Promise<SshSftpEngineIdentityResult> {
    const result: SftpListAsyncResult = await this.loader.listRemoteDirAsync(
      sessionId, this.parentRemotePath(path), expectedGeneration);
    if (result.errorCode < 0) {
      return {
        identity: null,
        errorCode: result.errorCode,
        transportLost: result.transportLost === true
      };
    }
    for (let index = 0; index < result.entries.length; index++) {
      const entry: SftpFileEntry = result.entries[index];
      if (!entry.isDirectory && entry.path === path) {
        return {
          identity: {
            size: Number.isFinite(entry.size) && entry.size >= 0 ? entry.size : -1,
            mtime: Number.isFinite(entry.mtime) && entry.mtime >= 0 ? entry.mtime : -1
          },
          errorCode: result.errorCode,
          transportLost: false
        };
      }
    }
    return { identity: null, errorCode: result.errorCode, transportLost: false };
  }

  private async readLocalIdentity(path: string): Promise<SshSftpFileIdentity | null> {
    try {
      const info = await fileIo.stat(path);
      const size: number = Number(info.size);
      const mtime: number = Number(info.mtime);
      return {
        size: Number.isFinite(size) && size >= 0 ? size : -1,
        mtime: Number.isFinite(mtime) && mtime >= 0 ? mtime : -1
      };
    } catch (_err) {
      return null;
    }
  }

  private async partialPath(taskId: string): Promise<string> {
    const root: string = await this.provider.transferBoxRoot();
    if (root.length > 0) { return root + '/ssh-sftp-' + taskId + '.partial'; }
    if (this.context !== null) { return this.context.cacheDir + '/ssh-sftp-' + taskId + '.partial'; }
    return '';
  }

  private async ensureLocalBatchPath(localRoot: string, relativePath: string,
    leafIsDirectory: boolean): Promise<string | null> {
    const root: SshLocalFileEntry | null = await this.provider.stat(localRoot);
    if (root === null || !root.isDirectory || root.isSymbolicLink) { return null; }
    const raw: string = relativePath.replace(/\\/g, '/').trim();
    const parts: string[] = raw.length === 0 ? [] : raw.split('/');
    const count: number = leafIsDirectory ? parts.length : Math.max(0, parts.length - 1);
    let current: string = localRoot;
    for (let index = 0; index < count; index++) {
      const name: string = parts[index];
      if (!this.safeName(name)) { return null; }
      const target: string | null = await this.provider.resolveRelative(current, name);
      if (target === null) { return null; }
      let entry: SshLocalFileEntry | null = await this.provider.stat(target);
      if (entry === null) {
        if (!await this.provider.createDirectory(current, name)) {
          entry = await this.provider.stat(target);
        } else {
          entry = await this.provider.stat(target);
        }
      }
      if (entry === null || !entry.isDirectory || entry.isSymbolicLink) { return null; }
      current = target;
    }
    return current;
  }

  private batchTaskSourceRelativePath(task: SshSftpTaskRecord): string {
    const slash: number = task.relativePath.indexOf('/');
    return slash >= 0 ? task.relativePath.substring(slash + 1) :
      (task.isDirectory ? '' : task.fileName);
  }

  private safeName(name: string): boolean {
    const trimmed: string = name.trim();
    return trimmed.length > 0 && trimmed !== '.' && trimmed !== '..' &&
      trimmed.indexOf('/') < 0 && trimmed.indexOf('\\') < 0 && trimmed.indexOf('\0') < 0;
  }

  private normalizeRemoteDir(path: string): string {
    const trimmed: string = path.trim();
    if (trimmed.length === 0) { return '.'; }
    let value: string = trimmed.replace(/\\+/g, '/');
    if (value.length > 1 && value.endsWith('/')) { value = value.substring(0, value.length - 1); }
    return value;
  }

  private parentRemotePath(path: string): string {
    const normalized: string = this.normalizeRemoteDir(path);
    if (normalized === '/' || normalized === '.') { return '.'; }
    const slash: number = normalized.lastIndexOf('/');
    if (slash <= 0) { return normalized.startsWith('/') ? '/' : '.'; }
    return normalized.substring(0, slash);
  }

  private remoteBaseName(path: string): string {
    const normalized: string = this.normalizeRemoteDir(path);
    const slash: number = normalized.lastIndexOf('/');
    return slash >= 0 ? normalized.substring(slash + 1) : normalized;
  }

  private joinRemotePath(parent: string, name: string): string {
    const base: string = this.normalizeRemoteDir(parent);
    if (base === '/') { return '/' + name; }
    if (base === '.') { return './' + name; }
    return base + '/' + name;
  }

  private async exportPartial(partialPath: string, finalUri: string,
    expectedSize: number): Promise<boolean> {
    if (partialPath.length === 0 || finalUri.length === 0 || partialPath === finalUri) { return false; }
    let source: fileIo.File | null = null;
    let destination: fileIo.File | null = null;
    try {
      source = await fileIo.open(partialPath, fileIo.OpenMode.READ_ONLY);
      destination = await fileIo.open(finalUri,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      let copied: number = 0;
      while (copied < expectedSize) {
        const chunkSize: number = Math.min(DOWNLOAD_CHUNK_BYTES, expectedSize - copied);
        const chunk = new ArrayBuffer(chunkSize);
        const readLength: number = await fileIo.read(source.fd, chunk);
        if (readLength <= 0) { return false; }
        const payload: ArrayBuffer = readLength === chunkSize ? chunk : chunk.slice(0, readLength);
        const written: number = await fileIo.write(destination.fd, payload);
        if (written !== readLength) { return false; }
        copied += written;
      }
      await fileIo.fsync(destination.fd);
      await fileIo.close(destination);
      destination = null;
      const identity: SshSftpFileIdentity | null = await this.readLocalIdentity(finalUri);
      if (identity === null || !sshSftpCommitSizeMatches(identity.size, expectedSize)) { return false; }
      try { await fileIo.unlink(partialPath); } catch (_err) { /* cleanup is best effort */ }
      return true;
    } catch (_err) {
      return false;
    } finally {
      if (source !== null) { try { await fileIo.close(source); } catch (_err) { /* best effort */ } }
      if (destination !== null) { try { await fileIo.close(destination); } catch (_err) { /* best effort */ } }
    }
  }
}
