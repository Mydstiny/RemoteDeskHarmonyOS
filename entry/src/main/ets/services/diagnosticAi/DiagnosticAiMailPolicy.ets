import { DiagnosticAiResult } from './DiagnosticAiModels';

export interface DiagnosticAiMailDraft {
  subject: string;
  body: string;
}

/** What goes into a diagnosis mail besides the AI's result. */
export interface DiagnosticAiMailInput {
  question: string;
  /** The AI's answer; null when there is none yet (the mail then says so). */
  result: DiagnosticAiResult | null;
  /** Names of the attached files (the diagnostic log), already written by the caller. */
  attachmentNames: string[];
  /** The user's feature requests still waiting to be sent (they ride along with feedback). */
  featureRequests: string[];
  appVersion: string;
}

const SEVERITY: string[][] = [['info', '提示'], ['low', '低'], ['medium', '中'], ['high', '高'], ['unknown', '未知']];

function severityLabel(value: string): string {
  const pair: string[] | undefined = SEVERITY.find((item: string[]): boolean => item[0] === value);
  return pair !== undefined ? pair[1] : '未知';
}

/** 1. 2. 3. — one item a line, empty items dropped. */
function numbered(items: string[]): string[] {
  return items.map((item: string): string => item.trim()).filter((item: string): boolean => item !== '')
    .map((item: string, index: number): string => (index + 1).toString() + '. ' + item);
}

/**
 * A user-reviewed diagnosis mail, written for the developer to read quickly: the problem in one line, the
 * preliminary diagnosis (conclusion, severity, confidence), the detailed diagnosis (likely causes one by one, then the
 * technical reading), the suggested steps one at a time, what is still unknown, the user's pending feature requests,
 * and the attached log by name. The log itself is a file attachment — never pasted into the text.
 */
export function diagnosticAiMailDraft(input: DiagnosticAiMailInput): DiagnosticAiMailDraft {
  const question: string = input.question.trim().replace(/\s+/g, ' ').slice(0, 240);
  const subject: string = 'RemoteDesktop 问题反馈：' + (question === '' ? 'AI 诊断' : question.slice(0, 48));
  const result: DiagnosticAiResult | null = input.result;
  const lines: string[] = ['您好，以下是 RemoteDesktop 用户确认后由 AI 整理的问题反馈。', ''];
  let section: number = 0;
  const heading = (title: string): void => {
    section++;
    lines.push('一二三四五六七八九十'.charAt(section - 1) + '、' + title);
  };
  heading('问题概述');
  lines.push(question !== '' ? question : '（用户没有填写问题描述）', '');
  heading('初步诊断');
  if (result === null) {
    lines.push('AI 还没有完成分析，请参考附件中的诊断日志。', '');
  } else {
    lines.push(result.summary.trim() !== '' ? result.summary.trim() : '（AI 没有给出结论）');
    lines.push('严重程度：' + severityLabel(result.severity) + ' · 置信度：' +
      Math.round(Math.max(0, Math.min(1, result.confidence)) * 100).toString() + '%', '');
    const causes: string[] = numbered(result.hypotheses);
    const notes: string[] = (result.developerNotes ?? '').split('\n').map((line: string): string => line.trim())
      .filter((line: string): boolean => line !== '');
    if (causes.length > 0 || notes.length > 0) {
      heading('详细诊断');
      if (causes.length > 0) { lines.push('（一）可能的原因', ...causes); }
      if (notes.length > 0) {
        if (causes.length > 0) { lines.push(''); }
        lines.push(causes.length > 0 ? '（二）技术分析' : '技术分析', ...notes);
      }
      lines.push('');
    }
    const steps: string[] = numbered(result.recommendedReadOnlySteps);
    if (steps.length > 0) { heading('建议步骤'); lines.push(...steps, ''); }
    const unknowns: string[] = numbered(result.unknowns);
    if (unknowns.length > 0) { heading('尚未确认'); lines.push(...unknowns, ''); }
  }
  const requests: string[] = numbered(input.featureRequests);
  if (requests.length > 0) { heading('用户提出的功能需求'); lines.push(...requests, ''); }
  if (input.attachmentNames.length > 0) {
    heading('附件');
    input.attachmentNames.forEach((name: string): void => {
      lines.push('- ' + name + '：诊断日志（已脱敏、结构化、限时采集）');
    });
    lines.push('');
  }
  lines.push('---', 'App 版本：' + input.appVersion + (result !== null && result.knowledgeVersion !== '' ?
    ' · 知识版本：' + result.knowledgeVersion : ''),
    '请在发送前检查收件人、正文和附件。RemoteDesktop 不会自动发送此邮件。');
  return { subject: subject, body: lines.join('\n') };
}

/** The mail that sends the user's collected feature requests to the developer. */
export function aiFeatureRequestMail(requests: string[], note: string, appVersion: string): DiagnosticAiMailDraft {
  const items: string[] = numbered(requests);
  const lines: string[] = ['您好，以下是我在使用 RemoteDesktop 时希望增加或改进的功能（由 AI 助理整理）：', '', ...items];
  if (note.trim() !== '') { lines.push('', '补充说明：', note.trim()); }
  lines.push('', '---', 'App 版本：' + appVersion, '请在发送前检查内容。RemoteDesktop 不会自动发送此邮件。');
  return { subject: 'RemoteDesktop 功能需求（' + items.length.toString() + ' 条）', body: lines.join('\n') };
}
