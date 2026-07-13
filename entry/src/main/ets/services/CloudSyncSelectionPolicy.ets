import { CLOUD_SYNC_TABLES } from './CloudSyncPolicy';

export const CLOUD_SYNC_SELECTION_PREFERENCE_KEY: string = 'cloudSyncSelectedTables';

const CLOUD_SYNC_SELECTABLE_TABLES: string[] = [
  'usersettings',
  'remotehosts',
  'rdpcredentials',
  'rustdeskrelays',
  'sshkeys',
  'totpentries'
];

const CLOUD_SYNC_ENCRYPTED_TABLES: string[] = [
  'remotehosts',
  'rdpcredentials',
  'rustdeskrelays',
  'sshkeys',
  'totpentries'
];

export const CLOUD_SYNC_SELECTION_DEFAULT: string[] = CLOUD_SYNC_SELECTABLE_TABLES.slice();

export function cloudSyncSelectableTables(): string[] {
  return CLOUD_SYNC_SELECTABLE_TABLES.slice();
}

export function normalizeCloudSyncSelection(selected: string[]): string[] {
  const normalized: string[] = [];
  for (let i = 0; i < CLOUD_SYNC_SELECTABLE_TABLES.length; i++) {
    const table: string = CLOUD_SYNC_SELECTABLE_TABLES[i];
    if (selected.indexOf(table) >= 0) { normalized.push(table); }
  }
  return normalized;
}

export function hasCloudSyncBusinessSelection(selected: string[]): boolean {
  return normalizeCloudSyncSelection(selected).length > 0;
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
  for (let i = 0; i < CLOUD_SYNC_TABLES.length; i++) {
    const table: string = CLOUD_SYNC_TABLES[i];
    if (normalized.indexOf(table) >= 0) { effective.push(table); }
  }
  return effective;
}
