import {
  MoonlightSettings,
  defaultMoonlightSettings,
  moonlightSettingsAreValid,
  normalizeMoonlightSettingsForLocalStorage
} from '../model/MoonlightModels';
import { MoonlightRecord } from '../model/MoonlightRecord';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from './AccountScopePolicy';
import {
  MoonlightRecordMeta,
  moonlightMutableFieldPaths,
  moonlightPayloadWithMeta,
  moonlightRecordBusinessPayload,
  moonlightRecordPayloadHashSha256
} from './MoonlightRecordPolicy';
import {
  MoonlightRepository,
  MoonlightRepositoryBatchMutation,
  MoonlightRepositoryBatchResult,
  MoonlightRepositoryPort
} from './MoonlightRepository';

export interface MoonlightLocalSettingsResult {
  ok: boolean;
  code: string;
  settings: MoonlightSettings;
  localCommitted: boolean;
}

function cloneSettings(settings: MoonlightSettings): MoonlightSettings {
  return JSON.parse(JSON.stringify(settings)) as MoonlightSettings;
}

function result(ok: boolean, code: string, settings: MoonlightSettings,
  localCommitted: boolean = false): MoonlightLocalSettingsResult {
  return { ok: ok, code: code, settings: cloneSettings(settings),
    localCommitted: localCommitted };
}

function settingsRecordId(ownerScopeId: string): string {
  const normalized: string = ownerScopeId.trim();
  if (normalized === '') { return ''; }
  const id: string = 'moonlight-settings|' + normalized;
  return id.length <= 128 ? id : '';
}

function currentSettingsRecord(records: MoonlightRecord[],
  ownerScopeId: string): MoonlightRecord | null {
  let selected: MoonlightRecord | null = null;
  const canonicalId: string = settingsRecordId(ownerScopeId);
  for (let i = 0; i < records.length; i++) {
    if (records[i].recordType !== 'settings' ||
        records[i].ownerId !== ownerScopeId) { continue; }
    if (selected === null || settingsRecordIsPreferred(
      records[i], selected, canonicalId)) {
      selected = records[i];
    }
  }
  return selected;
}

function settingsRecordIsPreferred(candidate: MoonlightRecord,
  current: MoonlightRecord, canonicalId: string): boolean {
  if (candidate.resetEpoch !== current.resetEpoch) {
    return candidate.resetEpoch > current.resetEpoch;
  }
  const candidateDeleted: boolean = candidate.deletedAt > 0;
  const currentDeleted: boolean = current.deletedAt > 0;
  if (candidateDeleted !== currentDeleted) { return candidateDeleted; }
  if (candidate.syncVersion !== current.syncVersion) {
    return candidate.syncVersion > current.syncVersion;
  }
  if (candidate.updatedAt !== current.updatedAt) {
    return candidate.updatedAt > current.updatedAt;
  }
  const candidateCanonical: boolean = candidate.id === canonicalId;
  const currentCanonical: boolean = current.id === canonicalId;
  if (candidateCanonical !== currentCanonical) { return candidateCanonical; }
  return candidate.id < current.id;
}

function settingsAliasTombstone(current: MoonlightRecord,
  nowMs: number): MoonlightRecord | null {
  const tombstone: MoonlightRecord =
    MoonlightRecord.fromJSON(current.toJSON());
  tombstone.payload = '{}';
  tombstone.ciphertext = '';
  tombstone.envelopeVersion = 0;
  tombstone.cryptoVersion = 0;
  tombstone.keyVersion = 0;
  tombstone.aadVersion = 0;
  if (current.syncVersion >= Number.MAX_SAFE_INTEGER) {
    if (current.resetEpoch >= Number.MAX_SAFE_INTEGER) { return null; }
    tombstone.resetEpoch = current.resetEpoch + 1;
    tombstone.syncVersion = 1;
  } else {
    tombstone.syncVersion = current.syncVersion + 1;
  }
  tombstone.updatedAt = Math.max(nowMs, current.updatedAt, current.createdAt);
  tombstone.deletedAt = tombstone.updatedAt;
  tombstone.payloadHashSha256 = moonlightRecordPayloadHashSha256(tombstone);
  return tombstone;
}

export class MoonlightSettingsLocalService {
  private readonly port: MoonlightRepositoryPort;
  private readonly repository: MoonlightRepository;

  constructor(port: MoonlightRepositoryPort) {
    this.port = port;
    this.repository = new MoonlightRepository(port);
  }

  load(): MoonlightLocalSettingsResult {
    const lease: AccountSessionLease | null = this.port.currentAccountLease();
    if (lease === null) { return result(false, 'not_ready', defaultMoonlightSettings()); }
    // Deleted legacy aliases remain part of conflict resolution. Filtering
    // tombstones here can expose an older live alias and silently resurrect
    // settings after an upgrade or interrupted cloud convergence.
    const records: MoonlightRecord[] | null =
      this.repository.loadAll(lease, true);
    if (records === null) { return result(false, 'read_failed', defaultMoonlightSettings()); }
    const record: MoonlightRecord | null =
      currentSettingsRecord(records, lease.ownerScopeId);
    if (record === null || record.deletedAt > 0) {
      return result(true, 'default', defaultMoonlightSettings());
    }
    const payload: Record<string, Object> | null = moonlightRecordBusinessPayload(record);
    if (payload === null) { return result(false, 'invalid_record', defaultMoonlightSettings()); }
    const settings: MoonlightSettings = payload as Object as MoonlightSettings;
    const normalized: MoonlightSettings = normalizeMoonlightSettingsForLocalStorage(settings);
    return moonlightSettingsAreValid(normalized) ? result(true, 'ok', normalized) :
      result(false, 'invalid_settings', defaultMoonlightSettings());
  }

