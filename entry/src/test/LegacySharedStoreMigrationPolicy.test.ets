import { describe, expect, it } from '@ohos/hypium';
import {
  legacyCryptoParamsMayMigrate,
  legacyRowOwnershipDecision
} from '../main/ets/services/LegacySharedStoreMigrationPolicy';

export default function legacySharedStoreMigrationPolicyTest(): void {
  describe('LegacySharedStoreMigrationPolicy', (): void => {
    it('never_assigns_blank_owner_to_the_first_account', 0, (): void => {
      expect(legacyRowOwnershipDecision('', 'huawei_account', 'union-a'))
        .assertEqual('quarantine_missing_owner');
      expect(legacyRowOwnershipDecision('', 'device_local', ''))
        .assertEqual('quarantine_missing_owner');
    });

    it('maps_only_local_aliases_or_the_verified_union_id', 0, (): void => {
      expect(legacyRowOwnershipDecision('local', 'device_local', ''))
        .assertEqual('target');
      expect(legacyRowOwnershipDecision('union-a', 'huawei_account', 'union-a'))
        .assertEqual('target');
      expect(legacyRowOwnershipDecision('union-b', 'huawei_account', 'union-a'))
        .assertEqual('other_owner');
    });

    it('migrates_global_crypto_only_when_one_owner_is_proven', 0, (): void => {
      expect(legacyCryptoParamsMayMigrate([], 'device_local', '')).assertTrue();
      expect(legacyCryptoParamsMayMigrate(
        ['union-a'], 'huawei_account', 'union-a')).assertTrue();
      expect(legacyCryptoParamsMayMigrate(
        ['union-a', 'union-b'], 'huawei_account', 'union-a')).assertFalse();
    });
  });
}
