import { describe, it, expect } from '@ohos/hypium';
import {
  observedVncFrameGeometry,
  shouldAdoptVncFrameGeometry
} from '../main/ets/services/VncSessionGeometryPolicy';

export default function vncSessionGeometryPolicyTest(): void {
  describe('VncSessionGeometryPolicy', (): void => {
    it('adopts the first accepted mac framebuffer geometry', 0, (): void => {
      expect(shouldAdoptVncFrameGeometry(
        1920, 1080, true, 1, 2940, 1912)).assertTrue();
      const geometry = observedVncFrameGeometry(true, 1, 2940, 1912);
      expect(geometry === null).assertFalse();
      if (geometry !== null) {
        expect(geometry.width).assertEqual(2940);
        expect(geometry.height).assertEqual(1912);
      }
    });

    it('rejects placeholders before an accepted frame', 0, (): void => {
      expect(shouldAdoptVncFrameGeometry(
        1920, 1080, true, 0, 2940, 1912)).assertFalse();
      expect(shouldAdoptVncFrameGeometry(
        1920, 1080, false, 8, 2940, 1912)).assertFalse();
    });

    it('does not reset input when the geometry is unchanged or invalid', 0, (): void => {
      expect(shouldAdoptVncFrameGeometry(
        2940, 1912, true, 8, 2940, 1912)).assertFalse();
      expect(observedVncFrameGeometry(true, 8, 0, 1912) === null).assertTrue();
    });
  });
}
