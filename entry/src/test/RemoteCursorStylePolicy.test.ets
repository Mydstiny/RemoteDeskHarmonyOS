import { describe, it, expect } from '@ohos/hypium';
import {
  normalizeRemoteCursorStyle,
  REMOTE_CURSOR_FALLBACK_EDGE_VP,
  REMOTE_CURSOR_MAX_EDGE_VP,
  REMOTE_CURSOR_MIN_EDGE_VP,
  remoteCursorSnapshotChanged,
  resolveRemoteCursorVisualScale,
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
    it('retries only missing cursor bitmaps and never replaces a current map on a timer', 0, (): void => {
      expect(shouldRefreshRemoteCursorBitmap(1, false, true, 0, 1000, 30000)).assertTrue();
      expect(shouldRefreshRemoteCursorBitmap(1, false, true, 1000, 1500, 30000)).assertFalse();
      expect(shouldRefreshRemoteCursorBitmap(1, false, true, 1000, 2000, 30000)).assertTrue();
      expect(shouldRefreshRemoteCursorBitmap(1, true, true, 1000, 31000, 30000)).assertFalse();
      expect(shouldRefreshRemoteCursorBitmap(1, true, true, 1000, 30999, 30000)).assertFalse();
      expect(shouldRefreshRemoteCursorBitmap(1, true, false, 1000, 60000, 30000)).assertFalse();
      expect(shouldRefreshRemoteCursorBitmap(0, false, true, 0, 60000, 30000)).assertFalse();
    });
    it('keeps fallback and protocol cursor sizes bounded without changing aspect ratio', 0, (): void => {
      expect(resolveRemoteCursorVisualScale(16, 16, 100, true)).assertEqual(
        REMOTE_CURSOR_FALLBACK_EDGE_VP / 16);
      expect(resolveRemoteCursorVisualScale(16, 16, 0.1, false)).assertEqual(
        REMOTE_CURSOR_MIN_EDGE_VP / 16);
      expect(resolveRemoteCursorVisualScale(16, 16, 100, false)).assertEqual(
        REMOTE_CURSOR_MAX_EDGE_VP / 16);
      expect(resolveRemoteCursorVisualScale(384, 16, 1, false)).assertEqual(
        REMOTE_CURSOR_MAX_EDGE_VP / 384);
    });
  });
}
