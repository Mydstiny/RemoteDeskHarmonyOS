import { describe, expect, it } from '@ohos/hypium';
import { selectRustDeskMultiCanvasPreview } from '../main/ets/services/RustDeskMultiCanvasPreviewPolicy';

export default function rustDeskMultiCanvasPreviewPolicyTest(): void {
  describe('RustDeskMultiCanvasPreviewPolicy', (): void => {
    const displays = [
      { display: 0, width: 1920, height: 1080, originalWidth: 1920,
        originalHeight: 1080, online: true },
      { display: 1, width: 2560, height: 1440, originalWidth: 2560,
        originalHeight: 1440, online: true },
      { display: 2, width: 1080, height: 1920, originalWidth: 1080,
        originalHeight: 1920, online: false }
    ];

    it('admits preferred online preview on desktop', 0, (): void => {
      const decision = selectRustDeskMultiCanvasPreview(true, true, 0, 1, displays);
      expect(decision.accepted).assertTrue();
      expect(decision.display).assertEqual(1);
    });

    it('fails closed outside desktop mode', 0, (): void => {
      expect(selectRustDeskMultiCanvasPreview(false, true, 0, 1, displays).reason)
        .assertEqual('feature_disabled');
    });

    it('never selects an offline preferred display', 0, (): void => {
      const decision = selectRustDeskMultiCanvasPreview(true, true, 0, 2, displays);
      expect(decision.accepted).assertTrue();
      expect(decision.display).assertEqual(1);
    });

    it('rejects a pair above the pixel budget', 0, (): void => {
      const decision = selectRustDeskMultiCanvasPreview(true, true, 0, 1, displays, 1);
      expect(decision.accepted).assertFalse();
      expect(decision.reason).assertEqual('resource_budget_exceeded');
    });
  });
}
