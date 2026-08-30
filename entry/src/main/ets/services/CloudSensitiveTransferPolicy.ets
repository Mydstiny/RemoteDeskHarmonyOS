/**
 * Pure safety policy for ordinary distributed tables.
 *
 * HarmonyOS cloudSync operates on a physical table, not on one projected row.
 * A native-first transfer is therefore allowed only when every non-empty
 * secret in the selected physical table is already an authenticated
 * ciphertext. This prevents a local crypto disable/reset or a legacy
 * plaintext row from being published by an unrelated later table sync.
 */

import {
  MOONLIGHT_CLOUD_TABLE,
  MoonlightRecord,
  MoonlightRecordType,
  moonlightRecordFromCloudRow
} from '../model/MoonlightRecord';
import { normalizeMoonlightCloudRowExact } from './CloudTableAdapter';
import {
  isMoonlightRecordTypeSelected,
  normalizeMoonlightCloudSyncSelection
} from './MoonlightCloudSyncSelectionPolicy';
import { remoteHostEndpointIsDevicePrivateForTransfer } from './LanHostAddressPolicy';
import { moonlightValidateRecord } from './MoonlightRecordPolicy';

export type CloudCiphertextProbe = (value: string) => boolean;
export type CloudDownloadValidationMode =
  'whole_snapshot' | 'record_isolation';

const SENSITIVE_BUSINESS_TABLES: string[] = [
  'remotehosts',
  'rdpcredentials',
  'rustdeskrelays',
  'sshkeys',
  'totpentries'
];

const SENSITIVE_COLUMNS: Record<string, string[]> = {
  'remotehosts': ['passward', 'sshkeydata'],
  'rdpcredentials': ['password'],
  'rustdeskrelays': ['apipassword', 'key'],
  'sshkeys': ['privatekey'],
  'totpentries': ['secret']
};

export function cloudSensitiveBusinessTables(): string[] {
  return SENSITIVE_BUSINESS_TABLES.slice();
}

export function cloudTableRequiresConfiguredCrypto(table: string): boolean {
  return table === 'cryptoparams' ||
    SENSITIVE_BUSINESS_TABLES.indexOf(table) >= 0;
}

function scalarSecretsAreSafe(
  table: string,
  row: Record<string, string>,
  ciphertextProbe: CloudCiphertextProbe
): boolean {
  const columns: string[] = SENSITIVE_COLUMNS[table] || [];
  for (let i = 0; i < columns.length; i++) {
    const value: string = row[columns[i]] || '';
    if (value !== '' && !ciphertextProbe(value)) { return false; }
  }
  return true;
}

function relayAccountSecretsAreSafe(
  row: Record<string, string>,
  ciphertextProbe: CloudCiphertextProbe
): boolean {
  const raw: string = row['accountsjson'] || '';
  if (raw === '') { return true; }
  try {
    const accounts: Array<Record<string, Object>> =
      JSON.parse(raw) as Array<Record<string, Object>>;
    if (!Array.isArray(accounts)) { return false; }
    for (let i = 0; i < accounts.length; i++) {
      if (!accounts[i] || typeof accounts[i] !== 'object' ||
        Array.isArray(accounts[i])) {
        return false;
      }
      const password: Object | undefined = accounts[i]['password'];
      if (password !== undefined && typeof password !== 'string') {
        return false;
      }
      const value: string =
        typeof password === 'string' ? password as string : '';
      if (value !== '' && !ciphertextProbe(value)) { return false; }
    }
    return true;
  } catch (_e) {
    return false;
  }
}

function encryptedRowsAreSafe(
  table: string,
  rows: Array<Record<string, string>>,
  ciphertextProbe: CloudCiphertextProbe
): boolean {
  for (let i = 0; i < rows.length; i++) {
    if (!scalarSecretsAreSafe(table, rows[i], ciphertextProbe)) {
      return false;
    }
    if (table === 'rustdeskrelays' &&
      !relayAccountSecretsAreSafe(rows[i], ciphertextProbe)) {
      return false;
    }
  }
  return true;
}

function exactMoonlightRecord(
  row: Record<string, string>
): MoonlightRecord | null {
  const exact: Record<string, string> | null =
    normalizeMoonlightCloudRowExact(row);
  if (exact === null) { return null; }
  const record: MoonlightRecord = moonlightRecordFromCloudRow(exact);
  return moonlightValidateRecord(record).valid ? record : null;
}

