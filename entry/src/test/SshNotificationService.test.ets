import { describe, it, expect } from '@ohos/hypium';
import {
  buildSshCompletionNotificationText,
  sshCompletionNotificationAllowed
} from '../main/ets/services/ssh/notification/SshNotificationService';

export default function sshNotificationServiceTest(): void {
  describe('SshNotificationService', (): void => {
    it('should_only_notify_failures_or_long_commands', 0, (): void => {
      expect(sshCompletionNotificationAllowed({
        hostLabel: 'prod', exitCode: 0, durationMs: 100
      })).assertFalse();
      expect(sshCompletionNotificationAllowed({
        hostLabel: 'prod', exitCode: 0, durationMs: 5000
      })).assertTrue();
      expect(sshCompletionNotificationAllowed({
        hostLabel: 'prod', exitCode: 7, durationMs: 100
      })).assertTrue();
    });

    it('text_should_not_include_command_or_network_identity', 0, (): void => {
      const text = buildSshCompletionNotificationText({
        hostLabel: 'prod', exitCode: 7, durationMs: 6200
      });
      expect(text.indexOf('退出码 7') >= 0).assertTrue();
      expect(text.indexOf('ssh')).assertEqual(-1);
      expect(text.indexOf('/')).assertEqual(-1);
    });
  });
}
