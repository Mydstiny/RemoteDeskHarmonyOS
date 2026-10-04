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

/**
 * Tables whose secrets are end-to-end encrypted only after a master password
 * is set; without one they are stored as entered and rely on the cloud
 * space's own storage encryption (user decision 2026-10-04). Copy must never
 * call that end-to-end encryption, and only secrets are end-to-end encrypted:
 * addresses and user names always rely on the cloud space.
 */
const CLOUD_SYNC_SECRET_BEARING_TABLES: string[] = [
  'remotehosts', 'rdpcredentials', 'rustdeskrelays', 'sshkeys', 'totpentries'
];

/**
 * '' when no badge applies; otherwise the protection of the table's secrets.
 * VNC is separate: without a master password a remembered VNC password is
 * kept only on this device (plain_explicit_v1 rows are forced local-only), so
 * no secret of that table reaches the cloud at all.
 */
export function cloudSyncTableProtectionLabel(table: string, cryptoConfigured: boolean): string {
  if (table === 'vncrecordv2') { return cryptoConfigured ? '机密端到端加密' : ''; }
  if (CLOUD_SYNC_SECRET_BEARING_TABLES.indexOf(table) < 0) { return ''; }
  return cryptoConfigured ? '机密端到端加密' : '云空间加密';
}

export function cloudSyncTableDescription(table: string, cryptoConfigured: boolean): string {
  if (table === 'usersettings') { return '仅同步主题、壁纸等可跨设备复用的外观偏好'; }
  if (table === 'vncrecordv2') {
    return cryptoConfigured ? 'VNC 设置、主机、Gateway、端到端加密的机密和 trust 候选元数据' :
      'VNC 设置、主机、Gateway 和 trust 候选元数据；未设主密码时记住的 VNC 密码只保存在本机，不上传';
  }
  return cryptoConfigured ? '包含敏感数据：密码、密钥等机密已用主密码端到端加密，自动同步加密参数' :
    '包含密码等敏感数据，由华为云空间加密存储，未做端到端加密';
}

export function cloudSyncManageTablesHint(cryptoConfigured: boolean): string {
  const base: string = '取消勾选不会删除数据，只会停止此设备未来的上传和下载。';
  return cryptoConfigured ? base + '密码、密钥等机密已用主密码端到端加密，加密参数随其同步；地址等普通配置由华为云空间加密存储。' :
    base + '未设置主密码时，敏感数据由华为云空间的存储加密和华为账号保护，' +
      '未做端到端加密；设置主密码后，密码、密钥等机密改为端到端加密。';
}

export function cloudSyncCryptoParamsDescription(cryptoConfigured: boolean): string {
  return cryptoConfigured ? '为已选择的敏感数据提供解密能力，自动随其同步' :
    '未设置主密码，暂无加密参数；设置后自动随敏感数据同步';
}

/** Status line of the master-password card in settings. */
export function masterPasswordStatusText(cryptoConfigured: boolean, unlocked: boolean): string {
  if (!cryptoConfigured) {
    return '未启用 · 设置后主机密码、SSH 密钥、2FA 将端到端加密后再云同步';
  }
  return unlocked ? '已启用 · 密码、SSH 密钥、2FA 已端到端加密' : '已锁定 · 需解锁后解密数据';
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
