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
  // 悬浮窗 / 小窗 / 悬浮模式 are what people call the orb too ("切到悬浮窗" must not go to the AI as a question).
  return /^(请)?(帮我)?(缩成|缩小成|进入|变成|切到|切换到|切换成|换成|改成|转成|收成|收起成|变回|回到)(悬浮球|悬浮窗|悬浮|小窗|小窗口)(模式)?(吧)?$/.test(text) ||
    /^(先)?(收起来|最小化|缩小|收起)(吧)?$/.test(text) || /^(悬浮球|悬浮窗|悬浮|小窗)模式(吧)?$/.test(text);
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
  // 新对话: the current one is kept in 对话记录, a new one starts (asked as a whole sentence, not "新对话在哪").
  if (/^(请|帮我|我们)?((开|开个|开一个|开始|开始一个|来个|来一个|换个|换一个|开启|开启一个|再开一个)新的?|新开(一个|个)?|新建(一个|个)?|新的?)(对话|会话|聊天|话题)(吧)?$/.test(t) ||
    /^(请|帮我)?(清空|清除|重置)(一下)?(当前|这个|这次)?的?(对话|会话|聊天)(记录)?(吧)?$/.test(t) ||
    /^(那就|我们)?(重新开始|重开|重来)(一个)?(对话|聊天)?(吧)?$/.test(t)) {
    return 'new';
  }
  if (new RegExp('^' + to + '(ai)?助理(模式)?(吧)?$').test(t)) { return 'assistant'; }
  if (new RegExp('^' + to + '(ai)?聊天(模式)?(吧)?$').test(t)) { return 'chat'; }
  if (aiQuestionIsFloat(question)) { return 'orb'; }
  if (aiQuestionIsGoodbye(question)) { return 'exit'; }
  return '';
}

/**
 * The answer above shows one card waiting for the user (打开「AI 配置」, 把「…」改为「…」): a short yes ("确认", "好的",
 * "打开吧", "确认打开 AI 配置" — also the AI's own suggestion pill) confirms it, a short no cancels it, right away, instead
 * of going to the AI again (which only says the card is there). 'confirm' · 'cancel' · '' (not about the card).
 */
export function aiPendingCardReply(question: string, cardTitle: string): string {
  const t: string = commandText(question).replace(/[「」『』“”"']/g, '');
  if (t === '' || t.length > 24) { return ''; }
  if (/^(不用了?|不要了?|取消|算了|先不|别|不)(打开|改|修改|执行|发|发送|连接|删除|删)?(了|吧|啦)?(谢谢)?$/.test(t)) { return 'cancel'; }
  if (/^(好|好的|好滴|行|可以|嗯|嗯嗯|对|是|是的|确认|确定|没问题|ok|okay|yes|同意|去吧|开吧|就这样)(的|吧|啊|呀|了|啦)?$/.test(t)) {
    return 'confirm';
  }
  const lead: RegExpExecArray | null = /^(请|帮我|那就|那|好的|好|行|可以|嗯)*(确认|确定|同意)?(帮我|给我)?/.exec(t);
  const said: boolean = lead !== null && lead[2] !== undefined;
  const rest: string = t.slice(lead !== null ? lead[0].length : 0).replace(/(吧|一下|了|啦)+$/, '');
  if (rest === '') { return said ? 'confirm' : ''; }
  // The card's own words ("打开 AI 配置" for 打开「AI 配置」), or just its verb ("打开吧", "确认修改").
  const title: string = commandText(cardTitle).replace(/[「」『』“”"']/g, '');
  if (rest.length >= 2 && (title === rest || title.startsWith(rest) || (said && title.indexOf(rest) >= 0))) { return 'confirm'; }
  if (/^(打开|修改|改|执行|连接|发送|发|删除|删|进入|继续|开)$/.test(rest)) { return 'confirm'; }
  return '';
}

/**
 * A feature request or an idea ("要是能……就好了", "希望能支持……", "把需求发给开发者"): 聊天 keeps the list
 * (manage_feature_requests), so it goes there from any mode. A fault report for the developer is not one.
 */
export function aiQuestionIsFeatureIdea(question: string): boolean {
  const t: string = question.trim().toLowerCase();
  if (t === '') { return false; }
  // What only a feature request says — even next to a fault ("老是断开，能不能加个自动重连"). "希望能连上" asks for
  // help, not a feature: 希望 counts only with 支持, 增加…; 能不能 only with 加个, 增加… ("能不能加速" is a question);
  // 需求 and 新功能 only when they are being asked for or sent ("我的需求是…", "需求文档", "有什么新功能" are not).
  if (/希望.{0,16}(支持|增加|加上|添加|新增|出个|做个|做一个)|(能不能|可不可以|可以不可以)(增加|添加|加个|加一个|做个|做一个|出个)|建议(增加|加上|支持|添加|做个|做一个)|需求.{0,4}(发给|告诉|交给|提交|整理)|(记下|记住|记一下)(这个|我的)?(需求|想法)|功能需求|功能建议|(想要|增加|添加|加个|加一个|做个|做一个)新功能|新功能(建议|需求)/.test(t)) {
    return true;
  }
  // Softer wording ("要是能……就好了", "希望有……") counts only when it is not about getting something working
  // ("要是能连上就好了", "希望能有办法解决断连") or a fault.
  return /(要是|如果)能.{0,24}就好|希望.{0,16}(能有|可以有)|希望有|想要(一个|个).{0,12}功能|我有(个|一个)想法|提(个|一个|点)(改进)?建议|提(个|一个)需求/.test(t) &&
    !/连上|连接|连得上|连通|解决|办法|修复|恢复|正常|报错|断连|加速|加密/.test(t) &&
    diagnosticAiAgentModeForQuestion(question) !== 'diagnose';
}

/**
 * Where a question asked in `mode` ('assistant' | 'chat') should go, or '' to stay. 聊天 hands over to 助理 only what
 * needs 助理's capture and mail flow (diagnosing the app, feedback); 助理 hands to 聊天 everything not about the app.
 * A question with added documents stays in 聊天.
 */
/**
 * A greeting or a word of thanks ("你好", "在吗", "谢谢", "你是谁"): either mode answers it where the user is — it is not
 * a task for the other one.
 */
export function aiQuestionIsSmallTalk(question: string): boolean {
  const t: string = commandText(question);
  if (t === '' || t.length > 12) { return false; }
  return /^(你好|您好|嗨|哈喽|哈啰|hello|hi|hey|在吗|在不在|在嘛|早|早安|早上好|上午好|中午好|下午好|晚上好|谢谢|多谢|谢啦|感谢|thanks|thankyou|你是谁|你叫什么|你叫什么名字|你能做什么|你会什么|你会做什么)(呀|啊|哦|哈|吗|呢|你|小艺|siri)*$/.test(t);
}

export function aiAutoRoute(question: string, mode: string, hasAttachments: boolean): string {
  if (question.trim() === '') { return ''; }
  if (aiQuestionIsSmallTalk(question)) { return ''; }
  if (aiQuestionIsFeatureIdea(question)) { return mode === 'chat' ? '' : 'chat'; }
  if (mode === 'chat') {
    if (hasAttachments || !aiQuestionIsAboutApp(question)) { return ''; }
    const agent: string = diagnosticAiAgentModeForQuestion(question);
    return agent === 'diagnose' || agent === 'feedback' ? 'assistant' : '';
  }
  return aiQuestionIsAboutApp(question) ? '' : 'chat';
}
