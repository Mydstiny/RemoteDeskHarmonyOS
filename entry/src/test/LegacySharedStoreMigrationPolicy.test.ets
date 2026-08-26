import { describe, expect, it } from '@ohos/hypium';
import {
  accountScopedCryptoParamsMayMigrate,
  accountScopedRowOwnershipDecision,
  legacyCryptoParamsMayMigrate,
  legacyRowOwnershipDecision,
  legacyVncRowMigrationDecision
} from '../main/ets/services/LegacySharedStoreMigrationPolicy';

export default function legacySharedStoreMigrationPolicyTest(): void {
  describe('LegacySharedStoreMigrationPolicy', (): void => {
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
