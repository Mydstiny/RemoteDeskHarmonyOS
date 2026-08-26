import { RemoteHost } from '../model/RemoteHost';
import {
  RUSTDESK_PEER_2FA_BINDING_VERSION,
  RUSTDESK_PEER_2FA_LEGACY_MIGRATION_VERSION,
  RustDeskPeerTwoFactorBinding,
  RustDeskPeerTwoFactorBindingStore,
  rustDeskPeerTwoFactorEndpointIdentity,
  scrubRustDeskPeerTwoFactorRuntime
} from './RustDeskPeerTwoFactorBindingStore';

export type RustDeskPeerTwoFactorLegacySource =
  'remote_json' | 'cloud_extension' | 'local_backup';

export interface RustDeskPeerTwoFactorLegacyCandidate {
  ownerScopeId: string
  hostId: string
  entryId: string
  autoSubmit: boolean
  sourceDeviceId: string
  source: RustDeskPeerTwoFactorLegacySource
}

export type RustDeskPeerTwoFactorLegacyMigrationStatus =
  'migrated' | 'already_migrated' | 'unbound' | 'persistence_failed';

export interface RustDeskPeerTwoFactorLegacyMigrationResult {
  status: RustDeskPeerTwoFactorLegacyMigrationStatus
  reason: string
}

function normalized(value: string): string { return value.trim(); }

function stringValue(row: Record<string, Object>, keys: string[]): string {
  for (let i = 0; i < keys.length; i++) {
    const value: Object = row[keys[i]];
    if (typeof value === 'string') { return (value as string).trim(); }
  }
  return '';
}

function booleanValue(row: Record<string, Object>, keys: string[]): boolean {
  for (let i = 0; i < keys.length; i++) {
    const value: Object = row[keys[i]];
    if (value === true || value === 1 || value === '1' || value === 'true') { return true; }
    if (value === false || value === 0 || value === '0' || value === 'false') { return false; }
  }
  return false;
}

function candidateFromRow(row: Record<string, Object>, ownerScopeId: string,
  hostId: string, source: RustDeskPeerTwoFactorLegacySource,
  allowAutoSubmit: boolean): RustDeskPeerTwoFactorLegacyCandidate | null {
  const entryId: string = stringValue(row,
    ['rustdeskTotpEntryId', 'rustdesktotpentryid']);
  if (entryId === '' || normalized(ownerScopeId) === '' || normalized(hostId) === '') {
    return null;
  }
  return {
    ownerScopeId: normalized(ownerScopeId),
    hostId: normalized(hostId),
    entryId,
    autoSubmit: allowAutoSubmit && booleanValue(row,
      ['rustdeskTotpAutoSubmit', 'rustdesktotpautosubmit']),
    sourceDeviceId: stringValue(row,
      ['rustdeskTotpDeviceId', 'rustdesktotpdeviceid']),
    source
  };
}

export function decodeRustDeskPeerTwoFactorLegacyDisplayConfig(
  raw: string, ownerScopeId: string, hostId: string
): RustDeskPeerTwoFactorLegacyCandidate | null {
  if (raw.trim() === '') { return null; }
  try {
    const parsed: Object = JSON.parse(raw) as Object;
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) { return null; }
    const payload: Record<string, Object> = parsed as Record<string, Object>;
    const extensionValue: Object = payload['_remoteDeskExtensionV1'];
    if (!extensionValue || typeof extensionValue !== 'object' || Array.isArray(extensionValue)) {
      return null;
    }
    return candidateFromRow(extensionValue as Record<string, Object>,
      ownerScopeId, hostId, 'cloud_extension', true);
  } catch (_error) {
    return null;
  }
}

