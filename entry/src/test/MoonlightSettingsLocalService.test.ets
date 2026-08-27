import { describe, it, expect } from '@ohos/hypium';
import { MoonlightSettings, defaultMoonlightSettings } from '../main/ets/model/MoonlightModels';
import { MoonlightRecord } from '../main/ets/model/MoonlightRecord';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from '../main/ets/services/AccountScopePolicy';
import {
  MoonlightRepositoryCommit,
  MoonlightRepositoryPort,
  MoonlightRepositoryReadResult
} from '../main/ets/services/MoonlightRepository';
import {
  MoonlightRecordMeta,
  moonlightMutableFieldPaths,
  moonlightPayloadWithMeta,
  moonlightRecordPayloadHashSha256
} from '../main/ets/services/MoonlightRecordPolicy';
import { MoonlightSettingsLocalService } from '../main/ets/services/MoonlightSettingsLocalService';

function settingsLease(owner: string, generation: number = 1): AccountSessionLease {
  return {
    ownerScopeId: owner,
    storeIdentity: 'settings-store-' + owner,
    generation: generation,
    storeInstanceId: generation
  };
}

class MemorySettingsPort implements MoonlightRepositoryPort {
  activeLease: AccountSessionLease | null = settingsLease('owner-a');
  rows: MoonlightRecord[] = [];
  commitCount: number = 0;
  lastLocalOnly: number = -1;
  readbackFailure: boolean = false;

  currentAccountLease(): AccountSessionLease | null {
    return this.activeLease === null ? null : cloneAccountSessionLease(this.activeLease);
  }

  isLeaseCurrent(candidate: AccountSessionLease): boolean {
    return accountSessionLeaseEquals(this.activeLease, candidate);
  }

  readMoonlightLocalRecord(candidate: AccountSessionLease,
    id: string): MoonlightRepositoryReadResult {
    if (!this.isLeaseCurrent(candidate)) { return { ok: false, record: null, localOnly: 1 }; }
    for (let i = 0; i < this.rows.length; i++) {
      if (this.rows[i].userId === candidate.ownerScopeId && this.rows[i].id === id) {
        const copy = MoonlightRecord.fromJSON(this.rows[i].toJSON());
        if (this.readbackFailure) { copy.updatedAt += 1; }
        return { ok: true, record: copy, localOnly: 1 };
      }
    }
    return { ok: true, record: null, localOnly: 1 };
  }

  loadMoonlightLocalRecords(candidate: AccountSessionLease,
    includeDeleted: boolean = false): MoonlightRecord[] | null {
    if (!this.isLeaseCurrent(candidate)) { return null; }
    const result: MoonlightRecord[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      if (this.rows[i].userId === candidate.ownerScopeId &&
          (includeDeleted || this.rows[i].deletedAt === 0)) {
        result.push(MoonlightRecord.fromJSON(this.rows[i].toJSON()));
      }
    }
    return result;
  }

  commitMoonlightLocalRecord(candidate: AccountSessionLease,
    record: MoonlightRecord, localOnly: number,
    _operation: string): boolean {
    if (!this.isLeaseCurrent(candidate)) { return false; }
    for (let i = 0; i < this.rows.length; i++) {
      if (this.rows[i].userId === candidate.ownerScopeId && this.rows[i].id === record.id) {
        this.rows[i] = MoonlightRecord.fromJSON(record.toJSON());
        this.commitCount++;
        this.lastLocalOnly = localOnly;
        return true;
      }
    }
    this.rows.push(MoonlightRecord.fromJSON(record.toJSON()));
    this.commitCount++;
    this.lastLocalOnly = localOnly;
    return true;
  }

  commitMoonlightLocalRecords(candidate: AccountSessionLease,
    commits: MoonlightRepositoryCommit[]): boolean {
    if (!this.isLeaseCurrent(candidate)) { return false; }
    for (let i = 0; i < commits.length; i++) {
      if (!this.commitMoonlightLocalRecord(candidate, commits[i].record,
        commits[i].localOnly, commits[i].operation)) {
        return false;
      }
    }
    return true;
  }

  recordMoonlightQuarantine(candidate: AccountSessionLease,
    _recordId: string, _reason: string, _payloadHashSha256: string): boolean {
    return this.isLeaseCurrent(candidate);
  }
}

