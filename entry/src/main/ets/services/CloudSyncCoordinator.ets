import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CloudSyncSelectionStore } from './CloudSyncSelectionStore';
import { CloudSyncDirection } from './CloudSyncPolicy';
import { ActiveRemoteSessionRegistry } from './ActiveRemoteSessionRegistry';
import { VncRecordType } from '../model/VncRecord';
import { VncCloudSyncSelectionStore } from './VncCloudSyncSelectionStore';
import { VNC_CLOUD_TABLE } from './VncRecordPolicy';
import { DataCrypto } from './DataCrypto';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from './AccountScopePolicy';
import {
  CloudAccountBinding,
  cloudTransferAllowed,
  unboundCloudAccountBinding
} from './CloudLifecycleSafetyPolicy';
import {
  CloudSyncDurableState,
  cloudSyncAutomaticUploadAllowed,
  cloudSyncBootstrapCompleted,
  cloneCloudSyncDurableState,
  cloudSyncDownloadAllowed,
  cloudSyncDurableStateWithIntents,
  cloudSyncOperationFinished,
  cloudSyncOperationStarted,
  cloudSyncQuiesced,
  cloudSyncQuiescing,
  cloudSyncRestoreQuarantined,
  cloudSyncRestoreReleased,
  recoverCloudSyncDurableState
} from './CloudSyncLifecyclePolicy';
import {
  CLOUD_SYNC_MAX_RETRY_ATTEMPTS,
  CloudSyncRequest,
  CloudSyncRetryRecord,
  CloudSyncSource,
  CloudSyncFailureKind,
  automaticRetryKey,
  coalesceAutomaticPush,
  shouldBlockAutomaticRetry,
  isAutomaticRetryRecord,
  nextCloudSyncRetryDelayMs,
  retryTablesStillSelected,
  retryVncTablesStillSelected,
  shouldDeferAutomaticPushDuringBootstrap,
  shouldUseCloudFirstForInitialBootstrap,
  shouldReplayAutomaticPush,
  snapshotCloudSyncTables,
  upsertAutomaticRetryRecord,
  CloudSyncBootstrapState
} from './CloudSyncCoordinatorPolicy';

const DOMAIN = 0x0001;
const TAG = 'CloudSyncCoordinator';

export interface CloudSyncOperationResult {
  ok: boolean;
  source: CloudSyncSource;
  tables: string[];
  failedTables: string[];
  rollbackFailed: boolean;
  failureKind: CloudSyncFailureKind;
}

export type CloudSyncTableExecutor = (table: string, direction: CloudSyncDirection, label: string) => Promise<boolean>;

export interface CloudSyncCoordinatorHooks {
  beginManualDownload: () => boolean;
  rollbackManualDownload: () => Promise<boolean>;
  /** Return false to roll the just-applied cloud download back to its snapshot. */
  completeManualDownload: (tables: string[]) => boolean | void;
  /** Complete only successful tables without clearing unrelated restore quarantine. */
  completeManualDownloadPartial?: (tables: string[]) => boolean | void;
  setRestorePending: (pending: boolean) => void;
  pendingMutationTableRevisions?: () => Record<string, number>;
  acknowledgeMutationJournal?: (table: string, coveredRevision: number) => boolean;
  failureKindForTable?: (table: string) => CloudSyncFailureKind;
  hasRestoredNotUploaded?: () => boolean;
  clearRestoredNotUploaded?: () => boolean;
  setStartupSyncPending?: (pending: boolean) => void;
  hasCloudBootstrapCompleted?: () => boolean;
  markCloudBootstrapCompleted?: () => boolean;
  discardMutationJournalForTables?: (tables: string[]) => boolean;
  loadDurableState?: () => CloudSyncDurableState | null;
  persistDurableState?: (state: CloudSyncDurableState) => boolean;
}

/**
 * Runs one frozen request and turns every executor/hook failure into data the
 * queue can observe.  Exported for deterministic policy tests; the singleton
 * coordinator is its only production caller.
 */
export async function executeCloudSyncRequest(
  request: CloudSyncRequest,
  executor: CloudSyncTableExecutor | null,
  hooks: CloudSyncCoordinatorHooks | null,
  onCloudFirstApplied: (tables: string[]) => void
): Promise<CloudSyncOperationResult> {
  const failedTables: string[] = [];
  let failureKind: CloudSyncFailureKind = 'none';
  // A VNC-only request may carry cryptoparams only as an optional dependency
  // for encrypted VNC secrets. Its failure must not prevent the independent
  // vncrecord transfer from preserving metadata or opaque ciphertext. A
  // mixed manual request must retain the ordinary fail-closed behavior so a
  // crypto failure cannot accidentally affect RDP, RustDesk, SSH, or TOTP.
  const vncOnlyRequest: boolean = request.tables.indexOf(VNC_CLOUD_TABLE) >= 0 &&
    request.tables.every((table: string): boolean =>
      table === VNC_CLOUD_TABLE || table === 'cryptoparams');
  if (!executor || request.tables.length === 0) {
    return {
      ok: request.tables.length === 0, source: request.source, tables: request.tables.slice(),
      failedTables: request.tables.slice(), rollbackFailed: false,
      failureKind: request.tables.length === 0 ? 'none' : 'unknown'
    };
  }
  if (request.source === 'manualDownload') {
    try {
      if (!hooks || !hooks.beginManualDownload()) {
        return {
          ok: false, source: request.source, tables: request.tables.slice(),
          failedTables: request.tables.slice(), rollbackFailed: false, failureKind: 'unknown'
        };
      }
    } catch (_e) {
      return {
        ok: false, source: request.source, tables: request.tables.slice(),
        failedTables: request.tables.slice(), rollbackFailed: false, failureKind: 'unknown'
      };
    }
  }
  for (let i = 0; i < request.tables.length; i++) {
    const table: string = request.tables[i];
    let ok: boolean = false;
    try {
      ok = await executor(table, request.direction, request.source);
    } catch (_e) {
      failedTables.push(table);
      failureKind = hooks && hooks.failureKindForTable ? hooks.failureKindForTable(table) : 'unknown';
      if (table === 'cryptoparams') {
        if (vncOnlyRequest) { continue; }
        for (let j = i + 1; j < request.tables.length; j++) { failedTables.push(request.tables[j]); }
      }
      break;
    }
    if (!ok) {
      failedTables.push(table);
      failureKind = hooks && hooks.failureKindForTable ? hooks.failureKindForTable(table) : 'unknown';
      if (table === 'cryptoparams') {
        if (vncOnlyRequest) { continue; }
        for (let j = i + 1; j < request.tables.length; j++) { failedTables.push(request.tables[j]); }
        break;
      }
    }
  }
  let rollbackFailed: boolean = false;
  if (request.source === 'manualDownload' && hooks) {
    try {
      if (failedTables.length === 0) {
        const completed: boolean | void = hooks.completeManualDownload(request.tables.slice());
        if (completed === false) {
          failedTables.push(request.tables.length > 0 ? request.tables[0] : '');
          if (failureKind === 'none') { failureKind = 'unknown'; }
          rollbackFailed = !(await hooks.rollbackManualDownload());
        }
      } else if (vncOnlyRequest && failedTables.length === 1 &&
        failedTables[0] === 'cryptoparams') {
        // `cryptoparams` is optional for a VNC transfer: metadata and opaque
        // encrypted rows may still be pulled safely. Commit the successful
        // VNC table and retain the crypto failure for the caller; rolling the
        // whole snapshot back would turn an independent VNC sync failure into
        // the very data loss this boundary is meant to prevent.
        const completedTables: string[] = request.tables.filter(
          (table: string): boolean => table !== 'cryptoparams');
        const completed: boolean | void = hooks.completeManualDownloadPartial
          ? hooks.completeManualDownloadPartial(completedTables)
          : hooks.completeManualDownload(completedTables);
        if (completed === false) { rollbackFailed = !(await hooks.rollbackManualDownload()); }
      } else { rollbackFailed = !(await hooks.rollbackManualDownload()); }
    } catch (_e) {
      rollbackFailed = true;
    }
  }
  const result: CloudSyncOperationResult = {
    ok: failedTables.length === 0 && !rollbackFailed,
    source: request.source,
    tables: request.tables.slice(),
    failedTables,
    rollbackFailed,
    failureKind
  };
  if (result.ok && request.direction === 'cloudFirst') {
    try { onCloudFirstApplied(request.tables.slice()); } catch (_e) { /* listener failures do not stall sync */ }
  }
  return result;
}

