import { describe, it, expect } from '@ohos/hypium';
import {
  legacyRdpPresetForResolutionId,
  normalizeRdpResolutionId,
  rdpResolutionAspectAssessment,
  rdpResolutionPresetForId,
  rdpResolutionPresets,
  rdpResolutionPresetsForSurface,
  resolveRdpResolutionGeometry
} from '../main/ets/services/RemoteResolutionPresetPolicy';

export default function remoteResolutionPresetPolicyTest() {
  describe('RemoteResolutionPresetPolicy', () => {
    it('provides more than ten standard presets', 0, () => {
      expect(rdpResolutionPresets().length > 10).assertTrue();
    });

    it('migrates released four-position values', 0, () => {
      expect(normalizeRdpResolutionId('', 0)).assertEqual('auto');
      expect(normalizeRdpResolutionId('', 2)).assertEqual('2560x1440');
      expect(normalizeRdpResolutionId('', 3)).assertEqual('3840x2160');
    });

    it('keeps stable ids and compatibility values', 0, () => {
      expect(rdpResolutionPresetForId('3440x1440')!.width).assertEqual(3440);
      expect(legacyRdpPresetForResolutionId('3840x2160')).assertEqual(3);
      expect(legacyRdpPresetForResolutionId('1920x1200')).assertEqual(1);
    });

    it('uses one geometry contract for adaptive and fixed layouts', 0, (): void => {
      const adaptive = resolveRdpResolutionGeometry('auto', 1599, 999);
      expect(adaptive.width).assertEqual(1598);
      expect(adaptive.height).assertEqual(999);
      expect(adaptive.followsWindow).assertTrue();
      const fixed = resolveRdpResolutionGeometry('1920x1200', 1600, 900);
      expect(fixed.width).assertEqual(1920);
      expect(fixed.height).assertEqual(1200);
      expect(fixed.orientation).assertEqual(0);
      expect(fixed.followsWindow).assertFalse();
    });

    it('ranks current-window aspect matches before mismatched presets', 0, (): void => {
      const ordered = rdpResolutionPresetsForSurface(1600, 1000);
      expect(ordered[0].id).assertEqual('1680x1050');
      expect(rdpResolutionAspectAssessment('1920x1200', 1600, 1000).avoidsRatioBars)
        .assertTrue();
      const mismatch = rdpResolutionAspectAssessment('1920x1080', 1600, 1000);
      expect(mismatch.avoidsRatioBars).assertFalse();
      expect(mismatch.aspectGapPercent > 10).assertTrue();
      expect(rdpResolutionAspectAssessment('auto', 1600, 1000).followsWindow).assertTrue();
    });
  });
}
