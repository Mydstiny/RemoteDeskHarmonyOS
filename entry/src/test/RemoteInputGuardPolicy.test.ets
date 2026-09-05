import { describe, it, expect } from '@ohos/hypium';
import {
  mouseButtonForRemote,
  physicalMousePressDisposition,
  PhysicalMousePressDisposition,
  remoteInputWindowActiveAfterEvent,
  remoteInputWindowFocusKnownAfterEvent,
  remoteInputWindowListenerIsCurrent,
  remoteMouseButtonsAfterEvent,
  remoteInputBlockedReason,
  resolvePhysicalMouseReleaseButton,
  shouldBlockRemoteInputForBrowseMode,
  shouldBlockRemoteInputForLifecycle,
  shouldReleaseAllMouseButtonsForAmbiguousUp,
  shouldReleaseMouseButtonsBeforeSwapChange,
  shouldRecoverPointerFocusAfterMouseRelease
} from '../main/ets/services/RemoteInputGuardPolicy';

export default function remoteInputGuardPolicyTest(): void {
  describe('RemoteInputGuardPolicy_browseMode', (): void => {
    it('should_block_only_rustdesk_input_when_browse_mode_is_enabled', 0, (): void => {
      expect(shouldBlockRemoteInputForBrowseMode('rustdesk', true)).assertTrue();
      expect(shouldBlockRemoteInputForBrowseMode('rustdesk', false)).assertFalse();
      expect(shouldBlockRemoteInputForBrowseMode('rdp', true)).assertFalse();
      expect(shouldBlockRemoteInputForBrowseMode('ssh', true)).assertFalse();
    });

    it('should_explain_why_input_is_blocked', 0, (): void => {
      const reason = remoteInputBlockedReason('rustdesk', true);
      expect(reason.length > 0).assertTrue();
      expect(remoteInputBlockedReason('rustdesk', false)).assertEqual('');
      expect(remoteInputBlockedReason('rdp', true)).assertEqual('');
    });

    it('blocks_input_during_every_background_and_restore_transition', 0, (): void => {
      expect(shouldBlockRemoteInputForLifecycle(true, false, false, false, false, false))
        .assertTrue();
      expect(shouldBlockRemoteInputForLifecycle(false, true, false, false, false, false))
        .assertTrue();
      expect(shouldBlockRemoteInputForLifecycle(false, false, true, false, false, false))
        .assertTrue();
      expect(shouldBlockRemoteInputForLifecycle(false, false, false, true, false, false))
        .assertTrue();
      expect(shouldBlockRemoteInputForLifecycle(false, false, false, false, true, false))
        .assertTrue();
      expect(shouldBlockRemoteInputForLifecycle(false, false, false, false, false, true))
        .assertTrue();
      expect(shouldBlockRemoteInputForLifecycle(false, false, false, false, false, false))
        .assertFalse();
    });

    it('keeps_input_fenced_until_window_is_active_after_restore', 0, (): void => {
      let active: boolean = remoteInputWindowActiveAfterEvent(true, 'inactive');
      expect(active).assertFalse();
      active = remoteInputWindowActiveAfterEvent(active, 'shown');
      expect(active).assertFalse();
      expect(shouldBlockRemoteInputForLifecycle(!active, false, false, false, false, false))
        .assertTrue();
      active = remoteInputWindowActiveAfterEvent(active, 'active');
      expect(active).assertTrue();
      expect(shouldBlockRemoteInputForLifecycle(!active, false, false, false, false, false))
        .assertFalse();
    });

    it('does_not_treat_visibility_or_unknown_events_as_focus_evidence', 0, (): void => {
      expect(remoteInputWindowFocusKnownAfterEvent(false, 'shown')).assertFalse();
      expect(remoteInputWindowFocusKnownAfterEvent(false, 'unknown')).assertFalse();
      expect(remoteInputWindowFocusKnownAfterEvent(false, 'active')).assertTrue();
      expect(remoteInputWindowFocusKnownAfterEvent(false, 'inactive')).assertTrue();
      expect(remoteInputWindowFocusKnownAfterEvent(false, 'hidden')).assertTrue();
      expect(remoteInputWindowFocusKnownAfterEvent(false, 'destroyed')).assertTrue();
    });

    it('rejects_callbacks_from_an_unregistered_window_generation', 0, (): void => {
      expect(remoteInputWindowListenerIsCurrent(4, 4)).assertTrue();
      expect(remoteInputWindowListenerIsCurrent(4, 5)).assertFalse();
      expect(remoteInputWindowListenerIsCurrent(5, 4)).assertFalse();
      expect(remoteInputWindowListenerIsCurrent(4.5, 4.5)).assertFalse();
    });

    it('releases_only_buttons_with_a_submitted_down', 0, (): void => {
      let down: Array<number> = remoteMouseButtonsAfterEvent([], 0, true);
      down = remoteMouseButtonsAfterEvent(down, 0, true);
      down = remoteMouseButtonsAfterEvent(down, 2, true);
      expect(down.length).assertEqual(2);
      expect(down[0]).assertEqual(0);
      expect(down[1]).assertEqual(2);
      down = remoteMouseButtonsAfterEvent(down, 0, false);
      expect(down.length).assertEqual(1);
      expect(down[0]).assertEqual(2);
      down = remoteMouseButtonsAfterEvent(down, 2, false);
      expect(down.length).assertEqual(0);
      expect(remoteMouseButtonsAfterEvent([], 2, false).length).assertEqual(0);
    });

    it('pairs_multi_button_releases_without_losing_remaining_holds', 0, (): void => {
      let localDown: Array<number> = remoteMouseButtonsAfterEvent([], 0, true);
      localDown = remoteMouseButtonsAfterEvent(localDown, 2, true);
      expect(resolvePhysicalMouseReleaseButton(0, localDown)).assertEqual(0);
      localDown = remoteMouseButtonsAfterEvent(localDown, 0, false);
      expect(resolvePhysicalMouseReleaseButton(2, localDown)).assertEqual(2);
      localDown = remoteMouseButtonsAfterEvent(localDown, 2, false);
      expect(localDown.length).assertEqual(0);
    });

    it('keeps_staged_macos_left_click_identity_across_mouse_chords', 0, (): void => {
      expect(physicalMousePressDisposition(true, -1, [], 0))
        .assertEqual(PhysicalMousePressDisposition.STAGE);
      expect(physicalMousePressDisposition(false, 0, [], 2))
        .assertEqual(PhysicalMousePressDisposition.COMMIT_STAGED_THEN_SEND);
      expect(physicalMousePressDisposition(true, 0, [2], 0))
        .assertEqual(PhysicalMousePressDisposition.IGNORE_DUPLICATE);
      expect(physicalMousePressDisposition(true, -1, [2], 0))
        .assertEqual(PhysicalMousePressDisposition.SEND_NOW);
      expect(physicalMousePressDisposition(false, 0, [2], 2))
        .assertEqual(PhysicalMousePressDisposition.IGNORE_DUPLICATE);
      expect(shouldRecoverPointerFocusAfterMouseRelease([2], false)).assertFalse();
      expect(shouldRecoverPointerFocusAfterMouseRelease([], true)).assertFalse();
      expect(shouldRecoverPointerFocusAfterMouseRelease([], false)).assertTrue();
    });

    it('drops_unpaired_or_ambiguous_mouse_releases_after_window_minimize', 0, (): void => {
      expect(resolvePhysicalMouseReleaseButton(2, [])).assertEqual(-1);
      expect(resolvePhysicalMouseReleaseButton(2, [0])).assertEqual(-1);
      expect(resolvePhysicalMouseReleaseButton(0, [0])).assertEqual(0);
      expect(resolvePhysicalMouseReleaseButton(-1, [2])).assertEqual(2);
      expect(resolvePhysicalMouseReleaseButton(-1, [0, 2])).assertEqual(-1);
    });

    it('fails_safe_by_releasing_every_button_for_ambiguous_multi_button_up', 0, (): void => {
      let remoteDown: Array<number> = [0, 2];
      expect(shouldReleaseAllMouseButtonsForAmbiguousUp(-1, remoteDown)).assertTrue();
      const heldBeforeRelease: Array<number> = remoteDown.slice();
      for (let index = 0; index < heldBeforeRelease.length; index++) {
        remoteDown = remoteMouseButtonsAfterEvent(remoteDown, heldBeforeRelease[index], false);
      }
      expect(remoteDown.length).assertEqual(0);
      expect(shouldReleaseAllMouseButtonsForAmbiguousUp(0, [0, 2])).assertFalse();
      expect(shouldReleaseAllMouseButtonsForAmbiguousUp(-1, [0])).assertFalse();
    });

    it('keeps_local_pairing_separate_from_swapped_remote_buttons', 0, (): void => {
      let localDown: Array<number> = [];
      let remoteDown: Array<number> = [];
      localDown = remoteMouseButtonsAfterEvent(localDown, 0, true);
      remoteDown = remoteMouseButtonsAfterEvent(remoteDown,
        mouseButtonForRemote(0, true), true);
      localDown = remoteMouseButtonsAfterEvent(localDown, 2, true);
      remoteDown = remoteMouseButtonsAfterEvent(remoteDown,
        mouseButtonForRemote(2, true), true);
      expect(localDown[0]).assertEqual(0);
      expect(localDown[1]).assertEqual(2);
      expect(remoteDown[0]).assertEqual(2);
      expect(remoteDown[1]).assertEqual(0);
      localDown = remoteMouseButtonsAfterEvent(localDown, 0, false);
      remoteDown = remoteMouseButtonsAfterEvent(remoteDown,
        mouseButtonForRemote(0, true), false);
      expect(resolvePhysicalMouseReleaseButton(2, localDown)).assertEqual(2);
      expect(remoteDown.length).assertEqual(1);
      expect(remoteDown[0]).assertEqual(0);
    });

    it('releases_wire_buttons_before_changing_left_right_swap', 0, (): void => {
      let remoteDown: Array<number> = remoteMouseButtonsAfterEvent([], 0, true);
      expect(shouldReleaseMouseButtonsBeforeSwapChange(false, true, remoteDown)).assertTrue();
      remoteDown = remoteMouseButtonsAfterEvent(remoteDown, 0, false);
      expect(remoteDown.length).assertEqual(0);
      expect(shouldReleaseMouseButtonsBeforeSwapChange(true, true, [2])).assertFalse();
      expect(shouldReleaseMouseButtonsBeforeSwapChange(false, true, [])).assertFalse();
    });
  });
}
