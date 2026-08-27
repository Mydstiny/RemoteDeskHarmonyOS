import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import {
  MOONLIGHT_LOCAL_RECORD_COLUMNS,
  MOONLIGHT_RECORD_COLUMNS,
  MoonlightRecord,
  moonlightLocalOnlyFlagIsValid,
  moonlightRecordFromCloudRow,
  moonlightRecordToCloudRow
} from '../model/MoonlightRecord';
import {
  MoonlightConflictDecision,
  resolveMoonlightRecordConflict
} from './MoonlightRecordConflictPolicy';
import { CloudMetadataReadResult } from './CloudMetadataSafetyPolicy';
import {
  moonlightRecordBusinessPayload,
  moonlightValidateRecord
} from './MoonlightRecordPolicy';

export type MoonlightBackupMode = 'redacted' | 'full';

export const MOONLIGHT_RESTORE_QUARANTINE_KEY: string =
  'moonlight_restored_not_activated_v1';

export type MoonlightRestoreActivationState =
  'clear' | 'pending' | 'blocked';

/**
 * A portable restore is never cloud-eligible merely because its rows are
 * valid. Only an absent marker means transfer is allowed. The known `1`
 * marker is actionable explicit-consent work; malformed/unreadable metadata
 * remains blocked and cannot be reinterpreted as absence.
 */
export function moonlightRestoreActivationState(
  marker: CloudMetadataReadResult
): MoonlightRestoreActivationState {
  if (marker.state === 'absent') { return 'clear'; }
  if (marker.state === 'present' && marker.value === '1') {
    return 'pending';
  }
  return 'blocked';
}

export function moonlightRestoreTransferBlocked(
  marker: CloudMetadataReadResult
): boolean {
  return moonlightRestoreActivationState(marker) !== 'clear';
}

/**
 * Runtime admission may bypass the known pending marker only inside the
 * explicit, current-account activation workflow. An unreadable or malformed
 * marker is never bypassed, even if a stale in-memory authorization survives
 * long enough to call this policy.
 */
export function moonlightRestoreRuntimeAdmissionAllowed(
  marker: CloudMetadataReadResult,
  explicitActivationAuthorized: boolean
): boolean {
  const state: MoonlightRestoreActivationState =
    moonlightRestoreActivationState(marker);
  return state === 'clear' ||
    (state === 'pending' && explicitActivationAuthorized);
}

export function moonlightBackupRowsRequireCloudActivation(
  rows: Array<Record<string, string>>
): boolean {
  for (let i = 0; i < rows.length; i++) {
    const type: string = rows[i]['recordtype'] || '';
    if (type === 'settings' || type === 'host' ||
        type === 'profile') {
      return true;
    }
  }
  return false;
}

export interface MoonlightBackupFilterResult {
  rows: Array<Record<string, string>>;
  excludedRows: number;
}

export interface MoonlightBackupRestoreResolution {
  rows: Array<Record<string, string>>;
  quarantinedRows: number;
  sourceRows: number;
}

function moonlightRestoreSha256Hex(value: string): string {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: new util.TextEncoder().encode(value) });
  const bytes: Uint8Array = md.digestSync().data;
  let result: string = '';
  for (let index = 0; index < bytes.length; index++) {
    result += bytes[index].toString(16).padStart(2, '0');
  }
  return result;
}

export function moonlightCanonicalHostRecordId(
  ownerScopeId: string, serverUuid: string
): string {
  const owner: string = ownerScopeId.trim();
  const uuid: string = serverUuid.trim();
  if (owner === '' || uuid === '') { return ''; }
  return 'moonlight-host|' + moonlightRestoreSha256Hex(
    'RemoteDeskHarmonyOS:moonlight-host:v1:' + owner + ':' + uuid);
}

export function moonlightCanonicalTrustRecordId(hostId: string): string {
  const normalized: string = hostId.trim();
  return normalized === '' ? '' : 'moonlight-trust|' +
    moonlightRestoreSha256Hex('v1:' + normalized);
}

/** Logical identity used to fence prerelease aliases during restore. */
export function moonlightRestoreAliasFenceId(
  record: MoonlightRecord
): string {
  if (record.recordType === 'host') {
    if (record.deletedAt > 0) { return record.id; }
    const payload: Record<string, Object> | null =
      moonlightRecordBusinessPayload(record);
    return payload !== null && typeof payload['serverUuid'] === 'string' ?
      moonlightCanonicalHostRecordId(
        record.userId, payload['serverUuid'] as string) : record.id;
  }
  if (record.recordType === 'trust') {
    if (record.deletedAt > 0) {
      return moonlightCanonicalTrustRecordId(record.ownerId) || record.id;
    }
    const payload: Record<string, Object> | null =
      moonlightRecordBusinessPayload(record);
    if (payload !== null && typeof payload['serverUuid'] === 'string') {
      const hostId: string = moonlightCanonicalHostRecordId(
        record.userId, payload['serverUuid'] as string);
      return moonlightCanonicalTrustRecordId(hostId) || record.id;
    }
  }
  return record.id;
}