/**
 * Owns the only synchronization queue in the app.  The RDB layer stays
 * ignorant of selection, foreground, retry, and restore policy so one source
 * cannot race another source with an opposite cloudSync direction.
 */
export class CloudSyncCoordinator {
  private static instance: CloudSyncCoordinator;
  private executor: CloudSyncTableExecutor | null = null;
  private readonly selection: CloudSyncSelectionStore = CloudSyncSelectionStore.getInstance();
  private readonly vncSelection: VncCloudSyncSelectionStore =
    VncCloudSyncSelectionStore.getInstance();
  private queueTail: Promise<void> = Promise.resolve();
  private pendingAutomaticTables: string[] = [];
  private deferredAutomaticTables: string[] = [];
  private pendingPull: Promise<CloudSyncOperationResult> | null = null;
  private onCloudFirstApplied: ((tables: string[]) => void) | null = null;
  private hooks: CloudSyncCoordinatorHooks | null = null;
  private retryTimer: number = -1;
  private retryRecords: CloudSyncRetryRecord[] = [];
  private restorePending: boolean = false;
  private automaticRetryAttempts: Record<string, number> = {};
  private automaticMutationVersions: Record<string, number> = {};
  private dirtyAutomaticTables: string[] = [];
  private blockedAutomaticTables: string[] = [];
  private journalMutationRevisions: Record<string, number> = {};
  private startupPull: Promise<CloudSyncOperationResult> | null = null;
  private startupState: CloudSyncBootstrapState = 'pending';
  private bootstrapCompleted: boolean = false;
  private currentLease: AccountSessionLease | null = null;
  private acceptingRequests: boolean = false;
  private bindingEpoch: number = 0;
  private currentBinding: CloudAccountBinding = unboundCloudAccountBinding();
  private transfersEnabled: boolean = false;
  private durableState: CloudSyncDurableState | null = null;

  static getInstance(): CloudSyncCoordinator {
    if (!CloudSyncCoordinator.instance) {
      CloudSyncCoordinator.instance = new CloudSyncCoordinator();
    }
    return CloudSyncCoordinator.instance;
  }

  bind(
    context: common.Context,
    lease: AccountSessionLease,
    binding: CloudAccountBinding,
    executor: CloudSyncTableExecutor,
    onCloudFirstApplied: (tables: string[]) => void,
    hooks: CloudSyncCoordinatorHooks
  ): boolean {
    if (this.currentLease !== null &&
      !accountSessionLeaseEquals(this.currentLease, lease)) {
      hilog.error(DOMAIN, TAG,
        'refused to replace a live account lease before dispose');
      return false;
    }
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    this.executor = executor;
    this.onCloudFirstApplied = onCloudFirstApplied;
    this.hooks = hooks;
    this.currentLease = cloneAccountSessionLease(lease);
    this.currentBinding = {
      state: binding.state,
      ownerScopeId: binding.ownerScopeId,
      storeIdentity: binding.storeIdentity,
      generation: binding.generation
    };
    this.transfersEnabled = cloudTransferAllowed(this.currentBinding);
    this.acceptingRequests = true;
    this.bindingEpoch++;
    this.queueTail = Promise.resolve();
    this.retryRecords = [];
    this.dirtyAutomaticTables = [];
    this.blockedAutomaticTables = [];
    this.pendingAutomaticTables = [];
    this.deferredAutomaticTables = [];
    this.automaticRetryAttempts = {};
    this.automaticMutationVersions = {};
    this.journalMutationRevisions = {};
    this.pendingPull = null;
    this.startupPull = null;
    this.restorePending = false;
    this.startupState = 'pending';
    this.bootstrapCompleted = true;
    if (hooks.hasCloudBootstrapCompleted) {
      try { this.bootstrapCompleted = hooks.hasCloudBootstrapCompleted(); } catch (_e) { this.bootstrapCompleted = false; }
    }
    let persistedState: CloudSyncDurableState | null = null;
    if (hooks.loadDurableState) {
      try { persistedState = hooks.loadDurableState(); } catch (_e) { persistedState = null; }
    }
    const recoveredState: CloudSyncDurableState =
      recoverCloudSyncDurableState(
        persistedState,
        this.currentBinding,
        this.transfersEnabled,
        this.bootstrapCompleted
      );
    if (!this.persistDurableCandidate(recoveredState)) {
      this.resetFailedBinding();
      return false;
    }
    this.restoreRetryRecord();
    this.restoreDirtyTables();
    this.restoreConflictTables();
    this.restoreMutationJournal();
    return true;
  }

  currentAccountLease(): AccountSessionLease | null {
    return this.currentLease === null ? null : cloneAccountSessionLease(this.currentLease);
  }

  isLeaseCurrent(lease: AccountSessionLease): boolean {
    return this.acceptingRequests && accountSessionLeaseEquals(this.currentLease, lease);
  }

  closeMutationGate(lease: AccountSessionLease): boolean {
    if (!accountSessionLeaseEquals(this.currentLease, lease)) { return false; }
    if (this.durableState !== null) {
      const next: CloudSyncDurableState =
        cloudSyncQuiescing(this.durableState);
      if (!this.persistDurableCandidate(next)) { return false; }
    }
    this.acceptingRequests = false;
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    return true;
  }

  reopenMutationGate(lease: AccountSessionLease): boolean {
    if (!accountSessionLeaseEquals(this.currentLease, lease)) { return false; }
    if (this.durableState !== null) {
      const next: CloudSyncDurableState = cloudSyncQuiesced(
        this.durableState, this.currentBinding, this.transfersEnabled);
      if (!this.persistDurableCandidate(next)) { return false; }
    }
    this.acceptingRequests = true;
    this.scheduleRetryTimer();
    return true;
  }

  /**
   * Stop accepting work and wait until every operation submitted under this
   * lease has completed. API 23 exposes no public cloud-sync cancellation;
   * timeout therefore means "indeterminate" and the caller must not close or
   * reuse the old store.
   */
  async quiesce(lease: AccountSessionLease, timeoutMs: number = 15000): Promise<boolean> {
    if (!this.closeMutationGate(lease)) { return false; }
    let timeoutId: number = -1;
    const drained: Promise<boolean> = this.queueTail.then(
      (): boolean => true,
      (): boolean => true
    );
    const timeout: Promise<boolean> = new Promise<boolean>(
      (resolve: (ok: boolean) => void): void => {
        timeoutId = setTimeout((): void => { resolve(false); },
          Math.max(1, timeoutMs)) as number;
      });
    const ok: boolean = await Promise.race([drained, timeout]);
    if (timeoutId >= 0) { clearTimeout(timeoutId); }
    if (!ok || !accountSessionLeaseEquals(this.currentLease, lease)) {
      return false;
    }
    if (this.durableState !== null) {
      const next: CloudSyncDurableState = cloudSyncQuiesced(
        this.durableState, this.currentBinding, this.transfersEnabled);
      if (!this.persistDurableCandidate(next)) { return false; }
    }
    return true;
  }

