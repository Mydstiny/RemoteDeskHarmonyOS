import { describe, it, expect } from '@ohos/hypium';
import {
  remotePointToSurface,
  surfaceDeltaToRemote,
  surfacePointToRemote,
  RemoteSurfaceTransform
} from '../../../main/ets/services/RemoteSurfaceTransformPolicy';

const TRANSFORM: RemoteSurfaceTransform = {
  remoteWidth: 1920,
  remoteHeight: 1080,
  viewportX: 55.555555,
  viewportY: 0,
  viewportW: 888.88889,
  viewportH: 500,
  surfaceWidthPx: 1000,
  surfaceHeightPx: 500,
  surfaceWidthVp: 1000,
  surfaceHeightVp: 500
};

export default function remoteSurfaceTransformPolicyTest(): void {
  describe('RemoteSurfaceTransformPolicy', (): void => {
    it('center_roundtrips_between_remote_and_surface', 0, (): void => {
      const local = remotePointToSurface(TRANSFORM, 960, 540);
      expect(Math.abs(local.x - 500) < 0.01).assertTrue();
      expect(Math.abs(local.y - 250) < 0.01).assertTrue();
      const remote = surfacePointToRemote(TRANSFORM, local.x, local.y);
      expect(Math.abs(remote.x - 960) < 0.1).assertTrue();
      expect(Math.abs(remote.y - 540) < 0.1).assertTrue();
    });

    it('relative_delta_uses_content_viewport_once', 0, (): void => {
      const delta = surfaceDeltaToRemote(TRANSFORM, 10, 0);
      expect(Math.abs(delta.x - 21.6) < 0.1).assertTrue();
      expect(Math.abs(delta.y) < 0.01).assertTrue();
    });

    it('letterbox_point_is_outside_remote_desktop', 0, (): void => {
      const point = surfacePointToRemote(TRANSFORM, 10, 250);
      expect(point.inside).assertFalse();
    });

    it('invalid_input_is_not_forwarded_as_a_pointer_position', 0, (): void => {
      const point = surfacePointToRemote(TRANSFORM, NaN, 250);
      expect(point.inside).assertFalse();
      const delta = surfaceDeltaToRemote(TRANSFORM, Infinity, 1);
      expect(Number.isFinite(delta.x)).assertTrue();
      expect(Number.isFinite(delta.y)).assertTrue();
    });
  });
}
