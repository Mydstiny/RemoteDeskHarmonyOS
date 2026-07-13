import { describe, it, expect } from '@ohos/hypium';
import {
  CLOUD_SYNC_SELECTION_DEFAULT,
  cloudSyncSelectableTables,
  effectiveCloudSyncTables,
  hasCloudSyncBusinessSelection,
  normalizeCloudSyncSelection
} from '../main/ets/services/CloudSyncSelectionPolicy';

export default function cloudSyncSelectionPolicyTest(): void {
  describe('CloudSyncSelectionPolicy', (): void => {
    it('defaults_to_every_user_selectable_table', 0, (): void => {
      expect(CLOUD_SYNC_SELECTION_DEFAULT.length).assertEqual(6);
      expect(cloudSyncSelectableTables().indexOf('cryptoparams')).assertEqual(-1);
      expect(cloudSyncSelectableTables().indexOf('remotehosts') >= 0).assertTrue();
      expect(cloudSyncSelectableTables().indexOf('usersettings') >= 0).assertTrue();
    });

    it('normalizes_unknown_and_duplicate_table_names', 0, (): void => {
      const selected: string[] = normalizeCloudSyncSelection(['sshkeys', 'invalid', 'sshkeys', 'usersettings']);
      expect(selected.length).assertEqual(2);
      expect(selected[0]).assertEqual('usersettings');
      expect(selected[1]).assertEqual('sshkeys');
    });

    it('adds_crypto_before_selected_encrypted_data', 0, (): void => {
      const tables: string[] = effectiveCloudSyncTables(['sshkeys', 'usersettings']);
      expect(tables.length).assertEqual(3);
      expect(tables[0]).assertEqual('cryptoparams');
      expect(tables[1]).assertEqual('usersettings');
      expect(tables[2]).assertEqual('sshkeys');
    });

    it('keeps_settings_independent_and_allows_zero_selection', 0, (): void => {
      expect(effectiveCloudSyncTables(['usersettings']).length).assertEqual(1);
      expect(effectiveCloudSyncTables(['usersettings'])[0]).assertEqual('usersettings');
      expect(hasCloudSyncBusinessSelection([])).assertFalse();
      expect(hasCloudSyncBusinessSelection(['usersettings'])).assertTrue();
    });
  });
}
