import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DiagnosticAiProviderProfile, DiagnosticAiUsageMetadata } from './DiagnosticAiModels';
import { diagnosticAiProviderIsHarmonyLocal, diagnosticAiProviderManifest } from './DiagnosticAiProviderCatalog';
import { DiagnosticAiProviderService, diagnosticAiEstimateTokens, diagnosticAiResponseMessage, diagnosticAiResponseText, diagnosticAiResponseUsage } from './DiagnosticAiProviderService';
import { AI_MODE_CHAT, DiagnosticAiRequestLog } from './DiagnosticAiRequestLog';
import { AiAttachment, AiDocument, aiCreateDocument, aiDocumentErrorText, aiDocumentKindLabel, aiReadDocument, aiRewriteDocument } from './AiDocumentService';
import { DiagnosticAiFeatureRequest } from './DiagnosticAiConversationStore';
import { DiagnosticAiMailDraft, aiFeatureRequestMail } from './DiagnosticAiMailPolicy';
import { CURRENT_RELEASE_VERSION } from '../ReleaseNotesRegistry';
import { aiAppGuide } from './DiagnosticAiKnowledgeBase';
import { AiSkill, AiToolSpec, aiSkillsForQuestion, aiToolByFunction, aiToolStatus } from './AiSkillCatalog';
import { AI_CONFIRM_TOOLS, AiChatAction, aiActionFor, aiRunSystemTool } from './AiSystemTools';
import { AiSettingChoice, AiSettingSpec, diagnosticAiSettingCurrent, diagnosticAiSettingSpec, diagnosticAiSettingValueLabel } from './DiagnosticAiSettingsActionPolicy';
import { diagnosticAiAppActionId, diagnosticAiAppActionTarget } from './DiagnosticAiAppActionPolicy';
import { AI_ASSISTANT_HANDOFF, AI_FLOAT_REQUEST, AI_MODE_REQUEST } from './AiBridgeKeys';
import { aiReadWebpage, aiWebSearch } from './AiWebTools';
import { AiTriageHost, DiagnosticAiHostBridge } from './DiagnosticAiTriagePolicy';


/** A setting's choice as the model wrote it: the stored value, its label, or 开/关 words for a switch. */
function settingChoice(spec: AiSettingSpec, raw: string): AiSettingChoice | undefined {
  const value: string = raw.trim().toLowerCase();
  if (spec.isBoolean()) {
    if (['true', 'on', '1', 'yes', '开启', '打开', '启用', '开'].indexOf(value) >= 0) { return spec.choices[0]; }
    if (['false', 'off', '0', 'no', '关闭', '停用', '禁用', '关'].indexOf(value) >= 0) { return spec.choices[1]; }
  }
  return spec.choices.find((choice: AiSettingChoice): boolean =>
    choice.value.toLowerCase() === value || choice.label.toLowerCase() === value);
}

/**
 * 聊天模式: the assistant as a general chatbot. It sees what the user typed, the documents the user added, and — only
 * through the tools the user left on in 设置 › AI 工具与技能 — the app's hosts, connection log, settings and AI usage.
 * It writes documents (Word, Excel, Markdown, text) with create_document; models without tool calling write a
 * <document> block instead and get a snapshot of the app data they need, so every model can do the same tasks.
 * Installed skills tell it how to do common tasks (周报, 会议纪要, 翻译…).
 */

const CHAT_READ_TIMEOUT_MS: number = 180000;
const MAX_TOOL_ROUNDS: number = 5;
/** Characters of the added documents put into one request (the rest is read on with read_attachment). */
const ATTACHMENT_BUDGET: number = 32000;
const ATTACHMENT_BUDGET_NO_TOOLS: number = 48000;
const READ_CHUNK: number = 12000;
const HISTORY_BUDGET: number = 24000;
const LOCAL_BUDGET: number = 3600;

export class AiChatTurn {
  role: string;
  content: string;

  constructor(role: string, content: string) {
    this.role = role;
    this.content = content;
  }
}

/** One saved conversation, as list_conversations shows it. */
export class AiConversationRow {
  id: string;
  title: string;
  /** 聊天 or 助理 */
  kind: string;
  updatedAt: number;
  turns: number;
  documents: number;

  constructor(id: string, title: string, kind: string, updatedAt: number, turns: number, documents: number) {
    this.id = id;
    this.title = title;
    this.kind = kind;
    this.updatedAt = updatedAt;
    this.turns = turns;
    this.documents = documents;
  }
}

/**
 * The app data the tools read and change, for this account (the chat view fills it from the app). The reads come
 * already in words for the model.
 */
export interface AiChatAppData {
  hosts: (protocol: string) => string;
  connections: (days: number) => string;
  settings: () => string;
  usage: (days: number) => string;
  /** The documents the AI wrote, newest first, that are still on the device. */
  documents: () => AiDocument[];
  /** Saved conversations, newest first; and the one going on now ('' none). */
  conversations: () => AiConversationRow[];
  currentConversation: () => string;
  /** 记忆: what the user asked the AI to keep (one note a line), whether it is on, and saving it. */
  memory: () => string;
  memoryEnabled: () => boolean;
  saveMemory: (text: string) => boolean;
  /** 需求收集: the user's feature requests (sent ones too), adding one (false: empty or already waiting), removing. */
  featureRequests: () => DiagnosticAiFeatureRequest[];
  addFeatureRequest: (text: string) => boolean;
  removeFeatureRequests: (text: string) => number;
}

function timeLabel(time: number): string {
  const d: Date = new Date(time);
  const pad = (value: number): string => (value < 10 ? '0' : '') + value.toString();
  return d.getFullYear().toString() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' +
    pad(d.getMinutes());
}

