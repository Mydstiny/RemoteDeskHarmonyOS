import { describe, expect, it } from '@ohos/hypium';
import {
  CloudSyncCoordinator,
  CloudSyncCoordinatorHooks,
  CloudSyncOperationResult,
  CloudSyncRetryClock,
  CloudSyncRetryTimerTask,
  CloudSyncSelectionSource,
  VncCloudSyncSelectionSource
} from '../main/ets/services/CloudSyncCoordinator';
import {
  CloudStore,
  CloudStoreMetadataQueryPort
} from '../main/ets/services/CloudStore';
import {
  CLOUD_DOWNLOAD_TRANSACTION_KEY,
  CLOUD_SELECTION_REENABLE_BARRIERS_KEY,
  VNC_SELECTION_REENABLE_TRANSACTION_KEY,
  CloudStoreVncAuthoritativeCompletionPort,
  CloudStoreVncSelectionFinalizationPort,
  VncSelectionCheckpointIdentity,
  VncSelectionReenableCheckpoint,
  VncSelectionReenableTransactionPayload,
  completeVncAuthoritativeCloudFirst,
  finalizeVncSelectionReenable,
  readVncSelectionBarrierPhase
} from '../main/ets/services/CloudStoreVncLifecycleWiring';
import {
  CloudStoreStartupRecoveryIo
} from '../main/ets/services/CloudStoreStartupRecoveryRunner';
import { CloudSyncDirection } from '../main/ets/services/CloudSyncPolicy';
import {
  CloudSyncFailureKind
} from '../main/ets/services/CloudSyncCoordinatorPolicy';
import {
  CloudSyncDurableState,
  cloudSyncRestoreQuarantined,
  newCloudSyncDurableState
} from '../main/ets/services/CloudSyncLifecyclePolicy';
import {
  AccountSessionLease
} from '../main/ets/services/AccountScopePolicy';
import {
  CloudAccountBinding
} from '../main/ets/services/CloudLifecycleSafetyPolicy';
import {
  CloudMetadataReadResult
} from '../main/ets/services/CloudMetadataSafetyPolicy';
import {
  CloudDownloadTransactionEnvelope,
  CloudDownloadTransactionOperation,
  cloudDownloadTransactionEnvelope
} from '../main/ets/services/CloudDownloadTransactionPolicy';
import {
  CloudSelectionReenablePhase
} from '../main/ets/services/CloudSelectionReenablePolicy';
import {
  CLOUD_BOOTSTRAP_COMPLETED_KEY,
  CLOUD_SYNC_DURABLE_STATE_KEY,
  RESTORED_NOT_UPLOADED_KEY,
  RESTORED_NOT_UPLOADED_TABLE_PREFIX,
  CloudRestoreResolutionPort,
  CloudRestoreResolutionResult,
  completeCloudRestoreResolution,
  pendingRestoreResolutionTables,
  writeFullRestoreQuarantineMarkers
} from '../main/ets/services/CloudStoreRestoreResolutionWiring';

class DeferredSignal {
  promise: Promise<void>;
  private resolveSignal:
    (() => void) | null = null;

  constructor() {
    this.promise = new Promise<void>(
      (resolve: () => void): void => {
        this.resolveSignal = resolve;
      });
  }

  release(): void {
    const resolve:
      (() => void) | null =
      this.resolveSignal;
    this.resolveSignal = null;
    if (resolve !== null) {
      resolve();
    }
  }
}

class FixedSelectionSource
  implements CloudSyncSelectionSource {
  private readonly tables: string[];

  constructor(tables: string[]) {
    this.tables = tables.slice();
  }

  selectedBusinessTables(): string[] {
    return this.tables.slice();
  }
}

class FixedVncSelectionSource
  implements VncCloudSyncSelectionSource {
  private readonly selected: boolean;
  private readonly crypto: boolean;

  constructor(selected: boolean,
    crypto: boolean = false) {
    this.selected = selected;
    this.crypto = crypto;
  }

  hasSelection(): boolean {
    return this.selected;
  }

  needsCrypto(
    _cryptoConfigured: boolean
  ): boolean {
    return this.crypto;
  }
}

class ControlledRetryClock
  implements CloudSyncRetryClock {
  private nowValue: number = 1000;
  private nextTimerId: number = 1;
  private timerId: number = -1;
  private task:
    CloudSyncRetryTimerTask | null = null;

  now(): number {
    return this.nowValue;
  }

  schedule(
    task: CloudSyncRetryTimerTask,
    _delayMs: number
  ): number {
    this.timerId = this.nextTimerId++;
    this.task = task;
    return this.timerId;
  }

  cancel(timerId: number): void {
    if (timerId === this.timerId) {
      this.timerId = -1;
      this.task = null;
    }
  }

  hasScheduledTask(): boolean {
    return this.task !== null;
  }

  advanceAndFire(deltaMs: number): void {
    this.nowValue += Math.max(0, deltaMs);
    const task:
      CloudSyncRetryTimerTask | null =
      this.task;
    this.task = null;
    this.timerId = -1;
    if (task !== null) {
      task();
    }
  }
}

class CoordinatorHooks
  implements CloudSyncCoordinatorHooks {
  failureKind: CloudSyncFailureKind =
    'network';
  restoredNotUploaded: boolean = false;
  restoredProbe:
    (() => boolean) | null = null;
  selectionBlocked:
    ((table: string) => boolean) | null =
    null;
  durableState:
    CloudSyncDurableState | null = null;
  restoreResolutionAllowed: boolean = true;
  restoreResolutionCount: number = 0;
  restoreResolutionTables: string[] = [];
  pendingRestoredTables: string[] | null = [];
  bootstrapCompleted: boolean = true;
  manualRollbackCount: number = 0;
  manualPartialCount: number = 0;
  manualPartialTables: string[] = [];
  manualPartialFailedTables: string[] = [];
  startupBeginCount: number = 0;
  startupRollbackCount: number = 0;
  startupCompleteCount: number = 0;
  startupPartialCount: number = 0;
  startupPartialAllowed: boolean = true;
  startupCompleteAllowed: boolean = true;
  startupCompleteThrowsOnce: boolean = false;
  startupPartialDirtyTables: string[] = [];
  startupPartialCompletedTables: string[] = [];
  startupPartialFailedTables: string[] = [];

  beginManualDownload(): boolean {
    return true;
  }

  async rollbackManualDownload():
    Promise<boolean> {
    this.manualRollbackCount++;
    return true;
  }

  completeManualDownload(
    _tables: string[]
  ): boolean {
    return true;
  }

  async completeManualDownloadPartial(
    tables: string[], failedTables: string[]
  ): Promise<boolean> {
    this.manualPartialCount++;
    this.manualPartialTables = tables.slice();
    this.manualPartialFailedTables = failedTables.slice();
    return true;
  }

  beginStartupDownload(): boolean {
    this.startupBeginCount++;
    return true;
  }

  async rollbackStartupDownload(): Promise<boolean> {
    this.startupRollbackCount++;
    return true;
  }

  completeStartupDownload(
    _dirtyTables: string[], _completedTables: string[]
  ): boolean {
    this.startupCompleteCount++;
    if (this.startupCompleteThrowsOnce) {
      this.startupCompleteThrowsOnce = false;
      throw new Error('injected startup finalizer failure');
    }
    return this.startupCompleteAllowed;
  }

  async completeStartupDownloadPartial(
    dirtyTables: string[], completedTables: string[],
    failedTables: string[]
  ): Promise<boolean> {
    this.startupPartialCount++;
    this.startupPartialDirtyTables = dirtyTables.slice();
    this.startupPartialCompletedTables = completedTables.slice();
    this.startupPartialFailedTables = failedTables.slice();
    return this.startupPartialAllowed;
  }

  setRestorePending(_pending: boolean): void {
  }

  failureKindForTable(
    _table: string
  ): CloudSyncFailureKind {
    return this.failureKind;
  }

  hasRestoredNotUploaded(): boolean {
    return this.restoredProbe !== null
      ? this.restoredProbe()
      : this.restoredNotUploaded;
  }

  pendingRestoreTables(): string[] | null {
    return this.pendingRestoredTables === null
      ? null : this.pendingRestoredTables.slice();
  }

  hasCloudBootstrapCompleted(): boolean {
    return this.bootstrapCompleted;
  }

  markCloudBootstrapCompleted(): boolean {
    this.bootstrapCompleted = true;
    return true;
  }

  loadDurableState():
    CloudSyncDurableState | null {
    return this.durableState;
  }

  persistDurableState(
    state: CloudSyncDurableState
  ): boolean {
    this.durableState = state;
    return true;
  }

  completeRestoreResolution(
    state: CloudSyncDurableState,
    resolvedTables: string[]
  ): boolean {
    if (!this.restoreResolutionAllowed) {
      return false;
    }
    this.restoreResolutionCount++;
    this.restoreResolutionTables =
      resolvedTables.slice();
    this.restoredNotUploaded = false;
    this.durableState = state;
    return true;
  }

  selectionReenableBlocked(
    table: string
  ): boolean {
    return this.selectionBlocked !== null &&
      this.selectionBlocked(table);
  }
}

function accountLease():
  AccountSessionLease {
  return {
    ownerScopeId: 'owner-wiring-test',
    storeIdentity:
      'remotedesktop_owner-wiring-test.db',
    generation: 7,
    storeInstanceId: 3
  };
}

function accountBinding():
  CloudAccountBinding {
  return {
    state: 'bound',
    ownerScopeId: 'owner-wiring-test',
    storeIdentity:
      'remotedesktop_owner-wiring-test.db',
    generation: 7,
    platformIdentityFingerprint:
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' +
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  };
}

function quarantinedCoordinatorHooks():
  CoordinatorHooks {
  const hooks: CoordinatorHooks =
    new CoordinatorHooks();
  hooks.restoredNotUploaded = true;
  hooks.pendingRestoredTables =
    ['remotehosts', 'sshkeys'];
  hooks.durableState =
    cloudSyncRestoreQuarantined(
      newCloudSyncDurableState(
        accountBinding(), true, true, 1),
      2);
  return hooks;
}

