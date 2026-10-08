import { describe, expect, it } from '@ohos/hypium';
import { diagnosticAiAgentModeForQuestion, diagnosticAiAgentModeLabel } from '../main/ets/services/diagnosticAi/DiagnosticAiAgentService';

export default function diagnosticAiAgentPolicyTest(): void {
  describe('DiagnosticAiAgentPolicy', (): void => {
    it('answers_app_usage_without_starting_capture', 0, (): void => {
      expect(diagnosticAiAgentModeForQuestion('如何添加第一台 RDP 主机？')).assertEqual('answer');
      expect(diagnosticAiAgentModeLabel('answer')).assertEqual('询问 AI');
    });

    it('routes_safe_setting_requests_to_configure', 0, (): void => {
      expect(diagnosticAiAgentModeForQuestion('帮我打开主机页 AI 入口')).assertEqual('configure');
      expect(diagnosticAiAgentModeLabel('configure')).assertEqual('帮我设置');
    });

    it('requires_diagnostic_capture_for_error_questions', 0, (): void => {
      expect(diagnosticAiAgentModeForQuestion('RDP 连接后黑屏，帮我诊断')).assertEqual('diagnose');
      expect(diagnosticAiAgentModeLabel('diagnose')).assertEqual('诊断问题');
    });

    it('keeps_developer_mail_as_a_separate_consent_path', 0, (): void => {
      expect(diagnosticAiAgentModeForQuestion('把这个错误邮件发给开发者')).assertEqual('feedback');
      expect(diagnosticAiAgentModeLabel('feedback')).assertEqual('反馈给开发者');
    });
  });
}
