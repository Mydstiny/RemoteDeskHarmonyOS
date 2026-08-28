import { describe, expect, it } from '@ohos/hypium';
import {
  accountScopedMigrationReceiptDecision,
  accountScopedMigrationReceiptNeedsUpgrade,
  accountScopedCryptoParamsMayMigrate,
  accountScopedLocalOverlayRowDecision,
  accountScopedRowOwnershipDecision,
  legacyCryptoParamsMayMigrate,
  legacyRowOwnershipDecision,
  legacyVncRowMigrationDecision
} from '../main/ets/services/LegacySharedStoreMigrationPolicy';
import {
  legacyMigrationSha256Hex
} from '../main/ets/services/LegacySharedStoreMigrator';

export default function legacySharedStoreMigrationPolicyTest(): void {
  describe('LegacySharedStoreMigrationPolicy', (): void => {
    it('hashes_an_empty_mutation_journal_without_a_zero_length_provider_update',
      0, (): void => {
        expect(legacyMigrationSha256Hex('')).assertEqual(
          'e3b0c44298fc1c149afbf4c8996fb924' +
          '27ae41e4649b934ca495991b7852b855');
      });

    it('refuses_to_hide_source_changes_after_a_committed_migration',
      0, (): void => {
        expect(accountScopedMigrationReceiptDecision(
          null, 'journal-v1:current')).assertEqual('migrate');
        expect(accountScopedMigrationReceiptDecision(
          'journal-v1:same', 'journal-v1:same'))
          .assertEqual('skip_unchanged');
        expect(accountScopedMigrationReceiptDecision(
          'journal-v1:old', 'journal-v1:changed'))
          .assertEqual('source_changed');
        expect(accountScopedMigrationReceiptDecision(
          'legacy-file-fingerprint', 'journal-v1:changed',
          null)).assertEqual('skip_unchanged');
        expect(accountScopedMigrationReceiptDecision(
          'legacy-file-fingerprint', 'journal-v1:changed',
          'journal-v1:baseline')).assertEqual('source_changed');
        expect(accountScopedMigrationReceiptDecision(
          'legacy-file-fingerprint', 'journal-v1:baseline',
          'journal-v1:baseline')).assertEqual('skip_unchanged');
        expect(accountScopedMigrationReceiptNeedsUpgrade(
          'legacy-file-fingerprint', 'skip_unchanged',
          'journal-v1:baseline'))
          .assertTrue();
        expect(accountScopedMigrationReceiptNeedsUpgrade(
          'legacy-file-fingerprint', 'skip_unchanged', null))
          .assertFalse();
        expect(accountScopedMigrationReceiptDecision(
          'journal-v1:empty', 'journal-v1:changed', null))
          .assertEqual('source_changed');
        expect(accountScopedMigrationReceiptDecision(
          'journal-v1:same', 'journal-v2:compatibility-dirty',
          'journal-v1:same')).assertEqual('source_changed');
        expect(accountScopedMigrationReceiptDecision(
          'journal-v2:same', 'journal-v2:same'))
          .assertEqual('skip_unchanged');
        expect(accountScopedMigrationReceiptNeedsUpgrade(
          'journal-v2:same', 'skip_unchanged',
          'journal-v1:baseline')).assertFalse();
      });

    it('claims_blank_legacy_owner_only_for_a_verified_account', 0, (): void => {
      expect(legacyRowOwnershipDecision('', 'huawei_account', 'union-a'))
        .assertEqual('target');
      expect(legacyRowOwnershipDecision('', 'huawei_account', ''))
        .assertEqual('quarantine_missing_owner');
      expect(legacyRowOwnershipDecision('', 'device_local', ''))
        .assertEqual('quarantine_missing_owner');
    });

    it('maps_only_local_aliases_or_the_verified_union_id', 0, (): void => {
      expect(legacyRowOwnershipDecision('local', 'device_local', ''))
        .assertEqual('target');
      expect(legacyRowOwnershipDecision('union-a', 'huawei_account', 'union-a'))
        .assertEqual('target');
      expect(legacyRowOwnershipDecision(
        'owner-a', 'huawei_account', 'union-a', 'owner-a'))
        .assertEqual('target');
      expect(legacyRowOwnershipDecision('union-b', 'huawei_account', 'union-a'))
        .assertEqual('other_owner');
    });

    it('migrates_global_crypto_only_when_one_owner_is_proven', 0, (): void => {
      expect(legacyCryptoParamsMayMigrate([], 'device_local', '')).assertTrue();
      expect(legacyCryptoParamsMayMigrate(
        ['union-a'], 'huawei_account', 'union-a')).assertTrue();
      expect(legacyCryptoParamsMayMigrate(
        [], 'huawei_account', 'union-a')).assertTrue();
      expect(legacyCryptoParamsMayMigrate(
        ['union-a', 'union-b'], 'huawei_account', 'union-a')).assertFalse();
    });

    it('quarantines_legacy_vnc_rows_that_cannot_be_proven_safe',
      0, (): void => {
        expect(legacyVncRowMigrationDecision(
          'union-a', 'union-a', 3, 3, true))
          .assertEqual('migrate');
        expect(legacyVncRowMigrationDecision(
          'union-b', 'union-a', 3, 3, true))
          .assertEqual('quarantine_owner_mismatch');
        expect(legacyVncRowMigrationDecision(
          'union-a', 'union-a', 2, 3, true))
          .assertEqual('quarantine_stale_epoch');
        expect(legacyVncRowMigrationDecision(
          'union-a', 'union-a', 3, 3, false))
          .assertEqual('quarantine_invalid_payload');
      });

    it('account_scoped_rows_follow_exact_owner_scope_binding', 0, (): void => {
      expect(accountScopedRowOwnershipDecision('', 'owner-a'))
        .assertEqual('quarantine_missing_owner');
      expect(accountScopedRowOwnershipDecision('owner-a', 'owner-a'))
        .assertEqual('target');
      expect(accountScopedRowOwnershipDecision(' owner-a ', 'owner-a'))
        .assertEqual('target');
      expect(accountScopedRowOwnershipDecision('owner-b', 'owner-a'))
        .assertEqual('other_owner');
      expect(accountScopedRowOwnershipDecision('union-a', 'owner-a'))
        .assertEqual('other_owner');
    });

    it('migrates_valid_local_only_vnc_and_moonlight_overlay_rows',
      0, (): void => {
        // Both protocol tables share the same exact owner/local-only gate;
        // their payload validators run before this policy decision.
        expect(accountScopedLocalOverlayRowDecision(
          'owner-a', 'owner-a', 1, true))
          .assertEqual('migrate');
        expect(accountScopedLocalOverlayRowDecision(
          'owner-a', 'owner-a', 0, true))
          .assertEqual('migrate');
        expect(accountScopedLocalOverlayRowDecision(
          'owner-b', 'owner-a', 1, true))
          .assertEqual('other_owner');
        expect(accountScopedLocalOverlayRowDecision(
          'owner-a', 'owner-a', 2, true))
          .assertEqual('quarantine_invalid_local_only');
        expect(accountScopedLocalOverlayRowDecision(
          'owner-a', 'owner-a', 1, false))
          .assertEqual('quarantine_invalid_payload');
      });

    it('account_scoped_crypto_requires_a_single_matching_owner_scope', 0,
      (): void => {
        expect(accountScopedCryptoParamsMayMigrate(
          ['owner-a'], 'owner-a')).assertTrue();
        expect(accountScopedCryptoParamsMayMigrate(
          [], 'owner-a')).assertFalse();
        expect(accountScopedCryptoParamsMayMigrate(
          ['local', 'owner-a'], 'owner-a')).assertTrue();
        expect(accountScopedCryptoParamsMayMigrate(
          ['owner-a', 'owner-b'], 'owner-a')).assertFalse();
        expect(accountScopedCryptoParamsMayMigrate(
          ['owner-b'], 'owner-a')).assertFalse();
      });
  });
}
