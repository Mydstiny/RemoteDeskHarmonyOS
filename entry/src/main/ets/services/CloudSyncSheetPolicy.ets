export const CLOUD_SYNC_SHEET_ACTIONS: string = 'actions';
export const CLOUD_SYNC_SHEET_UPLOAD_CONFIRM: string = 'uploadConfirm';
export const CLOUD_SYNC_SHEET_DOWNLOAD_CONFIRM: string = 'downloadConfirm';
export const CLOUD_SYNC_SHEET_UNAVAILABLE: string = 'unavailable';
export const CLOUD_SYNC_SHEET_UPLOADING: string = 'uploading';
export const CLOUD_SYNC_SHEET_DOWNLOADING: string = 'downloading';
export const CLOUD_SYNC_SHEET_MANAGE_TABLES: string = 'manageTables';
export const CLOUD_SYNC_SHEET_BACKUP_CONFIRM: string = 'backupConfirm';
export const CLOUD_SYNC_SHEET_RESTORE_CONFIRM: string = 'restoreConfirm';
export const CLOUD_SYNC_SHEET_DETAILS: string = 'details';

export interface CloudSyncSheetSpec {
  title: string;
  message: string;
  primaryLabel: string;
  secondaryLabel: string;
  primaryDestructive: boolean;
  secondaryDestructive: boolean;
  canDismiss: boolean;
}

export function cloudSyncSheetSpec(step: string): CloudSyncSheetSpec {
  if (step === CLOUD_SYNC_SHEET_DETAILS) {
    return {
      title: '云同步详情',
      message: '查看云同步正常使用所需的条件。',
      primaryLabel: '',
      secondaryLabel: '',
      primaryDestructive: false,
      secondaryDestructive: false,
      canDismiss: true
    };
  }
  if (step === CLOUD_SYNC_SHEET_BACKUP_CONFIRM) {
    return { title: '导出本地明文备份？', message: '备份包含 SSH 私钥、动态口令和登录凭据等敏感信息。请仅保存到可信位置。', primaryLabel: '选择位置并备份', secondaryLabel: '返回', primaryDestructive: true, secondaryDestructive: false, canDismiss: true };
  }
  if (step === CLOUD_SYNC_SHEET_RESTORE_CONFIRM) {
    return { title: '覆盖本地数据？', message: '已验证备份文件。恢复会替换本机全部 7 类数据，且不会自动上传到云端。', primaryLabel: '覆盖并恢复', secondaryLabel: '返回', primaryDestructive: true, secondaryDestructive: false, canDismiss: true };
  }
  if (step === CLOUD_SYNC_SHEET_UPLOAD_CONFIRM) {
    return {
      title: '覆盖云端存档？',
      message: '将以当前设备的 7 类数据替换云端现有存档。此操作完成前可返回，不会立即执行。',
      primaryLabel: '覆盖并上传',
      secondaryLabel: '返回',
      primaryDestructive: true,
      secondaryDestructive: false,
      canDismiss: true
    };
  }
  if (step === CLOUD_SYNC_SHEET_DOWNLOAD_CONFIRM) {
    return {
      title: '覆盖本地数据？',
      message: '将用云端的 7 类数据替换当前设备上的数据。请确认云端存档是你需要恢复的版本。',
      primaryLabel: '覆盖并下载',
      secondaryLabel: '返回',
      primaryDestructive: true,
      secondaryDestructive: false,
      canDismiss: true
    };
  }
  if (step === CLOUD_SYNC_SHEET_UNAVAILABLE) {
    return {
      title: '云同步暂不可用',
      message: '请确认已登录同一华为账号、已开通华为云空间，并在系统设置中打开云同步后重试。',
      primaryLabel: '我知道了',
      secondaryLabel: '',
      primaryDestructive: false,
      secondaryDestructive: false,
      canDismiss: true
    };
  }
  if (step === CLOUD_SYNC_SHEET_UPLOADING) {
    return {
      title: '正在上传到云端',
      message: '正在逐项覆盖云端存档，请勿关闭此页面。',
      primaryLabel: '',
      secondaryLabel: '',
      primaryDestructive: false,
      secondaryDestructive: false,
      canDismiss: false
    };
  }
  if (step === CLOUD_SYNC_SHEET_DOWNLOADING) {
    return {
      title: '正在下载云端数据',
      message: '正在恢复主机、密钥和 2FA 等数据，请勿关闭此页面。',
      primaryLabel: '',
      secondaryLabel: '',
      primaryDestructive: false,
      secondaryDestructive: false,
      canDismiss: false
    };
  }
  return {
    title: '云同步',
    message: '所有数据使用华为云空间在可信设备间同步。请选择要执行的操作。',
    primaryLabel: '上传当前设备所有信息到云端',
    secondaryLabel: '下载云端数据到本地',
    primaryDestructive: false,
    secondaryDestructive: true,
    canDismiss: true
  };
}
