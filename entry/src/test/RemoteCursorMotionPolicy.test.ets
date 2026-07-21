import { describe, it, expect } from '@ohos/hypium';
import {
  advanceRemoteCursorMotion,
  applyLocalCursorTarget,
  beginLocalCursorGesture,
  createRemoteCursorMotionState,
  endLocalCursorGesture,
  observeRemoteCursorPosition,
  REMOTE_CURSOR_LOCAL_SETTLE_MS,
  REMOTE_CURSOR_REMOTE_SILENCE_MS
} from '../main/ets/services/RemoteCursorMotionPolicy';

export default function remoteCursorMotionPolicyTest(): void {
  describe('RemoteCursorMotionPolicy', (): void => {
    it('keeps an active local gesture ahead of delayed remote coordinates', 0, (): void => {
      let state = createRemoteCursorMotionState(100, 100);
      state = beginLocalCursorGesture(state, 1000);
      state = applyLocalCursorTarget(state, 260, 180, 1010);
      state = observeRemoteCursorPosition(state, 120, 110, 1020);
      expect(state.displayX).assertEqual(260);
      expect(state.displayY).assertEqual(180);
      expect(state.owner).assertEqual('local-gesture');
    });

    it('does not use a far deferred coordinate as a timeout acknowledgement', 0, (): void => {
      let state = createRemoteCursorMotionState(100, 100);
      state = beginLocalCursorGesture(state, 1000);
      state = applyLocalCursorTarget(state, 500, 400, 1010);
      state = observeRemoteCursorPosition(state, 100, 100, 1020);
      state = endLocalCursorGesture(state, 1030);
      state = advanceRemoteCursorMotion(state, 1030 + REMOTE_CURSOR_LOCAL_SETTLE_MS);
      expect(state.displayX).assertEqual(500);
      expect(state.displayY).assertEqual(400);
      expect(state.owner).assertEqual('remote-silent');
    });

    it('does not let two early far observations pull a finished local gesture backward', 0, (): void => {
      let state = createRemoteCursorMotionState(100, 100);
      state = beginLocalCursorGesture(state, 1000);
      state = applyLocalCursorTarget(state, 500, 400, 1010);
      state = endLocalCursorGesture(state, 1020);
      const earlyAtMs: number = 1020 + REMOTE_CURSOR_LOCAL_SETTLE_MS + 1;
      state = observeRemoteCursorPosition(state, 100, 100, earlyAtMs);
      state = observeRemoteCursorPosition(state, 120, 110, earlyAtMs + 10);
      expect(state.displayX).assertEqual(500);
      expect(state.displayY).assertEqual(400);
      expect(state.owner).assertEqual('remote-silent');
    });

    it('accepts a close post-gesture peer echo without a visible jump', 0, (): void => {
      let state = createRemoteCursorMotionState(0, 0);
      state = beginLocalCursorGesture(state, 1000);
      state = applyLocalCursorTarget(state, 300, 200, 1010);
      state = endLocalCursorGesture(state, 1020);
      state = observeRemoteCursorPosition(state, 306, 206,
        1020 + REMOTE_CURSOR_LOCAL_SETTLE_MS + 1);
      expect(state.displayX).assertEqual(306);
      expect(state.displayY).assertEqual(206);
      expect(state.owner).assertEqual('remote');
    });

    it('allows independent remote movement after local input has been idle', 0, (): void => {
      let state = createRemoteCursorMotionState(0, 0);
      state = beginLocalCursorGesture(state, 1000);
      state = applyLocalCursorTarget(state, 300, 200, 1010);
      state = endLocalCursorGesture(state, 1020);
      state = advanceRemoteCursorMotion(state, 1020 + REMOTE_CURSOR_LOCAL_SETTLE_MS);
      state = observeRemoteCursorPosition(state, 800, 700,
        1010 + REMOTE_CURSOR_REMOTE_SILENCE_MS);
      expect(state.displayX).assertEqual(800);
      expect(state.displayY).assertEqual(700);
      expect(state.owner).assertEqual('remote');
    });

    it('keeps coordinates finite when a producer supplies invalid values', 0, (): void => {
      let state = createRemoteCursorMotionState(10, 20);
      state = applyLocalCursorTarget(state, NaN, Infinity, NaN);
      expect(Number.isFinite(state.displayX)).assertTrue();
      expect(Number.isFinite(state.displayY)).assertTrue();
      state = observeRemoteCursorPosition(state, NaN, Infinity, Infinity);
      expect(Number.isFinite(state.remoteObservedX)).assertTrue();
      expect(Number.isFinite(state.remoteObservedY)).assertTrue();
    });
  });
}
