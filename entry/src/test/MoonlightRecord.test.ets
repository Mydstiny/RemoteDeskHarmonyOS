import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  MOONLIGHT_APP_CACHE_TABLE,
  MOONLIGHT_CLOUD_TABLE,
  MOONLIGHT_LOCAL_RECORD_COLUMNS,
  MOONLIGHT_LOCAL_TABLE,
  MOONLIGHT_RECORD_COLUMNS,
  MoonlightLocalRecord,
  MoonlightRecord,
  moonlightLocalOnlyFlagIsValid,
  moonlightExpectedOwnerType,
  moonlightExpectedSecretKind
} from '../main/ets/model/MoonlightRecord';

export default function moonlightRecordTest(): void {
  describe('MoonlightRecord', (): void => {
    it('declares_one_cloud_table_and_two_local_tables', 0, (): void => {
      expect(MOONLIGHT_CLOUD_TABLE).assertEqual('moonlightrecordv1');
      expect(MOONLIGHT_LOCAL_TABLE).assertEqual('moonlightlocalrecords');
      expect(MOONLIGHT_APP_CACHE_TABLE).assertEqual('moonlightappcache');
      expect(MOONLIGHT_RECORD_COLUMNS.length).assertEqual(19);
      expect(MOONLIGHT_LOCAL_RECORD_COLUMNS.length).assertEqual(20);
      expect(MOONLIGHT_LOCAL_RECORD_COLUMNS[19]).assertEqual('localonly');
      for (let i = 0; i < MOONLIGHT_RECORD_COLUMNS.length; i++) {
        expect(MOONLIGHT_RECORD_COLUMNS[i]).assertEqual(MOONLIGHT_LOCAL_RECORD_COLUMNS[i]);
        expect(MOONLIGHT_RECORD_COLUMNS[i]).assertEqual(MOONLIGHT_RECORD_COLUMNS[i].toLowerCase());
      }
    });

    it('keeps_the_strict_owner_and_secret_matrix', 0, (): void => {
      expect(moonlightExpectedOwnerType('settings')).assertEqual('account');
      expect(moonlightExpectedOwnerType('host')).assertEqual('account');
      expect(moonlightExpectedOwnerType('profile')).assertEqual('host');
      expect(moonlightExpectedOwnerType('trust')).assertEqual('host');
      expect(moonlightExpectedOwnerType('secret')).assertEqual('account');
      expect(moonlightExpectedSecretKind('secret')).assertEqual('client_identity');
      expect(moonlightExpectedSecretKind('trust')).assertEqual('');
    });

    it('round_trips_the_exact_19_column_envelope', 0, (): void => {
      const record = new MoonlightRecord();
      record.id = 'host-1';
      record.userId = 'owner-1';
      record.recordType = 'host';
      record.ownerId = 'owner-1';
      record.ownerType = 'account';
      record.payload = '{"schemaVersion":1}';
      record.payloadHashSha256 = 'a'.repeat(64);
      record.syncVersion = 1;
      record.createdAt = 10;
      record.updatedAt = 11;
      const restored = MoonlightRecord.fromJSON(record.toJSON());
      expect(restored.id).assertEqual('host-1');
      expect(restored.recordType).assertEqual('host');
      expect(restored.payload).assertEqual('{"schemaVersion":1}');
      expect(restored.isDeleted()).assertFalse();
    });

    it('keeps_localonly_outside_the_cloud_envelope', 0, (): void => {
      const local = new MoonlightLocalRecord();
      local.id = 'local-host-1';
      local.localOnly = 1;
      const restored = MoonlightLocalRecord.fromLocalJSON(local.toLocalJSON());
      expect(restored.localOnly).assertEqual(1);
      expect(moonlightLocalOnlyFlagIsValid(restored.localOnly)).assertTrue();
      expect(moonlightLocalOnlyFlagIsValid(2)).assertFalse();
      expect(Object.keys(local.toJSON()).indexOf('localOnly')).assertEqual(-1);
      expect(Object.keys(local.toLocalJSON()).indexOf('localOnly') >= 0).assertTrue();
    });
  });
}