/** The one item whose name is `wanted` (exactly, or else the only one containing it); a string says why not. */
function pickByName<T>(items: T[], nameOf: (item: T) => string, wanted: string, what: string): T | string {
  const key: string = wanted.replace(/[《》「」"]/g, '').trim().toLowerCase();
  if (key === '') { return '没有给出' + what + '名称。'; }
  const exact: T[] = items.filter((item: T): boolean => nameOf(item).toLowerCase() === key);
  if (exact.length === 1) { return exact[0]; }
  const near: T[] = exact.length > 1 ? exact : items.filter((item: T): boolean => {
    const name: string = nameOf(item).toLowerCase();
    return name.indexOf(key) >= 0 || key.indexOf(name.replace(/\.[a-z]+$/, '')) >= 0;
  });
  if (near.length === 1) { return near[0]; }
  if (near.length === 0) { return '没有找到名为「' + wanted + '」的' + what + '。'; }
  return '有好几个' + what + '符合：' + near.slice(0, 6).map((item: T): string => '「' + nameOf(item) + '」').join('、') +
    '。请问用户指的是哪一个。';
}

/** 记忆 changed as update_memory asks (one note a line): [the new memory, what happened, in words]. */
export function aiMemoryEdit(memory: string, action: string, text: string, old: string): string[] {
  const lines: string[] = memory.split('\n').map((line: string): string => line.trim()).filter((line: string): boolean => line !== '');
  const note: string = text.trim().replace(/\s+/g, ' ').slice(0, 200);
  const matches = (line: string, what: string): boolean => {
    const a: string = line.toLowerCase();
    const b: string = what.trim().toLowerCase();
    return b !== '' && (a.indexOf(b) >= 0 || b.indexOf(a) >= 0);
  };
  if (action === 'clear') { return ['', '已清空记忆。']; }
  if (action === 'add') {
    if (note === '') { return [memory, '没有要记住的内容。']; }
    if (lines.some((line: string): boolean => line === note)) { return [memory, '这件事已经记着了。']; }
    return [lines.concat([note]).join('\n'), '已记住：' + note];
  }
  if (action === 'remove') {
    const kept: string[] = lines.filter((line: string): boolean => !matches(line, note));
    if (kept.length === lines.length) { return [memory, '记忆里没有和「' + note + '」相关的内容。']; }
    return [kept.join('\n'), '已忘掉 ' + (lines.length - kept.length).toString() + ' 条：' +
      lines.filter((line: string): boolean => matches(line, note)).join('；')];
  }
  if (action === 'replace') {
    const at: number = lines.findIndex((line: string): boolean => matches(line, old));
    if (note === '') { return [memory, '没有新的内容。']; }
    if (at < 0) { return [lines.concat([note]).join('\n'), '原来没有记着「' + old + '」，已作为新的一条记住：' + note]; }
    const before: string = lines[at];
    lines[at] = note;
    return [lines.join('\n'), '已把「' + before + '」改为「' + note + '」'];
  }
  return [memory, 'action 只能是 add、remove、replace 或 clear。'];
}

export interface AiChatRequest {
  /** The conversation so far, oldest first; the last turn is the new user message. */
  turns: AiChatTurn[];
  attachments: AiAttachment[];
  /** Name, tone and language the user set in AI 个性化设置. */
  preferences: string;
  /** The user's own memory notes (AI 个性化设置 › 记忆). */
  memory: string;
  /** The tools that are on. */
  tools: AiToolSpec[];
  /** The installed skills, and the ones this message asked for by its chip. */
  skills: AiSkill[];
  chosenSkills: string[];
  appData: AiChatAppData;
  /** What the chat shows while it waits ("正在查看主机列表"). */
  onProgress: (status: string) => void;
}

export class AiChatReply {
  text: string;
  documents: AiDocument[];
  usage: DiagnosticAiUsageMetadata;
  usedTools: boolean;
  /** What the user may want next, as the model suggested it (shown as pills under the answer). */
  suggestions: string[];
  /** Actions the model proposed, waiting for the user's 确认 (a reminder, a call, a mail…). */
  actions: AiChatAction[];

  constructor(text: string, documents: AiDocument[], usage: DiagnosticAiUsageMetadata, usedTools: boolean,
    suggestions: string[] = [], actions: AiChatAction[] = []) {
    this.text = text;
    this.documents = documents;
    this.usage = usage;
    this.usedTools = usedTools;
    this.suggestions = suggestions;
    this.actions = actions;
  }
}

/** The model's "<suggest>a|b|c</suggest>" line: up to three short next steps. */
export function aiChatSuggestions(text: string): string[] {
  const match: RegExpMatchArray | null = text.match(/<suggest>([\s\S]*?)<\/suggest>/);
  if (match === null) { return []; }
  return match[1].split(/[|｜\n]/).map((item: string): string => item.replace(/^[\s\-•\d.、]+/, '').trim())
    .filter((item: string): boolean => item !== '' && item.length <= 20).slice(0, 3);
}

export function aiChatStripSuggestions(text: string): string {
  return text.replace(/<suggest>[\s\S]*?<\/suggest>/g, '').replace(/<suggest>[\s\S]*$/, '').trim();
}

interface AiWireMessage { role: string; content: string; }
interface AiWireToolMessage { role: string; tool_call_id: string; content: string; }
interface AiWireAssistantToolCalls { role: string; content: string; tool_calls: Object[]; }

function hasTool(tools: AiToolSpec[], fn: string): boolean {
  return tools.some((tool: AiToolSpec): boolean => tool.fn === fn);
}

function todayLine(): string {
  const now: Date = new Date();
  const pad = (value: number): string => (value < 10 ? '0' : '') + value.toString();
  return '今天是 ' + now.getFullYear().toString() + ' 年 ' + (now.getMonth() + 1).toString() + ' 月 ' + now.getDate().toString() +
    ' 日，星期' + '日一二三四五六'.charAt(now.getDay()) + '，现在 ' + pad(now.getHours()) + ':' + pad(now.getMinutes()) + '。';
}

/** The skills: a short list of all installed ones, and the full instructions of those this message calls for. */
function skillsContext(skills: AiSkill[], active: AiSkill[]): string {
  if (skills.length === 0) { return ''; }
  let text: string = '已安装的技能（请求符合某个技能时按它的做法完成）：\n' +
    skills.map((skill: AiSkill): string => '- ' + skill.name + '：' + (skill.description !== '' ? skill.description : skill.instructions.slice(0, 40)))
      .join('\n') + '\n';
  active.slice(0, 3).forEach((skill: AiSkill): void => {
    text += '本次使用技能【' + skill.name + '】，做法：' + skill.instructions + '\n';
  });
  return text;
}

function chatSystemPrompt(request: AiChatRequest, active: AiSkill[], tools: boolean): string {
  const on: AiToolSpec[] = request.tools;
  const appTools: string[] = on.filter((tool: AiToolSpec): boolean => tool.group === 'app').map((tool: AiToolSpec): string => tool.name);
  return '你是用户的通用 AI 助手（聊天模式），运行在用户鸿蒙设备上的 RemoteDesktop（远程桌面）应用里，可以帮助写作、总结、翻译、润色、' +
    '问答、整理资料和处理文档。' + todayLine() + '\n' +
    '- 回答较长时用 Markdown 组织（标题、列表、表格、加粗）；简单问题直接回答，不要套话。\n' +
    '- 不要编造附件或应用数据里没有的内容；需要用户补充的信息直接说明。\n' +
    (appTools.length > 0 ?
      (tools ? '- 需要用户在应用里的数据（' + appTools.join('、') + '）时，调用对应工具读取，再据此回答；不要让用户自己去查。\n' :
        '- 下面附有用户在应用里的数据（' + appTools.join('、') + '），需要时直接使用。\n') :
      '- 用户关闭了读取应用数据的工具，你看不到主机、连接记录和设置；需要时请用户在 设置 › AI 工具与技能 里开启。\n') +
    (hasTool(on, 'create_document') ? (tools ?
      '- 用户要生成、改写或导出文档（Word、Excel、Markdown、文本）时，调用 create_document 生成文件：Word 和 Markdown 用 Markdown 写正文，' +
        'Excel 用 Markdown 表格写数据（第一行为表头）。生成后用一两句话说明文档内容，提示用户点「打开」用 WPS 等应用查看，不要把全文再贴一遍。\n' :
      '- 用户要生成、改写或导出文档时，在回答里输出一个文档块：\n<document title="文件名" format="docx">\n（正文）\n</document>\n' +
        'format 可以是 docx（Word）、xlsx（Excel，正文用 Markdown 表格）、md、txt；Word 和 Markdown 的正文用 Markdown 写。' +
        '应用会把文档块保存为文件并显示「打开」按钮，块外只用一两句话说明。\n') :
      '- 用户关闭了生成文档的工具，只用文字回答。\n') +
    (tools && hasTool(on, 'read_attachment') ? '- 附件只放了开头、需要后面的内容时，调用 read_attachment。\n' : '') +
    (tools && hasTool(on, 'list_documents') ?
      '- 用户要查看、修改或删除之前生成的文档时，先用 list_documents 找到它：修改先 read_document 读出原文，再用 update_document 写回完整的新正文；' +
        '删除用 delete_document。\n' : '') +
    (tools && hasTool(on, 'manage_feature_requests') ?
      '- 用户提出 App 还没有的功能、改进想法（“要是能……就好了”“希望……”）时，用 manage_feature_requests 记下，不必追问；' +
        '用户想要这些功能或让你发给开发者时，用它 send。\n' : '') +
    (tools && hasTool(on, 'switch_mode') ?
      '- 用户要回到文字、进入语音模式、切到助理或聊天、缩成悬浮球、开始新对话（开个新对话、清空对话、换个话题重新聊），或者表示要结束（拜拜、退出、就这样吧）时，调用 switch_mode。\n' : '') +
    (tools ? '- 应用里的数据可以增删改查：记住或忘掉事情用 update_memory；对话记录用 list_conversations / delete_conversation；' +
      '主机用 list_hosts / connect_host / edit_host / delete_host；提醒用 set_reminder / list_reminders / cancel_reminder。' +
      '删除和会改动数据的操作都会先显示确认卡片，回答里说明要做什么并提醒用户点确认，不要说已经完成。\n' : '') +
    (tools && on.some((tool: AiToolSpec): boolean => tool.group === 'system') ?
      '- 用户让你在手机上做事（提醒、日程、联系人、打电话、写邮件、导航、复制、手电筒、看剪贴板、识别图片文字等）时，直接调用对应工具，' +
        '不要只告诉用户怎么做。提醒、打电话、写邮件、导航、打开网页会先在对话里显示确认卡片，用户点确认才执行：回答里说明要做什么并提醒点确认，' +
        '不要说已经完成。日程和联系人会打开系统页面由用户保存。时间一律按用户本地时间写成 YYYY-MM-DD HH:mm。\n' : '') +
    '- 用户遇到 RemoteDesktop 本身的故障（连不上、黑屏、卡顿）需要诊断或抓日志时，用 ask_assistant 交给「助理」；改设置可以直接用 change_setting。\n' +
    '关于这个应用（回答用户的使用问题时以此为准，不要编造界面）：\n' + aiAppGuide() + '\n' +
    '- 回答的最后另起一行，写出用户最可能想接着做的 2 到 3 件事，格式 <suggest>事情一|事情二|事情三</suggest>，每件 12 字以内、' +
    '以动词开头、贴合这次的内容（例如“生成 Word 文档”“翻译成英文”“再精简一些”“补充下周计划”）；应用会把它们显示成按钮，不要在正文里重复。\n' +
    skillsContext(request.skills, active) +
    (request.preferences !== '' ? '用户偏好（只影响语气和称呼）：' + request.preferences + '\n' : '') +
    (request.memory !== '' ? '用户希望你记住：' + request.memory + '\n' : '');
}

/** Models without tools get the app data they may need up front (only from tools that are on). */
function appDataSnapshot(request: AiChatRequest, question: string, active: AiSkill[]): string {
  const wants: boolean = /周报|日报|月报|报告|主机|连接|远程|巡检|总结|统计|用量|设置/.test(question) ||
    active.some((skill: AiSkill): boolean => /list_hosts|connection_history|app_settings|ai_usage/.test(skill.instructions));
  if (!wants) { return ''; }
  let text: string = '';
  if (hasTool(request.tools, 'list_hosts')) { text += '\n【主机列表】\n' + request.appData.hosts('').slice(0, 4000); }
  if (hasTool(request.tools, 'connection_history')) {
    text += '\n【最近 30 天连接记录】\n' + request.appData.connections(30).slice(0, 6000);
  }
  if (hasTool(request.tools, 'ai_usage') && /用量|token|费用/.test(question.toLowerCase())) {
    text += '\n【AI 用量】\n' + request.appData.usage(30).slice(0, 1500);
  }
  if (hasTool(request.tools, 'app_settings') && /设置/.test(question)) {
    text += '\n【应用设置】\n' + request.appData.settings().slice(0, 4000);
  }
  return text === '' ? '' : '\n用户在应用里的数据：' + text;
}

/** The added documents as the model reads them, within the budget; each keeps at least a fair share. */
function attachmentsContext(attachments: AiAttachment[], budget: number, tools: boolean): string {
  if (attachments.length === 0) { return ''; }
  const share: number = Math.max(3000, Math.floor(budget / attachments.length));
  const parts: string[] = attachments.map((item: AiAttachment): string => {
    const shown: string = item.text.slice(0, share);
    const more: boolean = item.text.length > shown.length || item.truncated;
    return '《' + item.name + '》（' + aiDocumentKindLabel(item.kind) + '，约 ' + item.text.length.toString() + ' 字）：\n<<<\n' +
      shown + '\n>>>' + (more ? (tools ? '\n（以上是前 ' + shown.length.toString() + ' 字；需要后面的内容请调用 read_attachment，name=《' +
        item.name + '》的文件名，offset=' + shown.length.toString() + '）' : '\n（后面的内容已省略）') : '');
  });
  return '\n用户添加的附件：\n' + parts.join('\n\n');
}

/** The newest turns that fit the budget, oldest first. */
function historyMessages(turns: AiChatTurn[], budget: number): AiWireMessage[] {
  const picked: AiWireMessage[] = [];
  let used: number = 0;
  for (let i: number = turns.length - 1; i >= 0; i--) {
    const turn: AiChatTurn = turns[i];
    if (used + turn.content.length > budget && picked.length > 0) { break; }
    picked.unshift({ role: turn.role === 'assistant' ? 'assistant' : 'user', content: turn.content.slice(-budget) });
    used += turn.content.length;
  }
  // A conversation sent to the model starts with the user.
  while (picked.length > 0 && picked[0].role !== 'user') { picked.shift(); }
  return picked;
}

function stringField(row: Record<string, Object>, key: string): string {
  const value: Object | undefined = row[key];
  return typeof value === 'string' ? value as string : typeof value === 'number' ? (value as number).toString() : '';
}

function addUsage(total: DiagnosticAiUsageMetadata, part: DiagnosticAiUsageMetadata): void {
  total.promptTokens += part.promptTokens;
  total.completionTokens += part.completionTokens;
  total.cachedTokens += part.cachedTokens;
  if (part.estimated === true) { total.estimated = true; }
}

/** "<document title=… format=…>…</document>" blocks: written as files, and taken out of the answer text. */
export function aiChatDocumentBlocks(text: string): string[][] {
  const blocks: string[][] = [];
  const pattern: RegExp = /<document\s+title="([^"]*)"\s+format="([a-z]+)"\s*>([\s\S]*?)<\/document>/g;
  let match: RegExpExecArray | null = pattern.exec(text);
  while (match !== null) {
    blocks.push([match[1], match[2], match[3].replace(/^\n+|\n+$/g, '')]);
    match = pattern.exec(text);
  }
  return blocks;
}

