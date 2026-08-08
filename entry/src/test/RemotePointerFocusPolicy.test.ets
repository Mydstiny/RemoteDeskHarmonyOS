import { expect } from '@ohos/hypium';
import { auditedDescribe as describe, auditedIt as it } from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  RUSTDESK_MACOS_PHYSICAL_MOUSE_DRAG_THRESHOLD_VP,
  RemotePointerFocusRecoveryState,
  shouldStageRustDeskMacPhysicalMouseClick,
  shouldStartRustDeskMacPhysicalMouseDrag,
  shouldRecoverRemotePointerFocus
} from '../main/ets/services/RemotePointerFocusPolicy';

export default function remotePointerFocusPolicyTest(): void {
  describe('RemotePointerFocusPolicy', (): void => {
    it('does_not_recover_a_stable_proxy_after_a_normal_click', 0, (): void => {
      const state: RemotePointerFocusRecoveryState = {
        proxyExpected: true,
        recoveryNeeded: false,
        requestScheduled: false,
        requestPending: false
      };
      expect(shouldRecoverRemotePointerFocus(state)).assertFalse();
    });

    it('recovers_after_explicit_focus_loss_evidence', 0, (): void => {
      const state: RemotePointerFocusRecoveryState = {
        proxyExpected: true,
        recoveryNeeded: true,
        requestScheduled: false,
        requestPending: false
      };
      expect(shouldRecoverRemotePointerFocus(state)).assertTrue();
    });

    it('coalesces_an_already_scheduled_or_pending_request', 0, (): void => {
      expect(shouldRecoverRemotePointerFocus({
        proxyExpected: true,
        recoveryNeeded: false,
        requestScheduled: true,
        requestPending: false
      })).assertTrue();
      expect(shouldRecoverRemotePointerFocus({
        proxyExpected: true,
        recoveryNeeded: false,
        requestScheduled: false,
        requestPending: true
      })).assertTrue();
    });

    it('never_recovers_when_the_keyboard_proxy_is_not_required', 0, (): void => {
      expect(shouldRecoverRemotePointerFocus({
        proxyExpected: false,
        recoveryNeeded: true,
        requestScheduled: false,
        requestPending: false
      })).assertFalse();
    });

    it('stages_only_left_physical_mouse_clicks_for_rustdesk_macos', 0, (): void => {
      expect(RUSTDESK_MACOS_PHYSICAL_MOUSE_DRAG_THRESHOLD_VP).assertLarger(0);
      expect(shouldStageRustDeskMacPhysicalMouseClick('rustdesk', 'macos', true, 0)).assertTrue();
      expect(shouldStageRustDeskMacPhysicalMouseClick('rustdesk', 'macos', true, 2)).assertFalse();
      expect(shouldStageRustDeskMacPhysicalMouseClick('rustdesk', 'macos', false, 0)).assertFalse();
      expect(shouldStageRustDeskMacPhysicalMouseClick('rustdesk', 'windows', true, 0)).assertFalse();
      expect(shouldStageRustDeskMacPhysicalMouseClick('vnc', 'macos', true, 0)).assertFalse();
    });

    it('promotes_a_staged_click_only_after_local_drag_threshold', 0, (): void => {
      expect(shouldStartRustDeskMacPhysicalMouseDrag(10, 20, 13, 22)).assertFalse();
      expect(shouldStartRustDeskMacPhysicalMouseDrag(10, 20, 14, 20)).assertTrue();
      expect(shouldStartRustDeskMacPhysicalMouseDrag(10, 20, 7, 17)).assertTrue();
      expect(shouldStartRustDeskMacPhysicalMouseDrag(10, 20, Number.NaN, 20)).assertFalse();
    });
  });
}
