import { describe, it, expect } from '@ohos/hypium';
import {
  VNC_CONTINUOUS_WHEEL_GAIN,
  VNC_CONTINUOUS_WHEEL_MAX_DELTA,
  VNC_PHYSICAL_WHEEL_MAX_DELTA,
  VNC_PHYSICAL_WHEEL_STEPS,
  MOONLIGHT_HIGH_RES_WHEEL_DETENT,
  accumulateContinuousRemoteWheel,
  applyRemoteWheelDirection,
  discreteRemoteWheelDelta,
  moonlightAxisScrollAmount,
  nextVncTouchpadFlingDelta,
  shouldStartVncTouchpadFling
} from '../../../main/ets/services/RemoteWheelPolicy';

export default function remoteWheelPolicyTest(): void {
  describe('RemoteWheelPolicy', (): void => {
    it('matches_rustdesk_trackpad_units_and_keeps_fractional_motion_alive', 0, (): void => {
      const fast = accumulateContinuousRemoteWheel(40, 0, 1, 'vnc');
      const fine = accumulateContinuousRemoteWheel(0.5, 0, 1, 'vnc');
      const noise = accumulateContinuousRemoteWheel(0.05, 0, 1, 'vnc');
      expect(VNC_CONTINUOUS_WHEEL_GAIN).assertEqual(2.0);
      expect(fast.delta).assertEqual(VNC_CONTINUOUS_WHEEL_MAX_DELTA);
      expect(fast.remainder).assertEqual(0);
      expect(fine.delta).assertEqual(1);
      expect(noise.delta).assertEqual(0);
    });

    it('keeps_non_vnc_continuous_scroll_curve_compatible', 0, (): void => {
      const result = accumulateContinuousRemoteWheel(25, 0, 1, 'rustdesk');
      expect(result.delta).assertEqual(2);
      expect(result.remainder).assertEqual(0);
    });

    it('keeps_the_verified_physical_baseline_and_bounds_burst_acceleration', 0, (): void => {
      expect(discreteRemoteWheelDelta(1, 'vnc')).assertEqual(VNC_PHYSICAL_WHEEL_STEPS);
      expect(discreteRemoteWheelDelta(-1, 'vnc')).assertEqual(-VNC_PHYSICAL_WHEEL_STEPS);
      expect(discreteRemoteWheelDelta(45, 'vnc')).assertEqual(4);
      expect(discreteRemoteWheelDelta(-45, 'vnc')).assertEqual(-4);
      expect(discreteRemoteWheelDelta(45, 'vnc', 70)).assertEqual(8);
      expect(discreteRemoteWheelDelta(45, 'vnc', 20)).assertEqual(VNC_PHYSICAL_WHEEL_MAX_DELTA);
      expect(discreteRemoteWheelDelta(45, 'vnc', 100)).assertEqual(4);
      expect(discreteRemoteWheelDelta(120, 'vnc', 20)).assertEqual(VNC_PHYSICAL_WHEEL_MAX_DELTA);
      expect(discreteRemoteWheelDelta(120, 'rdp')).assertEqual(1);
    });

    it('normalizes_mouse_detents_and_bounds_moonlight_touchpad_scroll', 0, (): void => {
      expect(moonlightAxisScrollAmount(1, false))
        .assertEqual(MOONLIGHT_HIGH_RES_WHEEL_DETENT);
      expect(moonlightAxisScrollAmount(120, false))
        .assertEqual(MOONLIGHT_HIGH_RES_WHEEL_DETENT);
      expect(moonlightAxisScrollAmount(-120, false))
        .assertEqual(-MOONLIGHT_HIGH_RES_WHEEL_DETENT);
      expect(moonlightAxisScrollAmount(0.1, true)).assertEqual(1);
      expect(moonlightAxisScrollAmount(8, true)).assertEqual(32);
      expect(moonlightAxisScrollAmount(1000, true))
        .assertEqual(MOONLIGHT_HIGH_RES_WHEEL_DETENT);
    });

    it('starts_and_decays_vnc_touchpad_fling_like_rustdesk', 0, (): void => {
      expect(shouldStartVncTouchpadFling(3, 1)).assertTrue();
      expect(shouldStartVncTouchpadFling(2, 1)).assertFalse();
      expect(shouldStartVncTouchpadFling(2.1, 0.5)).assertTrue();
      expect(shouldStartVncTouchpadFling(2, 2)).assertFalse();
      expect(nextVncTouchpadFlingDelta(10)).assertEqual(9.7);
    });

    it('applies_the_shared_personalization_direction_last', 0, (): void => {
      expect(applyRemoteWheelDirection(3, false)).assertEqual(3);
      expect(applyRemoteWheelDirection(3, true)).assertEqual(-3);
      expect(applyRemoteWheelDirection(-6, true)).assertEqual(6);
    });
  });
}
