import { describe, it, expect } from '@ohos/hypium';
import {
  normalizeRemoteCursorStyle,
  remoteCursorSnapshotChanged,
  shouldRenderArrowCursor,
  shouldRenderCircleCursor,
  shouldRefreshRemoteCursorBitmap,
  shouldRenderVirtualTouchpadCursor
} from '../main/ets/services/RemoteCursorStylePolicy';

export default function remoteCursorStylePolicyTest() {
  describe('RemoteCursorStylePolicy', (): void => {
    it('normalizes only arrow and falls back to circle', 0, (): void => {
      expect(normalizeRemoteCursorStyle('arrow')).assertEqual('arrow');
      expect(normalizeRemoteCursorStyle('circle')).assertEqual('circle');
      expect(normalizeRemoteCursorStyle('bad')).assertEqual('circle');
      expect(normalizeRemoteCursorStyle(undefined)).assertEqual('circle');
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
    it('refreshes missing or stale cursor bitmaps without refreshing hidden cursors', 0, (): void => {
      expect(shouldRefreshRemoteCursorBitmap(1, false, true, 0, 1000, 30000)).assertTrue();
      expect(shouldRefreshRemoteCursorBitmap(1, false, true, 1000, 1500, 30000)).assertFalse();
      expect(shouldRefreshRemoteCursorBitmap(1, false, true, 1000, 2000, 30000)).assertTrue();
      expect(shouldRefreshRemoteCursorBitmap(1, true, true, 1000, 31000, 30000)).assertTrue();
      expect(shouldRefreshRemoteCursorBitmap(1, true, true, 1000, 30999, 30000)).assertFalse();
      expect(shouldRefreshRemoteCursorBitmap(1, true, false, 1000, 60000, 30000)).assertFalse();
      expect(shouldRefreshRemoteCursorBitmap(0, false, true, 0, 60000, 30000)).assertFalse();
    });
  });
}
