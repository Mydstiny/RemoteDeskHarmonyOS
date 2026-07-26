import { describe, it, expect } from '@ohos/hypium';
import {
  advanceCanvasPinchTouchState,
  claimCanvasPinchTouchState,
  drainCanvasPinchTouchState,
  shouldConsumeCanvasPinchTouch,
  shouldStartNewCanvasPinchTouchSequence
} from '../main/ets/services/RemoteCanvasPinchInputPolicy';

export default function remoteCanvasPinchInputPolicyTest(): void {
  describe('RemoteCanvasPinchInputPolicy', (): void => {
    it('consumes an active finger pinch stream', 0, (): void => {
      expect(shouldConsumeCanvasPinchTouch(true, true)).assertTrue();
    });

    it('does not consume mouse, pen or touchpad streams', 0, (): void => {
      expect(shouldConsumeCanvasPinchTouch(true, false)).assertFalse();
    });

    it('does not consume a finger stream before pinch ownership exists', 0, (): void => {
      expect(shouldConsumeCanvasPinchTouch(false, true)).assertFalse();
    });

    it('keeps ownership while the two fingers lift in separate Up events', 0, (): void => {
      const claimed = claimCanvasPinchTouchState(2);
      const draining = drainCanvasPinchTouchState(claimed);
      const firstUp = advanceCanvasPinchTouchState(draining, 'up', 2, 1);
      expect(firstUp.phase).assertEqual('draining');
      expect(firstUp.fingerCount).assertEqual(1);
      const finalUp = advanceCanvasPinchTouchState(firstUp, 'up', 1, 1);
      expect(finalUp.phase).assertEqual('idle');
      expect(finalUp.fingerCount).assertEqual(0);
    });

    it('handles Up events that exclude the changed finger', 0, (): void => {
      const state = drainCanvasPinchTouchState(claimCanvasPinchTouchState(2));
      const firstUp = advanceCanvasPinchTouchState(state, 'up', 1, 1);
      expect(firstUp.phase).assertEqual('draining');
      expect(firstUp.fingerCount).assertEqual(1);
      const finalUp = advanceCanvasPinchTouchState(firstUp, 'up', 0, 1);
      expect(finalUp.phase).assertEqual('idle');
    });

    it('terminates ownership on Cancel without forwarding it', 0, (): void => {
      const state = drainCanvasPinchTouchState(claimCanvasPinchTouchState(2));
      const cancelled = advanceCanvasPinchTouchState(state, 'cancel', 0, 2);
      expect(cancelled.phase).assertEqual('idle');
      expect(cancelled.fingerCount).assertEqual(0);
    });

    it('allows a new one-finger sequence after a missing terminal event', 0, (): void => {
      expect(shouldStartNewCanvasPinchTouchSequence('draining', 'down', 1, 1)).assertTrue();
      expect(shouldStartNewCanvasPinchTouchSequence('draining', 'down', 3, 1)).assertFalse();
      expect(shouldStartNewCanvasPinchTouchSequence('gesture', 'down', 1, 1)).assertFalse();
    });
  });
}