export function aiChatStripDocumentBlocks(text: string): string {
  return text.replace(/<document\s+title="[^"]*"\s+format="[a-z]+"\s*>[\s\S]*?<\/document>/g, '').replace(/\n{3,}/g, '\n\n').trim();
}

export class AiChatService {
  private readonly provider: DiagnosticAiProviderService = new DiagnosticAiProviderService();
  /** Provider/model pairs that refused a request with tools; they get the document-block protocol from then on. */
  private static toolsRefused: string[] = [];

  async respond(context: common.UIAbilityContext, profile: DiagnosticAiProviderProfile, secret: string,
    request: AiChatRequest): Promise<AiChatReply> {
    const startedAt: number = Date.now();
    const bytes: number = request.turns.reduce((sum: number, turn: AiChatTurn): number => sum + turn.content.length, 0) +
      request.attachments.reduce((sum: number, item: AiAttachment): number => sum + Math.min(item.text.length, ATTACHMENT_BUDGET), 0);
    try {
      const reply: AiChatReply = diagnosticAiProviderIsHarmonyLocal(profile.providerId) ?
        await this.respondLocal(context, request) : await this.respondRemote(context, profile, secret, request);
      DiagnosticAiRequestLog.record(AI_MODE_CHAT, null, Date.now() - startedAt, bytes);
      return reply;
    } catch (error) {
      DiagnosticAiRequestLog.record(AI_MODE_CHAT, error as Object, Date.now() - startedAt, bytes);
      throw error as Error;
    }
  }

