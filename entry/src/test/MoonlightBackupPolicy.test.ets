import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  MOONLIGHT_APP_CACHE_TABLE,
  MOONLIGHT_CLOUD_TABLE,
  MOONLIGHT_LOCAL_TABLE,
  MoonlightRecord,
  MoonlightRecordType,
  moonlightRecordToCloudRow
} from '../main/ets/model/MoonlightRecord';
import {
  BackupManifestV3,
  BackupSectionManifestV3
} from '../main/ets/services/BackupManifestV3';
import {
  MoonlightRecordMeta,
  moonlightPayloadWithMeta,
  moonlightRecordPayloadHashSha256
} from '../main/ets/services/MoonlightRecordPolicy';
import {
  moonlightBackupRowsRequireCloudActivation,
  moonlightRestoreActivationState,
  moonlightRestoreRuntimeAdmissionAllowed,
  moonlightRestoreTransferBlocked,
  resolveMoonlightBackupForRestore
} from '../main/ets/services/MoonlightBackupPolicy';
import { CLOUD_SYNC_TABLES } from '../main/ets/services/CloudSyncPolicy';
import {
  adaptLocalBackupDocumentForRestore,
  createLocalBackupDocument,
  LOCAL_BACKUP_PORTABLE_TABLES,
  localBackupCanonicalPayload,
  LocalBackupDocument,
  localBackupSha256,
  validateLocalBackupDocument
} from '../main/ets/services/LocalBackupPolicy';

function portableTables():
  Record<string, Array<Record<string, string>>> {
  const result:
    Record<string, Array<Record<string, string>>> = {};
  for (let i = 0; i < LOCAL_BACKUP_PORTABLE_TABLES.length; i++) {
    result[LOCAL_BACKUP_PORTABLE_TABLES[i]] = [];
  }
  return result;
}

function meta(
  mutationId: string, type: MoonlightRecordType
): MoonlightRecordMeta {
  return {
    mutationId,
    originId: 'owner-a-origin',
    baseSyncVersion: 0,
    fieldVersions: type === 'host'
      ? { 'displayName': 1 } : {}
  };
}

function recordFromBusiness(
  type: MoonlightRecordType, id: string,
  ownerId: string, business: Record<string, Object>,
  mutationId: string, syncVersion: number = 1
): MoonlightRecord {
  const record = new MoonlightRecord();
  record.id = id;
  record.userId = 'owner-a';
  record.recordType = type;
  record.ownerId = ownerId;
  record.ownerType = type === 'profile' || type === 'trust'
    ? 'host' : 'account';
  record.secretKind = type === 'secret' ? 'client_identity' : '';
  record.payload = moonlightPayloadWithMeta(
    business, meta(mutationId, type), type).canonical;
  record.syncVersion = syncVersion;
  record.createdAt = 100;
  record.updatedAt = 100 + syncVersion;
  record.payloadHashSha256 =
    moonlightRecordPayloadHashSha256(record);
  return record;
}

function hostRecord(
  id: string = 'host-1', serverUuid: string = 'server-1',
  mutationId: string = 'host-mutation', syncVersion: number = 1
): MoonlightRecord {
  return recordFromBusiness('host', id, 'owner-a', {
    schemaVersion: 1,
    serverUuid,
    displayName: 'Living Room PC',
    addresses: [{ host: '192.0.2.10', family: 'ipv4', port: 47989 }],
    preferredAddressKey: 'ipv4|192.0.2.10|47989',
    hostType: 'sunshine',
    wakeOnLan: { enabled: false, mac: '', broadcast: '' },
    userOrder: 0
  }, mutationId, syncVersion);
}

function trustRecord(): MoonlightRecord {
  return recordFromBusiness('trust', 'trust-1', 'host-1', {
    schemaVersion: 1,
    hostId: 'host-1',
    serverUuid: 'server-1',
    serverCertificateSha256: 'a'.repeat(64),
    pairingGeneration: 1,
    candidateObservedAt: 200
  }, 'trust-mutation');
}

function identityRecord(): MoonlightRecord {
  const record: MoonlightRecord = recordFromBusiness(
    'secret', 'identity-1', 'owner-a', {
      schemaVersion: 1,
      identityVersion: 1,
      certificateSha256: 'b'.repeat(64),
      storageMode: 'cloudEncryptedPending'
    }, 'identity-mutation');
  record.ciphertext = 'AQID';
  record.envelopeVersion = 1;
  record.cryptoVersion = 1;
  record.keyVersion = 1;
  record.aadVersion = 1;
  record.payloadHashSha256 =
    moonlightRecordPayloadHashSha256(record);
  return record;
}

