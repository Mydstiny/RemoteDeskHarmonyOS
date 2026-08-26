import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  defaultMoonlightSettings,
  MoonlightInputControlMode
} from '../main/ets/model/MoonlightModels';
import { MoonlightRecord, MoonlightRecordType } from '../main/ets/model/MoonlightRecord';
import {
  MoonlightRecordMeta,
  moonlightPayloadWithMeta,
  moonlightRecordPayloadHashSha256
} from '../main/ets/services/MoonlightRecordPolicy';
import {
  compareMoonlightRecordEnvelope,
  resolveMoonlightRecordConflict
} from '../main/ets/services/MoonlightRecordConflictPolicy';

function recordFromPayload(recordType: MoonlightRecordType, id: string, ownerId: string,
  business: Record<string, Object>, meta: MoonlightRecordMeta, syncVersion: number,
  updatedAt: number): MoonlightRecord {
  const record = new MoonlightRecord();
  record.id = id;
  record.userId = 'owner-1';
  record.recordType = recordType;
  record.ownerId = ownerId;
  record.ownerType = recordType === 'profile' || recordType === 'trust' ? 'host' : 'account';
  record.secretKind = recordType === 'secret' ? 'client_identity' : '';
  record.payload = moonlightPayloadWithMeta(business, meta, recordType).canonical;
  record.syncVersion = syncVersion;
  record.createdAt = 100;
  record.updatedAt = updatedAt;
  record.payloadHashSha256 = moonlightRecordPayloadHashSha256(record);
  return record;
}

function settingsRecord(mutationId: string, base: number, syncVersion: number,
  updatedAt: number, fps: number, bitrate: number,
  versions: Record<string, number>, legacyInputRecord: boolean = false,
  controlMode: MoonlightInputControlMode = 'adaptive'): MoonlightRecord {
  const values = defaultMoonlightSettings();
  values.video.fps = fps;
  values.video.bitrateKbps = bitrate;
  values.input.controlMode = legacyInputRecord ? undefined : controlMode;
  return recordFromPayload('settings', 'settings-1', 'owner-1', values as Record<string, Object>, {
    mutationId: mutationId, originId: 'origin-1', baseSyncVersion: base, fieldVersions: versions
  }, syncVersion, updatedAt);
}

function hostRecord(serverUuid: string, mutationId: string, syncVersion: number): MoonlightRecord {
  return recordFromPayload('host', 'host-1', 'owner-1', {
    schemaVersion: 1, serverUuid: serverUuid, displayName: 'PC',
    addresses: [{ host: '192.0.2.1', family: 'ipv4', port: 47989 }],
    preferredAddressKey: 'ipv4|192.0.2.1|47989', hostType: 'sunshine',
    wakeOnLan: { enabled: false, mac: '', broadcast: '' }, userOrder: 0
  }, { mutationId: mutationId, originId: 'origin-1', baseSyncVersion: 0,
    fieldVersions: { 'displayName': syncVersion } }, syncVersion, 100 + syncVersion);
}

function tombstoneFrom(source: MoonlightRecord, syncVersion: number,
  resetEpoch: number): MoonlightRecord {
  const result = MoonlightRecord.fromJSON(source.toJSON());
  result.payload = '{}';
  result.ciphertext = '';
  result.envelopeVersion = 0;
  result.cryptoVersion = 0;
  result.keyVersion = 0;
  result.aadVersion = 0;
  result.syncVersion = syncVersion;
  result.resetEpoch = resetEpoch;
  result.updatedAt = 500;
  result.deletedAt = 500;
  result.payloadHashSha256 = moonlightRecordPayloadHashSha256(result);
  return result;
}