  private async respondLocal(context: common.UIAbilityContext, request: AiChatRequest): Promise<AiChatReply> {
    const history: string = request.turns.slice(0, request.turns.length - 1).slice(-4)
      .map((turn: AiChatTurn): string => (turn.role === 'assistant' ? '助手：' : '用户：') + turn.content).join('\n').slice(-900);
    const question: string = request.turns.length > 0 ? request.turns[request.turns.length - 1].content : '';
    const prompt: string = (chatSystemPrompt(request, [], false).slice(0, 700) +
      attachmentsContext(request.attachments, 1200, false) + '\n最近对话：\n' + history + '\n用户：' + question).slice(-LOCAL_BUDGET);
    const answer: string = await this.provider.localChatText(prompt);
    return this.finish(context, answer, [], { promptTokens: diagnosticAiEstimateTokens(prompt),
      completionTokens: diagnosticAiEstimateTokens(answer), cachedTokens: 0, estimated: true }, false);
  }

  private async respondRemote(context: common.UIAbilityContext, profile: DiagnosticAiProviderProfile, secret: string,
    request: AiChatRequest): Promise<AiChatReply> {
    const manifest = diagnosticAiProviderManifest(profile.providerId);
    const key: string = profile.providerId + '\u001f' + profile.modelId;
    const question: string = request.turns.length > 0 ? request.turns[request.turns.length - 1].content : '';
    const active: AiSkill[] = request.skills.filter((skill: AiSkill): boolean => request.chosenSkills.indexOf(skill.id) >= 0)
      .concat(aiSkillsForQuestion(request.skills, question)
        .filter((skill: AiSkill): boolean => request.chosenSkills.indexOf(skill.id) < 0));
    const wireTools: Object[] = request.tools
      .filter((tool: AiToolSpec): boolean => tool.fn !== 'read_attachment' || request.attachments.length > 0)
      .map((tool: AiToolSpec): Object => JSON.parse(tool.schema) as Object);
    let tools: boolean = manifest !== null && manifest.adapterFamily === 'openai_compatible_http' &&
      AiChatService.toolsRefused.indexOf(key) < 0 && wireTools.length > 0;
    const build = (withTools: boolean): Object[] => {
      const system: AiWireMessage = { role: 'system', content: chatSystemPrompt(request, active, withTools) +
        attachmentsContext(request.attachments, withTools ? ATTACHMENT_BUDGET : ATTACHMENT_BUDGET_NO_TOOLS, withTools) +
        (withTools ? '' : appDataSnapshot(request, question, active)) };
      const list: Object[] = [system as Object];
      historyMessages(request.turns, HISTORY_BUDGET).forEach((message: AiWireMessage): void => { list.push(message as Object); });
      return list;
    };
    let messages: Object[] = build(tools);
    const usage: DiagnosticAiUsageMetadata = { promptTokens: 0, completionTokens: 0, cachedTokens: 0 };
    const documents: AiDocument[] = [];
    const actions: AiChatAction[] = [];
    let usedTools: boolean = false;
    let text: string = '';
    for (let round: number = 0; round <= MAX_TOOL_ROUNDS; round++) {
      const body: Record<string, Object> = { 'model': profile.modelId, 'stream': false, 'messages': messages };
      // The last round asks for the answer itself.
      if (tools && round < MAX_TOOL_ROUNDS) { body['tools'] = wireTools; body['tool_choice'] = 'auto'; }
      let raw: Record<string, Object>;
      try {
        raw = await this.provider.chatCompletion(profile, secret, body, CHAT_READ_TIMEOUT_MS);
      } catch (error) {
        const message: string = error instanceof Error ? error.message : '';
        if (tools && round === 0 && (message.indexOf('HTTP_400') >= 0 || message.indexOf('HTTP_422') >= 0)) {
          // This model does not take tools: answer with document blocks instead, now and from now on.
          hilog.info(0x0000, 'AiChat', 'tools refused by %{public}s, using document blocks', profile.providerId);
          AiChatService.toolsRefused.push(key);
          tools = false;
          messages = build(false);
          round = -1;
          continue;
        }
        throw error as Error;
      }
      const sent: string = JSON.stringify(messages);
      const reported: DiagnosticAiUsageMetadata | undefined = diagnosticAiResponseUsage(raw);
      const message: Record<string, Object> | null = diagnosticAiResponseMessage(raw);
      const calls: Object[] = message !== null && Array.isArray(message['tool_calls']) ? message['tool_calls'] as Object[] : [];
      addUsage(usage, reported ?? { promptTokens: diagnosticAiEstimateTokens(sent),
        completionTokens: diagnosticAiEstimateTokens(JSON.stringify(message ?? '')), cachedTokens: 0, estimated: true });
      if (!tools || calls.length === 0) {
        text = diagnosticAiResponseText(raw);
        break;
      }
      usedTools = true;
      // The assistant's tool calls go back as they came, without provider extras such as reasoning_content.
      const echo: AiWireAssistantToolCalls = { role: 'assistant', content: message !== null ? stringField(message, 'content') : '',
        tool_calls: calls };
      messages.push(echo as Object);
      // One by one: a tool may wait for the user (a picker, the calendar's own page).
      for (const call of calls) {
        const row: Record<string, Object> = call as Record<string, Object>;
        const fnValue: Object | undefined = row['function'];
        const fn: Record<string, Object> = fnValue !== undefined && fnValue !== null && typeof fnValue === 'object' ?
          fnValue as Record<string, Object> : JSON.parse('{}') as Record<string, Object>;
        const content: string = await this.runTool(context, stringField(fn, 'name'), stringField(fn, 'arguments'), request,
          documents, actions);
        const reply: AiWireToolMessage = { role: 'tool', tool_call_id: stringField(row, 'id'), content: content };
        messages.push(reply as Object);
      }
      request.onProgress('正在整理回答');
      hilog.info(0x0000, 'AiChat', 'tool round %{public}s calls=%{public}s', round.toString(), calls.length.toString());
    }
    if (text.trim() === '' && documents.length === 0 && actions.length === 0) { throw new Error('DIAGNOSTIC_AI_EMPTY_RESULT'); }
    const reply: AiChatReply = this.finish(context, text, documents, usage, usedTools);
    reply.actions = actions;
    if (reply.text === '' && actions.length > 0) { reply.text = '请确认下面的操作。'; }
    return reply;
  }

