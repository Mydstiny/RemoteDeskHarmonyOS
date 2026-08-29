import { describe, it, expect } from '@ohos/hypium';
import {
  followCanvasForLocalPointer,
  followCanvasForPhysicalPointer,
  followCanvasForRemotePointer
} from '../main/ets/services/RemoteCanvasPointerFollowPolicy';
import { CanvasTransform, CanvasViewport } from
  '../main/ets/services/RemoteCanvasTransformPolicy';
import { RemoteSurfaceTransform } from
  '../main/ets/services/RemoteSurfaceTransformPolicy';

export default function remoteCanvasPointerFollowPolicyTest(): void {
  describe('RemoteCanvasPointerFollowPolicy', (): void => {
    const viewport: CanvasViewport = {
      surfaceWidth: 1000, surfaceHeight: 600,
      sourceWidth: 2000, sourceHeight: 1000
    };
    const zoomed: CanvasTransform = { scale: 2, panX: 0, panY: 0, rotation: 0 };
    const surface: RemoteSurfaceTransform = {
      surfaceWidthVp: 1000, surfaceHeightVp: 600,
      surfaceWidthPx: 1000, surfaceHeightPx: 600,
      viewportX: -500, viewportY: -200,
      viewportW: 2000, viewportH: 1000,
      remoteWidth: 2000, remoteHeight: 1000,
      rotation: 0
    };

    it('does not move inside the central safe area', 0, (): void => {
      const result = followCanvasForRemotePointer({
        enabled: true, transform: zoomed, viewport, surfaceTransform: surface,
        remoteX: 1000, remoteY: 500
      });
      expect(result.moved).assertFalse();
      expect(result.reason).assertEqual('inside-safe-area');
    });

    it('moves both axes when the virtual pointer crosses a safe-area corner', 0, (): void => {
      const result = followCanvasForRemotePointer({
        enabled: true, transform: zoomed, viewport, surfaceTransform: surface,
        remoteX: 1600, remoteY: 850
      });
      expect(result.moved).assertTrue();
      expect(result.panDeltaX < 0).assertTrue();
      expect(result.panDeltaY < 0).assertTrue();
    });

    it('keeps remote pointer following valid through all display rotations', 0, (): void => {
      const remoteCorners: number[][] = [
        [1999, 999], [1999, 0], [0, 0], [0, 999]
      ];
      for (let rotation: number = 0; rotation < 4; rotation++) {
        const rotatedSurface: RemoteSurfaceTransform = {
          surfaceWidthVp: surface.surfaceWidthVp,
          surfaceHeightVp: surface.surfaceHeightVp,
          surfaceWidthPx: surface.surfaceWidthPx,
          surfaceHeightPx: surface.surfaceHeightPx,
          viewportX: surface.viewportX,
          viewportY: surface.viewportY,
          viewportW: surface.viewportW,
          viewportH: surface.viewportH,
          remoteWidth: surface.remoteWidth,
          remoteHeight: surface.remoteHeight,
          rotation
        };
        const result = followCanvasForRemotePointer({
          enabled: true,
          transform: { scale: 2, panX: 0, panY: 0, rotation },
          viewport,
          surfaceTransform: rotatedSurface,
          remoteX: remoteCorners[rotation][0],
          remoteY: remoteCorners[rotation][1]
        });
        expect(result.moved).assertTrue();
        expect(Number.isFinite(result.transform.panX)).assertTrue();
        expect(Number.isFinite(result.transform.panY)).assertTrue();
      }
    });

    it('uses strict bounds even when the manual RDP viewport permits free pan', 0, (): void => {
      const freeViewport: CanvasViewport = {
        surfaceWidth: 1000, surfaceHeight: 600,
        sourceWidth: 2000, sourceHeight: 1000,
        freePanInsetRatio: 0.45
      };
      const result = followCanvasForRemotePointer({
        enabled: true,
        transform: { scale: 2, panX: 9999, panY: 9999, rotation: 0 },
        viewport: freeViewport, surfaceTransform: surface,
        remoteX: 1900, remoteY: 900
      });
      expect(result.moved).assertTrue();
      expect(Math.abs(result.transform.panX) <= 500).assertTrue();
      expect(Math.abs(result.transform.panY) <= 200).assertTrue();
    });

    it('keeps fit and disabled behavior unchanged', 0, (): void => {
      const fit: CanvasTransform = { scale: 1, panX: 0, panY: 0, rotation: 0 };
      expect(followCanvasForRemotePointer({
        enabled: true, transform: fit, viewport, surfaceTransform: surface,
        remoteX: 1999, remoteY: 999
      }).moved).assertFalse();
      expect(followCanvasForRemotePointer({
        enabled: false, transform: zoomed, viewport, surfaceTransform: surface,
        remoteX: 1999, remoteY: 999
      }).reason).assertEqual('disabled');
    });

    it('arms a physical pointer only after it enters the inner region', 0, (): void => {
      const outside = followCanvasForPhysicalPointer({
        enabled: true, transform: zoomed, viewport,
        surfaceWidthVp: 1000, surfaceHeightVp: 600,
        localX: 2, localY: 300, pxPerVpX: 1, pxPerVpY: 1, armed: false
      });
      expect(outside.armed).assertFalse();
      expect(outside.moved).assertFalse();
      const inside = followCanvasForPhysicalPointer({
        enabled: true, transform: zoomed, viewport,
        surfaceWidthVp: 1000, surfaceHeightVp: 600,
        localX: 500, localY: 300, pxPerVpX: 1, pxPerVpY: 1, armed: false
      });
      expect(inside.armed).assertTrue();
      const edge = followCanvasForPhysicalPointer({
        enabled: true, transform: zoomed, viewport,
        surfaceWidthVp: 1000, surfaceHeightVp: 600,
        localX: 995, localY: 300, pxPerVpX: 1, pxPerVpY: 1, armed: inside.armed
      });
      expect(edge.active).assertTrue();
      expect(edge.panDeltaX < 0).assertTrue();
    });

    it('keeps the axes independent at a physical edge', 0, (): void => {
      const result = followCanvasForPhysicalPointer({
        enabled: true, transform: zoomed, viewport,
        surfaceWidthVp: 1000, surfaceHeightVp: 600,
        localX: 500, localY: 1, pxPerVpX: 1, pxPerVpY: 1, armed: true
      });
      expect(result.panDeltaX).assertEqual(0);
      expect(result.panDeltaY > 0).assertTrue();
    });

    it('keeps a local relative pointer on the safe-area edge while panning', 0, (): void => {
      const result = followCanvasForLocalPointer({
        enabled: true, transform: zoomed, viewport,
        surfaceWidthVp: 1000, surfaceHeightVp: 600,
        localX: 950, localY: 300, pxPerVpX: 1, pxPerVpY: 1
      });
      expect(result.moved).assertTrue();
      expect(result.pointerX < 950).assertTrue();
      expect(result.panDeltaX < 0).assertTrue();
      expect(result.panDeltaY).assertEqual(0);
    });
  });
}