  async dispose(lease: AccountSessionLease, timeoutMs: number = 15000): Promise<boolean> {
    if (!(await this.quiesce(lease, timeoutMs))) { return false; }
    if (!accountSessionLeaseEquals(this.currentLease, lease)) { return false; }
    this.bindingEpoch++;
    this.executor = null;
    this.onCloudFirstApplied = null;
    this.hooks = null;
    this.currentLease = null;
    this.currentBinding = unboundCloudAccountBinding();
    this.transfersEnabled = false;
    this.durableState = null;
    this.pendingPull = null;
    this.startupPull = null;
    this.pendingAutomaticTables = [];
    this.deferredAutomaticTables = [];
    this.retryRecords = [];
    this.restorePending = false;
    return true;
  }

  requestStartupPull(): Promise<CloudSyncOperationResult> {
    if (this.startupPull) { return this.startupPull; }
    if (!this.transfersEnabled) {
      return Promise.resolve(this.rejectedResult(
        this.makeRequest('startup', 'cloudFirst'), 'cloud_service'));
    }
    const restoreBlocked: boolean = this.restoreUploadBlocked();
    const initialDirty: string[] = this.dirtyAutomaticTables.slice();
    const initialBootstrap: boolean = shouldUseCloudFirstForInitialBootstrap(this.bootstrapCompleted);
    this.startupState = 'pending';
    if (this.hooks && this.hooks.setStartupSyncPending) {
      try { this.hooks.setStartupSyncPending(true); } catch (_e) { /* best effort */ }
    }
    const operation: Promise<CloudSyncOperationResult> = restoreBlocked
      ? Promise.resolve(this.skippedResult('startup'))
      : initialBootstrap
        ? this.requestStartupCloudFirst()
        : this.requestEstablishedStartupPull(initialDirty);
    const completed: Promise<CloudSyncOperationResult> = operation.then((result: CloudSyncOperationResult): CloudSyncOperationResult => {
      return this.finishStartupPull(result, initialBootstrap, initialDirty, restoreBlocked);
    }, (_e: Error): CloudSyncOperationResult => {
      const failed: CloudSyncOperationResult = {
        ok: false, source: 'startup', tables: [], failedTables: [], rollbackFailed: false,
        failureKind: 'unknown'
      };
      return this.finishStartupPull(failed, initialBootstrap, initialDirty, restoreBlocked);
    });
    this.startupPull = completed.then((result: CloudSyncOperationResult): CloudSyncOperationResult => {
      this.startupPull = null;
      return result;
    });
    return this.startupPull;
  }

  private requestStartupCloudFirst(): Promise<CloudSyncOperationResult> {
    return this.requestCloudFirst('startup').then((result: CloudSyncOperationResult): Promise<CloudSyncOperationResult> =>
      this.requestVncCloudFirst('startup', result));
  }

  /**
   * Established devices may have intentional offline mutations from the
   * previous session. Preserve the historical native-first recovery for those
   * devices, but only after the startup queue has been claimed by this method.
   * A device without the durable bootstrap marker never enters this branch.
   */
  private requestEstablishedStartupPull(dirty: string[]): Promise<CloudSyncOperationResult> {
    const selected: string[] = this.selectedTables();
    const pushable: string[] = dirty.filter((table: string): boolean =>
      (selected.indexOf(table) >= 0 ||
        (table === VNC_CLOUD_TABLE && this.vncPhysicalTableSelected())) &&
      !this.isAutomaticSyncBlocked(table));
    const ordinaryPushable: string[] = pushable.filter((table: string): boolean => table !== VNC_CLOUD_TABLE);
    const vncPushable: boolean = pushable.indexOf(VNC_CLOUD_TABLE) >= 0 &&
      this.vncUploadTables().length > 0;
    if (ordinaryPushable.length === 0 && !vncPushable) {
      return this.requestStartupCloudFirst();
    }
    const versions: Record<string, number> = {};
    ordinaryPushable.forEach((table: string): void => {
      versions[table] = this.automaticMutationVersions[table] || 1;
    });
    const ordinaryRequest: CloudSyncRequest | null = ordinaryPushable.length === 0 ? null : {
      source: 'automaticPush', direction: 'nativeFirst', tables: snapshotCloudSyncTables(ordinaryPushable)
    };
    const ordinaryJournalRevisions: Record<string, number> =
      this.captureJournalRevisions(ordinaryPushable);
    const pushOrdinary = ordinaryRequest === null
      ? Promise.resolve(this.skippedResult('startup'))
      : this.enqueue(ordinaryRequest).then((result: CloudSyncOperationResult): CloudSyncOperationResult => {
        if (!result.ok) { return result; }
        ordinaryPushable.forEach((table: string): void => {
          this.acknowledgeJournal(table, ordinaryJournalRevisions[table] || 0);
          const currentJournalRevision: number = this.captureJournalRevisions([table])[table] || 0;
          if ((this.automaticMutationVersions[table] || versions[table]) === versions[table] &&
            currentJournalRevision <= 0) { this.clearDirtyTable(table); }
        });
        return result;
      });
    return pushOrdinary.then((ordinaryResult: CloudSyncOperationResult): Promise<CloudSyncOperationResult> => {
      if (!ordinaryResult.ok) { return Promise.resolve(ordinaryResult); }
      const pushVnc = vncPushable ? this.requestVncStartupPush() : Promise.resolve(this.skippedResult('startup'));
      return pushVnc.then((vncResult: CloudSyncOperationResult): Promise<CloudSyncOperationResult> => {
        if (!vncResult.ok) { return Promise.resolve(vncResult); }
        return this.requestStartupCloudFirst();
      });
    });
  }

  private finishStartupPull(result: CloudSyncOperationResult, initialBootstrap: boolean,
    initialDirty: string[], restoreBlocked: boolean): CloudSyncOperationResult {
    let finalResult: CloudSyncOperationResult = result;
    if (result.ok && initialBootstrap && !restoreBlocked) {
      // A pre-bootstrap journal is not evidence of user intent on a new
      // device. Clear every recorded table intent after the authoritative pull,
      // including currently deselected tables, so a later selector change
      // cannot resurrect an unsafe native-first upload.
      const discardTables: string[] = initialDirty.slice();
      if (this.hooks && this.hooks.discardMutationJournalForTables &&
        !this.hooks.discardMutationJournalForTables(discardTables)) {
        finalResult = {
          ok: false, source: result.source, tables: result.tables.slice(),
          failedTables: discardTables.slice(), rollbackFailed: false, failureKind: 'unknown'
        };
      } else {
        for (let i = 0; i < discardTables.length; i++) {
          this.clearAutomaticIntent(discardTables[i]);
        }
        if (this.hooks && this.hooks.markCloudBootstrapCompleted &&
          !this.hooks.markCloudBootstrapCompleted()) {
          finalResult = {
            ok: false, source: result.source, tables: result.tables.slice(),
            failedTables: result.tables.slice(), rollbackFailed: false, failureKind: 'unknown'
          };
        } else {
          this.bootstrapCompleted = true;
          if (!this.persistBootstrapCompletion()) {
            finalResult = {
              ok: false, source: result.source, tables: result.tables.slice(),
              failedTables: result.tables.slice(), rollbackFailed: false, failureKind: 'unknown'
            };
          }
        }
      }
    }
    if (finalResult.ok) {
      this.startupState = 'ready';
      this.bootstrapCompleted = this.bootstrapCompleted || initialBootstrap;
    } else {
      this.startupState = 'pending';
    }
    if (this.hooks && this.hooks.setStartupSyncPending) {
      try { this.hooks.setStartupSyncPending(false); } catch (_e) { /* best effort */ }
    }
    if (finalResult.ok) { this.flushDeferredAutomaticPushes(); }
    return finalResult;
  }