  /** Document blocks in the answer become files too (models without tools, or one that wrote a block anyway). */
  private finish(context: common.Context, answer: string, documents: AiDocument[], usage: DiagnosticAiUsageMetadata,
    usedTools: boolean): AiChatReply {
    aiChatDocumentBlocks(answer).forEach((block: string[]): void => {
      try { documents.push(aiCreateDocument(context, block[0], block[1], block[2])); }
      catch (error) { hilog.warn(0x0000, 'AiChat', 'document block failed %{public}s', (error as Error).message); }
    });
    const suggestions: string[] = aiChatSuggestions(answer);
    let text: string = aiChatStripSuggestions(aiChatStripDocumentBlocks(answer));
    if (text === '' && documents.length > 0) {
      text = '已生成' + documents.map((doc: AiDocument): string => '「' + doc.name + '」').join('、') + '，点「打开」查看。';
    }
    return new AiChatReply(text, documents, usage, usedTools, suggestions);
  }

  private async runTool(context: common.UIAbilityContext, name: string, args: string, request: AiChatRequest,
    documents: AiDocument[], actions: AiChatAction[]): Promise<string> {
    const attachments: AiAttachment[] = request.attachments;
    let input: Record<string, Object> = JSON.parse('{}') as Record<string, Object>;
    try {
      const parsed: Object = JSON.parse(args === '' ? '{}' : args) as Object;
      if (parsed !== null && typeof parsed === 'object') { input = parsed as Record<string, Object>; }
    } catch (_error) {
      return '参数不是有效的 JSON，请重新调用。';
    }
    const spec: AiToolSpec | undefined = aiToolByFunction(name);
    if (spec === undefined) { return '没有这个工具：' + name; }
    if (!request.tools.some((tool: AiToolSpec): boolean => tool.fn === name)) {
      return '用户已在 设置 › AI 工具与技能 里关闭了「' + spec.name + '」，请不用它完成，或告诉用户需要开启。';
    }
    request.onProgress(aiToolStatus(name, name === 'create_document' ? stringField(input, 'title') :
      name === 'read_attachment' || name === 'read_document' || name === 'update_document' ?
        stringField(input, 'name').replace(/[《》]/g, '') :
      name === 'web_search' ? stringField(input, 'query').slice(0, 20) : ''));
    if (spec.group === 'system') {
      // A mail may carry documents the AI wrote: their files go along as attachments.
      if (name === 'send_email') {
        const wanted: Object | undefined = input['attach'];
        const names: string[] = Array.isArray(wanted) ? (wanted as Object[]).map((x: Object): string => String(x)) : [];
        const all: AiDocument[] = names.length > 0 ? request.appData.documents() : [];
        const paths: string[] = [];
        for (const wantedName of names) {
          const found: AiDocument | string = pickByName<AiDocument>(all, (d: AiDocument): string => d.name, wantedName, '文档');
          if (typeof found === 'string') { return (found as string) + '可以用 list_documents 查看有哪些文档。'; }
          paths.push((found as AiDocument).path);
        }
        input['attachment_paths'] = paths;
      }
      if (AI_CONFIRM_TOOLS.indexOf(name) >= 0) {
        const made: AiChatAction | string = aiActionFor('act-' + Date.now().toString(36) + actions.length.toString(), name, input);
        if (typeof made === 'string') { return made as string; }
        const action: AiChatAction = made as AiChatAction;
        actions.push(action);
        return '还没有执行：已在对话里显示确认卡片「' + action.title + '」（' + action.detail + '），用户点「确认」后才会执行。' +
          '请用一句话说明将要做什么，并提醒用户点确认；不要说“已设置”“已完成”。';
      }
      return await aiRunSystemTool(context, name, input);
    }
    if (name === 'change_setting') {
      const settingId: string = stringField(input, 'setting_id').trim();
      const spec: AiSettingSpec | undefined = diagnosticAiSettingSpec(settingId);
      if (spec === undefined) { return '没有这个设置：' + settingId + '。请先用 app_settings 查看可以修改的设置清单。'; }
      const choice: AiSettingChoice | undefined = settingChoice(spec, stringField(input, 'value'));
      if (choice === undefined) {
        return '「' + spec.label + '」没有这个取值，可选：' + spec.choices.map((c: AiSettingChoice): string => c.label).join('、');
      }
      const current: string | null = diagnosticAiSettingCurrent(settingId);
      if (current === choice.value) { return '「' + spec.label + '」已经是「' + choice.label + '」，不用修改。'; }
      const args: Record<string, string> = {};
      args['setting_id'] = settingId;
      args['value'] = choice.value;
      const action: AiChatAction = new AiChatAction('act-' + Date.now().toString(36) + actions.length.toString(), 'change_setting',
        '把「' + spec.label + '」改为「' + choice.label + '」',
        current !== null ? '现在是「' + diagnosticAiSettingValueLabel(settingId, current) + '」' : '应用设置', JSON.stringify(args));
      actions.push(action);
      return '还没有执行：已在对话里显示确认卡片「' + action.title + '」，用户确认后才会修改。请用一句话说明要改什么，并请用户确认；不要说“已修改”。';
    }
    if (name === 'open_app_screen') {
      const screen: string = stringField(input, 'screen').trim();
      const id = diagnosticAiAppActionId(screen);
      if (id === null || screen.startsWith('session.')) { return '没有这个页面：' + screen + '。只能用工具说明里列出的页面 id。'; }
      // A card, as Siri shows one: the answer above, the page to open below; it opens when the user confirms.
      const args: Record<string, string> = {};
      args['screen'] = id;
      const action: AiChatAction = new AiChatAction('act-' + Date.now().toString(36) + actions.length.toString(),
        'open_app_screen', '打开「' + diagnosticAiAppActionTarget(id) + '」', '在 App 里打开这个页面', JSON.stringify(args));
      actions.push(action);
      return '还没有打开：已显示卡片「' + action.title + '」，用户确认后才会打开。请用一两句话说明在那里可以做什么，并请用户确认。';
    }
    if (name === 'web_search') { return await aiWebSearch(stringField(input, 'query')); }
    if (name === 'read_webpage') { return await aiReadWebpage(stringField(input, 'url')); }
    if (name === 'float_orb') {
      AppStorage.setOrCreate(AI_FLOAT_REQUEST, Date.now());
      return '已缩成悬浮球，停在当前页面上；用户点一下悬浮球就回到对话。请只用一句很短的话回应。';
    }
    if (name === 'switch_mode') {
      const mode: string = stringField(input, 'mode').trim();
      if (mode === 'orb') {
        AppStorage.setOrCreate(AI_FLOAT_REQUEST, Date.now());
        return '已缩成悬浮球。请只用一句很短的话回应。';
      }
      if (['text', 'voice', 'assistant', 'chat', 'new', 'exit'].indexOf(mode) < 0) {
        return 'mode 只能是 text、voice、assistant、chat、orb、new 或 exit。';
      }
      AppStorage.setOrCreate(AI_MODE_REQUEST, mode + '@' + Date.now().toString());
      if (mode === 'new') { return '回答后会开始新对话（当前对话已保存在对话记录里）。请只用一句很短的话回应。'; }
      return mode === 'exit' ? '回答后 AI 会关闭。请只用一句很短的话道别。' :
        '回答后就切换过去。请只用一句很短的话回应，不要再问别的。';
    }
    if (name === 'connect_host') {
      const host: AiTriageHost | string = this.findHost(input);
      if (typeof host === 'string') { return host as string; }
      const found: AiTriageHost[] = [host as AiTriageHost];
      const args: Record<string, string> = {};
      args['host_id'] = found[0].id;
      // The card's title also goes back to the model with the conversation: never an address.
      const shown: string = /^[\d.:\[\]]+$|^[\w-]+(\.[\w-]+)+$/.test(found[0].label) ? '这台主机' : '「' + found[0].label + '」';
      const action: AiChatAction = new AiChatAction('act-' + Date.now().toString(36) + actions.length.toString(), 'connect_host',
        '连接' + shown, '开始远程连接', JSON.stringify(args));
      actions.push(action);
      return '还没有连接：已显示确认卡片，确认后开始连接' + shown + '。请用一句话请用户确认。';
    }
    if (name === 'ask_assistant') {
      const question: string = stringField(input, 'question').trim();
      if (question === '') { return '没有交出去：question 为空。'; }
      AppStorage.setOrCreate(AI_ASSISTANT_HANDOFF, Date.now().toString() + '|' + question.slice(0, 500));
      return '已交给 AI 助理，它会在“助理”里接着处理（诊断、抓日志或反馈）。请只用一句话告诉用户已交给助理。';
    }
    const days: number = Math.max(1, Math.min(45, parseInt(stringField(input, 'days'), 10) || 7));
    try {
      if (name === 'list_hosts') { return request.appData.hosts(stringField(input, 'protocol').toLowerCase()); }
      if (name === 'connection_history') { return request.appData.connections(days); }
      if (name === 'app_settings') { return request.appData.settings(); }
      if (name === 'ai_usage') { return request.appData.usage(days); }
    } catch (error) {
      return '读取失败：' + (error as Error).message;
    }
    if (name === 'list_documents' || name === 'read_document' || name === 'update_document' || name === 'delete_document') {
      return await this.documentTool(context, name, input, request, documents, actions);
    }
    if (name === 'list_conversations') {
      const rows: AiConversationRow[] = request.appData.conversations();
      if (rows.length === 0) { return '没有保存的对话记录。'; }
      const current: string = request.appData.currentConversation();
      return '保存的对话（标题｜类型｜最后更新｜轮数｜生成的文档）：\n' + rows.slice(0, 40).map((r: AiConversationRow): string =>
        r.title + '｜' + r.kind + '｜' + timeLabel(r.updatedAt) + '｜' + r.turns.toString() + ' 轮｜' + r.documents.toString() + ' 份' +
          (r.id === current ? '（当前对话）' : '')).join('\n');
    }
    if (name === 'delete_conversation') {
      const current: string = request.appData.currentConversation();
      const found: AiConversationRow | string = pickByName<AiConversationRow>(request.appData.conversations(),
        (r: AiConversationRow): string => r.title, stringField(input, 'title'), '对话');
      if (typeof found === 'string') { return found as string; }
      const row: AiConversationRow = found as AiConversationRow;
      if (row.id === current) { return '这是正在进行的对话，不能在对话里删除它。可以请用户新建对话后，在对话记录里删除。'; }
      const args: Record<string, string> = {};
      args['id'] = row.id;
      args['title'] = row.title;
      const action: AiChatAction = new AiChatAction('act-' + Date.now().toString(36) + actions.length.toString(),
        'delete_conversation', '删除对话「' + row.title + '」', row.kind + ' · ' + row.turns.toString() + ' 轮 · 删除后不能恢复',
        JSON.stringify(args));
      actions.push(action);
      return '还没有删除：已显示确认卡片「' + action.title + '」，用户确认后才删除。请用一句话请用户确认；不要说已删除。';
    }
    if (name === 'update_memory') {
      if (!request.appData.memoryEnabled()) {
        return '记忆功能已关闭，没有修改。请告诉用户可以在 AI 个性化设置 › 记忆 里打开。';
      }
      const changed: string[] = aiMemoryEdit(request.appData.memory(), stringField(input, 'action'), stringField(input, 'text'),
        stringField(input, 'old'));
      if (changed[0] !== request.appData.memory() && !request.appData.saveMemory(changed[0].slice(0, 4000))) {
        return '记忆没有保存成功，请稍后再试。';
      }
      return changed[1] + '。请用一句话告诉用户。';
    }
    if (name === 'manage_feature_requests') {
      return this.featureRequestTool(input, request, actions);
    }
    if (name === 'edit_host' || name === 'delete_host') {
      const found: AiTriageHost | string = this.findHost(input);
      if (typeof found === 'string') { return found as string; }
      const host: AiTriageHost = found as AiTriageHost;
      const args: Record<string, string> = {};
      args['host_id'] = host.id;
      const shown: string = /^[\d.:\[\]]+$|^[\w-]+(\.[\w-]+)+$/.test(host.label) ? '这台主机' : '「' + host.label + '」';
      const editing: boolean = name === 'edit_host';
      const action: AiChatAction = new AiChatAction('act-' + Date.now().toString(36) + actions.length.toString(), name,
        (editing ? '编辑' : '删除') + shown, editing ? '打开编辑页，由你修改并保存' : 'App 会再确认一次，删除后不能恢复',
        JSON.stringify(args));
      actions.push(action);
      return '还没有' + (editing ? '打开' : '删除') + '：已显示确认卡片「' + action.title + '」。' +
        (editing ? '用户确认后打开编辑页，由用户自己修改保存。' : '用户确认后 App 还会弹出删除确认，再次确认才删除。') +
        '请用一句话请用户确认；不要说已完成。';
    }
    if (name === 'create_document') {
      const title: string = stringField(input, 'title');
      const format: string = stringField(input, 'format');
      const content: string = stringField(input, 'content');
      if (content.trim() === '') { return '没有生成：content 为空。'; }
      try {
        const document: AiDocument = aiCreateDocument(context, title, format, content);
        documents.push(document);
        return '已生成文件「' + document.name + '」（' + Math.max(1, Math.round(document.bytes / 1024)).toString() +
          ' KB），用户可以点「打开」查看。请用一两句话告诉用户文档里有什么，不要重复全文。';
      } catch (error) {
        return '生成失败：' + (error as Error).message;
      }
    }
    if (name === 'read_attachment') {
      const wanted: string = stringField(input, 'name').replace(/[《》]/g, '').trim();
      const offset: number = Math.max(0, parseInt(stringField(input, 'offset'), 10) || 0);
      const item: AiAttachment | undefined = attachments.find((a: AiAttachment): boolean => a.name === wanted) ??
        attachments.find((a: AiAttachment): boolean => a.name.indexOf(wanted) >= 0 || wanted.indexOf(a.name) >= 0) ??
        (attachments.length === 1 ? attachments[0] : undefined);
      if (item === undefined) {
        return '没有这个附件。可用的附件：' + attachments.map((a: AiAttachment): string => a.name).join('、');
      }
      const chunk: string = item.text.slice(offset, offset + READ_CHUNK);
      if (chunk === '') { return '《' + item.name + '》已经读完（共 ' + item.text.length.toString() + ' 字）。'; }
      const next: number = offset + chunk.length;
      return chunk + (next < item.text.length ? '\n（下一段从 offset=' + next.toString() + ' 开始）' : '\n（已到结尾）');
    }
    return '没有这个工具：' + name;
  }

