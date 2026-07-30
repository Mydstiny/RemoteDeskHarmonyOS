import { describe, it, expect } from '@ohos/hypium';
import {
  hasUsableVncSheetBody,
  resolveVncSheetLayout
} from '../main/ets/services/VncSheetLayoutPolicy';

export default function vncSheetLayoutPolicyTest(): void {
  describe('VncSheetLayoutPolicy', (): void => {
    it('keeps_footer_reachable_with_phone_safe_area', 0, (): void => {
      const layout = resolveVncSheetLayout(720, 0, 24);
      expect(layout.footerReachable).assertTrue();
      expect(layout.bodyHeight).assertEqual(524);
      expect(hasUsableVncSheetBody(layout)).assertTrue();
    });

    it('keeps_footer_fixed_when_keyboard_reduces_body', 0, (): void => {
      const layout = resolveVncSheetLayout(720, 300, 24);
      expect(layout.footerReachable).assertTrue();
      expect(layout.bodyHeight).assertEqual(224);
      expect(hasUsableVncSheetBody(layout)).assertTrue();
    });

    it('reports_unusable_body_in_extreme_viewport', 0, (): void => {
      const layout = resolveVncSheetLayout(360, 180, 24);
      expect(layout.footerReachable).assertFalse();
      expect(hasUsableVncSheetBody(layout)).assertFalse();
    });
  });
}
