import { describe, it, expect } from '@ohos/hypium';
import {
  remotePointToSurface,
  surfacePointToRemote,
  surfaceDeltaToRemote,
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

    it('round-trips a clockwise quarter-turn using raw remote coordinates', 0, (): void => {
      const rotated: RemoteSurfaceTransform = {
        remoteWidth: 400,
        remoteHeight: 200,
        viewportX: 0,
        viewportY: 0,
        viewportW: 200,
        viewportH: 400,
        surfaceWidthPx: 200,
        surfaceHeightPx: 400,
        surfaceWidthVp: 200,
        surfaceHeightVp: 400,
        rotation: 1
      };
      const local = remotePointToSurface(rotated, 200, 100);
      expect(Math.abs(local.x - 100) < 0.01).assertTrue();
      expect(Math.abs(local.y - 200) < 0.01).assertTrue();
      const remote = surfacePointToRemote(rotated, local.x, local.y);
      expect(Math.abs(remote.x - 200) < 0.1).assertTrue();
      expect(Math.abs(remote.y - 100) < 0.1).assertTrue();
      expect(remote.inside).assertTrue();
    });

    it('rotates relative pointer deltas with the displayed canvas', 0, (): void => {
      const rotated: RemoteSurfaceTransform = {
        remoteWidth: 400,
        remoteHeight: 200,
        viewportX: 0,
        viewportY: 0,
        viewportW: 200,
        viewportH: 400,
        surfaceWidthPx: 200,
        surfaceHeightPx: 400,
        surfaceWidthVp: 200,
        surfaceHeightVp: 400,
        rotation: 1
      };
      const delta = surfaceDeltaToRemote(rotated, 10, 20);
      expect(Math.abs(delta.x - 20) < 0.01).assertTrue();
      expect(Math.abs(delta.y + 10) < 0.01).assertTrue();
    });
  });
}