  /** 需求收集: add, list, remove, or send them to the developer (a card the user confirms, then the mail app). */
  private featureRequestTool(input: Record<string, Object>, request: AiChatRequest, actions: AiChatAction[]): string {
    const action: string = stringField(input, 'action').trim();
    const text: string = stringField(input, 'text').trim();
    const pending = (): DiagnosticAiFeatureRequest[] => request.appData.featureRequests()
      .filter((row: DiagnosticAiFeatureRequest): boolean => row.sentAt === 0);
    if (action === 'add') {
      if (text === '') { return '没有记下：text 为空。'; }
      if (!request.appData.addFeatureRequest(text)) { return '这条需求已经记着了，不用重复记。'; }
      return '已记下（现在有 ' + pending().length.toString() + ' 条待发送的需求）。请用一句话告诉用户已记下，' +
        '攒好后说“把需求发给开发者”就能整理成邮件。';
    }
    if (action === 'list') {
      const rows: DiagnosticAiFeatureRequest[] = request.appData.featureRequests();
      if (rows.length === 0) { return '还没有记下任何需求。'; }
      return '需求清单（' + pending().length.toString() + ' 条待发送）：\n' + rows.map((row: DiagnosticAiFeatureRequest, i: number): string =>
        (i + 1).toString() + '. ' + row.text + '（' + timeLabel(row.createdAt).slice(0, 10) + '，' +
          (row.sentAt > 0 ? timeLabel(row.sentAt).slice(0, 10) + ' 已发送' : '待发送') + '）').join('\n');
    }
    if (action === 'remove') {
      const removed: number = request.appData.removeFeatureRequests(text);
      return removed > 0 ? '已删除 ' + removed.toString() + ' 条需求。' : '没有找到和「' + text + '」相关的需求。';
    }
    if (action === 'send') {
      const rows: DiagnosticAiFeatureRequest[] = pending();
      if (rows.length === 0) { return '没有待发送的需求。可以先告诉我你想要什么功能。'; }
      const mail: DiagnosticAiMailDraft = aiFeatureRequestMail(rows.map((row: DiagnosticAiFeatureRequest): string => row.text),
        stringField(input, 'note'), CURRENT_RELEASE_VERSION);
      const args: Record<string, Object> = {};
      args['ids'] = rows.map((row: DiagnosticAiFeatureRequest): string => row.id);
      args['subject'] = mail.subject;
      args['body'] = mail.body;
      const card: AiChatAction = new AiChatAction('act-' + Date.now().toString(36) + actions.length.toString(),
        'send_feature_requests', '把 ' + rows.length.toString() + ' 条需求发给开发者', '打开邮件应用，检查后由你发送',
        JSON.stringify(args));
      actions.push(card);
      return '还没有发送：已显示确认卡片「' + card.title + '」，确认后打开邮件应用。请用一两句话概括要发的需求并请用户确认。';
    }
    return 'action 只能是 add、list、remove 或 send。';
  }

