import { DiagnosticAiBundle } from './DiagnosticAiBundlePolicy';
import { DiagnosticAiResult } from './DiagnosticAiModels';

export interface DiagnosticAiMailDraft {
  subject: string;
  body: string;
}

/** Build a user-reviewed mail draft from already-redacted evidence only. */
export function diagnosticAiMailDraft(
  question: string,
  result: DiagnosticAiResult,
  bundle: DiagnosticAiBundle
): DiagnosticAiMailDraft {
  const safeQuestion: string = question.trim().slice(0, 240);
  const subject: string = 'RemoteDesktop AI 诊断：' +
    (safeQuestion === '' ? '问题反馈' : safeQuestion.slice(0, 48));
  const lines: string[] = [
    '这是由 RemoteDesktop 用户确认后生成的 AI 诊断草稿。',
    '',
    '问题描述：' + safeQuestion,
    '诊断结论：' + result.summary,
    '严重程度：' + result.severity,
    '置信度：' + Math.round(result.confidence * 100).toString() + '%',
    '知识版本：' + result.knowledgeVersion,
    '',
    '建议步骤：',
    ...result.recommendedReadOnlySteps.map((value: string): string => '- ' + value),
    '',
    '未确认项：',
    ...result.unknowns.map((value: string): string => '- ' + value),
    '',
    '诊断证据包（已脱敏、结构化、限时采集）：',
    bundle.text,
    '',
    '请在发送前检查收件人、正文和附件内容。RemoteDesktop 不会自动发送此邮件。'
  ];
  return { subject: subject, body: lines.join('\n') };
}
