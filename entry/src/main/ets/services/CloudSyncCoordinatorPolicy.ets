import { CloudSyncDirection, cloudPullOrder } from './CloudSyncPolicy';
import { effectiveCloudSyncTables } from './CloudSyncSelectionPolicy';

export type CloudSyncSource =
  'startup' | 'foreground' | 'cloudEvent' | 'automaticPush' | 'manualUpload' | 'manualDownload' | 'localRestore';

export const CLOUD_SYNC_MAX_RETRY_ATTEMPTS: number = 3;

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
  'cloud_service' | 'network' | 'unknown';

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
  return kind === 'version_conflict' || kind === 'empty_snapshot' || kind === 'tombstone_cleanup';
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
  if (kind === 'cloud_service') {
    return '华为云空间当前不可用，请确认账号、云空间服务和系统云同步开关。';
  }
  if (kind === 'network') {
    return '云同步未完成，请检查网络后重试。';
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
 * System auto-sync would synchronize every registered distributed table and
 * bypass the application's local table-selection policy. The app therefore
 * explicitly invokes cloudSync through CloudSyncCoordinator.
 */
export function cloudDistributedTableAutoSync(): boolean {
  return false;
}

/** A destructive pull or local restore owns the local RDB until it settles. */
export function cloudLocalMutationAllowed(manualDownloadActive: boolean, localRestoreActive: boolean): boolean {
  return !manualDownloadActive && !localRestoreActive;
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

/** Returns -1 after the last allowed retry attempt. */
export function nextCloudSyncRetryDelayMs(attempt: number): number {
  if (attempt === 1) { return 1000; }
  if (attempt === 2) { return 5000; }
  if (attempt === 3) { return 30000; }
  return -1;
}
