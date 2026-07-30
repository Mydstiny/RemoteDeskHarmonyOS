import { describe, expect, it } from '@ohos/hypium';
import {
  cloudSelectionAfterAuthoritativePull,
  cloudSelectionAfterLocalPromotion,
  cloudSelectionLocalPromotionAllowed,
  cloudSelectionNativeFirstAllowed,
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
  });
}
