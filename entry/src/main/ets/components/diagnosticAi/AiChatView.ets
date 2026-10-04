import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { curves, LengthMetrics } from '@kit.ArkUI';
import { inputMethod } from '@kit.IMEKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { AiThinkingIndicator } from './AiMotionViews';
import { AiInputCapsule, AiSendButton } from './AiIslandChrome';
import { DiagnosticAiProviderProfile } from '../../services/diagnosticAi/DiagnosticAiModels';
import { DiagnosticAiProfileStore } from '../../services/diagnosticAi/DiagnosticAiProfileStore';
import { diagnosticAiProviderIsHarmonyLocal, diagnosticAiProviderManifest } from '../../services/diagnosticAi/DiagnosticAiProviderCatalog';
import { AiChatAppData, AiChatReply, AiChatService, AiChatTurn, AiConversationRow } from '../../services/diagnosticAi/AiChatService';
import { AiAttachment, AiDocument, aiCreateDocument, aiDocumentAvailable, aiDocumentErrorText, aiDocumentKind, aiDocumentKindLabel, aiImportDocument, aiOpenDocument, aiPickDocuments, aiPrintDocument, aiSaveDocumentAs, aiShareDocument, aiTextAttachment } from '../../services/diagnosticAi/AiDocumentService';
import { AiChatAction, aiActionErrorText, aiRunAction } from '../../services/diagnosticAi/AiSystemTools';
import { AiReadAloud, AiVoiceInput } from '../../services/diagnosticAi/AiSpeech';
import { AI_VOICE_ENABLED } from '../../services/diagnosticAi/AiVoiceSettings';
import { AiMdBlock, AiMdSpan, aiMarkdownBlocks } from '../../services/diagnosticAi/AiMarkdownPolicy';
import { aiAutoRoute, aiModeCommand, aiPendingCardReply } from '../../services/diagnosticAi/AiChatRoutePolicy';
import { AI_MODE_REQUEST, AI_ORB_DICTATION, AiOrbDictation, aiOrbDictationDecode } from '../../services/diagnosticAi/AiBridgeKeys';
import { AI_STYLE, aiInk, aiStyleIsXiaoyi, aiXiaoyiGlass } from '../../services/diagnosticAi/AiStylePolicy';
import { AI_CHAT_REFRESH_KEY, AiShareInbox, AiSharedItem, aiChatRefresh } from '../../services/diagnosticAi/AiShareInbox';
import { AiSkill, AiToolSpec, aiSkillsForQuestion, aiThinkingPhrases } from '../../services/diagnosticAi/AiSkillCatalog';
import { AiSkillStore } from '../../services/diagnosticAi/AiSkillStore';
import { AiAppDataBridge, AiConnectionRow, aiConnectionsText, aiHostsText } from '../../services/diagnosticAi/AiAppDataBridge';
import { ConnectionJournal, ConnectionJournalEntry } from '../../services/ConnectionJournal';
import { diagnosticAiSettingCatalog } from '../../services/diagnosticAi/DiagnosticAiSettingsActionPolicy';
import { DiagnosticAiAssistantPreferences, DiagnosticAiConversationSession, DiagnosticAiConversationStore, DiagnosticAiConversationTurn, DiagnosticAiDailyUsage, DiagnosticAiTurnDocument, DiagnosticAiFeatureRequest, defaultDiagnosticAiAssistantPreferences, diagnosticAiSessionKind } from '../../services/diagnosticAi/DiagnosticAiConversationStore';
import { DiagnosticAiModelCatalog } from '../../services/diagnosticAi/DiagnosticAiModelCatalog';
import { ProAppRuntime } from '../../services/pro/ProAppRuntime';
import { ProEntries } from '../../services/pro/ProEntries';
import { PRO_DIAGNOSTICS_ASSISTANT_FEATURE } from '../../services/pro/ProFeatureCatalog';
import { AccountSessionCoordinator } from '../../services/AccountSessionCoordinator';

/** AppStorage: a request to start voice mode (hands-free); the home page opens it (AiVoiceIsland). */
export const AI_VOICE_REQUEST: string = 'aiVoice.request';

/** Most documents one chat holds at a time. */
const AI_CHAT_MAX_ATTACHMENTS: number = 5;
/** The header row's height; the 助理 | 聊天 switch of the panel sits over its left end. */
export const AI_CHAT_HEADER_HEIGHT: number = 34;

/** One message of the chat: the user's (with the names of the documents added to it) or the AI's (with documents). */
export class AiChatMessage {
  id: string;
  role: string;
  text: string;
  attachments: string[];
  documents: AiDocument[];
  createdAt: number;
  /** The AI's suggested next steps (pills under the latest answer; not kept with the saved session). */
  suggestions: string[];
  /** Actions waiting for (or done after) the user's 确认: a reminder, a call, a mail, a route, a web page. */
  actions: AiChatAction[];

  constructor(id: string, role: string, text: string, attachments: string[], documents: AiDocument[], createdAt: number,
    suggestions: string[] = [], actions: AiChatAction[] = []) {
    this.id = id;
    this.role = role;
    this.text = text;
    this.attachments = attachments;
    this.documents = documents;
    this.createdAt = createdAt;
    this.suggestions = suggestions;
    this.actions = actions;
  }
}

/** One pill under the latest answer: a next question to send, or something the app does itself. */
class AiChatPill {
  key: string;
  label: string;
  /** ask · excel · word · float */
  kind: string;

  constructor(key: string, label: string, kind: string) {
    this.key = key;
    this.label = label;
    this.kind = kind;
  }
}

/**
 * The chat outlives the island, like the assistant's conversation: closing, floating as the orb and reopening keep
 * it (and whether the island was in 聊天), until 新对话 or a change of account. A request out when the view goes (the
 * island floats) still lands here, and the view that comes back shows it.
 */
export class AiChatMemory {
  static owner: string = '';
  /** The island opens in 聊天 rather than 助理. */
  static active: boolean = false;
  static sessionId: string = '';
  static messages: AiChatMessage[] = [];
  /** Documents the conversation has read so far (sent to the model with every request). */
  static attachments: AiAttachment[] = [];
  /** Added (picked or shared) but not sent yet. */
  static pending: AiAttachment[] = [];
  /** A question handed over from 助理, asked as soon as the chat shows. */
  static handoff: string = '';
  /** Voice mode opened an app screen: the orb over it brings voice mode back (not the text panel). */
  static voiceResume: boolean = false;
  /** The request out now ('' none); 新对话 clears it, so a late answer is dropped. */
  static requestId: string = '';
  static status: string = '';
  static error: string = '';

  static clear(owner: string): void {
    AiChatMemory.owner = owner;
    AiChatMemory.sessionId = '';
    AiChatMemory.messages = [];
    AiChatMemory.attachments = [];
    AiChatMemory.pending = [];
    AiChatMemory.handoff = '';
    AiChatMemory.requestId = '';
    AiChatMemory.status = '';
    AiChatMemory.error = '';
  }
}

export function newMessageId(): string {
  return Date.now().toString(36) + Math.floor(Math.random() * 46656).toString(36);
}

/** Continue a saved chat (AI 对话记录 › 聊天): it becomes the current chat and the island opens in 聊天. */
export function aiChatResumeSession(owner: string, session: DiagnosticAiConversationSession): void {
  AiChatMemory.clear(owner);
  AiChatMemory.active = true;
  AiChatMemory.sessionId = session.id;
  const messages: AiChatMessage[] = [];
  session.turns.forEach((turn: DiagnosticAiConversationTurn, index: number): void => {
    messages.push(new AiChatMessage('r' + index.toString() + 'q', 'user', turn.question, turn.attachments ?? [], [], turn.createdAt));
    const documents: AiDocument[] = (turn.documents ?? []).map((doc: DiagnosticAiTurnDocument): AiDocument =>
      new AiDocument(doc.name, doc.format, doc.path, doc.bytes, turn.createdAt));
    messages.push(new AiChatMessage('r' + index.toString() + 'a', 'assistant', turn.answer, [], documents, turn.createdAt));
  });
  AiChatMemory.messages = messages;
}

/** The chat as a saved session (AI 对话记录 › 聊天): one turn per question and its answer. */
export function aiChatSaveSession(store: DiagnosticAiConversationStore, sessionId: string, messages: AiChatMessage[],
  profile: DiagnosticAiProviderProfile | undefined): void {
  const turns: DiagnosticAiConversationTurn[] = [];
  for (let i: number = 0; i < messages.length; i++) {
    const m: AiChatMessage = messages[i];
    if (m.role !== 'user' || i + 1 >= messages.length || messages[i + 1].role !== 'assistant') { continue; }
    const a: AiChatMessage = messages[i + 1];
    turns.push({ question: m.text, answer: a.text, mode: 'chat', createdAt: m.createdAt,
      attachments: m.attachments.length > 0 ? m.attachments : undefined,
      documents: a.documents.length > 0 ? a.documents.map((d: AiDocument): DiagnosticAiTurnDocument =>
        ({ name: d.name, format: d.format, path: d.path, bytes: d.bytes })) : undefined });
  }
  if (turns.length === 0 || sessionId === '') { return; }
  const previous: DiagnosticAiConversationSession | undefined = store.session(sessionId);
  const now: number = Date.now();
  store.saveSession({
    id: sessionId,
    title: previous !== undefined && previous.title !== '' ? previous.title :
      (turns[0].question.trim().replace(/\s+/g, ' ').slice(0, 40) || 'AI 聊天'),
    createdAt: previous !== undefined ? previous.createdAt : now,
    updatedAt: now,
    providerId: profile !== undefined ? profile.providerId : (previous !== undefined ? previous.providerId : ''),
    modelId: profile !== undefined ? profile.modelId : (previous !== undefined ? previous.modelId : ''),
    turns: turns,
    kind: 'chat'
  });
}

export function aiChatErrorText(error: Object): string {
  const value: string = error instanceof Error ? error.message : '';
  if (value.indexOf('LOCAL_MODEL_PC_ONLY') >= 0) { return '鸿蒙端侧小模型目前只支持 PC/2in1'; }
  if (value.indexOf('LOCAL_MODEL') >= 0) { return '鸿蒙端侧小模型当前不可用'; }
  if (value.indexOf('USE_CASE_NOT_ALLOWED') >= 0) { return '当前 AI 服务的套餐不允许聊天用途，请在辅助 AI 配置中换用按量计费的 API'; }
  if (value.indexOf('POLICY') >= 0) { return '当前 AI 服务配置还不能使用，请在辅助 AI 配置中重新保存'; }
  if (value.indexOf('HTTP_401') >= 0 || value.indexOf('HTTP_403') >= 0) { return 'AI 服务拒绝了请求，请检查 API Key 和模型权限'; }
  if (value.indexOf('HTTP_413') >= 0) { return '内容太长，超出了模型的请求上限；可以移除部分文档或开始新对话'; }
  if (value.indexOf('HTTP_429') >= 0) { return 'AI 服务当前限流，请稍后重试'; }
  if (value.indexOf('HTTP_5') >= 0) { return 'AI 服务暂时不可用，请稍后重试'; }
  if (value.indexOf('HTTP_400') >= 0 || value.indexOf('HTTP_422') >= 0) { return 'AI 服务不接受这个请求，可以换一个模型再试'; }
  if (value.indexOf('TIMEOUT') >= 0) { return 'AI 回答超时（生成长文档需要更久），请重试或换用更快的模型'; }
  if (value.indexOf('NETWORK') >= 0) { return 'AI 服务暂时无法连接，请检查网络'; }
  if (value.indexOf('EMPTY_RESULT') >= 0) { return 'AI 服务返回了空结果，请重试'; }
  return 'AI 请求失败，请重试';
}

