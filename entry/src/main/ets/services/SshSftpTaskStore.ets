import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  SshSftpBatchPlan,
  SshSftpTreeItem,
  joinSshSftpRelativeRemotePath,
  normalizeSshSftpRemotePath
} from './SshSftpBatchPolicy';
import {
  SshSftpTaskDirection,
  SshSftpTaskRecord,
  SshSftpTaskStage,
  SshSftpResumeContext,
  SshSftpResumeDisposition,
  SshSftpTaskCommand,
  SshSftpTaskCommandResult,
  SshSftpTaskEvent,
  SshSftpTaskListener,
  SftpEndpoint,
  SftpTransferSpec,
  isValidSftpTransferSpec,
  normalizeSshSftpTaskRecord,
  recoverInterruptedSshSftpTaskRecord,
  canTransitionSshSftpTask,
  sshSftpResumeDisposition,
  sshSftpTaskCommandTarget,
  upsertSshSftpTask,
  sshSftpTaskMaxCount
} from './SshSftpTaskPolicy';
import { recordDiagnosticEvent } from './DiagnosticCaptureRuntime';

const PREFS_NAME: string = 'RemoteDesktopSshSftpPrefs';
const TASKS_KEY: string = 'ssh.sftp.tasks.v1';
const FLUSH_DELAY_MS: number = 300;
const MAX_BATCH_ID_LENGTH: number = 64;

export interface SshSftpBatchTaskEnqueueResult {
  accepted: boolean;
  reason: string;
  batchId: string;
  records: SshSftpTaskRecord[];
}

/**
 * SSH-only durable metadata owner. It never persists credentials, Picker
 * grants, local URI values or payload bytes. Metadata writes are coalesced so
 * transfer checkpoints cannot block terminal input on every chunk.
 */
export class SshSftpTaskStore {
  private static instance: SshSftpTaskStore | null = null;
  private context: common.Context | null = null;
  private records: SshSftpTaskRecord[] = [];
  private flushTimer: number = -1;
  private dirty: boolean = false;
  private mutationVersion: number = 0;
  private flushInFlight: Promise<boolean> | null = null;
  private listeners: SshSftpTaskListener[] = [];
  private batchSequence: number = 0;
  private taskSequence: number = 0;
  private initialized: boolean = false;

  static getInstance(): SshSftpTaskStore {
    if (SshSftpTaskStore.instance === null) {
      SshSftpTaskStore.instance = new SshSftpTaskStore();
    }
    return SshSftpTaskStore.instance;
  }

  init(context: common.Context): void {
    // This store is process-scoped. Re-entering the SSH page must not reload a
    // possibly older preferences snapshot over an active background transfer.
    if (this.initialized) {
      this.context = context;
      return;
    }
    this.initialized = true;
    if (this.flushTimer !== -1) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
    this.context = context;
    this.records = [];
    this.taskSequence = 0;
    this.dirty = false;
    this.mutationVersion++;
    let recoveredInterruptedTask: boolean = false;
    try {
      const prefs = preferences.getPreferencesSync(context, { name: PREFS_NAME });
      const stored: Object = prefs.getSync(TASKS_KEY, '');
      if (typeof stored === 'string' && (stored as string).length > 0) {
        const parsed: Object = JSON.parse(stored as string) as Object;
        if (Array.isArray(parsed)) {
          for (let index = 0; index < parsed.length; index++) {
            const normalized: SshSftpTaskRecord | null =
              normalizeSshSftpTaskRecord(parsed[index] as Object);
            if (normalized !== null) {
              const recovered: SshSftpTaskRecord =
                recoverInterruptedSshSftpTaskRecord(normalized);
              recoveredInterruptedTask = recovered !== normalized || recoveredInterruptedTask;
              this.records = upsertSshSftpTask(this.records, recovered);
            }
          }
        }
      }
    } catch (_err) {
      this.records = [];
    }
    this.dirty = recoveredInterruptedTask;
    this.publishRestoredRecords();
    if (this.dirty) { this.scheduleFlush(); }
  }

