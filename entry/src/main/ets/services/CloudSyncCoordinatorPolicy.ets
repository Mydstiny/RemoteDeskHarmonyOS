import { CloudSyncDirection, cloudPullOrder } from './CloudSyncPolicy';
import { effectiveCloudSyncTables } from './CloudSyncSelectionPolicy';

export type CloudSyncSource =
  'startup' | 'foreground' | 'cloudEvent' | 'automaticPush' | 'manualUpload' | 'manualDownload' | 'localRestore';

export const CLOUD_SYNC_MAX_RETRY_ATTEMPTS: number = 3;
export const CLOUD_SYNC_ACCEPT_TIMEOUT_MS: number = 15000;
export const CLOUD_SYNC_IDLE_TIMEOUT_MS: number = 45000;
export const CLOUD_SYNC_OVERALL_TIMEOUT_MS: number = 180000;

export interface CloudSyncRequest {
  source: CloudSyncSource;
  direction: CloudSyncDirection;
  tables: string[];
}

export interface CloudSyncRetryRecord {
  source: CloudSyncSource;
  direction: CloudSyncDirection;
  tables: string[];
  failedTables: string[];
  attempt: number;
  nextRetryAt: number;
}

export type CloudSyncFailureKind =
  'none' | 'version_conflict' | 'empty_snapshot' | 'tombstone_cleanup' |
  'unsafe_payload' | 'cloud_service' | 'network' | 'indeterminate' |
  'unknown';

export type CloudSyncWatchdogTimeoutKind =
  'none' | 'accept_timeout' | 'idle_timeout' | 'overall_timeout';

export interface CloudSyncWatchdogState {
  startedAt: number;
  lastSignalAt: number;
  signalObserved: boolean;
  settled: boolean;
}

export interface CloudSyncCallbackIdentity {
  operationId: number;
  storeInstanceId: number;
  generation: number;
}

/**
 * The first successful cloud-first snapshot is a durable device bootstrap
 * boundary. Automatic native-first uploads are not allowed to cross that
 * boundary, otherwise a newly installed device can publish its local default
 * rows before it has ever observed the shared cloud state.
 */
export type CloudSyncBootstrapState = 'pending' | 'ready';

export function shouldDeferAutomaticPushDuringBootstrap(
  bootstrapState: CloudSyncBootstrapState
): boolean {
  return bootstrapState === 'pending';
}

export function shouldUseCloudFirstForInitialBootstrap(
  bootstrapCompleted: boolean
): boolean {
  return !bootstrapCompleted;
}

/** Classify native/RDB messages before they reach retry and UI policy. */
export function classifyCloudSyncFailure(message: string): CloudSyncFailureKind {
  const normalized: string = (message || '').toUpperCase();
  if (normalized.indexOf('VERSION_CONFLICT') >= 0 ||
    normalized.indexOf('VERSION CONFLICT') >= 0) {
    return 'version_conflict';
  }
  if (normalized.indexOf('EMPTY_CLOUD_SNAPSHOT') >= 0) { return 'empty_snapshot'; }
  if (normalized.indexOf('TOMBSTONE_CLEANUP') >= 0 ||
    normalized.indexOf('CLEAN_DIRTY_DATA') >= 0) {
    return 'tombstone_cleanup';
  }
  if (normalized.indexOf('UNSAFE_CLOUD_PAYLOAD') >= 0 ||
    normalized.indexOf('PLAINTEXT_SECRET') >= 0) {
    return 'unsafe_payload';
  }
  if (normalized.indexOf('NETWORK') >= 0 || normalized.indexOf('TIMEOUT') >= 0 ||
    normalized.indexOf('OFFLINE') >= 0) {
    return 'network';
  }
  if (normalized.indexOf('CLOUD') >= 0 || normalized.indexOf('SERVICE') >= 0 ||
    normalized.indexOf('148000') >= 0 || normalized.indexOf('801') >= 0) {
    return 'cloud_service';
  }
  return 'unknown';
}

/**
 * A cloudSync call has three independently bounded phases:
 * - the platform must accept the call or emit progress;
 * - an accepted transfer must continue emitting progress;
 * - the whole transfer must eventually reach SYNC_FINISH.
 *
 * A watchdog expiry does not mean that HarmonyOS cancelled the native
 * transfer. The caller must quarantine the physical store until the matching
 * native terminal callback arrives.
 */
export function cloudSyncWatchdogTimeoutKind(
  state: CloudSyncWatchdogState,
  now: number
): CloudSyncWatchdogTimeoutKind {
  if (state.settled) { return 'none'; }
  if (now - state.startedAt >= CLOUD_SYNC_OVERALL_TIMEOUT_MS) {
    return 'overall_timeout';
  }
  if (!state.signalObserved &&
    now - state.startedAt >= CLOUD_SYNC_ACCEPT_TIMEOUT_MS) {
    return 'accept_timeout';
  }
  if (state.signalObserved &&
    now - state.lastSignalAt >= CLOUD_SYNC_IDLE_TIMEOUT_MS) {
    return 'idle_timeout';
  }
  return 'none';
}

