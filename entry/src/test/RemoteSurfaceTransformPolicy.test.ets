import { describe, it, expect } from '@ohos/hypium';
import {
  remotePointToSurface,
  surfacePointToRemote,
  RemoteSurfaceTransform
} from '../main/ets/services/RemoteSurfaceTransformPolicy';

const HIGH_DENSITY_TRANSFORM: RemoteSurfaceTransform = {
  remoteWidth: 1920,
  remoteHeight: 1080,
  viewportX: 111.111111,
  viewportY: 0,
  viewportW: 1777.777778,
  viewportH: 1000,
  surfaceWidthPx: 2000,
  surfaceHeightPx: 1000,
  surfaceWidthVp: 1000,
  surfaceHeightVp: 500
};

export default function remoteSurfaceTransformPolicyTest(): void {
  describe('RemoteSurfaceTransformPolicy', (): void => {
    it('treats high-density ArkUI coordinates as vp', 0, (): void => {
      const local = remotePointToSurface(HIGH_DENSITY_TRANSFORM, 960, 540);
      expect(Math.abs(local.x - 500) < 0.01).assertTrue();
      expect(Math.abs(local.y - 250) < 0.01).assertTrue();
      const remote = surfacePointToRemote(HIGH_DENSITY_TRANSFORM, 500, 250);
      expect(Math.abs(remote.x - 960) < 0.1).assertTrue();
      expect(Math.abs(remote.y - 540) < 0.1).assertTrue();
    });

    it('does not fold out-of-bounds vp coordinates back into the surface', 0, (): void => {
      const point = surfacePointToRemote(HIGH_DENSITY_TRANSFORM, 1500, 250);
      expect(point.inside).assertFalse();
    });

    it('keeps mouse mapping stable with a freely panned negative viewport', 0, (): void => {
      const panned: RemoteSurfaceTransform = {
        remoteWidth: 1920,
        remoteHeight: 1080,
        viewportX: -200,
        viewportY: -100,
        viewportW: 2400,
        viewportH: 1350,
        surfaceWidthPx: 2000,
        surfaceHeightPx: 1000,
        surfaceWidthVp: 1000,
        surfaceHeightVp: 500
      };
      const local = remotePointToSurface(panned, 960, 540);
      expect(Math.abs(local.x - 500) < 0.01).assertTrue();
      expect(Math.abs(local.y - 287.5) < 0.01).assertTrue();
      const remote = surfacePointToRemote(panned, local.x, local.y);
      expect(Math.abs(remote.x - 960) < 0.1).assertTrue();
      expect(Math.abs(remote.y - 540) < 0.1).assertTrue();
      expect(remote.inside).assertTrue();
    });
  });
}