/** The AI service profile the chat uses: the one chosen in 辅助 AI 配置, or the only one with a model. */
export function aiChatSelectedProfile(store: DiagnosticAiProfileStore): DiagnosticAiProviderProfile | undefined {
  try {
    const profiles: DiagnosticAiProviderProfile[] = store.list();
    const settings = store.settingsSnapshot();
    const selected: DiagnosticAiProviderProfile | undefined = profiles.find((value: DiagnosticAiProviderProfile): boolean =>
      value.providerId === settings.selectedProviderId && value.modelId === settings.selectedModelId && value.modelId !== '' &&
      (settings.selectedAuthMode === '' || value.authMode === settings.selectedAuthMode));
    if (selected !== undefined) { return selected; }
    const candidates: DiagnosticAiProviderProfile[] = profiles.filter((value: DiagnosticAiProviderProfile): boolean => value.modelId !== '');
    return candidates.length === 1 ? candidates[0] : undefined;
  } catch (_error) { return undefined; }
}

/** Whether the current account may use the AI chat (the AI 助理 Pro entry). */
export function aiChatAllowed(): boolean {
  return ProEntries.visible(PRO_DIAGNOSTICS_ASSISTANT_FEATURE, ProAppRuntime.getInstance().context());
}

/** Whether `owner` is still the signed-in account. */
export function aiChatOwnerStill(owner: string): boolean {
  const scope = AccountSessionCoordinator.getInstance().currentScope();
  const current: string = scope.ownerScopeId.trim() === '' ? 'device-local' : scope.ownerScopeId;
  return current === owner;
}

/** The assistant's personalisation as one line for the model. */
export function aiChatPreferenceText(p: DiagnosticAiAssistantPreferences): string {
  const tone: string = p.personality === 'warm' ? '亲切' : p.personality === 'concise' ? '简洁' :
    p.personality === 'technical' ? '专业' : '平衡';
  const length: string = p.verbosity === 'concise' ? '简短' : p.verbosity === 'detailed' ? '详细' : '适中';
  return '助手名字：' + p.name + '；语气：' + tone + '；回答长度：' + length + '；语言：' + (p.language === 'en-US' ? '英文' : '中文');
}

/** A message as the model sees it in the history: documents added or made, and what became of confirm cards. */
export function aiChatTurnText(message: AiChatMessage): string {
  if (message.role === 'user') {
    return message.text + (message.attachments.length > 0 ? '\n（添加了文档：' + message.attachments.join('、') + '）' : '');
  }
  // What became of its confirm cards, so the model does not ask again for one already done.
  const actions: string = message.actions.map((a: AiChatAction): string => a.title + '：' +
    (a.status === 'done' ? '用户已确认，' + a.result : a.status === 'cancelled' ? '用户已取消' :
      a.status === 'failed' ? '执行失败，' + a.result : '等待用户确认')).join('；');
  return message.text + (message.documents.length > 0 ?
    '\n（已生成文档：' + message.documents.map((d: AiDocument): string => d.name).join('、') + '）' : '') +
    (actions !== '' ? '\n（确认卡片：' + actions + '）' : '');
}

function aiChatUsageText(conversationStore: DiagnosticAiConversationStore, days: number): string {
  const since: number = Date.now() - days * 24 * 3600 * 1000;
  const rows: DiagnosticAiDailyUsage[] = (conversationStore.usage().daily ?? [])
    .filter((row: DiagnosticAiDailyUsage): boolean => new Date(row.day).getTime() >= since - 24 * 3600 * 1000);
  if (rows.length === 0) { return '最近 ' + days.toString() + ' 天没有 AI 请求。'; }
  const total = (pick: (row: DiagnosticAiDailyUsage) => number): number =>
    rows.reduce((sum: number, row: DiagnosticAiDailyUsage): number => sum + pick(row), 0);
  return '最近 ' + days.toString() + ' 天：' + total((r: DiagnosticAiDailyUsage): number => r.requestCount).toString() + ' 次请求，' +
    tokenWords(total((r: DiagnosticAiDailyUsage): number => r.promptTokens + r.completionTokens)) + ' Token，估算 ¥' +
    total((r: DiagnosticAiDailyUsage): number => r.estimatedCostCny).toFixed(2) + '。\n' +
    rows.map((r: DiagnosticAiDailyUsage): string => r.day + '：' + r.requestCount.toString() + ' 次，' +
      tokenWords(r.promptTokens + r.completionTokens) + ' Token，¥' + r.estimatedCostCny.toFixed(2)).join('\n');
}

/**
 * The documents the AI wrote for this account that are still on the device, newest first: from the saved
 * conversations and the one going on.
 */
function aiChatDocuments(conversationStore: DiagnosticAiConversationStore): AiDocument[] {
  const found: AiDocument[] = [];
  const seen: Set<string> = new Set<string>();
  const add = (document: AiDocument): void => {
    if (document.path === '' || seen.has(document.path)) { return; }
    seen.add(document.path);
    if (aiDocumentAvailable(document)) { found.push(document); }
  };
  AiChatMemory.messages.forEach((m: AiChatMessage): void => { m.documents.forEach(add); });
  conversationStore.listSessions().forEach((session: DiagnosticAiConversationSession): void => {
    session.turns.forEach((turn: DiagnosticAiConversationTurn): void => {
      (turn.documents ?? []).forEach((d: DiagnosticAiTurnDocument): void => {
        add(new AiDocument(d.name, d.format, d.path, d.bytes, turn.createdAt));
      });
    });
  });
  return found.sort((a: AiDocument, b: AiDocument): number => b.createdAt - a.createdAt);
}

/** The app data the chat's tools read and change (hosts, connection log, settings, usage, documents, memory…). */
export function aiChatAppData(conversationStore: DiagnosticAiConversationStore): AiChatAppData {
  return {
    documents: (): AiDocument[] => aiChatDocuments(conversationStore),
    conversations: (): AiConversationRow[] => conversationStore.listSessions()
      .sort((a: DiagnosticAiConversationSession, b: DiagnosticAiConversationSession): number => b.updatedAt - a.updatedAt)
      .map((session: DiagnosticAiConversationSession): AiConversationRow => new AiConversationRow(session.id,
        session.title !== '' ? session.title : '（无标题）', diagnosticAiSessionKind(session) === 'chat' ? '聊天' : '助理',
        session.updatedAt, session.turns.length,
        session.turns.reduce((sum: number, turn: DiagnosticAiConversationTurn): number => sum + (turn.documents ?? []).length, 0))),
    currentConversation: (): string => AiChatMemory.sessionId,
    memory: (): string => conversationStore.assistantPreferences().manualMemorySummary,
    memoryEnabled: (): boolean => conversationStore.assistantPreferences().memoryEnabled,
    saveMemory: (text: string): boolean => {
      const preferences: DiagnosticAiAssistantPreferences = conversationStore.assistantPreferences();
      preferences.manualMemorySummary = text;
      return conversationStore.saveAssistantPreferences(preferences);
    },
    featureRequests: (): DiagnosticAiFeatureRequest[] => conversationStore.featureRequests(),
    addFeatureRequest: (text: string): boolean => conversationStore.addFeatureRequest(text) !== null,
    removeFeatureRequests: (text: string): number => conversationStore.removeFeatureRequests(text),
    hosts: (protocol: string): string => aiHostsText(AiAppDataBridge.hosts(), protocol),
    connections: (days: number): string => aiConnectionsText(ConnectionJournal.recent(days)
      .map((e: ConnectionJournalEntry): AiConnectionRow => ({ at: e.at, label: e.label, protocol: e.protocol, outcome: e.outcome,
        detail: e.detail })), days, AiAppDataBridge.hosts()),
    settings: (): string => diagnosticAiSettingCatalog(),
    usage: (days: number): string => aiChatUsageText(conversationStore, days)
  };
}

/** Counts one answer in AI 用量监控. */
export function aiChatRecordUsage(conversationStore: DiagnosticAiConversationStore, modelCatalog: DiagnosticAiModelCatalog,
  profile: DiagnosticAiProviderProfile, reply: AiChatReply): void {
  const usage = reply.usage;
  const cost: number = modelCatalog.estimateCost(profile.providerId, profile.modelId, usage.promptTokens,
    usage.completionTokens, usage.cachedTokens);
  conversationStore.recordUsage(usage.promptTokens, usage.completionTokens, usage.cachedTokens, cost,
    profile.providerId, profile.modelId, usage.estimated === true, true);
}

function sizeLabel(bytes: number): string {
  if (bytes >= 1024 * 1024) { return (bytes / 1024 / 1024).toFixed(1) + ' MB'; }
  return Math.max(1, Math.round(bytes / 1024)).toString() + ' KB';
}

function documentColor(format: string): string {
  if (format === 'docx') { return '#4A8DFF'; }
  if (format === 'xlsx') { return '#34C759'; }
  if (format === 'pptx') { return '#FF9F0A'; }
  if (format === 'pdf') { return '#FF453A'; }
  return '#AEAEB2';
}

/** Column widths of a table, from the longest text in each column (CJK counted double). */
function tableWidths(rows: string[][]): number[] {
  const columns: number = rows.reduce((most: number, row: string[]): number => Math.max(most, row.length), 0);
  const widths: number[] = [];
  for (let c: number = 0; c < columns; c++) {
    let widest: number = 0;
    rows.forEach((row: string[]): void => {
      const cell: string = c < row.length ? row[c] : '';
      let w: number = 0;
      for (let i: number = 0; i < cell.length; i++) { w += cell.charCodeAt(i) > 0x2E80 ? 2 : 1; }
      widest = Math.max(widest, w);
    });
    widths.push(Math.min(220, Math.max(64, widest * 7.5 + 20)));
  }
  return widths;
}

function tokenWords(value: number): string {
  return value >= 10000 ? (value / 10000).toFixed(1) + ' 万' : Math.round(value).toString();
}

/**
 * 聊天模式 inside the AI island: a general chatbot. It sees what the user types, the documents the user adds (picked
 * here or shared from another app) and, through the tools left on in 设置 › AI 工具与技能, the app's hosts,
 * connection log, settings and usage. Installed skills sit under the field as chips. Answers come in Markdown and
 * documents as cards to open in WPS, share or save. A question about the app's own faults gets a suggestion to hand
 * it to 助理, and the chat can float as the orb while the user works; nothing switches by itself.
 */
