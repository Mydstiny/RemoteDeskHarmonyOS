import { describe, it, expect } from '@ohos/hypium';
import {
  MOONLIGHT_HIGH_RES_WHEEL_DETENT,
  VNC_VIRTUAL_WHEEL_MAX_DELTA,
  accumulateContinuousRemoteWheel,
  applyRemoteWheelDirection,
  discreteRemoteWheelDelta,
  moonlightAxisScrollAmount,
  shouldForwardContinuousRemoteWheelSample
} from '../main/ets/services/RemoteWheelPolicy';

export default function remoteWheelPolicyTest(): void {
  describe('RemoteWheelPolicy', (): void => {
    it('accumulates_captured_virtual_vnc_motion_without_forcing_each_frame', 0, (): void => {
      const first = accumulateContinuousRemoteWheel(2, 0, 1, 'vnc');
      expect(first.delta).assertEqual(0);
      expect(first.remainder).assertEqual(0.5);
      const second = accumulateContinuousRemoteWheel(2, first.remainder, 1, 'vnc');
      expect(second.delta).assertEqual(1);
      expect(second.remainder).assertEqual(0);
    });

    it('bounds_fast_virtual_vnc_samples_without_retaining_backlog', 0, (): void => {
      const fast = accumulateContinuousRemoteWheel(40, 0, 1, 'vnc');
      expect(fast.delta).assertEqual(VNC_VIRTUAL_WHEEL_MAX_DELTA);
      expect(fast.remainder).assertEqual(0);
    });

    it('clears_virtual_vnc_fraction_when_direction_changes', 0, (): void => {
      const forward = accumulateContinuousRemoteWheel(2, 0, 1, 'vnc');
      const reversed = accumulateContinuousRemoteWheel(-2, forward.remainder, 1, 'vnc');
      expect(reversed.delta).assertEqual(0);
      expect(reversed.remainder).assertEqual(-0.5);
    });

    it('preserves_sub_half_vp_samples_until_they_form_a_vnc_tick', 0, (): void => {
      expect(shouldForwardContinuousRemoteWheelSample(0.4)).assertTrue();
      expect(shouldForwardContinuousRemoteWheelSample(-0.1)).assertTrue();
      expect(shouldForwardContinuousRemoteWheelSample(0)).assertFalse();
      expect(shouldForwardContinuousRemoteWheelSample(Number.NaN)).assertFalse();

      let remainder: number = 0;
      let totalDelta: number = 0;
      for (let index: number = 0; index < 16; index++) {
        const sample = accumulateContinuousRemoteWheel(0.25, remainder, 1, 'vnc');
        totalDelta += sample.delta;
        remainder = sample.remainder;
      }
      expect(totalDelta).assertEqual(1);
    });

    it('preserves_virtual_vnc_speed_multiplier_with_a_bounded_output', 0, (): void => {
      const normal = accumulateContinuousRemoteWheel(8, 0, 1, 'vnc');
      expect(normal.delta).assertEqual(2);
      const accelerated = accumulateContinuousRemoteWheel(8, 0, 2, 'vnc');
      expect(accelerated.delta).assertEqual(VNC_VIRTUAL_WHEEL_MAX_DELTA);
      expect(accelerated.remainder).assertEqual(0);
    });

    it('keeps_non_vnc_continuous_scroll_curve_compatible', 0, (): void => {
      const result = accumulateContinuousRemoteWheel(25, 0, 1, 'rustdesk');
      expect(result.delta).assertEqual(2);
      expect(result.remainder).assertEqual(0);
    });

    it('maps_every_discrete_vendor_unit_to_one_protocol_detent', 0, (): void => {
      expect(discreteRemoteWheelDelta(1, 'vnc')).assertEqual(1);
      expect(discreteRemoteWheelDelta(45, 'vnc', 20)).assertEqual(1);
      expect(discreteRemoteWheelDelta(120, 'vnc', 70)).assertEqual(1);
      expect(discreteRemoteWheelDelta(-120, 'vnc')).assertEqual(-1);
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

    it('applies_the_shared_personalization_direction_last', 0, (): void => {
      expect(applyRemoteWheelDirection(3, false)).assertEqual(3);
      expect(applyRemoteWheelDirection(3, true)).assertEqual(-3);
      expect(applyRemoteWheelDirection(-6, true)).assertEqual(6);
    });
  });
}