  /** Subscribe to durable task changes without exposing the preferences layer. */
  subscribe(listener: SshSftpTaskListener, replayRestored: boolean = true): () => void {
    this.listeners.push(listener);
    if (replayRestored) {
      const restored: SshSftpTaskRecord[] = this.records.slice();
      for (let index = 0; index < restored.length; index++) {
        try { listener({ kind: 'restored', record: restored[index] }); } catch (_err) {
          // Observers cannot break task subscription or persistence.
        }
      }
    }
    let active: boolean = true;
    return (): void => {
      if (!active) { return; }
      active = false;
      this.listeners = this.listeners.filter(
        (candidate: SshSftpTaskListener): boolean => candidate !== listener);
    };
  }

  list(hostId: string = ''): SshSftpTaskRecord[] {
    const filter: string = hostId.trim();
    return this.records.filter((record: SshSftpTaskRecord): boolean =>
      filter.length === 0 || record.hostId === filter);
  }

  listBatch(hostId: string, batchId: string): SshSftpTaskRecord[] {
    const owner: string = hostId.trim();
    const id: string = batchId.trim();
    if (owner.length === 0 || id.length === 0) { return []; }
    return this.records.filter((record: SshSftpTaskRecord): boolean =>
      record.hostId === owner && record.batchId === id);
  }

  get(taskId: string): SshSftpTaskRecord | null {
    const id: string = taskId.trim();
    for (let index = 0; index < this.records.length; index++) {
      if (this.records[index].taskId === id) { return this.records[index]; }
    }
    return null;
  }

  resumeDisposition(taskId: string, context: SshSftpResumeContext): SshSftpResumeDisposition {
    const record: SshSftpTaskRecord | null = this.get(taskId);
    return record === null ? 'NotResumable' : sshSftpResumeDisposition(record, context);
  }

  upsert(record: SshSftpTaskRecord): boolean {
    const normalized: SshSftpTaskRecord | null = normalizeSshSftpTaskRecord(record as Object);
    if (normalized === null) { return false; }
    const current: SshSftpTaskRecord | null = this.get(normalized.taskId);
    const nextRecords: SshSftpTaskRecord[] = upsertSshSftpTask(this.records, normalized);
    let stored: SshSftpTaskRecord | null = null;
    for (let index = 0; index < nextRecords.length; index++) {
      if (nextRecords[index].taskId === normalized.taskId) {
        stored = nextRecords[index];
        break;
      }
    }
    if (stored === null || (current !== null && stored === current)) { return false; }
    this.records = nextRecords;
    this.mutationVersion++;
    this.dirty = true;
    this.scheduleFlush();
    this.publish({ kind: 'changed', record: stored });
    return true;
  }

  remove(taskId: string): void {
    const id: string = taskId.trim();
    if (id.length === 0) { return; }
    const removed: SshSftpTaskRecord | null = this.get(id);
    if (removed === null) { return; }
    const next: SshSftpTaskRecord[] = this.records.filter(
      (record: SshSftpTaskRecord): boolean => record.taskId !== id);
    this.records = next;
    this.mutationVersion++;
    this.dirty = true;
    this.scheduleFlush();
    this.publish({ kind: 'removed', record: removed });
  }

