import { describe, it, expect } from '@ohos/hypium';
import {
  shouldShowLoginAfterSilentAttempt,
  silentLoginFallbackMessage,
  SILENT_LOGIN_TIMEOUT_MS
} from '../main/ets/services/LoginStartupPolicy';

export default function loginStartupPolicyTest(): void {
  describe('LoginStartupPolicy', (): void => {
    it('always_releases_loading_after_an_empty_or_failed_silent_attempt', 0, (): void => {
      expect(shouldShowLoginAfterSilentAttempt(false)).assertTrue();
      expect(shouldShowLoginAfterSilentAttempt(true)).assertFalse();
      expect(silentLoginFallbackMessage(1001502002, false)).assertEqual('');
      expect(silentLoginFallbackMessage(0, true)).assertEqual('登录状态检查超时，请重新登录');
      expect(silentLoginFallbackMessage(1001502003, false)).assertEqual('登录状态已失效，请重新登录');
    });

    it('uses_a_bounded_silent_login_timeout', 0, (): void => {
      expect(SILENT_LOGIN_TIMEOUT_MS).assertEqual(8000);
    });
  });
}
