import { describe, expect, it } from '@ohos/hypium';
import {
  cloudBindingRecoveryAfterProof,
  cloudBindingRecoveryAfterRollback,
  cloudBindingRecoveryIsPending,
  cloudBindingRecoveryRepeatedDialogBlocked,
  cloudBindingRecoveryRequested,
  cloudBindingRecoverySourceAuthorityKey,
  cloudBindingRecoverySourceAuthorityInspect,
  cloudBindingRecoverySourceAuthorityValue
} from '../main/ets/services/CloudBindingRecoveryPolicy';

export default function cloudBindingRecoveryPolicyTest(): void {
  describe('CloudBindingRecoveryPolicy', (): void => {
    it('retries_a_restored_local_scope_after_transient_canonical_failure',
      0, (): void => {
        expect(cloudBindingRecoveryRequested(
          'permission_dialog_blocked', false))
          .assertEqual('permission_pending');
        expect(cloudBindingRecoveryRequested(
          'permission_unavailable', false))
          .assertEqual('permission_pending');
        expect(cloudBindingRecoveryAfterProof('verified'))
          .assertEqual('binding_pending');
        const restored = cloudBindingRecoveryAfterRollback(true, true);
        expect(restored).assertEqual('binding_pending');
        expect(cloudBindingRecoveryIsPending(restored)).assertTrue();
      });

    it('hard_stops_identity_rejection_or_failed_local_rollback',
      0, (): void => {
        expect(cloudBindingRecoveryAfterProof('identity_mismatch'))
          .assertEqual('blocked');
        expect(cloudBindingRecoveryAfterRollback(true, false))
          .assertEqual('blocked');
        expect(cloudBindingRecoveryAfterRollback(false, true))
          .assertEqual('blocked');
      });

    it('allows_only_one_foreground_retry_for_the_blocked_dialog_signature',
      0, (): void => {
        expect(cloudBindingRecoveryRepeatedDialogBlocked(
          'permission_dialog_blocked',
          'permission_dialog_blocked')).assertTrue();
        expect(cloudBindingRecoveryRepeatedDialogBlocked(
          'permission_unavailable',
          'permission_dialog_blocked')).assertFalse();
      });

    it('keeps_the_local_source_authoritative_across_restart_until_baseline_is_durable',
      0, (): void => {
        const owner: string = 'owner-' +
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        const localStore: string = 'remotedesktop_' + owner + '.db';
        expect(cloudBindingRecoverySourceAuthorityKey(owner))
          .assertEqual('crsa1:' +
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
        const baseline: string = 'journal-v1:' +
          'e3b0c44298fc1c149afbf4c8996fb924' +
          '27ae41e4649b934ca495991b7852b855';
        const recoverable = cloudBindingRecoverySourceAuthorityInspect(
          cloudBindingRecoverySourceAuthorityValue(localStore, baseline),
          localStore, true);
        expect(recoverable.state).assertEqual('recoverable_source');
        expect(recoverable.baselineFingerprint).assertEqual(baseline);
        expect(cloudBindingRecoverySourceAuthorityInspect(
          localStore, localStore, true).state)
          .assertEqual('local_source');
        expect(cloudBindingRecoverySourceAuthorityInspect(
          '', localStore, true).state).assertEqual('absent');
        expect(cloudBindingRecoverySourceAuthorityInspect(
          'unexpected.db', localStore, true).state)
          .assertEqual('uncertain');
        expect(cloudBindingRecoverySourceAuthorityInspect(
          '', localStore, false).state).assertEqual('uncertain');
      });
  });
}