  save(settings: MoonlightSettings, nowMs: number,
    expectedLease: AccountSessionLease | null = null): MoonlightLocalSettingsResult {
    const normalized: MoonlightSettings = normalizeMoonlightSettingsForLocalStorage(settings);
    if (!moonlightSettingsAreValid(normalized) || !Number.isSafeInteger(nowMs) || nowMs <= 0) {
      return result(false, 'invalid_settings', normalized);
    }
    const lease: AccountSessionLease | null = this.port.currentAccountLease();
    if (lease === null) { return result(false, 'not_ready', normalized); }
    if (expectedLease !== null && !accountSessionLeaseEquals(lease, expectedLease)) {
      return result(false, 'stale_account', normalized);
    }
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    const records: MoonlightRecord[] | null =
      this.repository.loadAll(captured, true);
    if (records === null) { return result(false, 'read_failed', normalized); }
    const current: MoonlightRecord | null = currentSettingsRecord(records, captured.ownerScopeId);
    let hasLiveAlias: boolean = false;
    const canonicalId: string = settingsRecordId(captured.ownerScopeId);
    for (let i = 0; i < records.length; i++) {
      if (records[i].recordType === 'settings' &&
          records[i].ownerId === captured.ownerScopeId &&
          records[i].id !== (current === null ? canonicalId : current.id) &&
          records[i].deletedAt === 0) {
        hasLiveAlias = true;
        break;
      }
    }
    const nextVersion: number = current === null ? 1 : current.syncVersion + 1;
    if (!Number.isSafeInteger(nextVersion) || nextVersion < 1) {
      return result(false, 'version_exhausted', normalized);
    }
    const fieldVersions: Record<string, number> = {};
    const paths: string[] = moonlightMutableFieldPaths('settings');
    for (let i = 0; i < paths.length; i++) { fieldVersions[paths[i]] = nextVersion; }
    const meta: MoonlightRecordMeta = {
      mutationId: 'settings-' + nowMs.toString() + '-' + nextVersion.toString(),
      originId: ('moonlight-ui|' + captured.storeIdentity).substring(0, 128),
      baseSyncVersion: current === null ? 0 : current.syncVersion,
      fieldVersions: fieldVersions
    };
    const business: Record<string, Object> =
      JSON.parse(JSON.stringify(normalized)) as Record<string, Object>;
    const payload = moonlightPayloadWithMeta(business, meta, 'settings');
    if (!payload.ok) { return result(false, payload.reason, normalized); }
    const recordId: string = current === null ? settingsRecordId(captured.ownerScopeId) : current.id;
    if (recordId === '') { return result(false, 'invalid_settings', normalized); }
    const record: MoonlightRecord = new MoonlightRecord();
    record.id = recordId;
    record.userId = captured.ownerScopeId;
    record.recordType = 'settings';
    record.ownerId = captured.ownerScopeId;
    record.ownerType = 'account';
    record.payload = payload.canonical;
    record.resetEpoch = current !== null &&
      (current.deletedAt > 0 || hasLiveAlias) ?
      current.resetEpoch + 1 : current === null ? 0 : current.resetEpoch;
    if (!Number.isSafeInteger(record.resetEpoch) || record.resetEpoch < 0) {
      return result(false, 'version_exhausted', normalized);
    }
    record.syncVersion = nextVersion;
    record.createdAt = current === null ? nowMs : current.createdAt;
    record.updatedAt = Math.max(nowMs, record.createdAt,
      current === null ? 0 : current.updatedAt);
    record.payloadHashSha256 = moonlightRecordPayloadHashSha256(record);
    const mutations: MoonlightRepositoryBatchMutation[] = [
      { record: record, localOnly: 1 }
    ];
    let aliasOffset: number = 1;
    for (let i = 0; i < records.length; i++) {
      if (records[i].recordType !== 'settings' ||
          records[i].ownerId !== captured.ownerScopeId ||
          records[i].id === record.id || records[i].deletedAt > 0) {
        continue;
      }
      const alias: MoonlightRecord | null = settingsAliasTombstone(
        records[i], nowMs + aliasOffset);
      if (alias === null) {
        return result(false, 'version_exhausted', normalized);
      }
      mutations.push({ record: alias, localOnly: 1 });
      aliasOffset++;
    }
    const saved: MoonlightRepositoryBatchResult =
      this.repository.upsertBatch(captured, mutations);
    if (saved.ok) {
      return result(true, saved.code, normalized, saved.localCommitted);
    }
    if (saved.localCommitted && saved.code === 'readback_failed') {
      return result(true, 'pending_local_verification', normalized, true);
    }
    return result(false, saved.code, normalized, saved.localCommitted);
  }
}
