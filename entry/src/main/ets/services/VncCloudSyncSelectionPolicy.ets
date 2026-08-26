import { VncRecordType } from '../model/VncRecord';

/**
 * Legacy releases exposed five logical selectors for the single VNC cloud
 * table. Huawei Cloud Space registers and transfers the physical table as one
 * unit, so 1.1.1 treats every valid VNC record type as selected whenever the
 * ordinary table selector enables `vncrecordv2`.
 *
 * Keep the scope type and preference key as a compatibility boundary for old
 * settings/checkpoints. They no longer form a second cloud-transfer gate.
 */
export type VncCloudSyncScope = 'settings' | 'hosts' | 'gateways' | 'secrets' | 'trust';

export const VNC_CLOUD_SYNC_SELECTION_KEY: string = 'vncCloudSyncRecordScopes';
const VNC_CLOUD_SYNC_SCOPES: VncCloudSyncScope[] = [
  'settings', 'hosts', 'gateways', 'secrets', 'trust'
];

export const VNC_CLOUD_SYNC_SELECTION_DEFAULT: VncCloudSyncScope[] =
  VNC_CLOUD_SYNC_SCOPES.slice();

export function vncCloudSyncScopes(): VncCloudSyncScope[] {
  return VNC_CLOUD_SYNC_SCOPES.slice();
}

export function normalizeVncCloudSyncSelection(
  _legacySelected: string[]
): VncCloudSyncScope[] {
  // Empty, partial and malformed legacy selections all migrate to the one
  // physical-table contract. The ordinary CloudSyncSelectionStore remains the
  // sole enable/disable decision.
  return VNC_CLOUD_SYNC_SCOPES.slice();
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

/**
 * Encrypted secret rows follow the physical table. Explicit plaintext secrets
 * are still forced into `vnclocalrecords` by CloudStore and never reach here as
 * syncable cloud rows.
 */
export function vncSecretSyncAllowed(selected: string[], _cryptoReady: boolean = false): boolean {
  return normalizeVncCloudSyncSelection(selected).indexOf('secrets') >= 0;
}

export function vncSyncNeedsCrypto(selected: string[], cryptoConfigured: boolean = true): boolean {
  return cryptoConfigured && normalizeVncCloudSyncSelection(selected).indexOf('secrets') >= 0;
}
