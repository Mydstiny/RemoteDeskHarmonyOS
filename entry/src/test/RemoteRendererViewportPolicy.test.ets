import { describe, it, expect } from '@ohos/hypium';
import { shouldAcceptRendererViewportSnapshot } from '../main/ets/services/RemoteRendererViewportPolicy';

export default function remoteRendererViewportPolicyTest(): void {
  describe('RemoteRendererViewportPolicy', (): void => {
    it('accepts the initial snapshot before any transform is submitted', 0, (): void => {
      expect(shouldAcceptRendererViewportSnapshot(0, 0)).assertTrue();
    });

    it('rejects a native snapshot older than the pending transform', 0, (): void => {
      expect(shouldAcceptRendererViewportSnapshot(10, 8)).assertFalse();
    });

    it('accepts an applied transform and newer renderer generations', 0, (): void => {
      expect(shouldAcceptRendererViewportSnapshot(10, 10)).assertTrue();
      expect(shouldAcceptRendererViewportSnapshot(10, 12)).assertTrue();
    });

    it('treats invalid generations as the initial generation', 0, (): void => {
      expect(shouldAcceptRendererViewportSnapshot(Number.NaN, 0)).assertTrue();
      expect(shouldAcceptRendererViewportSnapshot(10, Number.NaN)).assertFalse();
    });
  });
}
