import { describe, it, expect } from '@ohos/hypium';
import {
  baseCanvasTransform,
  canvasTransformCanPan,
  canvasTransformDiffersFromBaseline,
  clampCanvasTransform,
  CANVAS_TRANSFORM_MAX_SCALE,
  localCanvasPanInteractionEnabled,
  normalizeLocalViewScaleMode,
  panCanvasTransform,
  pinchCanvasTransform,
  rebaseCanvasTransform,
  RDP_CANVAS_FREE_PAN_INSET_RATIO,
  REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION,
  resolveInitialRemoteDisplayScaleMode
} from '../main/ets/services/RemoteCanvasTransformPolicy';

export default function remoteCanvasTransformPolicyTest() {
  describe('RemoteCanvasTransformPolicy', () => {
    const viewport = { surfaceWidth: 1000, surfaceHeight: 600, sourceWidth: 2000, sourceHeight: 1000 };

    it('maps released scale values to stable settings values', 0, () => {
      expect(normalizeLocalViewScaleMode('original')).assertEqual('100');
      expect(normalizeLocalViewScaleMode('fill')).assertEqual('fill');
      expect(normalizeLocalViewScaleMode('custom')).assertEqual('custom');
      expect(normalizeLocalViewScaleMode('unknown')).assertEqual('fit');
      expect(localCanvasPanInteractionEnabled(false, 'fill')).assertTrue();
      expect(localCanvasPanInteractionEnabled(false, 'fit')).assertFalse();
      expect(localCanvasPanInteractionEnabled(true, 'fit')).assertTrue();
    });

    it('repairs unversioned derived display scale to the previous fit default', 0, () => {
      expect(resolveInitialRemoteDisplayScaleMode('100', 0)).assertEqual('fit');
      expect(resolveInitialRemoteDisplayScaleMode('custom', 0)).assertEqual('fit');
      expect(resolveInitialRemoteDisplayScaleMode('100', 1)).assertEqual('fit');
      expect(resolveInitialRemoteDisplayScaleMode('custom', 1)).assertEqual('fit');
      expect(resolveInitialRemoteDisplayScaleMode('', 0)).assertEqual('fit');
      expect(resolveInitialRemoteDisplayScaleMode('100', REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION))
        .assertEqual('100');
      expect(resolveInitialRemoteDisplayScaleMode('custom', REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION))
        .assertEqual('custom');
    });

    it('inherits an existing display scale even before the current version marker', 0, () => {
      expect(resolveInitialRemoteDisplayScaleMode('100', 0, true)).assertEqual('100');
      expect(resolveInitialRemoteDisplayScaleMode('custom', 1, true)).assertEqual('custom');
    });

    it('keeps fit centered and resolves 100 percent against contain scale', 0, () => {
      const fit = baseCanvasTransform('fit', 100, viewport);
      expect(fit.scale).assertEqual(1);
      const original = baseCanvasTransform('100', 100, viewport);
      expect(original.scale).assertEqual(2);
      expect(original.panX).assertEqual(0);
    });

    it('fills the surface without distortion or ratio bars', 0, (): void => {
      const letterboxed: CanvasViewport = {
        surfaceWidth: 1600,
        surfaceHeight: 1000,
        sourceWidth: 1920,
        sourceHeight: 1080,
        freePanInsetRatio: RDP_CANVAS_FREE_PAN_INSET_RATIO
      };
      const filled: CanvasTransform = baseCanvasTransform('fill', 100, letterboxed);
      const contain: number = Math.min(1600 / 1920, 1000 / 1080);
      const physical: number = contain * filled.scale;
      expect(Math.abs(1080 * physical - 1000) < 0.01).assertTrue();
      expect(1920 * physical > 1600).assertTrue();
      expect(canvasTransformCanPan(filled, letterboxed)).assertTrue();
      const verticalAttempt: CanvasTransform = panCanvasTransform(
        filled, letterboxed, 0, 999);
      expect(Math.abs(verticalAttempt.panY) < 0.01).assertTrue();
      expect(verticalAttempt.panX).assertEqual(0);

      const pillarboxed: CanvasViewport = {
        surfaceWidth: 1800,
        surfaceHeight: 900,
        sourceWidth: 1600,
        sourceHeight: 1000,
        freePanInsetRatio: RDP_CANVAS_FREE_PAN_INSET_RATIO
      };
      const wideFill: CanvasTransform = baseCanvasTransform('fill', 100, pillarboxed);
      const wideContain: number = Math.min(1800 / 1600, 900 / 1000);
      const widePhysical: number = wideContain * wideFill.scale;
      expect(Math.abs(1600 * widePhysical - 1800) < 0.01).assertTrue();
      expect(1000 * widePhysical > 900).assertTrue();
      const horizontalAttempt: CanvasTransform = panCanvasTransform(
        wideFill, pillarboxed, 999, 0);
      expect(Math.abs(horizontalAttempt.panX) < 0.01).assertTrue();
      expect(horizontalAttempt.panY).assertEqual(0);
    });

    it('keeps fill coverage after a panned canvas crosses window aspect ratios', 0, (): void => {
      const beforeViewport: CanvasViewport = {
        surfaceWidth: 1600,
        surfaceHeight: 1000,
        sourceWidth: 1920,
        sourceHeight: 1080,
        freePanInsetRatio: RDP_CANVAS_FREE_PAN_INSET_RATIO
      };
      const afterViewport: CanvasViewport = {
        surfaceWidth: 2560,
        surfaceHeight: 1080,
        sourceWidth: 1920,
        sourceHeight: 1080,
        freePanInsetRatio: RDP_CANVAS_FREE_PAN_INSET_RATIO
      };
      const filled: CanvasTransform = baseCanvasTransform('fill', 100, beforeViewport);
      const panned: CanvasTransform = panCanvasTransform(filled, beforeViewport, 100, 0);
      const rebased: CanvasTransform = rebaseCanvasTransform(
        panned, beforeViewport, afterViewport);
      const nextContain: number = Math.min(2560 / 1920, 1080 / 1080);
      const nextPhysical: number = nextContain * rebased.scale;
      expect(1920 * nextPhysical >= 2560).assertTrue();
      expect(1080 * nextPhysical >= 1080).assertTrue();
      expect(rebased.strictContentBounds === true).assertTrue();
    });

    it('only reports a reset affordance for a visible baseline deviation', 0, (): void => {
      const baseline: CanvasTransform = baseCanvasTransform('fit', 100, viewport);
      expect(canvasTransformDiffersFromBaseline(baseline,
        { scale: baseline.scale, panX: 0.4, panY: -0.4, rotation: 0 })).assertFalse();
      expect(canvasTransformDiffersFromBaseline(baseline,
        { scale: baseline.scale, panX: 1, panY: 0, rotation: 0 })).assertTrue();
      expect(canvasTransformDiffersFromBaseline(baseline,
        { scale: 1.01, panX: 0, panY: 0, rotation: 0 })).assertTrue();
    });

    it('fits a rotated canvas against the swapped display dimensions', 0, (): void => {
      const rotated = baseCanvasTransform('fit', 100, viewport, 1);
      expect(rotated.rotation).assertEqual(1);
      expect(rotated.scale).assertEqual(1);
      expect(rotated.panX).assertEqual(0);
      expect(rotated.panY).assertEqual(0);
    });

    it('keeps the focal remote point stable during a pinch', 0, () => {
      const before = baseCanvasTransform('fit', 100, viewport);
      const after = pinchCanvasTransform(before, viewport, 500, 300, 2, 0, 0);
      expect(Math.round(after.scale * 100)).assertEqual(200);
      expect(Math.round(after.panX)).assertEqual(0);
      expect(Math.round(after.panY)).assertEqual(0);
    });

    it('clamps pan to content bounds', 0, () => {
      const result = clampCanvasTransform({ scale: 2, panX: 9999, panY: -9999 }, viewport);
      expect(Math.round(result.panX)).assertEqual(500);
      expect(Math.round(result.panY)).assertEqual(-200);
    });

    it('only makes an overflowing canvas pannable', 0, () => {
      expect(canvasTransformCanPan(baseCanvasTransform('fit', 100, viewport), viewport))
        .assertFalse();
      expect(canvasTransformCanPan(baseCanvasTransform('100', 100, viewport), viewport))
        .assertTrue();
    });

    it('moves an overflowing canvas and clamps both directions', 0, () => {
      const zoomed = baseCanvasTransform('100', 100, viewport);
      const moved = panCanvasTransform(zoomed, viewport, 120, -80);
      expect(Math.round(moved.panX)).assertEqual(120);
      expect(Math.round(moved.panY)).assertEqual(-80);
      const bounded = panCanvasTransform(moved, viewport, 9999, -9999);
      expect(Math.round(bounded.panX)).assertEqual(500);
      expect(Math.round(bounded.panY)).assertEqual(-200);
    });

    it('keeps strict per-axis bounds when free pan is not enabled', 0, (): void => {
      const letterboxed: CanvasViewport = {
        surfaceWidth: 1600,
        surfaceHeight: 1000,
        sourceWidth: 1280,
        sourceHeight: 1024
      };
      const moved: CanvasTransform = panCanvasTransform(
        { scale: 1.2, panX: 0, panY: 0 }, letterboxed, 9999, 9999);
      expect(Math.round(moved.panX)).assertEqual(0);
      expect(Math.round(moved.panY)).assertEqual(100);
    });

    it('allows bounded two-axis free pan for an enlarged RDP canvas', 0, (): void => {
      const rdpLetterboxed: CanvasViewport = {
        surfaceWidth: 1600,
        surfaceHeight: 1000,
        sourceWidth: 1280,
        sourceHeight: 1024,
        freePanInsetRatio: RDP_CANVAS_FREE_PAN_INSET_RATIO
      };
      const fit: CanvasTransform = baseCanvasTransform('fit', 100, rdpLetterboxed);
      expect(canvasTransformCanPan(fit, rdpLetterboxed)).assertFalse();
      const fitMoved: CanvasTransform = panCanvasTransform(
        fit, rdpLetterboxed, 9999, -9999);
      expect(Math.round(fitMoved.panX)).assertEqual(0);
      expect(Math.round(fitMoved.panY)).assertEqual(0);
      const shrunken: CanvasTransform = panCanvasTransform(
        { scale: 0.8, panX: 0, panY: 0 }, rdpLetterboxed, 9999, -9999);
      expect(Math.round(shrunken.panX)).assertEqual(0);
      expect(Math.round(shrunken.panY)).assertEqual(0);
      const zoomed: CanvasTransform = { scale: 1.2, panX: 0, panY: 0 };
      expect(canvasTransformCanPan(zoomed, rdpLetterboxed)).assertTrue();
      const moved: CanvasTransform = panCanvasTransform(
        zoomed, rdpLetterboxed, 9999, 9999);
      expect(Math.round(moved.panX)).assertEqual(720);
      expect(Math.round(moved.panY)).assertEqual(450);
    });

    it('prefers real overflow and clamps free pan symmetrically', 0, (): void => {
      const rdpViewport: CanvasViewport = {
        surfaceWidth: viewport.surfaceWidth,
        surfaceHeight: viewport.surfaceHeight,
        sourceWidth: viewport.sourceWidth,
        sourceHeight: viewport.sourceHeight,
        freePanInsetRatio: RDP_CANVAS_FREE_PAN_INSET_RATIO
      };
      const positive: CanvasTransform = panCanvasTransform(
        { scale: 3, panX: 0, panY: 0 }, rdpViewport, 9999, 9999);
      expect(Math.round(positive.panX)).assertEqual(1000);
      expect(Math.round(positive.panY)).assertEqual(450);
      const negative: CanvasTransform = panCanvasTransform(
        { scale: 3, panX: 0, panY: 0 }, rdpViewport, -9999, -9999);
      expect(Math.round(negative.panX)).assertEqual(-1000);
      expect(Math.round(negative.panY)).assertEqual(-450);
    });

    it('keeps the multiplier within the native renderer limit', 0, (): void => {
      const smallViewport: CanvasViewport = {
        surfaceWidth: 100,
        surfaceHeight: 100,
        sourceWidth: 1000,
        sourceHeight: 1000
      };
      const maxed = baseCanvasTransform('custom', 300, smallViewport);
      expect(Math.round(maxed.scale * 100) / 100).assertEqual(CANVAS_TRANSFORM_MAX_SCALE);
      expect(maxed.scale <= CANVAS_TRANSFORM_MAX_SCALE).assertTrue();
    });

    it('preserves manual zoom and the centred content point across window rotation', 0, (): void => {
      const landscape: CanvasViewport = {
        surfaceWidth: 1000, surfaceHeight: 600,
        sourceWidth: 2000, sourceHeight: 1000
      };
      const portrait: CanvasViewport = {
        surfaceWidth: 600, surfaceHeight: 1000,
        sourceWidth: 2000, sourceHeight: 1000
      };
      const before: CanvasTransform = clampCanvasTransform({
        scale: 4, panX: 180, panY: -80, rotation: 0
      }, landscape);
      const after: CanvasTransform = rebaseCanvasTransform(before, landscape, portrait);
      expect(Math.abs(after.scale - before.scale) < 0.001).assertTrue();
      expect(after.panX > 0).assertTrue();
      expect(after.panY < 0).assertTrue();
    });

    it('keeps fit centred when rebasing a quarter-turned canvas', 0, (): void => {
      const next: CanvasViewport = {
        surfaceWidth: 600, surfaceHeight: 1000,
        sourceWidth: 2000, sourceHeight: 1000
      };
      const before: CanvasTransform = baseCanvasTransform('fit', 100, viewport, 1);
      const after: CanvasTransform = rebaseCanvasTransform(before, viewport, next);
      expect(after.rotation).assertEqual(1);
      expect(Math.abs(after.scale - 1) < 0.001).assertTrue();
      expect(Math.abs(after.panX) < 0.001).assertTrue();
      expect(Math.abs(after.panY) < 0.001).assertTrue();
    });

    it('preserves the focused region when the remote source rotates', 0, (): void => {
      const portraitSource: CanvasViewport = {
        surfaceWidth: 1000, surfaceHeight: 600,
        sourceWidth: 1000, sourceHeight: 2000
      };
      const before: CanvasTransform = clampCanvasTransform({
        scale: 3, panX: 120, panY: -210, rotation: 0
      }, viewport);
      const after: CanvasTransform = rebaseCanvasTransform(before, viewport, portraitSource);
      expect(Math.abs(after.scale - before.scale) < 0.001).assertTrue();
      expect(after.panX > 0).assertTrue();
      expect(after.panY < 0).assertTrue();
    });
  });
}
