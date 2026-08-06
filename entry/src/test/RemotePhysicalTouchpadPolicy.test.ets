import { describe, it, expect } from '@ohos/hypium';
import {
  accumulatePhysicalTouchpadPinch,
  accumulateRustDeskPhysicalTouchpadWheel,
  physicalTouchpadZoomKeyCode,
  physicalTouchpadZoomModifierKeyCode,
  resetPhysicalTouchpadPinchState,
  resetPhysicalTouchpadWheelState,
  RUSTDESK_TOUCHPAD_ZOOM_EQUALS_KEYCODE,
  RUSTDESK_TOUCHPAD_ZOOM_MINUS_KEYCODE,
  shouldUseRustDeskPhysicalTouchpad
} from '../main/ets/services/RemotePhysicalTouchpadPolicy';
import {
  HARMONY_KEYCODE_CTRL_LEFT,
  HARMONY_KEYCODE_META_LEFT,
  RemoteKeyboardLayout
} from '../main/ets/services/RemotePhysicalKeyboardPolicy';

export default function remotePhysicalTouchpadPolicyTest(): void {
  describe('RemotePhysicalTouchpadPolicy', (): void => {
    it('limits_the_axis_path_to_rustdesk_desktop_pc_mode_and_real_touchpad', 0, (): void => {
      expect(shouldUseRustDeskPhysicalTouchpad('rustdesk', true, 2, true)).assertTrue();
      expect(shouldUseRustDeskPhysicalTouchpad('rustdesk', false, 2, true)).assertFalse();
      expect(shouldUseRustDeskPhysicalTouchpad('rustdesk', true, 0, true)).assertFalse();
      expect(shouldUseRustDeskPhysicalTouchpad('rdp', true, 2, true)).assertFalse();
      expect(shouldUseRustDeskPhysicalTouchpad('rustdesk', true, 2, false)).assertFalse();
    });

    it('keeps_horizontal_and_vertical_remainders_independent', 0, (): void => {
      let state = resetPhysicalTouchpadWheelState();
      let result = accumulateRustDeskPhysicalTouchpadWheel(12, 0, state, 1, false);
      expect(result.x).assertEqual(0);
      expect(result.y).assertEqual(0);
      state = result.state;
      result = accumulateRustDeskPhysicalTouchpadWheel(1, 13, state, 1, true);
      expect(result.x).assertEqual(-1);
      expect(result.y).assertEqual(-1);
    });

    it('maps_pinch_steps_to_zoom_shortcuts_for_windows_and_macos', 0, (): void => {
      let pinch = resetPhysicalTouchpadPinchState();
      let result = accumulatePhysicalTouchpadPinch(1.05, pinch);
      expect(result.steps).assertEqual(0);
      result = accumulatePhysicalTouchpadPinch(1.10, result.state);
      expect(result.steps).assertEqual(1);
      expect(physicalTouchpadZoomKeyCode(result.steps))
        .assertEqual(RUSTDESK_TOUCHPAD_ZOOM_EQUALS_KEYCODE);
      expect(physicalTouchpadZoomModifierKeyCode(RemoteKeyboardLayout.WINDOWS))
        .assertEqual(HARMONY_KEYCODE_CTRL_LEFT);
      expect(physicalTouchpadZoomModifierKeyCode(RemoteKeyboardLayout.MACOS))
        .assertEqual(HARMONY_KEYCODE_META_LEFT);

      pinch = resetPhysicalTouchpadPinchState();
      result = accumulatePhysicalTouchpadPinch(0.9, pinch);
      expect(result.steps).assertEqual(-1);
      expect(physicalTouchpadZoomKeyCode(result.steps))
        .assertEqual(RUSTDESK_TOUCHPAD_ZOOM_MINUS_KEYCODE);
    });

    it('ignores_invalid_pinch_scales_without_poisoning_state', 0, (): void => {
      const result = accumulatePhysicalTouchpadPinch(NaN, { accumulation: 0.03, lastScale: 1 });
      expect(result.steps).assertEqual(0);
      expect(result.state.accumulation).assertEqual(0.03);
    });

    it('does_not_count_the_same_cumulative_scale_twice', 0, (): void => {
      let pinch = resetPhysicalTouchpadPinchState();
      let result = accumulatePhysicalTouchpadPinch(1.10, pinch);
      expect(result.steps).assertEqual(1);
      result = accumulatePhysicalTouchpadPinch(1.10, result.state);
      expect(result.steps).assertEqual(0);
    });
  });
}
