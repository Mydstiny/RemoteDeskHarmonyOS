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
  cloudSyncExternalRecoveryRequired,
  cloudSyncIndeterminateSettled,
  cloudSyncManualDownloadAllowed,
  cloudSyncManualUploadAllowed,
  cloudSyncOperationFinished,
  cloudSyncOperationStarted,
  cloudSyncQuiesced,
  cloudSyncQuiescing,
  cloudSyncRestoreQuarantined,
  cloudSyncRestoreResolutionAttemptFinished,
  cloudSyncRestoreResolutionCompleted,
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
  cloudFirstCompatibleTablesAfterOptionalFailure,
  coalesceAutomaticPush,
  exclusiveCloudOperationLeaseValid,
  exclusiveVncSelectionAdmissionAllowed,
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
import { recordDiagnosticEvent } from './DiagnosticCaptureRuntime';

const DOMAIN = 0x0001;
const TAG = 'CloudSyncCoordinator';

function diagnosticCloudSourceCode(source: CloudSyncSource): number {
  switch (source) {
    case 'startup': return 1;
    case 'foreground': return 2;
    case 'cloudEvent': return 3;
    case 'automaticPush': return 4;
    case 'manualUpload': return 5;
    case 'manualDownload': return 6;
    case 'selectionReenable': return 7;
    case 'localRestore': return 8;
  }
}

function diagnosticCloudDirectionCode(direction: CloudSyncDirection): number {
  return direction === 'nativeFirst' ? 1 : 2;
}

function diagnosticCloudFailureCode(failure: CloudSyncFailureKind): number {
  switch (failure) {
    case 'none': return 0;
    case 'version_conflict': return 1;
    case 'empty_snapshot': return 2;
    case 'tombstone_cleanup': return 3;
    case 'unsafe_payload': return 4;
    case 'cloud_service': return 5;
    case 'network': return 6;
    case 'indeterminate': return 7;
    case 'restore_pending': return 8;
    case 'no_selection': return 9;
    case 'unknown': return 10;
    case 'local_finalize': return 11;
  }
}

function diagnosticCloudRequestCode(request: CloudSyncRequest): number {
  return diagnosticCloudSourceCode(request.source) * 10 +
    diagnosticCloudDirectionCode(request.direction);
}

export interface CloudSyncOperationResult {
  ok: boolean;
  source: CloudSyncSource;
  tables: string[];
  failedTables: string[];
  rollbackFailed: boolean;
  failureKind: CloudSyncFailureKind;
}

export type ExclusiveSelectionCloudFirst =
  (table: string) => Promise<CloudSyncOperationResult>;

export type ExclusiveVncSelectionWork =
  (
    lease: AccountSessionLease,
    cloudFirst: ExclusiveSelectionCloudFirst
  ) => Promise<void>;

/** A restored local snapshot is quarantined until the user chooses a direction. */
export function restoreQuarantinedStartupResult(
  tables: string[]
): CloudSyncOperationResult {
  return {
    ok: false,
    source: 'startup',
    tables: [],
    failedTables: snapshotCloudSyncTables(tables),
    rollbackFailed: false,
    failureKind: 'restore_pending'
  };
}

function mergeCloudSyncTableLists(
  first: string[], second: string[]
): string[] {
  const merged: string[] = [];
  const values: string[] = first.concat(second);
  for (let i = 0; i < values.length; i++) {
    if (values[i] !== '' && merged.indexOf(values[i]) < 0) {
      merged.push(values[i]);
    }
  }
  return merged;
}

function combineCloudSyncOperationResults(
  source: CloudSyncSource,
  first: CloudSyncOperationResult,
  second: CloudSyncOperationResult
): CloudSyncOperationResult {
  const failedTables: string[] = mergeCloudSyncTableLists(
    first.failedTables, second.failedTables);
  return {
    ok: first.ok && second.ok && failedTables.length === 0 &&
      !first.rollbackFailed && !second.rollbackFailed,
    source,
    tables: mergeCloudSyncTableLists(first.tables, second.tables),
    failedTables,
    rollbackFailed: first.rollbackFailed || second.rollbackFailed,
    failureKind: first.failureKind !== 'none'
      ? first.failureKind : second.failureKind
  };
}

export type CloudSyncTableExecutor = (table: string, direction: CloudSyncDirection, label: string) => Promise<boolean>;

/**
 * Narrow production dependency used when the coordinator freezes one
 * request. Tests can inject an isolated selection without mutating the
 * process singleton; production still reads CloudSyncSelectionStore.
 */
export interface CloudSyncSelectionSource {
  selectedBusinessTables(): string[];
}

export interface VncCloudSyncSelectionSource {
  hasSelection(): boolean;
  needsCrypto(cryptoConfigured: boolean): boolean;
}

export type CloudSyncRetryTimerTask = () => void;

/**
 * Retry scheduling is an I/O boundary, not retry policy. Keeping it behind a
 * clock lets implementation tests fire the real retry callback while another
 * coordinator queue item owns the account lease.
 */
export interface CloudSyncRetryClock {
  now(): number;
  schedule(
    task: CloudSyncRetryTimerTask,
    delayMs: number
  ): number;
  cancel(timerId: number): void;
}

class SystemCloudSyncRetryClock implements CloudSyncRetryClock {
  now(): number {
    return Date.now();
  }

  schedule(
    task: CloudSyncRetryTimerTask,
    delayMs: number
  ): number {
    return setTimeout(task, delayMs) as number;
  }

  cancel(timerId: number): void {
    clearTimeout(timerId);
  }
}