@Component
export struct AiChatView {
  @Prop revealed: boolean = true;
  /** Room for the chat inside the island (it ends above the keyboard). */
  @Prop bodyLimit: number = 100000;
  @Prop deviceClass: string = 'phone';
  @Prop owner: string = 'device-local';
  @StorageProp(AI_CHAT_REFRESH_KEY) @Watch('reloadFromMemory') refreshToken: number = 0;
  /** AI 语音 (Beta) is on: the empty field offers voice mode. */
  @StorageProp(AI_VOICE_ENABLED) voiceEnabled: boolean = false;
  /** To 助理 (with a question to ask there, or '' just to switch). */
  onSwitchMode: (mode: string, question: string) => void = (_mode: string, _question: string): void => {};
  onActivityChanged: (active: boolean) => void = (_active: boolean): void => {};
  /** Shrink the island into the floating orb (the chat waits there). */
  onFloat: () => void = (): void => {};
  /** 设置 › AI 工具与技能. */
  onOpenSkills: () => void = (): void => {};
  /** The small chat beside the floating orb: the latest exchange and a field; 展开 goes back to the island. */
  @Prop mini: boolean = false;
  /** Siri's dark glass or 小艺's blue glass: the ink follows (AI 风格). */
  @StorageProp(AI_STYLE) aiStyle: string = 'siri';
  @StorageProp('diagnosticAiReducedMotion') reducedMotion: boolean = false;
  /** Beside the orb: what the orb hears goes into the field as it is recognized, and is sent when the user stops. */
  @StorageProp(AI_ORB_DICTATION) @Watch('onDictation') dictation: string = '';
  /** The AI's switch_mode 'new': once its answer is in (and has been seen a moment), a new chat starts here. */
  @StorageProp(AI_MODE_REQUEST) @Watch('onModeRequest') modeRequest: string = '';
  @State private dictating: boolean = false;
  /** 新对话: the conversation lifts away first (clearing), then the empty chat rises in (freshStart). */
  @State private clearing: boolean = false;
  @State private freshStart: boolean = false;
  @StorageProp('currentTheme') theme: string = 'light';
  /** The small chat's 展开 (none in a session: there is no full panel there). */
  @Prop canExpand: boolean = true;
  onExpand: () => void = (): void => {};
  onCardSize: (height: number) => void = (_height: number): void => {};
  @State private messages: AiChatMessage[] = [];
  @State private attachments: AiAttachment[] = [];
  @State private pending: AiAttachment[] = [];
  @State private draft: string = '';
  @State private busy: boolean = false;
  @State private status: string = '';
  @State private importing: boolean = false;
  @State private error: string = '';
  /** A question that looks like one for 助理, waiting for the user's choice. */
  @State private routeQuestion: string = '';
  @State private expanded: boolean = false;
  @State private providerName: string = '';
  @State private skills: AiSkill[] = [];
  @State private chosenSkill: AiSkill | null = null;
  @State private contentHeight: number = 0;
  /** How much taller than one line the chat field has grown: the messages give that room back. */
  @State private composerExtra: number = 0;
  private composerBase: number = 0;
  /** The message that just arrived (it fades in; the others are simply there). */
  @State private freshId: string = '';
  /** Dictating into the field; what was typed before it started. */
  /** The message being read aloud ('' none). */
  @State private speakingId: string = '';
  /** An action card being carried out. */
  @State private runningAction: string = '';
  /** Parsed Markdown per message, so a status line changing does not parse every answer again. */
  private blockCache: Map<string, AiMdBlock[]> = new Map<string, AiMdBlock[]>();
  @State private toolsOn: number = 0;
  private routeBypass: string = '';
  private alive: boolean = true;
  private sessionId: string = '';
  private readonly scroller: Scroller = new Scroller();
  /** Where each message starts in the scrolling conversation (to show a new answer from its question). */
  private positions: Map<string, number> = new Map<string, number>();
  private phrases: string[] = [];
  private phraseIndex: number = 0;
  private statusTimer: number = -1;
  private toolStatusAt: number = 0;
  private readonly chat: AiChatService = new AiChatService();
  private readonly store: DiagnosticAiProfileStore = new DiagnosticAiProfileStore();
  private readonly conversationStore: DiagnosticAiConversationStore = new DiagnosticAiConversationStore();
  private readonly modelCatalog: DiagnosticAiModelCatalog = new DiagnosticAiModelCatalog();
  private readonly skillStore: AiSkillStore = new AiSkillStore();
  private preferences: DiagnosticAiAssistantPreferences = defaultDiagnosticAiAssistantPreferences();

  aboutToAppear(): void {
    this.alive = true;
    // Shown because the orb began to listen: the field shows what it hears from the start.
    if (this.mini && aiOrbDictationDecode(this.dictation).state === 'listen') {
      this.dictating = true;
      this.draft = aiOrbDictationDecode(this.dictation).text;
    }
    const context: common.UIAbilityContext = this.context();
    try {
      this.store.init(context, this.owner);
      this.conversationStore.init(context, this.owner);
      this.modelCatalog.init(context, this.owner);
      this.skillStore.init(context, this.owner);
      this.preferences = this.conversationStore.assistantPreferences();
    } catch (_error) { /* requests fail closed below */ }
    if (AiChatMemory.owner !== this.owner) { AiChatMemory.clear(this.owner); }
    const profile: DiagnosticAiProviderProfile | undefined = this.selectedProfile();
    const manifest = profile !== undefined ? diagnosticAiProviderManifest(profile.providerId) : null;
    this.providerName = manifest !== null ? manifest.displayName : '';
    this.reloadFromMemory();
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.stopStatus();
    this.persist();
  }

  private onModeRequest(): void {
    if (this.modeRequest.split('@')[0] !== 'new') { return; }
    const asked: string = this.modeRequest;
    let waited: number = 0;
    const attempt = (): void => {
      if (!this.alive || this.modeRequest !== asked) { return; }
      if ((this.busy || AiChatMemory.requestId !== '') && waited < 30000) {
        waited += 300;
        setTimeout(attempt, 300);
        return;
      }
      this.startNewChat();
      this.toast('已开始新对话，之前的对话在对话记录里');
    };
    // The short reply ("好，重新开始") stays in view for a moment before the chat clears.
    setTimeout(attempt, 1200);
  }

  private onDictation(): void {
    if (!this.mini || !this.alive) { return; }
    const heard: AiOrbDictation = aiOrbDictationDecode(this.dictation);
    if (heard.state === 'listen') { this.dictating = true; this.draft = heard.text; return; }
    this.dictating = false;
    if (heard.state === 'done') { this.draft = heard.text; this.submit(); return; }
    if (heard.state === 'cancel') { this.draft = ''; }
  }

  /** Pick up what changed outside: a resumed chat, shared documents, a question from 助理, an answer that landed. */
  private reloadFromMemory(): void {
    if (AiChatMemory.owner !== this.owner) { AiChatMemory.clear(this.owner); }
    this.skills = this.skillStore.installedSkills();
    this.toolsOn = this.skillStore.enabledTools().length;
    const inFlight: boolean = AiChatMemory.requestId !== '';
    if (this.busy && inFlight) { return; }
    this.sessionId = AiChatMemory.sessionId;
    if (AiChatMemory.messages.length === 0) { this.contentHeight = 0; }
    this.messages = AiChatMemory.messages.slice();
    this.attachments = AiChatMemory.attachments.slice();
    this.pending = AiChatMemory.pending.slice();
    this.error = AiChatMemory.error;
    this.routeQuestion = '';
    if (inFlight !== this.busy) {
      this.busy = inFlight;
      this.onActivityChanged(inFlight);
    }
    if (inFlight) {
      this.status = AiChatMemory.status !== '' ? AiChatMemory.status : '正在思考';
      this.startStatus(this.status, []);
    }
    if (AiShareInbox.pending()) { void this.importShared(AiShareInbox.take()); }
    if (AiChatMemory.handoff !== '' && !inFlight) {
      const question: string = AiChatMemory.handoff;
      AiChatMemory.handoff = '';
      this.routeBypass = question;
      setTimeout((): void => { if (this.alive) { void this.ask(question, false); } }, 120);
    } else if (this.messages.length > 0) {
      setTimeout((): void => { this.scroller.scrollEdge(Edge.Bottom); }, 80);
    }
  }

  private persist(): void {
    AiChatMemory.owner = this.owner;
    AiChatMemory.sessionId = this.sessionId;
    AiChatMemory.messages = this.messages.slice();
    AiChatMemory.attachments = this.attachments.slice();
    AiChatMemory.pending = this.pending.slice();
  }

  private allowed(): boolean { return aiChatAllowed(); }

  private ownerStill(): boolean { return aiChatOwnerStill(this.owner); }

  private selectedProfile(): DiagnosticAiProviderProfile | undefined { return aiChatSelectedProfile(this.store); }

  private toast(message: string): void {
    try { this.getUIContext().getPromptAction().showToast({ message: message, duration: 2200 }); } catch (_error) { /* no toast */ }
  }

