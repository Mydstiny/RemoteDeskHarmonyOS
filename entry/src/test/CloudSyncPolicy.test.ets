import { describe, it, expect } from '@ohos/hypium';
import {
  CLOUD_SYNC_TABLES,
  OPTIONAL_CLOUD_SYNC_TABLES,
  cloudDistributedRegistrationPlan,
  cloudRollbackRequiresOptionalQuarantine,
  cloudRollbackRestoreTableNames,
  cloudSnapshotTableNames,
  coreCloudSyncTableNames,
  cloudSyncDirectionForOperation,
  cloudPullOrder,
  cloudSyncTableNames,
  cloudOperationRequiresConfirmation
} from '../main/ets/services/CloudSyncPolicy';

export default function cloudSyncPolicyTest() {
  describe('CloudSyncPolicy', (): void => {
    it('registers_every_configured_cloud_data_type_exactly_once', 0, (): void => {
      const tables: string[] = cloudSyncTableNames();
      expect(tables.length).assertEqual(9);
      expect(tables[0]).assertEqual('cryptoparams');
      expect(tables.indexOf('rdpcredentials') >= 0).assertTrue();
      expect(tables.indexOf('remotehosts') >= 0).assertTrue();
      expect(tables.indexOf('rustdeskrelays') >= 0).assertTrue();
      expect(tables.indexOf('sshkeys') >= 0).assertTrue();
      expect(tables.indexOf('totpentries') >= 0).assertTrue();
      expect(tables.indexOf('usersettings') >= 0).assertTrue();
      expect(tables.indexOf('vncrecordv2')).assertEqual(7);
      expect(tables.indexOf('moonlightrecordv1')).assertEqual(8);
      expect(tables.indexOf('vncrecords')).assertEqual(-1);
      expect(CLOUD_SYNC_TABLES.length).assertEqual(8);
      expect(coreCloudSyncTableNames().length).assertEqual(8);
      expect(OPTIONAL_CLOUD_SYNC_TABLES.length).assertEqual(1);
    });

    it('always_registers_the_legacy_eight_table_baseline_before_optional_tables',
      0, (): void => {
        const plan = cloudDistributedRegistrationPlan();
        expect(plan.baseline.length).assertEqual(8);
        expect(plan.baseline.indexOf('moonlightrecordv1')).assertEqual(-1);
        expect(plan.optionalSuperset.length).assertEqual(9);
        for (let i = 0; i < plan.baseline.length; i++) {
          expect(plan.optionalSuperset[i]).assertEqual(plan.baseline[i]);
        }
        expect(plan.optionalSuperset[8]).assertEqual('moonlightrecordv1');
        // Callers receive copies, so a failed optional registration or a test
        // mutation cannot corrupt the process-wide compatibility baseline.
        plan.baseline.splice(0, 1);
        plan.optionalSuperset.splice(0, 1);
        expect(cloudDistributedRegistrationPlan().baseline.length)
          .assertEqual(8);
        expect(cloudDistributedRegistrationPlan().optionalSuperset.length)
          .assertEqual(9);
      });

    it('keeps_legacy_snapshots_operational_when_optional_schema_is_missing',
      0, (): void => {
        const legacy: string[] = cloudSnapshotTableNames(false);
        const upgraded: string[] = cloudSnapshotTableNames(true);
        expect(legacy.length).assertEqual(8);
        expect(legacy.indexOf('moonlightrecordv1')).assertEqual(-1);
        expect(upgraded.length).assertEqual(9);
        expect(upgraded[8]).assertEqual('moonlightrecordv1');
        legacy.splice(0, 1);
        expect(cloudSnapshotTableNames(false).length).assertEqual(8);
      });

    it('recovers_core_rows_when_a_newer_optional_before_image_is_unavailable',
      0, (): void => {
        expect(cloudRollbackRestoreTableNames(
          true, false).length).assertEqual(8);
        expect(cloudRollbackRestoreTableNames(
          true, false).indexOf('moonlightrecordv1'))
          .assertEqual(-1);
        expect(cloudRollbackRequiresOptionalQuarantine(
          true, false)).assertTrue();
        expect(cloudRollbackRestoreTableNames(
          true, true).length).assertEqual(9);
        expect(cloudRollbackRequiresOptionalQuarantine(
          true, true)).assertFalse();
        expect(cloudRollbackRequiresOptionalQuarantine(
          false, false)).assertFalse();
      });

    it('pulls_crypto_before_every_encrypted_business_table', 0, (): void => {
      const order: string[] = cloudPullOrder();
      expect(order.length).assertEqual(9);
      expect(order[0]).assertEqual('cryptoparams');
      expect(order.indexOf('sshkeys') > 0).assertTrue();
      expect(order.indexOf('totpentries') > 0).assertTrue();
      expect(order.indexOf('remotehosts') > 0).assertTrue();
    });

    it('requires_a_second_confirmation_for_destructive_manual_operations', 0, (): void => {
      expect(cloudOperationRequiresConfirmation('upload')).assertTrue();
      expect(cloudOperationRequiresConfirmation('download')).assertTrue();
      expect(cloudOperationRequiresConfirmation('refresh')).assertFalse();
    });

    it('uses_forced_cloud_pull_for_recovery_and_forced_native_push_for_local_changes', 0, (): void => {
      expect(cloudSyncDirectionForOperation('startupPull')).assertEqual('cloudFirst');
      expect(cloudSyncDirectionForOperation('manualDownload')).assertEqual('cloudFirst');
      expect(cloudSyncDirectionForOperation('manualUpload')).assertEqual('nativeFirst');
      expect(cloudSyncDirectionForOperation('automaticPush')).assertEqual('nativeFirst');
    });
  });
}
