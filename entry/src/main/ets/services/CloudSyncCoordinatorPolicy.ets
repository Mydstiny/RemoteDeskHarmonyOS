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

/** Returns -1 after the last allowed retry attempt. */
export function nextCloudSyncRetryDelayMs(attempt: number): number {
  if (attempt === 1) { return 1000; }
  if (attempt === 2) { return 5000; }
  if (attempt === 3) { return 30000; }
  return -1;
}