  private hideKeyboard(): void {
    try { inputMethod.getController().hideTextInput(); } catch (_error) { /* keyboard already down */ }
  }

  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }

  private float(): void {
    this.hideKeyboard();
    this.persist();
    this.onFloat();
  }

  // ------------------------------------------------------------------ status while thinking

  /** Rotate through lines that fit the question; a tool's own status ("正在查看主机列表") wins for a while. */
  private startStatus(first: string, phrases: string[]): void {
    this.stopStatus();
    this.phrases = phrases;
    this.phraseIndex = 0;
    this.status = first;
    AiChatMemory.status = first;
    this.statusTimer = setInterval((): void => {
      if (!this.alive || Date.now() - this.toolStatusAt < 2600 || this.phrases.length === 0) { return; }
      this.phraseIndex = Math.min(this.phraseIndex + 1, this.phrases.length - 1);
      const next: string = this.phrases[this.phraseIndex];
      if (next !== this.status) {
        this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseOut }, (): void => { this.status = next; });
      }
    }, 2800);
  }

  private stopStatus(): void {
    if (this.statusTimer >= 0) { clearInterval(this.statusTimer); this.statusTimer = -1; }
  }

  private progress(status: string): void {
    AiChatMemory.status = status;
    this.toolStatusAt = Date.now();
    if (this.alive && status !== this.status) {
      this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseOut }, (): void => { this.status = status; });
    }
  }

  // ------------------------------------------------------------------ app data for the tools

  private appData(): AiChatAppData { return aiChatAppData(this.conversationStore); }

  // ------------------------------------------------------------------ documents

  private async addDocuments(): Promise<void> {
    if (this.importing || this.busy) { return; }
    const room: number = AI_CHAT_MAX_ATTACHMENTS - this.pending.length;
    if (room <= 0) { this.toast('一次最多添加 ' + AI_CHAT_MAX_ATTACHMENTS.toString() + ' 个文档'); return; }
    let uris: string[] = [];
    try { uris = await aiPickDocuments(this.context(), room); } catch (_error) { this.toast('无法打开文件选择'); return; }
    await this.importUris(uris.map((uri: string): AiSharedItem => new AiSharedItem(uri, '', '')));
  }

  private async importShared(items: AiSharedItem[]): Promise<void> {
    await this.importUris(items);
    if (this.draft.trim() === '' && this.pending.length > 0) { this.draft = '帮我总结这些内容的要点'; }
  }

  private async importUris(items: AiSharedItem[]): Promise<void> {
    if (items.length === 0) { return; }
    this.importing = true;
    try {
      for (const item of items) {
        if (this.pending.length >= AI_CHAT_MAX_ATTACHMENTS) { break; }
        try {
          const attachment: AiAttachment = item.uri === '' ? aiTextAttachment(item.name, item.text) :
            await aiImportDocument(this.context(), item.uri, aiDocumentKind(item.name) !== '' ? item.name : '');
          if (!this.alive) { return; }
          this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) }, (): void => {
            this.pending = this.pending.filter((a: AiAttachment): boolean => a.name !== attachment.name).concat([attachment]);
          });
        } catch (error) {
          this.toast(aiDocumentErrorText(error as Object));
        }
      }
    } finally {
      this.importing = false;
      this.persist();
    }
  }

  private removePending(attachment: AiAttachment): void {
    this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) }, (): void => {
      this.pending = this.pending.filter((a: AiAttachment): boolean => a.id !== attachment.id);
    });
    this.persist();
  }

  private async openDocument(document: AiDocument, thenFloat: boolean): Promise<void> {
    if (!aiDocumentAvailable(document)) { this.toast('文件已不在设备上'); return; }
    try {
      await aiOpenDocument(this.context(), document);
      if (thenFloat) { this.float(); }
    } catch (_error) { this.toast('没有找到可以打开这个文件的应用，可以先分享或另存'); }
  }

  private async shareDocument(document: AiDocument): Promise<void> {
    if (!aiDocumentAvailable(document)) { this.toast('文件已不在设备上'); return; }
    try { await aiShareDocument(this.context(), document); } catch (_error) { this.toast('无法打开分享'); }
  }

  private async saveDocument(document: AiDocument): Promise<void> {
    if (!aiDocumentAvailable(document)) { this.toast('文件已不在设备上'); return; }
    try { if (await aiSaveDocumentAs(this.context(), document)) { this.toast('已保存「' + document.name + '」'); } }
    catch (_error) { this.toast('保存失败'); }
  }

  /** 存为 Word: any answer becomes a document, model tools or not. */
  private saveAnswerAsDocument(message: AiChatMessage): void {
    const firstLine: string = message.text.split('\n').map((line: string): string => line.replace(/^#+\s*/, '').trim())
      .find((line: string): boolean => line !== '') ?? 'AI 回答';
    try {
      const document: AiDocument = aiCreateDocument(this.context(), firstLine.slice(0, 30), 'docx', message.text);
      this.messages = this.messages.map((m: AiChatMessage): AiChatMessage => m.id !== message.id ? m :
        new AiChatMessage(m.id, m.role, m.text, m.attachments, m.documents.concat([document]), m.createdAt, m.suggestions, m.actions));
      this.persist();
      aiChatSaveSession(this.conversationStore, this.sessionId, this.messages, undefined);
    } catch (_error) { this.toast('生成文档失败'); }
  }

  private copyText(text: string): void {
    try {
      pasteboard.getSystemPasteboard().setDataSync(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
      this.toast('已复制');
    } catch (_error) { this.toast('复制失败'); }
  }

  // ------------------------------------------------------------------ voice, reading aloud, actions

  private toggleReadAloud(message: AiChatMessage): void {
    if (this.speakingId === message.id) { AiReadAloud.stop(); return; }
    void AiReadAloud.speak(this.context(), this.owner, message.id, message.text, (id: string): void => {
      if (!this.alive) { return; }
      this.speakingId = id;
      // The list only re-keys its rows when the array changes: hand it a new one so 朗读 / 停止朗读 redraws.
      this.messages = this.messages.slice();
    }).then((note: string): void => { if (note !== '' && this.alive) { this.toast(note); } });
  }

  private setAction(messageId: string, action: AiChatAction, status: string, result: string): void {
    this.messages = this.messages.map((m: AiChatMessage): AiChatMessage => {
      if (m.id !== messageId) { return m; }
      const actions: AiChatAction[] = m.actions.map((a: AiChatAction): AiChatAction => {
        if (a.id !== action.id) { return a; }
        const next: AiChatAction = new AiChatAction(a.id, a.tool, a.title, a.detail, a.args);
        next.status = status;
        next.result = result;
        return next;
      });
      return new AiChatMessage(m.id, m.role, m.text, m.attachments, m.documents, m.createdAt, m.suggestions, actions);
    });
    this.persist();
  }

  /** The user confirmed a card: do it now, and say on the card what happened. */
  private async confirmAction(message: AiChatMessage, action: AiChatAction): Promise<void> {
    if (this.runningAction !== '' || (action.status !== 'pending' && action.status !== 'failed')) { return; }
    this.runningAction = action.id;
    try {
      // The host's edit sheet or delete dialog comes up over the app: the chat waits as the orb meanwhile.
      if (action.tool === 'edit_host' || action.tool === 'delete_host') {
        this.onFloat();
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 360); });
      }
      const result: string = await aiRunAction(this.context(), action, this.owner);
      this.setAction(message.id, action, 'done', result);
    } catch (error) {
      const why: string = aiActionErrorText(error as Object);
      hilog.warn(0x0000, 'AiChat', 'action %{public}s failed: %{public}s', action.tool, why);
      this.setAction(message.id, action, 'failed', why);
      this.toast('没有完成：' + why);
    } finally {
      this.runningAction = '';
    }
  }

  private async printDocument(document: AiDocument): Promise<void> {
    if (!aiDocumentAvailable(document)) { this.toast('文件已不在设备上'); return; }
    try { await aiPrintDocument(this.context(), document); } catch (_error) { this.toast('无法打开打印'); }
  }

  // ------------------------------------------------------------------ skills

  private useSkill(skill: AiSkill): void {
    this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) }, (): void => { this.chosenSkill = skill; });
    if (skill.needsDocument) {
      void this.addDocuments().then((): void => {
        if (this.draft.trim() === '') { this.draft = '帮我' + skill.name + '：'; }
      });
      return;
    }
    if (this.draft.trim() === '') { this.draft = skill.starter !== '' ? skill.starter : '帮我' + skill.name + '：'; }
    setTimeout((): void => { focusControl.requestFocus(this.messages.length === 0 ? 'aiChatQuestion' : 'aiChatDraft'); }, 60);
  }

  /** Skills that fit what is being typed (none picked yet). */
  private typedSkills(): AiSkill[] {
    if (this.chosenSkill !== null || this.draft.trim().length < 2) { return []; }
    return aiSkillsForQuestion(this.skills, this.draft).slice(0, 3);
  }

  // ------------------------------------------------------------------ asking

  private submit(): void {
    if (this.busy || this.importing) { return; }
    const typed: string = this.draft.trim();
    if (typed === '' && this.pending.length === 0) { return; }
    const question: string = typed !== '' ? typed : '请阅读我添加的文档，简要说说它讲了什么。';
    // A card waiting under the last answer: "确认" / "好的" / "确认打开 AI 配置" (typed, or the AI's own pill) does it
    // now, "不用了" cancels it — asking the AI again only got "the card is there, tap it".
    if (this.pending.length === 0 && this.answerCardReply(typed)) { this.draft = ''; this.hideKeyboard(); return; }
    // 拜拜 / 回到语音 / 切到助理 / 悬浮球: done by the app at once, in any mode (the open panel acts on the request).
    const command: string = this.pending.length === 0 ? aiModeCommand(typed) : '';
    if (command === 'orb') { this.draft = ''; this.float(); return; }
    if (command === 'new') { this.draft = ''; this.hideKeyboard(); this.startNewChat(); return; }
    if (command !== '') {
      this.draft = '';
      this.hideKeyboard();
      this.persist();
      AppStorage.setOrCreate(AI_MODE_REQUEST, command + '@' + Date.now().toString());
      return;
    }
    // Diagnosing the app or sending feedback needs 助理's capture and mail flow: it goes there by itself. The small
    // chat has no 助理 beside it, so it answers there itself rather than dropping the question.
    if (!this.mini && this.routeBypass !== question &&
      aiAutoRoute(question, 'chat', this.pending.length + this.attachments.length > 0) === 'assistant') {
      this.draft = '';
      this.hideKeyboard();
      this.persist();
      this.onSwitchMode('assistant', question);
      return;
    }
    this.routeBypass = '';
    this.draft = '';
    this.hideKeyboard();
    void this.ask(question, false);
  }

  /** The one card waiting under the latest answer, confirmed or cancelled by what was typed (true: handled). */
  private answerCardReply(typed: string): boolean {
    const last: AiChatMessage | undefined = this.messages.length > 0 ? this.messages[this.messages.length - 1] : undefined;
    if (last === undefined || last.role !== 'assistant' || this.runningAction !== '') { return false; }
    const waiting: AiChatAction[] = last.actions.filter((a: AiChatAction): boolean => a.status === 'pending');
    if (waiting.length !== 1) { return false; }
    const reply: string = aiPendingCardReply(typed, waiting[0].title);
    if (reply === 'confirm') { void this.confirmAction(last, waiting[0]); return true; }
    if (reply === 'cancel') { this.setAction(last.id, waiting[0], 'cancelled', ''); return true; }
    return false;
  }

  private retry(): void {
    const last: AiChatMessage | undefined = this.messages.length > 0 ? this.messages[this.messages.length - 1] : undefined;
    if (last === undefined || last.role !== 'user' || this.busy) { return; }
    void this.ask(last.text, true);
  }

  private turnText(message: AiChatMessage): string { return aiChatTurnText(message); }

  private preferenceText(): string { return aiChatPreferenceText(this.preferences); }

  private async ask(question: string, retry: boolean): Promise<void> {
    if (!this.allowed()) { this.error = '当前账号没有 AI 助理权限'; return; }
    const profile: DiagnosticAiProviderProfile | undefined = this.selectedProfile();
    if (profile === undefined) { this.error = '请先在辅助 AI 配置中保存 API Key 并选择模型'; return; }
    let secret: string = '';
    try { secret = this.store.secret(profile); } catch (_error) { secret = ''; }
    if (!diagnosticAiProviderIsHarmonyLocal(profile.providerId) && secret.trim() === '') {
      this.error = 'API Key 无法从本机安全存储读回，请在辅助 AI 配置中重新保存'; return;
    }
    const sent: AiAttachment[] = retry ? [] : this.pending;
    if (!retry) {
      const message: AiChatMessage = new AiChatMessage(newMessageId(), 'user', question,
        sent.map((a: AiAttachment): string => a.name), [], Date.now());
      // Not inside an animation: the switch from the empty chat to the conversation must not be animated through
      // in-between layouts (it flashed a half-height card with the add and send buttons). The bubble fades in itself.
      this.freshId = message.id;
      this.messages = this.messages.concat([message]);
      this.attachments = this.attachments.filter((a: AiAttachment): boolean =>
        !sent.some((s: AiAttachment): boolean => s.name === a.name)).concat(sent).slice(-AI_CHAT_MAX_ATTACHMENTS);
      this.pending = [];
    }
    if (this.sessionId === '') {
      this.sessionId = 'chat-' + Date.now().toString() + '-' + Math.floor(Math.random() * 100000).toString();
    }
    const chosen: string[] = this.chosenSkill !== null ? [this.chosenSkill.id] : [];
    const requestId: string = newMessageId();
    AiChatMemory.requestId = requestId;
    AiChatMemory.error = '';
    this.error = ''; this.routeQuestion = ''; this.chosenSkill = null;
    this.busy = true; this.onActivityChanged(true);
    const docNames: string[] = sent.map((a: AiAttachment): string => a.name);
    const phrases: string[] = aiThinkingPhrases(question, docNames);
    this.startStatus(phrases[0], phrases);
    this.persist();
    const sessionId: string = this.sessionId;
    setTimeout((): void => { this.scroller.scrollEdge(Edge.Bottom); }, 80);
    const askedId: string = this.messages.length > 0 ? this.messages[this.messages.length - 1].id : '';
    const tools: AiToolSpec[] = this.skillStore.enabledTools();
    // 记忆 may have changed since the view opened (update_memory, or 个性化设置).
    try { this.preferences = this.conversationStore.assistantPreferences(); } catch (_error) { /* keep what we have */ }
    try {
      const turns: AiChatTurn[] = this.messages.filter((m: AiChatMessage): boolean => m.role === 'user' || m.role === 'assistant')
        .map((m: AiChatMessage): AiChatTurn => new AiChatTurn(m.role, this.turnText(m)));
      const reply: AiChatReply = await this.chat.respond(this.context(), profile, secret, {
        turns: turns, attachments: this.attachments, preferences: this.preferenceText(),
        memory: this.preferences.memoryEnabled ? this.preferences.manualMemorySummary.trim().slice(0, 1200) : '',
        tools: tools, skills: this.skills, chosenSkills: chosen, appData: this.appData(),
        onProgress: (status: string): void => { this.progress(status); }
      });
      if (AiChatMemory.requestId !== requestId) { return; }
      if (!this.ownerStill() || !this.allowed()) { AiChatMemory.error = '账号已变化，已丢弃这次回答'; return; }
      const answer: AiChatMessage = new AiChatMessage(newMessageId(), 'assistant', reply.text, [], reply.documents, Date.now(),
        reply.suggestions, reply.actions);
      // The answer lands in the chat's memory whether or not this view is still up (the island may float meanwhile).
      if (this.alive) {
        this.freshId = answer.id;
        this.messages = this.messages.concat([answer]);
        this.persist();
        // Once it has risen in, the answer is like any other (redrawn later, it must not rise in again).
        setTimeout((): void => { if (this.freshId === answer.id) { this.freshId = ''; } }, 1600);
      } else {
        AiChatMemory.messages = AiChatMemory.messages.concat([answer]);
      }
      aiChatSaveSession(this.conversationStore, sessionId, AiChatMemory.messages, profile);
      this.recordUsage(profile, reply);
      hilog.info(0x0000, 'AiChat', 'answered chars=%{public}s docs=%{public}s tools=%{public}s', reply.text.length.toString(),
        reply.documents.length.toString(), reply.usedTools ? 'yes' : 'no');
      if (this.alive) {
        // Show the new answer from its question, not from its end.
        setTimeout((): void => {
          const y: number | undefined = this.positions.get(askedId);
          if (y !== undefined) { this.scroller.scrollTo({ xOffset: 0, yOffset: Math.max(0, y - 4) }); }
        }, 200);
      }
    } catch (error) {
      if (AiChatMemory.requestId !== requestId) { return; }
      AiChatMemory.error = aiChatErrorText(error as Object);
      try { this.conversationStore.recordFailure(profile.providerId, profile.modelId); } catch (_e) { /* best effort */ }
    } finally {
      if (AiChatMemory.requestId === requestId) {
        AiChatMemory.requestId = '';
        AiChatMemory.status = '';
        if (this.alive) {
          this.stopStatus();
          this.error = AiChatMemory.error;
          this.busy = false;
          this.onActivityChanged(false);
        } else {
          // The view that comes back (or the panel) picks the answer up.
          aiChatRefresh();
        }
      }
    }
  }

  private recordUsage(profile: DiagnosticAiProviderProfile, reply: AiChatReply): void {
    aiChatRecordUsage(this.conversationStore, this.modelCatalog, profile, reply);
  }

  private startNewChat(): void {
    if (this.busy || this.clearing) { return; }
    this.hideKeyboard();
    if (this.messages.length === 0 || this.reducedMotion) { this.resetChat(); return; }
    // The conversation lifts away and fades, then the empty chat rises in where it was.
    this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseIn }, (): void => { this.clearing = true; });
    setTimeout((): void => {
      if (!this.alive) { return; }
      this.freshStart = true;
      this.resetChat();
      this.clearing = false;
      setTimeout((): void => { this.freshStart = false; }, 900);
    }, 190);
  }

  private resetChat(): void {
    AiChatMemory.clear(this.owner);
    AiChatMemory.active = true;
    this.messages = []; this.attachments = []; this.pending = []; this.draft = ''; this.error = '';
    this.routeQuestion = ''; this.sessionId = ''; this.expanded = false; this.chosenSkill = null;
    this.contentHeight = 0; this.freshId = '';
    this.positions.clear();
    this.blockCache.clear();
    setTimeout((): void => { focusControl.requestFocus('aiChatQuestion'); }, 300);
  }

  /** Names of documents earlier messages used that this chat no longer holds (a resumed chat keeps no file text). */
  private missingAttachments(): string[] {
    const missing: string[] = [];
    this.messages.forEach((m: AiChatMessage): void => {
      m.attachments.forEach((name: string): void => {
        if (missing.indexOf(name) < 0 && !this.attachments.some((a: AiAttachment): boolean => a.name === name)) { missing.push(name); }
      });
    });
    return missing;
  }

  /** The tallest the conversation may scroll in: the card's usual (or expanded) height minus the rows around it. */
  private scrollLimit(): number {
    const usual: number = this.deviceClass === 'phone' ? 480 : 560;
    const card: number = Math.min(this.expanded ? 100000 : usual, this.bodyLimit);
    const chrome: number = AI_CHAT_HEADER_HEIGHT + 12 + 46 + this.composerExtra + 12 + (this.pending.length > 0 || this.importing ? 42 : 0) +
      (this.chosenSkill !== null || this.typedSkills().length > 0 || this.answerPills().length > 0 ? 44 : 0) +
      (this.missingAttachments().length > 0 && this.pending.length === 0 ? 30 : 0);
    return Math.max(120, card - chrome);
  }

  private privacyLine(): string {
    const target: string = this.providerName !== '' ? '发送给 ' + this.providerName : '发送给你选择的 AI 服务';
    return this.toolsOn > 0 ? '会' + target + '：你输入的内容、添加的文档，以及开启的工具读取的 App 数据（主机名、连接记录等，不含地址和密码）。' :
      '只会' + target + '你输入的内容和添加的文档。';
  }

  /** A table in the answer can go to Excel. */
  private exportAnswerAsSheet(message: AiChatMessage): void {
    const firstLine: string = message.text.split('\n').map((line: string): string => line.replace(/^#+\s*/, '').trim())
      .find((line: string): boolean => line !== '' && line.indexOf('|') < 0) ?? 'AI 表格';
    try {
      const document: AiDocument = aiCreateDocument(this.context(), firstLine.slice(0, 30), 'xlsx', message.text);
      this.messages = this.messages.map((m: AiChatMessage): AiChatMessage => m.id !== message.id ? m :
        new AiChatMessage(m.id, m.role, m.text, m.attachments, m.documents.concat([document]), m.createdAt, m.suggestions, m.actions));
      this.persist();
      aiChatSaveSession(this.conversationStore, this.sessionId, this.messages, undefined);
    } catch (_error) { this.toast('生成表格失败'); }
  }

  /**
   * Pills under the latest answer: the AI's own next steps first, then what the app can do with the answer right
   * away (a table to Excel, a long answer to Word), and the floating orb.
   */
  private answerPills(): AiChatPill[] {
    if (this.busy || this.messages.length === 0 || this.draft.trim() !== '' || this.routeQuestion !== '') { return []; }
    const last: AiChatMessage = this.messages[this.messages.length - 1];
    if (last.role !== 'assistant') { return []; }
    const pills: AiChatPill[] = last.suggestions.map((text: string, i: number): AiChatPill =>
      new AiChatPill('s' + i.toString() + last.id, text, 'ask'));
    const hasTable: boolean = this.blocksOf(last).some((block: AiMdBlock): boolean => block.kind === 'table');
    if (hasTable && !last.documents.some((d: AiDocument): boolean => d.format === 'xlsx')) {
      pills.push(new AiChatPill('excel' + last.id, '导出 Excel', 'excel'));
    } else if (last.documents.length === 0 && last.text.length > 200 &&
      !pills.some((p: AiChatPill): boolean => p.label.indexOf('Word') >= 0)) {
      pills.push(new AiChatPill('word' + last.id, '存为 Word', 'word'));
    }
    pills.push(new AiChatPill('float' + last.id, '缩成悬浮球', 'float'));
    return pills.slice(0, 5);
  }

  private runPill(pill: AiChatPill): void {
    const last: AiChatMessage = this.messages[this.messages.length - 1];
    if (pill.kind === 'ask') { this.draft = pill.label; this.submit(); return; }
    if (pill.kind === 'excel') { this.exportAnswerAsSheet(last); return; }
    if (pill.kind === 'word') { this.saveAnswerAsDocument(last); return; }
    this.float();
  }

  /** Pills rise in one after another and settle with a little spring, as the assistant's do. */
  private pillTransition(index: number): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 18 }))
        .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
        .animation({ curve: curves.springMotion(0.62, 0.58), delay: 120 + index * 110 }),
      TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.9, y: 0.9 }))
        .animation({ duration: 140, curve: Curve.EaseIn }));
  }

  // ------------------------------------------------------------------ views

  @Builder private glyphButton(symbol: Resource, label: string, action: () => void) {
    Stack() {
      SymbolGlyph(symbol).fontSize(16).fontColor(['#FFFFFF'])
    }
    .width(34).height(34).borderRadius(17).backgroundColor(aiInk(this.aiStyle, 'fillGray'))
    .accessibilityText(label)
    .onClick(action)
  }

  /** The header: the panel's 助理 | 聊天 switch sits over its left end; float, new chat and expand on the right. */
  @Builder private header() {
    Row({ space: 8 }) {
      Blank()
      this.glyphButton($r('sys.symbol.smal_window_playback'), '缩成悬浮球', (): void => { this.float(); })
      if (this.messages.length > 0) {
        this.glyphButton($r('sys.symbol.square_and_pencil'), '新对话', (): void => { this.startNewChat(); })
        this.glyphButton($r(this.expanded ? 'sys.symbol.arrow_down_right_and_arrow_up_left' :
          'sys.symbol.arrow_up_left_and_arrow_down_right'), this.expanded ? '收起' : '展开', (): void => {
          this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) }, (): void => { this.expanded = !this.expanded; });
        })
      }
    }.width('100%').height(AI_CHAT_HEADER_HEIGHT)
  }

  @Builder private smallPill(label: string, primary: boolean, action: () => void) {
    Text(label).fontSize(13).fontWeight(FontWeight.Medium).fontColor(primary ? '#000000' : '#FFFFFF')
      .height(32).padding({ left: 14, right: 14 }).borderRadius(16)
      .backgroundColor(primary ? '#F2F2F7' : aiInk(this.aiStyle, 'surfaceRaised'))
      .onClick(action)
  }

  @Builder private chip(label: string, symbol: Resource, index: number, action: () => void) {
    Row({ space: 6 }) {
      SymbolGlyph(symbol).fontSize(13).fontColor([aiInk(this.aiStyle, 'icon')])
      Text(label).fontSize(13).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
    }
    .height(32).padding({ left: 12, right: 14 }).borderRadius(16)
    .backgroundColor('#B31C1C1E').border({ width: 0.5, color: '#33FFFFFF' })
    .margin({ right: 8, top: 4, bottom: 4 })
    .transition(this.pillTransition(index))
    .onClick(action)
  }

  @Builder private attachmentChip(attachment: AiAttachment, removable: boolean) {
    Row({ space: 6 }) {
      SymbolGlyph($r(attachment.kind === 'pdf' ? 'sys.symbol.pdf_doc' : 'sys.symbol.doc_text_fill')).fontSize(14)
        .fontColor([documentColor(attachment.kind)])
      Text(attachment.name).fontSize(12).fontColor(aiInk(this.aiStyle, 'textSoft')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 150 })
      if (removable) {
        SymbolGlyph($r('sys.symbol.xmark_circle_fill')).fontSize(14).fontColor([aiInk(this.aiStyle, 'text2')])
          .onClick((): void => { this.removePending(attachment); })
      }
    }
    .height(30).padding({ left: 10, right: removable ? 6 : 10 }).borderRadius(15).backgroundColor(aiInk(this.aiStyle, 'surface'))
    .margin({ right: 6, bottom: 6 })
  }

  @Builder private pendingRow() {
    if (this.pending.length > 0 || this.importing) {
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.pending, (item: AiAttachment): void => { this.attachmentChip(item, true) },
          (item: AiAttachment): string => 'pending-' + item.id)
        if (this.importing) {
          Row({ space: 6 }) {
            LoadingProgress().width(16).height(16).color(aiInk(this.aiStyle, 'icon'))
            Text('正在读取文档…').fontSize(12).fontColor(aiInk(this.aiStyle, 'icon'))
          }.height(30).padding({ left: 10, right: 10 }).borderRadius(15).backgroundColor(aiInk(this.aiStyle, 'surface')).margin({ bottom: 6 })
        }
      }.width('100%')
    }
  }

  /** The skill picked for the next message, or skills that fit what is being typed. */
  @Builder private skillRow() {
    if (this.chosenSkill !== null) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.wand_and_stars')).fontSize(13).fontColor(['#B9A6FF'])
        Text('技能 · ' + (this.chosenSkill as AiSkill).name).fontSize(12).fontColor(aiInk(this.aiStyle, 'textSoft'))
        SymbolGlyph($r('sys.symbol.xmark_circle_fill')).fontSize(14).fontColor([aiInk(this.aiStyle, 'text2')])
          .onClick((): void => { this.chosenSkill = null; })
      }.height(30).padding({ left: 10, right: 6 }).borderRadius(15).backgroundColor('#2C2346')
      .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.9, y: 0.9 })))
    } else if (this.typedSkills().length > 0) {
      Row() {
        ForEach(this.typedSkills(), (skill: AiSkill, index: number): void => {
          this.chip('用「' + skill.name + '」', $r('sys.symbol.wand_and_stars'), index, (): void => { this.useSkill(skill); })
        }, (skill: AiSkill): string => 'typed-' + skill.id)
      }.width('100%')
    }
  }

  @Builder private spansText(spans: AiMdSpan[], size: number, color: string, weight: FontWeight) {
    Text() {
      ForEach(spans, (span: AiMdSpan): void => {
        Span(span.text).fontSize(size).fontColor(span.code ? '#FFD28A' : color)
          .fontWeight(span.bold ? FontWeight.Bold : weight)
      }, (span: AiMdSpan, index: number): string => index.toString() + span.text.slice(0, 12))
    }.fontSize(size).lineHeight(size * 1.5).fontColor(color).width('100%').copyOption(CopyOptions.LocalDevice)
  }

  @Builder private tableView(rows: string[][]) {
    Scroll() {
      Column() {
        ForEach(rows, (row: string[], r: number): void => {
          Row() {
            ForEach(row, (cell: string, c: number): void => {
              Text(cell).fontSize(13).lineHeight(18).fontColor(r === 0 ? '#FFFFFF' : aiInk(this.aiStyle, 'textSoft'))
                .fontWeight(r === 0 ? FontWeight.Medium : FontWeight.Normal)
                .width(tableWidths(rows)[c] ?? 80).padding({ left: 8, right: 8, top: 6, bottom: 6 })
                .border({ width: { right: 0.5 }, color: { right: '#33FFFFFF' } })
            }, (cell: string, c: number): string => r.toString() + '-' + c.toString())
          }.backgroundColor(r === 0 ? '#26FFFFFF' : Color.Transparent)
          .border({ width: { bottom: 0.5 }, color: { bottom: '#33FFFFFF' } })
        }, (_row: string[], r: number): string => 'tr-' + r.toString())
      }.borderRadius(10).clip(true).border({ width: 0.5, color: '#33FFFFFF' })
    }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
  }

  @Builder private blockView(block: AiMdBlock) {
    if (block.kind === 'h1' || block.kind === 'h2' || block.kind === 'h3') {
      this.spansText(block.spans, block.kind === 'h1' ? 20 : block.kind === 'h2' ? 18 : 16, '#FFFFFF', FontWeight.Bold)
    } else if (block.kind === 'bullet' || block.kind === 'number') {
      Row({ space: 6 }) {
        Text(block.kind === 'bullet' ? '•' : block.marker).fontSize(16).lineHeight(24).fontColor(aiInk(this.aiStyle, 'icon'))
          .width(block.kind === 'bullet' ? 12 : 22)
        Column() { this.spansText(block.spans, 16, '#FFFFFF', FontWeight.Normal) }.layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Top).padding({ left: block.level * 16 })
    } else if (block.kind === 'quote') {
      Row({ space: 10 }) {
        Column().width(3).height('100%').borderRadius(2).backgroundColor(aiInk(this.aiStyle, 'text4'))
        Column() { this.spansText(block.spans, 15, aiInk(this.aiStyle, 'icon'), FontWeight.Normal) }.layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Top)
    } else if (block.kind === 'rule') {
      Divider().color('#33FFFFFF').strokeWidth(0.5)
    } else if (block.kind === 'code') {
      Scroll() {
        Text(block.text).fontSize(13).lineHeight(19).fontColor(aiInk(this.aiStyle, 'textSoft')).fontFamily('monospace')
          .copyOption(CopyOptions.LocalDevice).padding(12)
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
      .borderRadius(12).backgroundColor(aiInk(this.aiStyle, 'surfaceDeep'))
    } else if (block.kind === 'table') {
      this.tableView(block.rows)
    } else {
      this.spansText(block.spans, 16, '#FFFFFF', FontWeight.Normal)
    }
  }

  @Builder private actionCard(message: AiChatMessage, action: AiChatAction) {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        Stack() {
          SymbolGlyph($r(action.tool === 'call_phone' ? 'sys.symbol.phone_fill' : action.tool === 'send_email' ?
            'sys.symbol.envelope_fill' : action.tool === 'navigate' ? 'sys.symbol.location_up_fill' : action.tool === 'open_link' ?
            'sys.symbol.link' : action.tool === 'change_setting' ? 'sys.symbol.gearshape_fill' :
            action.tool === 'open_app_screen' ? 'sys.symbol.chevron_right' : action.tool === 'connect_host' ? 'sys.symbol.display' :
            action.tool === 'edit_host' ? 'sys.symbol.square_and_pencil' : action.tool === 'send_feature_requests' ?
            'sys.symbol.envelope_fill' : action.tool === 'delete_host' ||
            action.tool === 'delete_document' || action.tool === 'delete_conversation' ? 'sys.symbol.trash_fill' :
            'sys.symbol.alarm_fill')).fontSize(20)
            .fontColor([action.status === 'done' ? '#34C759' : action.status === 'failed' ? '#FF9F0A' : '#4A8DFF'])
        }.width(42).height(42).borderRadius(12).backgroundColor(aiInk(this.aiStyle, 'surface'))
        Column({ space: 2 }) {
          Text(action.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor('#FFFFFF').maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          Text(action.status === 'pending' ? action.detail : action.status === 'done' ? '✓ ' + action.result :
            action.status === 'cancelled' ? '已取消' : '没有完成：' + action.result)
            .fontSize(12).fontColor(action.status === 'done' ? '#34C759' : aiInk(this.aiStyle, 'text2')).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      if (action.status === 'pending' || action.status === 'failed') {
        Row({ space: 8 }) {
          this.smallPill(this.runningAction === action.id ? '正在执行…' : action.status === 'failed' ? '重试' : '确认', true,
            (): void => { void this.confirmAction(message, action); })
          this.smallPill('取消', false, (): void => { this.setAction(message.id, action, 'cancelled', ''); })
        }.width('100%')
      }
    }.width('100%').padding(14).borderRadius(20).backgroundColor(aiInk(this.aiStyle, 'menu'))
    .border({ width: 0.5, color: action.status === 'pending' ? '#664A8DFF' : '#1FFFFFFF' })
  }

  @Builder private documentCard(document: AiDocument) {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.doc_text_fill')).fontSize(22).fontColor([documentColor(document.format)])
        }.width(42).height(42).borderRadius(12).backgroundColor(aiInk(this.aiStyle, 'surface'))
        Column({ space: 2 }) {
          Text(document.name).fontSize(15).fontWeight(FontWeight.Medium).fontColor('#FFFFFF').maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          Text(aiDocumentAvailable(document) ? aiDocumentKindLabel(document.format) + ' · ' + sizeLabel(document.bytes) : '已删除')
            .fontSize(12).fontColor(aiInk(this.aiStyle, 'text2'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      // Deleted (delete_document, or gone from the device): the card stays, without its buttons.
      if (aiDocumentAvailable(document)) {
        Row({ space: 8 }) {
          this.smallPill('打开', true, (): void => { void this.openDocument(document, false); })
          this.smallPill('分享', false, (): void => { void this.shareDocument(document); })
          this.smallPill('另存', false, (): void => { void this.saveDocument(document); })
          this.smallPill('打印', false, (): void => { void this.printDocument(document); })
        }.width('100%')
        // 悬浮球: open the document and keep the chat at hand as the orb.
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.smal_window_playback')).fontSize(13).fontColor([aiInk(this.aiStyle, 'text2')])
          Text('打开并缩成悬浮球，边看边问').fontSize(12).fontColor(aiInk(this.aiStyle, 'text2'))
        }.onClick((): void => { void this.openDocument(document, true); })
      }
    }.width('100%').padding(14).borderRadius(20).backgroundColor(aiInk(this.aiStyle, 'menu'))
    .border({ width: 0.5, color: '#1FFFFFFF' })
  }

  @Builder private actionLink(symbol: Resource, label: string, action: () => void) {
    Row({ space: 4 }) {
      SymbolGlyph(symbol).fontSize(13).fontColor([aiInk(this.aiStyle, 'text2')])
      Text(label).fontSize(12).fontColor(aiInk(this.aiStyle, 'text2'))
    }.height(24).onClick(action)
  }

  @Builder private messageView(message: AiChatMessage, last: boolean) {
    if (message.role === 'user') {
      Column({ space: 6 }) {
        if (message.attachments.length > 0) {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End }) {
            ForEach(message.attachments, (name: string): void => {
              Row({ space: 6 }) {
                SymbolGlyph($r('sys.symbol.paperclip')).fontSize(12).fontColor([aiInk(this.aiStyle, 'icon')])
                Text(name).fontSize(12).fontColor(aiInk(this.aiStyle, 'icon')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: 180 })
              }.padding({ left: 8, right: 8, top: 4, bottom: 4 }).borderRadius(10).backgroundColor(aiInk(this.aiStyle, 'surface'))
              .margin({ left: 6, bottom: 4 })
            }, (name: string): string => message.id + name)
          }.width('100%')
        }
        Row() {
          Text(message.text).fontSize(15).lineHeight(22).fontColor('#FFFFFF').copyOption(CopyOptions.LocalDevice)
            .padding({ left: 14, right: 14, top: 9, bottom: 9 }).borderRadius(18).backgroundColor(aiInk(this.aiStyle, 'surfaceRaised'))
            .constraintSize({ maxWidth: '86%' })
        }.width('100%').justifyContent(FlexAlign.End)
      }.width('100%').alignItems(HorizontalAlign.End)
    } else {
      Column({ space: 10 }) {
        ForEach(this.blocksOf(message), (block: AiMdBlock, index: number): void => {
          Column() { this.blockView(block) }.width('100%').alignItems(HorizontalAlign.Start)
            .transition(this.answerTransition(message, index))
        }, (_block: AiMdBlock, index: number): string => message.id + '-b' + index.toString())
        ForEach(message.documents, (document: AiDocument): void => {
          Column() { this.documentCard(document) }.width('100%')
            .transition(this.answerTransition(message, this.blocksOf(message).length))
        }, (document: AiDocument): string => message.id + '-d' + document.path)
        ForEach(message.actions, (action: AiChatAction): void => {
          Column() { this.actionCard(message, action) }.width('100%')
            .transition(this.answerTransition(message, this.blocksOf(message).length + 1))
        }, (action: AiChatAction): string => message.id + '-a' + action.id + action.status)
        Row({ space: 16 }) {
          this.actionLink($r('sys.symbol.doc_filled_on_doc'), '复制', (): void => { this.copyText(message.text); })
          if (AiReadAloud.available()) {
            this.actionLink($r(this.speakingId === message.id ? 'sys.symbol.pause_circle_fill' : 'sys.symbol.speaker_wave_2_fill'),
              this.speakingId === message.id ? '停止朗读' : '朗读', (): void => { this.toggleReadAloud(message); })
          }
          if (message.documents.length === 0 && message.text.length > 80) {
            this.actionLink($r('sys.symbol.doc_text'), '存为 Word', (): void => { this.saveAnswerAsDocument(message); })
          }

        }.width('100%')
        .transition(this.answerTransition(message, this.blocksOf(message).length + 2))
      }.width('100%')
    }
  }

  /**
   * A new answer rises in a block at a time where the thinking line was (each a little after the one before, as the
   * voice card does); an answer already there does not move.
   */
  private answerTransition(message: AiChatMessage, index: number): TransitionEffect {
    if (message.id !== this.freshId || this.reducedMotion) { return TransitionEffect.IDENTITY; }
    return TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 14 }))
      .combine(TransitionEffect.scale({ x: 0.985, y: 0.985, centerX: 0 }))
      .animation({ curve: curves.springMotion(0.48, 0.88), delay: 60 + Math.min(index, 8) * 85 });
  }

  /** Waiting for the answer, where the answer will appear: the ring (with room for its glow) and what is happening. */
  @Builder private thinkingRow() {
    Row({ space: 10 }) {
      // Beside the floating orb the orb itself turns (the small chat only says what is happening).
      if (!this.mini) {
        Stack() { AiThinkingIndicator({ indicatorSize: 24 }) }.width(36).height(36)
      }
      Stack({ alignContent: Alignment.Start }) {
        ForEach([this.status], (line: string): void => {
          Text(line + '…').fontSize(15).fontColor(aiInk(this.aiStyle, 'icon')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            // One line at a time: the old one leaves first, then the new one comes in (never both at once).
            .transition(TransitionEffect.asymmetric(
              TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 8 }))
                .animation({ duration: 220, delay: 120, curve: Curve.EaseOut }),
              TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -6 }))
                .animation({ duration: 110, curve: Curve.EaseIn })))
        }, (line: string): string => 'status-' + line)
      }.layoutWeight(1).height(36)
    }.width('100%').padding({ left: 4, right: 4 })
    .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
  }

  @Builder private routeCard() {
    Column({ space: 10 }) {
      Text('这像是 RemoteDesktop 的问题').fontSize(15).fontWeight(FontWeight.Medium).fontColor('#FFFFFF').width('100%')
      Text('助理可以抓取日志、排查连接问题，并直接帮你改设置。').fontSize(13).lineHeight(19)
        .fontColor(aiInk(this.aiStyle, 'text2')).width('100%')
      Row({ space: 8 }) {
        this.smallPill('交给助理', true, (): void => {
          const question: string = this.routeQuestion;
          this.routeQuestion = ''; this.draft = '';
          this.persist();
          this.onSwitchMode('assistant', question);
        })
        this.smallPill('仍在聊天里问', false, (): void => {
          this.routeBypass = this.routeQuestion;
          this.routeQuestion = '';
          this.submit();
        })
      }.width('100%')
    }.width('100%').padding(14).borderRadius(20).backgroundColor(aiInk(this.aiStyle, 'menu'))
    .border({ width: 0.5, color: '#1FFFFFFF' })
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 12 }))
      .animation({ curve: curves.springMotion(0.42, 0.86) }))
  }

  /** Something to send (typed, or documents added) and nothing under way. */
  private canSend(): boolean {
    return (this.draft.trim() !== '' || this.pending.length > 0) && !this.busy && !this.importing;
  }

  /**
   * With nothing typed and AI 语音 on, the send button is the voice-mode button (as in ChatGPT and Siri). Whether it
   * can send is read here, from the state itself: a value handed to a @Builder is a copy that never updates, which
   * left the button dark while typing. (Dictation is left to the input method's own voice input, which is better.)
   */
  /**
   * The voice and send buttons trading places: the one arriving springs in, the one leaving shrinks away quickly —
   * each with its own animation (the change comes from typing, outside any animateTo, where a bare transition would
   * just cut).
   */
  private swapTransition(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.55, y: 0.55 }))
        .animation({ curve: curves.springMotion(0.36, 0.7), delay: 40 }),
      TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.55, y: 0.55 }))
        .animation({ duration: 140, curve: Curve.EaseIn }));
  }

  @Builder private sendOrVoice() {
    // One spot for both: as typing begins the voice button shrinks away where the send button grows in (and lights
    // up) — overlapping, not one under the other for a moment.
    Stack() {
      if (this.voiceEnabled && !this.canSend() && !this.busy && this.draft.trim() === '' && this.pending.length === 0 &&
        AiVoiceInput.available()) {
        Stack() {
          SymbolGlyph($r('sys.symbol.waveform_1')).fontSize(18).fontColor(['#000000'])
        }
        .width(40).height(40).borderRadius(20).backgroundColor('#FFFFFF')
        .accessibilityText('语音模式')
        .onClick((): void => { this.startVoiceMode(); })
        .transition(this.swapTransition())
      } else {
        Stack() { AiSendButton({ active: this.canSend(), buttonSize: 40, onTap: (): void => { this.submit(); } }) }
          .width(40).height(40)
          .transition(this.swapTransition())
      }
    }.width(40).height(40)
  }

  private startVoiceMode(): void {
    AiReadAloud.stop();
    this.hideKeyboard();
    this.persist();
    AppStorage.setOrCreate(AI_VOICE_REQUEST, Date.now());
  }

  @Builder private addButton() {
    Stack() {
      SymbolGlyph($r('sys.symbol.plus')).fontSize(18).fontColor(['#FFFFFF'])
    }
    .width(40).height(40).borderRadius(20).backgroundColor(aiInk(this.aiStyle, 'surfaceRaised'))
    .opacity(this.importing || this.busy ? 0.4 : 1)
    .accessibilityText('添加文档')
    .onClick((): void => { void this.addDocuments(); })
  }

  @Builder private emptyState() {
    // An empty chat: Siri's text mode, typed straight into the card in large type.
    TextArea({ placeholder: ' 问点什么，或让我帮你处理文档', text: this.draft })
      .id('aiChatQuestion')
      .width('100%').fontSize(20).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
      .placeholderColor(aiInk(this.aiStyle, 'text2')).placeholderFont({ size: 20, weight: FontWeight.Medium })
      .caretStyle({ width: 2.5, color: '#FFFFFF' })
      .backgroundColor(Color.Transparent).padding({ left: 3, right: 0, top: 4, bottom: 2 })
      .constraintSize({ minHeight: 56, maxHeight: 180 })
      .enterKeyType(EnterKeyType.Send)
      .onChange((value: string): void => { this.draft = value; if (this.routeQuestion !== '') { this.routeQuestion = ''; } })
      .onSubmit((): void => { this.submit(); })
      .onAppear((): void => {
        if (this.revealed) { setTimeout((): void => { focusControl.requestFocus('aiChatQuestion'); }, 280); }
      })
    this.pendingRow()
    if (this.routeQuestion !== '') {
      this.routeCard()
    } else if (this.draft.trim() === '' && this.chosenSkill === null) {
      // The installed skills, as what the user might want; 技能 opens the library.
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.skills.slice(0, 9), (skill: AiSkill, index: number): void => {
          this.chip(skill.name, $r(skill.needsDocument ? 'sys.symbol.doc_text' : 'sys.symbol.wand_and_stars'), index,
            (): void => { this.useSkill(skill); })
        }, (skill: AiSkill): string => 'skill-' + skill.id)
        this.chip('更多技能', $r('sys.symbol.plus'), Math.min(9, this.skills.length),
          (): void => { this.hideKeyboard(); this.onOpenSkills(); })
      }.width('100%')
    } else {
      this.skillRow()
    }
    if (this.error !== '') {
      Text(this.error).fontSize(13).lineHeight(18).fontColor('#FF9F0A').width('100%')
    }
    Row({ space: 10 }) {
      this.addButton()
      Text(this.pending.length > 0 ? '已添加 ' + this.pending.length.toString() + ' 个文件' : '添加文档或图片')
        .fontSize(13).fontColor(aiInk(this.aiStyle, 'text2')).layoutWeight(1)
        .onClick((): void => { void this.addDocuments(); })
      this.sendOrVoice()
    }.width('100%')
    Text(this.privacyLine()).fontSize(11).lineHeight(16).fontColor(aiInk(this.aiStyle, 'text2')).width('100%')
  }

  @Builder private conversation() {
    Scroll(this.scroller) {
      Column({ space: 18 }) {
        ForEach(this.messages, (message: AiChatMessage, index: number): void => {
          Column() { this.messageView(message, index === this.messages.length - 1 && !this.busy) }
            .width('100%')
            // A new question fades in as a whole; a new answer rises in block by block (messageView).
            .transition(message.id === this.freshId && message.role === 'user' ?
              TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 12 }))
                .animation({ curve: curves.springMotion(0.42, 0.86) }) : TransitionEffect.IDENTITY)
            .onAreaChange((_old: Area, area: Area): void => { this.positions.set(message.id, Number(area.position.y)); })
        }, (message: AiChatMessage, index: number): string => message.id + '-' + message.documents.length.toString() + '-' +
          message.actions.map((a: AiChatAction): string => a.status).join('') + (this.runningAction !== '' &&
          message.actions.some((a: AiChatAction): boolean => a.id === this.runningAction) ? 'run' : '') + '-' +
          (index === this.messages.length - 1 && !this.busy ? 'last' : '') + (this.speakingId === message.id ? '-speak' : ''))
        if (this.busy) {
          this.thinkingRow()
        }
        if (this.error !== '' && !this.busy) {
          Column({ space: 8 }) {
            Text(this.error).fontSize(13).lineHeight(18).fontColor('#FF9F0A').width('100%')
            if (this.messages.length > 0 && this.messages[this.messages.length - 1].role === 'user') {
              Row() { this.smallPill('重试', true, (): void => { this.retry(); }) }.width('100%')
            }
          }.width('100%')
        }
        if (this.routeQuestion !== '') {
          this.routeCard()
        }
      }.width('100%').padding({ bottom: 6 })
      .onAreaChange((_old: Area, area: Area): void => {
        const height: number = Number(area.height);
        if (Math.abs(height - this.contentHeight) > 0.5) { this.contentHeight = height; }
      })
    }
    .width('100%')
    // As tall as the conversation, up to the card's limit: a short chat leaves no empty space above the field. Until
    // the conversation is measured it takes no room (never the full limit, which flashed a tall empty card).
    .height(this.contentHeight > 0 ? Math.min(this.contentHeight, this.scrollLimit()) : 1)
    .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
    .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(20) })
    if (this.missingAttachments().length > 0 && this.pending.length === 0) {
      Text('之前添加的文档没有随对话保存；要继续读取，请重新添加：' + this.missingAttachments().join('、'))
        .fontSize(11).lineHeight(16).fontColor(aiInk(this.aiStyle, 'text2')).width('100%')
    }
    this.pendingRow()
    if (this.answerPills().length > 0 && this.chosenSkill === null) {
      // What the answer suggests doing next, rising in over the field.
      Scroll() {
        Row() {
          ForEach(this.answerPills(), (pill: AiChatPill, index: number): void => {
            this.chip(pill.label, $r(pill.kind === 'ask' ? 'sys.symbol.wand_and_stars' : pill.kind === 'float' ?
              'sys.symbol.smal_window_playback' : 'sys.symbol.doc_text'), index, (): void => { this.runPill(pill); })
          }, (pill: AiChatPill): string => pill.key)
        }
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
      .edgeEffect(EdgeEffect.Spring)
      // The pills rise in one by one (their own transitions); they also leave together, sinking and fading.
      .transition(TransitionEffect.asymmetric(TransitionEffect.IDENTITY,
        TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 10 })).combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }))
          .animation({ duration: 180, curve: Curve.EaseIn })))
    } else {
      this.skillRow()
    }
    // Bottom-aligned so the buttons stay at the bottom as the field grows; on one line the field (44) and the
    // buttons (40) share a centre line, hence the 2 under each button.
    Row({ space: 10 }) {
      Column() { this.addButton() }.margin({ bottom: 2 })
      AiInputCapsule() {
        TextArea({ placeholder: '继续聊…', text: this.draft })
          .id('aiChatDraft')
          .layoutWeight(1).fontSize(16).fontColor('#FFFFFF').placeholderColor(aiInk(this.aiStyle, 'text2'))
          .caretStyle({ width: 2.5, color: '#FFFFFF' }).backgroundColor(Color.Transparent)
          .padding({ left: 0, right: 0, top: 9, bottom: 9 })
          .constraintSize({ minHeight: 40, maxHeight: 120 })
          .enterKeyType(EnterKeyType.Send)
          .onChange((value: string): void => { this.draft = value; if (this.routeQuestion !== '') { this.routeQuestion = ''; } })
          .onSubmit((): void => { this.submit(); })
      }
      Column() {
        this.sendOrVoice()
      }.margin({ bottom: 2 })
    }.width('100%').alignItems(VerticalAlign.Bottom)
    .onAreaChange((_old: Area, area: Area): void => {
      const height: number = Number(area.height);
      this.composerBase = this.composerBase === 0 ? height : Math.min(this.composerBase, height);
      const extra: number = Math.max(0, height - this.composerBase);
      if (Math.abs(extra - this.composerExtra) > 0.5) { this.composerExtra = extra; }
    })
  }

  private blocksOf(message: AiChatMessage): AiMdBlock[] {
    const key: string = message.id + ':' + message.text.length.toString();
    const cached: AiMdBlock[] | undefined = this.blockCache.get(key);
    if (cached !== undefined) { return cached; }
    const blocks: AiMdBlock[] = aiMarkdownBlocks(message.text);
    this.blockCache.set(key, blocks);
    return blocks;
  }

  private lastAnswer(): AiChatMessage | null {
    for (let i: number = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].role === 'assistant') { return this.messages[i]; }
    }
    return null;
  }

  private lastQuestion(): string {
    for (let i: number = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].role === 'user') { return this.messages[i].text; }
    }
    return '';
  }

  @Builder private miniDocument(document: AiDocument) {
    Row({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.doc_text_fill')).fontSize(18).fontColor([documentColor(document.format)])
      Text(document.name).fontSize(13).fontColor('#FFFFFF').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      this.smallPill('打开', true, (): void => { void this.openDocument(document, false); })
    }.width('100%').padding({ left: 10, right: 6, top: 6, bottom: 6 }).borderRadius(16).backgroundColor(aiInk(this.aiStyle, 'surface'))
  }

  /**
   * Beside the floating orb: the latest question and answer (or what is happening while it thinks), and a field to
   * go on. Documents open from here; anything more (adding files, skills, history) is in the full chat (展开).
   */
  @Builder private miniLayout() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.ellipsis_bubble')).fontSize(14).fontColor([aiInk(this.aiStyle, 'icon')])
        Text('聊天').fontSize(13).fontWeight(FontWeight.Medium).fontColor(aiInk(this.aiStyle, 'icon')).layoutWeight(1)
        if (this.canExpand) {
          this.glyphButton($r('sys.symbol.arrow_up_left_and_arrow_down_right'), '展开完整对话', (): void => {
            this.hideKeyboard();
            this.persist();
            this.onExpand();
          })
        }
      }.width('100%')
      if (this.busy) {
        if (this.lastQuestion() !== '') {
          Text(this.lastQuestion()).fontSize(13).lineHeight(18).fontColor(aiInk(this.aiStyle, 'text2')).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
        this.thinkingRow()
      } else if (this.lastAnswer() !== null) {
        Scroll() {
          Column({ space: 8 }) {
            if (this.lastQuestion() !== '') {
              Text(this.lastQuestion()).fontSize(13).lineHeight(18).fontColor(aiInk(this.aiStyle, 'text2')).maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
            }
            // A new answer rises in block by block where the thinking line was, as in the big chat.
            ForEach(this.blocksOf(this.lastAnswer() as AiChatMessage), (block: AiMdBlock, index: number): void => {
              Column() { this.blockView(block) }.width('100%').alignItems(HorizontalAlign.Start)
                .transition(this.answerTransition(this.lastAnswer() as AiChatMessage, index))
            }, (_block: AiMdBlock, index: number): string => 'mini-b' + index.toString() + '-' + (this.lastAnswer() as AiChatMessage).id)
            ForEach((this.lastAnswer() as AiChatMessage).documents, (document: AiDocument): void => {
              Column() { this.miniDocument(document) }.width('100%')
                .transition(this.answerTransition(this.lastAnswer() as AiChatMessage,
                  this.blocksOf(this.lastAnswer() as AiChatMessage).length))
            }, (document: AiDocument): string => 'mini-d' + document.path)
          }.width('100%')
        }.constraintSize({ maxHeight: 240 }).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
        .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(16) })
        .opacity(this.clearing ? 0 : 1)
        .translate({ y: this.clearing ? -12 : 0 })
      } else if (this.error === '') {
        Text('问点什么，我在这儿。').fontSize(14).fontColor(aiInk(this.aiStyle, 'text2')).width('100%')
          .transition(this.freshStart ? TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 16 }))
            .combine(TransitionEffect.scale({ x: 0.98, y: 0.98 }))
            .animation({ curve: curves.springMotion(0.48, 0.86), delay: 40 }) : TransitionEffect.IDENTITY)
      }
      if (this.error !== '' && !this.busy) {
        Text(this.error).fontSize(13).lineHeight(18).fontColor('#FF9F0A').width('100%')
      }
      if (this.routeQuestion !== '') {
        this.routeCard()
      }
      Row({ space: 8 }) {
        AiInputCapsule() {
          TextInput({ placeholder: this.dictating ? '正在听…' : '继续问…', text: this.draft })
            .id('aiChatMiniDraft')
            .layoutWeight(1).height(38).fontSize(15).fontColor('#FFFFFF').placeholderColor(aiInk(this.aiStyle, 'text2'))
            .caretStyle({ width: 2, color: '#FFFFFF' }).backgroundColor(Color.Transparent).padding(0)
            .enterKeyType(EnterKeyType.Send)
            .onChange((value: string): void => { this.draft = value; if (this.routeQuestion !== '') { this.routeQuestion = ''; } })
            .onSubmit((): void => { this.submit(); })
        }
        AiSendButton({ active: this.draft.trim() !== '' && !this.busy, buttonSize: 34, onTap: (): void => { this.submit(); } })
      }.width('100%').alignItems(VerticalAlign.Center)
    }
    // The island's material in small: black where the text is, smoky towards the foot, a soft rim.
    .width('100%').padding({ left: 16, right: 12, top: 12, bottom: 12 }).borderRadius(28)
    .backdropBlur(26)
    .linearGradient(aiStyleIsXiaoyi(this.aiStyle) ?
      { angle: 135, colors: [[aiXiaoyiGlass(this.theme === 'dark').from, 0], [aiXiaoyiGlass(this.theme === 'dark').to, 1]] } :
      { angle: 180, colors: [['#E6030304', 0], ['#D9070708', 0.5], ['#C7101012', 1]] })
    .border({ width: { top: 0.6, left: 0.6, right: 0.6, bottom: 1 },
      color: aiStyleIsXiaoyi(this.aiStyle) ? '#52FFFFFF' :
        { top: '#1FFFFFFF', left: '#17FFFFFF', right: '#17FFFFFF', bottom: '#59FFFFFF' } })
    .shadow({ radius: 24, color: aiStyleIsXiaoyi(this.aiStyle) ? '#4D2B3A86' : '#59000000', offsetY: 8 })
    .onAreaChange((_old: Area, area: Area): void => { this.onCardSize(Number(area.height)); })
  }

  build() {
    if (this.mini) {
      this.miniLayout()
    } else {
      this.fullLayout()
    }
  }

  @Builder private fullLayout() {
    Column({ space: 12 }) {
      this.header()
      if (this.messages.length === 0 && !this.busy) {
        // After 新对话 the empty chat rises in; on the first question it gives way at once (no in-between layout).
        Column({ space: 12 }) { this.emptyState() }.width('100%')
          .transition(TransitionEffect.asymmetric(this.freshStart ? TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 16 }))
            .combine(TransitionEffect.scale({ x: 0.98, y: 0.98 }))
            .animation({ curve: curves.springMotion(0.48, 0.86), delay: 40 }) :
            TransitionEffect.IDENTITY, TransitionEffect.IDENTITY))
      } else {
        Column({ space: 12 }) { this.conversation() }.width('100%')
          .opacity(this.clearing ? 0 : 1)
          .translate({ y: this.clearing ? -18 : 0 })
          .scale({ x: this.clearing ? 0.97 : 1, y: this.clearing ? 0.97 : 1 })
      }
    }
    .width('100%')
    .constraintSize({ maxHeight: this.bodyLimit })
  }
}