export interface CloudSyncCoordinatorHooks {
  beginManualDownload: () => boolean;
  rollbackManualDownload: () => Promise<boolean>;
  /** Return false to roll the just-applied cloud download back to its snapshot. */
  completeManualDownload: (tables: string[]) => boolean | void;
  /** Complete only successful tables without clearing unrelated restore quarantine. */
  completeManualDownloadPartial?: (
    tables: string[], failedTables: string[]
  ) => Promise<boolean>;
  beginSelectionReenableDownload?: () => boolean;
  rollbackSelectionReenableDownload?: () => Promise<boolean>;
  completeSelectionReenableDownload?: (tables: string[]) => boolean;
  beginStartupDownload?: () => boolean;
  rollbackStartupDownload?: () => Promise<boolean>;
  completeStartupDownload?: (
    dirtyTables: string[], completedTables: string[]
  ) => boolean;
  /**
   * Commit completed legacy tables while restoring failed optional-table
   * state from the same before-image. Failed optional barriers stay pending.
   */
  completeStartupDownloadPartial?: (
    dirtyTables: string[], completedTables: string[],
    failedTables: string[]
  ) => Promise<boolean>;
  setRestorePending: (pending: boolean) => void;
  pendingMutationTableRevisions?: () => Record<string, number>;
  acknowledgeMutationJournal?: (table: string, coveredRevision: number) => boolean;
  failureKindForTable?: (table: string) => CloudSyncFailureKind;
  hasRestoredNotUploaded?: () => boolean;
  /** Exact restored-table markers; null means the metadata boundary is unreadable. */
  pendingRestoreTables?: () => string[] | null;
  clearRestoredNotUploaded?: () => boolean;
  /** Atomically clears restore markers and persists the supplied ready state. */
  completeRestoreResolution?: (
    state: CloudSyncDurableState,
    resolvedTables: string[]
  ) => boolean;
  setStartupSyncPending?: (pending: boolean) => void;
  setCloudDownloadPending?: (pending: boolean) => void;
  settlePendingIndeterminate?: () => void;
  hasCloudBootstrapCompleted?: () => boolean;
  markCloudBootstrapCompleted?: () => boolean;
  discardMutationJournalForTables?: (tables: string[]) => boolean;
  loadDurableState?: () => CloudSyncDurableState | null;
  persistDurableState?: (state: CloudSyncDurableState) => boolean;
  selectionReenableBlocked?: (table: string) => boolean;
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
  let appliedCloudFirstTables: string[] = [];
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
  if (request.source === 'manualDownload' ||
    request.source === 'selectionReenable') {
    try {
      const begun: boolean = request.source ===
        'manualDownload'
        ? hooks !== null &&
          hooks.beginManualDownload()
        : hooks !== null &&
          hooks.beginSelectionReenableDownload !==
            undefined &&
          hooks.beginSelectionReenableDownload();
      if (!begun) {
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
  if (request.source === 'selectionReenable' &&
    hooks) {
    try {
      if (failedTables.length === 0) {
        const completed: boolean =
          hooks.completeSelectionReenableDownload !==
            undefined &&
          hooks.completeSelectionReenableDownload(
            request.tables.slice());
        if (!completed) {
          failedTables.push(
            request.tables.length > 0
              ? request.tables[0] : '');
          if (failureKind === 'none') {
            failureKind = 'unknown';
          }
          rollbackFailed =
            hooks.rollbackSelectionReenableDownload ===
              undefined ||
            !(await hooks
              .rollbackSelectionReenableDownload());
        }
      } else {
        rollbackFailed =
          hooks.rollbackSelectionReenableDownload ===
            undefined ||
          !(await hooks
            .rollbackSelectionReenableDownload());
      }
    } catch (_error) {
      rollbackFailed = true;
    }
  } else if (request.source === 'manualDownload' && hooks) {
    try {
      if (failedTables.length === 0) {
        const completed: boolean | void = hooks.completeManualDownload(request.tables.slice());
        if (completed === false) {
          failedTables.push(request.tables.length > 0 ? request.tables[0] : '');
          if (failureKind === 'none') { failureKind = 'unknown'; }
          rollbackFailed = !(await hooks.rollbackManualDownload());
        }
      } else {
        let completedTables: string[] = [];
        if (vncOnlyRequest && failedTables.length === 1 &&
            failedTables[0] === 'cryptoparams') {
          completedTables = request.tables.filter(
            (table: string): boolean => table !== 'cryptoparams');
        } else {
          completedTables =
            cloudFirstCompatibleTablesAfterOptionalFailure(
              request.direction, request.tables, failedTables);
        }
        if (completedTables.length > 0) {
        // `cryptoparams` is optional for a VNC transfer: metadata and opaque
        // encrypted rows may still be pulled safely. Commit the successful
          // VNC table and retain the crypto failure for the caller. The same
          // compatibility rule applies to the optional Moonlight table: a
          // failed ninth table must not roll successful legacy pulls back.
          const completed: boolean | void =
            hooks.completeManualDownloadPartial
              ? await hooks.completeManualDownloadPartial(
                completedTables, failedTables.slice())
              : hooks.completeManualDownload(completedTables);
          if (completed === false) {
            rollbackFailed = !(await hooks.rollbackManualDownload());
            failedTables.splice(
              0, failedTables.length, ...request.tables);
          } else {
            appliedCloudFirstTables = completedTables.slice();
          }
        } else {
          rollbackFailed = !(await hooks.rollbackManualDownload());
        }
      }
    } catch (_e) {
      try {
        rollbackFailed = !(await hooks.rollbackManualDownload());
      } catch (_rollbackError) {
        rollbackFailed = true;
      }
      failedTables.splice(
        0, failedTables.length, ...request.tables);
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
  if (request.direction === 'cloudFirst') {
    if (result.ok) {
      appliedCloudFirstTables = request.tables.slice();
    } else if (appliedCloudFirstTables.length === 0 &&
        request.source !== 'manualDownload') {
      appliedCloudFirstTables =
        cloudFirstCompatibleTablesAfterOptionalFailure(
          request.direction, request.tables, failedTables);
    }
  }
  if (appliedCloudFirstTables.length > 0) {
    try { onCloudFirstApplied(appliedCloudFirstTables); } catch (_e) { /* listener failures do not stall sync */ }
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
  private readonly selection:
    CloudSyncSelectionSource;
  private readonly vncSelection:
    VncCloudSyncSelectionSource;
  private readonly retryClock:
    CloudSyncRetryClock;
  private queueTail: Promise<void> = Promise.resolve();
  private pendingAutomaticTables: string[] = [];
  private deferredAutomaticTables: string[] = [];
  private pendingPull: Promise<CloudSyncOperationResult> | null = null;
  private onCloudFirstApplied: ((tables: string[]) => void) | null = null;
  private hooks: CloudSyncCoordinatorHooks | null = null;
  private retryTimer: number = -1;
  private retryRecords: CloudSyncRetryRecord[] = [];
  private restorePending: boolean = false;
  private restoreResolutionOperationInFlight: boolean = false;
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
  private vncSelectionMutationPending: boolean = false;
  private exclusiveVncSelectionLease:
    AccountSessionLease | null = null;

  constructor(
    selection: CloudSyncSelectionSource =
      CloudSyncSelectionStore.getInstance(),
    retryClock: CloudSyncRetryClock =
      new SystemCloudSyncRetryClock(),
    vncSelection: VncCloudSyncSelectionSource =
      VncCloudSyncSelectionStore.getInstance()
  ) {
    this.selection = selection;
    this.retryClock = retryClock;
    this.vncSelection = vncSelection;
  }

  static getInstance(): CloudSyncCoordinator {
    if (!CloudSyncCoordinator.instance) {
      CloudSyncCoordinator.instance = new CloudSyncCoordinator();
    }
    return CloudSyncCoordinator.instance;
  }

  bind(
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
      this.retryClock.cancel(this.retryTimer);
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
      generation: binding.generation,
      platformIdentityFingerprint:
        binding.platformIdentityFingerprint
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
    this.restoreResolutionOperationInFlight = false;
    this.vncSelectionMutationPending = false;
    this.exclusiveVncSelectionLease = null;
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

  requiresRestoreDirectionDecision(): boolean {
    return this.restoreResolutionPending();
  }

  isLeaseCurrent(lease: AccountSessionLease): boolean {
    return this.acceptingRequests && accountSessionLeaseEquals(this.currentLease, lease);
  }

  isExclusiveVncSelectionLease(
    lease: AccountSessionLease | null
  ): boolean {
    return lease !== null &&
      accountSessionLeaseEquals(
        this.exclusiveVncSelectionLease,
        lease) &&
      accountSessionLeaseEquals(
        this.currentLease, lease);
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
      this.retryClock.cancel(this.retryTimer);
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
    this.restoreResolutionOperationInFlight = false;
    this.vncSelectionMutationPending = false;
    this.exclusiveVncSelectionLease = null;
    return true;
  }

  /**
   * Called only after CloudStore fences an exact late native terminal callback.
   * It releases the durable recovery phase without claiming transfer success.
   */
  recoverIndeterminateTransfer(lease: AccountSessionLease): boolean {
    if (!accountSessionLeaseEquals(this.currentLease, lease) ||
      this.durableState === null ||
      this.durableState.phase !== 'recovery_required' ||
      this.durableState.lastFailureKind !== 'indeterminate') {
      return false;
    }
    const next: CloudSyncDurableState = cloudSyncIndeterminateSettled(
      this.durableState, this.currentBinding, this.transfersEnabled);
    if (!this.persistDurableCandidate(next)) { return false; }
    this.scheduleRetryTimer();
    return true;
  }

  /** A caller-owned durable transaction could not restore its before-image. */
  requireExternalRecovery(
    failedTables: string[]
  ): boolean {
    if (this.durableState === null) { return false; }
    const next: CloudSyncDurableState =
      cloudSyncExternalRecoveryRequired(
        this.durableState,
        failedTables);
    return this.persistDurableCandidate(next);
  }

  requestStartupPull(): Promise<CloudSyncOperationResult> {
    if (this.startupPull) { return this.startupPull; }
    if (!this.transfersEnabled) {
      return Promise.resolve(this.rejectedResult(
        this.makeRequest('startup', 'cloudFirst'), 'cloud_service'));
    }
    if (!this.runtimeTransferSelectionAvailable() &&
        !this.restoreResolutionPending() && !this.restoreUploadBlocked()) {
      // A dormant optional-table preference is not a runtime transfer set.
      // Do not create a startup checkpoint or mark bootstrap complete when no
      // deployed business table has actually been selected.
      return Promise.resolve(this.rejectedResult(
        this.makeRequest('startup', 'cloudFirst'), 'no_selection'));
    }
    const restoreBlocked: boolean = this.restoreUploadBlocked();
    const initialDirty: string[] = this.dirtyAutomaticTables.slice();
    const initialJournalRevisions: Record<string, number> =
      this.captureJournalRevisions(initialDirty);
    const initialMutationVersions: Record<string, number> = {};
    for (let i = 0; i < initialDirty.length; i++) {
      initialMutationVersions[initialDirty[i]] =
        this.automaticMutationVersions[initialDirty[i]] || 0;
    }
    const initialBootstrap: boolean = shouldUseCloudFirstForInitialBootstrap(this.bootstrapCompleted);
    this.startupState = 'pending';
    if (this.hooks && this.hooks.setStartupSyncPending) {
      try { this.hooks.setStartupSyncPending(true); } catch (_e) { /* best effort */ }
    }
    const startupCheckpointStarted: boolean =
      initialBootstrap && !restoreBlocked &&
      this.hooks !== null &&
      this.hooks.beginStartupDownload !== undefined &&
      this.hooks.beginStartupDownload();
    const checkpointFailed: boolean =
      initialBootstrap && !restoreBlocked &&
      !startupCheckpointStarted;
    const checkpointFailure: CloudSyncOperationResult = {
      ok: false, source: 'startup', tables: [],
      failedTables: this.selectedTables(),
      rollbackFailed: false, failureKind: 'local_finalize'
    };
    const operation: Promise<CloudSyncOperationResult> = checkpointFailed
      ? Promise.resolve(checkpointFailure)
      : restoreBlocked
      ? Promise.resolve(
        restoreQuarantinedStartupResult(
          this.selectedTables()))
      : initialBootstrap
        ? this.requestStartupCloudFirst()
        : this.requestEstablishedStartupPull(initialDirty);
    const completed: Promise<CloudSyncOperationResult> = operation.then(
      async (result: CloudSyncOperationResult):
        Promise<CloudSyncOperationResult> => {
      return await this.finishStartupPull(
        result, initialBootstrap, initialDirty,
        initialJournalRevisions, initialMutationVersions,
        restoreBlocked, startupCheckpointStarted);
    }, async (_e: Error):
      Promise<CloudSyncOperationResult> => {
      const failed: CloudSyncOperationResult = {
        ok: false, source: 'startup', tables: [], failedTables: [], rollbackFailed: false,
        failureKind: 'unknown'
      };
      return await this.finishStartupPull(
        failed, initialBootstrap, initialDirty,
        initialJournalRevisions, initialMutationVersions,
        restoreBlocked, startupCheckpointStarted);
    });
    const recovered: Promise<CloudSyncOperationResult> = completed.then(
      (result: CloudSyncOperationResult): CloudSyncOperationResult =>
        result,
      async (_error: Error): Promise<CloudSyncOperationResult> =>
        await this.recoverStartupFinalizationException(
          initialBootstrap, restoreBlocked,
          startupCheckpointStarted));
    this.startupPull = recovered;
    void recovered.then(
      (_result: CloudSyncOperationResult): void => {
        if (this.startupPull === recovered) {
          this.startupPull = null;
        }
      }, (_error: Error): void => {
        if (this.startupPull === recovered) {
          this.startupPull = null;
        }
      });
    return recovered;
  }

  private async recoverStartupFinalizationException(
    initialBootstrap: boolean,
    restoreBlocked: boolean,
    startupCheckpointStarted: boolean
  ): Promise<CloudSyncOperationResult> {
    let rollbackFailed: boolean = false;
    if (initialBootstrap && !restoreBlocked &&
        startupCheckpointStarted) {
      try {
        rollbackFailed = this.hooks === null ||
          this.hooks.rollbackStartupDownload === undefined ||
          !(await this.hooks.rollbackStartupDownload());
      } catch (_rollbackError) {
        rollbackFailed = true;
      }
    }
    this.startupState = 'pending';
    if (this.hooks && this.hooks.setStartupSyncPending) {
      try {
        this.hooks.setStartupSyncPending(false);
      } catch (_pendingError) { /* fail closed in memory */ }
    }
    return {
      ok: false,
      source: 'startup',
      tables: this.selectedTables(),
      failedTables: this.selectedTables(),
      rollbackFailed,
      failureKind: 'local_finalize'
    };
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
      !this.isAutomaticSyncBlocked(table) &&
      !this.selectionReenableBlocked(table));
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

  private async finishStartupPull(
    result: CloudSyncOperationResult,
    initialBootstrap: boolean,
    initialDirty: string[],
    _initialJournalRevisions: Record<string, number>,
    _initialMutationVersions: Record<string, number>,
    restoreBlocked: boolean,
    startupCheckpointStarted: boolean
  ): Promise<CloudSyncOperationResult> {
    let finalResult: CloudSyncOperationResult = result;
    const compatibleTables: string[] =
      cloudFirstCompatibleTablesAfterOptionalFailure(
        'cloudFirst', result.tables, result.failedTables);
    let compatibilityCommitted: boolean =
      !initialBootstrap && compatibleTables.length > 0;
    if (initialBootstrap && !restoreBlocked &&
      startupCheckpointStarted) {
      if (!result.ok) {
        let partialCompleted: boolean = false;
        if (compatibleTables.length > 0 && this.hooks !== null &&
            this.hooks.completeStartupDownloadPartial !== undefined) {
          const compatibleDirty: string[] = initialDirty.filter(
            (table: string): boolean =>
              compatibleTables.indexOf(table) >= 0);
          try {
            partialCompleted = await this.hooks
              .completeStartupDownloadPartial(
                compatibleDirty,
                compatibleTables.slice(),
                result.failedTables.slice());
          } catch (_partialError) {
            partialCompleted = false;
          }
        }
        if (partialCompleted) {
          compatibilityCommitted = true;
        } else {
          const restored: boolean =
            this.hooks !== null &&
            this.hooks.rollbackStartupDownload !==
              undefined &&
            (await this.hooks.rollbackStartupDownload());
          finalResult = {
            ok: false,
            source: result.source,
            tables: result.tables.slice(),
            failedTables: mergeCloudSyncTableLists(
              result.tables, result.failedTables),
            rollbackFailed: !restored,
            failureKind: result.failureKind
          };
        }
      } else if (this.hooks === null ||
        this.hooks.completeStartupDownload === undefined ||
        !this.hooks.completeStartupDownload(
          initialDirty.slice(), result.tables.slice())) {
        hilog.error(DOMAIN, TAG,
          'startup transfer succeeded but local download finalization failed stage=download_transaction');
        const restored: boolean =
          this.hooks !== null &&
          this.hooks.rollbackStartupDownload !==
            undefined &&
          (await this.hooks.rollbackStartupDownload());
        finalResult = {
          ok: false, source: result.source,
          tables: result.tables.slice(),
          failedTables: initialDirty.slice(),
          rollbackFailed: !restored,
          failureKind: 'local_finalize'
        };
      }
    }
    const bootstrapAccepted: boolean =
      finalResult.ok || compatibilityCommitted;
    if (bootstrapAccepted && initialBootstrap &&
      !restoreBlocked) {
      // The record-level reconcile above retains every genuine pre-bootstrap
      // journal entry. Queue those intents only after the authoritative pull
      // has committed, never before.
      for (let i = 0; i < initialDirty.length; i++) {
        if (compatibilityCommitted &&
            compatibleTables.indexOf(initialDirty[i]) < 0) {
          continue;
        }
        if (this.deferredAutomaticTables.indexOf(
          initialDirty[i]) < 0) {
          this.deferredAutomaticTables.push(
            initialDirty[i]);
        }
      }
      if (this.hooks && this.hooks.markCloudBootstrapCompleted &&
        !this.hooks.markCloudBootstrapCompleted()) {
        hilog.error(DOMAIN, TAG,
          'startup local finalization failed stage=bootstrap_marker');
        finalResult = {
          ok: false, source: result.source,
          tables: result.tables.slice(),
          failedTables: result.tables.slice(),
          rollbackFailed: false, failureKind: 'local_finalize'
        };
        compatibilityCommitted = false;
      } else {
        this.bootstrapCompleted = true;
        if (!this.persistBootstrapCompletion()) {
          hilog.error(DOMAIN, TAG,
            'startup local finalization failed stage=lifecycle_persist');
          finalResult = {
            ok: false, source: result.source,
            tables: result.tables.slice(),
            failedTables: result.tables.slice(),
            rollbackFailed: false, failureKind: 'local_finalize'
          };
          compatibilityCommitted = false;
        }
      }
    }
    const startupReady: boolean =
      finalResult.ok || compatibilityCommitted;
    if (startupReady) {
      this.startupState = 'ready';
      this.bootstrapCompleted = this.bootstrapCompleted || initialBootstrap;
    } else {
      this.startupState = 'pending';
    }
    if (this.hooks && this.hooks.setStartupSyncPending) {
      try { this.hooks.setStartupSyncPending(false); } catch (_e) { /* best effort */ }
    }
    if (startupReady) { this.flushDeferredAutomaticPushes(); }
    return finalResult;
  }

  private completeExplicitBootstrap(
    result: CloudSyncOperationResult,
    resolvedTables: string[] = result.tables
  ): CloudSyncOperationResult {
    if (!result.ok) { return result; }
    if (this.restoreResolutionPending()) {
      if (this.durableState === null || !this.hooks ||
        !this.hooks.completeRestoreResolution) {
        return this.restoreResolutionRejected(result);
      }
      const completed: CloudSyncDurableState =
        cloudSyncRestoreResolutionCompleted(
          this.durableState);
      try {
        if (!this.hooks.completeRestoreResolution(
          completed,
          snapshotCloudSyncTables(resolvedTables))) {
          return this.restoreResolutionRejected(result);
        }
      } catch (_error) {
        return this.restoreResolutionRejected(result);
      }
      this.durableState = completed;
      this.bootstrapCompleted = true;
      this.startupState = 'ready';
      if (this.hooks.setStartupSyncPending) {
        try {
          this.hooks.setStartupSyncPending(false);
        } catch (_error) { /* best effort */ }
      }
      this.flushDeferredAutomaticPushes();
      return result;
    }
    if (!this.bootstrapCompleted && this.hooks && this.hooks.markCloudBootstrapCompleted &&
      !this.hooks.markCloudBootstrapCompleted()) {
      hilog.error(DOMAIN, TAG,
        'explicit sync transfer succeeded but bootstrap marker write failed source=' +
        result.source + ' tables=' + result.tables.join(','));
      this.startupState = 'pending';
      return {
        ok: false, source: result.source, tables: result.tables.slice(),
        failedTables: result.tables.slice(), rollbackFailed: false,
        failureKind: 'local_finalize'
      };
    }
    this.bootstrapCompleted = true;
    if (!this.persistBootstrapCompletion()) {
      hilog.error(DOMAIN, TAG,
        'explicit sync transfer succeeded but bootstrap lifecycle persist failed source=' +
        result.source + ' tables=' + result.tables.join(','));
      this.startupState = 'pending';
      return {
        ok: false, source: result.source, tables: result.tables.slice(),
        failedTables: result.tables.slice(), rollbackFailed: false,
        failureKind: 'local_finalize'
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
    const base: CloudSyncRequest = this.makeRequest('manualUpload', 'nativeFirst');
    if (!this.transfersEnabled || !this.manualUploadAllowed()) {
      return Promise.resolve(this.rejectedResult(base, 'cloud_service'));
    }
    const resolvingRestore: boolean =
      this.restoreResolutionPending();
    if (!resolvingRestore && !this.runtimeTransferSelectionAvailable()) {
      return Promise.resolve(this.rejectedResult(base, 'no_selection'));
    }
    const restoredTables: string[] | null =
      resolvingRestore
        ? this.restoreTablesForExplicitDecision()
        : [];
    if (restoredTables === null) {
      return Promise.resolve(
        this.restoreResolutionRejected(
          this.rejectedResult(
            base, 'restore_pending')));
    }
    // Tables behind a pending selection re-enable barrier must complete their
    // cloud-first closed loop before any native-first upload. Skip them here
    // so one stuck table (e.g. vncrecord with an AGC-side schema problem)
    // cannot freeze every other table's manual upload.
    const tables: string[] = base.tables.filter(
      (table: string): boolean =>
        !this.selectionReenableBlocked(table) ||
        (resolvingRestore &&
          restoredTables.indexOf(table) >= 0));
    const includeVnc: boolean = this.vncPhysicalTableSelected() &&
      (!this.selectionReenableBlocked(VNC_CLOUD_TABLE) ||
        (resolvingRestore &&
          restoredTables.indexOf(
            VNC_CLOUD_TABLE) >= 0));
    hilog.info(DOMAIN, TAG,
      'manual upload plan ordinary=' + tables.join(',') +
      ' vncSelected=' + this.vncPhysicalTableSelected().toString() +
      ' includeVnc=' + includeVnc.toString() +
      ' restorePending=' + resolvingRestore.toString());
    const request: CloudSyncRequest = {
      source: 'manualUpload',
      direction: 'nativeFirst',
      tables
    };
    if (resolvingRestore) {
      return this.enqueueRestoreDecision(
        request,
        includeVnc ? this.vncUploadTables() : [],
        restoredTables);
    }
    if (tables.length === 0 && !includeVnc) {
      const allBlocked: CloudSyncOperationResult = {
        ok: false,
        source: 'manualUpload',
        tables: [],
        failedTables: base.tables.slice(),
        rollbackFailed: false,
        failureKind: 'unknown'
      };
      return Promise.resolve(allBlocked);
    }
    const versions: Record<string, number> = {};
    for (let i = 0; i < request.tables.length; i++) {
      versions[request.tables[i]] = this.automaticMutationVersions[request.tables[i]] || 0;
    }
    const journalRevisions: Record<string, number> = this.captureJournalRevisions(request.tables);
    return this.enqueue(request).then((result: CloudSyncOperationResult): Promise<CloudSyncOperationResult> => {
      for (let i = 0; i < request.tables.length; i++) {
        const table: string = request.tables[i];
        if (result.failedTables.indexOf(table) >= 0) { continue; }
        this.clearAutomaticSyncBlock(table);
        this.acknowledgeJournal(table, journalRevisions[table] || 0);
        const currentJournalRevision: number = this.captureJournalRevisions([table])[table] || 0;
        if ((this.automaticMutationVersions[table] || 0) === versions[table] && currentJournalRevision <= 0) {
          this.clearDirtyTable(table);
        }
      }
      // The ordinary selector may opt the physical VNC table in, but the
      // VNC request still has to pass through its independent logical scopes.
      // Run it after the ordinary queue item so this explicit operation stays
      // serialized without ever uploading the whole physical table blindly.
      if (includeVnc) {
        return this.requestVncManualUpload(false).then((vncResult: CloudSyncOperationResult): CloudSyncOperationResult => {
          const tables: string[] = snapshotCloudSyncTables(
            result.tables.concat(vncResult.tables));
          const failedTables: string[] = snapshotCloudSyncTables(
            result.failedTables.concat(vncResult.failedTables));
          const combined: CloudSyncOperationResult = {
            ok: failedTables.length === 0 && !result.rollbackFailed &&
              !vncResult.rollbackFailed,
            source: 'manualUpload',
            tables,
            failedTables,
            rollbackFailed: result.rollbackFailed || vncResult.rollbackFailed,
            failureKind: result.failureKind !== 'none' ? result.failureKind :
              vncResult.failureKind
          };
          return combined.ok ? this.completeExplicitBootstrap(
            combined, tables) : combined;
        });
      }
      return Promise.resolve(result.ok ? this.completeExplicitBootstrap(
        result, result.tables) : result);
    });
  }

  requestManualDownload(): Promise<CloudSyncOperationResult> {
    const request: CloudSyncRequest = this.makeRequest('manualDownload', 'cloudFirst');
    if (!this.transfersEnabled || !this.manualDownloadAllowed()) {
      return Promise.resolve(this.rejectedResult(request, 'cloud_service'));
    }
    const resolvingRestore: boolean =
      this.restoreResolutionPending();
    if (!resolvingRestore && !this.runtimeTransferSelectionAvailable()) {
      return Promise.resolve(this.rejectedResult(request, 'no_selection'));
    }
    const restoredTables: string[] | null =
      resolvingRestore
        ? this.restoreTablesForExplicitDecision()
        : [];
    if (restoredTables === null) {
      return Promise.resolve(
        this.restoreResolutionRejected(
          this.rejectedResult(
            request, 'restore_pending')));
    }
    const includeVnc: boolean = this.vncPhysicalTableSelected();
    if (resolvingRestore) {
      return this.enqueueRestoreDecision(
        request,
        includeVnc ? this.vncSyncTables() : [],
        restoredTables);
    }
    const versions: Record<string, number> = {};
    for (let i = 0; i < request.tables.length; i++) {
      versions[request.tables[i]] = this.automaticMutationVersions[request.tables[i]] || 0;
    }
    return this.enqueue(request).then((result: CloudSyncOperationResult): Promise<CloudSyncOperationResult> => {
      const compatibleTables: string[] =
        cloudFirstCompatibleTablesAfterOptionalFailure(
          'cloudFirst', result.tables, result.failedTables);
      if (!result.ok && compatibleTables.length === 0) {
        return Promise.resolve(result);
      }
      const completedOrdinary: string[] = result.ok
        ? request.tables.slice() : compatibleTables;
      for (let i = 0; i < completedOrdinary.length; i++) {
        const table: string = completedOrdinary[i];
        this.clearAutomaticSyncBlock(table);
        if ((this.automaticMutationVersions[table] || 0) === versions[table]) { this.clearDirtyTable(table); }
      }
      if (includeVnc) {
        return this.requestVncManualDownload(false).then((vncResult: CloudSyncOperationResult): CloudSyncOperationResult => {
          if (!vncResult.ok) {
            return result.ok ? vncResult :
              combineCloudSyncOperationResults(
                'manualDownload', result, vncResult);
          }
          const combined: CloudSyncOperationResult =
            combineCloudSyncOperationResults(
              'manualDownload', result, vncResult);
          const completedTables: string[] = mergeCloudSyncTableLists(
            completedOrdinary, vncResult.tables);
          if (combined.ok) {
            return this.completeExplicitBootstrap(
              combined, resolvingRestore
                ? restoredTables : completedTables);
          }
          const compatibleBootstrap: CloudSyncOperationResult =
            this.completeExplicitBootstrap({
              ok: true,
              source: 'manualDownload',
              tables: completedTables.slice(),
              failedTables: [],
              rollbackFailed: false,
              failureKind: 'none'
            }, completedTables);
          return compatibleBootstrap.ok ? combined :
            combineCloudSyncOperationResults(
              'manualDownload', combined,
              compatibleBootstrap);
        });
      }
      if (result.ok) {
        return Promise.resolve(this.completeExplicitBootstrap(
          result, resolvingRestore
            ? restoredTables : result.tables));
      }
      const compatibleBootstrap: CloudSyncOperationResult =
        this.completeExplicitBootstrap({
          ok: true,
          source: 'manualDownload',
          tables: completedOrdinary.slice(),
          failedTables: [],
          rollbackFailed: false,
          failureKind: 'none'
        }, completedOrdinary);
      return Promise.resolve(compatibleBootstrap.ok ? result :
        combineCloudSyncOperationResults(
          'manualDownload', result,
          compatibleBootstrap));
    });
  }

  private settleRestoreDecisionTables(
    source: 'manualUpload' | 'manualDownload',
    tables: string[],
    versions: Record<string, number>,
    journalRevisions: Record<string, number>
  ): void {
    for (let i = 0; i < tables.length; i++) {
      const table: string = tables[i];
      this.clearAutomaticSyncBlock(table);
      if (source === 'manualUpload') {
        this.acknowledgeJournal(
          table, journalRevisions[table] || 0);
      }
      const currentJournalRevision: number =
        this.captureJournalRevisions(
          [table])[table] || 0;
      if ((this.automaticMutationVersions[table] || 0) ===
        (versions[table] || 0) &&
        (source === 'manualDownload' ||
          currentJournalRevision <= 0)) {
        this.clearDirtyTable(table);
      }
    }
  }

  /**
   * One restore direction is one queue item. Ordinary tables, the independent
   * VNC projection and atomic marker completion therefore share one lease and
   * cannot be interleaved with another upload/download decision.
   */
  private enqueueRestoreDecision(
    ordinaryRequest: CloudSyncRequest,
    vncTables: string[],
    restoredTables: string[]
  ): Promise<CloudSyncOperationResult> {
    const source: 'manualUpload' |
      'manualDownload' =
      ordinaryRequest.source === 'manualUpload'
        ? 'manualUpload' : 'manualDownload';
    const direction: CloudSyncDirection =
      ordinaryRequest.direction;
    const ordinaryTables: string[] =
      snapshotCloudSyncTables(
        ordinaryRequest.tables);
    const vncRequestTables: string[] =
      snapshotCloudSyncTables(vncTables);
    const allTransferTables: string[] =
      snapshotCloudSyncTables(
        ordinaryTables.concat(
          vncRequestTables));
    const aggregateRequest: CloudSyncRequest = {
      source,
      direction,
      tables: allTransferTables
    };
    if (!this.acceptingRequests ||
      this.currentLease === null ||
      !this.transfersEnabled) {
      return Promise.resolve(
        this.rejectedResult(
          aggregateRequest));
    }
    if (direction === 'nativeFirst' &&
      !this.restoreUploadBarrierOverrideAllowed(
        allTransferTables)) {
      return Promise.resolve(
        this.rejectedResult(
          aggregateRequest,
          'cloud_service'));
    }
    const versions: Record<string, number> = {};
    for (let i = 0;
      i < allTransferTables.length; i++) {
      versions[allTransferTables[i]] =
        this.automaticMutationVersions[
          allTransferTables[i]] || 0;
    }
    const journalRevisions:
      Record<string, number> =
      source === 'manualUpload'
        ? this.captureJournalRevisions(
          allTransferTables)
        : {};
    const lease: AccountSessionLease =
      cloneAccountSessionLease(
        this.currentLease);
    const epoch: number = this.bindingEpoch;
    return new Promise<CloudSyncOperationResult>(
      (resolve: (result:
        CloudSyncOperationResult) => void): void => {
        const run = async (): Promise<void> => {
          const leaseCurrent = (): boolean =>
            this.acceptingRequests &&
            epoch === this.bindingEpoch &&
            accountSessionLeaseEquals(
              this.currentLease, lease);
          if (!leaseCurrent()) {
            resolve(this.rejectedResult(
              aggregateRequest));
            return;
          }
          const legs: CloudSyncRequest[] = [];
          if (ordinaryTables.length > 0) {
            legs.push({
              source, direction,
              tables: ordinaryTables
            });
          }
          if (vncRequestTables.length > 0) {
            legs.push({
              source, direction,
              tables: vncRequestTables
            });
          }
          const completedTables: string[] = [];
          for (let i = 0; i < legs.length; i++) {
            if (!this.beginLifecycleOperation(
              legs[i])) {
              resolve(this.rejectedResult(
                legs[i]));
              return;
            }
            const result: CloudSyncOperationResult =
              await this.execute(legs[i]);
            if (!leaseCurrent()) {
              resolve(this.rejectedResult(
                legs[i]));
              return;
            }
            if (!this.finishLifecycleOperation(
              result)) {
              resolve(this.rejectedResult(
                legs[i]));
              return;
            }
            if (result.failureKind ===
              'indeterminate' && this.hooks &&
              this.hooks.settlePendingIndeterminate) {
              this.hooks
                .settlePendingIndeterminate();
            }
            if (!result.ok) {
              resolve(result);
              return;
            }
            this.settleRestoreDecisionTables(
              source, result.tables,
              versions, journalRevisions);
            for (let j = 0;
              j < result.tables.length; j++) {
              if (completedTables.indexOf(
                result.tables[j]) < 0) {
                completedTables.push(
                  result.tables[j]);
              }
            }
          }
          if (!leaseCurrent()) {
            resolve(this.rejectedResult(
              aggregateRequest));
            return;
          }
          const combined: CloudSyncOperationResult = {
            ok: true,
            source,
            tables: completedTables,
            failedTables: [],
            rollbackFailed: false,
            failureKind: 'none'
          };
          const covered: string[] =
            snapshotCloudSyncTables(
              restoredTables.concat(
                completedTables));
          resolve(this.completeExplicitBootstrap(
            combined, covered));
        };
        this.queueTail =
          this.queueTail.then(run, run);
      });
  }

  /**
   * A newly re-enabled table gets an exact cloud-first barrier. CloudStore's
   * durable barrier keeps every native-first path blocked until the caller
   * records this terminal success and completes local promotion.
   */
  requestSelectionReenableCloudFirst(
    table: string
  ): Promise<CloudSyncOperationResult> {
    const request: CloudSyncRequest | null =
      this.selectionReenableRequest(table);
    if (request === null) {
      return Promise.resolve(this.rejectedResult({
        source: 'selectionReenable',
        direction: 'cloudFirst',
        tables: [table]
      }, 'cloud_service'));
    }
    return this.enqueue(request);
  }

  /**
   * VNC settings, its durable checkpoint, the required cloud-first and any
   * full before-image rollback occupy one queue item under one account lease.
   * Requests submitted later are appended behind this work and cannot start
   * while a restore is deleting/rebuilding the physical account store.
   */
  runExclusiveVncSelectionMutation(
    work: ExclusiveVncSelectionWork
  ): Promise<boolean> {
    if (!exclusiveVncSelectionAdmissionAllowed(
      this.vncSelectionMutationPending,
      this.restorePending,
      this.acceptingRequests,
      this.currentLease !== null)) {
      return Promise.resolve(false);
    }
    const lease: AccountSessionLease =
      cloneAccountSessionLease(
        this.currentLease as AccountSessionLease);
    const epoch: number = this.bindingEpoch;
    this.vncSelectionMutationPending = true;
    return new Promise<boolean>(
      (resolve: (ok: boolean) => void): void => {
        const run = async (): Promise<void> => {
          if (!this.acceptingRequests ||
            !exclusiveCloudOperationLeaseValid(
              epoch, this.bindingEpoch,
              accountSessionLeaseEquals(
                this.currentLease, lease))) {
            this.vncSelectionMutationPending = false;
            resolve(false);
            return;
          }
          this.exclusiveVncSelectionLease =
            cloneAccountSessionLease(lease);
          try {
            await work(
              cloneAccountSessionLease(lease),
              (table: string):
                Promise<CloudSyncOperationResult> =>
                this
                  .executeExclusiveSelectionCloudFirst(
                    table, lease, epoch));
            resolve(true);
          } catch (err) {
            hilog.error(DOMAIN, TAG,
              'exclusive VNC selection mutation failed: ' +
              JSON.stringify(err));
            resolve(false);
          } finally {
            this.exclusiveVncSelectionLease = null;
            this.vncSelectionMutationPending = false;
          }
        };
        this.queueTail = this.queueTail.then(run, run);
      });
  }

  private selectionReenableRequest(
    table: string
  ): CloudSyncRequest | null {
    let tables: string[] = [];
    if (table === VNC_CLOUD_TABLE) {
      tables = this.vncSyncTables();
    } else {
      tables = this.selectedTables().filter(
        (candidate: string): boolean =>
          candidate === table ||
          (candidate === 'cryptoparams' &&
            table !== 'usersettings'));
    }
    if (tables.indexOf(table) < 0) {
      return null;
    }
    return {
      source: 'selectionReenable',
      direction: 'cloudFirst',
      tables
    };
  }

  private async executeExclusiveSelectionCloudFirst(
    table: string,
    lease: AccountSessionLease,
    epoch: number
  ): Promise<CloudSyncOperationResult> {
    const request: CloudSyncRequest | null =
      this.selectionReenableRequest(table);
    if (request === null ||
      !this.isExclusiveVncSelectionLease(lease) ||
      !exclusiveCloudOperationLeaseValid(
        epoch, this.bindingEpoch, true) ||
      !this.transfersEnabled) {
      return this.rejectedResult({
        source: 'selectionReenable',
        direction: 'cloudFirst',
        tables: [table]
      }, 'cloud_service');
    }
    if (!this.beginLifecycleOperation(request)) {
      return this.rejectedResult(request);
    }
    const result: CloudSyncOperationResult =
      await this.execute(request);
    if (!this.isExclusiveVncSelectionLease(lease) ||
      !exclusiveCloudOperationLeaseValid(
        epoch, this.bindingEpoch, true)) {
      return this.rejectedResult(request);
    }
    if (!this.finishLifecycleOperation(result)) {
      return this.rejectedResult(request);
    }
    if (result.failureKind === 'indeterminate' &&
      this.hooks &&
      this.hooks.settlePendingIndeterminate) {
      this.hooks.settlePendingIndeterminate();
    }
    return result;
  }

  /** VNC manual operations use the same serialized transfer queue but never
   * inherit the ordinary RDP/RustDesk/SSH selection. */
  requestVncManualUpload(
    finalizeExplicit: boolean = true
  ): Promise<CloudSyncOperationResult> {
    const tables: string[] = this.vncUploadTables();
    if (tables.length === 0) { return Promise.resolve(this.skippedResult('manualUpload')); }
    const request: CloudSyncRequest = {
      source: 'manualUpload', direction: 'nativeFirst', tables
    };
    if (!this.transfersEnabled || !this.manualUploadAllowed()) {
      return Promise.resolve(this.rejectedResult(request, 'cloud_service'));
    }
    const versions: Record<string, number> = {};
    for (let i = 0; i < tables.length; i++) {
      versions[tables[i]] =
        this.automaticMutationVersions[tables[i]] || 0;
    }
    const journalRevisions: Record<string, number> = this.captureJournalRevisions(tables);
    return this.enqueue(request).then((result: CloudSyncOperationResult): CloudSyncOperationResult => {
      if (!result.ok) { return result; }
      for (let i = 0; i < tables.length; i++) {
        this.clearAutomaticSyncBlock(tables[i]);
        this.acknowledgeJournal(tables[i], journalRevisions[tables[i]] || 0);
        const currentJournalRevision: number =
          this.captureJournalRevisions(
            [tables[i]])[tables[i]] || 0;
        if ((this.automaticMutationVersions[tables[i]] || 0) ===
          versions[tables[i]] &&
          currentJournalRevision <= 0) {
          this.clearDirtyTable(tables[i]);
        }
      }
      return finalizeExplicit
        ? this.completeExplicitBootstrap(result, tables)
        : result;
    });
  }

  requestVncManualDownload(
    finalizeExplicit: boolean = true
  ): Promise<CloudSyncOperationResult> {
    const tables: string[] = this.vncSyncTables();
    if (tables.length === 0) { return Promise.resolve(this.skippedResult('manualDownload')); }
    const request: CloudSyncRequest = {
      source: 'manualDownload', direction: 'cloudFirst', tables
    };
    if (!this.transfersEnabled || !this.manualDownloadAllowed()) {
      return Promise.resolve(this.rejectedResult(request, 'cloud_service'));
    }
    const versions: Record<string, number> = {};
    for (let i = 0; i < tables.length; i++) {
      versions[tables[i]] =
        this.automaticMutationVersions[tables[i]] || 0;
    }
    return this.enqueue(request).then((result: CloudSyncOperationResult): CloudSyncOperationResult => {
      if (!result.ok) { return result; }
      for (let i = 0; i < tables.length; i++) {
        this.clearAutomaticSyncBlock(tables[i]);
        if ((this.automaticMutationVersions[tables[i]] || 0) ===
          versions[tables[i]]) {
          this.clearDirtyTable(tables[i]);
        }
      }
      return finalizeExplicit
        ? this.completeExplicitBootstrap(result, tables)
        : result;
    });
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
    if (!this.runtimeTransferSelectionAvailable() &&
        !this.restoreResolutionPending()) {
      return Promise.resolve(this.rejectedResult(
        this.makeRequest(source, 'cloudFirst'), 'no_selection'));
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
    // `vncrecordv2` is visible in the ordinary selector and is transferred by
    // the VNC path so encrypted rows can include cryptoparams when required.
    // There is no longer a second logical-scope selector.
    return snapshotCloudSyncTables(this.selection.selectedBusinessTables())
      .filter((table: string): boolean => table !== VNC_CLOUD_TABLE);
  }

  private vncPhysicalTableSelected(): boolean {
    return this.selection.selectedBusinessTables().indexOf(VNC_CLOUD_TABLE) >= 0;
  }

  private runtimeTransferSelectionAvailable(): boolean {
    return this.selectedTables().length > 0 ||
      this.vncPhysicalTableSelected();
  }

  private vncSyncTables(): string[] {
    if (!this.vncPhysicalTableSelected()) { return []; }
    const result: string[] = [];
    if (this.vncSelection.needsCrypto(DataCrypto.getInstance().isSetupComplete())) {
      result.push('cryptoparams');
    }
    result.push(VNC_CLOUD_TABLE);
    return result;
  }

  /**
   * The ordinary physical-table selection controls VNC transfer. A locked
   * device keeps encrypted secret rows opaque; it never replaces them with an
   * empty local projection.
   */
  private vncUploadTables(): string[] {
    return this.vncSyncTables();
  }

  private tablesForAutomaticRetry(retryKey: string): string[] {
    if (this.selectionReenableBlocked(retryKey)) {
      return [];
    }
    if (retryKey === VNC_CLOUD_TABLE) { return this.vncUploadTables(); }
    const selected: string[] = this.selectedTables();
    return selected.filter((candidate: string): boolean =>
      candidate === 'cryptoparams' || candidate === retryKey);
  }

  private requestVncStartupPush(): Promise<CloudSyncOperationResult> {
    if (this.restoreUploadBlocked() ||
      this.isAutomaticSyncBlocked(VNC_CLOUD_TABLE) ||
      this.selectionReenableBlocked(
        VNC_CLOUD_TABLE)) {
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
    const compatibleTables: string[] =
      cloudFirstCompatibleTablesAfterOptionalFailure(
        'cloudFirst', previous.tables, previous.failedTables);
    if (!previous.ok && compatibleTables.length === 0) {
      return Promise.resolve(previous);
    }
    const tables: string[] = this.vncSyncTables();
    if (tables.length === 0) { return Promise.resolve(previous); }
    return this.enqueue({ source, direction: 'cloudFirst', tables })
      .then((vnc: CloudSyncOperationResult): CloudSyncOperationResult =>
        combineCloudSyncOperationResults(source, previous, vnc));
  }

  private selectionReenableBlocked(
    table: string
  ): boolean {
    if (!this.hooks ||
      !this.hooks.selectionReenableBlocked) {
      return false;
    }
    try {
      return this.hooks.selectionReenableBlocked(table);
    } catch (_error) {
      return true;
    }
  }

  private skippedResult(source: CloudSyncSource): CloudSyncOperationResult {
    return { ok: true, source, tables: [], failedTables: [], rollbackFailed: false, failureKind: 'none' };
  }

  private enqueue(request: CloudSyncRequest): Promise<CloudSyncOperationResult> {
    recordDiagnosticEvent('data.cloud_sync', 'cloud_sync_requested', 'started',
      0, 0, diagnosticCloudRequestCode(request), 0, request.tables.length);
    if (!this.acceptingRequests || this.currentLease === null ||
      !this.transfersEnabled) {
      return Promise.resolve(this.rejectedResult(request));
    }
    if (request.direction === 'nativeFirst' &&
      request.tables.some(
        (table: string): boolean =>
          this.selectionReenableBlocked(table)) &&
      !(request.source === 'manualUpload' &&
        this.restoreResolutionPending() &&
        this.restoreUploadBarrierOverrideAllowed(
          request.tables))) {
      return Promise.resolve(
        this.rejectedResult(request, 'cloud_service'));
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
        if (result.failureKind === 'indeterminate' &&
          this.hooks && this.hooks.settlePendingIndeterminate) {
          this.hooks.settlePendingIndeterminate();
        }
        resolve(result);
      };
      this.queueTail = this.queueTail.then(run, run);
    });
  }

  private rejectedResult(request: CloudSyncRequest,
    failureKind: CloudSyncFailureKind = 'unknown'): CloudSyncOperationResult {
    recordDiagnosticEvent('data.cloud_sync', 'cloud_sync_skipped',
      failureKind === 'no_selection' || failureKind === 'restore_pending' ? 'skipped' : 'failed',
      0, 0, diagnosticCloudFailureCode(failureKind), 0, request.tables.length);
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
    const tracksCloudDownload: boolean = request.direction === 'cloudFirst' &&
      this.hooks !== null && this.hooks.setCloudDownloadPending !== undefined;
    if (tracksCloudDownload && this.hooks && this.hooks.setCloudDownloadPending) {
      this.hooks.setCloudDownloadPending(true);
    }
    recordDiagnosticEvent('data.cloud_sync', 'cloud_sync_started', 'started',
      0, 0, diagnosticCloudRequestCode(request), 0, request.tables.length);
    try {
      const result: CloudSyncOperationResult = await executeCloudSyncRequest(
        request,
        this.executor,
        this.hooks,
        (tables: string[]): void => {
          if (this.onCloudFirstApplied) { this.onCloudFirstApplied(tables); }
        }
      );
      recordDiagnosticEvent('data.cloud_sync', 'cloud_sync_completed',
        result.ok ? 'succeeded' : 'failed', 0, 0,
        diagnosticCloudFailureCode(result.failureKind), 0,
        result.failedTables.length);
      return result;
    } finally {
      if (tracksCloudDownload && this.hooks && this.hooks.setCloudDownloadPending) {
        this.hooks.setCloudDownloadPending(false);
      }
    }
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
    try {
      return this.hooks.hasRestoredNotUploaded();
    } catch (_e) {
      return true;
    }
  }

  private restoreResolutionPending(): boolean {
    return (this.durableState !== null &&
      this.durableState.phase === 'restore_quarantine') ||
      this.restoreUploadBlocked();
  }

  private restoreTablesForExplicitDecision():
    string[] | null {
    if (!this.hooks ||
      !this.hooks.pendingRestoreTables) {
      return null;
    }
    try {
      const pending: string[] | null =
        this.hooks.pendingRestoreTables();
      if (pending === null) {
        return null;
      }
      return snapshotCloudSyncTables(pending);
    } catch (_error) {
      return null;
    }
  }

  private restoreUploadBarrierOverrideAllowed(
    tables: string[]
  ): boolean {
    const pending: string[] | null =
      this.restoreTablesForExplicitDecision();
    if (pending === null) { return false; }
    for (let i = 0; i < tables.length; i++) {
      if (this.selectionReenableBlocked(tables[i]) &&
        pending.indexOf(tables[i]) < 0) {
        return false;
      }
    }
    return true;
  }

  private restoreResolutionRejected(
    result: CloudSyncOperationResult
  ): CloudSyncOperationResult {
    this.startupState = 'pending';
    return {
      ok: false,
      source: result.source,
      tables: result.tables.slice(),
      failedTables: result.tables.slice(),
      rollbackFailed: false,
      failureKind: 'restore_pending'
    };
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
    recordDiagnosticEvent('data.cloud_sync', 'cloud_sync_retry', 'retry',
      0, 0, diagnosticCloudRequestCode(request), delay,
      failedTables.length);
    const record: CloudSyncRetryRecord = {
      source: request.source,
      direction: request.direction,
      tables: request.tables.slice(),
      failedTables: failedTables.slice(),
      attempt,
      nextRetryAt:
        this.retryClock.now() + delay
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
    if (this.retryTimer >= 0) {
      this.retryClock.cancel(this.retryTimer);
      this.retryTimer = -1;
    }
    if (this.retryRecords.length === 0 || !this.transfersEnabled ||
      !this.automaticUploadAllowed()) { return; }
    let earliest: CloudSyncRetryRecord = this.retryRecords[0];
    for (let i = 1; i < this.retryRecords.length; i++) {
      if (this.retryRecords[i].nextRetryAt < earliest.nextRetryAt) { earliest = this.retryRecords[i]; }
    }
    const delay: number =
      Math.max(0, earliest.nextRetryAt -
      this.retryClock.now());
    const timerLease: AccountSessionLease | null = this.currentLease === null
      ? null : cloneAccountSessionLease(this.currentLease);
    const timerEpoch: number = this.bindingEpoch;
    this.retryTimer = this.retryClock.schedule((): void => {
      this.retryTimer = -1;
      if (!this.acceptingRequests || timerLease === null ||
        timerEpoch !== this.bindingEpoch ||
        !accountSessionLeaseEquals(this.currentLease, timerLease)) {
        return;
      }
      const now: number =
        this.retryClock.now();
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
    }, delay);
  }

  private automaticUploadAllowed(): boolean {
    return this.durableState !== null &&
      cloudSyncAutomaticUploadAllowed(this.durableState);
  }

  private manualUploadAllowed(): boolean {
    return this.durableState !== null &&
      cloudSyncManualUploadAllowed(
        this.durableState,
        this.restoreResolutionPending());
  }

  private manualDownloadAllowed(): boolean {
    return this.durableState !== null &&
      cloudSyncManualDownloadAllowed(
        this.durableState,
        this.restoreResolutionPending());
  }

  private beginLifecycleOperation(request: CloudSyncRequest): boolean {
    if (this.durableState === null) { return false; }
    this.restoreResolutionOperationInFlight = false;
    const resolvingRestore: boolean =
      (request.source === 'manualUpload' ||
        request.source === 'manualDownload') &&
      this.restoreResolutionPending();
    if (request.direction === 'nativeFirst' &&
      (request.source === 'manualUpload'
        ? !this.manualUploadAllowed()
        : !this.automaticUploadAllowed())) {
      return false;
    }
    if (request.direction === 'cloudFirst' &&
      (request.source === 'manualDownload'
        ? !this.manualDownloadAllowed()
        : !cloudSyncDownloadAllowed(this.durableState))) {
      return false;
    }
    const next: CloudSyncDurableState = cloudSyncOperationStarted(
      this.durableState, request.source, request.direction, request.tables);
    const persisted: boolean =
      this.persistDurableCandidate(next);
    if (persisted) {
      this.restoreResolutionOperationInFlight =
        resolvingRestore;
    }
    return persisted;
  }

  private finishLifecycleOperation(result: CloudSyncOperationResult): boolean {
    if (this.durableState === null) { return false; }
    const resolvingRestore: boolean =
      this.restoreResolutionOperationInFlight;
    this.restoreResolutionOperationInFlight = false;
    const next: CloudSyncDurableState = resolvingRestore
      ? cloudSyncRestoreResolutionAttemptFinished(
        this.durableState,
        result.ok,
        result.failedTables,
        result.rollbackFailed,
        result.failureKind,
        this.bootstrapCompleted)
      : cloudSyncOperationFinished(
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
      if (!this.hooks.persistDurableState(state)) {
        hilog.error(DOMAIN, TAG,
          'persist cloud lifecycle state rejected phase=' + state.phase +
          ' generation=' + state.generation.toString());
        return false;
      }
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
    this.restoreResolutionOperationInFlight = false;
    this.vncSelectionMutationPending = false;
    this.exclusiveVncSelectionLease = null;
  }
}
