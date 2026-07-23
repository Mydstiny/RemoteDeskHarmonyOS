/**
 * RemoteSessionPipLifecyclePolicy.test.ets - PIP preparation/auto-start rules.
 */
import { describe, it, expect } from '@ohos/hypium';
import { LiveViewMode } from '../../../main/ets/services/LiveViewTypes';
import {
  RemoteSessionPipLifecycleAction,
  hasRemoteSessionPipVideo,
  hasRdpRemoteSessionPipFrame,
  shouldPrepareRemoteSessionPip,
  resolveRemoteSessionPipLifecycle,
  resolveRemoteSessionPipContentSize
} from '../../../main/ets/services/RemoteSessionPipLifecyclePolicy';

export default function remoteSessionPipLifecyclePolicyTest(): void {
  describe('RemoteSessionPipLifecyclePolicy', (): void => {
    it('waits_for_system_auto_start_after_the_main_window_is_hidden', 0, (): void => {
      expect(resolveRemoteSessionPipLifecycle(
        true, LiveViewMode.AVSESSION, true, true, true, false
      )).assertEqual(RemoteSessionPipLifecycleAction.WAIT_FOR_AUTO_START);
    });

    it('disables_pip_when_the_remote_session_is_no_longer_active', 0, (): void => {
      expect(resolveRemoteSessionPipLifecycle(
        true, LiveViewMode.AVSESSION, true, false, true, false
      )).assertEqual(RemoteSessionPipLifecycleAction.DISABLE);
    });

    it('prepares_pip_only_while_the_foreground_window_is_shown', 0, (): void => {
      expect(resolveRemoteSessionPipLifecycle(
        true, LiveViewMode.AVSESSION, true, true, false, true
      )).assertEqual(RemoteSessionPipLifecycleAction.PREPARE);
    });

    it('allows_foreground_controller_prepare_before_the_first_video_frame', 0, (): void => {
      expect(shouldPrepareRemoteSessionPip(
        true, LiveViewMode.AVSESSION, true, true, true
      )).assertTrue();
    });

    it('uses_the_rdp_frame_pump_instead_of_a_decoder_handle', 0, (): void => {
      expect(hasRemoteSessionPipVideo('rdp', true, true, false, true)).assertTrue();
      expect(hasRemoteSessionPipVideo('rdp', true, true, false, false)).assertFalse();
    });

    it('accepts_rdp_owned_frame_before_graphics_metadata', 0, (): void => {
      expect(hasRdpRemoteSessionPipFrame(1, 4096)).assertTrue();
      expect(hasRdpRemoteSessionPipFrame(1, 0)).assertFalse();
      expect(hasRdpRemoteSessionPipFrame(0, 4096)).assertFalse();
    });

    it('keeps_decoder_requirement_for_rustdesk', 0, (): void => {
      expect(hasRemoteSessionPipVideo('rustdesk', true, true, true, false)).assertTrue();
      expect(hasRemoteSessionPipVideo('rustdesk', true, true, false, true)).assertFalse();
    });

    it('uses_remote_video_dimensions_for_content_ratio', 0, (): void => {
      const size = resolveRemoteSessionPipContentSize(2560, 1600, 2848, 1320);
      expect(size.width).assertEqual(2560);
      expect(size.height).assertEqual(1600);
    });

    it('falls_back_to_logical_remote_dimensions_before_the_first_frame', 0, (): void => {
      const size = resolveRemoteSessionPipContentSize(0, 0, 1600, 742);
      expect(size.width).assertEqual(1600);
      expect(size.height).assertEqual(742);
    });
  });
}