  /**
   * Apply a command through the durable transition policy. The returned record
   * is the store-owned snapshot; network/file I/O remains outside this class.
   */
  command(taskId: string, command: SshSftpTaskCommand): SshSftpTaskCommandResult {
    const current: SshSftpTaskRecord | null = this.get(taskId);
    if (current === null) {
      return { accepted: false, reason: 'task-not-found', record: null };
    }
    if (command.kind === 'complete' && !current.isDirectory) {
      return { accepted: false, reason: 'directory-task-required', record: current };
    }
    const target: SshSftpTaskStage | null =
      sshSftpTaskCommandTarget(current.stage, command);
    if (target === null) {
      return { accepted: false, reason: 'command-not-applicable', record: current };
    }
    if (!canTransitionSshSftpTask(current.stage, target)) {
      return { accepted: false, reason: 'invalid-stage-transition', record: current };
    }
    const now: number = Date.now();
    const next: SshSftpTaskRecord = {
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
      verifiedOffset: current.verifiedOffset,
      sourceSize: current.sourceSize,
      sourceMtime: current.sourceMtime,
      partialSize: current.partialSize,
      partialMtime: current.partialMtime,
      sessionGeneration: current.sessionGeneration,
      sequence: Math.max(current.sequence + 1, now),
      stage: target,
      updatedAt: now,
      sourceEndpoint: current.sourceEndpoint,
      targetEndpoint: current.targetEndpoint,
      sourcePath: current.sourcePath,
      targetPath: current.targetPath,
      partialIdentity: current.partialIdentity,
      checksumPolicy: current.checksumPolicy,
      commitState: current.commitState
    };
    if (!this.upsert(next)) {
      return { accepted: false, reason: 'stale-update', record: current };
    }
    return { accepted: true, reason: 'accepted', record: this.get(next.taskId) };
  }

  /** Enqueue an explicit local/SSH or SSH/SSH task without page-owned state. */
  enqueueTransferSpec(spec: SftpTransferSpec, hostId: string, fileName: string,
    totalBytes: number, sourceSize: number = totalBytes, sourceMtime: number = -1,
    isDirectory: boolean = false): SshSftpTaskRecord | null {
    const owner: string = hostId.trim();
    const name: string = fileName.trim();
    if (!isValidSftpTransferSpec(spec) || owner.length === 0 || name.length === 0 ||
      name.length > 255 || !Number.isFinite(totalBytes) || totalBytes < -1 ||
      !Number.isFinite(sourceSize) || sourceSize < -1) {
      return null;
    }
    const remoteEndpoint: SftpEndpoint = spec.source.kind === 'ssh'
      ? spec.source : spec.target;
    if (remoteEndpoint.kind !== 'ssh' || (remoteEndpoint.hostId || '').trim().length === 0) {
      return null;
    }
    if (this.get(spec.taskId) !== null) { return null; }
    const remotePath: string = spec.source.kind === 'ssh' ? spec.sourcePath : spec.targetPath;
    const record: SshSftpTaskRecord = {
      schemaVersion: 4,
      taskId: spec.taskId.trim(),
      batchId: '',
      relativePath: spec.source.kind === 'local' ? spec.sourcePath : spec.targetPath,
      hostId: owner,
      direction: spec.direction,
      isDirectory,
      remotePath,
      fileName: name,
      totalBytes: isDirectory ? 0 : totalBytes,
      verifiedOffset: 0,
      sourceSize: isDirectory ? 0 : sourceSize,
      sourceMtime: isDirectory ? 0 : sourceMtime,
      partialSize: -1,
      partialMtime: -1,
      sessionGeneration: 0,
      sequence: this.nextTaskSequence(),
      stage: 'queued',
      updatedAt: Date.now(),
      sourceEndpoint: spec.source,
      targetEndpoint: spec.target,
      sourcePath: spec.sourcePath,
      targetPath: spec.targetPath,
      partialIdentity: spec.partialIdentity,
      checksumPolicy: spec.checksumPolicy
    };
    return this.upsert(record) ? this.get(record.taskId) : null;
  }

