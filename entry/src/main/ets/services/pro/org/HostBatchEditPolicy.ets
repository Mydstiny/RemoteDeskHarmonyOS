export type HostBatchField = 'port' | 'username' | 'rdpResolution' | 'rdpQuality' | 'rdpGateway' |
  'rustdeskRelay' | 'sshProxy' | 'sshKeyId' | 'vncScaling' | 'vncReadOnly';
export interface HostBatchHost { id: string; protocol: string; [key: string]: Object; }
export interface HostBatchEdit { field: HostBatchField; value: string | number | boolean; enabled: boolean; }
export interface HostBatchDiff { hostId: string; field: HostBatchField; oldValue: string; newValue: string; skipped: boolean; }

const FIELD_PROTOCOLS: Record<string, string[]> = {
  port: ['rdp', 'rustdesk', 'ssh', 'vnc'], username: ['rdp', 'ssh', 'vnc'],
  rdpResolution: ['rdp'], rdpQuality: ['rdp'], rdpGateway: ['rdp'],
  rustdeskRelay: ['rustdesk'], sshProxy: ['ssh'], sshKeyId: ['ssh'],
  vncScaling: ['vnc'], vncReadOnly: ['vnc']
};

export function batchFieldProtocols(field: HostBatchField): string[] { return (FIELD_PROTOCOLS[field] || []).slice(); }
export function batchFieldAllowed(field: string): boolean {
  return Object.prototype.hasOwnProperty.call(FIELD_PROTOCOLS, field);
}
export function batchEditDiff(hosts: HostBatchHost[], edits: HostBatchEdit[]): HostBatchDiff[] {
  const result: HostBatchDiff[] = [];
  hosts.forEach((host: HostBatchHost): void => edits.forEach((edit: HostBatchEdit): void => {
    if (!edit.enabled || !batchFieldAllowed(edit.field)) { return; }
    const applicable: boolean = batchFieldProtocols(edit.field).indexOf(host.protocol) >= 0;
    const oldValue: Object = Object.prototype.hasOwnProperty.call(host, edit.field) ? host[edit.field] : '';
    result.push({ hostId: host.id, field: edit.field, oldValue: String(oldValue),
      newValue: String(edit.value), skipped: !applicable });
  }));
  return result;
}

export function isSensitiveBatchField(field: string): boolean {
  return ['password', 'privateKey', 'passphrase', 'token', 'secret', 'rdpCredentialId'].indexOf(field) >= 0;
}
