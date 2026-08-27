import { describe, it, expect } from '@ohos/hypium';
import {
  accumulateVncPhysicalTouchpadWheel,
  resetVncPhysicalWheelState,
  shouldTreatPhysicalAxisAsContinuous,
  VncPhysicalWheelState,
  vncPhysicalMouseWheelDelta
} from '../main/ets/services/VncPhysicalWheelPolicy';

function accumulateFourSamples(rawDelta: number): number {
  let state: VncPhysicalWheelState = resetVncPhysicalWheelState();
  let totalDelta: number = 0;
  for (let index: number = 0; index < 4; index++) {
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

    it('recognizes_touchpad_samples_even_when_pc_bridge_labels_them_mouse', 0, (): void => {
      expect(shouldTreatPhysicalAxisAsContinuous(false, 0, undefined, 0)).assertTrue();
      expect(shouldTreatPhysicalAxisAsContinuous(false, 2, undefined, 16)).assertTrue();
      expect(shouldTreatPhysicalAxisAsContinuous(true, 2, undefined, 100)).assertTrue();
    });

    it('normalizes_every_physical_mouse_vendor_unit_to_one_detent', 0, (): void => {
      expect(vncPhysicalMouseWheelDelta(1)).assertEqual(1);
      expect(vncPhysicalMouseWheelDelta(45)).assertEqual(1);
      expect(vncPhysicalMouseWheelDelta(120)).assertEqual(1);
      expect(vncPhysicalMouseWheelDelta(-1)).assertEqual(-1);
      expect(vncPhysicalMouseWheelDelta(-120)).assertEqual(-1);
    });

    it('adapts_touchpad_1_45_and_120_units_to_the_same_scroll_rate', 0, (): void => {
      expect(accumulateFourSamples(1)).assertEqual(1);
      expect(accumulateFourSamples(45)).assertEqual(1);
      expect(accumulateFourSamples(120)).assertEqual(1);
      expect(accumulateFourSamples(-45)).assertEqual(-1);
    });

    it('clears_stale_fraction_on_direction_change_and_caps_fast_samples', 0, (): void => {
      let state: VncPhysicalWheelState = resetVncPhysicalWheelState();
      const first = accumulateVncPhysicalTouchpadWheel(45, state, 1);
      state = first.state;
      const second = accumulateVncPhysicalTouchpadWheel(45, state, 1);
      state = second.state;
      expect(second.delta).assertEqual(0);
      expect(second.state.remainder).assertEqual(0.5);

      const reversed = accumulateVncPhysicalTouchpadWheel(-45, state, 1);
      expect(reversed.delta).assertEqual(0);
      expect(reversed.state.remainder).assertEqual(-0.25);

      const fast = accumulateVncPhysicalTouchpadWheel(1000,
        resetVncPhysicalWheelState(), 10);
      expect(fast.delta).assertEqual(2);
      expect(fast.state.remainder).assertEqual(0.5);
    });

    it('does_not_leak_fraction_across_idle_gaps_or_input_sources', 0, (): void => {
      let state: VncPhysicalWheelState = resetVncPhysicalWheelState();
      const first = accumulateVncPhysicalTouchpadWheel(45, state, 1, 100, 1);
      state = first.state;
      const second = accumulateVncPhysicalTouchpadWheel(45, state, 1, 110, 1);
      expect(second.state.remainder).assertEqual(0.5);

      const afterIdle = accumulateVncPhysicalTouchpadWheel(45, second.state, 1, 400, 1);
      expect(afterIdle.delta).assertEqual(0);
      expect(afterIdle.state.remainder).assertEqual(0.25);

      const afterSourceChange = accumulateVncPhysicalTouchpadWheel(
        45, second.state, 1, 120, 2);
      expect(afterSourceChange.delta).assertEqual(0);
      expect(afterSourceChange.state.remainder).assertEqual(0.25);
    });
  });
}
