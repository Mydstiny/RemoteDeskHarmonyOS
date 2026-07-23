import { describe, it, expect } from '@ohos/hypium';
import {
  normalizeRemoteCursorStyle,
  REMOTE_CURSOR_FALLBACK_EDGE_VP,
  REMOTE_CURSOR_MAX_EDGE_VP,
  REMOTE_CURSOR_MIN_EDGE_VP,
  resolveRemoteCursorVisualScale,
  shouldRenderArrowCursor,
  shouldRenderCircleCursor,
  shouldRenderRemoteCursorArrow,
  shouldRenderRemoteCursorFallbackIndicator,
  shouldRefreshRemoteCursorBitmap,
  shouldApplyCloudVirtualMouseStyle,
  VIRTUAL_MOUSE_STYLE_RESTORE_VERSION,
  resolveRemoteCursorRenderMode
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

    it('prefers_the_authoritative_arrow_when_observed_flags_overlap', 0, (): void => {
      expect(resolveRemoteCursorRenderMode(false, false)).assertEqual('none');
      expect(resolveRemoteCursorRenderMode(true, false)).assertEqual('circle');
      expect(resolveRemoteCursorRenderMode(false, true)).assertEqual('arrow');
      expect(resolveRemoteCursorRenderMode(true, true)).assertEqual('arrow');
    });

    it('hides_both_styles_outside_connected_touchpad_mode', 0, (): void => {
      expect(shouldRenderArrowCursor('arrow', false, true, true)).assertFalse();
      expect(shouldRenderArrowCursor('arrow', true, false, true)).assertFalse();
      expect(shouldRenderCircleCursor('circle', true, true, false)).assertFalse();
    });

    it('uses_a_circle_placeholder_for_a_non_authoritative_cursor_shape', 0, (): void => {
      expect(shouldRenderRemoteCursorFallbackIndicator(true, true, true, true)).assertTrue();
      expect(shouldRenderRemoteCursorFallbackIndicator(false, true, true, true)).assertFalse();
      expect(shouldRenderRemoteCursorFallbackIndicator(true, false, true, true)).assertFalse();
      expect(shouldRenderRemoteCursorFallbackIndicator(true, true, false, true)).assertFalse();
      expect(shouldRenderRemoteCursorFallbackIndicator(true, true, true, false)).assertFalse();
    });

    it('never_renders_the_fallback_bitmap_as_an_authoritative_arrow', 0, (): void => {
      expect(shouldRenderRemoteCursorArrow('arrow', true, true, true, true, true, false)).assertTrue();
      expect(shouldRenderRemoteCursorArrow('arrow', true, true, true, true, true, true)).assertFalse();
      expect(shouldRenderRemoteCursorArrow('circle', true, true, true, true, true, false)).assertFalse();
    });

    it('gates_cloud_style_until_local_restore_is_complete', 0, (): void => {
      expect(shouldApplyCloudVirtualMouseStyle(0)).assertFalse();
      expect(shouldApplyCloudVirtualMouseStyle(VIRTUAL_MOUSE_STYLE_RESTORE_VERSION - 1)).assertFalse();
      expect(shouldApplyCloudVirtualMouseStyle(VIRTUAL_MOUSE_STYLE_RESTORE_VERSION)).assertTrue();
      expect(shouldApplyCloudVirtualMouseStyle(NaN)).assertFalse();
    });

    it('retries_missing_cursor_bitmaps_without_replacing_current_maps', 0, (): void => {
      expect(shouldRefreshRemoteCursorBitmap(1, false, true, 0, 1000, 30000)).assertTrue();
      expect(shouldRefreshRemoteCursorBitmap(1, false, true, 1000, 1500, 30000)).assertFalse();
      expect(shouldRefreshRemoteCursorBitmap(1, false, true, 1000, 2000, 30000)).assertTrue();
      expect(shouldRefreshRemoteCursorBitmap(1, true, true, 1000, 31000, 30000)).assertFalse();
      expect(shouldRefreshRemoteCursorBitmap(1, true, true, 1000, 30999, 30000)).assertFalse();
      expect(shouldRefreshRemoteCursorBitmap(1, true, false, 1000, 60000, 30000)).assertFalse();
      expect(shouldRefreshRemoteCursorBitmap(0, false, true, 0, 60000, 30000)).assertFalse();
    });

    it('bounds_fallback_and_protocol_cursor_edges', 0, (): void => {
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
