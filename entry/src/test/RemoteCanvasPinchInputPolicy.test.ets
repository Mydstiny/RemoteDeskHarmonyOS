import { describe, it, expect } from '@ohos/hypium';
import { shouldConsumeCanvasPinchTouch } from '../main/ets/services/RemoteCanvasPinchInputPolicy';

export default function remoteCanvasPinchInputPolicyTest(): void {
  describe('RemoteCanvasPinchInputPolicy', (): void => {
    it('consumes an active finger pinch stream', 0, (): void => {
      expect(shouldConsumeCanvasPinchTouch(true, true)).assertTrue();
    });

    it('does not consume mouse, pen or touchpad streams', 0, (): void => {
      expect(shouldConsumeCanvasPinchTouch(true, false)).assertFalse();
    });

    it('does not consume a finger stream before pinch ownership exists', 0, (): void => {
      expect(shouldConsumeCanvasPinchTouch(false, true)).assertFalse();
    });
  });
}