  private completeExplicitBootstrap(result: CloudSyncOperationResult): CloudSyncOperationResult {
    if (!result.ok) { return result; }
    if (!this.bootstrapCompleted && this.hooks && this.hooks.markCloudBootstrapCompleted &&
      !this.hooks.markCloudBootstrapCompleted()) {
      this.startupState = 'pending';
      return {
        ok: false, source: result.source, tables: result.tables.slice(),
        failedTables: result.tables.slice(), rollbackFailed: false, failureKind: 'unknown'
      };
    }
    this.bootstrapCompleted = true;
    if (!this.persistBootstrapCompletion()) {
      this.startupState = 'pending';
      return {
        ok: false, source: result.source, tables: result.tables.slice(),
        failedTables: result.tables.slice(), rollbackFailed: false, failureKind: 'unknown'
      };
    }
    this.startupState = 'ready';
    if (this.hooks && this.hooks.setStartupSyncPending) {
      try { this.hooks.setStartupSyncPending(false); } catch (_e) { /* best effort */ }
    }
    this.flushDeferredAutomaticPushes();
    return result;
  }

  requestForegroundPull(): Promise<CloudSyncOperationResult> {
    if (this.startupPull) { return this.startupPull; }
    if (this.startupState !== 'ready') { return this.requestStartupPull(); }
    return this.requestCloudFirst('foreground').then((result: CloudSyncOperationResult): Promise<CloudSyncOperationResult> =>
      this.requestVncCloudFirst('foreground', result));
  }

  requestCloudEventPull(): Promise<CloudSyncOperationResult> {
    if (this.startupPull) { return this.startupPull; }
    if (this.startupState !== 'ready') { return this.requestStartupPull(); }
    return this.requestCloudFirst('cloudEvent').then((result: CloudSyncOperationResult): Promise<CloudSyncOperationResult> =>
      this.requestVncCloudFirst('cloudEvent', result));
  }

  requestManualUpload(): Promise<CloudSyncOperationResult> {
    const request: CloudSyncRequest = this.makeRequest('manualUpload', 'nativeFirst');
    if (!this.transfersEnabled || !this.automaticUploadAllowed()) {
      return Promise.resolve(this.rejectedResult(request, 'cloud_service'));
    }
    const includeVnc: boolean = this.vncPhysicalTableSelected();
    const versions: Record<string, number> = {};
    for (let i = 0; i < request.tables.length; i++) {
      versions[request.tables[i]] = this.automaticMutationVersions[request.tables[i]] || 0;
    }
    const journalRevisions: Record<string, number> = this.captureJournalRevisions(request.tables);
    return this.enqueue(request).then((result: CloudSyncOperationResult): Promise<CloudSyncOperationResult> => {
      if (!result.ok) { return Promise.resolve(result); }
      for (let i = 0; i < request.tables.length; i++) {
        const table: string = request.tables[i];
        this.clearAutomaticSyncBlock(table);
        this.acknowledgeJournal(table, journalRevisions[table] || 0);
        const currentJournalRevision: number = this.captureJournalRevisions([table])[table] || 0;
        if ((this.automaticMutationVersions[table] || 0) === versions[table] && currentJournalRevision <= 0) {
          this.clearDirtyTable(table);
        }
      }
      if (this.hooks && this.hooks.hasRestoredNotUploaded && this.hooks.hasRestoredNotUploaded() &&
        this.hooks.clearRestoredNotUploaded && !this.hooks.clearRestoredNotUploaded()) {
        hilog.warn(DOMAIN, TAG, 'manual upload completed but restored-state marker could not be cleared');
      }
      // The ordinary selector may opt the physical VNC table in, but the
      // VNC request still has to pass through its independent logical scopes.
      // Run it after the ordinary queue item so this explicit operation stays
      // serialized without ever uploading the whole physical table blindly.
      if (includeVnc) {
        return this.requestVncManualUpload().then((vncResult: CloudSyncOperationResult): CloudSyncOperationResult => {
          return vncResult.ok ? this.completeExplicitBootstrap(result) : vncResult;
        });
      }
      return Promise.resolve(this.completeExplicitBootstrap(result));
    });
  }

  requestManualDownload(): Promise<CloudSyncOperationResult> {
    const request: CloudSyncRequest = this.makeRequest('manualDownload', 'cloudFirst');
    if (!this.transfersEnabled) {
      return Promise.resolve(this.rejectedResult(request, 'cloud_service'));
    }
    const includeVnc: boolean = this.vncPhysicalTableSelected();
    const versions: Record<string, number> = {};
    for (let i = 0; i < request.tables.length; i++) {
      versions[request.tables[i]] = this.automaticMutationVersions[request.tables[i]] || 0;
    }
    return this.enqueue(request).then((result: CloudSyncOperationResult): Promise<CloudSyncOperationResult> => {
      if (!result.ok) { return Promise.resolve(result); }
      for (let i = 0; i < request.tables.length; i++) {
        const table: string = request.tables[i];
        this.clearAutomaticSyncBlock(table);
        if ((this.automaticMutationVersions[table] || 0) === versions[table]) { this.clearDirtyTable(table); }
      }
      if (includeVnc) {
        return this.requestVncManualDownload().then((vncResult: CloudSyncOperationResult): CloudSyncOperationResult => {
          return vncResult.ok ? this.completeExplicitBootstrap(result) : vncResult;
        });
      }
      return Promise.resolve(this.completeExplicitBootstrap(result));
    });
  }

  /** VNC manual operations use the same serialized transfer queue but never
   * inherit the ordinary RDP/RustDesk/SSH selection. */
  requestVncManualUpload(): Promise<CloudSyncOperationResult> {
    const tables: string[] = this.vncUploadTables();
    if (tables.length === 0) { return Promise.resolve(this.skippedResult('manualUpload')); }
    const request: CloudSyncRequest = {
      source: 'manualUpload', direction: 'nativeFirst', tables
    };
    if (!this.transfersEnabled || !this.automaticUploadAllowed()) {
      return Promise.resolve(this.rejectedResult(request, 'cloud_service'));
    }
    const journalRevisions: Record<string, number> = this.captureJournalRevisions(tables);
    return this.enqueue(request).then((result: CloudSyncOperationResult): CloudSyncOperationResult => {
      if (!result.ok) { return result; }
      for (let i = 0; i < tables.length; i++) {
        this.clearAutomaticSyncBlock(tables[i]);
        this.acknowledgeJournal(tables[i], journalRevisions[tables[i]] || 0);
        this.clearDirtyTable(tables[i]);
      }
      return this.completeExplicitBootstrap(result);
    });
  }

  requestVncManualDownload(): Promise<CloudSyncOperationResult> {
    const tables: string[] = this.vncSyncTables();
    if (tables.length === 0) { return Promise.resolve(this.skippedResult('manualDownload')); }
    const request: CloudSyncRequest = {
      source: 'manualDownload', direction: 'cloudFirst', tables
    };
    if (!this.transfersEnabled) {
      return Promise.resolve(this.rejectedResult(request, 'cloud_service'));
    }
    return this.enqueue(request).then((result: CloudSyncOperationResult): CloudSyncOperationResult =>
      this.completeExplicitBootstrap(result));
  }

  requestVncAutomaticPush(recordType: VncRecordType): Promise<CloudSyncOperationResult> {
    if (this.restorePending || this.restoreUploadBlocked()) {
      return Promise.resolve(this.skippedResult('automaticPush'));
    }
    const tables: string[] = this.vncUploadTables();
    if (tables.length === 0) { return Promise.resolve(this.skippedResult('automaticPush')); }
    const version: number = (this.automaticMutationVersions[VNC_CLOUD_TABLE] || 0) + 1;
    this.automaticMutationVersions[VNC_CLOUD_TABLE] = version;
    this.markDirtyTable(VNC_CLOUD_TABLE);
    if (!this.transfersEnabled || !this.automaticUploadAllowed()) {
      return Promise.resolve(this.skippedResult('automaticPush'));
    }
    if (shouldDeferAutomaticPushDuringBootstrap(this.startupState)) {
      if (this.deferredAutomaticTables.indexOf(VNC_CLOUD_TABLE) < 0) {
        this.deferredAutomaticTables.push(VNC_CLOUD_TABLE);
      }
      return Promise.resolve(this.skippedResult('automaticPush'));
    }
    if (this.isAutomaticSyncBlocked(VNC_CLOUD_TABLE)) {
      return Promise.resolve(this.skippedResult('automaticPush'));
    }
    const journalRevision: number =
      this.captureJournalRevisions([VNC_CLOUD_TABLE])[VNC_CLOUD_TABLE] || 0;
    return this.enqueueAutomaticRequest({
      source: 'automaticPush', direction: 'nativeFirst', tables
    }, VNC_CLOUD_TABLE, version, journalRevision);
  }

