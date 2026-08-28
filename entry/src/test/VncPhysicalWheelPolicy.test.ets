import { describe, it, expect } from '@ohos/hypium';
import {
  accumulateVncPhysicalTouchpadWheel,
  resetVncPhysicalWheelState,
  resolveVncPhysicalWheelRoute,
  shouldTreatPhysicalAxisAsContinuous,
  VNC_PHYSICAL_MOUSE_MAX_DELTA,
  VNC_PHYSICAL_TOUCHPAD_MAX_DELTA,
  VncPhysicalWheelState,
  vncPhysicalMouseWheelDelta
} from '../main/ets/services/VncPhysicalWheelPolicy';
import { amplifyVncWheelOutputDelta } from '../main/ets/services/RemoteWheelPolicy';

function accumulateTwoSamples(rawDelta: number): number {
  let state: VncPhysicalWheelState = resetVncPhysicalWheelState();
  let totalDelta: number = 0;
  for (let index: number = 0; index < 2; index++) {
    const sample = accumulateVncPhysicalTouchpadWheel(rawDelta, state, 1);
    totalDelta += sample.delta;
    state = sample.state;
  }
  return totalDelta;
}

export default function vncPhysicalWheelPolicyTest(): void {
  describe('VncPhysicalWheelPolicy', (): void => {
    it('uses_mouse_only_scroll_step_before_axis_lifecycle_metadata', 0, (): void => {
      expect(shouldTreatPhysicalAxisAsContinuous(true, 0, 45, 0)).assertFalse();
      expect(shouldTreatPhysicalAxisAsContinuous(false, 2, 45, 0)).assertFalse();
      expect(shouldTreatPhysicalAxisAsContinuous(false, 2, 120, 16)).assertFalse();
      expect(shouldTreatPhysicalAxisAsContinuous(false, 0, 1, 100)).assertFalse();
    });

    it('keeps_ambiguous_mouse_none_events_discrete_without_scroll_step', 0, (): void => {
      expect(shouldTreatPhysicalAxisAsContinuous(false, 0, undefined, 0)).assertFalse();
      expect(shouldTreatPhysicalAxisAsContinuous(false, 0, undefined, 20)).assertFalse();
      expect(vncPhysicalMouseWheelDelta(1)).assertEqual(1);
      expect(vncPhysicalMouseWheelDelta(-1)).assertEqual(-1);
    });

    it('recognizes_touchpad_and_explicit_axis_lifecycle_as_continuous', 0, (): void => {
      expect(shouldTreatPhysicalAxisAsContinuous(false, 2, undefined, 16)).assertTrue();
      expect(shouldTreatPhysicalAxisAsContinuous(true, 2, undefined, 100)).assertTrue();
      expect(shouldTreatPhysicalAxisAsContinuous(true, 0, undefined, 100)).assertTrue();
    });

    it('resolves_begin_end_cancel_lifecycle_without_forwarding_cancel', 0, (): void => {
      const begin = resolveVncPhysicalWheelRoute(false, 1, undefined);
      expect(begin.continuous).assertTrue();
      expect(begin.resetBefore).assertTrue();
      expect(begin.resetAfter).assertFalse();

      const end = resolveVncPhysicalWheelRoute(false, 3, undefined);
      expect(end.continuous).assertTrue();
      expect(end.resetAfter).assertTrue();
      expect(end.cancel).assertFalse();

      const cancel = resolveVncPhysicalWheelRoute(false, 4, undefined);
      expect(cancel.continuous).assertTrue();
      expect(cancel.resetAfter).assertTrue();
      expect(cancel.cancel).assertTrue();

      const mouse = resolveVncPhysicalWheelRoute(false, 2, 1);
      expect(mouse.continuous).assertFalse();
      expect(mouse.resetBefore).assertFalse();
      expect(mouse.resetAfter).assertFalse();
    });

    it('preserves_captured_mouse_scroll_step_without_multiplying_raw_degrees', 0, (): void => {
      expect(vncPhysicalMouseWheelDelta(45, 3)).assertEqual(3);
      expect(vncPhysicalMouseWheelDelta(-45, 3)).assertEqual(-3);
      expect(vncPhysicalMouseWheelDelta(120, 1)).assertEqual(1);
      expect(vncPhysicalMouseWheelDelta(1, undefined)).assertEqual(1);
      expect(vncPhysicalMouseWheelDelta(-1, Number.NaN)).assertEqual(-1);
      expect(vncPhysicalMouseWheelDelta(120, 100))
        .assertEqual(VNC_PHYSICAL_MOUSE_MAX_DELTA);
    });

    it('applies_the_same_ten_times_wire_gain_to_mouse_and_touchpad', 0, (): void => {
      expect(amplifyVncWheelOutputDelta(vncPhysicalMouseWheelDelta(45, 3)))
        .assertEqual(30);
      expect(amplifyVncWheelOutputDelta(accumulateTwoSamples(45)))
        .assertEqual(10);
    });

    it('adapts_touchpad_1_45_and_120_units_to_two_samples_per_tick', 0, (): void => {
      expect(accumulateTwoSamples(1)).assertEqual(1);
      expect(accumulateTwoSamples(45)).assertEqual(1);
      expect(accumulateTwoSamples(120)).assertEqual(1);
      expect(accumulateTwoSamples(-45)).assertEqual(-1);
    });

    it('rebases_large_first_samples_before_fine_motion_can_starve', 0, (): void => {
      let state: VncPhysicalWheelState = resetVncPhysicalWheelState();
      const large = accumulateVncPhysicalTouchpadWheel(120, state, 1);
      state = large.state;
      const fineOne = accumulateVncPhysicalTouchpadWheel(1, state, 1);
      expect(fineOne.delta).assertEqual(1);
      expect(fineOne.state.axisUnit).assertEqual(1);

      const medium = accumulateVncPhysicalTouchpadWheel(45,
        resetVncPhysicalWheelState(), 1);
      const mediumFine = accumulateVncPhysicalTouchpadWheel(1, medium.state, 1);
      expect(mediumFine.delta).assertEqual(1);
      expect(mediumFine.state.remainder).assertEqual(0);

      const small = accumulateVncPhysicalTouchpadWheel(1,
        resetVncPhysicalWheelState(), 1);
      const accelerated = accumulateVncPhysicalTouchpadWheel(45, small.state, 1);
      expect(accelerated.delta).assertEqual(2);
      expect(accelerated.state.remainder).assertEqual(0.5);
    });

    it('clears_stale_fraction_on_direction_change_and_caps_fast_samples', 0, (): void => {
      let state: VncPhysicalWheelState = resetVncPhysicalWheelState();
      const first = accumulateVncPhysicalTouchpadWheel(45, state, 1);
      state = first.state;
      const second = accumulateVncPhysicalTouchpadWheel(45, state, 1);
      state = second.state;
      expect(second.delta).assertEqual(1);
      expect(second.state.remainder).assertEqual(0);

      const reversed = accumulateVncPhysicalTouchpadWheel(-45, state, 1);
      expect(reversed.delta).assertEqual(0);
      expect(reversed.state.remainder).assertEqual(-0.5);

      const fast = accumulateVncPhysicalTouchpadWheel(1000,
        resetVncPhysicalWheelState(), 10);
      expect(fast.delta).assertEqual(VNC_PHYSICAL_TOUCHPAD_MAX_DELTA);
      expect(fast.state.remainder).assertEqual(0);
    });

    it('does_not_leak_fraction_across_idle_gaps_or_input_sources', 0, (): void => {
      let state: VncPhysicalWheelState = resetVncPhysicalWheelState();
      const first = accumulateVncPhysicalTouchpadWheel(45, state, 1, 100, 1);
      expect(first.state.remainder).assertEqual(0.5);
      const afterIdle = accumulateVncPhysicalTouchpadWheel(45, first.state, 1, 400, 1);
      expect(afterIdle.delta).assertEqual(0);
      expect(afterIdle.state.remainder).assertEqual(0.5);

      const afterSourceChange = accumulateVncPhysicalTouchpadWheel(
        45, first.state, 1, 120, 2);
      expect(afterSourceChange.delta).assertEqual(0);
      expect(afterSourceChange.state.remainder).assertEqual(0.5);
    });
  });
}
