import { describe, it, expect } from '@ohos/hypium';
import {
  CLOUD_SYNC_SELECTION_DEFAULT,
  cloudSyncSelectableTables,
  effectiveCloudSyncTables,
  hasCloudSyncBusinessSelection,
  normalizeCloudSyncSelection,
  runtimeAdmittedCloudSyncSelection,
  upgradeLegacyCloudSyncSelection
} from '../main/ets/services/CloudSyncSelectionPolicy';

export default function cloudSyncSelectionPolicyTest(): void {
  describe('CloudSyncSelectionPolicy', (): void => {
    it('defaults_to_moonlight_while_runtime_admission_still_owns_transfer', 0, (): void => {
      expect(CLOUD_SYNC_SELECTION_DEFAULT.join(','))
        .assertEqual('moonlightrecordv1');
      expect(cloudSyncSelectableTables().indexOf('cryptoparams')).assertEqual(-1);
      expect(cloudSyncSelectableTables().indexOf('remotehosts') >= 0).assertTrue();
      expect(cloudSyncSelectableTables().indexOf('usersettings') >= 0).assertTrue();
      expect(cloudSyncSelectableTables().indexOf('vncrecordv2') >= 0).assertTrue();
      expect(cloudSyncSelectableTables().indexOf('moonlightrecordv1'))
        .assertEqual(-1);
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

    it('keeps_vnc_physical_selection_outside_the_crypto_auto_pair', 0, (): void => {
      const tables: string[] = effectiveCloudSyncTables(['vncrecordv2']);
      expect(tables.length).assertEqual(1);
      expect(tables[0]).assertEqual('vncrecordv2');
    });

    it('keeps_optional_moonlight_physical_selection_outside_crypto', 0,
      (): void => {
        // A prerelease durable choice remains readable while the production
        // cloud deployment receipt is closed. This avoids silently erasing
        // user intent during an upgrade, while runtime admission stays off.
        expect(normalizeCloudSyncSelection(['moonlightrecordv1'])[0])
          .assertEqual('moonlightrecordv1');
        const tables: string[] = effectiveCloudSyncTables(
          ['moonlightrecordv1']);
        expect(tables.length).assertEqual(1);
        expect(tables[0]).assertEqual('moonlightrecordv1');
      });

    it('keeps_moonlight_out_of_the_user_table_picker', 0,
      (): void => {
        expect(cloudSyncSelectableTables(false).indexOf(
          'moonlightrecordv1')).assertEqual(-1);
        expect(cloudSyncSelectableTables(true).indexOf(
          'moonlightrecordv1')).assertEqual(-1);
      });

    it('filters_a_missing_optional_schema_without_erasing_legacy_intent', 0,
      (): void => {
        const durable: string[] = [
          'usersettings', 'remotehosts', 'moonlightrecordv1'
        ];
        const admitted: string[] = runtimeAdmittedCloudSyncSelection(
          durable, ['moonlightrecordv1']);
        expect(admitted.join(','))
          .assertEqual('usersettings,remotehosts');
        expect(durable.join(','))
          .assertEqual('usersettings,remotehosts,moonlightrecordv1');
      });

    it('preserves_dormant_moonlight_intent_when_a_core_selection_is_edited',
      0, (): void => {
        const persisted: string[] = normalizeCloudSyncSelection([
          'remotehosts', 'moonlightrecordv1'
        ]);
        const edited: string[] = persisted.filter(
          (table: string): boolean => table !== 'remotehosts');
        edited.push('usersettings');
        const durable: string[] = normalizeCloudSyncSelection(edited);
        const admitted: string[] = runtimeAdmittedCloudSyncSelection(
          durable, ['moonlightrecordv1']);
        expect(durable.join(','))
          .assertEqual('usersettings,moonlightrecordv1');
        expect(admitted.join(',')).assertEqual('usersettings');
      });

    it('repairs_pre_moonlight_and_partial_upgrade_choices_without_changing_legacy_tables', 0,
      (): void => {
        const legacy: string[] = [
          'usersettings', 'remotehosts', 'rdpcredentials',
          'rustdeskrelays', 'sshkeys', 'totpentries', 'vncrecordv2'
        ];
        const normalized: string[] =
          upgradeLegacyCloudSyncSelection(legacy, false);
        expect(normalized.slice(0, legacy.length).join(','))
          .assertEqual(legacy.join(','));
        expect(normalized[legacy.length]).assertEqual('moonlightrecordv1');
        // A migration receipt written by an earlier partial rollout is not
        // proof that the physical selection committed. Explicit whole-table
        // stops use a separate owner-scoped preference in the selection store.
        expect(upgradeLegacyCloudSyncSelection(legacy, true).join(','))
          .assertEqual(legacy.join(',') + ',moonlightrecordv1');
        const effective: string[] =
          effectiveCloudSyncTables(normalized);
        expect(effective[0]).assertEqual('cryptoparams');
        expect(effective.indexOf('moonlightrecordv1') >= 0).assertTrue();
      });
  });
}