export default function moonlightRecordConflictPolicyTest(): void {
  describe('MoonlightRecordConflictPolicy', (): void => {
    it('orders_envelopes_without_using_wall_clock_as_primary_truth', 0, (): void => {
      const left = settingsRecord('a', 0, 2, 10, 60, 20000, { 'video.fps': 2 });
      const right = settingsRecord('b', 0, 1, 9999, 30, 20000, { 'video.fps': 1 });
      expect(compareMoonlightRecordEnvelope(left, right)).assertEqual(1);
      right.resetEpoch = 1;
      right.payloadHashSha256 = moonlightRecordPayloadHashSha256(right);
      expect(compareMoonlightRecordEnvelope(left, right)).assertEqual(-1);
    });

    it('treats_exact_retry_as_idempotent_and_mutation_reuse_as_corruption', 0, (): void => {
      const current = settingsRecord('same', 0, 1, 100, 60, 20000, { 'video.fps': 1 });
      const retry = MoonlightRecord.fromJSON(current.toJSON());
      expect(resolveMoonlightRecordConflict(current, retry).reason).assertEqual('identical_retry');
      const corrupted = settingsRecord('same', 0, 1, 100, 30, 20000, { 'video.fps': 1 });
      const result = resolveMoonlightRecordConflict(current, corrupted);
      expect(result.action).assertEqual('quarantine_both');
      expect(result.reason).assertEqual('mutation_reuse_corruption');
    });

    it('merges_disjoint_concurrent_setting_fields_into_a_new_version', 0, (): void => {
      const current = settingsRecord('writer-a', 1, 2, 200, 30, 20000, { 'video.fps': 2 });
      const candidate = settingsRecord('writer-b', 1, 2, 201, 60, 40000,
        { 'video.bitrateKbps': 2 });
      const result = resolveMoonlightRecordConflict(current, candidate, {
        mutationId: 'merge-1', originId: 'merge-origin', updatedAt: 300
      });
      expect(result.action).assertEqual('write_merged');
      expect(result.record === null).assertFalse();
      const payload = JSON.parse((result.record as MoonlightRecord).payload) as Record<string, Object>;
      const video = payload['video'] as Record<string, Object>;
      expect(video['fps'] as number).assertEqual(30);
      expect(video['bitrateKbps'] as number).assertEqual(40000);
      expect((result.record as MoonlightRecord).syncVersion).assertEqual(3);
    });

    it('records_same_field_conflicts_but_resolves_by_envelope_order', 0, (): void => {
      const current = settingsRecord('writer-a', 1, 2, 200, 30, 20000, { 'video.fps': 2 });
      const candidate = settingsRecord('writer-b', 1, 2, 201, 60, 20000, { 'video.fps': 2 });
      const result = resolveMoonlightRecordConflict(current, candidate, {
        mutationId: 'merge-2', originId: 'merge-origin', updatedAt: 300
      });
      expect(result.action).assertEqual('write_merged');
      expect(result.conflictedPaths[0]).assertEqual('video.fps');
      const payload = JSON.parse((result.record as MoonlightRecord).payload) as Record<string, Object>;
      expect((payload['video'] as Record<string, Object>)['fps'] as number).assertEqual(60);
    });

    it('merges_a_legacy_settings_writer_that_has_no_additive_control_mode', 0,
      (): void => {
        const current = settingsRecord('new-writer', 1, 2, 200, 60, 20000,
          { 'input.controlMode': 2 }, false, 'keyboardMouse');
        const legacy = settingsRecord('legacy-writer', 1, 2, 201, 30, 20000,
          { 'video.fps': 2 }, true);
        const result = resolveMoonlightRecordConflict(current, legacy, {
          mutationId: 'merge-legacy-control', originId: 'merge-origin', updatedAt: 300
        });
        expect(result.action).assertEqual('write_merged');
        expect(result.reason).assertEqual('concurrent_fields_merged');
        expect(result.record === null).assertFalse();
        const payload = JSON.parse(
          (result.record as MoonlightRecord).payload) as Record<string, Object>;
        const input = payload['input'] as Record<string, Object>;
        const video = payload['video'] as Record<string, Object>;
        expect(input['controlMode'] as string).assertEqual('keyboardMouse');
        expect(video['fps'] as number).assertEqual(30);
      });

    it('fails_closed_on_equal_envelope_different_content', 0, (): void => {
      const current = settingsRecord('writer-a', 0, 1, 100, 30, 20000, { 'video.fps': 1 });
      const candidate = settingsRecord('writer-b', 0, 1, 100, 60, 20000, { 'video.fps': 1 });
      const result = resolveMoonlightRecordConflict(current, candidate, {
        mutationId: 'merge-3', originId: 'merge-origin', updatedAt: 200
      });
      expect(result.action).assertEqual('quarantine_both');
      expect(result.reason).assertEqual('same_envelope_content_mismatch');
    });

    it('makes_tombstones_win_same_epoch_and_requires_higher_epoch_revival', 0, (): void => {
      const live = settingsRecord('live', 0, 5, 400, 60, 20000, { 'video.fps': 5 });
      const deleted = tombstoneFrom(live, 4, 0);
      expect(resolveMoonlightRecordConflict(live, deleted).reason).assertEqual('tombstone_wins');
      const revival = settingsRecord('revive', 5, 1, 600, 60, 20000, { 'video.fps': 1 });
      revival.resetEpoch = 1;
      revival.payloadHashSha256 = moonlightRecordPayloadHashSha256(revival);
      const revived = resolveMoonlightRecordConflict(deleted, revival);
      expect(revived.action).assertEqual('accept_candidate');
      expect(revived.reason).assertEqual('explicit_revival');
    });

    it('blocks_host_identity_conflicts_even_when_candidate_envelope_is_newer', 0, (): void => {
      const current = hostRecord('server-a', 'a', 1);
      const candidate = hostRecord('server-b', 'b', 2);
      const result = resolveMoonlightRecordConflict(current, candidate);
      expect(result.action).assertEqual('quarantine_both');
      expect(result.reason).assertEqual('host_identity_conflict');
    });
  });
}
