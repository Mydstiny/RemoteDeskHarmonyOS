import { describe, it, expect } from '@ohos/hypium';
import {
  resolveSshAuthPromptGeneration,
  resolveSshAuthPromptSessionId
} from '../main/ets/services/ssh/auth/SshAuthPromptOwnerPolicy';

export default function sshAuthPromptOwnerPolicyTest(): void {
  describe('SshAuthPromptOwnerPolicy', (): void => {
    it('should_prefer_detached_pending_connect_identity', 0, (): void => {
      const sessionId: number = resolveSshAuthPromptSessionId(41, -1, -1);
      expect(sessionId).assertEqual(41);
      expect(resolveSshAuthPromptGeneration(sessionId, 41, 7, -1, 0, 0))
        .assertEqual(7);
    });

    it('should_preserve_foreground_and_attached_fallbacks', 0, (): void => {
      expect(resolveSshAuthPromptSessionId(0, 12, 9)).assertEqual(12);
      expect(resolveSshAuthPromptGeneration(12, 0, 0, 9, 3, 5)).assertEqual(5);
      expect(resolveSshAuthPromptSessionId(0, -1, 9)).assertEqual(9);
      expect(resolveSshAuthPromptGeneration(9, 0, 0, 9, 3, 5)).assertEqual(3);
    });

    it('should_reject_missing_or_unusable_identity', 0, (): void => {
      expect(resolveSshAuthPromptSessionId(0, -1, -1)).assertEqual(0);
      expect(resolveSshAuthPromptGeneration(0, 0, 0, -1, 0, 4)).assertEqual(0);
      expect(resolveSshAuthPromptGeneration(8, 0, 0, -1, 0, 0)).assertEqual(0);
    });
  });
}
