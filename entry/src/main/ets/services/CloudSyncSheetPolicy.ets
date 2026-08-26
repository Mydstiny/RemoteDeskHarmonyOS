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
    return {
      title: '导出本地备份？',
      message: '备份使用 v3 完整性清单并绑定当前本地数据作用域（华为账号作用域或本机离线作用域）。可在下方选择“脱敏配置”（不含密码、私钥、2FA 与登录令牌，保留设备信任）或“完整备份”（包含全部数据，是否加密由你决定）。',
      primaryLabel: '选择位置并备份',
      secondaryLabel: '返回',
      primaryDestructive: false,
      secondaryDestructive: false,
      canDismiss: true
    };
  }
  if (step === CLOUD_SYNC_SHEET_RESTORE_CONFIRM) {
    return {
      title: '合并本地配置？',
      message: '已验证备份文件。恢复只合并文件中实际存在的脱敏字段；缺表、空表和缺失字段不会清空本机数据，也不会自动上传到云端。',
      primaryLabel: '合并并恢复',
      secondaryLabel: '返回',
      primaryDestructive: false,
      secondaryDestructive: false,
      canDismiss: true
    };
  }
  if (step === CLOUD_SYNC_SHEET_UPLOAD_CONFIRM) {
    return {
      title: '覆盖云端存档？',
      message: '将以当前设备的已选数据替换云端现有存档；VNC 仅按独立 scope 写入 vncrecordv2。此操作完成前可返回，不会立即执行。',
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
      message: '将用云端的已选数据替换当前设备上的数据；VNC 仅按独立 scope 恢复 vncrecordv2。请确认云端存档是你需要恢复的版本。',
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
      message: '正在恢复主机、密钥、2FA 和 VNC vncrecordv2 等数据，请勿关闭此页面。',
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
