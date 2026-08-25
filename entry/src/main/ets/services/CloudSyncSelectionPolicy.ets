import { MOONLIGHT_CLOUD_TABLE } from '../model/MoonlightRecord';
import { moonlightCloudSchemaProvisioned } from './CloudLifecycleSafetyPolicy';
import { cloudSyncTableNames } from './CloudSyncPolicy';

export const CLOUD_SYNC_SELECTION_PREFERENCE_KEY: string = 'cloudSyncSelectedTables';

const CLOUD_SYNC_USER_SELECTABLE_TABLES: string[] = [
  'usersettings',
  'remotehosts',
  'rdpcredentials',
  'rustdeskrelays',
  'sshkeys',
  'totpentries',
  // The ordinary selector controls whether the single VNC physical table
  // participates at all. VNC record-type/sensitive selection remains in the
  // VNC settings owner and is enforced by CloudSyncCoordinator.
  'vncrecordv2'
];

// Moonlight is an upgrade-owned table rather than another user-selected data
// type. Pre-Moonlight installs get it appended once without changing any of
// their legacy table choices. The data-management delete flow may still stop
// it explicitly after a destructive cloud operation.
const CLOUD_SYNC_KNOWN_TABLES: string[] =
  CLOUD_SYNC_USER_SELECTABLE_TABLES.concat([MOONLIGHT_CLOUD_TABLE]);

const CLOUD_SYNC_ENCRYPTED_TABLES: string[] = [
  'remotehosts',
  'rdpcredentials',
  'rustdeskrelays',
  'sshkeys',
  'totpentries'
];

// New installs include Moonlight from their first account-bound startup. The
// runtime admission layer still keeps a missing/unavailable optional schema
// from affecting the legacy eight-table baseline or local database access.
export const CLOUD_SYNC_SELECTION_DEFAULT: string[] = [
  MOONLIGHT_CLOUD_TABLE
];

export function cloudSyncSelectableTables(
  _remoteSchemaProvisioned: boolean = moonlightCloudSchemaProvisioned()
): string[] {
  // Moonlight has no checkbox: it is auto-enabled as one complete category.
  return CLOUD_SYNC_USER_SELECTABLE_TABLES.slice();
}

export function normalizeCloudSyncSelection(selected: string[]): string[] {
  const normalized: string[] = [];
  for (let i = 0; i < CLOUD_SYNC_KNOWN_TABLES.length; i++) {
    const table: string = CLOUD_SYNC_KNOWN_TABLES[i];
    if (selected.indexOf(table) >= 0) { normalized.push(table); }
  }
  return normalized;
}

/**
 * Compatibility upgrade for builds which predate Moonlight.
 *
 * The legacy migration receipt is diagnostic only: releases which briefly
 * wrote that receipt before the physical Moonlight selection was committed
 * must still be repaired on the next activation. An explicit whole-category
 * stop is tracked by CloudSyncSelectionStore with its own owner-scoped key.
 */
export function upgradeLegacyCloudSyncSelection(
  selected: string[], _moonlightUpgradeCompleted: boolean
): string[] {
  const normalized: string[] = normalizeCloudSyncSelection(selected);
  if (normalized.indexOf(MOONLIGHT_CLOUD_TABLE) < 0) {
    normalized.push(MOONLIGHT_CLOUD_TABLE);
  }
  return normalized;
}

export function hasCloudSyncBusinessSelection(selected: string[]): boolean {
  return normalizeCloudSyncSelection(selected).length > 0;
}

/** Runtime admission never rewrites the durable user selection. */
export function runtimeAdmittedCloudSyncSelection(
  selected: string[], unavailable: string[]
): string[] {
  const normalized: string[] = normalizeCloudSyncSelection(selected);
  return normalized.filter((table: string): boolean =>
    unavailable.indexOf(table) < 0);
}

export function effectiveCloudSyncTables(selected: string[]): string[] {
  const normalized: string[] = normalizeCloudSyncSelection(selected);
  let needsCrypto: boolean = false;
  for (let i = 0; i < CLOUD_SYNC_ENCRYPTED_TABLES.length; i++) {
    if (normalized.indexOf(CLOUD_SYNC_ENCRYPTED_TABLES[i]) >= 0) {
      needsCrypto = true;
      break;
    }
  }
  const effective: string[] = needsCrypto ? ['cryptoparams'] : [];
  const registered: string[] = cloudSyncTableNames();
  for (let i = 0; i < registered.length; i++) {
    const table: string = registered[i];
    if (normalized.indexOf(table) >= 0) { effective.push(table); }
  }
  return effective;
}