  requestVncTableAutomaticPush(forcePhysical: boolean = false): Promise<CloudSyncOperationResult> {
    if (this.restorePending || this.restoreUploadBlocked()) {
      return Promise.resolve(this.skippedResult('automaticPush'));
    }
    // A crypto reset may intentionally bypass the logical record-type
    // selection so the reset generation can invalidate every VNC row, but it
    // still must honor the ordinary physical-table selector. The selector is
    // the user's final opt-out from any `vncrecord` transfer.
    if (forcePhysical && !this.vncPhysicalTableSelected()) {
      return Promise.resolve(this.skippedResult('automaticPush'));
    }
    const tables: string[] = forcePhysical ? [VNC_CLOUD_TABLE] : this.vncUploadTables();
    if (tables.length === 0) { return Promise.resolve(this.skippedResult('automaticPush')); }
    const version: number = (this.automaticMutationVersions[VNC_CLOUD_TABLE] || 0) + 1;
    this.automaticMutationVersions[VNC_CLOUD_TABLE] = version;
    this.markDirtyTable(VNC_CLOUD_TABLE);
    if (!this.transfersEnabled || !this.automaticUploadAllowed()) {
      return Promise.resolve(this.skippedResult('automaticPush'));
    }
    if (shouldDeferAutomaticPushDuringBootstrap(this.startupState)) {
      if (this.deferredAutomaticTables.indexOf(VNC_CLOUD_TABLE) < 0) {
        this.deferredAutomaticTables.push(VNC_CLOUD_TABLE);
      }
      return Promise.resolve(this.skippedResult('automaticPush'));
    }
    const journalRevision: number =
      this.captureJournalRevisions([VNC_CLOUD_TABLE])[VNC_CLOUD_TABLE] || 0;
    return this.enqueueAutomaticRequest({
      source: 'automaticPush', direction: 'nativeFirst', tables
    }, VNC_CLOUD_TABLE, version, journalRevision);
  }

  /** Reconcile local VNC projection without fabricating a cloud tombstone. */
  requestVncSelectionReconcile(): Promise<CloudSyncOperationResult> {
    if (this.restorePending || this.restoreUploadBlocked()) {
      return Promise.resolve(this.skippedResult('automaticPush'));
    }
    const tables: string[] = this.vncUploadTables();
    if (tables.length === 0) { return Promise.resolve(this.skippedResult('automaticPush')); }
    const version: number = (this.automaticMutationVersions[VNC_CLOUD_TABLE] || 0) + 1;
    this.automaticMutationVersions[VNC_CLOUD_TABLE] = version;
    this.markDirtyTable(VNC_CLOUD_TABLE);
    if (!this.transfersEnabled || !this.automaticUploadAllowed()) {
      return Promise.resolve(this.skippedResult('automaticPush'));
    }
    if (shouldDeferAutomaticPushDuringBootstrap(this.startupState)) {
      if (this.deferredAutomaticTables.indexOf(VNC_CLOUD_TABLE) < 0) {
        this.deferredAutomaticTables.push(VNC_CLOUD_TABLE);
      }
      return Promise.resolve(this.skippedResult('automaticPush'));
    }
    const journalRevision: number =
      this.captureJournalRevisions([VNC_CLOUD_TABLE])[VNC_CLOUD_TABLE] || 0;
    return this.enqueueAutomaticRequest({ source: 'automaticPush', direction: 'nativeFirst',
      tables }, VNC_CLOUD_TABLE, version, journalRevision);
  }

  requestAutomaticPush(table: string): Promise<CloudSyncOperationResult> {
    if (table === VNC_CLOUD_TABLE) { return this.requestVncTableAutomaticPush(); }
    const selected: string[] = this.selectedTables();
    if (selected.indexOf(table) < 0 || this.restorePending || this.restoreUploadBlocked()) {
      return Promise.resolve(this.skippedResult('automaticPush'));
    }
    const version: number = (this.automaticMutationVersions[table] || 0) + 1;
    this.automaticMutationVersions[table] = version;
    this.markDirtyTable(table);
    if (!this.transfersEnabled || !this.automaticUploadAllowed()) {
      return Promise.resolve(this.skippedResult('automaticPush'));
    }
    if (shouldDeferAutomaticPushDuringBootstrap(this.startupState)) {
      if (this.deferredAutomaticTables.indexOf(table) < 0) {
        this.deferredAutomaticTables.push(table);
      }
      return Promise.resolve(this.skippedResult('automaticPush'));
    }
    if (this.isAutomaticSyncBlocked(table)) {
      hilog.warn(DOMAIN, TAG, 'automatic push blocked after cloud conflict table=' + table);
      return Promise.resolve(this.skippedResult('automaticPush'));
    }
    const activeSession = ActiveRemoteSessionRegistry.getInstance().getActive();
    if (activeSession !== null && activeSession.protocolConnected) {
      if (this.deferredAutomaticTables.indexOf(table) < 0) {
        this.deferredAutomaticTables.push(table);
      }
      hilog.info(DOMAIN, TAG, 'defer automatic push during remote session table=' + table);
      return Promise.resolve(this.skippedResult('automaticPush'));
    }
    for (let i = 0; i < this.pendingAutomaticTables.length; i++) {
      if (coalesceAutomaticPush(this.pendingAutomaticTables[i], table)) {
        hilog.info(DOMAIN, TAG, 'coalesce latest mutation for table=' + table);
        return Promise.resolve(this.skippedResult('automaticPush'));
      }
    }
    // Sensitive selected tables always carry their cryptographic parameters first.
    // The snapshot is fixed now, so later selection changes cannot split this pair.
    const tables: string[] = selected.filter((candidate: string): boolean =>
      candidate === 'cryptoparams' || candidate === table
    );
    const journalRevision: number = this.captureJournalRevisions([table])[table] || 0;
    return this.enqueueAutomaticRequest({ source: 'automaticPush', direction: 'nativeFirst', tables },
      table, version, journalRevision);
  }

  /** Flushes mutations collected while audio/video had priority. */
  flushDeferredAutomaticPushes(): void {
    if (this.startupState !== 'ready') { return; }
    const activeSession = ActiveRemoteSessionRegistry.getInstance().getActive();
    if (activeSession !== null && activeSession.protocolConnected) { return; }
    const tables: string[] = this.deferredAutomaticTables.slice();
    this.deferredAutomaticTables = [];
    for (let i = 0; i < tables.length; i++) {
      this.requestAutomaticPush(tables[i]);
    }
  }

