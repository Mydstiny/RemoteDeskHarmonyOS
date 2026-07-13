/**
 * RemoteRestoreFrameRefreshPolicy.test.ets - 前台恢复刷新节奏
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  getRestoreFrameRefreshDelaysMs,
  RestoreRefreshAction,
  restoreRefreshActionForDelay,
  shouldPollSurfaceForRestore,
  shouldRebindSurfaceForRestore,
  shouldRestoreRenderImmediately
} from '../../../main/ets/services/RemoteRestoreFrameRefreshPolicy';

export default function remoteRestoreFrameRefreshPolicyTest(): void {
  describe('RemoteRestoreFrameRefreshPolicy', (): void => {
    it('restore_refresh_should_retry_after_initial_request', 0, (): void => {
      const delays: number[] = getRestoreFrameRefreshDelaysMs();
      expect(delays.length).assertLarger(1);
      expect(delays[0]).assertEqual(0);
      expect(delays[delays.length - 1]).assertLarger(300);
    });

    it('restore_refresh_should_cover_target_and_fallback_windows', 0, (): void => {
      const delays: number[] = getRestoreFrameRefreshDelaysMs();
      expect(delays[0]).assertEqual(0);
      expect(delays.indexOf(3000)).assertLarger(-1);
      expect(delays[delays.length - 1]).assertEqual(10000);
    });

    it('restore_should_reattach_immediately_when_surface_is_ready', 0, (): void => {
      expect(shouldRestoreRenderImmediately(true, 7, true, false)).assertEqual(true);
      expect(shouldPollSurfaceForRestore(true, 7, true, false)).assertEqual(false);
    });

    it('restore_should_poll_surface_when_surface_is_not_ready', 0, (): void => {
      expect(shouldRestoreRenderImmediately(true, 7, false, false)).assertEqual(false);
      expect(shouldPollSurfaceForRestore(true, 7, false, false)).assertEqual(true);
    });

    it('restore_should_skip_when_session_or_cleanup_is_invalid', 0, (): void => {
      expect(shouldRestoreRenderImmediately(true, -1, true, false)).assertEqual(false);
      expect(shouldPollSurfaceForRestore(true, -1, false, false)).assertEqual(false);
      expect(shouldRestoreRenderImmediately(true, 7, true, true)).assertEqual(false);
      expect(shouldPollSurfaceForRestore(true, 7, false, true)).assertEqual(false);
    });

    it('restore_escalates_to_surface_rebind_before_stall', 0, (): void => {
      expect(restoreRefreshActionForDelay(0)).assertEqual(RestoreRefreshAction.REQUEST_FRAME);
      expect(restoreRefreshActionForDelay(3000)).assertEqual(RestoreRefreshAction.REBIND_SURFACE);
      expect(restoreRefreshActionForDelay(10000)).assertEqual(RestoreRefreshAction.REPORT_STALLED);
    });

    it('restore_should_not_recreate_surface_when_renderer_is_attached', 0, (): void => {
      expect(shouldRebindSurfaceForRestore(RestoreRefreshAction.REBIND_SURFACE, -1)).assertEqual(true);
      expect(shouldRebindSurfaceForRestore(RestoreRefreshAction.REBIND_SURFACE, 387591935632)).assertEqual(false);
      expect(shouldRebindSurfaceForRestore(RestoreRefreshAction.REQUEST_FRAME, -1)).assertEqual(false);
    });
  });
}