function localRow(
  record: MoonlightRecord, localOnly: string = '1'
): Record<string, string> {
  const source: Record<string, string> =
    moonlightRecordToCloudRow(record);
  const row: Record<string, string> = {};
  const keys: string[] = Object.keys(source);
  for (let i = 0; i < keys.length; i++) {
    row[keys[i]] = source[keys[i]];
  }
  row['localonly'] = localOnly;
  return row;
}

function sign(document: LocalBackupDocument): string {
  document.sha256 = localBackupSha256(localBackupCanonicalPayload(
    document.createdAt, document.appVersion, document.tables,
    document.extensions, document.version, document.localTables,
    document.manifest));
  return JSON.stringify(document);
}

export default function moonlightBackupPolicyTest(): void {
  describe('MoonlightBackupPolicy', (): void => {
    it('keeps_restored_rows_blocked_until_the_exact_marker_is_resolved',
      0, (): void => {
        expect(moonlightRestoreActivationState({
          state: 'absent', value: ''
        })).assertEqual('clear');
        expect(moonlightRestoreTransferBlocked({
          state: 'absent', value: ''
        })).assertFalse();
        expect(moonlightRestoreActivationState({
          state: 'present', value: '1'
        })).assertEqual('pending');
        expect(moonlightRestoreTransferBlocked({
          state: 'present', value: '1'
        })).assertTrue();
        expect(moonlightRestoreActivationState({
          state: 'present', value: 'corrupt'
        })).assertEqual('blocked');
        expect(moonlightRestoreTransferBlocked({
          state: 'error', value: ''
        })).assertTrue();
        expect(moonlightRestoreRuntimeAdmissionAllowed({
          state: 'absent', value: ''
        }, false)).assertTrue();
        expect(moonlightRestoreRuntimeAdmissionAllowed({
          state: 'present', value: '1'
        }, false)).assertFalse();
        expect(moonlightRestoreRuntimeAdmissionAllowed({
          state: 'present', value: '1'
        }, true)).assertTrue();
        expect(moonlightRestoreRuntimeAdmissionAllowed({
          state: 'present', value: 'corrupt'
        }, true)).assertFalse();
        expect(moonlightRestoreRuntimeAdmissionAllowed({
          state: 'error', value: ''
        }, true)).assertFalse();
      });

    it('requires_explicit_activation_only_for_cloud_eligible_restore_rows',
      0, (): void => {
        expect(moonlightBackupRowsRequireCloudActivation([
          { recordtype: 'trust' }
        ])).assertFalse();
        expect(moonlightBackupRowsRequireCloudActivation([
          { recordtype: 'secret' }, { recordtype: 'trust' }
        ])).assertFalse();
        expect(moonlightBackupRowsRequireCloudActivation([
          { recordtype: 'host' }
        ])).assertTrue();
        expect(moonlightBackupRowsRequireCloudActivation([
          { recordtype: 'profile' }, { recordtype: 'trust' }
        ])).assertTrue();
      });

    it('redacted_backup_keeps_config_but_omits_trust_and_identity', 0,
      (): void => {
        const tables = portableTables();
        tables[MOONLIGHT_CLOUD_TABLE] = [
          moonlightRecordToCloudRow(hostRecord()),
          moonlightRecordToCloudRow(trustRecord()),
          moonlightRecordToCloudRow(identityRecord())
        ];
        const document = createLocalBackupDocument(
          tables, 300, '1.1.0', [], {}, 'owner-a');
        expect(document.tables[MOONLIGHT_CLOUD_TABLE].length)
          .assertEqual(1);
        expect(document.tables[MOONLIGHT_CLOUD_TABLE][0]['recordtype'])
          .assertEqual('host');
        expect(document.manifest?.moonlight?.clientIdentityIncluded)
          .assertFalse();
        expect(document.manifest?.moonlight?.clientIdentityOmitted)
          .assertTrue();
        expect(document.manifest?.moonlight?.trustCandidatesIncluded)
          .assertFalse();
      });

    it('full_backup_adds_trust_candidate_but_still_omits_identity', 0,
      (): void => {
        const tables = portableTables();
        tables[MOONLIGHT_CLOUD_TABLE] = [
          moonlightRecordToCloudRow(hostRecord()),
          moonlightRecordToCloudRow(trustRecord()),
          moonlightRecordToCloudRow(identityRecord())
        ];
        const document = createLocalBackupDocument(
          tables, 300, '1.1.0', [], {}, 'owner-a', 5,
          true, 'full');
        expect(document.tables[MOONLIGHT_CLOUD_TABLE].length)
          .assertEqual(2);
        expect(JSON.stringify(document).indexOf('identity-1'))
          .assertEqual(-1);
        expect(document.manifest?.moonlight?.trustCandidatesIncluded)
          .assertTrue();
        expect(document.manifest?.moonlight?.clientIdentityIncluded)
          .assertFalse();
      });

    it('restore_materializes_only_the_local_overlay_and_requires_repairing',
      0, (): void => {
        const tables = portableTables();
        tables[MOONLIGHT_CLOUD_TABLE] = [
          moonlightRecordToCloudRow(hostRecord())
        ];
        const document = createLocalBackupDocument(
          tables, 300, '1.1.0', [], {}, 'owner-a');
        const plan = adaptLocalBackupDocumentForRestore(
          document, 'owner-a', false);
        expect(plan !== null).assertTrue();
        expect(plan?.presentTables.indexOf(MOONLIGHT_CLOUD_TABLE) < 0)
          .assertTrue();
        expect(plan?.presentLocalTables.indexOf(MOONLIGHT_LOCAL_TABLE) >= 0)
          .assertTrue();
        expect(plan?.localTables[MOONLIGHT_LOCAL_TABLE][0]['localonly'])
          .assertEqual('1');
      });

    it('exports_and_restores_device_local_moonlight_without_account_login',
      0, (): void => {
        const localHost: MoonlightRecord = hostRecord();
        localHost.userId = 'device-local';
        localHost.ownerId = 'device-local';
        localHost.payloadHashSha256 =
          moonlightRecordPayloadHashSha256(localHost);
        const document = createLocalBackupDocument(
          portableTables(), 300, '1.1.0', [], {
            moonlightlocalrecords: [localRow(localHost)]
          }, 'device-local');
        expect(document.localTables?.moonlightlocalrecords.length)
          .assertEqual(1);
        expect(document.localTables?.moonlightlocalrecords[0]['userid'])
          .assertEqual('device-local');
        const plan = adaptLocalBackupDocumentForRestore(
          document, 'device-local', false);
        expect(plan !== null).assertTrue();
        expect(plan?.presentLocalTables.indexOf(
          MOONLIGHT_LOCAL_TABLE) >= 0).assertTrue();
        expect(plan?.localTables[MOONLIGHT_LOCAL_TABLE][0]['localonly'])
          .assertEqual('1');
      });

    it('chooses_the_newer_identical_envelope_from_cloud_and_local', 0,
      (): void => {
        const cloud: MoonlightRecord = hostRecord();
        const local: MoonlightRecord =
          MoonlightRecord.fromJSON(cloud.toJSON());
        local.syncVersion = 2;
        local.updatedAt = 102;
        local.payloadHashSha256 =
          moonlightRecordPayloadHashSha256(local);
        const result = resolveMoonlightBackupForRestore(
          [moonlightRecordToCloudRow(cloud)],
          [localRow(local)], 'owner-a', 'redacted');
        expect(result.rows.length).assertEqual(1);
        expect(result.rows[0]['syncversion']).assertEqual('2');
        expect(result.rows[0]['localonly']).assertEqual('1');
      });

    it('preserves_a_tombstone_over_a_live_duplicate', 0, (): void => {
      const live: MoonlightRecord = hostRecord();
      const deleted: MoonlightRecord =
        MoonlightRecord.fromJSON(live.toJSON());
      deleted.payload = '{}';
      deleted.syncVersion = 2;
      deleted.updatedAt = 200;
      deleted.deletedAt = 200;
      deleted.payloadHashSha256 =
        moonlightRecordPayloadHashSha256(deleted);
      const result = resolveMoonlightBackupForRestore(
        [moonlightRecordToCloudRow(live)],
        [localRow(deleted)], 'owner-a', 'redacted');
      expect(result.rows.length).assertEqual(1);
      expect(result.rows[0]['deletedat']).assertEqual('200');
    });

    it('quarantines_both_rows_on_a_host_identity_conflict', 0,
      (): void => {
        const result = resolveMoonlightBackupForRestore([
          moonlightRecordToCloudRow(hostRecord(
            'host-1', 'server-a', 'a', 1))
        ], [localRow(hostRecord(
          'host-1', 'server-b', 'b', 2))],
        'owner-a', 'redacted');
        expect(result.rows.length).assertEqual(0);
        expect(result.quarantinedRows).assertEqual(2);
      });

    it('quarantines_a_live_trust_candidate_without_its_host', 0,
      (): void => {
        const result = resolveMoonlightBackupForRestore(
          [moonlightRecordToCloudRow(trustRecord())], [],
          'owner-a', 'full');
        expect(result.rows.length).assertEqual(0);
        expect(result.quarantinedRows).assertEqual(1);
      });

    it('rejects_unknown_moonlight_columns_even_after_outer_resigning', 0,
      (): void => {
        const tables = portableTables();
        tables[MOONLIGHT_CLOUD_TABLE] = [
          moonlightRecordToCloudRow(hostRecord())
        ];
        const document = createLocalBackupDocument(
          tables, 300, '1.1.0', [], {}, 'owner-a');
        document.tables[MOONLIGHT_CLOUD_TABLE][0]['future'] = 'unsafe';
        expect(validateLocalBackupDocument(sign(document)) === null)
          .assertTrue();
      });

    it('fails_backup_creation_instead_of_silently_dropping_a_corrupt_row',
      0, (): void => {
        const tables = portableTables();
        const invalid: Record<string, string> =
          moonlightRecordToCloudRow(hostRecord());
        invalid['payloadhashsha256'] = '0'.repeat(64);
        tables[MOONLIGHT_CLOUD_TABLE] = [invalid];
        let rejected: boolean = false;
        try {
          createLocalBackupDocument(
            tables, 300, '1.1.0', [], {}, 'owner-a');
        } catch (_error) {
          rejected = true;
        }
        expect(rejected).assertTrue();
      });

    it('accepts_pre_moonlight_v3_as_no_moonlight_data', 0,
      (): void => {
        const document = createLocalBackupDocument(
          portableTables(), 300, '1.0.10', [], {}, 'owner-a');
        delete document.tables[MOONLIGHT_CLOUD_TABLE];
        if (document.localTables !== undefined) {
          delete document.localTables[MOONLIGHT_LOCAL_TABLE];
        }
        const manifest: BackupManifestV3 =
          document.manifest as BackupManifestV3;
        delete manifest.moonlight;
        const kept: BackupSectionManifestV3[] = [];
        for (let i = 0; i < manifest.sections.length; i++) {
          if (manifest.sections[i].table !== MOONLIGHT_CLOUD_TABLE &&
            manifest.sections[i].table !== MOONLIGHT_LOCAL_TABLE) {
            kept.push(manifest.sections[i]);
          }
        }
        manifest.sections = kept;
        expect(validateLocalBackupDocument(sign(document)) !== null)
          .assertTrue();
      });

    it('makes_a_pre_moonlight_reader_reject_the_new_v3_inventory', 0,
      (): void => {
        const document = createLocalBackupDocument(
          portableTables(), 300, '1.1.0', [], {}, 'owner-a');
        const names: string[] = Object.keys(document.tables);
        let oldKnownCount: number = 0;
        for (let i = 0; i < CLOUD_SYNC_TABLES.length; i++) {
          if (names.indexOf(CLOUD_SYNC_TABLES[i]) >= 0) {
            oldKnownCount++;
          }
        }
        // This is the exact old-reader inventory gate: unknown Moonlight data
        // cannot be silently dropped while the rest of the backup is applied.
        expect(oldKnownCount === names.length).assertFalse();
        expect(names.indexOf(MOONLIGHT_CLOUD_TABLE) >= 0).assertTrue();
      });

    it('rejects_a_tampered_identity_inclusion_claim', 0, (): void => {
      const document = createLocalBackupDocument(
        portableTables(), 300, '1.1.0', [], {}, 'owner-a');
      const manifest: BackupManifestV3 =
        document.manifest as BackupManifestV3;
      if (manifest.moonlight !== undefined) {
        manifest.moonlight.clientIdentityIncluded = true;
      }
      expect(validateLocalBackupDocument(sign(document)) === null)
        .assertTrue();
    });

    it('never_serializes_the_non_portable_app_cache_table', 0,
      (): void => {
        const tables = portableTables();
        tables[MOONLIGHT_APP_CACHE_TABLE] = [{ id: 'cache-1' }];
        const document = createLocalBackupDocument(
          tables, 300, '1.1.0', [], {}, 'owner-a');
        expect(JSON.stringify(document)
          .indexOf(MOONLIGHT_APP_CACHE_TABLE)).assertEqual(-1);
        expect(document.tables[MOONLIGHT_APP_CACHE_TABLE] === undefined)
          .assertTrue();
      });
  });
}
