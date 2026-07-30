import { describe, expect, it } from '@ohos/hypium';
import {
  cloudSelectionAfterAuthoritativePull,
  cloudSelectionAfterLocalPromotion,
  cloudSelectionBarrierAfterRollback,
  cloudSelectionLocalPromotionAllowed,
  cloudSelectionNativeFirstAllowed,
  cloudSelectionTransitionNeedsCloudFirst,
  normalizeCloudSelectionReenablePhase
} from '../main/ets/services/CloudSelectionReenablePolicy';
import {
  cloudBootstrapRecordReconcileAction
} from '../main/ets/services/CloudBootstrapReconcilePolicy';

export default function cloudLifecycleBarrierPolicyTest():
  void {
  describe('CloudLifecycleBarrierPolicy', (): void => {
    it('keeps_native_first_blocked_until_pull_and_promotion_commit',
      0, (): void => {
        const pulled = cloudSelectionAfterAuthoritativePull(
          'pending_pull');
        expect(pulled).assertEqual('pull_complete');
        expect(cloudSelectionNativeFirstAllowed(
          pulled)).assertFalse();
        const promoted = cloudSelectionAfterLocalPromotion(
          pulled);
        expect(promoted).assertEqual(
          'promotion_complete');
        expect(cloudSelectionNativeFirstAllowed(
          promoted)).assertFalse();
        expect(cloudSelectionNativeFirstAllowed(
          null)).assertTrue();
        expect(cloudSelectionLocalPromotionAllowed(
          true, false)).assertTrue();
        expect(cloudSelectionLocalPromotionAllowed(
          false, false)).assertFalse();
        expect(normalizeCloudSelectionReenablePhase(
          'corrupt') === null).assertTrue();
      });

    it('reconciles_only_records_proven_by_the_pre_bootstrap_journal',
      0, (): void => {
        expect(cloudBootstrapRecordReconcileAction(
          true, 'crypto_migrate', false))
          .assertEqual('restore_table');
        expect(cloudBootstrapRecordReconcileAction(
          false, 'update', true))
          .assertEqual('restore_record');
        expect(cloudBootstrapRecordReconcileAction(
          false, 'delete', false))
          .assertEqual('delete_record');
        expect(cloudBootstrapRecordReconcileAction(
          false, 'update', false))
          .assertEqual('invalid');
      });

    it('requires_cloud_first_only_when_a_vnc_scope_is_newly_enabled',
      0, (): void => {
        expect(cloudSelectionTransitionNeedsCloudFirst(
          [], ['hosts'], true)).assertTrue();
        expect(cloudSelectionTransitionNeedsCloudFirst(
          ['hosts'], ['hosts', 'secrets'],
          true)).assertTrue();
        expect(cloudSelectionTransitionNeedsCloudFirst(
          ['hosts'], [], true)).assertFalse();
        expect(cloudSelectionTransitionNeedsCloudFirst(
          [], ['hosts'], false)).assertFalse();
      });

    it('restores_the_exact_pre_save_barrier_after_a_failed_vnc_save',
      0, (): void => {
        expect(cloudSelectionBarrierAfterRollback(
          null) === null).assertTrue();
        expect(cloudSelectionBarrierAfterRollback(
          'pull_complete'))
          .assertEqual('pull_complete');
        expect(cloudSelectionBarrierAfterRollback(
          'pending_pull'))
          .assertEqual('pending_pull');
      });
  });
}
