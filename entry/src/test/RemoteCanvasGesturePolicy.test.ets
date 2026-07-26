import { describe, it, expect } from '@ohos/hypium';
import {
  endCanvasPanOwnership,
  endCanvasPinchOwnership,
  shouldReleaseCanvasGestureOwnership
} from '../main/ets/services/RemoteCanvasGesturePolicy';

export default function remoteCanvasGesturePolicyTest(): void {
  describe('RemoteCanvasGesturePolicy', (): void => {
    it('keeps pan ownership when pinch ends first', 0, (): void => {
      const afterPinch = endCanvasPinchOwnership({ pinchActive: true, panActive: true });
      expect(afterPinch.pinchActive).assertFalse();
      expect(afterPinch.panActive).assertTrue();
      expect(shouldReleaseCanvasGestureOwnership(afterPinch)).assertFalse();
      const final = endCanvasPanOwnership(afterPinch);
      expect(shouldReleaseCanvasGestureOwnership(final)).assertTrue();
    });

    it('keeps pinch ownership when pan ends first', 0, (): void => {
      const afterPan = endCanvasPanOwnership({ pinchActive: true, panActive: true });
      expect(afterPan.pinchActive).assertTrue();
      expect(afterPan.panActive).assertFalse();
      expect(shouldReleaseCanvasGestureOwnership(afterPan)).assertFalse();
      const final = endCanvasPinchOwnership(afterPan);
      expect(shouldReleaseCanvasGestureOwnership(final)).assertTrue();
    });
  });
}
