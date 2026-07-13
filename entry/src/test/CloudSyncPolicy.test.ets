import { describe, it, expect } from '@ohos/hypium';
import {
  CLOUD_SYNC_TABLES,
  cloudSyncDirectionForOperation,
  cloudPullOrder,
  cloudSyncTableNames,
  cloudOperationRequiresConfirmation
} from '../main/ets/services/CloudSyncPolicy';

export default function cloudSyncPolicyTest() {
  describe('CloudSyncPolicy', (): void => {
    it('registers_every_configured_cloud_data_type_exactly_once', 0, (): void => {
      const tables: string[] = cloudSyncTableNames();
      expect(tables.length).assertEqual(7);
      expect(tables[0]).assertEqual('cryptoparams');
      expect(tables.indexOf('rdpcredentials') >= 0).assertTrue();
      expect(tables.indexOf('remotehosts') >= 0).assertTrue();
      expect(tables.indexOf('rustdeskrelays') >= 0).assertTrue();
      expect(tables.indexOf('sshkeys') >= 0).assertTrue();
      expect(tables.indexOf('totpentries') >= 0).assertTrue();
      expect(tables.indexOf('usersettings') >= 0).assertTrue();
      expect(CLOUD_SYNC_TABLES.length).assertEqual(tables.length);
    });

    it('pulls_crypto_before_every_encrypted_business_table', 0, (): void => {
      const order: string[] = cloudPullOrder();
      expect(order.length).assertEqual(7);
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
