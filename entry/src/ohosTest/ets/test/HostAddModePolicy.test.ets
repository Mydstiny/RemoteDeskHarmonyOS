/** HostAddModePolicy.test.ets — FAB add-mode routing regression tests */
import { describe, it, expect } from '@ohos/hypium';
import { resolveHostAddMode } from '../../../main/ets/services/HostAddModePolicy';

export default function hostAddModePolicyTest(): void {
  describe('HostAddModePolicy', (): void => {
    it('mobile_should_default_to_modern_mode', 0, (): void => {
      expect(resolveHostAddMode('', false)).assertEqual('modern');
    });

    it('mobile_should_keep_classic_preference', 0, (): void => {
      expect(resolveHostAddMode('classic', false)).assertEqual('classic');
    });

    it('desktop_should_always_use_classic_mode', 0, (): void => {
      expect(resolveHostAddMode('modern', true)).assertEqual('classic');
    });
  });
}
