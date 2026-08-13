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
  MoonlightRepositoryPort,
  MoonlightRepositoryResult
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
  for (let i = 0; i < records.length; i++) {
    if (records[i].recordType !== 'settings' ||
        records[i].ownerId !== ownerScopeId) { continue; }
    if (selected !== null) { return null; }
    selected = records[i];
  }
  return selected;
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
    const records: MoonlightRecord[] | null = this.repository.loadAll(lease);
    if (records === null) { return result(false, 'read_failed', defaultMoonlightSettings()); }
    const record: MoonlightRecord | null =
      currentSettingsRecord(records, lease.ownerScopeId);
    if (record === null) {
      let count: number = 0;
      for (let i = 0; i < records.length; i++) {
        if (records[i].recordType === 'settings' && records[i].ownerId === lease.ownerScopeId) {
          count++;
        }
      }
      return result(count > 1 ? false : true,
        count > 1 ? 'duplicate_settings' : 'default', defaultMoonlightSettings());
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
    const records: MoonlightRecord[] | null = this.repository.loadAll(captured);
    if (records === null) { return result(false, 'read_failed', normalized); }
    const current: MoonlightRecord | null = currentSettingsRecord(records, captured.ownerScopeId);
    if (current === null) {
      let count: number = 0;
      for (let i = 0; i < records.length; i++) {
        if (records[i].recordType === 'settings' && records[i].ownerId === captured.ownerScopeId) {
          count++;
        }
      }
      if (count > 1) { return result(false, 'duplicate_settings', normalized); }
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
    record.syncVersion = nextVersion;
    record.createdAt = current === null ? nowMs : current.createdAt;
    record.updatedAt = Math.max(nowMs, record.createdAt,
      current === null ? 0 : current.updatedAt);
    record.payloadHashSha256 = moonlightRecordPayloadHashSha256(record);
    const saved: MoonlightRepositoryResult = this.repository.upsert(captured, record, 1);
    return result(saved.ok, saved.code, normalized, saved.localCommitted);
  }
}