  private enqueueAutomaticRequest(request: CloudSyncRequest, retryKey: string,
    completedVersion: number = this.automaticMutationVersions[retryKey] || 1,
    coveredJournalRevision: number = this.captureJournalRevisions([retryKey])[retryKey] || 0): Promise<CloudSyncOperationResult> {
    for (let i = 0; i < this.pendingAutomaticTables.length; i++) {
      if (coalesceAutomaticPush(this.pendingAutomaticTables[i], retryKey)) {
        return Promise.resolve(this.skippedResult('automaticPush'));
      }
    }
    this.pendingAutomaticTables.push(retryKey);
    return this.enqueue(request).then((result: CloudSyncOperationResult): CloudSyncOperationResult => {
      const index: number = this.pendingAutomaticTables.indexOf(retryKey);
      if (index >= 0) { this.pendingAutomaticTables.splice(index, 1); }
      if (result.ok) {
        this.automaticRetryAttempts[retryKey] = 0;
        this.removeAutomaticRetry(retryKey);
        this.acknowledgeJournal(retryKey, coveredJournalRevision);
        const latestVersion: number = this.automaticMutationVersions[retryKey] || completedVersion;
        if (shouldReplayAutomaticPush(completedVersion, latestVersion)) {
          const tables: string[] = this.tablesForAutomaticRetry(retryKey);
          this.enqueueAutomaticRequest({ source: 'automaticPush', direction: 'nativeFirst', tables },
            retryKey, latestVersion, this.captureJournalRevisions([retryKey])[retryKey] || 0);
        } else {
          const currentJournalRevision: number = this.captureJournalRevisions([retryKey])[retryKey] || 0;
          if (currentJournalRevision <= 0) { this.clearDirtyTable(retryKey); }
        }
      } else {
        if (shouldBlockAutomaticRetry(result.failureKind)) {
          this.blockAutomaticSyncTable(retryKey);
          this.removeAutomaticRetry(retryKey);
          hilog.warn(DOMAIN, TAG, 'automatic retry blocked table=' + retryKey +
            ' failure=' + result.failureKind);
        } else {
          const attempt: number = (this.automaticRetryAttempts[retryKey] || 0) + 1;
          this.automaticRetryAttempts[retryKey] = attempt;
          this.persistAutomaticRetry(request, result.failedTables, attempt);
        }
      }
      return result;
    });
  }

  /** Queue a database restore without allowing a concurrent cloud operation. */
  runExclusiveRestore(work: () => Promise<boolean>): Promise<boolean> {
    if (this.restorePending || !this.acceptingRequests ||
      this.currentLease === null) { return Promise.resolve(false); }
    const lease: AccountSessionLease = cloneAccountSessionLease(this.currentLease);
    const epoch: number = this.bindingEpoch;
    const lifecycleBeforeRestore: CloudSyncDurableState | null =
      this.durableState === null ? null :
        cloneCloudSyncDurableState(this.durableState);
    if (this.durableState !== null) {
      const quarantined: CloudSyncDurableState =
        cloudSyncRestoreQuarantined(this.durableState);
      if (!this.persistDurableCandidate(quarantined)) {
        return Promise.resolve(false);
      }
    }
    this.restorePending = true;
    if (this.hooks) { this.hooks.setRestorePending(true); }
    const run = async (): Promise<boolean> => {
      if (!this.acceptingRequests || epoch !== this.bindingEpoch ||
        !accountSessionLeaseEquals(this.currentLease, lease)) {
        return false;
      }
      const restored: boolean = await work();
      if (epoch !== this.bindingEpoch ||
        !accountSessionLeaseEquals(this.currentLease, lease)) {
        return false;
      }
      if (restored) {
        if (!this.clearAllDirtyIntents()) { return false; }
      } else if (lifecycleBeforeRestore !== null) {
        if (this.durableState === null) { return false; }
        const released: CloudSyncDurableState = cloudSyncRestoreReleased(
          this.durableState, lifecycleBeforeRestore);
        if (!this.persistDurableCandidate(released)) { return false; }
      }
      return restored;
    };
    return new Promise<boolean>((resolve: (value: boolean) => void): void => {
      this.queueTail = this.queueTail.then(async (): Promise<void> => {
        try {
          resolve(await run());
        } catch (_e) {
          resolve(false);
        } finally {
          this.restorePending = false;
          if (this.hooks) { this.hooks.setRestorePending(false); }
        }
      }, async (): Promise<void> => {
        try {
          resolve(await run());
        } catch (_e) {
          resolve(false);
        } finally {
          this.restorePending = false;
          if (this.hooks) { this.hooks.setRestorePending(false); }
        }
      });
    });
  }

  pendingTableCount(): number {
    return this.pendingAutomaticTables.length;
  }

  private requestCloudFirst(source: CloudSyncSource): Promise<CloudSyncOperationResult> {
    if (!this.transfersEnabled) {
      return Promise.resolve(this.rejectedResult(
        this.makeRequest(source, 'cloudFirst'), 'cloud_service'));
    }
    if (source !== 'manualDownload' && this.restoreUploadBlocked()) {
      return Promise.resolve(this.skippedResult(source));
    }
    if (this.pendingPull) { return this.pendingPull; }
    const request: CloudSyncRequest = this.makeRequest(source, 'cloudFirst');
    this.pendingPull = this.enqueue(request).then((result: CloudSyncOperationResult): CloudSyncOperationResult => {
      this.pendingPull = null;
      return result;
    }, (): CloudSyncOperationResult => {
      this.pendingPull = null;
      return {
        ok: false, source, tables: request.tables, failedTables: request.tables.slice(),
        rollbackFailed: false, failureKind: 'unknown'
      };
    });
    return this.pendingPull;
  }

  private makeRequest(source: CloudSyncSource, direction: CloudSyncDirection): CloudSyncRequest {
    let tables: string[] = this.selectedTables();
    // A conflict-blocked table must not be pulled automatically either.  An
    // explicit manual upload/download is the only operation allowed to
    // resolve that table and clear its durable block.
    if (direction === 'cloudFirst' && source !== 'manualDownload') {
      tables = tables.filter((table: string): boolean => !this.isAutomaticSyncBlocked(table));
    }
    return { source, direction, tables };
  }

  private selectedTables(): string[] {
    // `vncrecord` is visible in the ordinary selector so users can opt the
    // physical table out globally. It must never be returned here because
    // this path has no VNC record-type/secret projection context.
    return snapshotCloudSyncTables(this.selection.selectedBusinessTables())
      .filter((table: string): boolean => table !== VNC_CLOUD_TABLE);
  }

  private vncPhysicalTableSelected(): boolean {
    return this.selection.selectedBusinessTables().indexOf(VNC_CLOUD_TABLE) >= 0;
  }

  private vncSyncTables(): string[] {
    if (!this.vncPhysicalTableSelected() || !this.vncSelection.hasSelection()) { return []; }
    const result: string[] = [];
    if (this.vncSelection.needsCrypto(DataCrypto.getInstance().isSetupComplete())) {
      result.push('cryptoparams');
    }
    result.push(VNC_CLOUD_TABLE);
    return result;
  }

  /**
   * The regular VNC selection controls visible data. With no selected scope,
   * no VNC cloud transfer is scheduled. A locked device keeps encrypted
   * secret rows opaque; it never replaces them with an empty local projection.
   */
  private vncUploadTables(): string[] {
    return this.vncSyncTables();
  }

  private tablesForAutomaticRetry(retryKey: string): string[] {
    if (retryKey === VNC_CLOUD_TABLE) { return this.vncUploadTables(); }
    const selected: string[] = this.selectedTables();
    return selected.filter((candidate: string): boolean =>
      candidate === 'cryptoparams' || candidate === retryKey);
  }

  private requestVncStartupPush(): Promise<CloudSyncOperationResult> {
    if (this.restoreUploadBlocked() || this.isAutomaticSyncBlocked(VNC_CLOUD_TABLE)) {
      return Promise.resolve(this.skippedResult('startup'));
    }
    const tables: string[] = this.vncUploadTables();
    if (tables.length === 0) { return Promise.resolve(this.skippedResult('startup')); }
    const version: number = this.automaticMutationVersions[VNC_CLOUD_TABLE] || 1;
    const journalRevision: number =
      this.captureJournalRevisions([VNC_CLOUD_TABLE])[VNC_CLOUD_TABLE] || 0;
    return this.enqueueAutomaticRequest({ source: 'automaticPush', direction: 'nativeFirst',
      tables }, VNC_CLOUD_TABLE, version, journalRevision);
  }

