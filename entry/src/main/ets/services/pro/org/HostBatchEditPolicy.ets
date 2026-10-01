/**
 * Batch edit allowlist for Pro 高级主机管理. Only non-secret connection preferences are editable; passwords,
 * private keys, passphrases, tokens and saved Windows credentials never appear here.
 */
export type HostBatchField = 'port' | 'username' | 'rdpResolution' | 'rdpColorDepth' | 'rdpMultiMonitor' |
  'sshKeyId';
/** A host as batch edit sees it: `values` holds the current value of every batch field it has. */
export interface HostBatchHost { id: string; protocol: string; values: Record<string, Object>; }
export interface HostBatchEdit { field: HostBatchField; value: string | number | boolean; enabled: boolean; }
export interface HostBatchDiff {
  hostId: string; field: HostBatchField; oldValue: string; newValue: string; skipped: boolean; unchanged: boolean;
}

export const HOST_BATCH_FIELDS: HostBatchField[] = ['port', 'rdpResolution', 'rdpColorDepth', 'rdpMultiMonitor',
  'username', 'sshKeyId'];
export const HOST_BATCH_RESOLUTIONS: string[] = ['auto', '1280x720', '1600x900', '1920x1080', '2560x1440', '3840x2160'];
export const HOST_BATCH_COLOR_DEPTHS: number[] = [16, 24, 32];

export function batchFieldProtocols(field: HostBatchField): string[] {
  if (field === 'username' || field === 'sshKeyId') { return ['ssh']; }
  if (field === 'port' || field === 'rdpResolution' || field === 'rdpColorDepth' || field === 'rdpMultiMonitor') {
    return ['rdp'];
  }
  return [];
}
export function batchFieldAllowed(field: string): boolean {
  return (HOST_BATCH_FIELDS as string[]).indexOf(field) >= 0;
}

export function batchFieldLabel(field: HostBatchField): string {
  if (field === 'port') { return 'RDP 端口'; }
  if (field === 'username') { return 'SSH 用户名'; }
  if (field === 'rdpResolution') { return 'RDP 分辨率'; }
  if (field === 'rdpColorDepth') { return 'RDP 色深'; }
  if (field === 'rdpMultiMonitor') { return 'RDP 多显示器'; }
  return 'SSH 认证密钥';
}

export function batchFieldHint(field: HostBatchField): string {
  if (field === 'port') { return '只对 RDP 主机生效；改端口后首次连接需重新确认证书'; }
  if (field === 'username') { return '只改 SSH 登录用户名，不改密码'; }
  if (field === 'sshKeyId') { return '改为使用密钥库中的这把密钥登录；只改引用，不读取私钥'; }
  return '只对 RDP 主机生效';
}

export function batchResolutionLabel(value: string): string { return value === 'auto' ? '跟随窗口' : value.replace('x', ' × '); }

export function validBatchValue(field: HostBatchField, value: string | number | boolean): boolean {
  if (field === 'port') { return typeof value === 'number' && Number.isInteger(value) && value >= 1 && value <= 65535; }
  if (field === 'username') {
    return typeof value === 'string' && value.trim().length > 0 && value.length <= 256 && !/[\u0000-\u001f\u007f]/.test(value);
  }
  if (field === 'rdpResolution') { return typeof value === 'string' && HOST_BATCH_RESOLUTIONS.indexOf(value) >= 0; }
  if (field === 'rdpColorDepth') { return typeof value === 'number' && HOST_BATCH_COLOR_DEPTHS.indexOf(value) >= 0; }
  if (field === 'rdpMultiMonitor') { return typeof value === 'boolean'; }
  if (field === 'sshKeyId') {
    return typeof value === 'string' && value.length > 0 && value.length <= 128 && !/[\u0000-\u001f\u007f]/.test(value);
  }
  return false;
}

function displayValue(field: HostBatchField, value: Object | undefined): string {
  if (value === undefined || value === null) { return ''; }
  if (field === 'rdpResolution') { return batchResolutionLabel(String(value)); }
  if (field === 'rdpMultiMonitor') { return value === true ? '开启' : '关闭'; }
  if (field === 'rdpColorDepth') { return String(value) + ' 位'; }
  if (field === 'sshKeyId' && String(value) === '') { return '密码登录'; }
  return String(value);
}

/**
 * Per-host, per-field preview. A field the host's protocol does not support is `skipped`; equal old/new values are `unchanged`. Hosts carry display strings for each field.
 */
export function batchEditDiff(hosts: HostBatchHost[], edits: HostBatchEdit[]): HostBatchDiff[] {
  const result: HostBatchDiff[] = [];
  hosts.forEach((host: HostBatchHost): void => edits.forEach((edit: HostBatchEdit): void => {
    if (!edit.enabled || !batchFieldAllowed(edit.field) || !validBatchValue(edit.field, edit.value)) { return; }
    const applicable: boolean = batchFieldProtocols(edit.field).indexOf(host.protocol) >= 0;
    const oldRaw: Object | undefined = Object.keys(host.values).indexOf(edit.field) >= 0 ?
      host.values[edit.field] : undefined;
    const oldValue: string = displayValue(edit.field, oldRaw);
    const newValue: string = displayValue(edit.field, edit.value);
    result.push({ hostId: host.id, field: edit.field, oldValue, newValue, skipped: !applicable,
      unchanged: applicable && oldRaw !== undefined && String(oldRaw) === String(edit.value) });
  }));
  return result;
}

export function batchDiffCounts(diffs: HostBatchDiff[]): number[] {
  const changed: number = diffs.filter((diff: HostBatchDiff): boolean => !diff.skipped && !diff.unchanged).length;
  const skipped: number = diffs.filter((diff: HostBatchDiff): boolean => diff.skipped).length;
  return [changed, skipped, diffs.length - changed - skipped];
}

export function isSensitiveBatchField(field: string): boolean {
  return ['password', 'privateKey', 'passphrase', 'token', 'secret', 'rdpCredentialId', 'sshKeyData',
    'sshKeyPassphrase', 'sshProxyPassword'].indexOf(field) >= 0;
}
