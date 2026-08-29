import { describe, expect, it } from '@ohos/hypium';
import {
  platformCloudIdentityFingerprint,
  platformCloudIdentityMatchesAccountKit,
  platformCloudIdentityProofRetryable,
  platformCloudIdentityProofFromApi23,
  platformCloudIdentityProofIsValid,
  platformCloudPermissionRequestDecision,
  unavailablePlatformCloudIdentityProof
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

    it('distinguishes_a_blocked_permission_dialog_from_user_denial',
      0, (): void => {
        expect(platformCloudPermissionRequestDecision(
          -1, false, 3)).assertEqual('retryable');
        expect(platformCloudPermissionRequestDecision(
          -1, false, 5)).assertEqual('retryable');
        expect(platformCloudPermissionRequestDecision(
          -1, false, 12)).assertEqual('retryable');
        expect(platformCloudPermissionRequestDecision(
          -1, false, null)).assertEqual('denied');
        expect(platformCloudPermissionRequestDecision(
          -1, false, 0)).assertEqual('denied');
        expect(platformCloudPermissionRequestDecision(
          -1, true, 0)).assertEqual('denied');
        expect(platformCloudPermissionRequestDecision(
          -1, false, 4)).assertEqual('retryable_dialog');
        expect(platformCloudPermissionRequestDecision(
          -1, true, 4)).assertEqual('denied');
        expect(platformCloudPermissionRequestDecision(
          -1, false, 2)).assertEqual('denied');
        expect(platformCloudPermissionRequestDecision(
          2, false, null)).assertEqual('denied');
        expect(platformCloudPermissionRequestDecision(
          0, false, 3)).assertEqual('granted');
        expect(platformCloudIdentityProofRetryable(
          unavailablePlatformCloudIdentityProof(
            'permission_dialog_blocked'))).assertTrue();
        expect(platformCloudIdentityProofRetryable(
          unavailablePlatformCloudIdentityProof(
            'permission_unavailable'))).assertTrue();
        expect(platformCloudIdentityProofRetryable(
          unavailablePlatformCloudIdentityProof(
            'permission_denied'))).assertFalse();
      });
  });
}