  private requestVncCloudFirst(source: 'startup' | 'foreground' | 'cloudEvent',
    previous: CloudSyncOperationResult): Promise<CloudSyncOperationResult> {
    if (!previous.ok) { return Promise.resolve(previous); }
    const tables: string[] = this.vncSyncTables();
    if (tables.length === 0) { return Promise.resolve(previous); }
    return this.enqueue({ source, direction: 'cloudFirst', tables });
  }

  private skippedResult(source: CloudSyncSource): CloudSyncOperationResult {
    return { ok: true, source, tables: [], failedTables: [], rollbackFailed: false, failureKind: 'none' };
  }

  private enqueue(request: CloudSyncRequest): Promise<CloudSyncOperationResult> {
    if (!this.acceptingRequests || this.currentLease === null ||
      !this.transfersEnabled) {
      return Promise.resolve(this.rejectedResult(request));
    }
    const lease: AccountSessionLease = cloneAccountSessionLease(this.currentLease);
    const epoch: number = this.bindingEpoch;
    return new Promise<CloudSyncOperationResult>((resolve: (result: CloudSyncOperationResult) => void): void => {
      const run = async (): Promise<void> => {
        if (!this.acceptingRequests || epoch !== this.bindingEpoch ||
          !accountSessionLeaseEquals(this.currentLease, lease)) {
          resolve(this.rejectedResult(request));
          return;
        }
        if (!this.beginLifecycleOperation(request)) {
          resolve(this.rejectedResult(request));
          return;
        }
        const result: CloudSyncOperationResult = await this.execute(request);
        if (epoch !== this.bindingEpoch ||
          !accountSessionLeaseEquals(this.currentLease, lease)) {
          resolve(this.rejectedResult(request));
          return;
        }
        if (!this.finishLifecycleOperation(result)) {
          resolve(this.rejectedResult(request));
          return;
        }
        resolve(result);
      };
      this.queueTail = this.queueTail.then(run, run);
    });
  }

  private rejectedResult(request: CloudSyncRequest,
    failureKind: CloudSyncFailureKind = 'unknown'): CloudSyncOperationResult {
    return {
      ok: false,
      source: request.source,
      tables: request.tables.slice(),
      failedTables: request.tables.slice(),
      rollbackFailed: false,
      failureKind
    };
  }

  private async execute(request: CloudSyncRequest): Promise<CloudSyncOperationResult> {
    return await executeCloudSyncRequest(
      request,
      this.executor,
      this.hooks,
      (tables: string[]): void => {
        if (this.onCloudFirstApplied) { this.onCloudFirstApplied(tables); }
      }
    );
  }

  private restoreRetryRecord(): void {
    if (this.durableState === null || this.retryTimer >= 0) { return; }
    const records: CloudSyncRetryRecord[] = this.durableState.retryRecords;
    for (let i = 0; i < records.length; i++) {
      if (!isAutomaticRetryRecord(records[i])) { continue; }
      this.retryRecords = upsertAutomaticRetryRecord(this.retryRecords, records[i]);
      this.automaticRetryAttempts[automaticRetryKey(records[i])] = records[i].attempt;
    }
    this.scheduleRetryTimer();
  }

  private restoreDirtyTables(): void {
    if (this.durableState === null) { return; }
    const values: string[] = this.durableState.dirtyTables;
    for (let i = 0; i < values.length; i++) {
      if (this.dirtyAutomaticTables.indexOf(values[i]) < 0) {
        this.dirtyAutomaticTables.push(values[i]);
        this.automaticMutationVersions[values[i]] = 1;
      }
    }
  }

  private restoreConflictTables(): void {
    if (this.durableState === null) { return; }
    const values: string[] = this.durableState.conflictTables;
    for (let i = 0; i < values.length; i++) {
      if (values[i] !== '' && this.blockedAutomaticTables.indexOf(values[i]) < 0) {
        this.blockedAutomaticTables.push(values[i]);
      }
    }
  }

  private writeConflictTables(): void {
    if (!this.syncDurableIntents()) {
      hilog.error(DOMAIN, TAG, 'write conflict tables failed');
    }
  }

  private isAutomaticSyncBlocked(table: string): boolean {
    return this.blockedAutomaticTables.indexOf(table) >= 0;
  }

  private blockAutomaticSyncTable(table: string): void {
    if (table === '' || this.isAutomaticSyncBlocked(table)) { return; }
    this.blockedAutomaticTables.push(table);
    this.writeConflictTables();
  }

  private clearAutomaticSyncBlock(table: string): void {
    const index: number = this.blockedAutomaticTables.indexOf(table);
    if (index < 0) { return; }
    this.blockedAutomaticTables.splice(index, 1);
    this.writeConflictTables();
  }