  /** Create one durable task per item, including empty directories, in a validated batch plan. */
  enqueueBatch(hostId: string, direction: SshSftpTaskDirection, remoteRoot: string,
    plan: SshSftpBatchPlan, requestedBatchId: string = ''): SshSftpBatchTaskEnqueueResult {
    const owner: string = hostId.trim();
    const root: string | null = normalizeSshSftpRemotePath(remoteRoot);
    if (owner.length === 0 || root === null) {
      return { accepted: false, reason: 'invalid-batch-owner-or-root', batchId: '', records: [] };
    }
    if (!plan.accepted) {
      return { accepted: false, reason: 'invalid-batch-plan', batchId: '', records: [] };
    }
    const items: SshSftpTreeItem[] = plan.items;
    if (items.length === 0) {
      return { accepted: false, reason: 'batch-has-no-items', batchId: '', records: [] };
    }
    if (items.length > sshSftpTaskMaxCount() || this.records.length + items.length > sshSftpTaskMaxCount()) {
      return { accepted: false, reason: 'task-limit', batchId: '', records: [] };
    }
    const batchId: string = requestedBatchId.trim().length > 0
      ? requestedBatchId.trim() : this.nextBatchId();
    if (batchId.length > MAX_BATCH_ID_LENGTH || !/^[A-Za-z0-9_-]+$/.test(batchId)) {
      return { accepted: false, reason: 'invalid-batch-id', batchId: '', records: [] };
    }

    const records: SshSftpTaskRecord[] = [];
    for (let index = 0; index < items.length; index++) {
      const item: SshSftpTreeItem = items[index];
      if (item.isSymbolicLink || item.isSpecialFile || item.name.trim().length === 0 ||
        item.name.indexOf('/') >= 0 || item.name.indexOf('\\') >= 0 || item.name.indexOf('\0') >= 0 ||
        (!item.isDirectory && (!Number.isFinite(item.size) || item.size < 0))) {
        return { accepted: false, reason: 'invalid-batch-item', batchId: '', records: [] };
      }
      const remotePath: string | null = joinSshSftpRelativeRemotePath(root, item.relativePath);
      if (remotePath === null) {
        return { accepted: false, reason: 'invalid-batch-path', batchId: '', records: [] };
      }
      const taskId: string = batchId + '-' + (index + 1).toString();
      if (this.get(taskId) !== null) {
        return { accepted: false, reason: 'duplicate-batch-task', batchId: '', records: [] };
      }
      const sequence: number = this.nextTaskSequence();
      records.push({
        taskId,
        schemaVersion: 4,
        batchId,
        relativePath: item.relativePath,
        hostId: owner,
        direction,
        isDirectory: item.isDirectory,
        remotePath,
        fileName: item.name.trim(),
        totalBytes: item.isDirectory ? 0 : item.size,
        verifiedOffset: 0,
        sourceSize: item.isDirectory ? 0 : item.size,
        sourceMtime: Number.isFinite(item.mtime) && item.mtime >= 0 ? item.mtime : -1,
        partialSize: -1,
        partialMtime: -1,
        sessionGeneration: 0,
        sequence,
        stage: 'queued',
        updatedAt: sequence,
        sourceEndpoint: direction === 'upload'
          ? { kind: 'local' } as SftpEndpoint
          : { kind: 'ssh', hostId: owner } as SftpEndpoint,
        targetEndpoint: direction === 'upload'
          ? { kind: 'ssh', hostId: owner } as SftpEndpoint
          : { kind: 'local' } as SftpEndpoint,
        sourcePath: direction === 'upload' ? item.relativePath : remotePath,
        targetPath: direction === 'upload' ? remotePath : item.relativePath,
        partialIdentity: undefined,
        checksumPolicy: 'size_mtime'
      });
    }
    for (let index = 0; index < records.length; index++) {
      if (!this.upsert(records[index])) {
        return { accepted: false, reason: 'batch-task-write-failed', batchId, records: [] };
      }
    }
    const stored: SshSftpTaskRecord[] = records.map((record: SshSftpTaskRecord): SshSftpTaskRecord =>
      this.get(record.taskId) as SshSftpTaskRecord);
    return { accepted: true, reason: 'accepted', batchId, records: stored };
  }

