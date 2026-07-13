export const CLOUD_SYNC_TABLES: string[] = [
  'cryptoparams',
  'usersettings',
  'remotehosts',
  'rdpcredentials',
  'rustdeskrelays',
  'sshkeys',
  'totpentries'
];

export type CloudSyncOperation = 'upload' | 'download' | 'refresh';
export type CloudSyncDirection = 'cloudFirst' | 'nativeFirst';
export type CloudSyncExecution = 'startupPull' | 'manualDownload' | 'manualUpload' | 'automaticPush';

export function cloudSyncTableNames(): string[] {
  return CLOUD_SYNC_TABLES.slice();
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
