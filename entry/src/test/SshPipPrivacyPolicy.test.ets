import { describe, it, expect } from '@ohos/hypium';
import { sshPipPublicStatus } from
  '../main/ets/services/ssh/observability/SshPipPrivacyPolicy';

export default function sshPipPrivacyPolicyTest(): void {
  describe('SshPipPrivacyPolicy', (): void => {
    it('should_allow_only_fixed_public_status_text', 0, (): void => {
      expect(sshPipPublicStatus('后台保留')).assertEqual('后台保留');
      expect(sshPipPublicStatus('已连接')).assertEqual('已连接');

      const sensitive: string = sshPipPublicStatus(
        'root@10.0.0.8:22 /remote/private password=never-log-this');
      expect(sensitive).assertEqual('已连接');
      expect(sensitive.indexOf('10.0.0.8')).assertEqual(-1);
      expect(sensitive.indexOf('/remote/private')).assertEqual(-1);
      expect(sensitive.indexOf('never-log-this')).assertEqual(-1);
    });
  });
}