export function decodeRustDeskPeerTwoFactorLegacyBackupRows(
  rows: Array<Record<string, string>>,
  extensions: Array<Record<string, string>>,
  ownerScopeId: string
): RustDeskPeerTwoFactorLegacyCandidate[] {
  const result: RustDeskPeerTwoFactorLegacyCandidate[] = [];
  for (let i = 0; i < rows.length; i++) {
    const row: Record<string, string> = rows[i];
    const hostId: string = row['id'] || row['recordid'] || '';
    const objectRow: Record<string, Object> = row as Record<string, Object>;
    const direct: RustDeskPeerTwoFactorLegacyCandidate | null = candidateFromRow(
      objectRow, ownerScopeId, hostId, 'local_backup', false);
    if (direct !== null) { result.push(direct); }
  }
  for (let i = 0; i < extensions.length; i++) {
    const row: Record<string, string> = extensions[i];
    const hostId: string = row['recordid'] || row['id'] || '';
    let candidate: RustDeskPeerTwoFactorLegacyCandidate | null = candidateFromRow(
      row as Record<string, Object>, ownerScopeId, hostId, 'local_backup', false);
    if (candidate === null && (row['payload'] || '') !== '') {
      try {
        const parsed: Object = JSON.parse(row['payload']) as Object;
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
          candidate = candidateFromRow(parsed as Record<string, Object>,
            ownerScopeId, hostId, 'local_backup', false);
        }
      } catch (_error) { /* malformed legacy extension is ignored */ }
    }
    if (candidate !== null) { result.push(candidate); }
  }
  return result;
}

export function migrateRustDeskPeerTwoFactorLegacyCandidate(
  candidate: RustDeskPeerTwoFactorLegacyCandidate,
  host: RemoteHost,
  store: RustDeskPeerTwoFactorBindingStore,
  entryExists: (entryId: string) => boolean
): RustDeskPeerTwoFactorLegacyMigrationResult {
  const endpoint: string = rustDeskPeerTwoFactorEndpointIdentity(host);
  const owner: string = normalized(candidate.ownerScopeId);
  const sourceDevice: string = normalized(candidate.sourceDeviceId);
  scrubRustDeskPeerTwoFactorRuntime(host);
  if (!store.isLoaded() || owner === '' || owner !== store.currentOwnerScopeId() ||
    owner !== normalized(host.userId) || normalized(candidate.hostId) !== normalized(host.id) ||
    endpoint === '' || normalized(candidate.entryId) === '') {
    return { status: 'unbound', reason: 'legacy_owner_or_endpoint_mismatch' };
  }
  if (store.legacyMigrationVersion(host.id, endpoint, candidate.source) >=
    RUSTDESK_PEER_2FA_LEGACY_MIGRATION_VERSION) {
    return { status: 'already_migrated', reason: 'legacy_migration_marker_present' };
  }
  if (candidate.source !== 'local_backup' &&
    (sourceDevice === '' || sourceDevice !== store.deviceIdentity())) {
    return { status: 'unbound', reason: 'legacy_device_identity_not_proven' };
  }
  if (!entryExists(candidate.entryId)) {
    return { status: 'unbound', reason: 'legacy_totp_entry_missing' };
  }
  const binding: RustDeskPeerTwoFactorBinding = {
    version: RUSTDESK_PEER_2FA_BINDING_VERSION,
    ownerScopeId: owner,
    hostId: host.id,
    endpointIdentity: endpoint,
    entryId: normalized(candidate.entryId),
    autoSubmit: candidate.source === 'local_backup' ? false : candidate.autoSubmit,
    deviceIdentity: store.deviceIdentity(),
    source: 'legacy:' + candidate.source,
    migrationVersion: RUSTDESK_PEER_2FA_LEGACY_MIGRATION_VERSION,
    updatedAt: Date.now()
  };
  if (!store.save(binding)) {
    scrubRustDeskPeerTwoFactorRuntime(host);
    return { status: 'persistence_failed', reason: 'owner_local_binding_write_failed' };
  }
  scrubRustDeskPeerTwoFactorRuntime(host);
  return { status: 'migrated', reason: 'legacy_binding_migrated' };
}