function copyExactRow(
  source: Record<string, string>, columns: string[]
): Record<string, string> | null {
  const keys: string[] = Object.keys(source);
  if (keys.length !== columns.length) { return null; }
  const row: Record<string, string> = {};
  for (let i = 0; i < columns.length; i++) {
    const key: string = columns[i];
    if (typeof source[key] !== 'string') { return null; }
    row[key] = source[key];
  }
  return row;
}

function recordTypeIsPortable(
  record: MoonlightRecord, mode: MoonlightBackupMode
): boolean {
  if (record.recordType === 'secret') { return false; }
  if (mode === 'redacted' && record.recordType === 'trust') {
    return false;
  }
  return record.recordType === 'settings' ||
    record.recordType === 'host' ||
    record.recordType === 'profile' ||
    record.recordType === 'trust';
}

/** Source-store admission is stricter than redaction: malformed rows abort. */
export function moonlightBackupSourceRowsAreValid(
  rows: Array<Record<string, string>>,
  owner: string,
  localTable: boolean
): boolean {
  const columns: string[] = localTable
    ? MOONLIGHT_LOCAL_RECORD_COLUMNS : MOONLIGHT_RECORD_COLUMNS;
  const ids: Set<string> = new Set<string>();
  for (let i = 0; i < rows.length; i++) {
    const exact: Record<string, string> | null =
      copyExactRow(rows[i], columns);
    if (exact === null || exact['userid'] !== owner ||
      ids.has(exact['id'] || '')) {
      return false;
    }
    if (localTable &&
      !moonlightLocalOnlyFlagIsValid(Number(exact['localonly']))) {
      return false;
    }
    if (!moonlightValidateRecord(
      moonlightRecordFromCloudRow(exact)).valid) {
      return false;
    }
    ids.add(exact['id']);
  }
  return true;
}

/**
 * Moonlight client identity is omitted even from a full portable backup.
 * Full mode adds only certificate trust candidates; it never adds private-key
 * bytes, pairing PINs, session tokens, cache rows or device-local approval.
 */
export function filterMoonlightBackupRows(
  rows: Array<Record<string, string>>,
  mode: MoonlightBackupMode,
  localTable: boolean
): MoonlightBackupFilterResult {
  const result: Array<Record<string, string>> = [];
  let excludedRows: number = 0;
  const columns: string[] = localTable
    ? MOONLIGHT_LOCAL_RECORD_COLUMNS : MOONLIGHT_RECORD_COLUMNS;
  for (let i = 0; i < rows.length; i++) {
    const exact: Record<string, string> | null =
      copyExactRow(rows[i], columns);
    if (exact === null) {
      excludedRows++;
      continue;
    }
    if (localTable &&
      !moonlightLocalOnlyFlagIsValid(Number(exact['localonly']))) {
      excludedRows++;
      continue;
    }
    const record: MoonlightRecord = moonlightRecordFromCloudRow(exact);
    if (!moonlightValidateRecord(record).valid ||
      !recordTypeIsPortable(record, mode)) {
      excludedRows++;
      continue;
    }
    result.push(exact);
  }
  return { rows: result, excludedRows };
}

export function moonlightBackupRowsAreValid(
  rows: Array<Record<string, string>>,
  owner: string,
  mode: MoonlightBackupMode,
  localTable: boolean
): boolean {
  const filtered: MoonlightBackupFilterResult =
    filterMoonlightBackupRows(rows, mode, localTable);
  if (filtered.excludedRows !== 0 || filtered.rows.length !== rows.length) {
    return false;
  }
  for (let i = 0; i < rows.length; i++) {
    if (rows[i]['userid'] !== owner) { return false; }
  }
  return true;
}

function reboundRecord(
  row: Record<string, string>, targetOwner: string
): MoonlightRecord | null {
  const rebound: Record<string, string> = {};
  for (let i = 0; i < MOONLIGHT_RECORD_COLUMNS.length; i++) {
    const key: string = MOONLIGHT_RECORD_COLUMNS[i];
    if (typeof row[key] !== 'string') { return null; }
    rebound[key] = row[key];
  }
  rebound['userid'] = targetOwner;
  if (rebound['ownertype'] === 'account') {
    rebound['ownerid'] = targetOwner;
  }
  const record: MoonlightRecord = moonlightRecordFromCloudRow(rebound);
  return moonlightValidateRecord(record).valid ? record : null;
}

