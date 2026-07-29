import { describe, it, expect } from '@ohos/hypium';
import {
  VNC_CLOUD_SYNC_SELECTION_DEFAULT,
  isVncRecordTypeSelected,
  normalizeVncCloudSyncSelection,
  vncSecretSyncAllowed,
  vncSyncNeedsCrypto
} from '../main/ets/services/VncCloudSyncSelectionPolicy';

export default function vncCloudSyncSelectionPolicyTest(): void {
  describe('VncCloudSyncSelectionPolicy', (): void => {
    it('defaults_to_no_vnc_cloud_transfer_until_account_binding_is_validated', 0, (): void => {
      expect(VNC_CLOUD_SYNC_SELECTION_DEFAULT.length).assertEqual(0);
    });

    it('normalizes_only_the_independent_vnc_scopes', 0, (): void => {
      const selected: string[] = normalizeVncCloudSyncSelection([
        'hosts', 'not-a-scope', 'hosts', 'secrets'
      ]);
      expect(selected.length).assertEqual(2);
      expect(selected[0]).assertEqual('hosts');
      expect(selected[1]).assertEqual('secrets');
      expect(isVncRecordTypeSelected('host', selected)).assertTrue();
      expect(isVncRecordTypeSelected('gateway', selected)).assertFalse();
    });

    it('allows_explicit_secret_selection_without_crypto_readiness', 0, (): void => {
      const selected: string[] = ['settings', 'secrets'];
      expect(vncSyncNeedsCrypto(selected)).assertTrue();
      expect(vncSyncNeedsCrypto(selected, false)).assertFalse();
      expect(vncSecretSyncAllowed(selected, false)).assertTrue();
      expect(vncSecretSyncAllowed(selected, true)).assertTrue();
      expect(vncSecretSyncAllowed(['settings'], true)).assertFalse();
    });
  });
}
