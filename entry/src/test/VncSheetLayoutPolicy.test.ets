import { describe, it, expect } from '@ohos/hypium';
import {
  hasUsableVncSheetBody,
  resolveVncSheetLayout,
  VNC_SHEET_DENSITY_ACTION_ONLY,
  VNC_SHEET_DENSITY_COMPACT,
  VNC_SHEET_DENSITY_REGULAR
} from '../main/ets/services/VncSheetLayoutPolicy';

export default function vncSheetLayoutPolicyTest(): void {
  describe('VncSheetLayoutPolicy', (): void => {
    it('keeps_footer_reachable_with_phone_safe_area', 0, (): void => {
      const layout = resolveVncSheetLayout(720, 0, 24);
      expect(layout.footerReachable).assertTrue();
      expect(layout.bodyHeight).assertEqual(524);
      expect(layout.density).assertEqual(VNC_SHEET_DENSITY_REGULAR);
      expect(hasUsableVncSheetBody(layout)).assertTrue();
    });

    it('keeps_footer_fixed_when_keyboard_reduces_body', 0, (): void => {
      const layout = resolveVncSheetLayout(720, 300, 24);
      expect(layout.footerReachable).assertTrue();
      expect(layout.bodyHeight).assertEqual(224);
      expect(layout.density).assertEqual(VNC_SHEET_DENSITY_REGULAR);
      expect(hasUsableVncSheetBody(layout)).assertTrue();
    });

    it('compacts_header_and_footer_to_keep_action_reachable', 0, (): void => {
      const layout = resolveVncSheetLayout(360, 180, 24);
      expect(layout.footerReachable).assertTrue();
      expect(layout.bodyHeight).assertEqual(40);
      expect(layout.density).assertEqual(VNC_SHEET_DENSITY_COMPACT);
      expect(hasUsableVncSheetBody(layout)).assertFalse();
    });

    it('prioritizes_footer_when_only_the_primary_action_fits', 0, (): void => {
      const layout = resolveVncSheetLayout(140, 40, 24);
      expect(layout.footerReachable).assertTrue();
      expect(layout.bodyHeight).assertEqual(12);
      expect(layout.density).assertEqual(VNC_SHEET_DENSITY_ACTION_ONLY);
      expect(hasUsableVncSheetBody(layout)).assertFalse();
    });
  });
}