export function moonlightCloudRowsCarryLiveIdentity(
  rows: Array<Record<string, string>>
): boolean {
  for (let i = 0; i < rows.length; i++) {
    const record: MoonlightRecord | null = exactMoonlightRecord(rows[i]);
    // A malformed row that claims to be an identity is treated as sensitive;
    // callers must not use malformed input to bypass a crypto-reset barrier.
    if (record === null) {
      if (rows[i]['recordtype'] === 'secret' &&
          rows[i]['deletedat'] === '0') { return true; }
      continue;
    }
    if (record.recordType === 'secret' && record.deletedAt === 0) {
      return true;
    }
  }
  return false;
}

/**
 * Moonlight v1 cloud sync carries only re-pairable public configuration.
 * Pairing trust and the client identity are device-bound local state; reject
 * both live rows and tombstones so an old experimental projection can never
 * be republished by a later whole-table native-first operation.
 */
export function moonlightCloudRowsAreUploadSafe(
  rows: Array<Record<string, string>>,
  _cryptoConfigured: boolean,
  _ciphertextProbe: CloudCiphertextProbe
): boolean {
  for (let i = 0; i < rows.length; i++) {
    const record: MoonlightRecord | null = exactMoonlightRecord(rows[i]);
    if (record === null) { return false; }
    if (record.recordType !== 'settings' && record.recordType !== 'host' &&
        record.recordType !== 'profile') {
      return false;
    }
  }
  return true;
}

/**
 * HarmonyOS synchronizes a physical table rather than a SQL-filtered owner
 * view. Moonlight native-first is therefore admitted only when every physical
 * row belongs to the active owner and every row is part of the public v1
 * contract. An empty table is safe only for a bound, non-empty owner.
 */
export function moonlightPhysicalCloudRowsAreUploadSafe(
  rows: Array<Record<string, string>>,
  ownerScopeId: string,
  cryptoConfigured: boolean,
  ciphertextProbe: CloudCiphertextProbe,
  selectedScopes: string[] = ['settings', 'hosts', 'profiles'],
  pendingPhysicalMutationRecordIds?: string[]
): boolean {
  const owner: string = ownerScopeId.trim();
  if (owner.length === 0 || owner !== ownerScopeId) { return false; }
  const selected: string[] = normalizeMoonlightCloudSyncSelection(
    selectedScopes, false);
  for (let i = 0; i < rows.length; i++) {
    if (rows[i]['userid'] !== owner) { return false; }
    const record: MoonlightRecord | null = exactMoonlightRecord(rows[i]);
    if (record === null) { return false; }
    // HarmonyOS synchronizes the physical table. A live row outside current
    // consent is admissible only when the durable mutation journal proves it
    // is a clean pre-existing cloud mirror. This lets a single physical table
    // retain deselected cloud data without either deleting it or re-uploading
    // a pending local edit. Callers that cannot read the journal omit the
    // proof and fail closed. Tombstones remain uploadable so an explicit
    // cross-device deletion can converge.
    if (record.deletedAt === 0 &&
        !isMoonlightRecordTypeSelected(
          record.recordType, selected, false) &&
        (pendingPhysicalMutationRecordIds === undefined ||
          pendingPhysicalMutationRecordIds.indexOf('__table__') >= 0 ||
          pendingPhysicalMutationRecordIds.indexOf(record.id) >= 0)) {
        return false;
    }
  }
  return moonlightCloudRowsAreUploadSafe(
    rows, cryptoConfigured, ciphertextProbe);
}

/**
 * Scope reduction cancels only a pending live upload outside the new consent.
 * Explicit tombstones still converge across devices, and malformed deletion
 * metadata remains pending so the caller fails closed during validation.
 */
export function moonlightPhysicalMutationShouldRemainPending(
  recordType: MoonlightRecordType,
  deletedAt: number,
  selectedScopes: string[]
): boolean {
  if (!Number.isSafeInteger(deletedAt) || deletedAt < 0) { return true; }
  return deletedAt > 0 || isMoonlightRecordTypeSelected(
    recordType,
    normalizeMoonlightCloudSyncSelection(selectedScopes, false), false);
}

/**
 * A device whose local crypto was reset may still retain an already-encrypted
 * cloud identity opaquely. It cannot promote/upload it until crypto is
 * configured again, but download validation must not reinterpret ciphertext
 * as plaintext or manufacture a deletion.
 */
export function moonlightCloudRowsAreDownloadCompatible(
  rows: Array<Record<string, string>>,
  ciphertextProbe: CloudCiphertextProbe
): boolean {
  for (let i = 0; i < rows.length; i++) {
    const record: MoonlightRecord | null = exactMoonlightRecord(rows[i]);
    if (record === null) { return false; }
    if (record.recordType === 'secret' && record.deletedAt === 0 &&
        !ciphertextProbe(record.ciphertext)) { return false; }
  }
  return true;
}

