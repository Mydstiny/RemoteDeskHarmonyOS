import { describe, it, expect } from '@ohos/hypium';
import {
  baseCanvasTransform,
  clampCanvasTransform,
  normalizeLocalViewScaleMode,
  pinchCanvasTransform,
  REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION,
  resolveInitialRemoteDisplayScaleMode
} from '../main/ets/services/RemoteCanvasTransformPolicy';

export default function remoteCanvasTransformPolicyTest() {
  describe('RemoteCanvasTransformPolicy', () => {
    const viewport = { surfaceWidth: 1000, surfaceHeight: 600, sourceWidth: 2000, sourceHeight: 1000 };

    it('maps released scale values to stable settings values', 0, () => {
      expect(normalizeLocalViewScaleMode('original')).assertEqual('100');
      expect(normalizeLocalViewScaleMode('custom')).assertEqual('custom');
      expect(normalizeLocalViewScaleMode('unknown')).assertEqual('fit');
    });

    it('repairs unversioned derived display scale to the previous fit default', 0, () => {
      expect(resolveInitialRemoteDisplayScaleMode('100', 0)).assertEqual('fit');
      expect(resolveInitialRemoteDisplayScaleMode('custom', 0)).assertEqual('fit');
      expect(resolveInitialRemoteDisplayScaleMode('', 0)).assertEqual('fit');
      expect(resolveInitialRemoteDisplayScaleMode('100', REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION))
        .assertEqual('100');
      expect(resolveInitialRemoteDisplayScaleMode('custom', REMOTE_DISPLAY_SCALE_PREFERENCE_VERSION))
        .assertEqual('custom');
    });

    it('keeps fit centered and resolves 100 percent against contain scale', 0, () => {
      const fit = baseCanvasTransform('fit', 100, viewport);
      expect(fit.scale).assertEqual(1);
      const original = baseCanvasTransform('100', 100, viewport);
      expect(original.scale).assertEqual(2);
      expect(original.panX).assertEqual(0);
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
  });
}
