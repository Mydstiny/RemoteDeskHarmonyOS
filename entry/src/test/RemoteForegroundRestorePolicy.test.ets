import { describe, it, expect } from '@ohos/hypium';
import {
  shouldBindSurfaceBeforeForegroundRenderer,
  shouldInvalidateSurfaceAfterBackgroundDetach,
  shouldPollSurfaceAfterForegroundRestore
} from '../main/ets/services/RemoteForegroundRestorePolicy';

export default function remoteForegroundRestorePolicyTest() {
  describe('RemoteForegroundRestorePolicy', (): void => {
    it('invalidates_surface_after_background_renderer_detach', 0, (): void => {
      expect(shouldInvalidateSurfaceAfterBackgroundDetach(42, 7)).assertTrue();
      expect(shouldInvalidateSurfaceAfterBackgroundDetach(-1, 7)).assertFalse();
      expect(shouldInvalidateSurfaceAfterBackgroundDetach(42, -1)).assertFalse();
    });

    it('binds_surface_before_foreground_renderer_only_when_surface_is_valid', 0, (): void => {
      expect(shouldBindSurfaceBeforeForegroundRenderer('123456', 1920, 1080)).assertTrue();
      expect(shouldBindSurfaceBeforeForegroundRenderer('', 1920, 1080)).assertFalse();
      expect(shouldBindSurfaceBeforeForegroundRenderer('123456', 0, 1080)).assertFalse();
      expect(shouldBindSurfaceBeforeForegroundRenderer('123456', 1920, 0)).assertFalse();
    });

    it('polls_surface_for_restore_even_when_connection_was_preserved', 0, (): void => {
      expect(shouldPollSurfaceAfterForegroundRestore(true, 7, false, false)).assertTrue();
      expect(shouldPollSurfaceAfterForegroundRestore(true, 7, true, false)).assertFalse();
      expect(shouldPollSurfaceAfterForegroundRestore(false, 7, false, false)).assertFalse();
      expect(shouldPollSurfaceAfterForegroundRestore(true, -1, false, false)).assertFalse();
      expect(shouldPollSurfaceAfterForegroundRestore(true, 7, false, true)).assertFalse();
    });
  });
}
