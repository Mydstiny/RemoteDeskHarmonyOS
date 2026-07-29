import { describe, expect, it } from '@ohos/hypium';
import { resolveCanvasActiveTouchCount } from '../main/ets/services/RemoteCanvasTouchPointPolicy';

export default function remoteCanvasTouchPointPolicyTest(): void {
  describe('RemoteCanvasTouchPointPolicy', (): void => {
    it('keeps two tracked contacts when Move exposes only the changed touch', 0, (): void => {
      expect(resolveCanvasActiveTouchCount('move', 2, 1, 2, 1)).assertEqual(2);
    });

    it('uses the post-sync map after each Up', 0, (): void => {
      expect(resolveCanvasActiveTouchCount('up', 1, 2, 2, 1)).assertEqual(1);
      expect(resolveCanvasActiveTouchCount('up', 0, 1, 1, 1)).assertEqual(0);
    });

    it('retains the old Down fallback before a touch map is available', 0, (): void => {
      expect(resolveCanvasActiveTouchCount('down', 0, 1, 1, 1)).assertEqual(2);
    });

    it('clears all contacts on cancel', 0, (): void => {
      expect(resolveCanvasActiveTouchCount('cancel', 2, 2, 2, 2)).assertEqual(0);
    });
  });
}