  /** Journal rows survive a process death even if Preferences could not flush. */
  private restoreMutationJournal(): void {
    if (!this.hooks || !this.hooks.pendingMutationTableRevisions) { return; }
    try {
      const revisions: Record<string, number> = this.hooks.pendingMutationTableRevisions();
      const tables: string[] = Object.keys(revisions);
      for (let i = 0; i < tables.length; i++) {
        const table: string = tables[i];
        const revision: number = revisions[table];
        if (!Number.isFinite(revision) || revision <= 0) { continue; }
        this.journalMutationRevisions[table] = Math.max(this.journalMutationRevisions[table] || 0, revision);
        if (this.dirtyAutomaticTables.indexOf(table) < 0) { this.dirtyAutomaticTables.push(table); }
        this.automaticMutationVersions[table] = Math.max(this.automaticMutationVersions[table] || 0, 1);
      }
      this.writeDirtyTables();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'restore mutation journal ignored: ' + JSON.stringify(err));
    }
  }

  private captureJournalRevisions(tables: string[]): Record<string, number> {
    const result: Record<string, number> = {};
    if (!this.hooks || !this.hooks.pendingMutationTableRevisions) { return result; }
    try {
      const current: Record<string, number> = this.hooks.pendingMutationTableRevisions();
      for (let i = 0; i < tables.length; i++) {
        const table: string = tables[i];
        const revision: number = current[table] || 0;
        if (revision > 0) {
          this.journalMutationRevisions[table] = revision;
          result[table] = revision;
        } else {
          this.journalMutationRevisions[table] = 0;
        }
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'read mutation journal failed: ' + JSON.stringify(err));
    }
    return result;
  }

  private acknowledgeJournal(table: string, revision: number): void {
    if (revision <= 0 || !this.hooks || !this.hooks.acknowledgeMutationJournal) { return; }
    try {
      if (!this.hooks.acknowledgeMutationJournal(table, revision)) {
        hilog.warn(DOMAIN, TAG, 'journal acknowledgement deferred table=' + table);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'journal acknowledgement failed table=' + table + ' err=' + JSON.stringify(err));
    }
  }

  private restoreUploadBlocked(): boolean {
    if (!this.hooks || !this.hooks.hasRestoredNotUploaded) { return false; }
    try { return this.hooks.hasRestoredNotUploaded(); } catch (_e) { return false; }
  }

  private clearAllDirtyIntents(): boolean {
    this.dirtyAutomaticTables = [];
    this.automaticMutationVersions = {};
    this.journalMutationRevisions = {};
    this.blockedAutomaticTables = [];
    this.deferredAutomaticTables = [];
    this.retryRecords = [];
    this.automaticRetryAttempts = {};
    const persisted: boolean = this.syncDurableIntents();
    this.scheduleRetryTimer();
    return persisted;
  }

  private writeDirtyTables(): void {
    if (!this.syncDurableIntents()) {
      hilog.error(DOMAIN, TAG, 'write dirty tables failed');
    }
  }

  private markDirtyTable(table: string): void {
    if (this.dirtyAutomaticTables.indexOf(table) < 0) {
      this.dirtyAutomaticTables.push(table);
      this.writeDirtyTables();
    }
  }

  private clearDirtyTable(table: string): void {
    const index: number = this.dirtyAutomaticTables.indexOf(table);
    if (index >= 0) {
      this.dirtyAutomaticTables.splice(index, 1);
      this.writeDirtyTables();
    }
  }

  /** Drop a pre-bootstrap automatic intent after the authoritative pull won. */
  private clearAutomaticIntent(table: string): void {
    this.clearDirtyTable(table);
    this.automaticMutationVersions[table] = 0;
    this.journalMutationRevisions[table] = 0;
    this.automaticRetryAttempts[table] = 0;
    const remaining: CloudSyncRetryRecord[] = [];
    for (let i = 0; i < this.retryRecords.length; i++) {
      if (automaticRetryKey(this.retryRecords[i]) !== table) { remaining.push(this.retryRecords[i]); }
    }
    this.retryRecords = remaining;
    this.writeRetryRecords();
    const deferredIndex: number = this.deferredAutomaticTables.indexOf(table);
    if (deferredIndex >= 0) { this.deferredAutomaticTables.splice(deferredIndex, 1); }
  }

  private persistAutomaticRetry(request: CloudSyncRequest, failedTables: string[], attempt: number): void {
    const retryKey: string = automaticRetryKey({
      source: request.source, direction: request.direction, tables: request.tables,
      failedTables, attempt, nextRetryAt: 0
    });
    if (failedTables.length === 0 || attempt > CLOUD_SYNC_MAX_RETRY_ATTEMPTS) {
      this.removeAutomaticRetry(retryKey);
      return;
    }
    const delay: number = nextCloudSyncRetryDelayMs(attempt);
    if (delay < 0) { return; }
    const record: CloudSyncRetryRecord = {
      source: request.source,
      direction: request.direction,
      tables: request.tables.slice(),
      failedTables: failedTables.slice(),
      attempt,
      nextRetryAt: Date.now() + delay
    };
    this.retryRecords = upsertAutomaticRetryRecord(this.retryRecords, record);
    this.writeRetryRecords();
    this.scheduleRetryTimer();
  }

  private removeAutomaticRetry(retryKey: string): void {
    const remaining: CloudSyncRetryRecord[] = [];
    for (let i = 0; i < this.retryRecords.length; i++) {
      if (automaticRetryKey(this.retryRecords[i]) !== retryKey) { remaining.push(this.retryRecords[i]); }
    }
    this.retryRecords = remaining;
    this.writeRetryRecords();
    this.scheduleRetryTimer();
  }

  private writeRetryRecords(): void {
    if (!this.syncDurableIntents()) {
      hilog.error(DOMAIN, TAG, 'persist retry failed');
    }
  }

  private scheduleRetryTimer(): void {
    if (this.retryTimer >= 0) { clearTimeout(this.retryTimer); this.retryTimer = -1; }
    if (this.retryRecords.length === 0 || !this.transfersEnabled ||
      !this.automaticUploadAllowed()) { return; }
    let earliest: CloudSyncRetryRecord = this.retryRecords[0];
    for (let i = 1; i < this.retryRecords.length; i++) {
      if (this.retryRecords[i].nextRetryAt < earliest.nextRetryAt) { earliest = this.retryRecords[i]; }
    }
    const delay: number = Math.max(0, earliest.nextRetryAt - Date.now());
    const timerLease: AccountSessionLease | null = this.currentLease === null
      ? null : cloneAccountSessionLease(this.currentLease);
    const timerEpoch: number = this.bindingEpoch;
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      if (!this.acceptingRequests || timerLease === null ||
        timerEpoch !== this.bindingEpoch ||
        !accountSessionLeaseEquals(this.currentLease, timerLease)) {
        return;
      }
      const now: number = Date.now();
      const due: CloudSyncRetryRecord[] = [];
      const remaining: CloudSyncRetryRecord[] = [];
      for (let i = 0; i < this.retryRecords.length; i++) {
        if (this.retryRecords[i].nextRetryAt <= now) { due.push(this.retryRecords[i]); }
        else { remaining.push(this.retryRecords[i]); }
      }
      this.retryRecords = remaining;
      this.writeRetryRecords();
      this.scheduleRetryTimer();
      for (let i = 0; i < due.length; i++) {
        const retry: CloudSyncRetryRecord = due[i];
        const retryKey: string = automaticRetryKey(retry);
        if (this.isAutomaticSyncBlocked(retryKey)) {
          this.automaticRetryAttempts[retryKey] = 0;
          continue;
        }
        const tables: string[] = retryKey === VNC_CLOUD_TABLE
          ? retryVncTablesStillSelected(retry.tables, this.vncUploadTables())
          : retryTablesStillSelected(retry.tables, this.selectedTables());
        if (tables.length === 0) {
          this.automaticRetryAttempts[retryKey] = 0;
          continue;
        }
        this.enqueueAutomaticRequest(
          { source: 'automaticPush', direction: retry.direction, tables },
          retryKey
        );
      }
    }, delay) as number;
  }

  private automaticUploadAllowed(): boolean {
    return this.durableState !== null &&
      cloudSyncAutomaticUploadAllowed(this.durableState);
  }

  private beginLifecycleOperation(request: CloudSyncRequest): boolean {
    if (this.durableState === null) { return false; }
    if (request.direction === 'nativeFirst' && !this.automaticUploadAllowed()) {
      return false;
    }
    if (request.direction === 'cloudFirst' &&
      !cloudSyncDownloadAllowed(this.durableState)) {
      return false;
    }
    const next: CloudSyncDurableState = cloudSyncOperationStarted(
      this.durableState, request.source, request.direction, request.tables);
    return this.persistDurableCandidate(next);
  }

  private finishLifecycleOperation(result: CloudSyncOperationResult): boolean {
    if (this.durableState === null) { return false; }
    const next: CloudSyncDurableState = cloudSyncOperationFinished(
      this.durableState,
      result.ok,
      result.failedTables,
      result.rollbackFailed,
      result.failureKind,
      this.bootstrapCompleted);
    return this.persistDurableCandidate(next);
  }

  private persistBootstrapCompletion(): boolean {
    if (this.durableState === null) { return false; }
    const next: CloudSyncDurableState =
      cloudSyncBootstrapCompleted(this.durableState);
    return this.persistDurableCandidate(next);
  }

  private syncDurableIntents(): boolean {
    if (this.durableState === null) { return false; }
    const next: CloudSyncDurableState = cloudSyncDurableStateWithIntents(
      this.durableState,
      this.dirtyAutomaticTables,
      this.blockedAutomaticTables,
      this.retryRecords
    );
    return this.persistDurableCandidate(next);
  }

  private persistDurableCandidate(state: CloudSyncDurableState): boolean {
    if (!this.hooks ||
      !this.hooks.persistDurableState) {
      return false;
    }
    try {
      if (!this.hooks.persistDurableState(state)) { return false; }
      this.durableState = state;
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG,
        'persist cloud lifecycle state failed: ' + JSON.stringify(err));
      return false;
    }
  }

  private resetFailedBinding(): void {
    this.bindingEpoch++;
    this.acceptingRequests = false;
    this.executor = null;
    this.onCloudFirstApplied = null;
    this.hooks = null;
    this.currentLease = null;
    this.currentBinding = unboundCloudAccountBinding();
    this.transfersEnabled = false;
    this.durableState = null;
    this.pendingPull = null;
    this.startupPull = null;
    this.pendingAutomaticTables = [];
    this.deferredAutomaticTables = [];
    this.retryRecords = [];
    this.dirtyAutomaticTables = [];
    this.blockedAutomaticTables = [];
    this.automaticRetryAttempts = {};
    this.automaticMutationVersions = {};
    this.journalMutationRevisions = {};
    this.restorePending = false;
  }
}
