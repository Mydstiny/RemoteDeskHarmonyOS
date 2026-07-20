import { describe, it, expect } from '@ohos/hypium';
import {
  normalizeRemoteCursorStyle,
  shouldRenderArrowCursor,
  shouldRenderCircleCursor
} from '../../../main/ets/services/RemoteCursorStylePolicy';

export default function remoteCursorStylePolicyTest(): void {
  describe('RemoteCursorStylePolicy', (): void => {
    it('defaults_missing_and_unknown_values_to_circle', 0, (): void => {
      expect(normalizeRemoteCursorStyle(undefined)).assertEqual('circle');
      expect(normalizeRemoteCursorStyle('')).assertEqual('circle');
      expect(normalizeRemoteCursorStyle('legacy-arrow')).assertEqual('circle');
    });

    it('accepts_only_the_explicit_official_cursor_value', 0, (): void => {
      expect(normalizeRemoteCursorStyle('arrow')).assertEqual('arrow');
      expect(normalizeRemoteCursorStyle('circle')).assertEqual('circle');
    });

    it('keeps_circle_and_arrow_mutually_exclusive', 0, (): void => {
      expect(shouldRenderArrowCursor('arrow', true, true, true)).assertTrue();
      expect(shouldRenderArrowCursor('circle', true, true, true)).assertFalse();
      expect(shouldRenderCircleCursor('circle', true, true, true)).assertTrue();
      expect(shouldRenderCircleCursor('arrow', true, true, true)).assertFalse();
    });

    it('hides_both_styles_outside_connected_touchpad_mode', 0, (): void => {
      expect(shouldRenderArrowCursor('arrow', false, true, true)).assertFalse();
      expect(shouldRenderArrowCursor('arrow', true, false, true)).assertFalse();
      expect(shouldRenderCircleCursor('circle', true, true, false)).assertFalse();
    });
  });
}
