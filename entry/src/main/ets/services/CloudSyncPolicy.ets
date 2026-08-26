// Huawei Cloud Space owns the deployed Record Type schema. Do not bundle an
// `arkdata/cloud/cloud_schema.json` override in the HAP: the system prefers the
// HAP copy over the service schema, so a stale copy rejects otherwise valid
// uploads after any container schema revision.
import { MOONLIGHT_CLOUD_TABLE } from '../model/MoonlightRecord';

// These eight tables are the already-deployed compatibility baseline. Keep
// them separate so a missing optional Moonlight AGC table can never make an
// upgraded installation lose the cloud registration used by older releases.
export const CLOUD_SYNC_TABLES: string[] = [
  'cryptoparams',
  'usersettings',
  'remotehosts',
  'rdpcredentials',
  'rustdeskrelays',
  'sshkeys',
  'totpentries',
  'vncrecordv2'
];

export const OPTIONAL_CLOUD_SYNC_TABLES: string[] = [
  MOONLIGHT_CLOUD_TABLE
];

export interface CloudDistributedRegistrationPlan {
  /** Already deployed tables that must remain usable after every upgrade. */
  baseline: string[];
  /** Optional tables are attempted only as a superset of the baseline. */
  optionalSuperset: string[];
}

export type CloudSyncOperation = 'upload' | 'download' | 'refresh';
export type CloudSyncDirection = 'cloudFirst' | 'nativeFirst';
export type CloudSyncExecution = 'startupPull' | 'manualDownload' | 'manualUpload' | 'automaticPush';

export function cloudSyncTableNames(): string[] {
  return CLOUD_SYNC_TABLES.concat(OPTIONAL_CLOUD_SYNC_TABLES);
}

export function coreCloudSyncTableNames(): string[] {
  return CLOUD_SYNC_TABLES.slice();
}

export function optionalCloudSyncTableNames(): string[] {
  return OPTIONAL_CLOUD_SYNC_TABLES.slice();
}

/**
 * Registration is deliberately two-stage. Calling the platform with the
 * optional superset before the deployed baseline would let a missing new AGC
 * table disable cloud sync for every existing protocol during an app upgrade.
 */
export function cloudDistributedRegistrationPlan():
  CloudDistributedRegistrationPlan {
  return {
    baseline: coreCloudSyncTableNames(),
    optionalSuperset: cloudSyncTableNames()
  };
}

/**
 * Rollback/backup snapshots include the optional table only after its local
 * schema has passed the exact contract check. Otherwise the deployed eight
 * tables still form a complete, valid snapshot instead of the whole operation
 * failing on a missing additive table.
 */
export function cloudSnapshotTableNames(
  optionalSchemaReady: boolean
): string[] {
  return optionalSchemaReady ? cloudSyncTableNames() :
    coreCloudSyncTableNames();
}

/**
 * Recover the deployed baseline even if a newer in-flight before-image also
 * contains an optional table whose local schema is no longer admissible.
 * Optional physical rows stay untouched and are quarantined separately.
 */
export function cloudRollbackRestoreTableNames(
  snapshotContainsOptional: boolean,
  optionalSchemaReady: boolean
): string[] {
  return snapshotContainsOptional && optionalSchemaReady ?
    cloudSyncTableNames() : coreCloudSyncTableNames();
}

export function cloudRollbackRequiresOptionalQuarantine(
  snapshotContainsOptional: boolean,
  optionalSchemaReady: boolean
): boolean {
  return snapshotContainsOptional && !optionalSchemaReady;
}

export function cloudPullOrder(): string[] {
  return cloudSyncTableNames();
}

export function cloudOperationRequiresConfirmation(operation: CloudSyncOperation): boolean {
  return operation === 'upload' || operation === 'download';
}

/**
 * 端云方向必须由操作意图决定，而不能用时间优先。
 * 新设备的空白本地库也会有较新的时间戳；时间优先会把它反向写回云端。
 */
export function cloudSyncDirectionForOperation(operation: CloudSyncExecution): CloudSyncDirection {
  if (operation === 'startupPull' || operation === 'manualDownload') {
    return 'cloudFirst';
  }
  return 'nativeFirst';
}
