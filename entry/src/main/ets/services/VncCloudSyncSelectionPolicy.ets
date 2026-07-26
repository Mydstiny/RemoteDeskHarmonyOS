import { VncRecordType } from '../model/VncRecord';

/**
 * VNC has one physical cloud table but five independently selectable logical
 * record scopes. This policy is intentionally separate from the RDP,
 * RustDesk and SSH table selector.
 */
export type VncCloudSyncScope = 'settings' | 'hosts' | 'gateways' | 'secrets' | 'trust';

export const VNC_CLOUD_SYNC_SELECTION_KEY: string = 'vncCloudSyncRecordScopes';
export const VNC_CLOUD_SYNC_SELECTION_DEFAULT: VncCloudSyncScope[] = [
  'settings', 'hosts', 'gateways'
];

const VNC_CLOUD_SYNC_SCOPES: VncCloudSyncScope[] = [
  'settings', 'hosts', 'gateways', 'secrets', 'trust'
];

export function vncCloudSyncScopes(): VncCloudSyncScope[] {
  return VNC_CLOUD_SYNC_SCOPES.slice();
}

export function normalizeVncCloudSyncSelection(selected: string[]): VncCloudSyncScope[] {
  const normalized: VncCloudSyncScope[] = [];
  for (let i = 0; i < VNC_CLOUD_SYNC_SCOPES.length; i++) {
    const scope: VncCloudSyncScope = VNC_CLOUD_SYNC_SCOPES[i];
    if (selected.indexOf(scope) >= 0) { normalized.push(scope); }
  }
  return normalized;
}

export function hasVncCloudSyncBusinessSelection(selected: string[]): boolean {
  return normalizeVncCloudSyncSelection(selected).length > 0;
}

export function vncRecordTypeToSyncScope(recordType: VncRecordType): VncCloudSyncScope {
  if (recordType === 'host') { return 'hosts'; }
  if (recordType === 'gateway') { return 'gateways'; }
  if (recordType === 'secret') { return 'secrets'; }
  if (recordType === 'trust') { return 'trust'; }
  return 'settings';
}

export function isVncRecordTypeSelected(recordType: VncRecordType, selected: string[]): boolean {
  return normalizeVncCloudSyncSelection(selected).indexOf(vncRecordTypeToSyncScope(recordType)) >= 0;
}

/** Secrets require both explicit opt-in and an unlocked local crypto key. */
export function vncSecretSyncAllowed(selected: string[], cryptoReady: boolean): boolean {
  return cryptoReady && normalizeVncCloudSyncSelection(selected).indexOf('secrets') >= 0;
}

export function vncSyncNeedsCrypto(selected: string[]): boolean {
  return normalizeVncCloudSyncSelection(selected).indexOf('secrets') >= 0;
}