function localRestoreRow(
  record: MoonlightRecord
): Record<string, string> {
  const source: Record<string, string> =
    moonlightRecordToCloudRow(record);
  const row: Record<string, string> = {};
  for (let i = 0; i < MOONLIGHT_RECORD_COLUMNS.length; i++) {
    const key: string = MOONLIGHT_RECORD_COLUMNS[i];
    row[key] = source[key];
  }
  // Portable restore is intentionally local-first. Selected rows may be
  // promoted only after cloud-first bootstrap and explicit user consent.
  row['localonly'] = '1';
  return row;
}

/**
 * Resolve the cloud section and local overlay into one local-only projection.
 * No synthetic merge context is invented during restore. Ambiguous equal
 * envelopes and identity conflicts are quarantined instead of guessed.
 */
export function resolveMoonlightBackupForRestore(
  cloudRows: Array<Record<string, string>>,
  localRows: Array<Record<string, string>>,
  targetOwner: string,
  mode: MoonlightBackupMode
): MoonlightBackupRestoreResolution {
  const filteredCloud: MoonlightBackupFilterResult =
    filterMoonlightBackupRows(cloudRows, mode, false);
  const filteredLocal: MoonlightBackupFilterResult =
    filterMoonlightBackupRows(localRows, mode, true);
  const records: Map<string, MoonlightRecord> =
    new Map<string, MoonlightRecord>();
  const blockedIds: Set<string> = new Set<string>();
  let quarantinedRows: number = filteredCloud.excludedRows +
    filteredLocal.excludedRows;
  const candidates: Array<Record<string, string>> =
    filteredCloud.rows.concat(filteredLocal.rows);
  for (let i = 0; i < candidates.length; i++) {
    const candidate: MoonlightRecord | null =
      reboundRecord(candidates[i], targetOwner);
    const id: string = candidates[i]['id'] || '';
    if (candidate === null || id === '' || blockedIds.has(id)) {
      quarantinedRows++;
      continue;
    }
    const current: MoonlightRecord | undefined = records.get(id);
    if (current === undefined) {
      records.set(id, candidate);
      continue;
    }
    const decision: MoonlightConflictDecision =
      resolveMoonlightRecordConflict(current, candidate, null);
    if (decision.action === 'quarantine_both' ||
      decision.record === null) {
      records.delete(id);
      blockedIds.add(id);
      quarantinedRows += 2;
      continue;
    }
    if (decision.action === 'quarantine_candidate') {
      quarantinedRows++;
      continue;
    }
    records.set(id, decision.record);
  }
  // Same-ID conflict resolution cannot see prerelease aliases. Keep the
  // canonical payload-free delete/unpair boundary authoritative across IDs;
  // only a strictly higher reset epoch is an explicit revival.
  const logicalTombstones: Map<string, MoonlightRecord> =
    new Map<string, MoonlightRecord>();
  records.forEach((record: MoonlightRecord): void => {
    if (record.deletedAt === 0 ||
        (record.recordType !== 'host' && record.recordType !== 'trust')) {
      return;
    }
    const key: string = moonlightRestoreAliasFenceId(record);
    const current: MoonlightRecord | undefined = logicalTombstones.get(key);
    if (current === undefined || record.resetEpoch > current.resetEpoch ||
        (record.resetEpoch === current.resetEpoch &&
         record.syncVersion > current.syncVersion)) {
      logicalTombstones.set(key, record);
    }
  });
  const aliasIds: string[] = Array.from(records.keys());
  for (let i = 0; i < aliasIds.length; i++) {
    const record: MoonlightRecord = records.get(
      aliasIds[i]) as MoonlightRecord;
    if (record.deletedAt > 0 ||
        (record.recordType !== 'host' && record.recordType !== 'trust')) {
      continue;
    }
    const boundary: MoonlightRecord | undefined =
      logicalTombstones.get(moonlightRestoreAliasFenceId(record));
    if (boundary !== undefined &&
        boundary.resetEpoch >= record.resetEpoch) {
      records.delete(record.id);
      quarantinedRows++;
    }
  }
  const ids: string[] = Array.from(records.keys()).sort();
  const activeHostIds: Set<string> = new Set<string>();
  for (let i = 0; i < ids.length; i++) {
    const record: MoonlightRecord =
      records.get(ids[i]) as MoonlightRecord;
    if (record.recordType === 'host' && record.deletedAt === 0) {
      activeHostIds.add(record.id);
    }
  }
  const rows: Array<Record<string, string>> = [];
  for (let i = 0; i < ids.length; i++) {
    const record: MoonlightRecord =
      records.get(ids[i]) as MoonlightRecord;
    if ((record.recordType === 'profile' ||
      record.recordType === 'trust') &&
      record.deletedAt === 0 &&
      !activeHostIds.has(record.ownerId)) {
      quarantinedRows++;
      continue;
    }
    rows.push(localRestoreRow(record));
  }
  return {
    rows,
    quarantinedRows,
    sourceRows: cloudRows.length + localRows.length
  };
}
