import { diagnosticAiSettingIntents } from './DiagnosticAiSettingsActionPolicy';

/**
 * 助理 or 聊天: which mode a question belongs to. The answer is only ever a suggestion the user taps — the
 * conversation never switches by itself. In 聊天, a question about the app itself (its connections, hosts, settings,
 * logs) is better handled by 助理, which can read and change them; in 助理, a general task (writing, translating, a
 * document) is better in 聊天, which has the document tools.
 */

/** Words that only make sense for this app. */
const APP_WORDS: string[] = ['remotedesktop', 'remote desktop', '远程桌面', 'rdp', 'rustdesk', 'vnc', 'moonlight', 'sunshine',
  'sftp', 'ssh', '串流', '主机列表', '这台主机', '我的主机', '添加主机', '连接主机', '远程连接', '远程控制', '抓日志', '抓取日志', '诊断日志',
  '这个应用', '这个app', '本应用', '这个软件', 'ai 配置', 'ai配置', '辅助 ai', '云同步', '主机同步', '跳板机', '网关', '剪贴板同步',
  '远端', '被控端', '控制端', '私钥', '主机指纹'];

/** Words of a general task the chat's tools are for. */
const TASK_WORDS: string[] = ['写一', '写个', '写份', '写篇', '帮我写', '起草', '草拟', '润色', '改写', '续写', '扩写', '缩写', '翻译',
  '总结', '摘要', '概括', '提炼', '整理成', '做个表', '做一张表', '表格', '周报', '日报', '月报', '简历', '邮件草稿', '写邮件', '文案',
  '作文', '诗', '故事', '演讲稿', '方案', '计划书', '大纲', 'ppt', 'word', 'excel', 'wps', '文档', 'docx', 'xlsx', 'pdf',
  '解释一下', '是什么意思', '帮我算', '计算', '食谱', '旅行', '攻略', '推荐几', '学习计划'];

function hits(text: string, words: string[]): number {
  return words.filter((word: string): boolean => text.indexOf(word) >= 0).length;
}

/** Whether a question is about the app itself (its connections, hosts, settings or logs). */
export function aiQuestionIsAboutApp(question: string): boolean {
  const text: string = question.trim().toLowerCase();
  if (text === '') { return false; }
  if (hits(text, APP_WORDS) > 0) { return true; }
  // "把画质调成速度优先" names no app word but is one of the app's own settings.
  return diagnosticAiSettingIntents(question).length > 0;
}

/** Whether a question is a general task (writing, translating, a document) rather than anything about the app. */
export function aiQuestionIsGeneralTask(question: string): boolean {
  const text: string = question.trim().toLowerCase();
  return text !== '' && hits(text, TASK_WORDS) > 0 && !aiQuestionIsAboutApp(question);
}

/**
 * The mode to suggest for a question asked in `mode` ('assistant' | 'chat'), or '' to keep it where it is. A question
 * with added documents stays in chat.
 */
export function aiRouteSuggestion(question: string, mode: string, hasAttachments: boolean): string {
  if (mode === 'chat') {
    return !hasAttachments && aiQuestionIsAboutApp(question) ? 'assistant' : '';
  }
  return aiQuestionIsGeneralTask(question) ? 'chat' : '';
}
