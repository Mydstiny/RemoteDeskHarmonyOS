import { DiagnosticAiProviderProfile, DiagnosticAiResult } from './DiagnosticAiModels';
import { DiagnosticAiProviderService, DiagnosticAiAssistInput } from './DiagnosticAiProviderService';
import { diagnosticAiKnowledgeSnapshot } from './DiagnosticAiKnowledgeBase';

export type DiagnosticAiAgentMode = 'answer' | 'configure' | 'diagnose' | 'feedback';

export interface DiagnosticAiAgentRequest {
  mode: DiagnosticAiAgentMode;
  question: string;
  history: string;
  bundle: string;
  assistantContext?: string;
}

/** Intent is a safety boundary, not a request to let the model choose arbitrary tools. */
export function diagnosticAiAgentModeForQuestion(question: string): DiagnosticAiAgentMode {
  const value = question.trim().toLowerCase();
  if (value.indexOf('邮件') >= 0 || value.indexOf('反馈') >= 0 || value.indexOf('开发者') >= 0 || value.indexOf('发送错误') >= 0) {
    return 'feedback';
  }
  if (value.indexOf('诊断') >= 0 || value.indexOf('日志') >= 0 || value.indexOf('报错') >= 0 || value.indexOf('错误') >= 0 ||
      value.indexOf('失败') >= 0 || value.indexOf('黑屏') >= 0 || value.indexOf('卡顿') >= 0 || value.indexOf('连不上') >= 0 ||
      value.indexOf('连接不上') >= 0 || value.indexOf('崩溃') >= 0 || value.indexOf('异常') >= 0) {
    return 'diagnose';
  }
  if (value.indexOf('帮我设置') >= 0 || value.indexOf('帮我打开') >= 0 || value.indexOf('帮我关闭') >= 0 ||
      value.indexOf('启用') >= 0 || value.indexOf('关闭') >= 0 || value.indexOf('调整') >= 0 || value.indexOf('改成') >= 0 ||
      value.indexOf('配置') >= 0) {
    return 'configure';
  }
  return 'answer';
}

export function diagnosticAiAgentModeLabel(mode: DiagnosticAiAgentMode): string {
  switch (mode) {
    case 'configure': return '帮我设置';
    case 'diagnose': return '诊断问题';
    case 'feedback': return '反馈给开发者';
    default: return '询问 AI';
  }
}

export class DiagnosticAiAgentService {
  private readonly provider: DiagnosticAiProviderService = new DiagnosticAiProviderService();

  private boundedBundle(bundle: string): string {
    const limit: number = 48000;
    if (bundle.length <= limit) { return bundle; }
    // Keep both the capture header and the newest events. The full redacted bundle remains local for retry/export;
    // the Provider request must stay below common domestic context/request limits.
    const half: number = Math.floor(limit / 2);
    return bundle.slice(0, half) + '\n{"truncatedForProvider":true,"originalBytes":' + bundle.length.toString() + '}\n' +
      bundle.slice(-half);
  }

  async respond(profile: DiagnosticAiProviderProfile, secret: string,
    request: DiagnosticAiAgentRequest): Promise<DiagnosticAiResult> {
    const input: DiagnosticAiAssistInput = {
      mode: request.mode, question: request.question.trim().slice(0, 4000),
      history: request.history.slice(-8000), bundle: this.boundedBundle(request.bundle),
      knowledge: diagnosticAiKnowledgeSnapshot(), assistantContext: request.assistantContext ?? ''
    };
    return await this.provider.assist(profile, secret, input);
  }
}
