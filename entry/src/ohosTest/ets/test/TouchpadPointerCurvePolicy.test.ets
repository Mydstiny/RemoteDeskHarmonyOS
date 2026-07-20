import { describe, it, expect } from '@ohos/hypium';
import {
  clampTouchpadEffectiveGain,
  resetTouchpadPointerCurveState,
  touchpadPointerCurve
} from '../../../main/ets/services/TouchpadPointerCurvePolicy';

export default function touchpadPointerCurvePolicyTest(): void {
  describe('TouchpadPointerCurvePolicy', (): void => {
    it('long_event_gap_resets_velocity_instead_of_spiking', 0, (): void => {
      const previous = { smoothedSpeed: 0.9, lastTimeMs: 1000 };
      const result = touchpadPointerCurve(40, 0, 1201, previous);
      expect(result.gain).assertEqual(0.75);
      expect(result.state.smoothedSpeed).assertEqual(0);
    });

    it('small_steps_keep_a_nonzero_precision_gain', 0, (): void => {
      const result = touchpadPointerCurve(0.5, 0, 1016, resetTouchpadPointerCurveState());
      expect(result.gain >= 0.75).assertTrue();
      expect(result.gain <= 1.65).assertTrue();
    });

    it('effective_gain_is_bounded_even_with_user_speed', 0, (): void => {
      expect(clampTouchpadEffectiveGain(1.65, 2.2)).assertEqual(2.4);
    });
    it('invalid_previous_state_does_not_create_nan', 0, (): void => {
      const result = touchpadPointerCurve(1, 0, 1000, {
        smoothedSpeed: NaN,
        lastTimeMs: Infinity
      });
      expect(Number.isFinite(result.gain)).assertTrue();
      expect(Number.isFinite(result.state.smoothedSpeed)).assertTrue();
    });
  });
}
