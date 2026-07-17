import { describe, it, expect } from '@ohos/hypium';
import {
  normalizeRemoteCursorStyle,
  shouldRenderArrowCursor,
  shouldRenderCircleCursor,
  shouldRenderVirtualTouchpadCursor
} from '../main/ets/services/RemoteCursorStylePolicy';

export default function remoteCursorStylePolicyTest() {
  describe('RemoteCursorStylePolicy', (): void => {
    it('normalizes only arrow and falls back to circle', 0, (): void => {
      expect(normalizeRemoteCursorStyle('arrow')).assertEqual('arrow');
      expect(normalizeRemoteCursorStyle('bad')).assertEqual('circle');
      expect(normalizeRemoteCursorStyle(undefined)).assertEqual('circle');
    });
    it('renders virtual cursors only for ready touchpad sessions', 0, (): void => {
      expect(shouldRenderVirtualTouchpadCursor(true, true, true)).assertTrue();
      expect(shouldRenderVirtualTouchpadCursor(true, false, true)).assertFalse();
      expect(shouldRenderArrowCursor('arrow', true, true, true)).assertTrue();
      expect(shouldRenderArrowCursor('circle', true, true, true)).assertFalse();
      expect(shouldRenderCircleCursor('circle', true, true, true)).assertTrue();
      expect(shouldRenderCircleCursor('arrow', true, true, true)).assertFalse();
    });
  });
}
