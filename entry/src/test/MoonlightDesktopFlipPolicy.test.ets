import { expect } from '@ohos/hypium';
import { auditedDescribe as describe, auditedIt as it } from
  '../main/ets/services/FocusedTestRegistrationAudit';
import {
  effectiveMoonlightDesktopFlipMode,
  mirrorMoonlightDesktopInput,
  moonlightDesktopFlipState,
  normalizeMoonlightDesktopFlipMode,
  projectMoonlightDesktopRelativeInput,
  reprojectMoonlightDesktopFlipPan,
  toggleMoonlightDesktopFlipAxis
} from '../main/ets/services/MoonlightDesktopFlipPolicy';

export default function moonlightDesktopFlipPolicyTest(): void {
  describe('MoonlightDesktopFlipPolicy', (): void => {
    it('normalizes_and_scopes_the_fallback_to_pc_sessions', 0, (): void => {
      expect(normalizeMoonlightDesktopFlipMode('axes_15')).assertEqual('axes_15');
      expect(normalizeMoonlightDesktopFlipMode('axes_0')).assertEqual('reset');
      expect(normalizeMoonlightDesktopFlipMode('axes_16')).assertEqual('reset');
      expect(effectiveMoonlightDesktopFlipMode('axes_3', true, '')).assertEqual('axes_3');
      expect(effectiveMoonlightDesktopFlipMode('axes_3', false, 'window-1')).assertEqual('axes_3');
      expect(effectiveMoonlightDesktopFlipMode('axes_3', false, '')).assertEqual('reset');
    });

    it('toggles_all_visual_and_control_axes_independently', 0, (): void => {
      let mode: string = toggleMoonlightDesktopFlipAxis('reset', 'visual_y');
      mode = toggleMoonlightDesktopFlipAxis(mode, 'visual_x');
      mode = toggleMoonlightDesktopFlipAxis(mode, 'control_y');
      mode = toggleMoonlightDesktopFlipAxis(mode, 'control_x');
      expect(mode).assertEqual('axes_15');
      const state = moonlightDesktopFlipState(mode);
      expect(state.visualFlipX).assertTrue();
      expect(state.visualFlipY).assertTrue();
      expect(state.controlFlipX).assertTrue();
      expect(state.controlFlipY).assertTrue();
    });

    it('mirrors_absolute_input_inside_the_published_content_viewport', 0,
      (): void => {
        const point = mirrorMoonlightDesktopInput(30, 45, 10, 20, 100, 80, true, true);
        expect(point.x).assertEqual(90);
        expect(point.y).assertEqual(75);
        const unchanged = mirrorMoonlightDesktopInput(30, 45, 10, 20, 100, 80, false, false);
        expect(unchanged.x).assertEqual(30);
        expect(unchanged.y).assertEqual(45);
      });

    it('reprojects_only_pan_axes_affected_by_visual_flip_changes', 0, (): void => {
      const vertical = reprojectMoonlightDesktopFlipPan('reset', 'axes_1', 18, -9);
      expect(vertical.panX).assertEqual(18);
      expect(vertical.panY).assertEqual(9);
      const horizontal = reprojectMoonlightDesktopFlipPan('axes_1', 'axes_3', 18, 9);
      expect(horizontal.panX).assertEqual(-18);
      expect(horizontal.panY).assertEqual(9);
    });

    it('keeps_trackpad_wire_and_visible_cursor_deltas_in_the_same_space', 0,
      (): void => {
        const normal = projectMoonlightDesktopRelativeInput(
          4, -3, 2, false, false, false, false);
        expect(normal.wireX).assertEqual(8);
        expect(normal.wireY).assertEqual(-6);
        expect(normal.visualX).assertEqual(8);
        expect(normal.visualY).assertEqual(-6);
        const visualOnly = projectMoonlightDesktopRelativeInput(
          4, -3, 2, false, false, true, true);
        expect(visualOnly.wireX).assertEqual(8);
        expect(visualOnly.wireY).assertEqual(-6);
        expect(visualOnly.visualX).assertEqual(-8);
        expect(visualOnly.visualY).assertEqual(6);
        const controlOnly = projectMoonlightDesktopRelativeInput(
          4, -3, 2, true, true, false, false);
        expect(controlOnly.wireX).assertEqual(-8);
        expect(controlOnly.wireY).assertEqual(6);
        expect(controlOnly.visualX).assertEqual(-8);
        expect(controlOnly.visualY).assertEqual(6);
        const matched = projectMoonlightDesktopRelativeInput(
          4, -3, 2, true, true, true, true);
        expect(matched.wireX).assertEqual(-8);
        expect(matched.wireY).assertEqual(6);
        expect(matched.visualX).assertEqual(8);
        expect(matched.visualY).assertEqual(-6);
      });
  });
}