/**
 * Native-first is stricter than download compatibility. Even an empty
 * sensitive table remains blocked while crypto is disabled, because it may
 * carry local reset/delete intent that must not become a remote wipe.
 */
export function cloudTableRowsAreUploadSafe(
  table: string,
  rows: Array<Record<string, string>>,
  cryptoConfigured: boolean,
  ciphertextProbe: CloudCiphertextProbe
): boolean {
  if (table === 'remotehosts') {
    for (let i = 0; i < rows.length; i++) {
      if (remoteHostEndpointIsDevicePrivateForTransfer(
        rows[i]['protocol'] || '', rows[i]['host'],
        rows[i]['proxyhost'])) { return false; }
    }
  }
  if (table === MOONLIGHT_CLOUD_TABLE) {
    return moonlightCloudRowsAreUploadSafe(
      rows, cryptoConfigured, ciphertextProbe);
  }
  if (!cloudTableRequiresConfiguredCrypto(table)) { return true; }
  // Encryption configuration is the user's explicit choice, never a
  // presumption. Without a configured crypto contract the secrets upload as
  // stored (plaintext, chosen by the user); with a configured contract every
  // secret in the snapshot must be ciphertext.
  if (!cryptoConfigured) { return true; }
  if (table === 'cryptoparams') { return true; }
  return encryptedRowsAreSafe(table, rows, ciphertextProbe);
}

/**
 * Legacy cloud rows created before encryption remain readable when the cloud
 * account has no crypto contract. Once cryptoparams declare active encryption,
 * every non-empty secret in the same snapshot must be ciphertext.
 */
export function cloudTableRowsAreDownloadCompatible(
  table: string,
  rows: Array<Record<string, string>>,
  cryptoConfigured: boolean,
  ciphertextProbe: CloudCiphertextProbe
): boolean {
  if (table === 'remotehosts') {
    for (let i = 0; i < rows.length; i++) {
      if (remoteHostEndpointIsDevicePrivateForTransfer(
        rows[i]['protocol'] || '', rows[i]['host'],
        rows[i]['proxyhost'])) { return false; }
    }
  }
  if (table === MOONLIGHT_CLOUD_TABLE) {
    return moonlightCloudRowsAreDownloadCompatible(rows, ciphertextProbe);
  }
  if (table === 'cryptoparams' ||
    SENSITIVE_BUSINESS_TABLES.indexOf(table) < 0 ||
    !cryptoConfigured) {
    return true;
  }
  return encryptedRowsAreSafe(table, rows, ciphertextProbe);
}

/**
 * Moonlight owns a transactional per-record materializer: valid rows are
 * applied while malformed, foreign-owner, or unsupported future rows are
 * quarantined. Running the ordinary whole-snapshot rejection gate as well
 * would let one bad optional row block an otherwise usable cloud pull.
 * Existing cloud tables retain their historical whole-snapshot behavior.
 */
export function cloudDownloadValidationMode(
  table: string
): CloudDownloadValidationMode {
  return table === MOONLIGHT_CLOUD_TABLE ?
    'record_isolation' : 'whole_snapshot';
}

/**
 * A local crypto disable pauses ordinary secret-bearing tables but can keep
 * settings and VNC metadata selected. A forgotten-password reset also pauses
 * the VNC physical table so its local deletes cannot become a remote wipe.
 */
export function cloudSelectionAfterLocalCryptoTransition(
  selected: string[],
  reset: boolean
): string[] {
  const result: string[] = [];
  for (let i = 0; i < selected.length; i++) {
    const table: string = selected[i];
    if (SENSITIVE_BUSINESS_TABLES.indexOf(table) >= 0) { continue; }
    if (reset && table === 'vncrecordv2') { continue; }
    result.push(table);
  }
  return result;
}

export function vncSelectionAfterLocalCryptoTransition(
  selected: string[],
  reset: boolean
): string[] {
  if (reset) { return []; }
  return selected.filter((scope: string): boolean => scope !== 'secrets');
}

/** Remove only the Moonlight physical table whose current snapshot is unsafe. */
export function moonlightSelectionAfterLocalCryptoTransition(
  selected: string[],
  rows: Array<Record<string, string>>,
  cryptoConfigured: boolean,
  ciphertextProbe: CloudCiphertextProbe
): string[] {
  if (moonlightCloudRowsAreUploadSafe(
    rows, cryptoConfigured, ciphertextProbe)) {
    return selected.slice();
  }
  return selected.filter((table: string): boolean =>
    table !== MOONLIGHT_CLOUD_TABLE);
}
