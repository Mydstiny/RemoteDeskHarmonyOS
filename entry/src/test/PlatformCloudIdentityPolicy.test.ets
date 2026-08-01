import { describe, expect, it } from '@ohos/hypium';
import {
  platformCloudIdentityFingerprint,
  platformCloudIdentityMatchesAccountKit,
  platformCloudIdentityProofFromApi23,
  platformCloudIdentityProofIsValid
} from '../main/ets/services/PlatformCloudIdentityPolicy';

export default function platformCloudIdentityPolicyTest():
  void {
  describe('PlatformCloudIdentityPolicy', (): void => {
    it('mints_an_opaque_proof_only_for_a_logged_in_platform_account',
      0, (): void => {
        const verified =
          platformCloudIdentityProofFromApi23(
            'platform-account-a', true);
        expect(platformCloudIdentityProofIsValid(
          verified)).assertTrue();
        expect(verified.fingerprint.indexOf(
          'platform-account-a')).assertEqual(-1);
        expect(platformCloudIdentityProofIsValid(
          platformCloudIdentityProofFromApi23(
            'platform-account-a', false))).assertFalse();
        expect(platformCloudIdentityProofIsValid(
          platformCloudIdentityProofFromApi23(
            '', true))).assertFalse();
        expect(platformCloudIdentityMatchesAccountKit(
          'account-a', 'account-a')).assertTrue();
        expect(platformCloudIdentityMatchesAccountKit(
          'account-a', 'account-b')).assertFalse();
      });

    it('keeps_platform_accounts_stable_but_distinct',
      0, (): void => {
        expect(platformCloudIdentityFingerprint(
          ' platform-account-a '))
          .assertEqual(platformCloudIdentityFingerprint(
            'platform-account-a'));
        expect(platformCloudIdentityFingerprint(
          'platform-account-a') ===
          platformCloudIdentityFingerprint(
            'platform-account-b')).assertFalse();
      });
  });
}
