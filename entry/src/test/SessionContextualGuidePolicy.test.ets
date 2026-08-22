import { describe, expect, it } from '@ohos/hypium';
import {
  sessionContextualGuide,
  shouldRetrySessionContextualGuide,
  shouldShowSessionContextualGuide
} from '../main/ets/services/SessionContextualGuidePolicy';

export default function sessionContextualGuidePolicyTest(): void {
  describe('SessionContextualGuidePolicy', (): void => {
    it('shows_only_once_after_the_session_is_ready', 0, (): void => {
      expect(shouldShowSessionContextualGuide(true, false, false)).assertTrue();
      expect(shouldShowSessionContextualGuide(false, false, false)).assertFalse();
      expect(shouldShowSessionContextualGuide(true, true, false)).assertFalse();
      expect(shouldShowSessionContextualGuide(true, false, true)).assertFalse();
      expect(shouldRetrySessionContextualGuide(true, false)).assertTrue();
      expect(shouldRetrySessionContextualGuide(false, false)).assertFalse();
      expect(shouldRetrySessionContextualGuide(true, true)).assertFalse();
    });

    it('uses_short_device_specific_entries', 0, (): void => {
      const sshPhone = sessionContextualGuide('ssh', 'phone');
      const moonlightPc = sessionContextualGuide('moonlight', 'desktop');
      expect(sshPhone.message.indexOf('SFTP') >= 0).assertTrue();
      expect(sshPhone.message.indexOf('会话工具') >= 0).assertTrue();
      expect(moonlightPc.message.indexOf('顶部工具栏') >= 0).assertTrue();
      expect(moonlightPc.message.length < 60).assertTrue();
      expect(sshPhone.storageKey === moonlightPc.storageKey).assertFalse();
    });
  });
}
