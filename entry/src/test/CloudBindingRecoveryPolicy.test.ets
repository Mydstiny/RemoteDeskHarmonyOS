import { describe, expect, it } from '@ohos/hypium';
import {
  cloudBindingRecoveryAfterProof,
  cloudBindingRecoveryAfterRollback,
  cloudBindingRecoveryIsPending,
  cloudBindingRecoveryRepeatedDialogBlocked,
  cloudBindingRecoveryRequested
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
  });
}
