/** RemoteHostSheetLifecyclePolicy regression tests. */
import { describe, it, expect } from '@ohos/hypium';
import {
  nextRemoteHostSheetGeneration,
  shouldAcceptRemoteHostSheetDismiss,
  shouldApplyRemoteHostSheetResult,
  shouldCallRemoteHostSheetDismissAction,
  shouldSetRemoteHostSheetVisibility
} from '../../../main/ets/services/RemoteHostSheetLifecyclePolicy';

export default function remoteHostSheetLifecyclePolicyTest(): void {
  describe('RemoteHostSheetLifecyclePolicy', (): void => {
    it('accepts_only_one_idle_interactive_dismiss_request', 0, (): void => {
      expect(shouldAcceptRemoteHostSheetDismiss({ busy: false, closing: false, pendingRoute: false }))
        .assertTrue();
      expect(shouldAcceptRemoteHostSheetDismiss({ busy: true, closing: false, pendingRoute: false }))
        .assertFalse();
      expect(shouldAcceptRemoteHostSheetDismiss({ busy: false, closing: true, pendingRoute: false }))
        .assertFalse();
      expect(shouldAcceptRemoteHostSheetDismiss({ busy: false, closing: false, pendingRoute: true }))
        .assertFalse();
    });

    it('uses_action_only_for_interactive_close', 0, (): void => {
      expect(shouldCallRemoteHostSheetDismissAction('interactive')).assertTrue();
      expect(shouldCallRemoteHostSheetDismissAction('programmatic')).assertFalse();
      expect(shouldSetRemoteHostSheetVisibility('interactive')).assertFalse();
      expect(shouldSetRemoteHostSheetVisibility('programmatic')).assertTrue();
    });

    it('rejects_stale_async_results_after_sheet_reuse', 0, (): void => {
      expect(shouldApplyRemoteHostSheetResult(4, 4, 'host-a', 'host-a')).assertTrue();
      expect(shouldApplyRemoteHostSheetResult(5, 4, 'host-a', 'host-a')).assertFalse();
      expect(shouldApplyRemoteHostSheetResult(4, 4, 'host-b', 'host-a')).assertFalse();
      expect(shouldApplyRemoteHostSheetResult(4, 4, '', 'host-a')).assertFalse();
    });

    it('wraps_sheet_generation_without_reusing_zero', 0, (): void => {
      expect(nextRemoteHostSheetGeneration(0)).assertEqual(1);
      expect(nextRemoteHostSheetGeneration(Number.MAX_SAFE_INTEGER)).assertEqual(1);
    });
  });
}
