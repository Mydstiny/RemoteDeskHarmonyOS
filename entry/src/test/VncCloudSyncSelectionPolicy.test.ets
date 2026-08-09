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
    it('defaults_to_every_record_type_under_the_single_physical_table', 0, (): void => {
      expect(VNC_CLOUD_SYNC_SELECTION_DEFAULT.length).assertEqual(5);
    });

    it('migrates_partial_and_unknown_legacy_scopes_to_the_complete_table', 0, (): void => {
      const selected: string[] = normalizeVncCloudSyncSelection([
        'hosts', 'not-a-scope', 'hosts', 'secrets'
      ]);
      expect(selected.length).assertEqual(5);
      expect(selected[0]).assertEqual('settings');
      expect(selected[4]).assertEqual('trust');
      expect(isVncRecordTypeSelected('host', selected)).assertTrue();
      expect(isVncRecordTypeSelected('gateway', selected)).assertTrue();
      expect(isVncRecordTypeSelected('trust', [])).assertTrue();
    });

    it('keeps_encrypted_secret_rows_in_the_table_without_a_scope_gate', 0, (): void => {
      const selected: string[] = ['settings', 'secrets'];
      expect(vncSyncNeedsCrypto(selected)).assertTrue();
      expect(vncSyncNeedsCrypto(selected, false)).assertFalse();
      expect(vncSecretSyncAllowed(selected, false)).assertTrue();
      expect(vncSecretSyncAllowed(selected, true)).assertTrue();
      expect(vncSecretSyncAllowed([], true)).assertTrue();
    });
  });
}
