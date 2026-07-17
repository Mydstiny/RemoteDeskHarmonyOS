import { describe, it, expect } from '@ohos/hypium';
import {
  TOUCHPAD_CURVE_MAX_GAIN,
  TOUCHPAD_CURVE_MIN_GAIN,
  clampTouchpadEffectiveGain,
  resetTouchpadPointerCurveState,
  touchpadPointerCurve
} from '../main/ets/services/TouchpadPointerCurvePolicy';

export default function touchpadPointerCurvePolicyTest() {
  describe('TouchpadPointerCurvePolicy', (): void => {
    it('is bounded and increases with movement speed', 0, (): void => {
      const state = resetTouchpadPointerCurveState();
      const slow = touchpadPointerCurve(1, 0, 1000, state);
      const fast = touchpadPointerCurve(80, 0, 1016, slow.state);
      expect(slow.gain >= TOUCHPAD_CURVE_MIN_GAIN).assertTrue();
      expect(fast.gain > slow.gain).assertTrue();
      expect(fast.gain <= TOUCHPAD_CURVE_MAX_GAIN).assertTrue();
    });
    it('handles invalid inputs without NaN and caps user speed composition', 0, (): void => {
      const result = touchpadPointerCurve(NaN, Infinity, 0, resetTouchpadPointerCurveState());
      expect(Number.isFinite(result.gain)).assertTrue();
      expect(clampTouchpadEffectiveGain(99, 2.2)).assertEqual(3.0);
    });
  });
}
