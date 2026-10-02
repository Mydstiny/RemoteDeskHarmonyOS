import { common } from '@kit.AbilityKit';
import { curves, LengthMetrics } from '@kit.ArkUI';
import { inputMethod } from '@kit.IMEKit';
import { AiKernelRing } from './XiaoyiOrb';
import { HdsImmersiveEdgeLight } from './HdsImmersiveEdgeLight';
import { AI_FLOAT_ORB, AiAssistantGlyph, AiInputCapsule, AiPrimaryPill, AiSendButton, AiSiriOrb } from './AiIslandChrome';
import { AppConfig, Palette, buildDark, buildLight } from '../../common/Theme';
import { AppUiMetrics } from '../../common/AppUiMetrics';
import { DiagnosticAiProviderProfile, DiagnosticAiResult, DiagnosticAiSettingProposal } from '../../services/diagnosticAi/DiagnosticAiModels';
import { DiagnosticModuleId } from '../../services/DiagnosticCapturePolicy';
import { diagnosticAiModulesForQuestion, diagnosticAiCaptureStatus } from '../../services/diagnosticAi/DiagnosticAiBundlePolicy';
import { DiagnosticAiCaptureOrchestrator } from '../../services/diagnosticAi/DiagnosticAiCaptureOrchestrator';
import { DiagnosticAiProfileStore } from '../../services/diagnosticAi/DiagnosticAiProfileStore';
import { diagnosticAiProviderIsHarmonyLocal } from '../../services/diagnosticAi/DiagnosticAiProviderCatalog';
import { DiagnosticAiAgentMode, DiagnosticAiAgentService, diagnosticAiAgentModeForQuestion, diagnosticAiAgentModeLabel } from '../../services/diagnosticAi/DiagnosticAiAgentService';
import { diagnosticAiMailDraft } from '../../services/diagnosticAi/DiagnosticAiMailPolicy';
import { diagnosticAiApplyProposal, diagnosticAiSettingActionText } from '../../services/diagnosticAi/DiagnosticAiSettingsActionPolicy';
import { ProAppRuntime } from '../../services/pro/ProAppRuntime';
import { ProEntries } from '../../services/pro/ProEntries';
import { PRO_DIAGNOSTICS_ASSISTANT_FEATURE } from '../../services/pro/ProFeatureCatalog';
import { AccountSessionCoordinator } from '../../services/AccountSessionCoordinator';
import { DiagnosticAiAppAction, DiagnosticAiAppActionId, diagnosticAiAppActionsForSteps } from '../../services/diagnosticAi/DiagnosticAiAppActionPolicy';

/** A suggested question shown as a pill in the island; it follows what the user is asking about. */
class AiSuggestion {
  label: string;
  mode: DiagnosticAiAgentMode;
  question: string;

  constructor(label: string, mode: DiagnosticAiAgentMode, question: string) {
    this.label = label;
    this.mode = mode;
    this.question = question;
  }
}

/**
 * Something the answer suggests doing, shown as a pill: a setting change to apply, a screen of the app to open, or
 * one of the conversation's own actions ('mail' draft, 'mailOpen' in the mail app, 'new' conversation).
 */
class AiAction {
  key: string;
  label: string;
  proposal: DiagnosticAiSettingProposal | null;
  appAction: DiagnosticAiAppActionId | null;
  special: string;

  constructor(key: string, label: string, proposal: DiagnosticAiSettingProposal | null,
    appAction: DiagnosticAiAppActionId | null, special: string = '') {
    this.key = key;
    this.label = label;
    this.proposal = proposal;
    this.appAction = appAction;
    this.special = special;
  }
}

/** One finished exchange of the conversation. */
class AiTurn {
  question: string;
  answer: string;

  constructor(question: string, answer: string) {
    this.question = question;
    this.answer = answer;
  }
}

/**
 * The conversation outlives the island: closing and reopening the assistant keeps the earlier exchanges (for the
 * user to scroll back to, and as context for the next request) until 新对话 or a change of account clears it.
 */
class AiConversationMemory {
  static owner: string = '';
  static turns: AiTurn[] = [];
  static history: string = '';

  static clear(owner: string): void {
    AiConversationMemory.owner = owner;
    AiConversationMemory.turns = [];
    AiConversationMemory.history = '';
  }
}

/** A topic the pills follow: its keywords and the questions to suggest for it. */
class AiTopic {
  words: string[];
  items: AiSuggestion[];

  constructor(words: string[], items: AiSuggestion[]) {
    this.words = words;
    this.items = items;
  }
}

const AI_TOPICS: AiTopic[] = [
  new AiTopic(['连不上', '连接', '断开', '掉线', '超时', '黑屏', '卡', '延迟', '慢', '闪退', '报错', '错误', '失败', 'error'], [
    new AiSuggestion('诊断连接问题', 'diagnose', '我遇到了连接问题，请帮我诊断。'),
    new AiSuggestion('检查网络延迟', 'answer', '怎样检查远程连接的网络延迟？'),
    new AiSuggestion('分析最近报错', 'diagnose', '请帮我分析最近一次连接的报错。')]),
  new AiTopic(['分辨率', '缩放', '画质', '清晰', '模糊', '显示', '全屏', '屏幕', '字体', '太小', '太大'], [
    new AiSuggestion('调整远端分辨率', 'configure', '帮我调整远端桌面的分辨率。'),
    new AiSuggestion('设置界面缩放', 'configure', '帮我设置远端界面的缩放比例。'),
    new AiSuggestion('画质与流畅度', 'answer', '如何在画质和流畅度之间取得平衡？')]),
  new AiTopic(['键盘', '鼠标', '触控', '手势', '快捷键', '右键', '输入', '打字'], [
    new AiSuggestion('触控手势说明', 'answer', '远程桌面里有哪些触控手势？'),
    new AiSuggestion('外接键盘快捷键', 'answer', '外接键盘时可以用哪些快捷键？'),
    new AiSuggestion('切换鼠标模式', 'configure', '帮我切换远程桌面的鼠标模式。')]),
  new AiTopic(['同步', '云', '备份', '账号', '登录', '多设备', '恢复'], [
    new AiSuggestion('开启云同步', 'configure', '帮我开启主机的云同步。'),
    new AiSuggestion('备份主机配置', 'answer', '怎样备份我的主机配置？'),
    new AiSuggestion('多设备同步', 'answer', '多台设备之间如何同步主机？')]),
  new AiTopic(['密钥', '密码', '凭据', '证书', '安全', '加密', '指纹'], [
    new AiSuggestion('管理 SSH 密钥', 'answer', '怎样导入和管理 SSH 密钥？'),
    new AiSuggestion('保存 RDP 凭据', 'answer', '怎样保存 RDP 的登录凭据？'),
    new AiSuggestion('证书提示说明', 'answer', '连接时提示证书不受信任怎么办？')]),
  new AiTopic(['添加', '新建', '导入', '主机', '配置', 'rdp', 'ssh', 'vnc', 'rustdesk', 'moonlight'], [
    new AiSuggestion('如何添加主机', 'answer', '如何添加并连接第一台主机？'),
    new AiSuggestion('导入主机', 'answer', '怎样从文件导入主机？'),
    new AiSuggestion('设置主机分组', 'configure', '帮我把主机按用途分组。')])
];

const AI_DEFAULT_SUGGESTIONS: AiSuggestion[] = [
  new AiSuggestion('询问用法', 'answer', '如何添加并连接第一台主机？'),
  new AiSuggestion('帮我设置', 'configure', '帮我设置当前应用，让我更容易完成远程连接。'),
  new AiSuggestion('诊断问题', 'diagnose', '我遇到了连接问题，请帮我诊断。')
];