function legacySettingsRecord(owner: string): MoonlightRecord {
  const settings: MoonlightSettings = defaultMoonlightSettings();
  settings.video.scalingMode = 'fill';
  settings.background.allowPip = false;
  settings.video.fps = 120;
  settings.audio.enabled = false;
  const fieldVersions: Record<string, number> = {};
  const paths: string[] = moonlightMutableFieldPaths('settings');
  for (let index: number = 0; index < paths.length; index++) {
    fieldVersions[paths[index]] = 1;
  }
  const meta: MoonlightRecordMeta = {
    mutationId: 'legacy-settings-1', originId: 'legacy-local-store',
    baseSyncVersion: 0, fieldVersions: fieldVersions
  };
  const payload = moonlightPayloadWithMeta(
    JSON.parse(JSON.stringify(settings)) as Record<string, Object>, meta, 'settings');
  const record: MoonlightRecord = new MoonlightRecord();
  record.id = 'moonlight-settings|' + owner;
  record.userId = owner;
  record.recordType = 'settings';
  record.ownerId = owner;
  record.ownerType = 'account';
  record.payload = payload.canonical;
  record.syncVersion = 1;
  record.createdAt = 100;
  record.updatedAt = 100;
  record.payloadHashSha256 = moonlightRecordPayloadHashSha256(record);
  return record;
}