async function flushPromiseQueue(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

type MetadataMode =
  'present' | 'absent' | 'error';

class MutableMetadataQueryPort
  implements CloudStoreMetadataQueryPort {
  mode: MetadataMode = 'absent';
  value: string = '';

  queryValue(_key: string):
    string | null {
    if (this.mode === 'error') {
      throw new Error(
        'injected querySync failure');
    }
    if (this.mode === 'absent') {
      return null;
    }
    return this.value;
  }
}

type CompletionFault =
  'none' | 'begin' | 'rebase' |
  'journal' | 'delete' | 'commit';

function vncCheckpointIdentity():
  VncSelectionCheckpointIdentity {
  const lease: AccountSessionLease =
    accountLease();
  return {
    ownerScopeId: lease.ownerScopeId,
    storeIdentity: lease.storeIdentity,
    generation: lease.generation
  };
}

function vncCheckpointRaw(
  stage: string
): string {
  const payload:
    VncSelectionReenableTransactionPayload = {
    snapshot: {},
    extensions: [],
    metadata: [],
    mutationJournal: [],
    localTables: {},
    stage,
    previousScopes: ['settings'],
    previousBarrier: '',
    settingsId: 'vnc-settings-wiring'
  };
  const identity:
    VncSelectionCheckpointIdentity =
    vncCheckpointIdentity();
  const envelope:
    CloudDownloadTransactionEnvelope | null =
    cloudDownloadTransactionEnvelope(
      'vnc_scope_reenable',
      identity.ownerScopeId,
      identity.storeIdentity,
      identity.generation,
      JSON.stringify(payload),
      1000);
  return envelope === null
    ? '' : JSON.stringify(envelope);
}

function checkpointStageFromRaw(
  raw: string
): string {
  try {
    const envelope:
      CloudDownloadTransactionEnvelope =
      JSON.parse(raw) as
        CloudDownloadTransactionEnvelope;
    const payload:
      VncSelectionReenableTransactionPayload =
      JSON.parse(envelope.payloadJson) as
        VncSelectionReenableTransactionPayload;
    return payload.stage;
  } catch (_error) {
    return '';
  }
}

function vncBarrierRaw(
  phase: string
): string {
  const barriers:
    Record<string, string> = {};
  barriers['vncrecordv2'] = phase;
  return JSON.stringify(barriers);
}

function cloneStringRecord(
  source: Record<string, string>
): Record<string, string> {
  const result: Record<string, string> = {};
  const keys: string[] =
    Object.keys(source);
  for (let i = 0; i < keys.length; i++) {
    result[keys[i]] = source[keys[i]];
  }
  return result;
}

class MetadataMapQueryPort
  implements CloudStoreMetadataQueryPort {
  private values:
    Record<string, string> = {};
  private errorKeys: string[] = [];

  queryValue(key: string):
    string | null {
    if (this.errorKeys.indexOf(key) >= 0) {
      throw new Error(
        'injected querySync failure key=' +
        key);
    }
    const value: string | undefined =
      this.values[key];
    return value === undefined
      ? null : value;
  }

  set(key: string, value: string): void {
    this.values[key] = value;
  }

  delete(key: string): void {
    delete this.values[key];
  }

  has(key: string): boolean {
    return this.values[key] !== undefined;
  }

  value(key: string): string {
    return this.values[key] || '';
  }

  snapshot(): Record<string, string> {
    return cloneStringRecord(this.values);
  }

  replace(
    values: Record<string, string>
  ): void {
    this.values =
      cloneStringRecord(values);
  }

  setError(
    key: string,
    enabled: boolean
  ): void {
    const index: number =
      this.errorKeys.indexOf(key);
    if (enabled && index < 0) {
      this.errorKeys.push(key);
    } else if (!enabled && index >= 0) {
      this.errorKeys.splice(index, 1);
    }
  }
}

type RestoreResolutionFault =
  'none' | 'begin' | 'read' |
  'write-bootstrap' | 'write-durable' |
  'delete-global' | 'delete-table' |
  'write-barrier' | 'delete-barrier' |
  'commit' | 'post-read';

class FakeRestoreResolutionPort
  implements CloudRestoreResolutionPort {
  fault: RestoreResolutionFault = 'none';
  beginCount: number = 0;
  commitCount: number = 0;
  rollbackCount: number = 0;
  private values:
    Record<string, string> = {};
  private before:
    Record<string, string> = {};
  private committed: boolean = false;

  seed(key: string, value: string): void {
    this.values[key] = value;
  }

  has(key: string): boolean {
    return this.values[key] !== undefined;
  }

  value(key: string): string {
    return this.values[key] || '';
  }

  beginTransaction(): void {
    this.beginCount++;
    if (this.fault === 'begin') {
      throw new Error('begin fault');
    }
    this.before = cloneStringRecord(this.values);
  }

  commit(): void {
    if (this.fault === 'commit') {
      throw new Error('commit fault');
    }
    this.commitCount++;
    this.committed = true;
  }

  rollback(): void {
    this.rollbackCount++;
    this.values = cloneStringRecord(this.before);
  }

  readMetadata(key: string):
    CloudMetadataReadResult {
    if (this.fault === 'read' ||
      (this.fault === 'post-read' &&
        this.committed)) {
      return { state: 'error', value: '' };
    }
    const value: string | undefined =
      this.values[key];
    return value === undefined
      ? { state: 'absent', value: '' }
      : { state: 'present', value };
  }

  writeMetadata(
    key: string, value: string
  ): boolean {
    if ((this.fault === 'write-bootstrap' &&
      key === CLOUD_BOOTSTRAP_COMPLETED_KEY) ||
      (this.fault === 'write-durable' &&
        key === CLOUD_SYNC_DURABLE_STATE_KEY) ||
      (this.fault === 'write-barrier' &&
        key ===
          CLOUD_SELECTION_REENABLE_BARRIERS_KEY)) {
      return false;
    }
    this.values[key] = value;
    return true;
  }

  deleteMetadata(key: string): boolean {
    if ((this.fault === 'delete-global' &&
      key === RESTORED_NOT_UPLOADED_KEY) ||
      (this.fault === 'delete-table' &&
        key.indexOf(
          RESTORED_NOT_UPLOADED_TABLE_PREFIX) === 0) ||
      (this.fault === 'delete-barrier' &&
        key ===
          CLOUD_SELECTION_REENABLE_BARRIERS_KEY)) {
      return false;
    }
    delete this.values[key];
    return true;
  }
}

function seededRestoreResolutionPort(
  withRemainingBarrier: boolean = true
): FakeRestoreResolutionPort {
  const port: FakeRestoreResolutionPort =
    new FakeRestoreResolutionPort();
  port.seed(RESTORED_NOT_UPLOADED_KEY, '1');
  port.seed(
    RESTORED_NOT_UPLOADED_TABLE_PREFIX +
      'remotehosts', '1');
  port.seed(
    RESTORED_NOT_UPLOADED_TABLE_PREFIX +
      'vncrecordv2', '1');
  const barriers: Record<string, string> = {};
  barriers['remotehosts'] = 'pending_pull';
  barriers['vncrecordv2'] = 'pending_pull';
  if (withRemainingBarrier) {
    barriers['sshkeys'] = 'pending_pull';
  }
  port.seed(
    CLOUD_SELECTION_REENABLE_BARRIERS_KEY,
    JSON.stringify(barriers));
  return port;
}

/**
 * Minimal transactional fake. Mutations are written only to working state
 * between begin/commit, so rollback and kill-point assertions exercise the
 * same stateless collaborator that CloudStore's private completion entry uses.
 * All post-commit reads still traverse CloudStore.readLocalMetadataState.
 */
class FakeVncCompletionPort
  implements
  CloudStoreVncAuthoritativeCompletionPort {
  fault: CompletionFault = 'none';
  postCommitReadError: boolean = false;
  events: string[] = [];
  journalState: string = 'captured';
  snapshotCleared: boolean = false;
  private readonly store: CloudStore;
  private readonly metadata:
    MetadataMapQueryPort;
  private transactionId: number = 0;
  private working:
    Record<string, string> = {};
  private workingJournal: string =
    'captured';

  constructor(
    store: CloudStore,
    metadata: MetadataMapQueryPort
  ) {
    this.store = store;
    this.metadata = metadata;
    this.metadata.set(
      CLOUD_DOWNLOAD_TRANSACTION_KEY,
      'general-before-image');
    this.metadata.set(
      VNC_SELECTION_REENABLE_TRANSACTION_KEY,
      vncCheckpointRaw('prepared'));
  }

  activeOperation():
    CloudDownloadTransactionOperation | null {
    return 'selection_reenable';
  }

  checkpointIdentity():
    VncSelectionCheckpointIdentity {
    return vncCheckpointIdentity();
  }

  readMetadataState(
    key: string
  ): CloudMetadataReadResult {
    return this.store
      .readLocalMetadataState(key);
  }

  beginTransaction(): boolean {
    this.events.push('begin');
    if (this.fault === 'begin') {
      return false;
    }
    this.transactionId++;
    this.working =
      this.metadata.snapshot();
    this.workingJournal =
      this.journalState;
    return true;
  }

  rebaseAuthoritativeCheckpoint():
    boolean {
    this.events.push(
      this.transactionId.toString() +
      ':rebase');
    if (this.fault === 'rebase') {
      return false;
    }
    this.working[
      VNC_SELECTION_REENABLE_TRANSACTION_KEY] =
      vncCheckpointRaw('authoritative');
    return true;
  }

  reconcileJournal(
    tables: string[]
  ): boolean {
    this.events.push(
      this.transactionId.toString() +
      ':journal:' + tables.join('+'));
    if (this.fault === 'journal') {
      return false;
    }
    this.workingJournal = 'replayed';
    return true;
  }

  deleteDownloadCheckpoint(): boolean {
    this.events.push(
      this.transactionId.toString() +
      ':delete');
    if (this.fault === 'delete') {
      return false;
    }
    delete this.working[
      CLOUD_DOWNLOAD_TRANSACTION_KEY];
    return true;
  }

  commit(): boolean {
    this.events.push(
      this.transactionId.toString() +
      ':commit');
    if (this.fault === 'commit') {
      return false;
    }
    this.metadata.replace(this.working);
    this.journalState =
      this.workingJournal;
    if (this.postCommitReadError) {
      this.metadata.setError(
        VNC_SELECTION_REENABLE_TRANSACTION_KEY,
        true);
    }
    return true;
  }

  rollback(): void {
    this.events.push(
      this.transactionId.toString() +
      ':rollback');
    this.working =
      this.metadata.snapshot();
    this.workingJournal =
      this.journalState;
  }

  generalCheckpointPresent(): boolean {
    return this.metadata.has(
      CLOUD_DOWNLOAD_TRANSACTION_KEY);
  }

  vncCheckpointStage(): string {
    return checkpointStageFromRaw(
      this.metadata.value(
        VNC_SELECTION_REENABLE_TRANSACTION_KEY));
  }

  clearInMemorySnapshot(): void {
    this.events.push('publish');
    this.snapshotCleared = true;
  }
}

class FakeVncFinalizationPort
  implements
  CloudStoreVncSelectionFinalizationPort {
  events: string[] = [];
  uploadRequested: boolean = false;
  postCommitErrorKey: string = '';
  overridePostCommitBarrier:
    boolean = false;
  postCommitBarrierRaw: string = '';
  private readonly store: CloudStore;
  private readonly metadata:
    MetadataMapQueryPort;
  private working:
    Record<string, string> = {};

  constructor(
    store: CloudStore,
    metadata: MetadataMapQueryPort
  ) {
    this.store = store;
    this.metadata = metadata;
    this.metadata.set(
      VNC_SELECTION_REENABLE_TRANSACTION_KEY,
      vncCheckpointRaw('authoritative'));
    this.metadata.set(
      CLOUD_SELECTION_REENABLE_BARRIERS_KEY,
      vncBarrierRaw('pending_pull'));
  }

  checkpointIdentity():
    VncSelectionCheckpointIdentity {
    return vncCheckpointIdentity();
  }

  readMetadataState(
    key: string
  ):
    CloudMetadataReadResult {
    return this.store
      .readLocalMetadataState(key);
  }

  preparePromotion(): boolean {
    this.events.push('prepare');
    return true;
  }

  beginTransaction(): boolean {
    this.events.push('begin');
    this.working =
      this.metadata.snapshot();
    return true;
  }

  persistPullComplete(): boolean {
    this.events.push('pull_complete');
    this.working[
      CLOUD_SELECTION_REENABLE_BARRIERS_KEY] =
      vncBarrierRaw('pull_complete');
    return true;
  }

  promote(): boolean {
    this.events.push('promote');
    return true;
  }

  persistPromotionComplete():
    boolean {
    this.events.push(
      'promotion_complete');
    this.working[
      CLOUD_SELECTION_REENABLE_BARRIERS_KEY] =
      vncBarrierRaw(
        'promotion_complete');
    return true;
  }

  releaseBarrier(): boolean {
    this.events.push('release');
    delete this.working[
      CLOUD_SELECTION_REENABLE_BARRIERS_KEY];
    return true;
  }

  deleteCheckpoint(): boolean {
    this.events.push('delete');
    delete this.working[
      VNC_SELECTION_REENABLE_TRANSACTION_KEY];
    return true;
  }

  commit(): boolean {
    this.events.push('commit');
    this.metadata.replace(this.working);
    if (this.overridePostCommitBarrier) {
      this.metadata.set(
        CLOUD_SELECTION_REENABLE_BARRIERS_KEY,
        this.postCommitBarrierRaw);
    }
    if (this.postCommitErrorKey !== '') {
      this.metadata.setError(
        this.postCommitErrorKey, true);
    }
    return true;
  }

  rollback(): void {
    this.events.push('rollback');
    this.working =
      this.metadata.snapshot();
  }

  requestAutomaticUpload(): void {
    this.events.push('upload');
    this.uploadRequested = true;
  }
}

type RecoveryFault =
  'none' | 'restore' | 'scopes' |
  'begin' | 'lifecycle' | 'barrier' |
  'delete' | 'commit';

/**
 * Bottom-level persistence fake injected into a detached CloudStore. The test
 * still calls CloudStore.init, so CloudStore's private startup call point,
 * production adapter construction and runner own checkpoint parsing, payload
 * projection, key/table routing and fail-closed behavior.
 */
class FakeVncStartupRecoveryIo
  implements CloudStoreStartupRecoveryIo {
  fault: RecoveryFault = 'none';
  events: string[] = [];
  recoveryRequired: boolean = false;
  snapshotPublished: boolean = false;
  recoveredStage: string = '';
  recoveredCallback: boolean = false;
  stagedScopes: string[] = [];
  private readonly metadataReader:
    CloudStore;
  private readonly metadata:
    MetadataMapQueryPort;
  private working:
    Record<string, string> = {};

  constructor(metadata: MetadataMapQueryPort) {
    this.metadata = metadata;
    this.metadataReader =
      new CloudStore({
        metadataQuery: metadata
      });
    this.metadata.set(
      CLOUD_SELECTION_REENABLE_BARRIERS_KEY,
      vncBarrierRaw('pending_pull'));
  }

  checkpointIdentity():
    VncSelectionCheckpointIdentity {
    return vncCheckpointIdentity();
  }

  readMetadataState(
    key: string
  ): CloudMetadataReadResult {
    return this.metadataReader
      .readLocalMetadataState(key);
  }

  recoveryMetadata(
    checkpoint:
      VncSelectionReenableCheckpoint
  ): Array<Record<string, string>> {
    this.events.push('metadata');
    this.recoveredStage =
      checkpoint.payload.stage;
    return checkpoint.payload.metadata;
  }

  async restoreManualDownloadSnapshot(
    _snapshot:
      Record<string,
        Array<Record<string, string>>>,
    _extensions:
      Array<Record<string, string>>,
    _metadata:
      Array<Record<string, string>>,
    _mutationJournal:
      Array<Record<string, string>>,
    _localTables:
      Record<string,
        Array<Record<string, string>>>
  ): Promise<boolean> {
    this.events.push('restore');
    return this.fault !== 'restore';
  }

  stageSelectedScopes(
    scopes: string[]
  ): void {
    this.events.push('scopes:stage');
    this.stagedScopes = scopes;
  }

  persistSelectedScopes(): boolean {
    this.events.push('scopes:persist');
    return this.fault !== 'scopes';
  }

  beginTransaction(): boolean {
    this.events.push('begin');
    if (this.fault === 'begin') {
      return false;
    }
    this.working =
      this.metadata.snapshot();
    return true;
  }

  settleRecoveryLifecycle(): boolean {
    this.events.push('lifecycle');
    return this.fault !== 'lifecycle';
  }

  restoreSelectionReenableBarrier(
    table: string,
    previousPhase:
      CloudSelectionReenablePhase | null
  ): boolean {
    this.events.push(
      'barrier:' + table);
    if (this.fault === 'barrier' ||
      table !== 'vncrecordv2') {
      return false;
    }
    if (previousPhase === null) {
      delete this.working[
        CLOUD_SELECTION_REENABLE_BARRIERS_KEY];
    } else {
      this.working[
        CLOUD_SELECTION_REENABLE_BARRIERS_KEY] =
        vncBarrierRaw(previousPhase);
    }
    return true;
  }

  deleteLocalMetadata(
    key: string
  ): boolean {
    this.events.push('delete:' + key);
    if (this.fault === 'delete') {
      return false;
    }
    delete this.working[key];
    return true;
  }

  commit(): boolean {
    this.events.push('commit');
    if (this.fault === 'commit') {
      return false;
    }
    this.metadata.replace(this.working);
    return true;
  }

  rollback(): void {
    this.events.push('rollback');
    this.working =
      this.metadata.snapshot();
  }

  publishSnapshot(): void {
    this.events.push('publish');
    this.snapshotPublished = true;
  }

  markRecoveryRequired(): void {
    this.events.push('fail_closed');
    this.recoveryRequired = true;
  }

  onRecovered(): void {
    this.events.push('recovered');
    this.recoveredCallback = true;
  }

  checkpointPresent(): boolean {
    return this.metadata.has(
      VNC_SELECTION_REENABLE_TRANSACTION_KEY);
  }
}

export default function cloudDataWiringTest():
  void {
  describe('CloudDataWiring', (): void => {
    it('does_not_execute_or_bootstrap_when_no_runtime_table_is_selected',
      0, async (): Promise<void> => {
        const coordinator = new CloudSyncCoordinator(
          new FixedSelectionSource([]),
          new ControlledRetryClock(),
          new FixedVncSelectionSource(false));
        const hooks = new CoordinatorHooks();
        let executions: number = 0;
        expect(coordinator.bind(
          accountLease(), accountBinding(),
          async (): Promise<boolean> => {
            executions++;
            return true;
          },
          (_tables: string[]): void => {},
          hooks)).assertTrue();

        const startup: CloudSyncOperationResult =
          await coordinator.requestStartupPull();
        expect(startup.ok).assertFalse();
        expect(startup.failureKind).assertEqual('no_selection');
        const upload: CloudSyncOperationResult =
          await coordinator.requestManualUpload();
        expect(upload.ok).assertFalse();
        expect(upload.failureKind).assertEqual('no_selection');
        const download: CloudSyncOperationResult =
          await coordinator.requestManualDownload();
        expect(download.ok).assertFalse();
        expect(download.failureKind).assertEqual('no_selection');
        expect(executions).assertEqual(0);
        expect(await coordinator.dispose(
          accountLease(), 1000)).assertTrue();
      });

    it('commits_core_startup_and_vnc_when_optional_moonlight_transfer_fails',
      0, async (): Promise<void> => {
        const coordinator = new CloudSyncCoordinator(
          new FixedSelectionSource([
            'usersettings', 'vncrecordv2',
            'moonlightrecordv1'
          ]),
          new ControlledRetryClock(),
          new FixedVncSelectionSource(true));
        const hooks = new CoordinatorHooks();
        hooks.bootstrapCompleted = false;
        hooks.selectionBlocked =
          (table: string): boolean =>
            table === 'moonlightrecordv1';
        const executions: string[] = [];
        const applied: string[] = [];
        expect(coordinator.bind(
          accountLease(), accountBinding(),
          async (table: string, _direction: CloudSyncDirection,
            label: string): Promise<boolean> => {
            executions.push(label + ':' + table);
            return table !== 'moonlightrecordv1';
          },
          (tables: string[]): void => {
            tables.forEach((table: string): void => {
              if (applied.indexOf(table) < 0) { applied.push(table); }
            });
          }, hooks)).assertTrue();

        const startup: CloudSyncOperationResult =
          await coordinator.requestStartupPull();
        expect(startup.ok).assertFalse();
        expect(startup.failedTables.join(','))
          .assertEqual('moonlightrecordv1');
        expect(hooks.startupBeginCount).assertEqual(1);
        expect(hooks.startupPartialCount).assertEqual(1);
        expect(hooks.startupRollbackCount).assertEqual(0);
        expect(hooks.startupPartialCompletedTables.join(','))
          .assertEqual('usersettings,vncrecordv2');
        expect(hooks.startupPartialFailedTables.join(','))
          .assertEqual('moonlightrecordv1');
        expect(hooks.bootstrapCompleted).assertTrue();
        expect(executions.join(','))
          .assertEqual(
            'startup:usersettings,startup:moonlightrecordv1,' +
            'startup:vncrecordv2');
        expect(applied.join(','))
          .assertEqual('usersettings,vncrecordv2');

        const beforeEvent: number = executions.length;
        const event: CloudSyncOperationResult =
          await coordinator.requestCloudEventPull();
        expect(event.ok).assertFalse();
        expect(event.failedTables.join(','))
          .assertEqual('moonlightrecordv1');
        expect(executions.length - beforeEvent).assertEqual(3);
        expect(executions[executions.length - 1])
          .assertEqual('cloudEvent:vncrecordv2');
        expect(await coordinator.dispose(
          accountLease(), 1000)).assertTrue();
      });

    it('rolls_initial_bootstrap_back_when_core_or_partial_finalization_fails',
      0, async (): Promise<void> => {
        const coreHooks = new CoordinatorHooks();
        coreHooks.bootstrapCompleted = false;
        const core = new CloudSyncCoordinator(
          new FixedSelectionSource([
            'usersettings', 'moonlightrecordv1'
          ]), new ControlledRetryClock());
        expect(core.bind(
          accountLease(), accountBinding(),
          async (table: string): Promise<boolean> =>
            table !== 'usersettings',
          (_tables: string[]): void => {}, coreHooks)).assertTrue();
        const coreFailure: CloudSyncOperationResult =
          await core.requestStartupPull();
        expect(coreFailure.ok).assertFalse();
        expect(coreFailure.failedTables.join(','))
          .assertEqual('usersettings,moonlightrecordv1');
        expect(coreHooks.startupPartialCount).assertEqual(0);
        expect(coreHooks.startupRollbackCount).assertEqual(1);
        expect(coreHooks.bootstrapCompleted).assertFalse();
        expect(await core.dispose(
          accountLease(), 1000)).assertTrue();

        const partialHooks = new CoordinatorHooks();
        partialHooks.bootstrapCompleted = false;
        partialHooks.startupPartialAllowed = false;
        const partial = new CloudSyncCoordinator(
          new FixedSelectionSource([
            'usersettings', 'moonlightrecordv1'
          ]), new ControlledRetryClock());
        expect(partial.bind(
          accountLease(), accountBinding(),
          async (table: string): Promise<boolean> =>
            table !== 'moonlightrecordv1',
          (_tables: string[]): void => {}, partialHooks)).assertTrue();
        const finalizationFailure: CloudSyncOperationResult =
          await partial.requestStartupPull();
        expect(finalizationFailure.ok).assertFalse();
        expect(finalizationFailure.failedTables.join(','))
          .assertEqual('usersettings,moonlightrecordv1');
        expect(partialHooks.startupPartialCount).assertEqual(1);
        expect(partialHooks.startupRollbackCount).assertEqual(1);
        expect(partialHooks.bootstrapCompleted).assertFalse();
        expect(await partial.dispose(
          accountLease(), 1000)).assertTrue();
      });

    it('reports_local_finalization_failure_after_successful_startup_transfer',
      0, async (): Promise<void> => {
        const hooks: CoordinatorHooks = new CoordinatorHooks();
        hooks.bootstrapCompleted = false;
        hooks.startupCompleteAllowed = false;
        const coordinator = new CloudSyncCoordinator(
          new FixedSelectionSource(['usersettings']),
          new ControlledRetryClock());
        expect(coordinator.bind(
          accountLease(), accountBinding(),
          async (_table: string): Promise<boolean> => true,
          (_tables: string[]): void => {}, hooks)).assertTrue();

        const startup: CloudSyncOperationResult =
          await coordinator.requestStartupPull();
        expect(startup.ok).assertFalse();
        expect(startup.failureKind)
          .assertEqual('local_finalize');
        expect(hooks.startupCompleteCount).assertEqual(1);
        expect(hooks.startupRollbackCount).assertEqual(1);
        expect(hooks.bootstrapCompleted).assertFalse();
        expect(await coordinator.dispose(
          accountLease(), 1000)).assertTrue();
      });

    it('clears_rejected_startup_finalizer_and_allows_an_exact_retry',
      0, async (): Promise<void> => {
        const hooks: CoordinatorHooks = new CoordinatorHooks();
        hooks.bootstrapCompleted = false;
        hooks.startupCompleteThrowsOnce = true;
        const coordinator = new CloudSyncCoordinator(
          new FixedSelectionSource(['usersettings']),
          new ControlledRetryClock());
        let executions: number = 0;
        expect(coordinator.bind(
          accountLease(), accountBinding(),
          async (_table: string): Promise<boolean> => {
            executions++;
            return true;
          }, (_tables: string[]): void => {}, hooks)).assertTrue();

        const first: CloudSyncOperationResult =
          await coordinator.requestStartupPull();
        expect(first.ok).assertFalse();
        expect(first.failureKind).assertEqual('local_finalize');
        expect(first.rollbackFailed).assertFalse();
        expect(hooks.startupRollbackCount).assertEqual(1);

        const second: CloudSyncOperationResult =
          await coordinator.requestStartupPull();
        expect(second.ok).assertTrue();
        expect(executions).assertEqual(2);
        expect(hooks.startupCompleteCount).assertEqual(2);
        expect(await coordinator.dispose(
          accountLease(), 1000)).assertTrue();
      });

    it('keeps_core_manual_download_and_continues_vnc_after_optional_failure',
      0, async (): Promise<void> => {
        const coordinator = new CloudSyncCoordinator(
          new FixedSelectionSource([
            'usersettings', 'vncrecordv2',
            'moonlightrecordv1'
          ]),
          new ControlledRetryClock(),
          new FixedVncSelectionSource(true));
        const hooks = new CoordinatorHooks();
        hooks.selectionBlocked =
          (table: string): boolean =>
            table === 'moonlightrecordv1';
        const executions: string[] = [];
        expect(coordinator.bind(
          accountLease(), accountBinding(),
          async (table: string, _direction: CloudSyncDirection,
            label: string): Promise<boolean> => {
            executions.push(label + ':' + table);
            return table !== 'moonlightrecordv1';
          },
          (_tables: string[]): void => {}, hooks)).assertTrue();

        const result: CloudSyncOperationResult =
          await coordinator.requestManualDownload();
        expect(result.ok).assertFalse();
        expect(result.failedTables.join(','))
          .assertEqual('moonlightrecordv1');
        expect(hooks.manualPartialCount).assertEqual(1);
        expect(hooks.manualPartialTables.join(','))
          .assertEqual('usersettings');
        expect(hooks.manualPartialFailedTables.join(','))
          .assertEqual('moonlightrecordv1');
        expect(hooks.manualRollbackCount).assertEqual(0);
        expect(executions.join(','))
          .assertEqual(
            'manualDownload:usersettings,' +
            'manualDownload:moonlightrecordv1,' +
            'manualDownload:vncrecordv2');
        expect(await coordinator.dispose(
          accountLease(), 1000)).assertTrue();
      });

    it('continues_vnc_manual_upload_after_an_ordinary_table_fails',
      0, async (): Promise<void> => {
        const coordinator = new CloudSyncCoordinator(
          new FixedSelectionSource(['remotehosts']),
          new ControlledRetryClock(),
          new FixedVncSelectionSource(true));
        const hooks = new CoordinatorHooks();
        const executions: string[] = [];
        expect(coordinator.bind(
          accountLease(), accountBinding(),
          async (table: string,
            direction: CloudSyncDirection): Promise<boolean> => {
            executions.push(direction + ':' + table);
            return table !== 'remotehosts';
          },
          (_tables: string[]): void => {},
          hooks)).assertTrue();

        const result: CloudSyncOperationResult =
          await coordinator.requestManualUpload();
        expect(result.ok).assertFalse();
        expect(result.failedTables.join(','))
          .assertEqual('remotehosts');
        expect(executions.join(','))
          .assertEqual('nativeFirst:remotehosts,nativeFirst:vncrecordv2');
        expect(await coordinator.dispose(
          accountLease(), 1000)).assertTrue();
      });

    it('serializes_live_sync_exclusive_restore_event_retry_and_upload',
      0, async (): Promise<void> => {
        const clock =
          new ControlledRetryClock();
        const coordinator =
          new CloudSyncCoordinator(
            new FixedSelectionSource(
              ['remotehosts', 'sshkeys']),
            clock);
        const hooks =
          new CoordinatorHooks();
        const lease = accountLease();
        const events: string[] = [];
        const cloudGate =
          new DeferredSignal();
        const restoreGate =
          new DeferredSignal();
        let mode: string = 'bootstrap';
        let blockedCloudEvent:
          boolean = false;
        const bound: boolean =
          coordinator.bind(
            lease,
            accountBinding(),
            async (
              table: string,
              _direction:
                CloudSyncDirection,
              label: string
            ): Promise<boolean> => {
              events.push(
                label + ':' + table +
                ':start');
              if (mode === 'seed_failure' &&
                label === 'automaticPush' &&
                table === 'remotehosts') {
                events.push(
                  'seed:failed');
                return false;
              }
              if (mode === 'queue_probe' &&
                label === 'cloudEvent' &&
                !blockedCloudEvent) {
                blockedCloudEvent = true;
                await cloudGate.promise;
              }
              events.push(
                label + ':' + table +
                ':done');
              return true;
            },
            (_tables: string[]): void => {
            },
            hooks);
        expect(bound).assertTrue();
        const startup:
          CloudSyncOperationResult =
          await coordinator
            .requestStartupPull();
        expect(startup.ok).assertTrue();

        mode = 'seed_failure';
        const seed:
          CloudSyncOperationResult =
          await coordinator
            .requestAutomaticPush(
              'remotehosts');
        expect(seed.ok).assertFalse();
        expect(clock.hasScheduledTask())
          .assertTrue();

        mode = 'queue_probe';
        const existingSync:
          Promise<CloudSyncOperationResult> =
          coordinator
            .requestCloudEventPull();
        await flushPromiseQueue();
        const exclusive:
          Promise<boolean> =
          coordinator
            .runExclusiveVncSelectionMutation(
              async (
                exclusiveLease:
                  AccountSessionLease
              ): Promise<void> => {
                events.push(
                  'exclusive:start');
                expect(coordinator
                  .isExclusiveVncSelectionLease(
                    exclusiveLease))
                  .assertTrue();
                await restoreGate.promise;
                events.push(
                  'exclusive:restore_done');
              });
        cloudGate.release();
        expect((await existingSync).ok)
          .assertTrue();
        await flushPromiseQueue();
        expect(events.indexOf(
          'exclusive:start') >= 0)
          .assertTrue();

        const startsBeforeRelease:
          number = events.filter(
            (event: string): boolean =>
              event.indexOf(':start') >= 0)
            .length;
        const queuedEvent =
          coordinator
            .requestCloudEventPull();
        const queuedUpload =
          coordinator
            .requestAutomaticPush(
              'sshkeys');
        clock.advanceAndFire(2000);
        await flushPromiseQueue();
        expect(events.filter(
          (event: string): boolean =>
            event.indexOf(':start') >= 0)
          .length)
          .assertEqual(
            startsBeforeRelease);

        restoreGate.release();
        expect(await exclusive).assertTrue();
        expect((await queuedEvent).ok)
          .assertTrue();
        expect((await queuedUpload).ok)
          .assertTrue();
        const drain =
          coordinator
            .runExclusiveVncSelectionMutation(
              async (): Promise<void> => {
                events.push('drain');
              });
        expect(await drain).assertTrue();

        const restoreDoneIndex:
          number = events.indexOf(
          'exclusive:restore_done');
        const secondCloudIndex:
          number = events.lastIndexOf(
          'cloudEvent:cryptoparams:start');
        const retryIndex:
          number = events.lastIndexOf(
          'automaticPush:remotehosts:start');
        const uploadIndex:
          number = events.lastIndexOf(
          'automaticPush:sshkeys:start');
        expect(restoreDoneIndex >= 0)
          .assertTrue();
        expect(secondCloudIndex >
          restoreDoneIndex).assertTrue();
        expect(retryIndex >
          restoreDoneIndex).assertTrue();
        expect(uploadIndex >
          restoreDoneIndex).assertTrue();
        expect(await coordinator.dispose(
          lease, 1000)).assertTrue();
      });

    it('invalidated_lease_fails_closed_before_queued_exclusive_work',
      0, async (): Promise<void> => {
        const coordinator =
          new CloudSyncCoordinator(
            new FixedSelectionSource(
              ['remotehosts']),
            new ControlledRetryClock());
        const hooks =
          new CoordinatorHooks();
        const lease = accountLease();
        const gate = new DeferredSignal();
        let block: boolean = false;
        let exclusiveStarted:
          boolean = false;
        expect(coordinator.bind(
          lease,
          accountBinding(),
          async (
            _table: string,
            _direction:
              CloudSyncDirection,
            label: string
          ): Promise<boolean> => {
            if (block &&
              label === 'cloudEvent') {
              await gate.promise;
            }
            return true;
          },
          (_tables: string[]): void => {
          },
          hooks)).assertTrue();
        expect((await coordinator
          .requestStartupPull()).ok)
          .assertTrue();
        block = true;
        const active =
          coordinator
            .requestCloudEventPull();
        await flushPromiseQueue();
        const queued =
          coordinator
            .runExclusiveVncSelectionMutation(
              async (): Promise<void> => {
                exclusiveStarted = true;
              });
        const disposing =
          coordinator.dispose(
            lease, 1000);
        gate.release();
        expect((await active).ok)
          .assertTrue();
        expect(await queued).assertFalse();
        expect(await disposing).assertTrue();
        expect(exclusiveStarted)
          .assertFalse();
      });

    it('uses_CloudStore_metadata_query_port_for_present_absent_and_error',
      0, (): void => {
        const metadata =
          new MutableMetadataQueryPort();
        const store =
          new CloudStore({
            metadataQuery: metadata
          });
        metadata.mode = 'absent';
        expect(store.readLocalMetadataState(
          'barrier').state)
          .assertEqual('absent');
        metadata.mode = 'present';
        metadata.value = 'pending_pull';
        const present =
          store.readLocalMetadataState(
            'barrier');
        expect(present.state)
          .assertEqual('present');
        expect(present.value)
          .assertEqual('pending_pull');
        metadata.mode = 'error';
        expect(store.readLocalMetadataState(
          'barrier').state)
          .assertEqual('error');
        expect(store
          .selectionReenableBlocked(
            'remotehosts'))
          .assertTrue();
        expect(store
          .hasRestoredNotUploaded())
          .assertTrue();
      });

    it('metadata_query_error_blocks_bootstrap_retry_and_native_first',
      0, async (): Promise<void> => {
        const metadata =
          new MutableMetadataQueryPort();
        const store =
          new CloudStore({
            metadataQuery: metadata
          });
        const clock =
          new ControlledRetryClock();
        const hooks =
          new CoordinatorHooks();
        hooks.selectionBlocked =
          (table: string): boolean =>
            store
              .selectionReenableBlocked(
                table);
        const coordinator =
          new CloudSyncCoordinator(
            new FixedSelectionSource(
              ['remotehosts']),
            clock);
        let executions: number = 0;
        let failUpload: boolean = false;
        expect(coordinator.bind(
          accountLease(),
          accountBinding(),
          async (
            table: string,
            _direction:
              CloudSyncDirection,
            label: string
          ): Promise<boolean> => {
            executions++;
            return !(failUpload &&
              label === 'automaticPush' &&
              table === 'remotehosts');
          },
          (_tables: string[]): void => {
          },
          hooks)).assertTrue();
        metadata.mode = 'absent';
        expect((await coordinator
          .requestStartupPull()).ok)
          .assertTrue();
        failUpload = true;
        expect((await coordinator
          .requestAutomaticPush(
            'remotehosts')).ok)
          .assertFalse();
        expect(clock.hasScheduledTask())
          .assertTrue();
        const beforeRetry: number =
          executions;
        metadata.mode = 'error';
        clock.advanceAndFire(2000);
        await flushPromiseQueue();
        expect(executions)
          .assertEqual(beforeRetry);
        expect((await coordinator
          .requestAutomaticPush(
            'remotehosts')).ok)
          .assertFalse();
        expect(executions)
          .assertEqual(beforeRetry);
        expect(await coordinator.dispose(
          accountLease(), 1000))
          .assertTrue();

        const bootstrapHooks =
          new CoordinatorHooks();
        bootstrapHooks.restoredProbe =
          (): boolean =>
            store.hasRestoredNotUploaded();
        const bootstrap =
          new CloudSyncCoordinator(
            new FixedSelectionSource(
              ['remotehosts']),
            new ControlledRetryClock());
        expect(bootstrap.bind(
          accountLease(),
          accountBinding(),
          async (): Promise<boolean> =>
            true,
          (_tables: string[]): void => {
          },
          bootstrapHooks)).assertTrue();
        const blocked =
          await bootstrap
            .requestStartupPull();
        expect(blocked.ok).assertFalse();
        expect(blocked.failureKind)
          .assertEqual(
            'restore_pending');
        expect(await bootstrap.dispose(
          accountLease(), 1000))
          .assertTrue();
      });

    it('lets_explicit_upload_resolve_restore_quarantine_but_keeps_automatic_closed',
      0, async (): Promise<void> => {
        const hooks: CoordinatorHooks =
          quarantinedCoordinatorHooks();
        const coordinator =
          new CloudSyncCoordinator(
            new FixedSelectionSource(
              ['remotehosts', 'sshkeys']),
            new ControlledRetryClock());
        const executions: string[] = [];
        expect(coordinator.bind(
          accountLease(),
          accountBinding(),
          async (
            table: string,
            direction: CloudSyncDirection,
            label: string
          ): Promise<boolean> => {
            executions.push(
              label + ':' + direction + ':' + table);
            return true;
          },
          (_tables: string[]): void => {
          },
          hooks)).assertTrue();

        expect((await coordinator
          .requestStartupPull()).failureKind)
          .assertEqual('restore_pending');
        const beforeAutomatic: number =
          executions.length;
        expect((await coordinator
          .requestAutomaticPush(
            'remotehosts')).ok).assertTrue();
        expect(executions.length)
          .assertEqual(beforeAutomatic);

        const uploaded: CloudSyncOperationResult =
          await coordinator.requestManualUpload();
        expect(uploaded.ok).assertTrue();
        expect(executions.some(
          (event: string): boolean =>
            event.indexOf(
              'manualUpload:nativeFirst:remotehosts') >= 0))
          .assertTrue();
        expect(hooks.restoreResolutionCount)
          .assertEqual(1);
        expect(hooks.restoredNotUploaded)
          .assertFalse();
        expect(hooks.durableState !== null &&
          hooks.durableState.phase === 'ready')
          .assertTrue();
        expect(hooks.restoreResolutionTables
          .indexOf('remotehosts') >= 0)
          .assertTrue();
        expect(hooks.restoreResolutionTables
          .indexOf('sshkeys') >= 0)
          .assertTrue();
        expect(await coordinator.dispose(
          accountLease(), 1000))
          .assertTrue();
      });

    it('keeps_restore_quarantine_after_terminal_failure_and_allows_explicit_retry',
      0, async (): Promise<void> => {
        const hooks: CoordinatorHooks =
          quarantinedCoordinatorHooks();
        const coordinator =
          new CloudSyncCoordinator(
            new FixedSelectionSource(
              ['remotehosts', 'sshkeys']),
            new ControlledRetryClock());
        let failSsh: boolean = true;
        expect(coordinator.bind(
          accountLease(),
          accountBinding(),
          async (
            table: string,
            _direction: CloudSyncDirection,
            _label: string
          ): Promise<boolean> =>
            !(failSsh && table === 'sshkeys'),
          (_tables: string[]): void => {
          },
          hooks)).assertTrue();

        const failed: CloudSyncOperationResult =
          await coordinator.requestManualUpload();
        expect(failed.ok).assertFalse();
        expect(hooks.restoreResolutionCount)
          .assertEqual(0);
        expect(hooks.restoredNotUploaded)
          .assertTrue();
        expect(hooks.durableState !== null &&
          hooks.durableState.phase ===
            'restore_quarantine')
          .assertTrue();

        failSsh = false;
        expect((await coordinator
          .requestManualUpload()).ok)
          .assertTrue();
        expect(hooks.restoreResolutionCount)
          .assertEqual(1);
        expect(await coordinator.dispose(
          accountLease(), 1000))
          .assertTrue();
      });

    it('keeps_quarantine_when_atomic_restore_completion_rejects_uncovered_tables',
      0, async (): Promise<void> => {
        const hooks: CoordinatorHooks =
          quarantinedCoordinatorHooks();
        hooks.restoreResolutionAllowed = false;
        const coordinator =
          new CloudSyncCoordinator(
            new FixedSelectionSource(
              ['remotehosts']),
            new ControlledRetryClock());
        expect(coordinator.bind(
          accountLease(),
          accountBinding(),
          async (): Promise<boolean> => true,
          (_tables: string[]): void => {
          },
          hooks)).assertTrue();

        const result: CloudSyncOperationResult =
          await coordinator.requestManualDownload();
        expect(result.ok).assertFalse();
        expect(result.failureKind)
          .assertEqual('restore_pending');
        expect(hooks.restoredNotUploaded)
          .assertTrue();
        expect(hooks.durableState !== null &&
          hooks.durableState.phase ===
            'restore_quarantine')
          .assertTrue();
        expect(await coordinator.dispose(
          accountLease(), 1000))
          .assertTrue();
      });

    it('resolves_unselected_restore_markers_as_local_only_after_explicit_direction',
      0, async (): Promise<void> => {
        const hooks: CoordinatorHooks =
          quarantinedCoordinatorHooks();
        hooks.pendingRestoredTables = [
          'remotehosts', 'sshkeys',
          'vncrecordv2'
        ];
        const coordinator =
          new CloudSyncCoordinator(
            new FixedSelectionSource([]),
            new ControlledRetryClock());
        let executions: number = 0;
        expect(coordinator.bind(
          accountLease(), accountBinding(),
          async (): Promise<boolean> => {
            executions++;
            return true;
          },
          (_tables: string[]): void => {},
          hooks)).assertTrue();

        const result: CloudSyncOperationResult =
          await coordinator.requestManualUpload();
        expect(result.ok).assertTrue();
        expect(executions).assertEqual(0);
        expect(hooks.restoreResolutionTables.join(','))
          .assertEqual(
            'remotehosts,sshkeys,vncrecordv2');
        expect(hooks.durableState !== null &&
          hooks.durableState.phase === 'ready')
          .assertTrue();
        expect(await coordinator.dispose(
          accountLease(), 1000)).assertTrue();
      });

    it('atomically_releases_durable_quarantine_when_restore_died_before_writing_markers',
      0, async (): Promise<void> => {
        const hooks: CoordinatorHooks =
          quarantinedCoordinatorHooks();
        hooks.restoredNotUploaded = false;
        hooks.pendingRestoredTables = [];
        const coordinator =
          new CloudSyncCoordinator(
            new FixedSelectionSource([]),
            new ControlledRetryClock());
        expect(coordinator.bind(
          accountLease(), accountBinding(),
          async (): Promise<boolean> => false,
          (_tables: string[]): void => {},
          hooks)).assertTrue();

        const result: CloudSyncOperationResult =
          await coordinator.requestManualDownload();
        expect(result.ok).assertTrue();
        expect(hooks.restoreResolutionCount)
          .assertEqual(1);
        expect(hooks.restoreResolutionTables.length)
          .assertEqual(0);
        expect(hooks.durableState !== null &&
          hooks.durableState.phase === 'ready')
          .assertTrue();
        expect(await coordinator.dispose(
          accountLease(), 1000)).assertTrue();
      });

    it('syncs_only_selected_restore_tables_but_atomically_covers_every_marker',
      0, async (): Promise<void> => {
        const hooks: CoordinatorHooks =
          quarantinedCoordinatorHooks();
        hooks.pendingRestoredTables = [
          'remotehosts', 'sshkeys',
          'vncrecordv2'
        ];
        hooks.selectionBlocked =
          (table: string): boolean =>
            table === 'remotehosts';
        const coordinator =
          new CloudSyncCoordinator(
            new FixedSelectionSource(
              ['remotehosts']),
            new ControlledRetryClock());
        const executions: string[] = [];
        expect(coordinator.bind(
          accountLease(), accountBinding(),
          async (table: string,
            direction: CloudSyncDirection):
            Promise<boolean> => {
            executions.push(
              direction + ':' + table);
            return true;
          },
          (_tables: string[]): void => {},
          hooks)).assertTrue();

        expect((await coordinator
          .requestManualUpload()).ok)
          .assertTrue();
        expect(executions.join(','))
          .assertEqual(
            'nativeFirst:remotehosts');
        expect(hooks.restoreResolutionTables.join(','))
          .assertEqual(
            'remotehosts,sshkeys,vncrecordv2');
        expect(await coordinator.dispose(
          accountLease(), 1000)).assertTrue();
      });

    it('serializes_ordinary_and_vnc_restore_legs_before_an_opposite_direction',
      0, async (): Promise<void> => {
        const hooks: CoordinatorHooks =
          quarantinedCoordinatorHooks();
        hooks.pendingRestoredTables = [
          'remotehosts', 'vncrecordv2'
        ];
        const coordinator =
          new CloudSyncCoordinator(
            new FixedSelectionSource([
              'remotehosts', 'vncrecordv2'
            ]),
            new ControlledRetryClock(),
            new FixedVncSelectionSource(true));
        const events: string[] = [];
        expect(coordinator.bind(
          accountLease(), accountBinding(),
          async (table: string,
            direction: CloudSyncDirection):
            Promise<boolean> => {
            events.push(direction + ':' + table);
            return true;
          },
          (_tables: string[]): void => {},
          hooks)).assertTrue();

        const upload:
          Promise<CloudSyncOperationResult> =
          coordinator.requestManualUpload();
        const download:
          Promise<CloudSyncOperationResult> =
          coordinator.requestManualDownload();
        const uploadResult:
          CloudSyncOperationResult = await upload;
        const downloadResult:
          CloudSyncOperationResult = await download;
        expect(uploadResult.ok).assertTrue();
        expect(downloadResult.ok).assertTrue();
        expect(events.join(','))
          .assertEqual(
            'nativeFirst:remotehosts,' +
            'nativeFirst:vncrecordv2,' +
            'cloudFirst:remotehosts,' +
            'cloudFirst:vncrecordv2');
        expect(hooks.restoreResolutionCount)
          .assertEqual(1);
        expect(await coordinator.dispose(
          accountLease(), 1000)).assertTrue();
      });

    it('keeps_restore_quarantined_when_vnc_leg_fails_then_reruns_both_legs_on_retry',
      0, async (): Promise<void> => {
        const hooks: CoordinatorHooks =
          quarantinedCoordinatorHooks();
        hooks.pendingRestoredTables = [
          'remotehosts', 'vncrecordv2'
        ];
        const coordinator =
          new CloudSyncCoordinator(
            new FixedSelectionSource([
              'remotehosts', 'vncrecordv2'
            ]),
            new ControlledRetryClock(),
            new FixedVncSelectionSource(true));
        let failVnc: boolean = true;
        const events: string[] = [];
        expect(coordinator.bind(
          accountLease(), accountBinding(),
          async (table: string,
            direction: CloudSyncDirection):
            Promise<boolean> => {
            events.push(direction + ':' + table);
            return !(failVnc &&
              table === 'vncrecordv2');
          },
          (_tables: string[]): void => {},
          hooks)).assertTrue();

        const failed: CloudSyncOperationResult =
          await coordinator.requestManualUpload();
        expect(failed.ok).assertFalse();
        expect(events.join(','))
          .assertEqual(
            'nativeFirst:remotehosts,' +
            'nativeFirst:vncrecordv2');
        expect(hooks.restoreResolutionCount)
          .assertEqual(0);
        expect(hooks.restoredNotUploaded)
          .assertTrue();
        expect(hooks.durableState !== null &&
          hooks.durableState.phase ===
            'restore_quarantine')
          .assertTrue();

        failVnc = false;
        const retried: CloudSyncOperationResult =
          await coordinator.requestManualUpload();
        expect(retried.ok).assertTrue();
        expect(events.join(','))
          .assertEqual(
            'nativeFirst:remotehosts,' +
            'nativeFirst:vncrecordv2,' +
            'nativeFirst:remotehosts,' +
            'nativeFirst:vncrecordv2');
        expect(hooks.restoreResolutionCount)
          .assertEqual(1);
        expect(hooks.restoredNotUploaded)
          .assertFalse();
        expect(hooks.durableState !== null &&
          hooks.durableState.phase === 'ready')
          .assertTrue();
        expect(await coordinator.dispose(
          accountLease(), 1000)).assertTrue();
      });

    it('runs_the_exact_restore_resolution_transaction_and_releases_covered_barriers',
      0, (): void => {
        const port: FakeRestoreResolutionPort =
          seededRestoreResolutionPort();
        const tables: string[] = [
          'remotehosts', 'sshkeys',
          'vncrecordv2'
        ];
        const result: CloudRestoreResolutionResult =
          completeCloudRestoreResolution(
            '{"phase":"ready"}',
            ['remotehosts', 'vncrecordv2'],
            tables, port);
        expect(result.ok).assertTrue();
        expect(result.committed).assertTrue();
        expect(port.commitCount).assertEqual(1);
        expect(port.rollbackCount).assertEqual(0);
        expect(port.value(
          CLOUD_BOOTSTRAP_COMPLETED_KEY))
          .assertEqual('1');
        expect(port.value(
          CLOUD_SYNC_DURABLE_STATE_KEY))
          .assertEqual('{"phase":"ready"}');
        expect(port.has(
          RESTORED_NOT_UPLOADED_KEY))
          .assertFalse();
        expect(port.has(
          RESTORED_NOT_UPLOADED_TABLE_PREFIX +
            'remotehosts')).assertFalse();
        expect(port.has(
          RESTORED_NOT_UPLOADED_TABLE_PREFIX +
            'vncrecordv2')).assertFalse();
        expect(port.value(
          CLOUD_SELECTION_REENABLE_BARRIERS_KEY))
          .assertEqual(
            '{"sshkeys":"pending_pull"}');
      });

    it('commits_ready_state_for_consistent_empty_marker_set_after_process_death',
      0, (): void => {
        const port: FakeRestoreResolutionPort =
          new FakeRestoreResolutionPort();
        const result: CloudRestoreResolutionResult =
          completeCloudRestoreResolution(
            '{"phase":"ready"}', [],
            ['remotehosts', 'vncrecordv2'],
            port);
        expect(result.ok).assertTrue();
        expect(result.committed).assertTrue();
        expect(port.commitCount).assertEqual(1);
        expect(port.value(
          CLOUD_SYNC_DURABLE_STATE_KEY))
          .assertEqual('{"phase":"ready"}');
      });

    it('writes_the_full_restore_global_and_per_table_marker_contract',
      0, (): void => {
        const values: Record<string, string> = {};
        const tables: string[] = [
          'remotehosts', 'sshkeys',
          'vncrecordv2'
        ];
        expect(writeFullRestoreQuarantineMarkers(
          tables,
          (key: string, value: string):
            boolean => {
            values[key] = value;
            return true;
          })).assertTrue();
        expect(values[
          RESTORED_NOT_UPLOADED_KEY])
          .assertEqual('1');
        for (let i = 0; i < tables.length; i++) {
          expect(values[
            RESTORED_NOT_UPLOADED_TABLE_PREFIX +
              tables[i]]).assertEqual('1');
        }
      });

    it('upgrades_legacy_global_only_and_orphan_table_restore_markers_fail_closed',
      0, (): void => {
        const tables: string[] = [
          'remotehosts', 'sshkeys',
          'vncrecordv2'
        ];
        const globalOnly:
          FakeRestoreResolutionPort =
          new FakeRestoreResolutionPort();
        globalOnly.seed(
          RESTORED_NOT_UPLOADED_KEY, '1');
        expect((pendingRestoreResolutionTables(
          tables,
          (key: string):
            CloudMetadataReadResult =>
            globalOnly.readMetadata(key)) || [])
          .join(',')).assertEqual(
            tables.join(','));

        const tableOnly:
          FakeRestoreResolutionPort =
          new FakeRestoreResolutionPort();
        tableOnly.seed(
          RESTORED_NOT_UPLOADED_TABLE_PREFIX +
            'sshkeys', '1');
        expect((pendingRestoreResolutionTables(
          tables,
          (key: string):
            CloudMetadataReadResult =>
            tableOnly.readMetadata(key)) || [])
          .join(',')).assertEqual('sshkeys');
      });

    it('does_not_infer_a_new_optional_table_from_an_old_global_restore_marker',
      0, (): void => {
        const coreTables: string[] = [
          'remotehosts', 'sshkeys',
          'vncrecordv2'
        ];
        const allTables: string[] =
          coreTables.concat(['moonlightrecordv1']);
        const globalOnly:
          FakeRestoreResolutionPort =
          new FakeRestoreResolutionPort();
        globalOnly.seed(
          RESTORED_NOT_UPLOADED_KEY, '1');
        expect((pendingRestoreResolutionTables(
          allTables,
          (key: string):
            CloudMetadataReadResult =>
            globalOnly.readMetadata(key),
          coreTables) || []).join(','))
          .assertEqual(coreTables.join(','));

        const explicitOptional:
          FakeRestoreResolutionPort =
          new FakeRestoreResolutionPort();
        explicitOptional.seed(
          RESTORED_NOT_UPLOADED_TABLE_PREFIX +
            'moonlightrecordv1', '1');
        expect((pendingRestoreResolutionTables(
          allTables,
          (key: string):
            CloudMetadataReadResult =>
            explicitOptional.readMetadata(key),
          coreTables) || []).join(','))
          .assertEqual('moonlightrecordv1');
      });

    it('rolls_back_every_restore_resolution_precommit_fault',
      0, (): void => {
        const faults: RestoreResolutionFault[] = [
          'begin', 'read', 'write-bootstrap',
          'write-durable', 'delete-global',
          'delete-table', 'write-barrier',
          'delete-barrier', 'commit'
        ];
        const tables: string[] = [
          'remotehosts', 'sshkeys',
          'vncrecordv2'
        ];
        for (let i = 0; i < faults.length; i++) {
          const port: FakeRestoreResolutionPort =
            seededRestoreResolutionPort(
              faults[i] !== 'delete-barrier');
          port.fault = faults[i];
          const result: CloudRestoreResolutionResult =
            completeCloudRestoreResolution(
              '{"phase":"ready"}',
              ['remotehosts', 'vncrecordv2'],
              tables, port);
          expect(result.ok).assertFalse();
          expect(result.committed).assertFalse();
          expect(port.has(
            RESTORED_NOT_UPLOADED_KEY))
            .assertTrue();
          if (faults[i] === 'begin') {
            expect(port.rollbackCount)
              .assertEqual(0);
          } else {
            expect(port.rollbackCount)
              .assertEqual(1);
          }
        }
      });

    it('fails_closed_on_uncovered_or_malformed_restore_markers_and_postcommit_readback',
      0, (): void => {
        const tables: string[] = [
          'remotehosts', 'vncrecordv2'
        ];
        const uncovered:
          FakeRestoreResolutionPort =
          seededRestoreResolutionPort(false);
        expect(completeCloudRestoreResolution(
          '{"phase":"ready"}',
          ['remotehosts'], tables,
          uncovered).ok).assertFalse();
        expect(uncovered.rollbackCount)
          .assertEqual(1);

        const malformed:
          FakeRestoreResolutionPort =
          seededRestoreResolutionPort(false);
        malformed.seed(
          RESTORED_NOT_UPLOADED_TABLE_PREFIX +
            'remotehosts', 'bad');
        expect(pendingRestoreResolutionTables(
          tables,
          (key: string):
            CloudMetadataReadResult =>
            malformed.readMetadata(key)) === null)
          .assertTrue();

        const postCommit:
          FakeRestoreResolutionPort =
          seededRestoreResolutionPort(false);
        postCommit.fault = 'post-read';
        const committed:
          CloudRestoreResolutionResult =
          completeCloudRestoreResolution(
            '{"phase":"ready"}',
            tables, tables, postCommit);
        expect(committed.ok).assertFalse();
        expect(committed.committed).assertTrue();
        expect(postCommit.commitCount)
          .assertEqual(1);
        expect(postCommit.rollbackCount)
          .assertEqual(0);
      });

    it('rejects_every_structurally_invalid_or_future_selection_barrier',
      0, (): void => {
        const malformed: string[] = [
          '[]', '"text"', '42',
          '{"future":"pending_pull"}',
          '{"remotehosts":"bad"}'
        ];
        const tables: string[] = [
          'remotehosts', 'vncrecordv2'
        ];
        for (let i = 0;
          i < malformed.length; i++) {
          const port:
            FakeRestoreResolutionPort =
            seededRestoreResolutionPort(false);
          port.seed(
            CLOUD_SELECTION_REENABLE_BARRIERS_KEY,
            malformed[i]);
          const result:
            CloudRestoreResolutionResult =
            completeCloudRestoreResolution(
              '{"phase":"ready"}',
              tables, tables, port);
          expect(result.ok).assertFalse();
          expect(result.committed).assertFalse();
          expect(port.rollbackCount)
            .assertEqual(1);
          expect(port.has(
            RESTORED_NOT_UPLOADED_KEY))
            .assertTrue();
        }
      });

    it('treats_any_present_or_unreadable_global_restore_marker_as_quarantine',
      0, (): void => {
        const metadata =
          new MetadataMapQueryPort();
        const store = new CloudStore({
          metadataQuery: metadata
        });
        expect(store.hasRestoredNotUploaded())
          .assertFalse();
        metadata.set(
          RESTORED_NOT_UPLOADED_KEY,
          'malformed');
        expect(store.hasRestoredNotUploaded())
          .assertTrue();
        metadata.setError(
          RESTORED_NOT_UPLOADED_KEY, true);
        expect(store.hasRestoredNotUploaded())
          .assertTrue();
      });

    it('drives_CloudStore_authoritative_completion_in_one_transaction',
      0, (): void => {
        const metadata =
          new MetadataMapQueryPort();
        const store =
          new CloudStore({
            metadataQuery: metadata
          });
        const port =
          new FakeVncCompletionPort(
            store, metadata);
        expect(
          completeVncAuthoritativeCloudFirst(
            ['vncrecordv2'], port).ok)
          .assertTrue();
        expect(port.events.join(','))
          .assertEqual(
            'begin,1:rebase,' +
            '1:journal:vncrecord,' +
            '1:delete,1:commit,publish');
        expect(port
          .generalCheckpointPresent())
          .assertFalse();
        expect(port.vncCheckpointStage())
          .assertEqual('authoritative');
        expect(port.journalState)
          .assertEqual('replayed');
        expect(port.snapshotCleared)
          .assertTrue();
      });

    it('rolls_back_every_precommit_fault_without_publishing_ready_state',
      0, (): void => {
        const faults:
          CompletionFault[] = [
          'begin', 'rebase', 'journal',
          'delete', 'commit'
        ];
        for (let i = 0;
          i < faults.length; i++) {
          const metadata =
            new MetadataMapQueryPort();
          const store =
            new CloudStore({
              metadataQuery: metadata
            });
          const port =
            new FakeVncCompletionPort(
              store, metadata);
          port.fault = faults[i];
          expect(
            completeVncAuthoritativeCloudFirst(
              ['vncrecordv2'], port).ok)
            .assertFalse();
          if (faults[i] === 'begin') {
            expect(port.events.indexOf(
              '1:rollback'))
              .assertEqual(-1);
          } else {
            expect(port.events.indexOf(
              '1:rollback') >= 0)
              .assertTrue();
          }
          expect(port
            .generalCheckpointPresent())
            .assertTrue();
          expect(port.vncCheckpointStage())
            .assertEqual('prepared');
          expect(port.journalState)
            .assertEqual('captured');
          expect(port.snapshotCleared)
            .assertFalse();
        }
      });

    it('keeps_committed_authoritative_recovery_model_when_postcommit_readback_errors',
      0, (): void => {
        const metadata =
          new MetadataMapQueryPort();
        const store =
          new CloudStore({
            metadataQuery: metadata
          });
        const port =
          new FakeVncCompletionPort(
            store, metadata);
        port.postCommitReadError = true;
        expect(
          completeVncAuthoritativeCloudFirst(
            ['vncrecordv2'], port).ok)
          .assertFalse();
        expect(port.events.indexOf(
          '1:commit') >= 0)
          .assertTrue();
        expect(port.events.indexOf(
          '1:rollback'))
          .assertEqual(-1);
        expect(port
          .generalCheckpointPresent())
          .assertFalse();
        expect(port.vncCheckpointStage())
          .assertEqual('authoritative');
        expect(port.journalState)
          .assertEqual('replayed');
        expect(port.snapshotCleared)
          .assertFalse();
      });

    it('retires_legacy_vnc_scope_checkpoint_without_blocking_account_startup',
      0, async (): Promise<void> => {
        const successMetadata =
          new MetadataMapQueryPort();
        const firstProcessStore =
          new CloudStore({
            metadataQuery: successMetadata
          });
        const completion =
          new FakeVncCompletionPort(
            firstProcessStore,
            successMetadata);
        expect(
          completeVncAuthoritativeCloudFirst(
            ['vncrecordv2'],
            completion).ok)
          .assertTrue();
        expect(completion
          .vncCheckpointStage())
          .assertEqual('authoritative');

        const recoveryIo =
          new FakeVncStartupRecoveryIo(
            successMetadata);
        const restartedStore =
          CloudStore
            .createStartupRecoveryVerificationStore(
              recoveryIo);
        await restartedStore.init(null);
        expect(restartedStore.isReady())
          .assertTrue();
        expect(recoveryIo
          .recoveredStage)
          .assertEqual('');
        expect(recoveryIo
          .recoveredCallback)
          .assertTrue();
        expect(recoveryIo
          .checkpointPresent())
          .assertFalse();
        expect(recoveryIo
          .stagedScopes.length)
          .assertEqual(0);
        expect(recoveryIo.events.join(','))
          .assertEqual(
            'begin,barrier:vncrecordv2,delete:' +
            VNC_SELECTION_REENABLE_TRANSACTION_KEY +
            ',delete:cloud_bootstrap_completed_v1,' +
            'commit,lifecycle,publish,recovered');
        expect(recoveryIo
          .recoveryRequired)
          .assertFalse();

        const failures:
          RecoveryFault[] = [
          'begin', 'barrier', 'delete',
          'commit', 'lifecycle'
        ];
        for (let i = 0;
          i < failures.length; i++) {
          const failedMetadata =
            new MetadataMapQueryPort();
          const failedStore =
            new CloudStore({
              metadataQuery:
                failedMetadata
            });
          const failedCompletion =
            new FakeVncCompletionPort(
              failedStore,
              failedMetadata);
          expect(
            completeVncAuthoritativeCloudFirst(
              ['vncrecordv2'],
              failedCompletion).ok)
            .assertTrue();
          const failedIo =
            new FakeVncStartupRecoveryIo(
              failedMetadata);
          failedIo.fault = failures[i];
          const failedStartup =
            CloudStore
              .createStartupRecoveryVerificationStore(
                failedIo);
          await failedStartup.init(null);
          expect(failedStartup.isReady())
            .assertTrue();
          expect(failedIo
            .checkpointPresent())
            .assertEqual(
              failures[i] !== 'lifecycle');
          expect(failedIo
            .recoveryRequired)
            .assertTrue();
          expect(failedIo
            .snapshotPublished)
            .assertFalse();
          expect(failedIo
            .recoveredCallback)
            .assertFalse();
          expect(failedIo.events.indexOf(
            'fail_closed') >= 0)
            .assertTrue();
        }
      });

    it('rejects_semantically_malformed_vnc_barriers_before_and_after_commit',
      0, (): void => {
        const malformed:
          string[] = [
          '{"vncrecord":"corrupt"}',
          '{"vncrecord":null}',
          '{"vncrecord":{}}',
          '{"vncrecord":[]}',
          '[]',
          '"text"',
          '42',
          'null'
        ];
        for (let i = 0;
          i < malformed.length; i++) {
          const beforeMetadata =
            new MetadataMapQueryPort();
          const beforeStore =
            new CloudStore({
              metadataQuery:
                beforeMetadata
            });
          const beforePort =
            new FakeVncFinalizationPort(
              beforeStore,
              beforeMetadata);
          beforeMetadata.set(
            CLOUD_SELECTION_REENABLE_BARRIERS_KEY,
            malformed[i]);
          const beforeRead =
            readVncSelectionBarrierPhase(
              (key: string):
                CloudMetadataReadResult =>
                beforeStore
                  .readLocalMetadataState(key));
          expect(beforeRead.readable)
            .assertFalse();
          expect(finalizeVncSelectionReenable(
            beforePort).ok)
            .assertFalse();
          expect(beforePort.events.length)
            .assertEqual(0);
          expect(beforePort.uploadRequested)
            .assertFalse();

          const afterMetadata =
            new MetadataMapQueryPort();
          const afterStore =
            new CloudStore({
              metadataQuery:
                afterMetadata
            });
          const afterPort =
            new FakeVncFinalizationPort(
              afterStore,
              afterMetadata);
          afterPort
            .overridePostCommitBarrier = true;
          afterPort.postCommitBarrierRaw =
            malformed[i];
          expect(finalizeVncSelectionReenable(
            afterPort).ok)
            .assertFalse();
          expect(afterPort.events
            .indexOf('commit') >= 0)
            .assertTrue();
          expect(afterPort.uploadRequested)
            .assertFalse();
        }

        const absent:
          string[] = [
          '{}',
          '{"remotehosts":"pending_pull"}'
        ];
        for (let i = 0;
          i < absent.length; i++) {
          const metadata =
            new MetadataMapQueryPort();
          const store =
            new CloudStore({
              metadataQuery: metadata
            });
          metadata.set(
            CLOUD_SELECTION_REENABLE_BARRIERS_KEY,
            absent[i]);
          const read =
            readVncSelectionBarrierPhase(
              (key: string):
                CloudMetadataReadResult =>
                store.readLocalMetadataState(
                  key));
          expect(read.readable).assertTrue();
          expect(read.phase === null)
            .assertTrue();
        }

        const phases:
          string[] = [
          'pending_pull',
          'pull_complete',
          'promotion_complete'
        ];
        for (let i = 0;
          i < phases.length; i++) {
          const metadata =
            new MetadataMapQueryPort();
          const store =
            new CloudStore({
              metadataQuery: metadata
            });
          metadata.set(
            CLOUD_SELECTION_REENABLE_BARRIERS_KEY,
            vncBarrierRaw(phases[i]));
          const read =
            readVncSelectionBarrierPhase(
              (key: string):
                CloudMetadataReadResult =>
                store.readLocalMetadataState(
                  key));
          expect(read.readable).assertTrue();
          expect(read.phase)
            .assertEqual(phases[i]);
        }

        const noVncKeyMetadata =
          new MetadataMapQueryPort();
        const noVncKeyStore =
          new CloudStore({
            metadataQuery:
              noVncKeyMetadata
          });
        const noVncKeyPort =
          new FakeVncFinalizationPort(
            noVncKeyStore,
            noVncKeyMetadata);
        noVncKeyPort
          .overridePostCommitBarrier = true;
        noVncKeyPort.postCommitBarrierRaw =
          '{}';
        expect(finalizeVncSelectionReenable(
          noVncKeyPort).ok)
          .assertTrue();
        expect(noVncKeyPort.uploadRequested)
          .assertTrue();
      });

    it('metadata_errors_block_actual_finalization_promotion_and_postcommit_upload',
      0, (): void => {
        const preCheckpointMetadata =
          new MetadataMapQueryPort();
        const preCheckpointStore =
          new CloudStore({
            metadataQuery:
              preCheckpointMetadata
          });
        const preCheckpointPort =
          new FakeVncFinalizationPort(
            preCheckpointStore,
            preCheckpointMetadata);
        preCheckpointMetadata.setError(
          VNC_SELECTION_REENABLE_TRANSACTION_KEY,
          true);
        expect(finalizeVncSelectionReenable(
          preCheckpointPort).ok)
          .assertFalse();
        expect(preCheckpointPort
          .events.length)
          .assertEqual(0);
        expect(preCheckpointPort
          .uploadRequested)
          .assertFalse();

        const preBarrierMetadata =
          new MetadataMapQueryPort();
        const preBarrierStore =
          new CloudStore({
            metadataQuery:
              preBarrierMetadata
          });
        const preBarrierPort =
          new FakeVncFinalizationPort(
            preBarrierStore,
            preBarrierMetadata);
        preBarrierMetadata.setError(
          CLOUD_SELECTION_REENABLE_BARRIERS_KEY,
          true);
        expect(finalizeVncSelectionReenable(
          preBarrierPort).ok)
          .assertFalse();
        expect(preBarrierPort.events
          .indexOf('release'))
          .assertEqual(-1);
        expect(preBarrierPort
          .uploadRequested)
          .assertFalse();

        const checkpointMetadata =
          new MetadataMapQueryPort();
        const checkpointStore =
          new CloudStore({
            metadataQuery:
              checkpointMetadata
          });
        const checkpointPort =
          new FakeVncFinalizationPort(
            checkpointStore,
            checkpointMetadata);
        checkpointPort.postCommitErrorKey =
          VNC_SELECTION_REENABLE_TRANSACTION_KEY;
        expect(finalizeVncSelectionReenable(
          checkpointPort).ok)
          .assertFalse();
        expect(checkpointPort.events
          .indexOf('commit') >= 0)
          .assertTrue();
        expect(checkpointPort
          .uploadRequested)
          .assertFalse();

        const barrierMetadata =
          new MetadataMapQueryPort();
        const barrierStore =
          new CloudStore({
            metadataQuery: barrierMetadata
          });
        const barrierPort =
          new FakeVncFinalizationPort(
            barrierStore,
            barrierMetadata);
        barrierPort.postCommitErrorKey =
          CLOUD_SELECTION_REENABLE_BARRIERS_KEY;
        expect(finalizeVncSelectionReenable(
          barrierPort).ok)
          .assertFalse();
        expect(barrierPort
          .uploadRequested)
          .assertFalse();

        const successMetadata =
          new MetadataMapQueryPort();
        const successStore =
          new CloudStore({
            metadataQuery: successMetadata
          });
        const successPort =
          new FakeVncFinalizationPort(
            successStore,
            successMetadata);
        expect(finalizeVncSelectionReenable(
          successPort).ok)
          .assertTrue();
        expect(successPort.events.join(','))
          .assertEqual(
            'prepare,begin,pull_complete,' +
            'promote,promotion_complete,' +
            'release,delete,commit,upload');
        expect(successMetadata.has(
          VNC_SELECTION_REENABLE_TRANSACTION_KEY))
          .assertFalse();
        expect(successMetadata.has(
          CLOUD_SELECTION_REENABLE_BARRIERS_KEY))
          .assertFalse();
      });
  });
}
