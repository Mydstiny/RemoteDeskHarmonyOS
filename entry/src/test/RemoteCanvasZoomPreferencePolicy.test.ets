import { describe, it, expect } from '@ohos/hypium';
import {
  CANVAS_GESTURE_ZOOM_PREFERENCE_VERSION,
  resolveCanvasGestureZoomPreference
} from '../main/ets/services/RemoteCanvasZoomPreferencePolicy';

export default function remoteCanvasZoomPreferencePolicyTest(): void {
  describe('RemoteCanvasZoomPreferencePolicy', (): void => {
    it('keeps a stored value from an older app version', 0, (): void => {
      const result = resolveCanvasGestureZoomPreference(true, 1, false);
      expect(result.enabled).assertTrue();
      expect(result.userConfigured).assertFalse();
      expect(result.version).assertEqual(CANVAS_GESTURE_ZOOM_PREFERENCE_VERSION);
    });

    it('uses the clean-install default only when the preference is absent', 0, (): void => {
      const result = resolveCanvasGestureZoomPreference(true, 0, false, false, false);
      expect(result.enabled).assertFalse();
      expect(result.userConfigured).assertFalse();
    });

    it('keeps a later explicit user choice', 0, (): void => {
      const result = resolveCanvasGestureZoomPreference(true,
        CANVAS_GESTURE_ZOOM_PREFERENCE_VERSION, true);
      expect(result.enabled).assertTrue();
      expect(result.userConfigured).assertTrue();
    });
  });
}
