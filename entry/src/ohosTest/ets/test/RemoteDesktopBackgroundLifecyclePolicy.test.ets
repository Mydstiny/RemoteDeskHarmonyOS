/**
 * RemoteDesktopBackgroundLifecyclePolicy.test.ets - Ability bg flag lifecycle decisions (T-256)
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  decideRemoteDesktopBackgroundAction,
  RemoteDesktopBackgroundAction,
  shouldDeferRemoteDesktopDisappear
} from '../../../main/ets/services/RemoteDesktopBackgroundLifecyclePolicy';

export default function remoteDesktopBackgroundLifecyclePolicyTest(): void {
  describe('RemoteDesktopBackgroundLifecyclePolicy', (): void => {
    it('background_flag_true_should_detach_connected_session', 0, (): void => {
      const action = decideRemoteDesktopBackgroundAction(true, true, 7, false, false);
      expect(action).assertEqual(RemoteDesktopBackgroundAction.detach);
    });

    it('background_flag_true_should_not_disconnect_already_preserved_session', 0, (): void => {
      const action = decideRemoteDesktopBackgroundAction(true, false, 7, true, true);
      expect(action).assertEqual(RemoteDesktopBackgroundAction.alreadyPreserved);
    });

    it('foreground_flag_false_should_restore_preserved_session', 0, (): void => {
      const action = decideRemoteDesktopBackgroundAction(false, false, 7, true, true);
      expect(action).assertEqual(RemoteDesktopBackgroundAction.restore);
    });

    it('foreground_flag_false_without_preserved_session_should_do_nothing', 0, (): void => {
      const action = decideRemoteDesktopBackgroundAction(false, false, -1, false, false);
      expect(action).assertEqual(RemoteDesktopBackgroundAction.none);
    });

    it('background_without_connected_session_should_not_start_preserve_path', 0, (): void => {
      expect(decideRemoteDesktopBackgroundAction(true, false, -1, false, false))
        .assertEqual(RemoteDesktopBackgroundAction.none);
      expect(decideRemoteDesktopBackgroundAction(true, false, 7, false, false))
        .assertEqual(RemoteDesktopBackgroundAction.none);
    });

    it('connected_page_should_wait_for_late_background_signal_before_disconnect', 0, (): void => {
      expect(shouldDeferRemoteDesktopDisappear(false, true, 7, false, false)).assertTrue();
      expect(shouldDeferRemoteDesktopDisappear(true, true, 7, false, false)).assertFalse();
      expect(shouldDeferRemoteDesktopDisappear(false, false, 7, false, false)).assertFalse();
      expect(shouldDeferRemoteDesktopDisappear(false, true, 7, true, true)).assertFalse();
    });
  });
}