  /** Create a durable SSH-to-SSH batch owned by the target host. */
  enqueueRemoteBatch(sourceHostId: string, targetHostId: string,
    sourceRoot: string, targetRoot: string, direction: SshSftpTaskDirection,
    plan: SshSftpBatchPlan, requestedBatchId: string = ''): SshSftpBatchTaskEnqueueResult {
    const sourceOwner: string = sourceHostId.trim();
    const targetOwner: string = targetHostId.trim();
    const sourceBase: string | null = normalizeSshSftpRemotePath(sourceRoot);
    const targetBase: string | null = normalizeSshSftpRemotePath(targetRoot);
    if (sourceOwner.length === 0 || targetOwner.length === 0 ||
      sourceBase === null || targetBase === null) {
      return { accepted: false, reason: 'invalid-remote-endpoint-or-root', batchId: '', records: [] };
    }
    if (!plan.accepted || plan.items.length === 0) {
      return { accepted: false, reason: 'invalid-batch-plan', batchId: '', records: [] };
    }
    if (plan.items.length > sshSftpTaskMaxCount() ||
      this.records.length + plan.items.length > sshSftpTaskMaxCount()) {
      return { accepted: false, reason: 'task-limit', batchId: '', records: [] };
    }
    const batchId: string = requestedBatchId.trim().length > 0
      ? requestedBatchId.trim() : this.nextBatchId();
    if (batchId.length > MAX_BATCH_ID_LENGTH || !/^[A-Za-z0-9_-]+$/.test(batchId)) {
      return { accepted: false, reason: 'invalid-batch-id', batchId: '', records: [] };
    }
    const sourceEndpoint: SftpEndpoint = { kind: 'ssh', hostId: sourceOwner };
    const targetEndpoint: SftpEndpoint = { kind: 'ssh', hostId: targetOwner };
    const records: SshSftpTaskRecord[] = [];
    for (let index = 0; index < plan.items.length; index++) {
      const item: SshSftpTreeItem = plan.items[index];
      if (item.name.trim().length === 0 || item.isSymbolicLink || item.isSpecialFile ||
        (!item.isDirectory && (!Number.isFinite(item.size) || item.size < 0))) {
        return { accepted: false, reason: 'invalid-batch-item', batchId: '', records: [] };
      }
      const sourcePath: string | null = joinSshSftpRelativeRemotePath(sourceBase, item.relativePath);
      const targetPath: string | null = joinSshSftpRelativeRemotePath(targetBase, item.relativePath);
      if (sourcePath === null || targetPath === null) {
        return { accepted: false, reason: 'invalid-remote-batch-path', batchId: '', records: [] };
      }
      const taskId: string = batchId + '-' + (index + 1).toString();
      if (this.get(taskId) !== null) {
        return { accepted: false, reason: 'duplicate-batch-task', batchId: '', records: [] };
      }
      const spec: SftpTransferSpec = {
        schemaVersion: 4,
        taskId,
        source: sourceEndpoint,
        target: targetEndpoint,
        sourcePath,
        targetPath,
        direction,
        checksumPolicy: 'size_mtime'
      };
      if (!isValidSftpTransferSpec(spec)) {
        return { accepted: false, reason: 'same-remote-endpoint-path', batchId: '', records: [] };
      }
      const sequence: number = this.nextTaskSequence();
      records.push({
        taskId,
        schemaVersion: 4,
        batchId,
        relativePath: item.relativePath,
        // The target host owns task listing and recovery. Source/target remain
        // explicit so a late callback cannot silently reverse the copy.
        hostId: targetOwner,
        direction,
        isDirectory: item.isDirectory,
        remotePath: targetPath,
        fileName: item.name.trim(),
        totalBytes: item.isDirectory ? 0 : item.size,
        verifiedOffset: 0,
        sourceSize: item.isDirectory ? 0 : item.size,
        sourceMtime: Number.isFinite(item.mtime) && item.mtime >= 0 ? item.mtime : -1,
        partialSize: -1,
        partialMtime: -1,
        sessionGeneration: 0,
        sequence,
        stage: 'queued',
        updatedAt: sequence,
        sourceEndpoint,
        targetEndpoint,
        sourcePath,
        targetPath,
        partialIdentity: undefined,
        checksumPolicy: 'size_mtime'
      });
    }
    for (let index = 0; index < records.length; index++) {
      if (!this.upsert(records[index])) {
        return { accepted: false, reason: 'batch-task-write-failed', batchId, records: [] };
      }
    }
    const stored: SshSftpTaskRecord[] = records.map((record: SshSftpTaskRecord): SshSftpTaskRecord =>
      this.get(record.taskId) as SshSftpTaskRecord);
    return { accepted: true, reason: 'accepted', batchId, records: stored };
  }

