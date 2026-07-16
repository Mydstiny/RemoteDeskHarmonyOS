import { describe, it, expect } from '@ohos/hypium';
import { normalizeBreakpoint } from '../main/ets/utils/BreakpointUtil';

export default function breakpointUtilTest(): void {
  describe('BreakpointUtil', (): void => {
    it('keeps_width_breakpoints_for_non_foldable_devices', 0, (): void => {
      expect(normalizeBreakpoint(360, false, false)).assertEqual('sm');
      expect(normalizeBreakpoint(720, false, false)).assertEqual('md');
      expect(normalizeBreakpoint(1024, false, false)).assertEqual('lg');
      expect(normalizeBreakpoint(1600, false, false)).assertEqual('xl');
    });
    it('uses_phone_layout_when_foldable_is_folded', 0, (): void => {
      expect(normalizeBreakpoint(1024, true, true)).assertEqual('sm');
    });
    it('uses_pad_layout_when_foldable_is_expanded', 0, (): void => {
      expect(normalizeBreakpoint(720, true, false)).assertEqual('md');
      expect(normalizeBreakpoint(1024, true, false)).assertEqual('lg');
      expect(normalizeBreakpoint(1600, true, false)).assertEqual('lg');
    });
  });
}
