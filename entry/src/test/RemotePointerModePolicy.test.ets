import { describe, it, expect } from '@ohos/hypium';
import {
  shouldHideSystemPointerForEmbeddedRemoteCursor,
  shouldHideSystemPointerForVirtualTouchpad,
  shouldRenderTouchPointerIndicator,
  shouldUseSystemMousePointer
} from '../main/ets/services/RemotePointerModePolicy';

export default function remotePointerModePolicyTest() {
  describe('RemotePointerModePolicy', (): void => {
    it('does_not_render_touch_indicator_in_keyboard_mouse_mode', 0, (): void => {
      expect(shouldRenderTouchPointerIndicator(true, true)).assertFalse();
    });

    it('renders_touch_indicator_only_when_visible_in_touch_modes', 0, (): void => {
      expect(shouldRenderTouchPointerIndicator(true, false)).assertTrue();
      expect(shouldRenderTouchPointerIndicator(false, false)).assertFalse();
    });

    it('uses_system_mouse_pointer_only_in_keyboard_mouse_mode', 0, (): void => {
      expect(shouldUseSystemMousePointer(true)).assertTrue();
      expect(shouldUseSystemMousePointer(false)).assertFalse();
    });

    it('hides_the_system_pointer_only_for_phone_pad_virtual_touchpads', 0, (): void => {
      expect(shouldHideSystemPointerForVirtualTouchpad(true, true, false)).assertTrue();
      expect(shouldHideSystemPointerForVirtualTouchpad(false, true, false)).assertFalse();
      expect(shouldHideSystemPointerForVirtualTouchpad(true, false, false)).assertFalse();
      expect(shouldHideSystemPointerForVirtualTouchpad(true, true, true)).assertFalse();
    });

    it('hides_the_local_pointer_only_over_an_active_embedded_remote_cursor', 0, (): void => {
      expect(shouldHideSystemPointerForEmbeddedRemoteCursor(
        true, true, true, false)).assertTrue();
      expect(shouldHideSystemPointerForEmbeddedRemoteCursor(
        false, true, true, false)).assertFalse();
      expect(shouldHideSystemPointerForEmbeddedRemoteCursor(
        true, false, true, false)).assertFalse();
      expect(shouldHideSystemPointerForEmbeddedRemoteCursor(
        true, true, false, false)).assertFalse();
      expect(shouldHideSystemPointerForEmbeddedRemoteCursor(
        true, true, true, true)).assertFalse();
    });
  });
}
