import { describe, it, expect } from '@ohos/hypium';
import {
  buildSshBackgroundNotificationContent,
  buildSshCompletionNotificationText,
  ensureSshNotificationEnabled,
  nextSshCompletionNotificationId,
  SshBackgroundNotificationContent,
  sshCompletionNotificationAllowed
} from '../main/ets/services/ssh/notification/SshNotificationService';

export default function sshNotificationServiceTest(): void {
  describe('SshNotificationService', (): void => {
    it('should_only_notify_failures_or_long_commands', 0, (): void => {
      expect(sshCompletionNotificationAllowed({
        enabled: true, hostLabel: 'prod', exitCode: 0, durationMs: 100
      })).assertFalse();
      expect(sshCompletionNotificationAllowed({
        enabled: true, hostLabel: 'prod', exitCode: 0, durationMs: 5000
      })).assertTrue();
      expect(sshCompletionNotificationAllowed({
        enabled: true, hostLabel: 'prod', exitCode: 7, durationMs: 100
      })).assertTrue();
      expect(sshCompletionNotificationAllowed({
        enabled: false, hostLabel: 'prod', exitCode: 7, durationMs: 100
      })).assertFalse();
    });

    it('text_should_not_include_command_or_network_identity', 0, (): void => {
      const text = buildSshCompletionNotificationText({
        enabled: true, hostLabel: 'prod', exitCode: 7, durationMs: 6200
      });
      expect(text.indexOf('退出码 7') >= 0).assertTrue();
      expect(text.indexOf('ssh')).assertEqual(-1);
      expect(text.indexOf('/')).assertEqual(-1);
    });

    it('should_allocate_distinct_bounded_ids_for_concurrent_sessions', 0, (): void => {
      const first: number = nextSshCompletionNotificationId(0);
      const second: number = nextSshCompletionNotificationId(first);
      expect(first).assertEqual(606101);
      expect(second).assertEqual(606102);
      expect(nextSshCompletionNotificationId(607124)).assertEqual(first);
      expect(nextSshCompletionNotificationId(Number.NaN)).assertEqual(first);
    });

    it('authorization_should_skip_prompt_when_already_enabled', 0,
      async (): Promise<void> => {
        let requests: number = 0;
        const enabled: boolean = await ensureSshNotificationEnabled(
          async (): Promise<boolean> => true,
          async (): Promise<void> => { requests++; });
        expect(enabled).assertTrue();
        expect(requests).assertEqual(0);
      });

    it('authorization_should_verify_user_acceptance_before_enabling', 0,
      async (): Promise<void> => {
        let enabled: boolean = false;
        let requests: number = 0;
        const result: boolean = await ensureSshNotificationEnabled(
          async (): Promise<boolean> => enabled,
          async (): Promise<void> => {
            requests++;
            enabled = true;
          });
        expect(result).assertTrue();
        expect(requests).assertEqual(1);
      });

    it('authorization_should_fail_closed_after_denial', 0,
      async (): Promise<void> => {
        let checks: number = 0;
        const result: boolean = await ensureSshNotificationEnabled(
          async (): Promise<boolean> => {
            checks++;
            return false;
          },
          async (): Promise<void> => { throw new Error('denied'); });
        expect(result).assertFalse();
        expect(checks).assertEqual(2);
      });

    it('background_text_should_expose_counts_without_host_identity', 0, (): void => {
      const content: SshBackgroundNotificationContent =
        buildSshBackgroundNotificationContent(2, 1);
      const visible: string = content.title + ' ' + content.text;
      expect(content.text).assertEqual('保持 2 个 SSH 连接，1 个后台受限');
      expect(visible.indexOf('root@10.0.0.8:22')).assertEqual(-1);
      expect(visible.indexOf('/remote/private')).assertEqual(-1);

      const limited: SshBackgroundNotificationContent =
        buildSshBackgroundNotificationContent(0, 1);
      expect(limited.title).assertEqual('SSH 后台受限');
      expect(limited.text).assertEqual('后台受限，未保持持续连接');
    });
  });
}