/**
 * Pills for what is being typed: topics are ranked by how many of their keywords appear, and the three pills are
 * taken from the best topics first (so a question that touches two topics gets pills from both).
 */
function aiSuggestionsFor(text: string): AiSuggestion[] {
  const q: string = text.toLowerCase();
  const ranked: AiTopic[] = AI_TOPICS
    .map((topic: AiTopic): number => topic.words.filter((w: string): boolean => q.indexOf(w) >= 0).length)
    .map((hits: number, index: number): number[] => [hits, index])
    .filter((pair: number[]): boolean => pair[0] > 0)
    .sort((a: number[], b: number[]): number => b[0] - a[0] || a[1] - b[1])
    .map((pair: number[]): AiTopic => AI_TOPICS[pair[1]]);
  if (ranked.length === 0) { return AI_DEFAULT_SUGGESTIONS; }
  const picked: AiSuggestion[] = [];
  // Round-robin over the matching topics, best first: the top topic leads, a second topic still gets a pill.
  for (let round: number = 0; round < 3 && picked.length < 3; round++) {
    ranked.forEach((topic: AiTopic): void => {
      if (picked.length < 3 && round < topic.items.length) { picked.push(topic.items[round]); }
    });
  }
  return picked;
}

@Component
export struct DiagnosticAiAssistantPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @StorageProp('breakpoint') breakpoint: string = 'md';
  /** Inside the 启动 AI 辅助 sub-setting sheet, which already shows the title and close button. */
  @Prop embedded: boolean = false;
  /** Inside the dark AI island the panel always uses the dark palette. */
  @Prop forceDark: boolean = false;
  /**
   * Siri-style text mode for the AI island: the question is typed straight into the card with the keyboard up,
   * small pill actions sit under it, and the result opens in the same card. Same capture and analysis as the panel.
   */
  @Prop siriMode: boolean = false;
  @Prop deviceClass: 'phone' | 'pad' | 'pc' = 'phone';
  /** In the AI island while a capture or analysis runs: a small floating capsule that leaves the app usable. */
  @Prop @Watch('refreshReady') compact: boolean = false;
  /** An AI service is set up (a model chosen, and its API Key saved unless it runs on the device). */
  @State private aiReady: boolean = true;
  /**
   * Inside the AI island the island draws the glass, rim and edge light around the card, so the panel only lays out
   * the content and reports the card's size for the island to morph to.
   */
  @Prop shellless: boolean = false;
  /** False while the island is still a capsule; the question field takes focus once the card is open. */
  @Prop @Watch('onRevealed') revealed: boolean = true;
  /** Tallest the island may draw the card (it stays clear of the keyboard); 0: no limit. */
  @Prop maxCardHeight: number = 0;
  /** Top padding of the island panel so its first line sits under the Dynamic Island (−1: default). */
  @Prop cardTopPadding: number = -1;
  /** Opens a screen of the app for an answer's step (the island floats meanwhile). */
  onAppAction: (action: DiagnosticAiAppActionId) => void = (_action: DiagnosticAiAppActionId): void => {};
  onCardSize: (width: number, height: number) => void = (_width: number, _height: number): void => {};
  @State private pulse: boolean = false;
  @State private captureBytes: number = 0;
  onClose: () => void = (): void => {};
  onCaptureStateChanged: (capturing: boolean) => void = (_capturing: boolean): void => {};
  /** Capturing or analyzing; drives the edge glow of the sheet around the panel. */
  onActivityChanged: (active: boolean) => void = (_active: boolean): void => {};
  @State private lastActive: boolean = false;
  onOpenMailDraft: (subject: string, body: string) => void = (_subject: string, _body: string): void => {};
  @State question: string = '';
  @State private agentMode: DiagnosticAiAgentMode = 'answer';
  @State private awaitingCapture: boolean = false;
  @State private conversation: string = '';
  @State status: string = '';
  @State busy: boolean = false;
  @State result: DiagnosticAiResult | null = null;
  @State modules: DiagnosticModuleId[] = [];
  @State eventCount: number = 0;
  @State elapsed: number = 0;
  @State private latestBundleText: string = '';
  @State private mailPreviewVisible: boolean = false;
  @State private mailSubject: string = '';
  @State private mailBody: string = '';
  /** The result starts as a compact answer; the expand control reveals the full conversation surface. */
  @State private expandedResult: boolean = false;
  @State private draftQuestion: string = '';
  /** Pills under the prompt; they follow what is being typed and change with an exit/enter animation. */
  @State private suggestions: AiSuggestion[] = aiSuggestionsFor('');
  /** Earlier exchanges of this conversation, shown above the current answer. */
  @State private turns: AiTurn[] = [];
  private readonly answerScroller: Scroller = new Scroller();
  /** Setting changes from the current answer that were already applied; their pills leave. */
  @State private appliedActions: string[] = [];
  private suggestionTimer: number = -1;
  private readonly capture: DiagnosticAiCaptureOrchestrator = DiagnosticAiCaptureOrchestrator.getInstance();
  private readonly agent: DiagnosticAiAgentService = new DiagnosticAiAgentService();
  private store: DiagnosticAiProfileStore = new DiagnosticAiProfileStore();
  private owner: string = 'device-local';
  private timer: number = -1;
  private lifecycleGeneration: number = 0;
  private captureOwnedByPanel: boolean = false;

  private onRevealed(): void {
    this.refreshReady();
    if (this.revealed) { this.focusQuestion(); }
  }

  /** Checked whenever the panel shows again: the user may have just set the service up from the guide card. */
  private refreshReady(): void {
    const selected: DiagnosticAiProviderProfile | undefined = this.selectedProfile();
    this.aiReady = selected !== undefined &&
      (diagnosticAiProviderIsHarmonyLocal(selected.providerId) || this.store.secret(selected).trim() !== '');
  }

  private focusQuestion(): void {
    setTimeout((): void => {
      if (this.revealed && this.aiReady && this.result === null && !this.busy && !this.capturing()) {
        focusControl.requestFocus('aiIslandQuestion');
      }
    }, 280);
  }

  private reportCardSize(area: Area): void {
    this.onCardSize(Number(area.width), Number(area.height));
  }

  private pal(): Palette {
    return this.theme === 'light' && !this.forceDark ? buildLight(this.accent) : buildDark(this.accent);
  }

  private siriRadius(): number { return this.deviceClass === 'phone' ? 34 : 30; }
  private siriSidePadding(): number {
    if (this.shellless) { return this.deviceClass === 'phone' ? 26 : 28; }
    return this.deviceClass === 'phone' ? 18 : 24;
  }

  /**
   * Function cards inside the island (diagnosis consent, setting proposals, mail preview): a graphite card nested in
   * the black panel, a step more opaque than the shell, rising in from below while it comes into focus — as Siri
   * shows a notification card under its reply.
   */
  private functionCardTransition(): TransitionEffect {
    return TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ y: 22 }))
      .combine(TransitionEffect.scale({ x: 0.94, y: 0.94 }))
      .animation({ curve: curves.springMotion(0.42, 0.86) });
  }
  private siriResultHeight(): number {
    if (this.expandedResult) { return this.deviceClass === 'phone' ? 460 : 560; }
    return this.deviceClass === 'phone' ? 320 : 390;
  }

  aboutToAppear(): void {
    this.lifecycleGeneration++;
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    this.owner = scope.ownerScopeId.trim() === '' ? 'device-local' : scope.ownerScopeId;
    this.store.init(getContext(this) as common.UIAbilityContext, this.owner);
    if (AiConversationMemory.owner !== this.owner) { AiConversationMemory.clear(this.owner); }
    this.refreshReady();
    this.conversation = AiConversationMemory.history;
    this.turns = AiConversationMemory.turns.slice();
    this.timer = setInterval((): void => { this.syncCapture(); }, 500);
  }

  aboutToDisappear(): void {
    this.lifecycleGeneration++;
    if (this.suggestionTimer >= 0) { clearTimeout(this.suggestionTimer); this.suggestionTimer = -1; }
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
    if (this.captureOwnedByPanel) {
      this.capture.cancel(this.owner);
      this.captureOwnedByPanel = false;
      this.onCaptureStateChanged(false);
    }
  }

  private allowed(): boolean {
    return ProEntries.visible(PRO_DIAGNOSTICS_ASSISTANT_FEATURE, ProAppRuntime.getInstance().context());
  }

  private syncCapture(): void {
    const snapshot = this.capture.status();
    this.eventCount = snapshot.eventCount; this.elapsed = snapshot.durationMinutes * 60 - snapshot.remainingSeconds;
    this.captureBytes = snapshot.approximateBytes;
    this.reportActivity();
    if (snapshot.phase === 'capturing') {
      this.status = '正在抓取脱敏诊断事件，复现问题后点「结束并分析」';
      this.pulse = !this.pulse;
    }
  }

  private capturing(): boolean { return this.capture.status().phase === 'capturing'; }

  private reportActivity(): void {
    const active: boolean = this.busy || this.capturing();
    if (active !== this.lastActive) { this.lastActive = active; this.onActivityChanged(active); }
  }
  private sizeText(): string {
    return this.captureBytes >= 1024 ? (this.captureBytes / 1024).toFixed(1) + ' KB' : this.captureBytes.toString() + ' B';
  }
  private severityText(): string {
    const severity: string = this.result === null ? 'unknown' : this.result.severity;
    if (severity === 'high') { return '高'; }
    if (severity === 'medium') { return '中'; }
    if (severity === 'low') { return '低'; }
    if (severity === 'info') { return '提示'; }
    return '未知';
  }
  private severityColor(): string {
    const severity: string = this.result === null ? 'unknown' : this.result.severity;
    if (severity === 'high') { return '#E5484D'; }
    if (severity === 'medium') { return '#F08C00'; }
    if (severity === 'low') { return '#2BB673'; }
    return this.accent;
  }

  private selectedProfile(): DiagnosticAiProviderProfile | undefined {
    const profiles = this.store.list();
    const settings = this.store.settingsSnapshot();
    return profiles.find((value: DiagnosticAiProviderProfile): boolean =>
      value.providerId === settings.selectedProviderId && value.modelId === settings.selectedModelId && value.modelId !== '') ??
      profiles.find((value: DiagnosticAiProviderProfile): boolean => value.modelId !== '');
  }

  private errorText(error: Object): string {
    const value = error instanceof Error ? error.message : 'DIAGNOSTIC_AI_UNKNOWN';
    if (value.indexOf('LOCAL_MODEL_PC_ONLY') >= 0) { return '鸿蒙端侧小模型当前仅支持 PC/2in1，手机和 Pad 暂不可用'; }
    if (value.indexOf('LOCAL_MODEL_BUSY') >= 0) { return '鸿蒙端侧小模型正在处理其他请求，请稍后重试'; }
    if (value.indexOf('LOCAL_MODEL') >= 0) { return '鸿蒙端侧小模型当前不可用，请在 Provider 设置中重新检测'; }
    if (value.indexOf('HTTP_401') >= 0 || value.indexOf('HTTP_403') >= 0) { return 'AI 服务拒绝了请求，请检查 API Key、套餐权限或模型权限'; }
    if (value.indexOf('HTTP_400') >= 0 || value.indexOf('HTTP_422') >= 0) { return 'AI 服务不接受当前请求格式，请重新拉取模型或换用兼容模型'; }
    if (value.indexOf('NETWORK') >= 0) { return 'AI 服务暂时无法连接，请检查网络、地址和证书'; }
    if (value.indexOf('EMPTY_RESULT') >= 0) { return 'AI 服务返回了空结果，请重试或更换模型'; }
    if (value.indexOf('ANALYSIS_UNAVAILABLE') >= 0) { return '当前 Provider 尚未完成 AI 请求适配'; }
    return value;
  }

  private async sendAgent(mode: DiagnosticAiAgentMode, bundle: string = ''): Promise<void> {
    if (!this.allowed() || this.busy || this.question.trim() === '') { return; }
    const selected = this.selectedProfile();
    if (selected === undefined) { this.status = '请先在辅助 AI 配置中保存 API Key 并选择模型'; return; }
    const secret: string = this.store.secret(selected);
    if (!diagnosticAiProviderIsHarmonyLocal(selected.providerId) && secret.trim() === '') {
      this.status = '已找到 Provider 配置，但 API Key 无法从本机安全存储读回；请重新保存 API Key';
      return;
    }
    const requestGeneration: number = this.lifecycleGeneration;
    const requestOwner: string = this.owner;
    const selectedRevision: number = selected.revision;
    this.agentMode = mode; this.busy = true; this.result = null; this.expandedResult = false;
    this.status = '正在连接 AI…'; this.reportActivity();
    try {
      const analyzed: DiagnosticAiResult = await this.agent.respond(selected, secret, {
        mode, question: this.question, history: this.conversation, bundle
      });
      const currentScope = AccountSessionCoordinator.getInstance().currentScope();
      const currentOwner: string = currentScope.ownerScopeId.trim() === '' ? 'device-local' : currentScope.ownerScopeId;
      const latestProfile = this.store.list().find((value: DiagnosticAiProviderProfile): boolean => value.id === selected.id);
      if (requestGeneration !== this.lifecycleGeneration || currentOwner !== requestOwner || !this.allowed() ||
        latestProfile === undefined || latestProfile.revision !== selectedRevision) {
        this.status = '页面或账号作用域已变化，已丢弃旧 AI 结果'; return;
      }
      this.result = analyzed;
      this.conversation = (this.conversation + '\n用户：' + this.question + '\n助手：' + analyzed.summary).slice(-8000);
      this.rememberExchange(analyzed);
      this.status = mode === 'diagnose' ? '诊断完成；请查看证据、建议和可选操作。' : '已收到 AI 回复；请从卡片中选择下一步。';
    } catch (error) {
      this.status = this.errorText(error);
    } finally { this.busy = false; this.reportActivity(); }
  }

  private beginCapture(): void {
    if (!this.allowed() || this.busy || this.question.trim() === '') { return; }
    if (this.selectedProfile() === undefined) { this.status = '请先在辅助 AI 配置中保存 API Key 并选择模型'; return; }
    this.agentMode = 'diagnose'; this.awaitingCapture = false;
    this.modules = diagnosticAiModulesForQuestion(this.question);
    const result = this.capture.start(this.owner, { modules: this.modules, durationMinutes: 3, consentId: 'consent-' + Date.now().toString() });
    this.syncCapture();
    if (result === 'ok') {
      this.captureOwnedByPanel = true;
      this.onCaptureStateChanged(true);
      this.status = '正在抓取脱敏诊断事件…';
    } else {
      this.status = '无法开始抓取：' + result;
    }
  }

  private async finishCapture(): Promise<void> {
    if (this.busy) { return; }
    const requestGeneration: number = this.lifecycleGeneration;
    const requestOwner: string = this.owner;
    this.busy = true; this.reportActivity(); const stopCode = this.capture.stop(requestOwner); this.captureOwnedByPanel = false;
    this.onCaptureStateChanged(false); this.syncCapture();
    if (stopCode !== 'ok' && stopCode !== 'not_active') {
      this.status = '无法结束抓取：' + stopCode; this.busy = false; return;
    }
    const bundle = this.capture.bundle(requestOwner);
    if (bundle === null) {
      this.capture.cancel(requestOwner);
      this.status = '没有可分析的诊断事件'; this.busy = false; return;
    }
    this.latestBundleText = bundle.text;
    this.capture.discard(requestOwner, bundle.captureId);
    const selected = this.selectedProfile();
    if (selected === undefined) { this.status = '请先在辅助 AI 配置中保存 API Key 并选择模型'; this.busy = false; return; }
    const selectedRevision: number = selected.revision;
    try {
      const analyzed: DiagnosticAiResult = await this.agent.respond(selected, this.store.secret(selected), {
        mode: 'diagnose', question: this.question, history: this.conversation, bundle: bundle.text
      });
      const currentScope = AccountSessionCoordinator.getInstance().currentScope();
      const currentOwner: string = currentScope.ownerScopeId.trim() === '' ? 'device-local' : currentScope.ownerScopeId;
      const latestProfile = this.store.list().find((value: DiagnosticAiProviderProfile): boolean => value.id === selected.id);
      if (requestGeneration !== this.lifecycleGeneration || currentOwner !== requestOwner || !this.allowed() ||
        latestProfile === undefined || latestProfile.revision !== selectedRevision) {
        this.status = '页面或账号作用域已变化，已丢弃旧诊断结果';
        return;
      }
      this.result = analyzed;
      this.conversation = (this.conversation + '\n用户：' + this.question + '\n助手：' + analyzed.summary).slice(-8000);
      this.rememberExchange(analyzed);
      this.status = '诊断完成；请查看证据、建议和可选操作。';
    } catch (error) {
      this.status = this.errorText(error);
    } finally { this.busy = false; this.reportActivity(); }
  }

  @Builder private metric(value: string, label: string) {
    Column({ space: 2 }) {
      Text(value).fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily)
      Text(label).fontSize(11).fontColor(this.pal().text3)
    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
  }

  @Builder private captureCard() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Circle().width(10).height(10).fill('#E5484D')
          .opacity(this.pulse ? 1 : 0.35).animation({ duration: 480, curve: Curve.EaseInOut })
        Text('抓取中').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text).layoutWeight(1)
        Text('最长 3 分钟').fontSize(11).fontColor(this.pal().text3)
      }.width('100%')
      Row() {
        this.metric(this.eventCount.toString(), '事件')
        this.metric(this.elapsed.toString() + ' 秒', '已运行')
        this.metric(this.sizeText(), '数据量')
      }.width('100%')
    }.width('100%').padding(14).borderRadius(16).backgroundColor(this.pal().card)
    .border({ width: 1, color: '#33E5484D' })
  }

  @Builder private resultCard() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text(this.agentMode === 'diagnose' ? '诊断结果' : diagnosticAiAgentModeLabel(this.agentMode) + '结果')
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.pal().text).layoutWeight(1)
        Text('影响 ' + this.severityText()).fontSize(11).fontColor(this.severityColor())
          .padding({ left: 8, right: 8, top: 3, bottom: 3 }).borderRadius(9)
          .backgroundColor('#1A' + this.severityColor().substring(1))
      }.width('100%')
      Text((this.result as DiagnosticAiResult).summary).fontSize(14).lineHeight(21).fontColor(this.pal().text)
        .width('100%').copyOption(CopyOptions.InApp)
      Column({ space: 4 }) {
        Row() {
          Text('置信度').fontSize(11).fontColor(this.pal().text3).layoutWeight(1)
          Text(Math.round((this.result as DiagnosticAiResult).confidence * 100).toString() + '%').fontSize(11)
            .fontColor(this.pal().text2)
        }.width('100%')
        Progress({ value: Math.round((this.result as DiagnosticAiResult).confidence * 100), total: 100,
          type: ProgressType.Linear }).width('100%').color(this.accent).style({ strokeWidth: 5 })
      }.width('100%')
      if ((this.result as DiagnosticAiResult).unknowns.length > 0) {
        Text('尚不确定：' + (this.result as DiagnosticAiResult).unknowns.join('；')).fontSize(12).lineHeight(18)
          .fontColor(this.pal().text2).width('100%')
      }
      if ((this.result as DiagnosticAiResult).recommendedReadOnlySteps.length > 0) {
        Text('建议操作').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
        ForEach((this.result as DiagnosticAiResult).recommendedReadOnlySteps, (step: string, index: number): void => {
          Row({ space: 8 }) {
            Text((index + 1).toString()).fontSize(11).fontColor(this.accent).width(18).height(18)
              .textAlign(TextAlign.Center).borderRadius(9).backgroundColor(this.pal().surface)
            Text(step).fontSize(12).lineHeight(17).fontColor(this.pal().text2).layoutWeight(1)
          }.width('100%')
        }, (_step: string, index: number): string => 'step' + index.toString())
      }
      if ((this.result as DiagnosticAiResult).settingProposals.length > 0) {
        Text('可选设置建议 · 逐项确认后才会应用').fontSize(13).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).width('100%').margin({ top: 4 })
        ForEach((this.result as DiagnosticAiResult).settingProposals, (proposal: DiagnosticAiSettingProposal): void => {
          Row({ space: 10 }) {
            Column({ space: 3 }) {
              Text(diagnosticAiSettingActionText(proposal.settingId) + ' → ' + proposal.proposedValue)
                .fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
              Text(proposal.reason).fontSize(11).lineHeight(16).fontColor(this.pal().text2).width('100%')
            }.layoutWeight(1)
            Button('应用').height(34).fontSize(13).padding({ left: 14, right: 14 }).borderRadius(17)
              .backgroundColor(this.accent).fontColor(Color.White).enabled(proposal.requiresUserConfirmation)
              .onClick((): void => {
                const applied: boolean = diagnosticAiApplyProposal(proposal);
                this.status = applied ? '已应用：' + diagnosticAiSettingActionText(proposal.settingId) : '该建议未通过安全白名单';
              })
          }.width('100%').padding(10).backgroundColor(this.pal().surface).borderRadius(12)
        }, (_proposal: DiagnosticAiSettingProposal, index: number): string => index.toString())
      }
      if (this.agentMode === 'diagnose' || this.agentMode === 'feedback' || this.latestBundleText !== '') {
        Divider().color(this.pal().divider).margin({ top: 2, bottom: 2 })
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.envelope_fill')).fontSize(16).fontColor([this.pal().text3])
          Text('需要人工协助时，可生成邮件草稿；发送前会再预览一次，不会自动发送。').fontSize(12).lineHeight(17)
            .fontColor(this.pal().text2).layoutWeight(1)
        }.width('100%')
        Button('生成邮件草稿').height(42).width('100%').borderRadius(21).backgroundColor(this.pal().surface)
          .fontColor(this.accent)
          .onClick((): void => {
            const draft = diagnosticAiMailDraft(this.question, this.result as DiagnosticAiResult, {
              captureId: 'latest', schemaVersion: 8, modules: this.modules,
              text: this.latestBundleText, eventCount: this.eventCount, bytes: this.latestBundleText.length
            });
            this.mailSubject = draft.subject; this.mailBody = draft.body; this.mailPreviewVisible = true;
          })
      }
      if (this.mailPreviewVisible) {
        Column({ space: 8 }) {
          Text('邮件预览').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
          Text('主题：' + this.mailSubject).fontSize(12).fontColor(this.pal().text2).width('100%')
          Scroll() {
            Text(this.mailBody).fontSize(11).lineHeight(16).fontColor(this.pal().text).width('100%')
              .copyOption(CopyOptions.InApp)
          }.height(150).width('100%').backgroundColor(this.pal().card).borderRadius(10).padding(8)
          Row({ space: 8 }) {
            Button('取消').layoutWeight(1).height(40).borderRadius(20).backgroundColor(this.pal().card)
              .fontColor(this.pal().text).onClick((): void => { this.mailPreviewVisible = false; })
            Button('打开系统邮件').layoutWeight(1).height(40).borderRadius(20).backgroundColor(this.accent)
              .fontColor(Color.White)
              .onClick((): void => { this.onOpenMailDraft(this.mailSubject, this.mailBody); this.mailPreviewVisible = false; })
          }.width('100%')
        }.width('100%').padding(12).backgroundColor(this.pal().surface).borderRadius(14)
      }
    }.width('100%').padding(16).borderRadius(18).backgroundColor(this.pal().card)
    .border({ width: 0.5, color: this.pal().cardBorder })
  }

  /** A floating dark-glass capsule under the card, like Siri's 「Show Results」. */
  @Builder private pill(label: string, primary: boolean, action: () => void) {
    if (primary) {
      AiPrimaryPill({ label: label, onTap: action })
    } else {
      this.plainPill(label, false, action)
    }
  }

  @Builder private plainPill(label: string, primary: boolean, action: () => void) {
    Row({ space: 6 }) {
      if (primary) {
        Circle().width(12).height(12).fill(Color.Transparent)
          .sweepGradient({ center: ['50%', '50%'], colors: [['#42CBF7', 0], ['#2A7DFF', 0.3], ['#A479FF', 0.6],
            ['#FF678C', 0.85], ['#42CBF7', 1]] }).borderRadius(6)
      }
      Text(label).fontSize(13).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
    }
    .height(32).padding({ left: primary ? 10 : 14, right: 14 }).borderRadius(16)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, { colorMode: ThemeColorMode.DARK, adaptiveColor: AdaptiveColor.DEFAULT })
    .backgroundColor('#8C1C1C1E')
    .border({ width: 0.5, color: '#33FFFFFF' })
    .shadow({ radius: 12, color: '#40000000', offsetY: 4 })
    .onClick(action)
  }

  private submitQuestion(): void {
    if (this.question.trim() === '' || this.busy || this.capturing()) { return; }
    try { inputMethod.getController().hideTextInput(); } catch (_error) { /* keyboard already down */ }
    const mode = diagnosticAiAgentModeForQuestion(this.question);
    this.agentMode = mode;
    if (mode === 'diagnose') {
      this.modules = diagnosticAiModulesForQuestion(this.question);
      this.awaitingCapture = true;
      this.status = '这类问题需要读取一小段脱敏事件；请确认后开始抓取。';
      return;
    }
    this.awaitingCapture = false;
    void this.sendAgent(mode);
  }

  /** Submit a follow-up from the result surface while keeping the conversation summary in the request. */
  private submitDraftQuestion(): void {
    const value: string = this.draftQuestion.trim();
    if (value === '' || this.busy || this.capturing()) { return; }
    if (this.result !== null) {
      this.turns = this.turns.concat([new AiTurn(this.question, (this.result as DiagnosticAiResult).summary)]);
    }
    this.question = value;
    this.draftQuestion = '';
    this.appliedActions = [];
    this.result = null;
    this.expandedResult = false;
    this.mailPreviewVisible = false;
    this.latestBundleText = '';
    this.modules = [];
    this.awaitingCapture = false;
    this.status = '';
    this.submitQuestion();
  }

  /** Refresh the pills shortly after typing pauses; only a change of topic swaps them. */
  private followTyping(text: string): void {
    if (this.suggestionTimer >= 0) { clearTimeout(this.suggestionTimer); }
    this.suggestionTimer = setTimeout((): void => {
      this.suggestionTimer = -1;
      const next: AiSuggestion[] = aiSuggestionsFor(text);
      if (next.map((s: AiSuggestion): string => s.label).join() ===
        this.suggestions.map((s: AiSuggestion): string => s.label).join()) { return; }
      this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) }, (): void => { this.suggestions = next; });
    }, 380);
  }

  /** Pills rise in one after another; on a topic change the old ones fade out as the new ones arrive. */
  private pillTransition(index: number): TransitionEffect {
    return TransitionEffect.asymmetric(
      // Unhurried and springy: each pill pops up from below, overshoots a little and settles.
      TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 18 }))
        .combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
        .animation({ curve: curves.springMotion(0.62, 0.58), delay: 260 + index * 130 }),
      TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.9, y: 0.9 }))
        .animation({ duration: 160, curve: Curve.EaseIn }));
  }

  private conversationHeight(): number {
    const usual: number = this.siriResultHeight() + 150;
    return Math.min(this.expandedResult ? 100000 : usual, this.cardBodyLimit());
  }

  /** Room for the card's content inside the island's limit, minus the card's own top and bottom padding. */
  private cardBodyLimit(): number {
    if (this.maxCardHeight <= 0) { return 100000; }
    const top: number = this.cardTopPadding >= 0 ? this.cardTopPadding : this.deviceClass === 'phone' ? 22 : 18;
    const bottom: number = this.deviceClass === 'phone' ? 16 : 12;
    return Math.max(120, this.maxCardHeight - top - bottom);
  }

  /**
   * What the answer suggests doing, as pills to tap: setting changes the app can apply directly, and the app screens
   * its steps point to (only whitelisted ones; a step that matches none stays text). Applied changes drop out.
   */
  private resultActions(): AiAction[] {
    const result: DiagnosticAiResult | null = this.result;
    if (result === null) { return []; }
    const actions: AiAction[] = [];
    result.settingProposals.forEach((proposal: DiagnosticAiSettingProposal, index: number): void => {
      const key: string = 'set-' + proposal.settingId + '-' + proposal.proposedValue;
      if (this.appliedActions.indexOf(key) < 0) {
        actions.push(new AiAction(key, diagnosticAiSettingActionText(proposal.settingId) + ' → ' + proposal.proposedValue,
          proposal, null));
      }
    });
    diagnosticAiAppActionsForSteps(result.recommendedReadOnlySteps)
      .forEach((action: DiagnosticAiAppAction): void => {
        actions.push(new AiAction('app-' + action.id, action.label, null, action.id));
      });
    if (this.agentMode === 'diagnose' || this.agentMode === 'feedback' || this.latestBundleText !== '') {
      actions.push(this.mailPreviewVisible ? new AiAction('mail-open', '打开系统邮件', null, null, 'mailOpen') :
        new AiAction('mail-draft', '生成邮件草稿', null, null, 'mail'));
    }
    actions.push(new AiAction('new-conversation', '新对话', null, null, 'new'));
    return actions;
  }

  /** Keep the finished exchange for the next time the assistant opens, and show the answer from its start. */
  private rememberExchange(result: DiagnosticAiResult): void {
    AiConversationMemory.owner = this.owner;
    AiConversationMemory.history = this.conversation;
    AiConversationMemory.turns = this.turns.concat([new AiTurn(this.question, result.summary)]);
    setTimeout((): void => {
      if (this.turns.length > 0) { this.answerScroller.scrollEdge(Edge.Bottom); }
    }, 80);
  }

  private startNewConversation(): void {
    AiConversationMemory.clear(this.owner);
    this.conversation = '';
    this.turns = [];
    this.result = null; this.question = ''; this.status = ''; this.mailPreviewVisible = false; this.modules = [];
    this.awaitingCapture = false; this.agentMode = 'answer'; this.expandedResult = false; this.draftQuestion = '';
    this.appliedActions = [];
    this.focusQuestion();
  }

  private runAction(action: AiAction): void {
    if (action.special === 'new') { this.startNewConversation(); return; }
    if (action.special === 'mailOpen') {
      this.onOpenMailDraft(this.mailSubject, this.mailBody); this.mailPreviewVisible = false; return;
    }
    if (action.special === 'mail') {
      const draft = diagnosticAiMailDraft(this.question, this.result as DiagnosticAiResult, {
        captureId: 'latest', schemaVersion: 8, modules: this.modules,
        text: this.latestBundleText, eventCount: this.eventCount, bytes: this.latestBundleText.length
      });
      this.mailSubject = draft.subject; this.mailBody = draft.body; this.mailPreviewVisible = true;
      return;
    }
    if (action.proposal !== null) {
      const applied: boolean = diagnosticAiApplyProposal(action.proposal);
      this.status = applied ? '已应用：' + diagnosticAiSettingActionText(action.proposal.settingId) : '该建议未通过安全白名单';
      if (applied) {
        this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) },
          (): void => { this.appliedActions = this.appliedActions.concat([action.key]); });
      }
      return;
    }
    if (action.appAction !== null) {
      this.onAppAction(action.appAction);
    }
  }

  @Builder private expandButton() {
    Stack() {
      SymbolGlyph($r(this.expandedResult ? 'sys.symbol.arrow_down_right_and_arrow_up_left' :
        'sys.symbol.arrow_up_left_and_arrow_down_right'))
        .fontSize(17).fontColor(['#FFFFFF'])
    }
    .width(36).height(36).borderRadius(18)
    .backgroundColor('#2E3A3A3C')
    .backdropBlur(10)
    .border({ width: { top: 0.8, left: 0.6, right: 0.6, bottom: 0.6 },
      color: { top: '#4DFFFFFF', left: '#1FFFFFFF', right: '#1FFFFFFF', bottom: '#14FFFFFF' } })
    .accessibilityText(this.expandedResult ? '收起完整回答' : '展开完整回答')
    .onClick((): void => {
      this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) },
        (): void => { this.expandedResult = !this.expandedResult; });
    })
  }

  /** Siri's conversation input bar (after a reply): the glass capsule with the field, the send button beside it. */
  @Builder private inputBar() {
    Row({ space: 10 }) {
      AiInputCapsule() {
        TextInput({ placeholder: '继续询问 AI 助手', text: this.draftQuestion })
          .layoutWeight(1).height(40).fontSize(16).fontColor('#FFFFFF').placeholderColor('#8E8E93')
          .caretStyle({ width: 2.5, color: '#FFFFFF' }).backgroundColor(Color.Transparent).padding(0)
          .onChange((value: string): void => { this.draftQuestion = value; this.followTyping(value); })
          .onSubmit((): void => { this.submitDraftQuestion(); })
      }
      AiSendButton({ active: this.draftQuestion.trim() !== '', buttonSize: 38,
        onTap: (): void => { this.submitDraftQuestion(); } })
    }.width('100%').alignItems(VerticalAlign.Bottom)
  }

  private quickQuestion(mode: DiagnosticAiAgentMode, question: string): void {
    this.question = question;
    this.agentMode = mode;
    this.result = null;
    this.expandedResult = false;
    this.draftQuestion = '';
    this.status = '';
    this.awaitingCapture = mode === 'diagnose';
    this.modules = mode === 'diagnose' ? diagnosticAiModulesForQuestion(question) : [];
    // A function card is about to rise into the panel; let it be seen instead of covered by the keyboard.
    if (this.awaitingCapture) {
      try { inputMethod.getController().hideTextInput(); } catch (_error) { /* keyboard already down */ }
    }
  }

  /** The card's text area: the question typed in white, iOS secondary gray for everything else. */
  /**
   * No AI service yet: instead of a question field the assistant offers one card that takes the user to 辅助 AI 配置
   * (it opens like any app action: done check, then the floating orb until the settings are closed).
   */
  @Builder private setupGuide() {
    Column({ space: 14 }) {
      Text('先配置 AI 服务').fontSize(20).fontWeight(FontWeight.Medium).fontColor('#FFFFFF').width('100%')
      Text('AI 助手需要一个模型服务才能回答。选择服务商并保存 API Key 后就可以提问了。')
        .fontSize(14).lineHeight(20).fontColor('#8E8E93').width('100%')
      if (this.revealed) {
        Row({ space: 12 }) {
          Stack() {
            SymbolGlyph($r('sys.symbol.gearshape_fill')).fontSize(20).fontColor(['#FFFFFF'])
          }.width(40).height(40).borderRadius(20).backgroundColor('#2E3A3A3C')
          Column({ space: 2 }) {
            Text('前往 AI 配置').fontSize(16).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
            Text('选择服务商、模型并保存 API Key').fontSize(12).fontColor('#8E8E93')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor(['#8E8E93'])
        }
        .width('100%').padding(14).borderRadius(24).backgroundColor('#F01C1C1F')
        .border({ width: 0.5, color: '#1FFFFFFF' })
        .transition(this.pillTransition(0))
        .onClick((): void => { this.onAppAction('ai.config'); })
      }
    }.width('100%')
  }

  @Builder private siriCardBody() {
    if (!this.aiReady && this.result === null && !this.busy && !this.capturing()) {
      this.setupGuide()
    } else {
      this.chatBody()
    }
  }

  @Builder private chatBody() {
    Column({ space: 12 }) {
      // First question: Siri's text mode — typed straight into the card in large type, no field around it.
      if (this.result === null && !this.capturing() && !this.busy && !this.awaitingCapture) {
        // A hair space keeps the placeholder clear of the caret, which sits before the first character.
        TextArea({ placeholder: '\u200A描述遇到的问题 — 询问 AI', text: this.question })
          .id('aiIslandQuestion')
          .width('100%').fontSize(20).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
          .placeholderColor('#8E8E93').placeholderFont({ size: 20, weight: FontWeight.Medium })
          .caretStyle({ width: 2.5, color: '#FFFFFF' })
          .backgroundColor(Color.Transparent).padding({ left: 3, right: 0, top: 4, bottom: 2 })
          .constraintSize({ minHeight: 56, maxHeight: 180 })
          .enterKeyType(EnterKeyType.Go)
          .onChange((value: string): void => { this.question = value; this.followTyping(value); })
          .onSubmit((): void => { this.submitQuestion(); })
          .onAppear((): void => {
            // While the island is still a capsule the keyboard would jump in front of it; onRevealed focuses later.
            if (this.revealed) { this.focusQuestion(); }
          })
      } else {
        if (this.result !== null) {
          // The conversation scrolls below; the corner keeps the expand control, as in Siri.
          Row() {
            Text(this.turns.length > 0 ? '对话 · ' + (this.turns.length + 1).toString() + ' 轮' : '')
              .fontSize(12).fontColor('#8E8E93').layoutWeight(1)
            this.expandButton()
          }.width('100%')
        } else {
          Text(this.question).fontSize(17).lineHeight(23).fontColor('#FFFFFF').width('100%').maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      if (this.revealed && this.result === null && !this.capturing() && !this.busy && !this.awaitingCapture) {
        Row({ space: 10 }) {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(this.suggestions, (item: AiSuggestion, index: number): void => {
              Row() { this.plainPill(item.label, false, (): void => { this.quickQuestion(item.mode, item.question); }) }
                .margin({ right: 8, top: 4, bottom: 4 })
                .transition(this.pillTransition(index))
            }, (item: AiSuggestion): string => item.label)
          }.layoutWeight(1)
          AiSendButton({ active: this.question.trim() !== '', buttonSize: 36,
            onTap: (): void => { this.submitQuestion(); } })
            .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.4, y: 0.4 }))
              .animation({ curve: curves.springMotion(0.6, 0.55), delay: 260 + 3 * 130 }))
        }.width('100%').alignItems(VerticalAlign.Bottom)
      }
      if (this.awaitingCapture && !this.capturing() && !this.busy) {
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            AiAssistantGlyph({ glyphSize: 22, ink: '#F2F2F7' })
            Column({ space: 2 }) {
              Text('要开始诊断吗？').fontSize(14).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
              Text('只读取脱敏事件：' + this.modules.join('、')).fontSize(12).fontColor('#C7C7CC')
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          }.width('100%')
          Text('你可以先复现问题；点击「开始抓取诊断」后才会读取这部分日志。')
            .fontSize(12).lineHeight(17).fontColor('#8E8E93').width('100%')
        }.width('100%').padding(14).borderRadius(24).backgroundColor('#F01C1C1F')
          .border({ width: 0.5, color: '#1FFFFFFF' })
          .transition(this.functionCardTransition())
      }
      if (this.capturing()) {
        Row({ space: 8 }) {
          Circle().width(7).height(7).fill('#FF453A')
            .opacity(this.pulse ? 1 : 0.35).animation({ duration: 480, curve: Curve.EaseInOut })
          Text('正在抓取 · ' + this.eventCount.toString() + ' 条事件 · ' + this.elapsed.toString() + ' 秒')
            .fontSize(14).fontColor('#8E8E93').layoutWeight(1)
        }.width('100%')
        Text('现在去复现问题，完成后点「结束并分析」').fontSize(13).fontColor('#8E8E93').width('100%')
      } else if (this.busy) {
        Row({ space: 10 }) {
          AiKernelRing({ ringSize: 30 })
          Text('正在思考…').fontSize(15).fontColor('#C7C7CC')
        }.width('100%')
      } else if (this.status.length > 0 && this.result === null && this.status.indexOf('正在') < 0) {
        Text(this.status).fontSize(13).lineHeight(18).fontColor('#FF9F0A').width('100%')
      }
      if (this.result !== null) {
        Scroll(this.answerScroller) {
          Column({ space: 12 }) {
            ForEach(this.turns, (turn: AiTurn, index: number): void => {
              Column({ space: 6 }) {
                Text(turn.question).fontSize(14).lineHeight(20).fontColor('#8E8E93').width('100%')
                Text(turn.answer).fontSize(15).lineHeight(22).fontColor('#C7C7CC').width('100%')
                  .copyOption(CopyOptions.InApp)
              }.width('100%').padding({ bottom: 12 })
              .border({ width: { bottom: 0.5 }, color: { bottom: '#26FFFFFF' } })
            }, (turn: AiTurn, index: number): string => 'turn-' + index.toString())
            Text(this.question).fontSize(14).lineHeight(20).fontColor('#8E8E93').width('100%')
            Text((this.result as DiagnosticAiResult).summary).fontSize(17).lineHeight(25).fontColor('#FFFFFF')
              .width('100%').copyOption(CopyOptions.InApp)
            Text('影响 ' + this.severityText() + ' · 置信度 ' +
              Math.round((this.result as DiagnosticAiResult).confidence * 100).toString() + '%')
              .fontSize(12).fontColor('#8E8E93').width('100%')
            if ((this.result as DiagnosticAiResult).unknowns.length > 0) {
              Text('尚不确定：' + (this.result as DiagnosticAiResult).unknowns.join('；')).fontSize(13).lineHeight(19)
                .fontColor('#8E8E93').width('100%')
            }
            if ((this.result as DiagnosticAiResult).recommendedReadOnlySteps.length > 0) {
              Text('建议操作').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#FFFFFF').width('100%')
              ForEach((this.result as DiagnosticAiResult).recommendedReadOnlySteps, (step: string, index: number): void => {
                Text((index + 1).toString() + '. ' + step).fontSize(13).lineHeight(19).fontColor('#C7C7CC').width('100%')
              }, (_step: string, index: number): string => 'siri-step' + index.toString())
            }
            ForEach((this.result as DiagnosticAiResult).settingProposals, (proposal: DiagnosticAiSettingProposal): void => {
              Row({ space: 10 }) {
                Column({ space: 2 }) {
                  Text(diagnosticAiSettingActionText(proposal.settingId) + ' → ' + proposal.proposedValue)
                    .fontSize(14).fontWeight(FontWeight.Medium).fontColor('#FFFFFF').width('100%')
                  Text(proposal.reason).fontSize(12).lineHeight(17).fontColor('#8E8E93').width('100%')
                }.layoutWeight(1)
              }.width('100%').padding(14).borderRadius(22).backgroundColor('#F01C1C1F')
              .border({ width: 0.5, color: '#1FFFFFFF' })
              .transition(this.functionCardTransition())
            }, (_proposal: DiagnosticAiSettingProposal, index: number): string => index.toString())
            if (this.mailPreviewVisible) {
              Column({ space: 6 }) {
                Text('邮件预览 · ' + this.mailSubject).fontSize(13).fontColor('#FFFFFF').width('100%')
                Scroll() {
                  Text(this.mailBody).fontSize(12).lineHeight(17).fontColor('#C7C7CC').width('100%')
                    .copyOption(CopyOptions.InApp)
                }.height(120).width('100%')
              }.width('100%').padding(14).borderRadius(22).backgroundColor('#F01C1C1F')
              .border({ width: 0.5, color: '#1FFFFFFF' })
              .transition(this.functionCardTransition())
            }
          }.width('100%')
        }.layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
        // Text running past the top or bottom of the answer fades out instead of being cut.
        .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(28) })
        // Over the input bar: what the answer suggests doing — or, while a follow-up is typed, questions that follow it.
        if (this.revealed && this.draftQuestion.trim() !== '') {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(this.suggestions, (item: AiSuggestion, index: number): void => {
              Row() {
                this.plainPill(item.label, false, (): void => {
                  this.draftQuestion = item.question;
                  this.submitDraftQuestion();
                })
              }
                .margin({ right: 8, top: 4, bottom: 4 })
                .transition(this.pillTransition(index))
            }, (item: AiSuggestion): string => 'ask-' + item.label)
          }.width('100%')
        } else if (this.revealed && this.resultActions().length > 0) {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(this.resultActions(), (item: AiAction, index: number): void => {
              Row() { this.plainPill(item.label, false, (): void => { this.runAction(item); }) }
                .margin({ right: 8, top: 4, bottom: 4 })
                .transition(this.pillTransition(index))
            }, (item: AiAction): string => item.key)
          }.width('100%')
        }
        this.inputBar()
      }
    }.width('100%')
    // After a reply the panel turns into Siri's conversation surface with a set height (never more than the island
    // allows, so it ends above the keyboard): the answer scrolls in the middle, the input bar stays at its foot.
    // Expanded, it takes all the room there is.
    .height(this.result === null ? undefined : this.conversationHeight())
    .constraintSize({ maxHeight: this.cardBodyLimit() })
  }

  @Builder private siriLayout() {
    Column({ space: 12 }) {
      // The card: dark glass; the system AI colors glow out from under its lower edge.
      Stack({ alignContent: Alignment.Bottom }) {
        if (!this.shellless) {
          // Keep the HDS-like light constrained to the card's lower edge. It is deliberately not a full-screen rainbow.
          Column() {
            Row().width('100%').height(34).borderRadius(17)
              .linearGradient({ angle: 90, colors: [['#42CBF7', 0], ['#2A7DFF', 0.28], ['#A479FF', 0.58], ['#FF678C', 1]] })
            Row().width('82%').height(12).borderRadius(6)
              .linearGradient({ angle: 90, colors: [['#72E6FF', 0], ['#8C6BFF', 0.55], ['#FFB4C6', 1]] })
              .margin({ top: -6 })
          }.width(this.deviceClass === 'phone' ? '92%' : '76%').height(40).offset({ y: 12 })
          .blur(this.deviceClass === 'phone' ? 32 : 28).opacity(this.lastActive ? 1 : 0.74)
          HdsImmersiveEdgeLight({ active: this.lastActive || this.result !== null })
            .width('100%').height(36).offset({ y: 8 })
        }
        Column() { this.siriCardBody() }
          .width('100%').padding({ left: this.siriSidePadding(), right: this.siriSidePadding() - 4,
            top: this.cardTopPadding >= 0 ? this.cardTopPadding : this.deviceClass === 'phone' ? 22 : 18, bottom: this.deviceClass === 'phone' ? 16 : 12 })
          .borderRadius(this.siriRadius()).clip(!this.shellless)
          .backgroundBlurStyle(this.shellless ? BlurStyle.NONE : BlurStyle.COMPONENT_ULTRA_THICK,
            { colorMode: ThemeColorMode.DARK, adaptiveColor: AdaptiveColor.DEFAULT })
          .backgroundColor(this.shellless ? Color.Transparent : this.deviceClass === 'phone' ? '#EC080A10' : '#E016161B')
          .border({ width: this.shellless ? 0 : { top: 0.8, left: 0.5, right: 0.5, bottom: 0.5 },
            color: { top: '#4DFFFFFF', left: '#1FFFFFFF', right: '#1FFFFFFF', bottom: '#1FFFFFFF' } })
          .shadow(this.shellless ? { radius: 0, color: Color.Transparent } :
            { radius: this.deviceClass === 'phone' ? 36 : 30, color: '#60000000', offsetY: 12 })
          .onAreaChange((_old: Area, area: Area): void => { this.reportCardSize(area); })
      }.width('100%')
      // Floating pill actions under the card.
      Row({ space: 8 }) {
        if (this.capturing()) {
          this.pill('结束并分析', true, (): void => { void this.finishCapture(); })
          this.pill('取消', false, (): void => {
            this.capture.cancel(this.owner); this.captureOwnedByPanel = false;
            this.onCaptureStateChanged(false); this.syncCapture(); this.status = '已取消抓取';
          })
        }
        if (this.awaitingCapture && !this.capturing() && !this.busy) {
          this.pill('开始抓取诊断', true, (): void => { this.beginCapture(); })
          this.pill('取消', false, (): void => { this.awaitingCapture = false; this.status = ''; })
        }
      }.width('100%').justifyContent(FlexAlign.Center)
    }.width('100%')
  }

  /**
   * Floating, the assistant is only Siri's voice orb: it keeps working (capture, thinking) or waits while the user
   * works in a screen an answer opened, and a tap brings the conversation back.
   */
  @Builder private compactLayout() {
    Stack() {
      AiSiriOrb({ orbSize: AI_FLOAT_ORB, active: this.lastActive })
    }
    .width(AI_FLOAT_ORB).height(AI_FLOAT_ORB)
    .accessibilityText(this.capturing() ? 'AI 助手正在抓取，轻点返回对话' : this.busy ? 'AI 助手正在思考，轻点返回对话' :
      'AI 助手，轻点返回对话')
    .onAreaChange((_old: Area, area: Area): void => { this.reportCardSize(area); })
  }

  build() {
    if (this.siriMode && this.compact) {
      this.compactLayout()
    } else if (this.siriMode) {
      this.siriLayout()
    } else {
      this.panelLayout()
    }
  }

  @Builder private panelLayout() {
    Column() {
      if (!this.embedded) {
        Row({ space: 10 }) {
          Text('启动 AI 辅助').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
            .fontFamily(AppConfig.fontFamily).layoutWeight(1)
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2]).padding(8)
            .onClick((): void => { this.onClose(); })
        }.width('100%').margin({ bottom: 12 })
      }
      Scroll() {
        Column({ space: 12 }) {
          Row({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.checkmark_shield')).fontSize(18).fontColor(['#2BB673'])
            Text('可以回答应用用法、协助设置和诊断问题。需要读取诊断事件或生成邮件时，会先让你选择；不会自动执行或发送。')
              .fontSize(12).lineHeight(18).fontColor(this.pal().text2).layoutWeight(1)
          }.width('100%').padding(12).borderRadius(14).backgroundColor('#142BB673').alignItems(VerticalAlign.Top)
          Column({ space: 8 }) {
            Text('遇到了什么问题？').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
            TextArea({ placeholder: '问问 RemoteDesktop，或描述你想完成的操作', text: this.question })
              .height(96).fontSize(15).fontFamily(AppConfig.fontFamily)
              .backgroundColor(this.pal().surface).borderRadius(14).enabled(!this.busy && !this.capturing())
              .onChange((value: string): void => { this.question = value; })
            if (this.modules.length > 0 && (this.awaitingCapture || this.capturing())) {
              Flex({ wrap: FlexWrap.Wrap }) {
                Text('抓取范围').fontSize(11).fontColor(this.pal().text3).margin({ right: 6, bottom: 6, top: 4 })
                ForEach(this.modules, (module: DiagnosticModuleId): void => {
                  Text(module).fontSize(11).fontColor(this.accent).padding({ left: 8, right: 8, top: 3, bottom: 3 })
                    .borderRadius(9).backgroundColor(this.pal().surface).margin({ right: 6, bottom: 6 })
                }, (module: DiagnosticModuleId): string => module)
              }.width('100%')
            }
          }.width('100%').padding(14).borderRadius(18).backgroundColor(this.pal().card)
          .border({ width: 0.5, color: this.pal().cardBorder })
          if (this.capturing()) {
            this.captureCard()
          }
          if (this.status.length > 0 && !this.capturing()) {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.info_circle_fill')).fontSize(15).fontColor([this.accent])
              Text(this.status).fontSize(12).lineHeight(17).fontColor(this.pal().text).layoutWeight(1)
            }.width('100%').padding(10).borderRadius(12).backgroundColor(this.pal().surface)
          }
          if (this.result !== null) {
            this.resultCard()
          }
        }.width('100%').padding({ bottom: 12 })
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
      Row({ space: 10 }) {
        if (this.capturing()) {
          Button('取消').height(48).layoutWeight(1).borderRadius(24).backgroundColor(this.pal().surface)
            .fontColor(this.pal().text).enabled(!this.busy)
            .onClick((): void => { this.capture.cancel(this.owner); this.captureOwnedByPanel = false;
              this.onCaptureStateChanged(false); this.syncCapture(); this.status = '已取消抓取'; })
        }
        Button(this.busy ? 'AI 思考中…' : this.capturing() ? '结束并分析' : this.awaitingCapture ? '开始抓取诊断' : this.result !== null ? '再问一个' : '发送给 AI')
          .height(48).layoutWeight(1).borderRadius(24).fontSize(16).fontWeight(FontWeight.Medium)
          .backgroundColor(this.accent).fontColor(Color.White)
          .enabled(!this.busy && this.question.trim() !== '')
          .onClick((): void => {
            if (this.capturing()) { void this.finishCapture(); }
            else if (this.awaitingCapture) { this.beginCapture(); }
            else if (this.result !== null) { this.result = null; this.question = ''; this.status = ''; this.mailPreviewVisible = false; }
            else { this.submitQuestion(); }
          })
      }.width('100%').margin({ top: 10 })
    }.width('100%').height('100%').padding(this.embedded ? 0 : 20)
    .backgroundColor(this.embedded ? Color.Transparent : this.pal().sheetBg)
  }
}