  /** The saved host the model named (by name, optionally one protocol); a string says why there is not one. */
  private findHost(input: Record<string, Object>): AiTriageHost | string {
    const wanted: string = stringField(input, 'name').trim().toLowerCase();
    const protocol: string = stringField(input, 'protocol').trim().toLowerCase();
    if (wanted === '') { return '没有主机名称。请先用 list_hosts 看用户有哪些主机，或问用户指的是哪一台。'; }
    const protocols: string[] = protocol !== '' ? [protocol] : ['rdp', 'rustdesk', 'ssh', 'vnc', 'moonlight'];
    const all: AiTriageHost[] = [];
    protocols.forEach((p: string): void => { DiagnosticAiHostBridge.hosts(p).forEach((h: AiTriageHost): void => { all.push(h); }); });
    const exact: AiTriageHost[] = all.filter((h: AiTriageHost): boolean => h.label.toLowerCase() === wanted);
    const found: AiTriageHost[] = exact.length > 0 ? exact :
      all.filter((h: AiTriageHost): boolean => h.label.toLowerCase().indexOf(wanted) >= 0 || wanted.indexOf(h.label.toLowerCase()) >= 0);
    if (found.length === 0) { return '没有找到名为「' + stringField(input, 'name') + '」的主机。可以用 list_hosts 看看有哪些主机。'; }
    if (found.length > 1) {
      // An unnamed host is listed by its address: the model gets 未命名主机 instead.
      return '有好几台主机符合：' + found.slice(0, 6).map((h: AiTriageHost): string =>
        /^[\d.:\[\]]+$|^[\w-]+(\.[\w-]+)+$/.test(h.label) ? '未命名主机' : h.label).join('、') + '。请问用户指的是哪一台。';
    }
    return found[0];
  }

