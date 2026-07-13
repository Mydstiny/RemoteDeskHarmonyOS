/**
 * SshTerminalScrollPolicy.test.ets — SSH 终端手动滚动不应被布局变化拉回底部。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  shouldAutoScrollToBottomAfterViewportChange,
  shouldHonorAutoScrollToBottom,
  terminalDragScrollLines,
  terminalGridTop,
  terminalSparseContentGridTop,
  terminalLogicalViewportHeight,
  terminalRowsBottomOffset,
  terminalTouchDragScrollLines,
  terminalVisualBottomOffset,
  terminalTouchSurfaceOffsetY
} from '../main/ets/services/SshTerminalScrollPolicy';

export default function sshTerminalScrollPolicyTest(): void {
  describe('SshTerminalScrollPolicy', (): void => {
    it('should_ignore_auto_bottom_request_after_user_scrolls_history', 0, (): void => {
      expect(shouldHonorAutoScrollToBottom(false)).assertFalse();
    });

    it('should_honor_auto_bottom_request_while_following_bottom', 0, (): void => {
      expect(shouldHonorAutoScrollToBottom(true)).assertTrue();
    });

    it('should_not_force_bottom_when_viewport_grows_after_user_scrolls_history', 0, (): void => {
      expect(shouldAutoScrollToBottomAfterViewportChange(false, 480, 720)).assertFalse();
    });

    it('should_keep_following_bottom_when_viewport_changes_at_bottom', 0, (): void => {
      expect(shouldAutoScrollToBottomAfterViewportChange(true, 720, 480)).assertTrue();
    });

    it('should_convert_upward_drag_to_history_scroll_lines', 0, (): void => {
      expect(terminalDragScrollLines(132, 100, 16)).assertEqual(-2);
    });

    it('should_convert_downward_drag_to_bottom_scroll_lines', 0, (): void => {
      expect(terminalDragScrollLines(100, 132, 16)).assertEqual(2);
    });

    it('should_map_upward_touch_drag_opposite_to_mouse_wheel_axis', 0, (): void => {
      expect(terminalTouchDragScrollLines(132, 100, 16)).assertEqual(2);
    });

    it('should_map_downward_touch_drag_opposite_to_mouse_wheel_axis', 0, (): void => {
      expect(terminalTouchDragScrollLines(100, 132, 16)).assertEqual(-2);
    });

    it('should_align_touch_surface_with_shifted_mobile_terminal_canvas', 0, (): void => {
      expect(terminalTouchSurfaceOffsetY(false, 280, 52)).assertEqual(-332);
    });

    it('should_keep_touch_surface_unshifted_on_desktop', 0, (): void => {
      expect(terminalTouchSurfaceOffsetY(true, 280, 52)).assertEqual(0);
    });

    it('should_use_unobscured_mobile_text_height_for_terminal_rows', 0, (): void => {
      expect(terminalLogicalViewportHeight(false, 749, 16, 28, 94)).assertEqual(627);
    });

    it('should_keep_desktop_terminal_rows_based_on_full_shell_height', 0, (): void => {
      expect(terminalLogicalViewportHeight(true, 749, 16, 28, 94)).assertEqual(749);
    });

    it('should_keep_pty_rows_stable_when_soft_keyboard_appears', 0, (): void => {
      expect(terminalRowsBottomOffset(false, 300, 28)).assertEqual(28);
    });

    it('should_keep_visual_offset_tracking_soft_keyboard', 0, (): void => {
      expect(terminalVisualBottomOffset(false, 300, 28)).assertEqual(300);
    });

    it('should_top_align_visible_terminal_after_scrollback_exists', 0, (): void => {
      expect(terminalSparseContentGridTop(true, 122, 627, 320, 128, true)).assertEqual(122);
    });

    it('should_bottom_align_sparse_mobile_terminal_before_scrollback_exists', 0, (): void => {
      expect(terminalSparseContentGridTop(true, 122, 627, 48, 128, false)).assertEqual(701);
    });

    it('should_top_align_non_sparse_command_history_before_scrollback_exists', 0, (): void => {
      expect(terminalSparseContentGridTop(true, 122, 627, 320, 128, false)).assertEqual(122);
    });

    it('should_anchor_full_grid_bottom_when_keyboard_reduces_visible_viewport', 0, (): void => {
      expect(terminalGridTop(true, 420, 329, 624, 624, 128, false)).assertEqual(125);
    });
  });
}
