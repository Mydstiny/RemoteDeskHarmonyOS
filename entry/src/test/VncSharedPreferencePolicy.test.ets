import { describe, it, expect } from '@ohos/hypium';
import {
  resolveVncReverseWheel,
  shouldMigrateLegacyVncReverseWheel
} from '../main/ets/services/VncSharedPreferencePolicy';

export default function vncSharedPreferencePolicyTest(): void {
  describe('VncSharedPreferencePolicy', (): void => {
    it('uses_the_shared_personalization_key_when_present', 0, (): void => {
      expect(resolveVncReverseWheel(true, false, true).value).assertFalse();
      expect(resolveVncReverseWheel(true, false, true).source).assertEqual('shared');
      expect(shouldMigrateLegacyVncReverseWheel(true)).assertFalse();
    });

    it('reads_the_legacy_vnc_value_only_when_shared_state_is_absent', 0, (): void => {
      expect(resolveVncReverseWheel(false, false, true).value).assertTrue();
      expect(resolveVncReverseWheel(false, false, true).source).assertEqual('legacy');
      expect(resolveVncReverseWheel(false, false, false).source).assertEqual('default');
      expect(shouldMigrateLegacyVncReverseWheel(false)).assertTrue();
    });
  });
}
