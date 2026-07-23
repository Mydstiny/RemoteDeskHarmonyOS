import { describe, it, expect } from '@ohos/hypium';
import {
  sensitiveDataState,
  sensitiveWriteRequiresUnlock,
  shouldRedactLockedCiphertext
} from '../main/ets/services/SensitiveDataStatePolicy';

export default function sensitiveDataStatePolicyTest(): void {
  describe('SensitiveDataStatePolicy', (): void => {
    it('distinguishes_disabled_from_configured_but_locked', 0, (): void => {
      expect(sensitiveDataState(false, false)).assertEqual('disabled');
      expect(sensitiveDataState(true, false)).assertEqual('locked');
      expect(sensitiveDataState(true, true)).assertEqual('unlocked');
    });

    it('rejects_sensitive_writes_only_while_a_configured_store_is_locked', 0, (): void => {
      expect(sensitiveWriteRequiresUnlock(false, false)).assertFalse();
      expect(sensitiveWriteRequiresUnlock(true, false)).assertTrue();
      expect(sensitiveWriteRequiresUnlock(true, true)).assertFalse();
      expect(shouldRedactLockedCiphertext(true, false, true)).assertTrue();
      expect(shouldRedactLockedCiphertext(true, false, false)).assertFalse();
    });
  });
}
