import { describe, it, expect } from '@ohos/hypium';
import {
  RdpMultimonLayout,
  nextRdpMonitorFocus,
  normalizeRdpMultimonCount,
  rdpMonitorRects,
  rdpMultimonLayout
} from '../main/ets/services/RdpMultiMonitorPolicy';

export default function rdpMultiMonitorPolicyTest() {
  describe('RdpMultiMonitorPolicy', () => {
    it('declares_side_by_side_and_downgrades', 0, () => {
      const two: RdpMultimonLayout = rdpMultimonLayout(2, 2560, 1440);
      expect(two.desktopWidth).assertEqual(5120);
      expect(two.downgraded).assertFalse();
      const four: RdpMultimonLayout = rdpMultimonLayout(4, 2560, 1440);
      expect(four.monitorWidth).assertEqual(1920);
      expect(four.downgraded).assertTrue();
      expect(rdpMonitorRects(two)[1].x).assertEqual(2560);
      expect(normalizeRdpMultimonCount(1)).assertEqual(0);
      expect(nextRdpMonitorFocus(1, 2)).assertEqual(-1);
    });
  });
}