export function cloudSyncWatchdogNextDelayMs(
  state: CloudSyncWatchdogState,
  now: number
): number {
  if (state.settled) { return -1; }
  const overallRemaining: number =
    CLOUD_SYNC_OVERALL_TIMEOUT_MS - (now - state.startedAt);
  const phaseRemaining: number = state.signalObserved
    ? CLOUD_SYNC_IDLE_TIMEOUT_MS - (now - state.lastSignalAt)
    : CLOUD_SYNC_ACCEPT_TIMEOUT_MS - (now - state.startedAt);
  return Math.max(1, Math.min(overallRemaining, phaseRemaining));
}

/**
 * Operation id prevents duplicate/older callbacks in one open store from
 * acting; store instance id prevents callbacks from a previous open of the
 * same file; generation prevents callbacks from a previous account session.
 */
export function cloudSyncCallbackIdentityMatches(
  expected: CloudSyncCallbackIdentity,
  candidate: CloudSyncCallbackIdentity
): boolean {
  return expected.operationId > 0 &&
    expected.storeInstanceId > 0 &&
    expected.generation > 0 &&
    candidate.operationId === expected.operationId &&
    candidate.storeInstanceId === expected.storeInstanceId &&
    candidate.generation === expected.generation;
}

/** A suspicious empty result must never replace existing local startup data. */
export function shouldRejectAutomaticEmptyCloudSnapshot(
  source: string, direction: CloudSyncDirection, beforeVisibleRows: number, afterVisibleRows: number
): boolean {
  return direction === 'cloudFirst' &&
    (source === 'startup' || source === 'foreground' || source === 'cloudEvent') &&
    beforeVisibleRows > 0 && afterVisibleRows === 0;
}

/** These failures must stop native-first retries until the user resolves them. */
export function shouldBlockAutomaticRetry(kind: CloudSyncFailureKind): boolean {
  return kind === 'version_conflict' || kind === 'empty_snapshot' ||
    kind === 'tombstone_cleanup' || kind === 'unsafe_payload';
}

export function cloudSyncFailureMessage(kind: CloudSyncFailureKind): string {
  if (kind === 'version_conflict') {
    return '云端版本冲突，已停止自动重试，未继续覆盖本地数据。请先下载并确认云端数据，再重新上传。';
  }
  if (kind === 'empty_snapshot') {
    return '检测到云端返回空快照，已保留本地数据，本次同步未应用。请确认华为账号和云空间后重试。';
  }
  if (kind === 'tombstone_cleanup') {
    return '云端删除记录清理未完成，已暂停自动同步。请检查网络后重试。';
  }
  if (kind === 'unsafe_payload') {
    return '检测到未加密或不完整的敏感云数据，已回滚本次下载并暂停自动同步。请先确认主密码和云端版本。';
  }
  if (kind === 'cloud_service') {
    return '华为云空间当前不可用，请确认账号、云空间服务和系统云同步开关。';
  }
  if (kind === 'network') {
    return '云同步未完成，请检查网络后重试。';
  }
  if (kind === 'indeterminate') {
    return '系统云同步回调超时，已暂停本地修改和账号切换，避免迟到数据覆盖。应用会在收到终态后自动核对；若长时间未恢复，请完全退出后重新打开应用。';
  }
  return '云同步未完成，数据未确认全部同步，请稍后重试。';
}

/** The originating business table identifies one automatic retry stream. */
export function automaticRetryKey(record: CloudSyncRetryRecord): string {
  for (let i = record.tables.length - 1; i >= 0; i--) {
    if (record.tables[i] !== 'cryptoparams') { return record.tables[i]; }
  }
  return 'cryptoparams';
}

/** Keep one durable retry per originating table without discarding other tables. */
export function upsertAutomaticRetryRecord(
  current: CloudSyncRetryRecord[], next: CloudSyncRetryRecord
): CloudSyncRetryRecord[] {
  const key: string = automaticRetryKey(next);
  const result: CloudSyncRetryRecord[] = [];
  for (let i = 0; i < current.length; i++) {
    if (automaticRetryKey(current[i]) !== key) { result.push(current[i]); }
  }
  result.push(next);
  return result;
}

export function isAutomaticRetryRecord(record: CloudSyncRetryRecord): boolean {
  return record.source === 'automaticPush' && record.direction === 'nativeFirst' &&
    record.tables.length > 0 && record.failedTables.length > 0 &&
    record.attempt >= 1 && record.attempt <= CLOUD_SYNC_MAX_RETRY_ATTEMPTS;
}

/**
 * A retry is a new automatic operation, so it must honor the user's current
 * selection.  A business-table retry is discarded altogether once that table
 * is deselected; cryptoparams never survives by itself for such a retry.
 */
