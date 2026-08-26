import { describe, it, expect } from '@ohos/hypium';
import {
  accumulateVncPhysicalTouchpadWheel,
  shouldTreatPhysicalAxisAsContinuous
} from '../main/ets/services/VncPhysicalWheelPolicy';

export default function vncPhysicalWheelPolicyTest(): void {
  describe('VncPhysicalWheelPolicy', (): void => {
    it('recognizes_touchpad_axis_samples_exposed_as_mouse_input', 0, (): void => {
      expect(shouldTreatPhysicalAxisAsContinuous(true, 0, 45, 0)).assertTrue();
      expect(shouldTreatPhysicalAxisAsContinuous(false, 2, 45, 0)).assertTrue();
      expect(shouldTreatPhysicalAxisAsContinuous(false, 0, undefined, 0)).assertTrue();
      expect(shouldTreatPhysicalAxisAsContinuous(false, 0, 45, 16)).assertTrue();
      expect(shouldTreatPhysicalAxisAsContinuous(false, 0, 45, 100)).assertFalse();
    });

    it('converts_axis_units_without_rfb_burst_amplification', 0, (): void => {
      const first = accumulateVncPhysicalTouchpadWheel(-45, 0, 1);
      expect(first.delta).assertEqual(-1);
      expect(first.remainder).assertEqual(0);
      const fine = accumulateVncPhysicalTouchpadWheel(22.5, 0, 1);
      expect(fine.delta).assertEqual(0);
      expect(fine.remainder).assertEqual(0.5);
      const completed = accumulateVncPhysicalTouchpadWheel(22.5, fine.remainder, 1);
      expect(completed.delta).assertEqual(1);
      expect(completed.remainder).assertEqual(0);
    });
  });
}
