import { diagnosticAiSettingIntents } from './DiagnosticAiSettingsActionPolicy';
import { diagnosticAiAgentModeForQuestion } from './DiagnosticAiAgentService';

/**
 * 助理 or 聊天: which mode a question belongs to. 助理 is for the app itself — diagnosing a connection, capturing
 * logs, sending feedback, how the app works and its settings; 聊天 does everything else with all the tools (documents,
 * the phone's functions, the web, the app's data). Each mode hands a question to the other by itself.
 */

/** Words that only make sense for this app. */
const APP_WORDS: string[] = ['remotedesktop', 'remote desktop', '远程桌面', 'rdp', 'rustdesk', 'vnc', 'moonlight', 'sunshine',
  'sftp', 'ssh', '串流', '主机列表', '这台主机', '我的主机', '添加主机', '连接主机', '远程连接', '远程控制', '抓日志', '抓取日志', '诊断日志',
  '这个应用', '这个app', '本应用', '这个软件', 'ai 配置', 'ai配置', '辅助 ai', '云同步', '主机同步', '跳板机', '网关', '剪贴板同步',
  '远端', '被控端', '控制端', '私钥', '主机指纹', 'ai设置', 'ai 设置', 'ai 助理', 'ai助理', 'ai 动效', 'ai动效', '思考动画',
  '悬浮球', 'ai 语音', 'ai语音', '朗读引擎', '深色模式', '浅色模式', '主题色', '光晕', '应用图标', '设置页'];

/** Words of a general task the chat's tools are for. */
const TASK_WORDS: string[] = ['写一', '写个', '写份', '写篇', '帮我写', '起草', '草拟', '润色', '改写', '续写', '扩写', '缩写', '翻译',
  '总结', '摘要', '概括', '提炼', '整理成', '做个表', '做一张表', '表格', '周报', '日报', '月报', '简历', '邮件草稿', '写邮件', '文案',
  '作文', '诗', '故事', '演讲稿', '方案', '计划书', '大纲', 'ppt', 'word', 'excel', 'wps', '文档', 'docx', 'xlsx', 'pdf',
  '解释一下', '是什么意思', '帮我算', '计算', '食谱', '旅行', '攻略', '推荐几', '学习计划',
  '提醒我', '日程', '日历', '打电话', '给他打', '给她打', '导航', '怎么去', '剪贴板', '刚复制', '手电筒', '电量', '识别图片'];

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

/**
 * "缩成悬浮球" / "进入悬浮球模式" / "先收起来" / "最小化": the AI surface floats as the orb — done at once by the app,
 * whatever mode it is in (悬浮球 is also an app word for its 动效 setting, so this is checked before any routing).
 */
export function aiQuestionIsFloat(question: string): boolean {
  const text: string = question.trim().replace(/[。！!，,？?\s]/g, '');
  return /^(请)?(帮我)?(缩成|缩小成|进入|变成|切到|切换到|切换成|收成|收起成|变回)悬浮球(模式)?(吧)?$/.test(text) ||
    /^(先)?(收起来|最小化|缩小|收起)(吧)?$/.test(text) || /^悬浮球模式$/.test(text);
}

function commandText(question: string): string {
  return question.trim().toLowerCase().replace(/[。！!，,？?、\s~～…\.]/g, '');
}

/**
 * "拜拜" / "再见" / "退出" / "就这样吧" / "没事了谢谢": the user is done with the AI — it closes, from any mode. Only
 * short sentences count ("怎么跟同事说再见" is a question).
 */
export function aiQuestionIsGoodbye(question: string): boolean {
  const t: string = commandText(question);
  if (t === '' || t.length > 14) { return false; }
  if (/拜拜|再见|拜了|回见|byebye|^bye|晚安/.test(t)) { return true; }
  return /^(好的|好|那|那就|行|嗯|ok)?(退出|关闭|关掉|结束|关了|退了)(吧)?(ai|助手|助理|对话|了)?(吧|了)?$/.test(t) ||
    /^(好了|好的|好|行|嗯|ok)?(谢谢|多谢|谢啦)?(你)?(就这样|先这样|没事了|没别的了|没有了|不用了)(吧|了|啦)?(谢谢|多谢|谢啦)?(你)?$/.test(t);
}

/**
 * A command to change the AI's mode, said or typed in any mode: 'text' (回到文字 / 我要打字 / 退出语音), 'voice'
 * (语音模式), 'assistant' (切到助理), 'chat' (切到聊天), 'orb' (悬浮球), 'exit' (拜拜, 退出) — or '' for anything else.
 */
export function aiModeCommand(question: string): string {
  const t: string = commandText(question);
  if (t === '' || t.length > 16) { return ''; }
  const to: string = '(请|帮我)?(回到|回|切到|切回|切换到|切换回|切换成|换成|换回|换到|改成|改回|转到|转成|变成|变回|返回|用|进入|打开|开启|交给)';
  if (new RegExp('^' + to + '(文字|文本|打字|键盘|输入框|文字聊天|聊天界面)(模式|输入|聊天|对话)?(吧)?$').test(t) ||
    /^(退出|关闭|关掉|不用|结束|停止)语音(模式|对话|聊天)?(吧)?$/.test(t) || /^我(要|想)(打字|用文字|文字聊)/.test(t) ||
    /^(文字|打字)模式(吧)?$/.test(t)) {
    return 'text';
  }
  if (new RegExp('^' + to + '语音(模式|对话|聊天)?(吧)?$').test(t) || /^(跟我|和我)?语音(聊天|对话)(吧)?$/.test(t) ||
    /^语音模式(吧)?$/.test(t)) {
    return 'voice';
  }
  if (new RegExp('^' + to + '(ai)?助理(模式)?(吧)?$').test(t)) { return 'assistant'; }
  if (new RegExp('^' + to + '(ai)?聊天(模式)?(吧)?$').test(t)) { return 'chat'; }
  if (aiQuestionIsFloat(question)) { return 'orb'; }
  if (aiQuestionIsGoodbye(question)) { return 'exit'; }
  return '';
}

/**
 * Where a question asked in `mode` ('assistant' | 'chat') should go, or '' to stay. 聊天 hands over to 助理 only what
 * needs 助理's capture and mail flow (diagnosing the app, feedback); 助理 hands to 聊天 everything not about the app.
 * A question with added documents stays in 聊天.
 */
export function aiAutoRoute(question: string, mode: string, hasAttachments: boolean): string {
  if (question.trim() === '') { return ''; }
  if (mode === 'chat') {
    if (hasAttachments || !aiQuestionIsAboutApp(question)) { return ''; }
    const agent: string = diagnosticAiAgentModeForQuestion(question);
    return agent === 'diagnose' || agent === 'feedback' ? 'assistant' : '';
  }
  return aiQuestionIsAboutApp(question) ? '' : 'chat';
}