export function retryTablesStillSelected(retryTables: string[], selectedBusinessTables: string[]): string[] {
  const selected: string[] = effectiveCloudSyncTables(selectedBusinessTables);
  let hasRequestedBusinessTable: boolean = false;
  let hasSelectedBusinessTable: boolean = false;
  for (let i = 0; i < retryTables.length; i++) {
    if (retryTables[i] !== 'cryptoparams') {
      hasRequestedBusinessTable = true;
      if (selected.indexOf(retryTables[i]) >= 0) { hasSelectedBusinessTable = true; }
    }
  }
  if (hasRequestedBusinessTable && !hasSelectedBusinessTable) { return []; }
  return retryTables.filter((table: string): boolean => selected.indexOf(table) >= 0);
}

/**
 * VNC uses one physical business table but its selection is kept in a
 * separate logical namespace.  The ordinary selector must never be able to
 * retain or resurrect a VNC retry by accident.
 */
export function retryVncTablesStillSelected(retryTables: string[], selectedVncTables: string[]): string[] {
  const selected: string[] = selectedVncTables.slice();
  const hasVncBusinessTable: boolean = retryTables.indexOf('vncrecord') >= 0;
  if (hasVncBusinessTable && selected.indexOf('vncrecord') < 0) { return []; }
  return retryTables.filter((table: string): boolean => selected.indexOf(table) >= 0);
}

/**
 * System auto-sync would synchronize every registered distributed table and
 * bypass the application's local table-selection policy. The app therefore
 * explicitly invokes cloudSync through CloudSyncCoordinator.
 */
export function cloudDistributedTableAutoSync(): boolean {
  return false;
}

/** A destructive pull or local restore owns the local RDB until it settles. */
export function cloudLocalMutationAllowed(manualDownloadActive: boolean, localRestoreActive: boolean,
  _startupSyncPending: boolean = false, _bootstrapCompleted: boolean = true,
  cloudDownloadActive: boolean = false, indeterminateTransferActive: boolean = false): boolean {
  // Local edits are independent from the cloud bootstrap. The bootstrap gate
  // only suppresses automatic native-first uploads; otherwise Safety-0 or an
  // unavailable cloud service would make an offline database permanently
  // read-only.
  return !manualDownloadActive && !localRestoreActive &&
    !cloudDownloadActive && !indeterminateTransferActive;
}

/** Freeze a user's selection in canonical pull/encryption order for one operation. */
export function snapshotCloudSyncTables(selectedBusinessTables: string[]): string[] {
  const selected: string[] = effectiveCloudSyncTables(selectedBusinessTables);
  return cloudPullOrder().filter((table: string): boolean => selected.indexOf(table) >= 0);
}

/** Automatic writes may be coalesced only when they target the same table. */
export function coalesceAutomaticPush(pendingTable: string, incomingTable: string): boolean {
  return pendingTable === incomingTable;
}

export function shouldReplayAutomaticPush(completedVersion: number, currentVersion: number): boolean {
  return currentVersion > completedVersion;
}

/** Progress.SYNC_FINISH is the only event that confirms the transfer settled. */
export function cloudSyncProgressFinished(schedule: number): boolean {
  return schedule === 2;
}

/** ProgressCode.SUCCESS is meaningful only on the terminal progress event. */
export function cloudSyncProgressSucceeded(schedule: number, code: number): boolean {
  return cloudSyncProgressFinished(schedule) && code === 0;
}

export interface CloudSyncStatisticSnapshot {
  successful: number;
  failed: number;
  remained: number;
}

export interface CloudSyncTableDetailsSnapshot {
  upload: CloudSyncStatisticSnapshot;
  download: CloudSyncStatisticSnapshot;
}

/** A successful code without complete target-table statistics is uncertain. */
export function cloudSyncTargetTableCompleted(
  details: Record<string, CloudSyncTableDetailsSnapshot> | null,
  table: string
): boolean {
  if (details === null || table.trim().length === 0) { return false; }
  const tableDetails: CloudSyncTableDetailsSnapshot | undefined = details[table];
  if (tableDetails === undefined || tableDetails.upload === undefined ||
    tableDetails.download === undefined) {
    return false;
  }
  const upload: CloudSyncStatisticSnapshot = tableDetails.upload;
  const download: CloudSyncStatisticSnapshot = tableDetails.download;
  return upload.failed === 0 && upload.remained === 0 &&
    download.failed === 0 && download.remained === 0;
}

/** API 23 reports the common operational failures through ProgressCode. */
export function classifyCloudSyncProgressCode(code: number): CloudSyncFailureKind {
  if (code === 2 || code === 7) { return 'network'; }
  if (code === 3 || code === 4 || code === 5 || code === 6) {
    return 'cloud_service';
  }
  return code === 0 ? 'none' : 'unknown';
}

/** Returns -1 after the last allowed retry attempt. */
export function nextCloudSyncRetryDelayMs(attempt: number): number {
  if (attempt === 1) { return 1000; }
  if (attempt === 2) { return 5000; }
  if (attempt === 3) { return 30000; }
  return -1;
}
