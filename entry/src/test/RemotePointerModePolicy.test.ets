import { describe, it, expect } from '@ohos/hypium';
import {
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
  });
}
