import { describe, it, expect } from '@ohos/hypium';
import {
  legacyRdpPresetForResolutionId,
  normalizeRdpResolutionId,
  rdpResolutionPresetForId,
  rdpResolutionPresets
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
  });
}
