import { describe, it, expect } from '@ohos/hypium';
import {
  nextTwoFingerScrollLatch,
  shouldStartTwoFingerScroll,
  twoFingerSpreadVp,
  TWO_FINGER_SCROLL_MAX_SPREAD_STEP_VP,
  TWO_FINGER_SCROLL_MIN_STEP_VP
} from '../main/ets/services/TwoFingerScrollPolicy';

export default function twoFingerScrollPolicyTest(): void {
  describe('TwoFingerScrollPolicy_spread', (): void => {
    it('should_measure_distance_between_two_contacts', 0, (): void => {
      expect(twoFingerSpreadVp(0, 0, 3, 4)).assertEqual(5);
      expect(twoFingerSpreadVp(10, 10, 10, 10)).assertEqual(0);
    });
  });

  describe('TwoFingerScrollPolicy_decision', (): void => {
    it('should_scroll_on_vertical_drag_with_stable_spread', 0, (): void => {
      expect(shouldStartTwoFingerScroll(0, 6, 0)).assertTrue();
      expect(shouldStartTwoFingerScroll(0, -6, 0.5)).assertTrue();
    });

    it('should_ignore_jitter_below_min_step', 0, (): void => {
      const belowMin: number = TWO_FINGER_SCROLL_MIN_STEP_VP - 0.1;
      expect(shouldStartTwoFingerScroll(0, belowMin, 0)).assertFalse();
      expect(shouldStartTwoFingerScroll(0, 0, 0)).assertFalse();
    });

    it('should_yield_to_pinch_when_spread_changes', 0, (): void => {
      const spreading: number = TWO_FINGER_SCROLL_MAX_SPREAD_STEP_VP + 0.5;
      expect(shouldStartTwoFingerScroll(0, 6, spreading)).assertFalse();
      expect(shouldStartTwoFingerScroll(0, 6, -spreading)).assertFalse();
    });

    it('should_reject_horizontally_dominant_drag', 0, (): void => {
      expect(shouldStartTwoFingerScroll(20, 2, 0)).assertFalse();
      // 45 度斜滑：纵向没有达到横向的 1.4 倍，不算滚动。
      expect(shouldStartTwoFingerScroll(6, 6, 0)).assertFalse();
    });

    it('should_reject_non_finite_input', 0, (): void => {
      expect(shouldStartTwoFingerScroll(Number.NaN, 6, 0)).assertFalse();
      expect(shouldStartTwoFingerScroll(0, Number.NaN, 0)).assertFalse();
      expect(shouldStartTwoFingerScroll(0, 6, Number.NaN)).assertFalse();
    });
  });

  describe('TwoFingerScrollPolicy_latch', (): void => {
    it('should_keep_scrolling_once_recognized', 0, (): void => {
      // 一旦锁存，后续帧即使间距抖动或转为横向也继续按滚轮处理。
      const spreading: number = TWO_FINGER_SCROLL_MAX_SPREAD_STEP_VP + 5;
      expect(nextTwoFingerScrollLatch(true, 20, 0.1, spreading)).assertTrue();
    });

    it('should_stay_idle_until_a_real_scroll_step', 0, (): void => {
      expect(nextTwoFingerScrollLatch(false, 0, 0.1, 0)).assertFalse();
      expect(nextTwoFingerScrollLatch(false, 0, 6, 0)).assertTrue();
    });
  });
}
