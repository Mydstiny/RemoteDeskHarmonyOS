import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DiagnosticAiProviderProfile, DiagnosticAiUsageMetadata } from './DiagnosticAiModels';
import { diagnosticAiProviderIsHarmonyLocal, diagnosticAiProviderManifest } from './DiagnosticAiProviderCatalog';
import { DiagnosticAiProviderService, diagnosticAiEstimateTokens, diagnosticAiResponseMessage, diagnosticAiResponseText, diagnosticAiResponseUsage } from './DiagnosticAiProviderService';
import { AI_MODE_CHAT, DiagnosticAiRequestLog } from './DiagnosticAiRequestLog';
import { AiAttachment, AiDocument, aiCreateDocument, aiDocumentKindLabel } from './AiDocumentService';
import { AiSkill, AiToolSpec, aiSkillsForQuestion, aiToolByFunction, aiToolStatus } from './AiSkillCatalog';
import { AI_CONFIRM_TOOLS, AiChatAction, aiActionFor, aiRunSystemTool } from './AiSystemTools';
import { AiSettingChoice, AiSettingSpec, diagnosticAiSettingCurrent, diagnosticAiSettingSpec, diagnosticAiSettingValueLabel } from './DiagnosticAiSettingsActionPolicy';
import { diagnosticAiAppActionId, diagnosticAiAppActionLabel } from './DiagnosticAiAppActionPolicy';
import { AI_APP_ACTION_REQUEST, AI_ASSISTANT_HANDOFF } from './AiBridgeKeys';


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

/** The app data the tools read, each already in words for the model (the chat view fills it from the app). */
export interface AiChatAppData {
  hosts: (protocol: string) => string;
  connections: (days: number) => string;
  settings: () => string;
  usage: (days: number) => string;
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
    (tools && on.some((tool: AiToolSpec): boolean => tool.group === 'system') ?
      '- 用户让你在手机上做事（提醒、日程、联系人、打电话、写邮件、导航、复制、手电筒、看剪贴板、识别图片文字等）时，直接调用对应工具，' +
        '不要只告诉用户怎么做。提醒、打电话、写邮件、导航、打开网页会先在对话里显示确认卡片，用户点确认才执行：回答里说明要做什么并提醒点确认，' +
        '不要说已经完成。日程和联系人会打开系统页面由用户保存。时间一律按用户本地时间写成 YYYY-MM-DD HH:mm。\n' : '') +
    '- 用户遇到 RemoteDesktop 本身的故障（连不上、黑屏、卡顿）或要修改应用设置时，提醒切换到「助理」模式，助理可以抓日志、直接改设置。\n' +
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
      name === 'read_attachment' ? stringField(input, 'name').replace(/[《》]/g, '') : ''));
    if (spec.group === 'system') {
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
      AppStorage.setOrCreate(AI_APP_ACTION_REQUEST, id + '@' + Date.now().toString());
      return '已打开「' + diagnosticAiAppActionLabel(id) + '」页面。请用一句话告诉用户可以在这里做什么。';
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
}
