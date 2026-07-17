/** FabAddStylePolicy routing and legacy-key compatibility regression tests. */
import { describe, it, expect } from '@ohos/hypium';
import { resolveFabAddStyle } from '../../../main/ets/services/FabAddStylePolicy';

export default function hostAddModePolicyTest(): void {
  describe('FabAddStylePolicy', (): void => {
    it('mobile_should_default_to_modern_mode', 0, (): void => {
      expect(resolveFabAddStyle('', false)).assertEqual('modern');
    });

    it('mobile_should_keep_classic_preference', 0, (): void => {
      expect(resolveFabAddStyle('classic', false)).assertEqual('classic');
    });

    it('desktop_should_always_use_classic_mode', 0, (): void => {
      expect(resolveFabAddStyle('modern', true)).assertEqual('classic');
    });
  });
}
