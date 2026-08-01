import { describe, it, expect } from '@ohos/hypium';
import {
  observedVncFrameGeometry,
  shouldAdoptVncFrameGeometry
} from '../../../main/ets/services/VncSessionGeometryPolicy';

export default function vncSessionGeometryPolicyTest(): void {
  describe('VncSessionGeometryPolicy', (): void => {
    it('uses_accepted_framebuffer_geometry_as_pointer_space', 0, (): void => {
      expect(shouldAdoptVncFrameGeometry(
        1920, 1080, true, 1, 2940, 1912)).assertTrue();
      const geometry = observedVncFrameGeometry(true, 1, 2940, 1912);
      expect(geometry === null).assertFalse();
      if (geometry !== null) {
        expect(geometry.width).assertEqual(2940);
        expect(geometry.height).assertEqual(1912);
      }
    });

    it('ignores_unaccepted_or_unchanged_geometry', 0, (): void => {
      expect(shouldAdoptVncFrameGeometry(
        1920, 1080, true, 0, 2940, 1912)).assertFalse();
      expect(shouldAdoptVncFrameGeometry(
        2940, 1912, true, 3, 2940, 1912)).assertFalse();
    });
  });
}
