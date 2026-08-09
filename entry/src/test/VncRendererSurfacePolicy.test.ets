import { describe, it, expect } from '@ohos/hypium';
import {
  isVncRendererSurfaceReady,
  shouldDeferVncRendererUntilSurface
} from '../main/ets/services/VncRendererSurfacePolicy';

export default function vncRendererSurfacePolicyTest(): void {
  describe('VncRendererSurfacePolicy', (): void => {
    it('requires both a ready flag and a non-empty SurfaceId', 0, (): void => {
      expect(isVncRendererSurfaceReady(true, '123456')).assertTrue();
      expect(isVncRendererSurfaceReady(true, '  ')).assertFalse();
      expect(isVncRendererSurfaceReady(false, '123456')).assertFalse();
    });

    it('defers only VNC startup when the current surface is unavailable', 0, (): void => {
      expect(shouldDeferVncRendererUntilSurface(true, false, '', false, false)).assertTrue();
      expect(shouldDeferVncRendererUntilSurface(true, true, '  ', false, false)).assertTrue();
      expect(shouldDeferVncRendererUntilSurface(true, true, '123456', false, false)).assertFalse();
      expect(shouldDeferVncRendererUntilSurface(false, false, '', false, false)).assertFalse();
    });

    it('does not poll during restore teardown or cleanup', 0, (): void => {
      expect(shouldDeferVncRendererUntilSurface(true, false, '', true, false)).assertFalse();
      expect(shouldDeferVncRendererUntilSurface(true, false, '', false, true)).assertFalse();
    });
  });
}