  async flushNow(): Promise<boolean> {
    if (this.flushTimer !== -1) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
    // A mutation can arrive while the provider flush is awaiting. Keep
    // draining until the snapshot that includes the newest mutation lands.
    if (this.context === null && this.dirty) { return false; }
    while (this.dirty) {
      if (!await this.flush()) { return false; }
    }
    return true;
  }

  private scheduleFlush(): void {
    if (this.flushTimer !== -1) { return; }
    this.flushTimer = setTimeout((): void => {
      this.flushTimer = -1;
      this.flush().catch((_err: Error): void => { /* next mutation retries persistence */ });
    }, FLUSH_DELAY_MS);
  }

  private async flush(): Promise<boolean> {
    if (this.flushInFlight !== null) { return await this.flushInFlight; }
    const context: common.Context | null = this.context;
    if (!this.dirty || context === null) { return true; }
    const version: number = this.mutationVersion;
    const snapshot: string = JSON.stringify(this.records);
    const operation: Promise<boolean> = (async (): Promise<boolean> => {
      try {
        const prefs = preferences.getPreferencesSync(context, { name: PREFS_NAME });
        prefs.putSync(TASKS_KEY, snapshot);
        await prefs.flush();
        if (version === this.mutationVersion) {
          this.dirty = false;
        } else {
          // A checkpoint arrived while the provider flush was in flight. Keep
          // it dirty and schedule a second write instead of losing that state.
          this.dirty = true;
        }
        return true;
      } catch (_err) {
        return false;
      } finally {
        this.flushInFlight = null;
        if (this.dirty && version !== this.mutationVersion) { this.scheduleFlush(); }
      }
    })();
    this.flushInFlight = operation;
    return await operation;
  }

  private publishRestoredRecords(): void {
    for (let index = 0; index < this.records.length; index++) {
      this.publish({ kind: 'restored', record: this.records[index] });
    }
  }

  private publish(event: SshSftpTaskEvent): void {
    const stage: SshSftpTaskStage = event.record.stage;
    if (stage === 'queued') {
      recordDiagnosticEvent('connection.ssh_sftp', 'sftp_task_started', 'started',
        0, event.record.sessionGeneration, event.record.direction === 'upload' ? 1 : 2,
        0, 1, event.record.totalBytes > 0 ? event.record.totalBytes : 0);
    } else if (stage === 'completed' || stage === 'failed' || stage === 'cancelled') {
      recordDiagnosticEvent('connection.ssh_sftp', 'sftp_task_completed',
        stage === 'completed' ? 'succeeded' : (stage === 'cancelled' ? 'cancelled' : 'failed'),
        0, event.record.sessionGeneration, event.record.direction === 'upload' ? 1 : 2,
        0, 1, event.record.verifiedOffset > 0 ? event.record.verifiedOffset : 0);
    }
    const listeners: SshSftpTaskListener[] = this.listeners.slice();
    for (let index = 0; index < listeners.length; index++) {
      try { listeners[index](event); } catch (_err) { /* observers cannot break persistence */ }
    }
  }

  private nextBatchId(): string {
    this.batchSequence = (this.batchSequence + 1) % 1000000;
    return 'sftp-batch-' + Date.now().toString() + '-' + this.batchSequence.toString();
  }

  private nextTaskSequence(): number {
    this.taskSequence = Math.max(this.taskSequence + 1, Date.now());
    return this.taskSequence;
  }
}
