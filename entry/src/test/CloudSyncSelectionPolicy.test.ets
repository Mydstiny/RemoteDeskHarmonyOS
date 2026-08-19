import { describe, it, expect } from '@ohos/hypium';
import {
  CLOUD_SYNC_SELECTION_DEFAULT,
  cloudSyncSelectableTables,
  effectiveCloudSyncTables,
  hasCloudSyncBusinessSelection,
  normalizeCloudSyncSelection,
  runtimeAdmittedCloudSyncSelection
} from '../main/ets/services/CloudSyncSelectionPolicy';

export default function cloudSyncSelectionPolicyTest(): void {
  describe('CloudSyncSelectionPolicy', (): void => {
    it('defaults_to_no_cloud_transfer_until_account_binding_is_validated', 0, (): void => {
      expect(CLOUD_SYNC_SELECTION_DEFAULT.length).assertEqual(0);
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

    it('exposes_moonlight_after_the_remote_schema_receipt_is_enabled', 0,
      (): void => {
        expect(cloudSyncSelectableTables(false).indexOf(
          'moonlightrecordv1')).assertEqual(-1);
        expect(cloudSyncSelectableTables(true).indexOf(
          'moonlightrecordv1') >= 0).assertTrue();
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

    it('upgrades_every_legacy_selection_without_enabling_moonlight', 0,
      (): void => {
        const legacy: string[] = [
          'usersettings', 'remotehosts', 'rdpcredentials',
          'rustdeskrelays', 'sshkeys', 'totpentries', 'vncrecordv2'
        ];
        const normalized: string[] =
          normalizeCloudSyncSelection(legacy);
        expect(normalized.join(','))
          .assertEqual(legacy.join(','));
        expect(normalized.indexOf('moonlightrecordv1'))
          .assertEqual(-1);
        // The implicit cryptoparams dependency remains first; the new
        // optional table is absent until the user explicitly selects it.
        const effective: string[] =
          effectiveCloudSyncTables(normalized);
        expect(effective[0]).assertEqual('cryptoparams');
        expect(effective.indexOf('moonlightrecordv1'))
          .assertEqual(-1);
      });
  });
}
