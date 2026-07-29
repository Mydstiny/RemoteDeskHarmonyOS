import { describe, it, expect } from '@ohos/hypium';
import {
  advanceCanvasTwoFingerMove,
  beginCanvasTwoFingerCandidate,
  claimCanvasTwoFingerPan,
  claimCanvasTwoFingerPinch,
  expireCanvasTwoFingerHold,
  endCanvasPanOwnership,
  endCanvasPinchOwnership,
  finishCanvasTwoFingerCandidate,
  shouldApplyCanvasTwoFingerPan,
  shouldPreserveCanvasTwoFingerRightClick,
  shouldSendCanvasTwoFingerScroll,
  shouldReleaseCanvasGestureOwnership
} from '../main/ets/services/RemoteCanvasGesturePolicy';

export default function remoteCanvasGesturePolicyTest(): void {
  describe('RemoteCanvasGesturePolicy', (): void => {
    it('keeps pan ownership when pinch ends first', 0, (): void => {
      const afterPinch = endCanvasPinchOwnership({ pinchActive: true, panActive: true });
      expect(afterPinch.pinchActive).assertFalse();
      expect(afterPinch.panActive).assertTrue();
      expect(shouldReleaseCanvasGestureOwnership(afterPinch)).assertFalse();
      const final = endCanvasPanOwnership(afterPinch);
      expect(shouldReleaseCanvasGestureOwnership(final)).assertTrue();
    });

    it('keeps pinch ownership when pan ends first', 0, (): void => {
      const afterPan = endCanvasPanOwnership({ pinchActive: true, panActive: true });
      expect(afterPan.pinchActive).assertTrue();
      expect(afterPan.panActive).assertFalse();
      expect(shouldReleaseCanvasGestureOwnership(afterPan)).assertFalse();
      const final = endCanvasPinchOwnership(afterPan);
      expect(shouldReleaseCanvasGestureOwnership(final)).assertTrue();
    });

    it('keeps fast two-finger movement on the touchpad scroll path', 0, (): void => {
      const candidate = beginCanvasTwoFingerCandidate(1, 100, 100, 0, true, true);
      const result = advanceCanvasTwoFingerMove(candidate, 100, 120, 100);
      expect(result.state.owner).assertEqual('touchpad-scroll');
      expect(result.action).assertEqual('scroll');
      expect(shouldSendCanvasTwoFingerScroll(result.state)).assertTrue();
      expect(shouldApplyCanvasTwoFingerPan(result.state)).assertFalse();
    });

    it('arms then claims canvas pan only after the hold', 0, (): void => {
      const candidate = beginCanvasTwoFingerCandidate(2, 100, 100, 0, true, true);
      const armed = expireCanvasTwoFingerHold(candidate, 400);
      expect(armed.owner).assertEqual('canvas-pan-armed');
      const moved = advanceCanvasTwoFingerMove(armed, 110, 100, 401);
      expect(moved.state.owner).assertEqual('canvas-pan');
      expect(moved.action).assertEqual('pan');
      expect(shouldApplyCanvasTwoFingerPan(moved.state)).assertTrue();
      expect(shouldSendCanvasTwoFingerScroll(moved.state)).assertFalse();
      expect(claimCanvasTwoFingerPan(armed, false).owner).assertEqual('canvas-pan');
    });

    it('honors a late hold deadline before classifying the first move', 0, (): void => {
      const candidate = beginCanvasTwoFingerCandidate(7, 100, 100, 0, true, true);
      const moved = advanceCanvasTwoFingerMove(candidate, 140, 100, 500);
      expect(moved.state.owner).assertEqual('canvas-pan');
      expect(moved.action).assertEqual('pan');
    });

    it('does not arm pan when the canvas cannot overflow', 0, (): void => {
      const candidate = beginCanvasTwoFingerCandidate(3, 100, 100, 0, true, false);
      const expired = expireCanvasTwoFingerHold(candidate, 500);
      expect(expired.owner).assertEqual('candidate');
      expect(expired.holdTimerPending).assertFalse();
      const moved = advanceCanvasTwoFingerMove(expired, 100, 120, 501);
      expect(moved.state.owner).assertEqual('touchpad-scroll');
    });

    it('lets pinch win before the hold and cancels the timer', 0, (): void => {
      const candidate = beginCanvasTwoFingerCandidate(4, 100, 100, 0, true, true);
      const pinch = claimCanvasTwoFingerPinch(candidate, false);
      expect(pinch.owner).assertEqual('canvas-pinch');
      expect(pinch.holdTimerPending).assertFalse();
      const afterTimer = expireCanvasTwoFingerHold(pinch, 1000);
      expect(afterTimer.owner).assertEqual('canvas-pinch');
    });

    it('preserves a two-finger right click when hold ends without movement', 0, (): void => {
      const candidate = beginCanvasTwoFingerCandidate(5, 100, 100, 0, true, true);
      const armed = expireCanvasTwoFingerHold(candidate, 400);
      const finished = finishCanvasTwoFingerCandidate(armed, false);
      expect(finished.owner).assertEqual('touchpad-right-click');
      expect(shouldPreserveCanvasTwoFingerRightClick(finished)).assertTrue();
      const untouched = finishCanvasTwoFingerCandidate(candidate, false);
      expect(untouched.owner).assertEqual('touchpad-right-click');
      expect(shouldPreserveCanvasTwoFingerRightClick(untouched)).assertTrue();
    });

    it('keeps remote touch scale as a separate target', 0, (): void => {
      const candidate = beginCanvasTwoFingerCandidate(6, 100, 100, 0, true, true);
      const remote = claimCanvasTwoFingerPinch(candidate, true);
      expect(remote.owner).assertEqual('remote-touch-scale');
      expect(shouldApplyCanvasTwoFingerPan(remote)).assertFalse();
    });
  });
}
