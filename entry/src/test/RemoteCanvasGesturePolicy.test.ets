import { describe, it, expect } from '@ohos/hypium';
import {
  advanceCanvasTwoFingerMove,
  beginCanvasTwoFingerCandidate,
  claimCanvasTwoFingerPan,
  claimCanvasTwoFingerPinch,
  endCanvasPanOwnership,
  endCanvasPinchOwnership,
  finishCanvasTwoFingerCandidate,
  shouldApplyCanvasTwoFingerPan,
  shouldPreserveCanvasTwoFingerRightClick,
  shouldReleaseCanvasGestureOwnership,
  shouldSendCanvasTwoFingerScroll
} from '../main/ets/services/RemoteCanvasGesturePolicy';

export default function remoteCanvasGesturePolicyTest(): void {
  describe('RemoteCanvasGesturePolicy', (): void => {
    it('releases the shared drain only after pinch and pan finish', 0, (): void => {
      const afterPinch = endCanvasPinchOwnership({ pinchActive: true, panActive: true });
      expect(afterPinch.panActive).assertTrue();
      expect(shouldReleaseCanvasGestureOwnership(afterPinch)).assertFalse();
      expect(shouldReleaseCanvasGestureOwnership(endCanvasPanOwnership(afterPinch))).assertTrue();
    });

    it('keeps fit-canvas two-finger translation on remote scroll', 0, (): void => {
      const candidate = beginCanvasTwoFingerCandidate(1, 100, 100, 0, true, false, 80);
      const result = advanceCanvasTwoFingerMove(candidate, 100, 108, 10, false, 81);
      expect(result.state.owner).assertEqual('touchpad-scroll');
      expect(result.action).assertEqual('scroll');
      expect(shouldSendCanvasTwoFingerScroll(result.state)).assertTrue();
    });

    it('pans an overflowing canvas without a hold delay', 0, (): void => {
      const candidate = beginCanvasTwoFingerCandidate(2, 100, 100, 0, true, true, 80);
      const result = advanceCanvasTwoFingerMove(candidate, 108, 100, 1, false, 80);
      expect(result.state.owner).assertEqual('canvas-pan');
      expect(result.action).assertEqual('pan');
      expect(shouldApplyCanvasTwoFingerPan(result.state)).assertTrue();
    });

    it('routes immediate RustDesk remote-app translation to touch pan', 0, (): void => {
      const candidate = beginCanvasTwoFingerCandidate(3, 100, 100, 0, true, true, 80);
      const result = advanceCanvasTwoFingerMove(candidate, 108, 100, 1, true, 80);
      expect(result.state.owner).assertEqual('remote-touch-pan');
      expect(claimCanvasTwoFingerPan(candidate, true).owner).assertEqual('remote-touch-pan');
    });

    it('lets span change claim pinch before centroid translation', 0, (): void => {
      const candidate = beginCanvasTwoFingerCandidate(4, 100, 100, 0, true, true, 80);
      const result = advanceCanvasTwoFingerMove(candidate, 110, 100, 1, false, 86);
      expect(result.state.owner).assertEqual('canvas-pinch');
      expect(result.action).assertEqual('none');
      expect(shouldApplyCanvasTwoFingerPan(result.state)).assertFalse();
    });

    it('lets a recognized slow pinch replace provisional fit scroll', 0, (): void => {
      const candidate = beginCanvasTwoFingerCandidate(5, 100, 100, 0, true, false, 80);
      const scroll = advanceCanvasTwoFingerMove(candidate, 100, 106, 1, false, 82);
      expect(scroll.state.owner).assertEqual('touchpad-scroll');
      expect(claimCanvasTwoFingerPinch(scroll.state, false).owner).assertEqual('canvas-pinch');
    });

    it('does not let pinch steal a committed pan', 0, (): void => {
      const candidate = beginCanvasTwoFingerCandidate(6, 100, 100, 0, true, true, 80);
      const pan = claimCanvasTwoFingerPan(candidate, false);
      expect(claimCanvasTwoFingerPinch(pan, false).owner).assertEqual('canvas-pan');
    });

    it('preserves a stationary two-finger release as right click', 0, (): void => {
      const candidate = beginCanvasTwoFingerCandidate(7, 100, 100, 0, true, true, 80);
      const finished = finishCanvasTwoFingerCandidate(candidate, false);
      expect(finished.owner).assertEqual('touchpad-right-click');
      expect(shouldPreserveCanvasTwoFingerRightClick(finished)).assertTrue();
    });

    it('keeps remote touch scale as a distinct owner', 0, (): void => {
      const candidate = beginCanvasTwoFingerCandidate(8, 100, 100, 0, true, true, 80);
      expect(claimCanvasTwoFingerPinch(candidate, true).owner).assertEqual('remote-touch-scale');
      const ended = endCanvasPinchOwnership({ pinchActive: true, panActive: false });
      expect(ended.pinchActive).assertFalse();
      expect(shouldReleaseCanvasGestureOwnership(ended)).assertTrue();
    });
  });
}