  /** The documents the AI wrote: list, read back, rewrite in place, delete (a card the user confirms). */
  private async documentTool(context: common.UIAbilityContext, name: string, input: Record<string, Object>,
    request: AiChatRequest, documents: AiDocument[], actions: AiChatAction[]): Promise<string> {
    const all: AiDocument[] = request.appData.documents();
    if (name === 'list_documents') {
      if (all.length === 0) { return '设备上没有 AI 生成的文档（可能还没生成过，或已经删除）。'; }
      return 'AI 生成过的文档（名称｜类型｜大小｜生成时间）：\n' + all.slice(0, 50).map((d: AiDocument): string =>
        d.name + '｜' + aiDocumentKindLabel(d.format) + '｜' + Math.max(1, Math.round(d.bytes / 1024)).toString() + ' KB｜' +
          timeLabel(d.createdAt)).join('\n');
    }
    const found: AiDocument | string = pickByName<AiDocument>(all, (d: AiDocument): string => d.name,
      stringField(input, 'name'), '文档');
    if (typeof found === 'string') {
      return (found as string) + (all.length > 0 ? '可以用 list_documents 查看有哪些文档。' : '设备上没有 AI 生成的文档。');
    }
    const document: AiDocument = found as AiDocument;
    if (name === 'read_document') {
      try {
        const text: string = await aiReadDocument(context, document);
        const offset: number = Math.max(0, parseInt(stringField(input, 'offset'), 10) || 0);
        const chunk: string = text.slice(offset, offset + READ_CHUNK);
        if (chunk === '') { return '《' + document.name + '》已经读完（共 ' + text.length.toString() + ' 字）。'; }
        const next: number = offset + chunk.length;
        return '《' + document.name + '》' + (offset > 0 ? '（续）' : '') + '：\n' + chunk +
          (next < text.length ? '\n（下一段从 offset=' + next.toString() + ' 开始）' : '\n（已到结尾）');
      } catch (error) {
        return '读取失败：' + aiDocumentErrorText(error as Object);
      }
    }
    if (name === 'update_document') {
      const content: string = stringField(input, 'content');
      if (content.trim() === '') { return '没有修改：content 为空。'; }
      try {
        const updated: AiDocument = aiRewriteDocument(document, content);
        documents.push(updated);
        return '已改写「' + updated.name + '」（' + Math.max(1, Math.round(updated.bytes / 1024)).toString() +
          ' KB），对话里这份文档的卡片打开的就是新内容。请用一两句话说明改了什么，不要重复全文。';
      } catch (error) {
        return '修改失败：' + aiDocumentErrorText(error as Object);
      }
    }
    // delete_document: a card; the file goes only when the user confirms.
    const args: Record<string, string> = {};
    args['name'] = document.name;
    args['format'] = document.format;
    args['path'] = document.path;
    const action: AiChatAction = new AiChatAction('act-' + Date.now().toString(36) + actions.length.toString(),
      'delete_document', '删除文档「' + document.name + '」', '从设备上删除，不能恢复', JSON.stringify(args));
    actions.push(action);
    return '还没有删除：已显示确认卡片「' + action.title + '」，用户确认后才删除。请用一句话请用户确认；不要说已删除。';
  }
}
