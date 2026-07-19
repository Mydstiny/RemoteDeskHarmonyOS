import { describe, it, expect } from '@ohos/hypium';
import {
  normalizeRemoteCursorStyle,
  remoteCursorSnapshotChanged,
  shouldRenderArrowCursor,
  shouldRenderCircleCursor,
  shouldRenderVirtualTouchpadCursor
} from '../main/ets/services/RemoteCursorStylePolicy';

export default function remoteCursorStylePolicyTest() {
  describe('RemoteCursorStylePolicy', (): void => {
    it('normalizes only arrow and falls back to circle', 0, (): void => {
      expect(normalizeRemoteCursorStyle('arrow')).assertEqual('arrow');
      expect(normalizeRemoteCursorStyle('circle')).assertEqual('circle');
      expect(normalizeRemoteCursorStyle('bad')).assertEqual('arrow');
      expect(normalizeRemoteCursorStyle(undefined)).assertEqual('arrow');
    });
    it('renders virtual cursors only for ready touchpad sessions', 0, (): void => {
      expect(shouldRenderVirtualTouchpadCursor(true, true, true)).assertTrue();
      expect(shouldRenderVirtualTouchpadCursor(true, false, true)).assertFalse();
      expect(shouldRenderArrowCursor('arrow', true, true, true)).assertTrue();
      expect(shouldRenderArrowCursor('circle', true, true, true)).assertFalse();
      expect(shouldRenderCircleCursor('circle', true, true, true)).assertTrue();
      expect(shouldRenderCircleCursor('circle', false, true, true)).assertFalse();
      expect(shouldRenderCircleCursor('arrow', true, true, true)).assertFalse();
    });
    it('invalidates the cursor view only when its rendered snapshot changes', 0, (): void => {
      expect(remoteCursorSnapshotChanged(100, 200, true, 101, 200, true)).assertTrue();
      expect(remoteCursorSnapshotChanged(100, 200, false, 100, 200, true)).assertTrue();
      expect(remoteCursorSnapshotChanged(100, 200, true, 100, 200, true)).assertFalse();
    });
  });
}