export default function moonlightSettingsLocalServiceTest(): void {
  describe('MoonlightSettingsLocalService', (): void => {
    it('loads_defaults_without_writing_when_no_local_settings_exist', 0, (): void => {
      const port = new MemorySettingsPort();
      const loaded = new MoonlightSettingsLocalService(port).load();
      expect(loaded.ok).assertTrue();
      expect(loaded.code).assertEqual('default');
      expect(port.commitCount).assertEqual(0);
    });

    it('commits_and_reads_owner_scoped_settings_as_local_only', 0, (): void => {
      const port = new MemorySettingsPort();
      const service = new MoonlightSettingsLocalService(port);
      const settings: MoonlightSettings = defaultMoonlightSettings();
      settings.video.fps = 120;
      const saved = service.save(settings, 1000);
      expect(saved.ok).assertTrue();
      expect(saved.localCommitted).assertTrue();
      expect(port.commitCount).assertEqual(1);
      expect(port.lastLocalOnly).assertEqual(1);
      expect(service.load().settings.video.fps).assertEqual(120);
    });

    it('loads_legacy_display_fields_without_rewriting_and_strips_them_on_next_save', 0,
      (): void => {
        const port = new MemorySettingsPort();
        port.rows.push(legacySettingsRecord('owner-a'));
        const service = new MoonlightSettingsLocalService(port);
        const loaded = service.load();
        expect(loaded.ok).assertTrue();
        expect(loaded.code).assertEqual('ok');
        expect(loaded.settings.video.fps).assertEqual(120);
        expect(loaded.settings.audio.enabled).assertFalse();
        expect(loaded.settings.video.scalingMode === undefined).assertTrue();
        expect(loaded.settings.background.allowPip === undefined).assertTrue();
        expect(port.commitCount).assertEqual(0);

        const saved = service.save(loaded.settings, 1000);
        expect(saved.ok).assertTrue();
        expect(port.rows[0].payload.indexOf('scalingMode')).assertEqual(-1);
        expect(port.rows[0].payload.indexOf('allowPip')).assertEqual(-1);
      });

    it('does_not_leak_settings_across_account_leases', 0, (): void => {
      const port = new MemorySettingsPort();
      const service = new MoonlightSettingsLocalService(port);
      const settings: MoonlightSettings = defaultMoonlightSettings();
      settings.audio.enabled = false;
      expect(service.save(settings, 1000).ok).assertTrue();
      port.activeLease = settingsLease('owner-b', 2);
      const ownerB = service.load();
      expect(ownerB.code).assertEqual('default');
      expect(ownerB.settings.audio.enabled).assertTrue();
    });

    it('rejects_a_draft_captured_under_a_stale_account_lease', 0, (): void => {
      const port = new MemorySettingsPort();
      const service = new MoonlightSettingsLocalService(port);
      const captured: AccountSessionLease = cloneAccountSessionLease(
        port.activeLease as AccountSessionLease);
      port.activeLease = settingsLease('owner-b', 2);
      const saved = service.save(defaultMoonlightSettings(), 1000, captured);
      expect(saved.code).assertEqual('stale_account');
      expect(saved.localCommitted).assertFalse();
      expect(port.commitCount).assertEqual(0);
    });

    it('fails_closed_without_an_active_local_account_lease', 0, (): void => {
      const port = new MemorySettingsPort();
      port.activeLease = null;
      const service = new MoonlightSettingsLocalService(port);
      expect(service.load().code).assertEqual('not_ready');
      expect(service.save(defaultMoonlightSettings(), 1000).localCommitted).assertFalse();
      expect(port.commitCount).assertEqual(0);
    });

    it('keeps_committed_truth_when_readback_fails_after_local_commit', 0, (): void => {
      const port = new MemorySettingsPort();
      port.readbackFailure = true;
      const saved = new MoonlightSettingsLocalService(port).save(defaultMoonlightSettings(), 1000);
      expect(saved.ok).assertTrue();
      expect(saved.code).assertEqual('pending_local_verification');
      expect(saved.localCommitted).assertTrue();
      expect(port.commitCount).assertEqual(1);
    });

    it('revives_a_settings_tombstone_with_a_higher_reset_epoch', 0, (): void => {
      const port = new MemorySettingsPort();
      const tombstone: MoonlightRecord = legacySettingsRecord('owner-a');
      tombstone.payload = '{}';
      tombstone.syncVersion = 2;
      tombstone.resetEpoch = 3;
      tombstone.updatedAt = 500;
      tombstone.deletedAt = 500;
      tombstone.payloadHashSha256 = moonlightRecordPayloadHashSha256(tombstone);
      port.rows.push(tombstone);
      const saved = new MoonlightSettingsLocalService(port).save(
        defaultMoonlightSettings(), 1000);
      expect(saved.ok).assertTrue();
      expect(saved.localCommitted).assertTrue();
      expect(port.rows[0].deletedAt).assertEqual(0);
      expect(port.rows[0].resetEpoch).assertEqual(4);
      expect(port.rows[0].syncVersion).assertEqual(3);
    });

    it('selects_the_newest_legacy_settings_record_instead_of_blocking_crud', 0,
      (): void => {
        const port = new MemorySettingsPort();
        const older: MoonlightRecord = legacySettingsRecord('owner-a');
        older.id = 'legacy-settings-a';
        older.payloadHashSha256 = moonlightRecordPayloadHashSha256(older);
        const newer: MoonlightRecord = legacySettingsRecord('owner-a');
        newer.id = 'legacy-settings-b';
        newer.syncVersion = 4;
        newer.updatedAt = 400;
        newer.payloadHashSha256 = moonlightRecordPayloadHashSha256(newer);
        port.rows.push(older);
        port.rows.push(newer);
        const service = new MoonlightSettingsLocalService(port);
        expect(service.load().code).assertEqual('ok');
        const saved = service.save(defaultMoonlightSettings(), 1000);
        expect(saved.ok).assertTrue();
        expect(port.rows[1].syncVersion).assertEqual(5);
      });

    it('keeps_a_same_epoch_tombstone_authoritative_over_a_canonical_live_alias',
      0, (): void => {
        const port = new MemorySettingsPort();
        const tombstone: MoonlightRecord = legacySettingsRecord('owner-a');
        tombstone.id = 'legacy-settings-deleted';
        tombstone.payload = '{}';
        tombstone.resetEpoch = 2;
        tombstone.syncVersion = 5;
        tombstone.updatedAt = 500;
        tombstone.deletedAt = 500;
        tombstone.payloadHashSha256 = moonlightRecordPayloadHashSha256(tombstone);
        const canonicalLive: MoonlightRecord = legacySettingsRecord('owner-a');
        canonicalLive.resetEpoch = 2;
        canonicalLive.syncVersion = 5;
        canonicalLive.updatedAt = 500;
        canonicalLive.payloadHashSha256 =
          moonlightRecordPayloadHashSha256(canonicalLive);
        port.rows.push(tombstone);
        port.rows.push(canonicalLive);

        const service = new MoonlightSettingsLocalService(port);
        const loaded = service.load();
        expect(loaded.ok).assertTrue();
        expect(loaded.code).assertEqual('default');
        const saved = service.save(
          defaultMoonlightSettings(), 1000);
        expect(saved.ok).assertTrue();
        expect(port.rows[0].deletedAt).assertEqual(0);
        expect(port.rows[0].resetEpoch).assertEqual(3);
        expect(port.rows[0].syncVersion).assertEqual(6);
        expect(port.rows[1].deletedAt > 0).assertTrue();
        expect(port.rows[1].syncVersion).assertEqual(6);
      });

    it('converges_live_legacy_settings_aliases_in_the_same_atomic_save', 0,
      (): void => {
        const port = new MemorySettingsPort();
        const older: MoonlightRecord = legacySettingsRecord('owner-a');
        older.id = 'legacy-settings-a';
        older.payloadHashSha256 = moonlightRecordPayloadHashSha256(older);
        const newer: MoonlightRecord = legacySettingsRecord('owner-a');
        newer.id = 'legacy-settings-b';
        newer.syncVersion = 4;
        newer.updatedAt = 400;
        newer.payloadHashSha256 = moonlightRecordPayloadHashSha256(newer);
        port.rows.push(older);
        port.rows.push(newer);

        const saved = new MoonlightSettingsLocalService(port).save(
          defaultMoonlightSettings(), 1000);
        expect(saved.ok).assertTrue();
        expect(port.rows[0].deletedAt > 0).assertTrue();
        expect(port.rows[0].syncVersion).assertEqual(2);
        expect(port.rows[1].deletedAt).assertEqual(0);
        expect(port.rows[1].syncVersion).assertEqual(5);
      });
  });
}
