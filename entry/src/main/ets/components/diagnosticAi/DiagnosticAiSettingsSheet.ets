import { AiMotionSettingsPanel } from './AiMotionSettingsPanel';
import { appUiOnAccentText } from '../../common/AppUiColorPolicy';
import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { AppConfig, Palette, buildDark, buildLight } from '../../common/Theme';
import { AppSettingsActionRow } from '../AppSettingsActionRow';
import { AppUiMetrics } from '../../common/AppUiMetrics';
import { DiagnosticAiAssistantPanel } from './DiagnosticAiAssistantPanel';
import { AiSegmented } from './AiSegmented';
import { AiSkillsSettingsPanel } from './AiSkillsSettingsPanel';
import { AiVoiceSettingsPanel } from './AiVoiceSettingsPanel';
import { DiagnosticAiAuthMode, DiagnosticAiModelInfo, DiagnosticAiModelPriceEntry, DiagnosticAiProviderManifest, DiagnosticAiProviderProfile, DiagnosticAiSettings } from '../../services/diagnosticAi/DiagnosticAiModels';
import { diagnosticAiHarmonyLocalDeviceSupported, diagnosticAiProviderCodingPlanAvailable, diagnosticAiProviderIsHarmonyLocal, diagnosticAiProviderManifests, diagnosticAiProviderNormalApiAvailable, diagnosticAiProviderSupportsDevice, HARMONY_LOCAL_MODEL_ID } from '../../services/diagnosticAi/DiagnosticAiProviderCatalog';
import { diagnosticAiProviderManifest } from '../../services/diagnosticAi/DiagnosticAiProviderCatalog';
import { validateDiagnosticAiEndpoint } from '../../services/diagnosticAi/DiagnosticAiEndpointPolicy';
import { DiagnosticAiProfileStore } from '../../services/diagnosticAi/DiagnosticAiProfileStore';
import { DiagnosticAiProviderService, diagnosticAiPrivacySummary } from '../../services/diagnosticAi/DiagnosticAiProviderService';
import { DiagnosticAiModelCatalog } from '../../services/diagnosticAi/DiagnosticAiModelCatalog';
import { AccountSessionCoordinator } from '../../services/AccountSessionCoordinator';
import { ProAppRuntime } from '../../services/pro/ProAppRuntime';
import { ProEntries } from '../../services/pro/ProEntries';
import { PRO_DIAGNOSTICS_ASSISTANT_FEATURE, PRO_DIAGNOSTICS_FEATURE, PRO_DIAGNOSTICS_PROVIDER_FEATURE } from '../../services/pro/ProFeatureCatalog';
import { diagnosticAiUsageDay, DiagnosticAiDailyProviderUsage, DiagnosticAiDailyUsage, DiagnosticAiAssistantPreferences, DiagnosticAiConversationSession, DiagnosticAiConversationStore, DiagnosticAiConversationTurn, DiagnosticAiProviderUsage, DiagnosticAiUsageSnapshot, defaultDiagnosticAiAssistantPreferences, diagnosticAiSessionKind } from '../../services/diagnosticAi/DiagnosticAiConversationStore';
import { DiagnosticAiAppActionId } from '../../services/diagnosticAi/DiagnosticAiAppActionPolicy';

class DiagnosticAiPersonalityChoice {
  id: 'balanced' | 'warm' | 'concise' | 'technical';
  label: string;
  constructor(id: 'balanced' | 'warm' | 'concise' | 'technical', label: string) { this.id = id; this.label = label; }
}

class DiagnosticAiChoice {
  id: string;
  label: string;
  constructor(id: string, label: string) { this.id = id; this.label = label; }
}

const DIAGNOSTIC_AI_PERSONALITY_CHOICES: DiagnosticAiPersonalityChoice[] = [
  new DiagnosticAiPersonalityChoice('balanced', '均衡'), new DiagnosticAiPersonalityChoice('warm', '温和'),
  new DiagnosticAiPersonalityChoice('concise', '简洁'), new DiagnosticAiPersonalityChoice('technical', '技术')
];

const DIAGNOSTIC_AI_VERBOSITY_CHOICES: DiagnosticAiChoice[] = [
  new DiagnosticAiChoice('concise', '简洁'), new DiagnosticAiChoice('standard', '标准'), new DiagnosticAiChoice('detailed', '详细')
];
const DIAGNOSTIC_AI_ROLE_CHOICES: DiagnosticAiChoice[] = [
  new DiagnosticAiChoice('remote-expert', '远程桌面专家'), new DiagnosticAiChoice('beginner-guide', '新手引导'),
  new DiagnosticAiChoice('diagnostic-first', '排障优先'), new DiagnosticAiChoice('privacy-first', '隐私优先')
];

/** What each personality, length and role means for the answers, shown under the choice. */
function aiPersonalityNote(id: string): string {
  switch (id) {
    case 'warm': return '语气更耐心，会解释每一步为什么这么做';
    case 'concise': return '只说结论和最关键的一两步';
    case 'technical': return '会讲协议细节、错误码和日志依据';
    default: return '先给结论，再列出操作步骤';
  }
}

function aiVerbosityNote(id: string): string {
  if (id === 'concise') { return '一两句话说清楚'; }
  if (id === 'detailed') { return '补充原因、注意事项和替代方案'; }
  return '结论加上必要的步骤';
}

function aiRoleNote(id: string): string {
  switch (id) {
    case 'beginner-guide': return '少用术语，一步一步带着做';
    case 'diagnostic-first': return '遇到问题先帮你定位原因、建议抓日志';
    case 'privacy-first': return '尽量少读日志，涉及数据外发时先说明';
    default: return '覆盖各协议的使用、设置与排障';
  }
}

/** A sample answer to "RDP 连不上怎么办？" in the chosen style and length, for the preview bubble. */
function aiPreviewAnswer(personality: string, verbosity: string): string {
  const head: string = personality === 'technical' ? '连接在 TCP 握手阶段失败（ERRCONNECT_CONNECT_TRANSPORT_FAILED），3389 端口不可达。' :
    personality === 'warm' ? '别担心，这多半是电脑那边还没准备好接受远程连接。' :
    personality === 'concise' ? '电脑的远程桌面没开，或端口被拦截了。' : '多半是电脑没有开启远程桌面，或防火墙拦住了连接。';
  if (verbosity === 'concise') { return head; }
  const steps: string = personality === 'concise' ? '\n1. 在电脑上打开"远程桌面"。' :
    '\n1. 在电脑上打开"设置 → 系统 → 远程桌面"。\n2. 确认防火墙放行"远程桌面"。';
  if (verbosity === 'standard') { return head + steps; }
  return head + steps + '\n3. 如果走的是外网，还要在路由器上转发 3389 端口。' +
    (personality === 'warm' ? '\n做完这几步再试一次，有问题我陪你继续查。' : '');
}

const CONFIG_TABS: string[][] = [['api', 'API Key'], ['coding', 'Coding Plan'], ['local', '本机模型']];
/** Coding Plan access is closed for now: most plans only allow their own coding tools, so nothing can be saved here. */
const CODING_PLAN_OPEN: boolean = false;

const USAGE_RANGES: string[][] = [['today', '今天'], ['7d', '7 天'], ['30d', '30 天'], ['all', '全部']];
const USAGE_AVATAR_COLORS: string[] = ['#5E5CE6', '#0A84FF', '#30B0C7', '#34C759', '#FF9F0A', '#FF375F', '#BF5AF2'];

/** One time range of 用量监控, summed over the selected subscription(s). */
class AiUsageView {
  requests: number = 0;
  failed: number = 0;
  prompt: number = 0;
  completion: number = 0;
  cached: number = 0;
  cost: number = 0;
}

/** A subscription's share of the chosen range. */
class AiUsageRow {
  key: string;
  name: string;
  model: string;
  view: AiUsageView;

  constructor(key: string, name: string, model: string, view: AiUsageView) {
    this.key = key;
    this.name = name;
    this.model = model;
    this.view = view;
  }
}

/** One bar of the daily chart. */
class AiUsageBar {
  day: string;
  label: string;
  tokens: number;
  today: boolean;

  constructor(day: string, label: string, tokens: number, today: boolean) {
    this.day = day;
    this.label = label;
    this.tokens = tokens;
    this.today = today;
  }
}

/** Saved conversations of one date group (今天 / 昨天 / 近 7 天 / 更早). */
class AiSessionGroup {
  title: string;
  sessions: DiagnosticAiConversationSession[];

  constructor(title: string, sessions: DiagnosticAiConversationSession[]) {
    this.title = title;
    this.sessions = sessions;
  }
}

@Component
export struct DiagnosticAiSettingsSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'md';
  onClose: () => void = (): void => {};
  onAppAction: (action: DiagnosticAiAppActionId) => void = (_action: DiagnosticAiAppActionId): void => {};
  /** Replace the current native settings sheet with the assistant sheet for a saved session. */
  onOpenSession: (sessionId: string) => void = (_sessionId: string): void => {};
  initialResumeSessionId: string = '';
  /** Which sub-setting this sheet shows: 0 config, 1 assistant, 3 usage, 4 personalization, 5 sessions. */
  @Prop section: number = 0;
  @State manifests: DiagnosticAiProviderManifest[] = [];
  @State profiles: DiagnosticAiProviderProfile[] = [];
  @State settings: DiagnosticAiSettings = { selectedProviderId: '', selectedModelId: '', selectedAuthMode: '', showOrbOnHostPage: false, reducedMotion: false, retentionDays: 7 };
  @State selectedProvider: string = 'deepseek';
  @State authModeDraft: DiagnosticAiAuthMode = 'api_key';
  @State termsAcceptedDraft: boolean = false;
  @State endpoint: string = '';
  @State keyText: string = '';
  @State model: string = '';
  @State message: string = '';
  @State busy: boolean = false;
  @State availableModels: DiagnosticAiModelInfo[] = [];
  @State deviceType: string = 'unknown';
  @State sessions: DiagnosticAiConversationSession[] = [];
  @State usageSnapshot: DiagnosticAiUsageSnapshot = { requestCount: 0, promptTokens: 0, completionTokens: 0, cachedTokens: 0, estimatedCostCny: 0, updatedAt: 0, providerUsage: [] };
  @State assistantPreferences: DiagnosticAiAssistantPreferences = defaultDiagnosticAiAssistantPreferences();
  @State memoryDraft: string = '';
  @State assistantNameDraft: string = 'RD Assistant';
  @State sessionMemorySummary: string = '';
  @State modelPricing: DiagnosticAiModelPriceEntry[] = [];
  @State resumeSessionId: string = '';
  @State usageProviderFilter: string = '';
  /** 用量监控 time range: today, 7d, 30d or all. */
  @State usageRange: string = '7d';
  @State pricingExpanded: boolean = false;
  /** 对话记录: search text. */
  @State sessionQuery: string = '';
  /** AI 对话记录: 助理 sessions and 聊天 sessions are listed apart. */
  @State sessionKind: string = 'assistant';
  /** 辅助 AI 配置: which kind of service is being set up (按量 API, Coding Plan or a model on this device). */
  @State configTab: string = 'api';
  /** 个性化: every change saves at once; this flashes 已保存 next to the section title. */
  @State assistantSavedFlash: boolean = false;
  @State memoryExpanded: boolean = false;
  private assistantSavedTimer: number = -1;
  private memorySaveTimer: number = -1;
  @State updatingModelPricing: boolean = false;
  @State private personalityDraft: 'balanced' | 'warm' | 'concise' | 'technical' = 'balanced';
  @State private verbosityDraft: 'concise' | 'standard' | 'detailed' = 'standard';
  @State private roleDraft: 'remote-expert' | 'beginner-guide' | 'diagnostic-first' | 'privacy-first' = 'remote-expert';
  @State private languageDraft: 'zh-CN' | 'en-US' = 'zh-CN';
  @State private memoryEnabledDraft: boolean = true;
  @State private proactiveSuggestionsDraft: boolean = true;
  @State private confirmBeforeActionsDraft: boolean = true;
  private readonly providerService: DiagnosticAiProviderService = new DiagnosticAiProviderService();
  private readonly modelCatalog: DiagnosticAiModelCatalog = new DiagnosticAiModelCatalog();
  private readonly conversationStore: DiagnosticAiConversationStore = new DiagnosticAiConversationStore();
  private store: DiagnosticAiProfileStore = new DiagnosticAiProfileStore();
  private owner: string = 'device-local';
  private accountUnsubscribe: (() => void) | null = null;

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }

  private authModeLabel(mode: DiagnosticAiAuthMode): string {
    if (mode === 'api_key') { return 'API Key'; }
    if (mode === 'coding_plan_key') { return 'Coding Plan 专用 Key'; }
    if (mode === 'oauth_pkce') { return '官方账户登录'; }
    if (mode === 'device_authorization') { return '设备授权'; }
    if (mode === 'official_cli_bridge') { return '官方 CLI Bridge'; }
    if (mode === 'none') { return '本机/端侧'; }
    return '暂不可用';
  }

  private selectedProfileForAuthMode(): DiagnosticAiProviderProfile | undefined {
    return this.profiles.find((value: DiagnosticAiProviderProfile): boolean =>
      value.providerId === this.selectedProvider && value.authMode === this.authModeDraft);
  }

  private authModesForSelected(): DiagnosticAiAuthMode[] {
    const manifest: DiagnosticAiProviderManifest | undefined = this.selectedManifest();
    return manifest === undefined ? [] : manifest.authModes.slice();
  }

  private extraAuthModesForSelected(): DiagnosticAiAuthMode[] {
    return this.authModesForSelected().filter((mode: DiagnosticAiAuthMode): boolean =>
      mode !== 'api_key' && mode !== 'coding_plan_key' && mode !== 'none');
  }

  aboutToAppear(): void {
    try { this.deviceType = deviceInfo.deviceType; } catch (_error) { this.deviceType = 'unknown'; }
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    this.reloadScope(scope.ownerScopeId);
    if (this.accountUnsubscribe === null) {
      this.accountUnsubscribe = AccountSessionCoordinator.getInstance().onChange((nextScope): void => {
        this.reloadScope(nextScope.ownerScopeId);
        this.message = '账号作用域已切换，已重新加载 AI 配置；旧密钥不会继续使用';
      });
    }
  }

  aboutToDisappear(): void {
    if (this.accountUnsubscribe !== null) { this.accountUnsubscribe(); this.accountUnsubscribe = null; }
  }

  private reloadScope(ownerScopeId: string): void {
    this.owner = ownerScopeId.trim() === '' ? 'device-local' : ownerScopeId.trim();
    this.selectedProvider = 'deepseek'; this.authModeDraft = 'api_key'; this.termsAcceptedDraft = false;
    this.manifests = diagnosticAiProviderManifests(); this.store.init(getContext(this) as common.UIAbilityContext, this.owner);
    this.conversationStore.init(getContext(this) as common.UIAbilityContext, this.owner);
    this.modelCatalog.init(getContext(this) as common.UIAbilityContext, this.owner);
    this.profiles = this.store.list(); this.settings = this.store.settingsSnapshot();
    AppStorage.setOrCreate('diagnosticAiReducedMotion', this.settings.reducedMotion);
    this.sessions = this.conversationStore.listSessions();
    this.sessionMemorySummary = this.conversationStore.summarizedSessionMemory();
    this.modelPricing = this.modelCatalog.list();
    this.usageSnapshot = this.conversationStore.usage();
    this.assistantPreferences = this.conversationStore.assistantPreferences();
    this.assistantNameDraft = this.assistantPreferences.name;
    this.personalityDraft = this.assistantPreferences.personality;
    this.verbosityDraft = this.assistantPreferences.verbosity;
    this.roleDraft = this.assistantPreferences.role;
    this.languageDraft = this.assistantPreferences.language;
    this.memoryEnabledDraft = this.assistantPreferences.memoryEnabled;
    this.memoryDraft = this.assistantPreferences.manualMemorySummary;
    this.proactiveSuggestionsDraft = this.assistantPreferences.proactiveSuggestions;
    this.confirmBeforeActionsDraft = this.assistantPreferences.confirmBeforeActions;
    if (this.settings.selectedProviderId !== '') { this.selectedProvider = this.settings.selectedProviderId; }
    this.model = this.settings.selectedModelId;
    const selected = this.manifests.find((value: DiagnosticAiProviderManifest): boolean => value.providerId === this.selectedProvider);
    this.endpoint = selected?.endpoint ?? '';
    const selectedProfile = this.profiles.find((value: DiagnosticAiProviderProfile): boolean =>
      value.providerId === this.selectedProvider &&
      (this.settings.selectedAuthMode === '' || value.authMode === this.settings.selectedAuthMode));
    const savedAuthMode: DiagnosticAiAuthMode | undefined = this.settings.selectedAuthMode === '' ? undefined : this.settings.selectedAuthMode;
    this.authModeDraft = selectedProfile?.authMode ?? savedAuthMode ?? selected?.authModes[0] ?? 'api_key';
    if (selectedProfile !== undefined) { this.termsAcceptedDraft = selectedProfile.consentId !== '' && selectedProfile.consentAt > 0; }
    this.configTab = this.tabForSelection();
    this.resumeSessionId = this.initialResumeSessionId.trim();
  }

  private manifestIsLocal(manifest: DiagnosticAiProviderManifest): boolean {
    return manifest.market === 'local' || diagnosticAiProviderIsHarmonyLocal(manifest.providerId);
  }

  private manifestHasCodingPlan(manifest: DiagnosticAiProviderManifest): boolean {
    return manifest.authModes.indexOf('coding_plan_key') >= 0 || manifest.billingMode === 'coding_plan';
  }

  private tabForSelection(): string {
    const manifest: DiagnosticAiProviderManifest | undefined = this.selectedManifest();
    if (manifest !== undefined && this.manifestIsLocal(manifest)) { return 'local'; }
    return this.authModeDraft === 'coding_plan_key' ? 'coding' : 'api';
  }

  /** The providers a tab offers. */
  private tabManifests(tab: string): DiagnosticAiProviderManifest[] {
    return this.manifests.filter((manifest: DiagnosticAiProviderManifest): boolean =>
      tab === 'local' ? this.manifestIsLocal(manifest) :
      tab === 'coding' ? this.manifestHasCodingPlan(manifest) : !this.manifestIsLocal(manifest));
  }

  private profileKind(profile: DiagnosticAiProviderProfile): string {
    const manifest = this.manifests.find((m: DiagnosticAiProviderManifest): boolean => m.providerId === profile.providerId);
    if (manifest !== undefined && this.manifestIsLocal(manifest)) { return '本机'; }
    return profile.authMode === 'coding_plan_key' ? 'Coding Plan' : 'API';
  }

  /** Switch the tab: the tab's saved service if there is one, otherwise its first available provider. */
  private selectConfigTab(tab: string): void {
    if (tab === this.configTab) { return; }
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => { this.configTab = tab; });
    const candidates: DiagnosticAiProviderManifest[] = this.tabManifests(tab);
    const saved: DiagnosticAiProviderProfile | undefined = this.profiles.find((p: DiagnosticAiProviderProfile): boolean =>
      candidates.some((m: DiagnosticAiProviderManifest): boolean => m.providerId === p.providerId) &&
      (tab !== 'coding' || p.authMode === 'coding_plan_key') && (tab !== 'api' || p.authMode !== 'coding_plan_key'));
    const target: DiagnosticAiProviderManifest | undefined = saved !== undefined ?
      candidates.find((m: DiagnosticAiProviderManifest): boolean => m.providerId === saved.providerId) :
      candidates.find((m: DiagnosticAiProviderManifest): boolean => this.providerAvailable(m));
    this.message = '';
    if (target === undefined || (tab === 'coding' && !CODING_PLAN_OPEN)) { return; }
    this.selectProvider(target.providerId);
    if (tab === 'coding') { this.selectAuthMode('coding_plan_key'); }
    else if (tab === 'api' && target.authModes.indexOf('api_key') >= 0) { this.selectAuthMode('api_key'); }
  }

  private allowed(): boolean { return ProEntries.visible(PRO_DIAGNOSTICS_FEATURE, ProAppRuntime.getInstance().context()); }
  private providerAllowed(): boolean { return ProEntries.visible(PRO_DIAGNOSTICS_PROVIDER_FEATURE, ProAppRuntime.getInstance().context()); }
  private assistantAllowed(): boolean {
    return ProEntries.visible(PRO_DIAGNOSTICS_ASSISTANT_FEATURE, ProAppRuntime.getInstance().context());
  }

  private providerAvailable(manifest: DiagnosticAiProviderManifest): boolean {
    if (!diagnosticAiProviderSupportsDevice(manifest, this.deviceType)) { return false; }
    return diagnosticAiProviderIsHarmonyLocal(manifest.providerId) ||
      diagnosticAiProviderNormalApiAvailable(manifest) || diagnosticAiProviderCodingPlanAvailable(manifest);
  }

  private selectedNormalApiAvailable(): boolean {
    const manifest = this.selectedManifest();
    return manifest !== undefined && diagnosticAiProviderNormalApiAvailable(manifest);
  }

  private selectedCodingPlanAvailable(): boolean {
    const manifest = this.selectedManifest();
    return manifest !== undefined && diagnosticAiProviderCodingPlanAvailable(manifest);
  }

  private codingPlanDeclared(): boolean {
    const manifest = this.selectedManifest();
    return manifest !== undefined && (manifest.authModes.indexOf('coding_plan_key') >= 0 || manifest.billingMode === 'coding_plan');
  }

  private selectAuthMode(mode: DiagnosticAiAuthMode): void {
    this.authModeDraft = mode; this.keyText = ''; this.availableModels = [];
    const saved = this.profiles.find((value: DiagnosticAiProviderProfile): boolean =>
      value.providerId === this.selectedProvider && value.authMode === mode);
    this.termsAcceptedDraft = saved !== undefined && saved.consentId !== '' && saved.consentAt > 0;
    this.model = saved?.modelId ?? '';
    if (mode === 'coding_plan_key') { this.endpoint = this.selectedManifest()?.endpoint ?? ''; }
  }

  private selectProvider(id: string): void {
    const manifest = this.manifests.find((value: DiagnosticAiProviderManifest): boolean => value.providerId === id);
    if (manifest !== undefined && diagnosticAiProviderIsHarmonyLocal(id) &&
      !diagnosticAiHarmonyLocalDeviceSupported(this.deviceType)) {
      this.message = '鸿蒙端侧小模型当前仅支持 PC/2in1；手机和 Pad 暂不可用，后续开放后将上线。';
      return;
    }
    this.selectedProvider = id;
    if (manifest !== undefined && !diagnosticAiProviderIsHarmonyLocal(id) &&
      (manifest.endpoint === '' || manifest.chatPath === '')) {
      this.message = '该 Provider 已列入路线图，当前版本尚未开放请求适配';
      return;
    }
    this.endpoint = manifest?.endpoint ?? ''; this.availableModels = []; this.keyText = ''; this.termsAcceptedDraft = false;
    const existing = this.profiles.find((value: DiagnosticAiProviderProfile): boolean => value.providerId === id &&
      (this.settings.selectedAuthMode === '' || value.authMode === this.settings.selectedAuthMode));
    this.authModeDraft = existing?.authMode ?? manifest?.authModes[0] ?? 'api_key';
    if (existing !== undefined) { this.model = existing.modelId; this.termsAcceptedDraft = existing.consentId !== '' && existing.consentAt > 0; }
    if (manifest !== undefined && diagnosticAiProviderIsHarmonyLocal(id)) { this.model = HARMONY_LOCAL_MODEL_ID; }
    else { this.model = ''; }
    this.message = '';
  }

  private async saveProvider(): Promise<void> {
    if (!this.providerAllowed() || this.busy) { return; }
    const manifest = this.manifests.find((value: DiagnosticAiProviderManifest): boolean => value.providerId === this.selectedProvider);
    const localProvider: boolean = manifest !== undefined && diagnosticAiProviderIsHarmonyLocal(manifest.providerId);
    if (manifest === undefined || !this.providerAvailable(manifest) || (!localProvider && (manifest.endpoint === '' || manifest.chatPath === ''))) {
      this.message = '该 Provider 尚未完成请求适配'; return;
    }
    if (this.authModeDraft === 'api_key' && !this.selectedNormalApiAvailable()) {
      this.message = '当前 Provider 未声明可用于诊断助手的普通 API 连接'; return;
    }
    if (this.authModeDraft === 'coding_plan_key' && !CODING_PLAN_OPEN) {
      this.message = '暂不开放 Coding Plan 接入，请在「API Key」中使用按量计费的普通 API'; return;
    }
    if (this.authModeDraft === 'coding_plan_key' && !this.selectedCodingPlanAvailable()) {
      this.message = 'Coding Plan 专用连接尚未完成官方 Manifest 核验，普通 API Key 不会复用到这里'; return;
    }
    if (localProvider && !diagnosticAiHarmonyLocalDeviceSupported(this.deviceType)) {
      this.message = '鸿蒙端侧小模型当前仅支持 PC/2in1；手机和 Pad 暂不可用，后续开放后将上线。'; return;
    }
    if (manifest === undefined || manifest.authModes.indexOf(this.authModeDraft) < 0 || this.authModeDraft === 'unsupported') {
      this.message = '该认证方式未被 Provider Manifest 声明，已阻止保存'; return;
    }
    if (this.authModeDraft === 'oauth_pkce' || this.authModeDraft === 'device_authorization' || this.authModeDraft === 'official_cli_bridge') {
      this.message = '该官方授权方式尚未完成端点核验，暂不能保存'; return;
    }
    if (this.authModeDraft === 'coding_plan_key' &&
      (manifest.billingMode !== 'coding_plan' || manifest.codingPlanModelIds.length === 0 ||
        manifest.allowedUseCases.indexOf('diagnostic_assistant') < 0 || manifest.requiresOfficialTool || manifest.termsVersion === '' ||
        manifest.codingPlanModelIds.indexOf(this.model.trim()) < 0)) {
      this.message = 'Coding Plan 尚未完成诊断助手用途核验，不能保存为可用配置'; return;
    }
    if (this.authModeDraft === 'coding_plan_key' && this.endpoint.trim() !== manifest.endpoint.trim()) {
      this.message = 'Coding Plan 必须使用 Manifest 声明的专用 Base URL'; return;
    }
    if (!localProvider && this.keyText.trim() === '' && !this.selectedHasSecret()) {
      this.message = '请先输入当前认证方式的 Key；不同认证方式不会共用密钥'; return;
    }
    if (!localProvider && !this.termsAcceptedDraft) {
      this.message = '请先确认当前 Provider 条款版本和诊断助手数据用途'; return;
    }
    if (!localProvider) {
      const endpointDecision = validateDiagnosticAiEndpoint(this.endpoint, manifest.adapterFamily, false);
      if (!endpointDecision.ok) { this.message = '保存失败：' + endpointDecision.message; return; }
    }
    this.busy = true; this.message = '';
    const existing = this.profiles.find((value: DiagnosticAiProviderProfile): boolean =>
      value.providerId === manifest.providerId && value.authMode === this.authModeDraft);
    const nextRevision: number = existing === undefined ? 1 : Math.max(1, existing.revision + 1);
    const profile: DiagnosticAiProviderProfile = { id: this.selectedProvider + '-' + this.authModeDraft + '-' + this.owner.slice(-8), owner: this.owner,
      providerId: manifest.providerId, displayName: manifest.displayName, endpoint: localProvider ? '' : this.endpoint.trim(),
      modelId: localProvider ? HARMONY_LOCAL_MODEL_ID : this.model.trim(),
      authKind: manifest.authKind, authHeader: manifest.authHeader, authMode: localProvider ? 'none' : this.authModeDraft,
      billingMode: manifest.billingMode, allowedUseCases: manifest.allowedUseCases.slice(),
      requiresInteractive: manifest.requiresInteractive, requiresOfficialTool: manifest.requiresOfficialTool,
      entitlementEndpoint: manifest.entitlementEndpoint, termsVersion: manifest.termsVersion, dataRegion: manifest.dataRegion,
      authorizationStatus: localProvider || this.keyText.trim() !== '' || this.selectedHasSecret() ? 'connected' : 'unconfigured',
      consentId: localProvider || this.termsAcceptedDraft ? 'diagnostic-assistant:' + manifest.providerId + ':' + manifest.termsVersion : '',
      consentAt: localProvider || this.termsAcceptedDraft ? Date.now() : 0,
      secretRef: '', secretFingerprint: '', manifestVersion: manifest.schemaVersion,
      privacy: { region: manifest.privacy.region, retention: manifest.privacy.retention,
        trainingUse: manifest.privacy.trainingUse, policyRef: manifest.privacy.policyRef },
      showOrbOnHostPage: this.settings.showOrbOnHostPage, revision: nextRevision, updatedAt: Date.now() };
    if (!this.store.saveProfile(profile, this.keyText.trim())) { this.message = '保存失败：请检查 API Key 和 Provider 地址'; }
    else {
      this.settings.selectedProviderId = profile.providerId;
      this.settings.selectedModelId = profile.modelId;
      this.settings.selectedAuthMode = profile.authMode;
      if (!this.store.saveSettings(this.settings)) {
        this.message = 'Provider 已写入，但选择状态持久化失败，请重试保存';
        this.busy = false;
        return;
      }
      const persisted = this.store.list().find((value: DiagnosticAiProviderProfile): boolean => value.id === profile.id);
      const persistedSettings = this.store.settingsSnapshot();
      if (persisted === undefined || persistedSettings.selectedProviderId !== profile.providerId ||
        persistedSettings.selectedModelId !== profile.modelId ||
        (profile.secretFingerprint !== '' && this.store.secret(persisted) === '')) {
        this.message = '配置回读校验失败，请重新保存 API Key 和模型';
        this.busy = false;
        return;
      }
      this.keyText = ''; this.profiles = this.store.list();
      this.message = localProvider ? '鸿蒙端侧小模型配置已保存；点击“检测端侧模型”确认系统模型可用。' :
        this.authModeLabel(this.authModeDraft) + '配置已保存；密钥只保存在本机安全存储。';
    }
    this.busy = false;
  }

  private async fetchModels(): Promise<void> {
    const profile = this.selectedProfileForAuthMode();
    if (profile === undefined || this.busy) { this.message = '请先保存 Provider 配置'; return; }
    this.busy = true; this.message = '正在拉取模型列表…';
    try {
      const models = await this.providerService.listModels(profile, this.store.secret(profile));
      this.availableModels = models;
      if (models.length > 0 && !models.some((value: DiagnosticAiModelInfo): boolean => value.id === this.model)) {
        this.model = models[0].id;
      }
      this.availableModels = models;
      if (this.model !== '' && models.some((value: DiagnosticAiModelInfo): boolean => value.id === this.model)) {
        if (this.persistModelSelection(this.model)) {
          this.message = diagnosticAiProviderIsHarmonyLocal(this.selectedProvider) ?
            '端侧模型已就绪；当前请求将在本机处理。' :
            '已读取并保存 ' + models.length.toString() + ' 个模型；当前模型可直接调用 AI。';
        } else {
          this.message = '模型列表已读取，但选择状态持久化失败，请点击保存配置重试';
        }
      } else {
        this.message = '已读取 ' + models.length.toString() + ' 个模型；请选择模型。';
      }
    } catch (error) { this.message = this.providerErrorText(error as Object); }
    finally { this.busy = false; }
  }

  private async updateModelPricing(): Promise<void> {
    const profile: DiagnosticAiProviderProfile | undefined = this.selectedUsageProvider();
    if (profile === undefined || this.updatingModelPricing || this.busy) {
      this.message = '请先保存 Provider 配置和模型'; return;
    }
    this.updatingModelPricing = true; this.busy = true; this.message = '正在从 Provider 官方模型清单更新模型与价格…';
    try {
      const rows: DiagnosticAiModelPriceEntry[] = await this.providerService.listModelCatalog(profile, this.store.secret(profile));
      const count: number = this.modelCatalog.updateFromProvider(rows);
      this.modelPricing = this.modelCatalog.list();
      this.availableModels = rows.map((item: DiagnosticAiModelPriceEntry): DiagnosticAiModelInfo => ({
        id: item.modelId, displayName: item.displayName, providerId: item.providerId,
        supportsStreaming: this.selectedManifest()?.supportsStreaming ?? false,
        supportsVision: this.selectedManifest()?.supportsVision ?? false,
        supportsTools: this.selectedManifest()?.supportsTools ?? false, fetchedAt: item.updatedAt, stale: false
      }));
      this.message = '已更新 ' + count.toString() + ' 个模型；Provider 未返回单价的项目继续使用本地维护基线，费用仍是估算。';
    } catch (error) {
      this.message = this.providerErrorText(error as Object) + '；本地维护价格表未被覆盖';
    } finally { this.updatingModelPricing = false; this.busy = false; }
  }

  private persistModelSelection(modelId: string): boolean {
    const profile = this.selectedProfileForAuthMode();
    if (profile === undefined || modelId.trim() === '') { return false; }
    profile.modelId = modelId.trim();
    if (!this.store.saveProfile(profile, '')) { return false; }
    const next = this.store.settingsSnapshot();
    next.selectedProviderId = profile.providerId; next.selectedModelId = profile.modelId; next.selectedAuthMode = profile.authMode;
    if (!this.store.saveSettings(next)) { return false; }
    this.settings = next; this.profiles = this.store.list(); return true;
  }

  private selectModel(modelId: string): void {
    this.model = modelId;
    if (this.persistModelSelection(modelId)) {
      this.message = '模型已保存，AI 助手可以直接调用。';
    }
  }

  private saveOrbPreference(value: boolean): void {
    this.settings.showOrbOnHostPage = value; this.store.saveSettings(this.settings);
    AppStorage.setOrCreate('diagnosticAiOrbEnabled', value);
    this.message = value ? '远程主机页 AI 入口已开启' : '远程主机页 AI 入口已关闭';
  }

  private saveReducedMotion(value: boolean): void {
    const next: DiagnosticAiSettings = {
      selectedProviderId: this.settings.selectedProviderId,
      selectedModelId: this.settings.selectedModelId,
      selectedAuthMode: this.settings.selectedAuthMode,
      showOrbOnHostPage: this.settings.showOrbOnHostPage,
      reducedMotion: value,
      retentionDays: this.settings.retentionDays
    };
    if (!this.store.saveSettings(next)) {
      this.message = 'AI 动效偏好保存失败，请稍后重试';
      return;
    }
    this.settings = next;
    AppStorage.setOrCreate('diagnosticAiReducedMotion', value);
    this.message = value ? 'AI 动效已简化' : 'AI 动效已恢复';
  }

  /** Save the assistant preferences right away (after any change) and flash 已保存. */
  private saveAssistantNow(): void {
    this.saveAssistantPreferences();
    if (this.message.indexOf('失败') >= 0) { return; }
    this.message = '';
    this.assistantSavedFlash = true;
    if (this.assistantSavedTimer !== -1) { clearTimeout(this.assistantSavedTimer); }
    this.assistantSavedTimer = setTimeout((): void => { this.assistantSavedFlash = false; this.assistantSavedTimer = -1; }, 1400);
  }

  /** Typing in the memory field saves once the user pauses. */
  private saveMemorySoon(): void {
    if (this.memorySaveTimer !== -1) { clearTimeout(this.memorySaveTimer); }
    this.memorySaveTimer = setTimeout((): void => { this.memorySaveTimer = -1; this.saveAssistantNow(); }, 800);
  }

  private saveAssistantPreferences(): void {
    const next: DiagnosticAiAssistantPreferences = {
      name: this.assistantNameDraft.trim() === '' ? 'RD Assistant' : this.assistantNameDraft.trim().slice(0, 32),
      personality: this.personalityDraft, verbosity: this.verbosityDraft, role: this.roleDraft, language: this.languageDraft,
      memoryEnabled: this.memoryEnabledDraft, memorySummary: this.sessionMemorySummary.slice(0, 4000),
      manualMemorySummary: this.memoryDraft.trim().slice(0, 4000),
      proactiveSuggestions: this.proactiveSuggestionsDraft, confirmBeforeActions: this.confirmBeforeActionsDraft, updatedAt: Date.now()
    };
    if (this.conversationStore.saveAssistantPreferences(next)) {
      this.assistantPreferences = next; this.message = '助手偏好已保存在本机，仅用于后续对话语气和上下文。';
    } else { this.message = '助手偏好保存失败，请稍后重试'; }
  }

  private usageRowKey(row: DiagnosticAiProviderUsage): string { return row.providerId + '\u001f' + row.modelId; }

  /** The provider's own name for an id ("deepseek" → "DeepSeek"), the id itself when unknown. */
  private providerName(providerId: string): string {
    const profile: DiagnosticAiProviderProfile | undefined = this.profiles.find((item: DiagnosticAiProviderProfile): boolean =>
      item.providerId === providerId);
    if (profile !== undefined && profile.displayName !== '') { return profile.displayName; }
    const manifest = diagnosticAiProviderManifest(providerId);
    return manifest !== null ? manifest.displayName : providerId;
  }

  /** The days of the chosen range (empty for 全部, which uses the running totals). */
  private rangeDays(): string[] {
    if (this.usageRange === 'all') { return []; }
    const count: number = this.usageRange === 'today' ? 1 : this.usageRange === '7d' ? 7 : 30;
    const days: string[] = [];
    for (let i: number = 0; i < count; i++) { days.push(diagnosticAiUsageDay(Date.now() - i * 24 * 3600 * 1000)); }
    return days;
  }

  /** Requests, failures, tokens and cost of the range, for one subscription key or (empty key) all of them. */
  private usageFor(key: string): AiUsageView {
    const view: AiUsageView = new AiUsageView();
    if (this.usageRange === 'all') {
      if (key === '') {
        view.requests = this.usageSnapshot.requestCount; view.failed = this.usageSnapshot.failedCount ?? 0;
        view.prompt = this.usageSnapshot.promptTokens; view.completion = this.usageSnapshot.completionTokens;
        view.cached = this.usageSnapshot.cachedTokens; view.cost = this.usageSnapshot.estimatedCostCny;
        return view;
      }
      const row: DiagnosticAiProviderUsage | undefined = this.usageSnapshot.providerUsage.find(
        (item: DiagnosticAiProviderUsage): boolean => this.usageRowKey(item) === key);
      if (row !== undefined) {
        view.requests = row.requestCount; view.failed = row.failedCount ?? 0; view.prompt = row.promptTokens;
        view.completion = row.completionTokens; view.cached = row.cachedTokens; view.cost = row.estimatedCostCny;
      }
      return view;
    }
    const days: string[] = this.rangeDays();
    (this.usageSnapshot.daily ?? []).filter((d: DiagnosticAiDailyUsage): boolean => days.indexOf(d.day) >= 0)
      .forEach((d: DiagnosticAiDailyUsage): void => {
        if (key === '') {
          view.requests += d.requestCount; view.failed += d.failedCount; view.prompt += d.promptTokens;
          view.completion += d.completionTokens; view.cached += d.cachedTokens; view.cost += d.estimatedCostCny;
          return;
        }
        d.providers.filter((p: DiagnosticAiDailyProviderUsage): boolean => p.key === key)
          .forEach((p: DiagnosticAiDailyProviderUsage): void => {
            view.requests += p.requestCount; view.failed += p.failedCount; view.prompt += p.promptTokens;
            view.completion += p.completionTokens; view.cached += p.cachedTokens; view.cost += p.estimatedCostCny;
          });
      });
    return view;
  }

  private currentUsage(): AiUsageView { return this.usageFor(this.usageProviderFilter); }

  /** Every subscription with use in the range, biggest first. */
  private usageRows(): AiUsageRow[] {
    return this.usageSnapshot.providerUsage.map((row: DiagnosticAiProviderUsage): AiUsageRow =>
      new AiUsageRow(this.usageRowKey(row), this.providerName(row.providerId), row.modelId === '' ? '未知模型' : row.modelId,
        this.usageFor(this.usageRowKey(row))))
      .filter((row: AiUsageRow): boolean => row.view.requests + row.view.failed > 0)
      .sort((a: AiUsageRow, b: AiUsageRow): number =>
        (b.view.prompt + b.view.completion) - (a.view.prompt + a.view.completion));
  }

  /** The last 14 days as bars of tokens (the filter applies). */
  private usageBars(): AiUsageBar[] {
    const bars: AiUsageBar[] = [];
    for (let i: number = 13; i >= 0; i--) {
      const time: number = Date.now() - i * 24 * 3600 * 1000;
      const day: string = diagnosticAiUsageDay(time);
      const row: DiagnosticAiDailyUsage | undefined = (this.usageSnapshot.daily ?? []).find(
        (d: DiagnosticAiDailyUsage): boolean => d.day === day);
      let tokens: number = 0;
      if (row !== undefined) {
        if (this.usageProviderFilter === '') { tokens = row.promptTokens + row.completionTokens; }
        else {
          row.providers.filter((p: DiagnosticAiDailyProviderUsage): boolean => p.key === this.usageProviderFilter)
            .forEach((p: DiagnosticAiDailyProviderUsage): void => { tokens += p.promptTokens + p.completionTokens; });
        }
      }
      bars.push(new AiUsageBar(day, i === 0 ? '今天' : (new Date(time).getDate()).toString(), tokens, i === 0));
    }
    return bars;
  }

  private maxBar(): number {
    return Math.max(1, ...this.usageBars().map((bar: AiUsageBar): number => bar.tokens));
  }

  private tokenText(value: number): string {
    if (value >= 1000000) { return (value / 1000000).toFixed(2) + 'M'; }
    if (value >= 10000) { return (value / 1000).toFixed(1) + 'K'; }
    return Math.round(value).toString();
  }

  private moneyText(value: number): string {
    return value <= 0 ? '¥0' : value < 0.01 ? '¥' + value.toFixed(4) : '¥' + value.toFixed(2);
  }

  private rangeLabel(): string {
    return this.usageRange === 'today' ? '今天' : this.usageRange === '7d' ? '近 7 天' : this.usageRange === '30d' ? '近 30 天' : '全部';
  }

  /** Whether a subscription's price is known (otherwise its cost is a rough default estimate). */
  private priceKnown(key: string): boolean {
    const parts: string[] = key.split('\u001f');
    const price: DiagnosticAiModelPriceEntry | undefined = this.modelPricing.find((p: DiagnosticAiModelPriceEntry): boolean =>
      p.providerId === parts[0] && p.modelId === (parts.length > 1 ? parts[1] : ''));
    return price !== undefined && price.inputCnyPerMillion >= 0 && price.outputCnyPerMillion >= 0;
  }

  /** Ask before anything that deletes or clears; `run` happens only after the danger button. */
  private confirmDanger(title: string, message: string, action: string, run: () => void): void {
    this.getUIContext().getPromptAction().showDialog({
      title: title,
      message: message,
      buttons: [{ text: '取消', color: this.pal().text2 }, { text: action, color: this.pal().danger }]
    }).then((result): void => {
      if (result.index === 1) { run(); }
    }).catch((): void => {});
  }

  private confirmClearUsage(): void {
    this.confirmDanger('清空用量统计？', '所有服务的 Token 和费用统计会清零，对话记录不受影响。', '清空',
      (): void => { this.clearUsage(); });
  }

  private clearUsage(): void {
    if (this.conversationStore.clearUsage()) {
      this.usageSnapshot = this.conversationStore.usage();
      this.usageProviderFilter = '';
      this.message = '用量统计已清空';
    }
  }

  /** Saved conversations matching the search, grouped by when they were last used. */
  private sessionGroups(): AiSessionGroup[] {
    const query: string = this.sessionQuery.trim().toLowerCase();
    const matches: DiagnosticAiConversationSession[] = this.kindSessions().filter((session: DiagnosticAiConversationSession): boolean =>
      query === '' || session.title.toLowerCase().indexOf(query) >= 0 ||
        session.turns.some((turn): boolean => turn.question.toLowerCase().indexOf(query) >= 0 ||
          turn.answer.toLowerCase().indexOf(query) >= 0));
    const startOfToday: number = new Date(new Date().toDateString()).getTime();
    const day: number = 24 * 3600 * 1000;
    const groups: AiSessionGroup[] = [new AiSessionGroup('今天', []), new AiSessionGroup('昨天', []),
      new AiSessionGroup('近 7 天', []), new AiSessionGroup('更早', [])];
    matches.forEach((session: DiagnosticAiConversationSession): void => {
      const index: number = session.updatedAt >= startOfToday ? 0 : session.updatedAt >= startOfToday - day ? 1 :
        session.updatedAt >= startOfToday - 6 * day ? 2 : 3;
      groups[index].sessions.push(session);
    });
    return groups.filter((group: AiSessionGroup): boolean => group.sessions.length > 0);
  }

  private kindSessions(): DiagnosticAiConversationSession[] {
    return this.sessions.filter((session: DiagnosticAiConversationSession): boolean =>
      diagnosticAiSessionKind(session) === this.sessionKind);
  }

  private sessionDocumentCount(session: DiagnosticAiConversationSession): number {
    return session.turns.reduce((sum: number, turn: DiagnosticAiConversationTurn): number => sum + (turn.documents ?? []).length, 0);
  }

  private sessionTime(session: DiagnosticAiConversationSession): string {
    const date: Date = new Date(session.updatedAt);
    const pad = (value: number): string => (value < 10 ? '0' : '') + value.toString();
    const startOfToday: number = new Date(new Date().toDateString()).getTime();
    return session.updatedAt >= startOfToday ? pad(date.getHours()) + ':' + pad(date.getMinutes()) :
      (date.getMonth() + 1).toString() + '月' + date.getDate().toString() + '日';
  }

  private sessionPreview(session: DiagnosticAiConversationSession): string {
    const last = session.turns.length > 0 ? session.turns[session.turns.length - 1] : undefined;
    return last === undefined ? '' : last.answer.replace(/\s+/g, ' ').trim();
  }

  private openSession(session: DiagnosticAiConversationSession): void {
    const profile: DiagnosticAiProviderProfile | undefined = this.profiles.find((item: DiagnosticAiProviderProfile): boolean =>
      item.providerId === session.providerId && item.modelId === session.modelId);
    if (profile !== undefined) { this.useProviderForNewRequests(profile); }
    this.onOpenSession(session.id);
  }

  private deleteSession(session: DiagnosticAiConversationSession): void {
    if (this.conversationStore.deleteSession(session.id)) {
      this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => {
        this.sessions = this.conversationStore.listSessions();
      });
    }
  }

  private confirmDeleteSession(session: DiagnosticAiConversationSession): void {
    this.confirmDanger('删除这个对话？', '「' + session.title + '」会从对话记录中删除，无法恢复。', '删除',
      (): void => { this.deleteSession(session); });
  }

  private confirmClearSessions(): void {
    const count: number = this.kindSessions().length;
    this.confirmDanger(this.sessionKind === 'chat' ? '清空全部聊天记录？' : '清空全部助理对话？',
      '会删除这里的 ' + count.toString() + ' 个对话，无法恢复。', '清空', (): void => { this.clearSessions(); });
  }

  private clearSessions(): void {
    if (this.conversationStore.clearSessions(this.sessionKind === 'chat' ? 'chat' : 'assistant')) {
      this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => {
        this.sessions = this.conversationStore.listSessions();
      });
    }
  }

  private priceText(value: number): string { return value < 0 ? '待确认' : '¥' + value.toFixed(2); }

  private selectedUsageProvider(): DiagnosticAiProviderProfile | undefined {
    const selected: DiagnosticAiProviderProfile | undefined = this.profiles.find((item: DiagnosticAiProviderProfile): boolean =>
      item.providerId === this.settings.selectedProviderId && item.modelId === this.settings.selectedModelId &&
      (this.settings.selectedAuthMode === '' || item.authMode === this.settings.selectedAuthMode));
    if (selected !== undefined) { return selected; }
    const candidates: DiagnosticAiProviderProfile[] = this.profiles.filter((item: DiagnosticAiProviderProfile): boolean => item.modelId !== '');
    return candidates.length === 1 ? candidates[0] : undefined;
  }

  private useProviderForNewRequests(profile: DiagnosticAiProviderProfile): void {
    const next: DiagnosticAiSettings = {
      selectedProviderId: profile.providerId, selectedModelId: profile.modelId,
      selectedAuthMode: profile.authMode,
      showOrbOnHostPage: true, reducedMotion: this.settings.reducedMotion, retentionDays: this.settings.retentionDays
    };
    if (this.store.saveSettings(next)) {
      this.settings = next; this.selectedProvider = profile.providerId; this.model = profile.modelId;
      this.usageProviderFilter = profile.providerId + '\u001f' + profile.modelId;
      this.message = '已切换当前 AI 订阅：' + profile.displayName + ' / ' + profile.modelId;
    } else { this.message = '切换当前 AI 订阅失败，请重试'; }
  }

  private selectedManifest(): DiagnosticAiProviderManifest | undefined {
    return this.manifests.find((value: DiagnosticAiProviderManifest): boolean => value.providerId === this.selectedProvider);
  }
  private selectedProviderSupported(): boolean {
    const manifest = this.selectedManifest();
    return manifest !== undefined && this.providerAvailable(manifest);
  }
  private savedProfile(): DiagnosticAiProviderProfile | undefined {
    const selected: DiagnosticAiProviderProfile | undefined = this.profiles.find((value: DiagnosticAiProviderProfile): boolean =>
      value.providerId === this.settings.selectedProviderId &&
      (this.settings.selectedAuthMode === '' || value.authMode === this.settings.selectedAuthMode));
    if (selected !== undefined) { return selected; }
    return this.profiles.length === 1 ? this.profiles[0] : undefined;
  }
  /** The selected provider already has a stored key, so an empty field keeps it (saveProfile reuses the same ref). */
  private selectedHasSecret(): boolean {
    return this.profiles.some((value: DiagnosticAiProviderProfile): boolean =>
      value.providerId === this.selectedProvider && value.authMode === this.authModeDraft && value.secretFingerprint !== '');
  }

  private revokeProfile(profile: DiagnosticAiProviderProfile): void {
    if (this.busy || !this.store.removeProfile(profile.id)) {
      this.message = '删除/撤销 Provider 配置失败，请稍后重试'; return;
    }
    this.profiles = this.store.list();
    if (this.settings.selectedProviderId === profile.providerId &&
      (this.settings.selectedAuthMode === '' || this.settings.selectedAuthMode === profile.authMode)) {
      const next = this.store.settingsSnapshot();
      next.selectedProviderId = ''; next.selectedModelId = ''; next.selectedAuthMode = '';
      this.store.saveSettings(next); this.settings = next; this.model = ''; this.authModeDraft = 'api_key';
    }
    this.keyText = ''; this.termsAcceptedDraft = false; this.message = '已删除本机 Provider 配置并撤销其密钥';
  }
  private providerTag(manifest: DiagnosticAiProviderManifest): string {
    if (diagnosticAiProviderIsHarmonyLocal(manifest.providerId) && !this.providerAvailable(manifest)) {
      return '仅 PC/2in1';
    }
    if (!this.providerAvailable(manifest)) { return '后续适配'; }
    return diagnosticAiProviderIsHarmonyLocal(manifest.providerId) ? '端侧' : manifest.market === 'local' ? '本机' : '大陆';
  }
  /** Messages that report a failure are tinted; everything else reads as information. */
  private messageIsError(): boolean {
    return this.message.indexOf('失败') >= 0 || this.message.indexOf('请先') >= 0 || this.message.indexOf('尚未') >= 0;
  }
  private providerErrorText(error: Object): string {
    const value = error instanceof Error ? error.message : '';
    if (value.indexOf('LOCAL_MODEL_PC_ONLY') >= 0) {
      return '鸿蒙端侧小模型当前仅支持 PC/2in1；手机和 Pad 暂不可用，后续开放后将上线。';
    }
    if (value.indexOf('LOCAL_MODEL') >= 0) {
      return '端侧模型暂不可用，请确认当前是 PC/2in1，并稍后重新检测。';
    }
    return value === '' ? '模型列表读取失败' : value;
  }
  private headerTitle(): string {
    if (this.section === 1) { return '启动 AI 辅助'; }
    if (this.section === 3) { return 'AI 用量监控'; }
    if (this.section === 4) { return 'AI 个性化设置'; }
    if (this.section === 5) { return 'AI 对话记录'; }
    if (this.section === 6) { return 'AI 动效'; }
    if (this.section === 7) { return 'AI 工具与技能'; }
    if (this.section === 8) { return 'AI 语音'; }
    return '辅助 AI 配置';
  }
  private headerDetail(): string {
    if (this.section === 1) { return '询问应用、协助设置、诊断问题并生成反馈草稿'; }
    if (this.section === 3) { return '按时间和订阅查看请求、Token、缓存命中和费用'; }
    if (this.section === 4) { return '名称、语气和仅保存在本机的助手记忆'; }
    if (this.section === 5) { return '搜索、继续或删除历史对话'; }
    if (this.section === 6) { return '思考动画、悬浮球、完成动画和展开方式'; }
    if (this.section === 7) { return '聊天可用的工具、已安装的技能和技能库'; }
    if (this.section === 8) { return 'Beta · 语音模式、按住说话和朗读引擎'; }
    return '选择 Provider、模型和数据外发策略';
  }

  @Builder private header() {
    Row({ space: 12 }) {
      Column() {
        SymbolGlyph(this.section === 1 ? $r('sys.symbol.performance') : this.section === 6 ? $r('sys.symbol.wand_and_stars') :
          this.section === 7 ? $r('sys.symbol.puzzle_fill') : this.section === 8 ? $r('sys.symbol.mic_fill_waves_left_and_right') :
          $r('sys.symbol.gearshape_fill'))
          .fontSize(20).fontColor([Color.White])
      }
      .width(40).height(40).borderRadius(13).justifyContent(FlexAlign.Center)
      .linearGradient({ angle: 135, colors: [['#2BB673', 0], ['#00A3A3', 1]] })
      Column({ space: 2 }) {
        Text(this.headerTitle()).fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          .fontFamily(AppConfig.fontFamily)
        Text(this.headerDetail()).fontSize(12).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2]).padding(8)
        .accessibilityText('关闭').onClick((): void => { this.onClose(); })
    }.width('100%').margin({ bottom: 14 })
  }

  @Builder private sectionLabel(text: string) {
    Text(text).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text2).width('100%')
      .margin({ top: 6 })
  }

  @Builder private statusCard() {
    Row({ space: 12 }) {
      Column() {
        SymbolGlyph(this.savedProfile() !== undefined ? $r('sys.symbol.checkmark_shield') : $r('sys.symbol.info_circle_fill'))
          .fontSize(22).fontColor([this.savedProfile() !== undefined ? '#2BB673' : this.pal().text3])
      }.width(44).height(44).borderRadius(14).justifyContent(FlexAlign.Center).backgroundColor(this.pal().surface)
      Column({ space: 3 }) {
        Text(this.savedProfile() === undefined ? '尚未配置 AI 服务' :
          (this.savedProfile() as DiagnosticAiProviderProfile).displayName)
          .fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        Text(this.savedProfile() === undefined ? '选择下方的服务商，填写密钥并选择模型' :
          ((this.savedProfile() as DiagnosticAiProviderProfile).modelId === '' ? '尚未选择模型' :
            '模型 ' + (this.savedProfile() as DiagnosticAiProviderProfile).modelId) + ' · ' +
            diagnosticAiPrivacySummary(this.savedProfile() as DiagnosticAiProviderProfile))
          .fontSize(12).fontColor(this.pal().text2).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text(this.savedProfile() === undefined ? '未配置' : '已配置').fontSize(11)
        .fontColor(this.savedProfile() === undefined ? this.pal().text3 : '#2BB673')
        .padding({ left: 8, right: 8, top: 3, bottom: 3 }).borderRadius(9)
        .backgroundColor(this.savedProfile() === undefined ? this.pal().surface : '#1A2BB673')
    }
    .width('100%').padding(14).borderRadius(18).backgroundColor(this.pal().card)
    .border({ width: 0.5, color: this.pal().cardBorder })
  }

  @Builder private providerCard(manifest: DiagnosticAiProviderManifest) {
    Column({ space: 6 }) {
      Row() {
        Text(manifest.displayName).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        if (this.selectedProvider === manifest.providerId) {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(16).fontColor([this.accent])
        }
      }.width('100%')
      Text(this.providerTag(manifest)).fontSize(11)
        .fontColor(this.providerAvailable(manifest) ? this.accent : this.pal().text3)
    }
    .alignItems(HorizontalAlign.Start)
    .width(this.breakpoint === 'sm' ? '47%' : '31%').padding(12).margin({ right: 8, bottom: 8 }).borderRadius(14)
    .backgroundColor(this.selectedProvider === manifest.providerId ? this.pal().surface : this.pal().card)
    .border({ width: this.selectedProvider === manifest.providerId ? 1.5 : 0.5,
      color: this.selectedProvider === manifest.providerId ? this.accent : this.pal().cardBorder })
    .opacity(this.providerAvailable(manifest) ? 1 : 0.55)
    .onClick((): void => {
      if (diagnosticAiProviderIsHarmonyLocal(manifest.providerId) && !this.providerAvailable(manifest)) {
        this.message = '鸿蒙端侧小模型当前仅支持 PC/2in1；手机和 Pad 暂不可用，后续开放后将上线。';
      } else if (this.providerAvailable(manifest)) {
        this.selectProvider(manifest.providerId);
      }
    })
  }

  @Builder private field(label: string, hint: string) {
    Column({ space: 2 }) {
      Text(label).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
      if (hint.length > 0) { Text(hint).fontSize(11).fontColor(this.pal().text3) }
    }.alignItems(HorizontalAlign.Start).width('100%')
  }

  @Builder private authModeChip(mode: DiagnosticAiAuthMode) {
    Text(this.authModeLabel(mode)).fontSize(12)
      .fontColor(this.authModeDraft === mode ? appUiOnAccentText(this.accent) : this.pal().text)
      .padding({ left: 10, right: 10, top: 7, bottom: 7 }).margin({ right: 7, bottom: 6 }).borderRadius(14)
      .backgroundColor(this.authModeDraft === mode ? this.accent : this.pal().surface)
      .onClick((): void => { this.selectAuthMode(mode); })
  }

  /** 用量监控 — time range first, then the subscription filter; every figure below follows both. */
  @Builder private usageRangeBar() {
    AiSegmented({ options: USAGE_RANGES, current: this.usageRange, trackColor: this.pal().surface, thumbColor: this.pal().card, textColor: this.pal().text, mutedColor: this.pal().text3,
      onPick: (id: string): void => {
        this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => { this.usageRange = id; });
      } })
  }

  @Builder private usageFilterChip(key: string, label: string) {
    Text(label).fontSize(12).fontWeight(FontWeight.Medium)
      .fontColor(this.usageProviderFilter === key ? appUiOnAccentText(this.accent) : this.pal().text2)
      .height(30).padding({ left: 12, right: 12 }).borderRadius(15)
      .backgroundColor(this.usageProviderFilter === key ? this.accent : this.pal().surface)
      .onClick((): void => {
        this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => { this.usageProviderFilter = key; });
      })
  }

  @Builder private usageChart() {
    Column({ space: 10 }) {
      Row() {
        Text('每日 Token').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text).layoutWeight(1)
        Text('近 14 天').fontSize(11).fontColor(this.pal().text3)
      }.width('100%')
      Row({ space: 4 }) {
        ForEach(this.usageBars(), (bar: AiUsageBar, index: number): void => {
          Column({ space: 4 }) {
            Blank()
            Row().width('70%').height(Math.max(3, bar.tokens / this.maxBar() * 86)).borderRadius(3)
              .backgroundColor(bar.today ? this.accent : bar.tokens > 0 ? '#66' + this.accent.slice(1) : this.pal().surface)
            Text(bar.today || index % 3 === 1 ? bar.label : ' ').fontSize(9)
              .fontColor(bar.today ? this.accent : this.pal().text3).maxLines(1)
          }.layoutWeight(1).height(112).alignItems(HorizontalAlign.Center)
        }, (bar: AiUsageBar): string => 'bar-' + bar.day + '-' + bar.tokens.toString())
      }.width('100%')
    }.width('100%').padding(14).borderRadius(18).backgroundColor(this.pal().card)
    .border({ width: 0.5, color: this.pal().cardBorder })
  }

  @Builder private usageRowView(row: AiUsageRow, total: number) {
    Row({ space: 12 }) {
      Text(row.name.charAt(0).toUpperCase()).fontSize(15).fontWeight(FontWeight.Bold).fontColor(Color.White)
        .width(36).height(36).textAlign(TextAlign.Center).borderRadius(18)
        .backgroundColor(USAGE_AVATAR_COLORS[Math.abs(row.key.length * 7 + row.name.charCodeAt(0)) % USAGE_AVATAR_COLORS.length])
      Column({ space: 4 }) {
        Row() {
          Text(row.name).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text).layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.moneyText(row.view.cost)).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        }.width('100%')
        Text(row.model + ' · ' + row.view.requests.toString() + ' 次' +
          (row.view.failed > 0 ? ' · 失败 ' + row.view.failed.toString() : '') + ' · ' +
          this.tokenText(row.view.prompt + row.view.completion) + ' Token' + (this.priceKnown(row.key) ? '' : ' · 价格待确认'))
          .fontSize(11).fontColor(this.pal().text3).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Stack({ alignContent: Alignment.Start }) {
          Row().width('100%').height(4).borderRadius(2).backgroundColor(this.pal().surface)
          Row().width((total > 0 ? Math.min(1, (row.view.prompt + row.view.completion) / total) * 100 : 0).toFixed(0) + '%')
            .height(4).borderRadius(2).backgroundColor(this.accent)
        }.width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').padding({ top: 10, bottom: 10 })
    .onClick((): void => {
      this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => {
        this.usageProviderFilter = this.usageProviderFilter === row.key ? '' : row.key;
      });
    })
  }

  @Builder private usageAndHistorySection() {
    Column({ space: 12 }) {
      this.usageRangeBar()
      if (this.usageSnapshot.providerUsage.length > 1) {
        Scroll() {
          Row({ space: 8 }) {
            this.usageFilterChip('', '全部订阅')
            ForEach(this.usageSnapshot.providerUsage, (row: DiagnosticAiProviderUsage): void => {
              this.usageFilterChip(this.usageRowKey(row), this.providerName(row.providerId) + ' · ' +
                (row.modelId === '' ? '未知模型' : row.modelId))
            }, (row: DiagnosticAiProviderUsage): string => 'chip-' + this.usageRowKey(row))
          }
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
      }
      // The headline: what the range cost, with its requests, tokens and failures.
      Column({ space: 6 }) {
        Text(this.rangeLabel() + ' · 估算费用').fontSize(12).fontColor(this.pal().text3)
        Text(this.moneyText(this.currentUsage().cost)).fontSize(34).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        Row({ space: 14 }) {
          Text(this.currentUsage().requests.toString() + ' 次请求').fontSize(13).fontColor(this.pal().text2)
          Text(this.tokenText(this.currentUsage().prompt + this.currentUsage().completion) + ' Token').fontSize(13)
            .fontColor(this.pal().text2)
          if (this.currentUsage().failed > 0) {
            Text(this.currentUsage().failed.toString() + ' 次失败').fontSize(13).fontColor('#FF453A')
          }
        }
        if ((this.usageSnapshot.chatRequestCount ?? 0) > 0 && this.usageProviderFilter === '') {
          Text('累计其中聊天模式 ' + (this.usageSnapshot.chatRequestCount ?? 0).toString() + ' 次 · ' +
            this.tokenText(this.usageSnapshot.chatTokens ?? 0) + ' Token · ' + this.moneyText(this.usageSnapshot.chatCostCny ?? 0))
            .fontSize(12).fontColor(this.pal().text3)
        }
      }.width('100%').alignItems(HorizontalAlign.Start).padding(18).borderRadius(22)
      .backgroundColor(this.pal().card).border({ width: 0.5, color: this.pal().cardBorder })
      Row({ space: 10 }) {
        AiUsageTile({ label: '请求', value: this.currentUsage().requests.toString(),
          detail: this.currentUsage().failed > 0 ? '失败 ' + this.currentUsage().failed.toString() + ' 次' : '全部成功',
          ratio: -1, cardColor: this.pal().card, edgeColor: this.pal().cardBorder, textColor: this.pal().text,
          mutedColor: this.pal().text3, trackColor: this.pal().surface }).layoutWeight(1)
        AiUsageTile({ label: 'Token', value: this.tokenText(this.currentUsage().prompt + this.currentUsage().completion),
          detail: '输入 ' + this.tokenText(this.currentUsage().prompt) + ' · 输出 ' + this.tokenText(this.currentUsage().completion),
          ratio: -1, cardColor: this.pal().card, edgeColor: this.pal().cardBorder, textColor: this.pal().text,
          mutedColor: this.pal().text3, trackColor: this.pal().surface }).layoutWeight(1)
      }.width('100%')
      Row({ space: 10 }) {
        AiUsageTile({ label: '缓存命中', value: this.currentUsage().prompt > 0 ?
          Math.round(this.currentUsage().cached / this.currentUsage().prompt * 100).toString() + '%' : '—',
          detail: '命中 ' + this.tokenText(this.currentUsage().cached) + ' Token',
          ratio: this.currentUsage().prompt > 0 ? this.currentUsage().cached / this.currentUsage().prompt : 0, cardColor: this.pal().card, edgeColor: this.pal().cardBorder, textColor: this.pal().text,
          mutedColor: this.pal().text3, trackColor: this.pal().surface }).layoutWeight(1)
        AiUsageTile({ label: '平均每次', value: this.currentUsage().requests > 0 ?
          this.tokenText((this.currentUsage().prompt + this.currentUsage().completion) / this.currentUsage().requests) : '—',
          detail: this.currentUsage().requests > 0 ? '约 ' + this.moneyText(this.currentUsage().cost / this.currentUsage().requests) + ' / 次' : '还没有请求',
          ratio: -1, cardColor: this.pal().card, edgeColor: this.pal().cardBorder, textColor: this.pal().text,
          mutedColor: this.pal().text3, trackColor: this.pal().surface }).layoutWeight(1)
      }.width('100%')
      if (this.usageRange !== 'today') {
        this.usageChart()
      }
      if (this.usageRows().length > 0) {
        Column() {
          Text('各订阅用量').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
            .margin({ bottom: 2 })
          ForEach(this.usageRows(), (row: AiUsageRow): void => {
            this.usageRowView(row, this.usageRows().reduce((sum: number, r: AiUsageRow): number =>
              sum + r.view.prompt + r.view.completion, 0))
          }, (row: AiUsageRow): string => 'usage-' + row.key + '-' + this.usageRange + '-' + row.view.requests.toString())
        }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 4 }).borderRadius(18)
        .backgroundColor(this.pal().card).border({ width: 0.5, color: this.pal().cardBorder })
      }
      // Which subscription new requests use (switchable when there are several).
      Column({ space: 8 }) {
        Text('新请求使用的订阅').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
        if (this.profiles.length === 0) {
          Text('尚未配置可用的 AI 订阅').fontSize(12).fontColor(this.pal().text3).width('100%')
        }
        ForEach(this.profiles, (profile: DiagnosticAiProviderProfile): void => {
          Row({ space: 10 }) {
            SymbolGlyph(profile.providerId === this.settings.selectedProviderId && profile.modelId === this.settings.selectedModelId ?
              $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle')).fontSize(18)
              .fontColor([profile.providerId === this.settings.selectedProviderId && profile.modelId === this.settings.selectedModelId ?
                this.accent : this.pal().text3])
            Column({ space: 2 }) {
              Text(profile.displayName).fontSize(14).fontColor(this.pal().text)
              Text(profile.modelId === '' ? '未选择模型' : profile.modelId).fontSize(11).fontColor(this.pal().text3)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          }.width('100%').padding({ top: 6, bottom: 6 }).onClick((): void => { this.useProviderForNewRequests(profile); })
        }, (profile: DiagnosticAiProviderProfile): string => 'usage-provider-' + profile.id)
      }.width('100%').padding(14).borderRadius(18).backgroundColor(this.pal().card)
      .border({ width: 0.5, color: this.pal().cardBorder })
      // Model prices: folded away unless asked for.
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Text('模型与价格表').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text).layoutWeight(1)
          SymbolGlyph($r(this.pricingExpanded ? 'sys.symbol.chevron_up' : 'sys.symbol.chevron_down')).fontSize(16)
            .fontColor([this.pal().text3])
        }.width('100%').onClick((): void => {
          this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => {
            this.pricingExpanded = !this.pricingExpanded;
          });
        })
        if (this.pricingExpanded) {
          Row({ space: 8 }) {
            Text('本地保留完整基线；保存 Provider 后可从其官方模型清单刷新').fontSize(11).fontColor(this.pal().text3).layoutWeight(1)
            Button(this.updatingModelPricing ? '更新中…' : '联网更新').height(32).fontSize(12)
              .padding({ left: 12, right: 12 }).borderRadius(16).backgroundColor(this.pal().surface).fontColor(this.accent)
              .enabled(!this.updatingModelPricing && !this.busy && this.selectedUsageProvider() !== undefined)
              .onClick((): void => { void this.updateModelPricing(); })
          }.width('100%')
          ForEach(this.modelPricing, (row: DiagnosticAiModelPriceEntry): void => {
            Row({ space: 8 }) {
              Column({ space: 2 }) {
                Text(this.providerName(row.providerId) + ' · ' + row.displayName).fontSize(12).fontColor(this.pal().text)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text('输入 ' + this.priceText(row.inputCnyPerMillion) + ' · 输出 ' + this.priceText(row.outputCnyPerMillion) +
                  ' · 缓存 ' + this.priceText(row.cachedInputCnyPerMillion) + '（元/百万 Token）').fontSize(10).fontColor(this.pal().text3)
                  .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Text(row.sourceKind === 'provider' ? '在线' : '维护').fontSize(10)
                .fontColor(row.sourceKind === 'provider' ? '#2BB673' : this.pal().text3)
            }.width('100%').padding({ top: 5, bottom: 5 })
          }, (row: DiagnosticAiModelPriceEntry): string => 'price-' + row.providerId + '-' + row.modelId)
        }
      }.width('100%').padding(14).borderRadius(18).backgroundColor(this.pal().card)
      .border({ width: 0.5, color: this.pal().cardBorder })
      Text(((this.usageSnapshot.estimatedCount ?? 0) > 0 ? (this.usageSnapshot.estimatedCount ?? 0).toString() +
        ' 次请求的服务没有返回用量，Token 为本机按实际发送内容估算。' : '') +
        '费用按模型价格表估算，不是服务商账单；价格待确认的模型按 ¥0.30/百万 Token 粗估。统计只保存在本机当前账号下。')
        .fontSize(11).lineHeight(16).fontColor(this.pal().text3).width('100%')
      Text('清空用量统计').fontSize(13).fontColor('#FF453A')
        .padding({ top: 4, bottom: 8 }).onClick((): void => { this.confirmClearUsage(); })
    }.width('100%')
  }

  @Builder private sessionGroupHeader(title: string) {
    Text(title).fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.pal().text3).width('100%')
      .padding({ left: 4, top: 10, bottom: 6 }).backgroundColor(this.pal().sheetBg)
  }

  @Builder private sessionDeleteButton(session: DiagnosticAiConversationSession) {
    Stack() {
      SymbolGlyph($r('sys.symbol.trash_fill')).fontSize(20).fontColor([Color.White])
    }.width(64).height('100%').borderRadius(18).backgroundColor('#FF453A').margin({ left: 8 })
    .onClick((): void => { this.deleteSession(session); })
  }

  @Builder private sessionCard(session: DiagnosticAiConversationSession) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(session.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text).layoutWeight(1)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.sessionTime(session)).fontSize(11).fontColor(this.pal().text3)
      }.width('100%')
      if (this.sessionPreview(session) !== '') {
        Text(this.sessionPreview(session)).fontSize(13).lineHeight(19).fontColor(this.pal().text2).width('100%')
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      Row({ space: 6 }) {
        Text(session.turns.length.toString() + ' 轮').fontSize(11).fontColor(this.pal().text2)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 }).borderRadius(8).backgroundColor(this.pal().surface)
        if (this.sessionDocumentCount(session) > 0) {
          Text(this.sessionDocumentCount(session).toString() + ' 个文档').fontSize(11).fontColor(this.pal().text2)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 }).borderRadius(8).backgroundColor(this.pal().surface)
        }
        if (session.modelId !== '') {
          Text(session.modelId).fontSize(11).fontColor(this.pal().text2).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 180 })
            .padding({ left: 8, right: 8, top: 2, bottom: 2 }).borderRadius(8).backgroundColor(this.pal().surface)
        }
        Blank()
        // Visible delete for PC and Pad mice; swiping left still deletes at once.
        SymbolGlyph($r('sys.symbol.trash')).fontSize(16).fontColor([this.pal().text3])
          .padding(6).margin({ right: 6 }).accessibilityText('删除对话')
          .onClick((): void => { this.confirmDeleteSession(session); })
        Text('继续').fontSize(12).fontColor(this.accent)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([this.accent])
      }.width('100%')
    }.width('100%').padding(14).borderRadius(18).backgroundColor(this.pal().card)
    .border({ width: 0.5, color: this.pal().cardBorder })
    .onClick((): void => { this.openSession(session); })
  }

  /** 对话记录: search, grouped by date, swipe left to delete, tap to continue on the same subscription. */
  @Builder private sessionManagementSection() {
    Column({ space: 10 }) {
      AiSegmented({ options: [['assistant', '助理'], ['chat', '聊天']], current: this.sessionKind, trackColor: this.pal().surface, thumbColor: this.pal().card, textColor: this.pal().text, mutedColor: this.pal().text3,
        onPick: (id: string): void => {
          this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, (): void => {
            this.sessionKind = id;
          });
        } })
      Search({ value: this.sessionQuery, placeholder: '搜索对话内容' })
        .height(40).width('100%').borderRadius(20)
        .onChange((value: string): void => { this.sessionQuery = value; })
      if (this.kindSessions().length === 0) {
        Column({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.ellipsis_bubble')).fontSize(40).fontColor([this.pal().text3])
          Text(this.sessionKind === 'chat' ? '还没有聊天记录' : '还没有助理对话').fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text)
          Text(this.sessionKind === 'chat' ? '在 AI 灵动岛里切到「聊天」，聊天和生成的文档会保存在这里，可以随时继续。' :
            '向 AI 助理提问应用的用法、设置或问题后，对话会自动保存在这里，可以随时继续。').fontSize(13).lineHeight(19)
            .fontColor(this.pal().text3).textAlign(TextAlign.Center)
        }.width('100%').padding({ top: 48, bottom: 48 })
      } else {
        Row() {
          Text('共 ' + this.kindSessions().length.toString() + ' 个对话').fontSize(12).fontColor(this.pal().text3)
            .layoutWeight(1)
          Text('清空全部').fontSize(12).fontColor('#FF453A')
            .onClick((): void => { this.confirmClearSessions(); })
        }.width('100%')
        if (this.sessionGroups().length === 0) {
          Text('没有找到匹配的对话').fontSize(13).fontColor(this.pal().text3).width('100%').textAlign(TextAlign.Center)
            .padding({ top: 24 })
        }
        List({ space: 8 }) {
          ForEach(this.sessionGroups(), (group: AiSessionGroup): void => {
            ListItemGroup({ header: this.sessionGroupHeader(group.title), space: 8 }) {
              ForEach(group.sessions, (session: DiagnosticAiConversationSession): void => {
                ListItem() { this.sessionCard(session) }
                  .swipeAction({ end: { builder: (): void => { this.sessionDeleteButton(session); } },
                    edgeEffect: SwipeEdgeEffect.Spring })
              }, (session: DiagnosticAiConversationSession): string => 'session-' + session.id + '-' + session.updatedAt.toString())
            }
          }, (group: AiSessionGroup): string => 'group-' + group.title + '-' + group.sessions.length.toString())
        }.layoutWeight(1).width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).sticky(StickyStyle.Header)
      }
    }.layoutWeight(1).width('100%')
  }

  @Builder private prefToggle(title: string, detail: string, isOn: boolean, onChange: (value: boolean) => void) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        Text(detail).fontSize(11).lineHeight(15).fontColor(this.pal().text3)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: isOn }).selectedColor(this.accent)
        .onChange((value: boolean): void => { onChange(value); })
    }.width('100%').padding({ top: 4, bottom: 4 })
  }

  @Builder private prefCard(title: string) {
    Text(title).fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.pal().text3).width('100%')
      .padding({ left: 4, top: 4 })
  }

  /** AI 个性化: every change applies and saves at once; the preview shows how answers will read. */
  @Builder private assistantCustomizationSection() {
    Column({ space: 10 }) {
      Row() {
        Text('改动会立即生效并保存在本机').fontSize(12).fontColor(this.pal().text3).layoutWeight(1)
        if (this.assistantSavedFlash) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(14).fontColor(['#34C759'])
            Text('已保存').fontSize(12).fontColor('#34C759')
          }.transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
        }
      }.width('100%').padding({ left: 4, right: 4 })
      // Preview: the assistant's name and a sample answer in the current style and length.
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Text((this.assistantNameDraft.trim() === '' ? 'R' : this.assistantNameDraft.trim().charAt(0)).toUpperCase())
            .fontSize(16).fontWeight(FontWeight.Bold).fontColor(appUiOnAccentText(this.accent)).width(36).height(36)
            .textAlign(TextAlign.Center).borderRadius(18).backgroundColor(this.accent)
          TextInput({ placeholder: '助手名称', text: this.assistantNameDraft }).height(38).fontSize(15).layoutWeight(1)
            .fontWeight(FontWeight.Medium).backgroundColor(this.pal().surface).borderRadius(12).maxLength(32)
            .onChange((value: string): void => { this.assistantNameDraft = value; })
            .onSubmit((): void => { this.saveAssistantNow(); })
            .onBlur((): void => { this.saveAssistantNow(); })
        }.width('100%')
        Text('“RDP 连不上怎么办？”').fontSize(12).fontColor(this.pal().text3).width('100%')
        Text(aiPreviewAnswer(this.personalityDraft, this.verbosityDraft)).fontSize(13).lineHeight(19).fontColor(this.pal().text)
          .width('100%').padding(12).borderRadius(16).backgroundColor(this.pal().surface)
          .animation({ duration: 220, curve: Curve.EaseOut })
      }.width('100%').padding(14).borderRadius(18).backgroundColor(this.pal().card)
      .border({ width: 0.5, color: this.pal().cardBorder })

      this.prefCard('回答')
      Column({ space: 10 }) {
        Text('风格').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
        AiSegmented({ options: [['balanced', '均衡'], ['warm', '温和'], ['concise', '简洁'], ['technical', '技术']],
          current: this.personalityDraft, trackColor: this.pal().surface, thumbColor: this.pal().card, textColor: this.pal().text, mutedColor: this.pal().text3,
          onPick: (id: string): void => {
            this.personalityDraft = id as 'balanced' | 'warm' | 'concise' | 'technical'; this.saveAssistantNow();
          } })
        Text(aiPersonalityNote(this.personalityDraft)).fontSize(11).fontColor(this.pal().text3).width('100%')
        Text('长度').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%').margin({ top: 4 })
        AiSegmented({ options: [['concise', '简短'], ['standard', '标准'], ['detailed', '详细']], current: this.verbosityDraft,
          trackColor: this.pal().surface, thumbColor: this.pal().card, textColor: this.pal().text, mutedColor: this.pal().text3,
          onPick: (id: string): void => { this.verbosityDraft = id as 'concise' | 'standard' | 'detailed'; this.saveAssistantNow(); } })
        Text(aiVerbosityNote(this.verbosityDraft)).fontSize(11).fontColor(this.pal().text3).width('100%')
        Text('语言').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%').margin({ top: 4 })
        AiSegmented({ options: [['zh-CN', '简体中文'], ['en-US', 'English']], current: this.languageDraft, trackColor: this.pal().surface, thumbColor: this.pal().card, textColor: this.pal().text, mutedColor: this.pal().text3,
          onPick: (id: string): void => { this.languageDraft = id as 'zh-CN' | 'en-US'; this.saveAssistantNow(); } })
      }.width('100%').padding(14).borderRadius(18).backgroundColor(this.pal().card)
      .border({ width: 0.5, color: this.pal().cardBorder })

      this.prefCard('角色')
      Column() {
        ForEach(DIAGNOSTIC_AI_ROLE_CHOICES, (item: DiagnosticAiChoice, index: number): void => {
          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text(item.label).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
              Text(aiRoleNote(item.id)).fontSize(11).fontColor(this.pal().text3)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            SymbolGlyph($r(this.roleDraft === item.id ? 'sys.symbol.checkmark_circle_fill' : 'sys.symbol.circle'))
              .fontSize(20).fontColor([this.roleDraft === item.id ? this.accent : this.pal().text3])
          }.width('100%').padding({ top: 10, bottom: 10 })
          .border({ width: { bottom: index < DIAGNOSTIC_AI_ROLE_CHOICES.length - 1 ? 0.5 : 0 }, color: this.pal().divider })
          .onClick((): void => {
            this.roleDraft = item.id as 'remote-expert' | 'beginner-guide' | 'diagnostic-first' | 'privacy-first';
            this.saveAssistantNow();
          })
        }, (item: DiagnosticAiChoice): string => 'role-' + item.id)
      }.width('100%').padding({ left: 14, right: 14, top: 2, bottom: 2 }).borderRadius(18).backgroundColor(this.pal().card)
      .border({ width: 0.5, color: this.pal().cardBorder })

      this.prefCard('行为')
      Column({ space: 4 }) {
        this.prefToggle('主动建议', '在回答下面显示可以直接点的下一步操作', this.proactiveSuggestionsDraft,
          (value: boolean): void => { this.proactiveSuggestionsDraft = value; this.saveAssistantNow(); })
        this.prefToggle('敏感操作先确认', '断开连接、传输文件、涉及隐私或凭据的操作先问你，建议保持开启',
          this.confirmBeforeActionsDraft, (value: boolean): void => { this.confirmBeforeActionsDraft = value; this.saveAssistantNow(); })
        this.prefToggle('减少 AI 动效', '关闭持续旋转和弹簧转场，只保留状态变化', this.settings.reducedMotion,
          (value: boolean): void => { this.saveReducedMotion(value); })
      }.width('100%').padding({ left: 14, right: 14, top: 8, bottom: 8 }).borderRadius(18).backgroundColor(this.pal().card)
      .border({ width: 0.5, color: this.pal().cardBorder })

      this.prefCard('记忆')
      Column({ space: 10 }) {
        this.prefToggle('允许本地记忆', '最近对话的摘要和你补充的偏好会附在后续提问里，只保存在本机', this.memoryEnabledDraft,
          (value: boolean): void => { this.memoryEnabledDraft = value; this.saveAssistantNow(); })
        if (this.memoryEnabledDraft) {
          Text('你希望 AI 记住的偏好').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
          TextArea({ placeholder: '例如：我主要用 RDP 连公司电脑，回答请先给最短的操作路径。', text: this.memoryDraft })
            .height(84).fontSize(13).backgroundColor(this.pal().surface).borderRadius(12).maxLength(4000)
            .onChange((value: string): void => { this.memoryDraft = value; this.saveMemorySoon(); })
          Row() {
            Text('自动生成的对话摘要').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text).layoutWeight(1)
            if (this.sessionMemorySummary !== '') {
              Text(this.memoryExpanded ? '收起' : '查看').fontSize(12).fontColor(this.accent)
                .onClick((): void => { this.memoryExpanded = !this.memoryExpanded; })
            }
          }.width('100%')
          Text(this.sessionMemorySummary === '' ? '完成几次问答后，这里会出现最近对话的本机摘要。' : this.sessionMemorySummary)
            .fontSize(11).lineHeight(16).fontColor(this.pal().text3).width('100%').maxLines(this.memoryExpanded ? 40 : 3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.memoryDraft.trim() !== '') {
            Text('清除我补充的偏好').fontSize(13).fontColor('#FF453A')
              .onClick((): void => {
                this.confirmDanger('清除你补充的偏好？', 'AI 不再记住这段偏好，自动生成的对话摘要不受影响。', '清除',
                  (): void => { this.memoryDraft = ''; this.saveAssistantNow(); });
              })
          }
        }
      }.width('100%').padding(14).borderRadius(18).backgroundColor(this.pal().card)
      .border({ width: 0.5, color: this.pal().cardBorder })
    }.width('100%')
  }

  @Builder private configTabs() {
    AiSegmented({ options: CONFIG_TABS, current: this.configTab, segmentHeight: 34, trackColor: this.pal().surface, thumbColor: this.pal().card, textColor: this.pal().text, mutedColor: this.pal().text3,
      onPick: (id: string): void => { this.selectConfigTab(id); } })
  }

  @Builder private configTabIntro() {
    Text(this.configTab === 'api' ? '按量计费的普通 API：在服务商控制台创建 API Key，按实际用量付费。' :
      this.configTab === 'coding' ? 'Coding Plan 是面向编程工具的包月套餐，使用独立的 Key 和专用地址；普通 API 与 Coding Plan 分开保存，互不复用。' :
      '模型运行在本机或局域网内的电脑上，不需要 API Key，数据不出设备。')
      .fontSize(12).lineHeight(17).fontColor(this.pal().text3).width('100%').padding({ left: 4, right: 4 })
  }

  /** API key / local connection fields for the selected provider (Coding Plan only when one is verified). */
  @Builder private connectionFields() {
    if (diagnosticAiProviderIsHarmonyLocal(this.selectedProvider)) {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.lock_shield_fill')).fontSize(22).fontColor([this.accent])
        Column({ space: 2 }) {
          Text('鸿蒙端侧小模型').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          Text(this.selectedProviderSupported() ? '由系统管理，不需要地址、Key 或模型 ID' : '当前设备不可用：手机和 Pad 暂未开放')
            .fontSize(12).fontColor(this.pal().text3)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      Button(this.busy ? '检测中…' : '检测端侧模型').height(42).fontSize(13).borderRadius(21).width('100%')
        .backgroundColor(this.pal().surface).fontColor(this.accent)
        .enabled(!this.busy && this.selectedProviderSupported())
        .onClick((): void => { void this.fetchModels(); })
    } else {
      if (this.configTab === 'api' && this.extraAuthModesForSelected().length > 0) {
        this.field('授权方式', '')
        Flex({ wrap: FlexWrap.Wrap }) {
          this.authModeChip('api_key')
          ForEach(this.extraAuthModesForSelected(), (mode: DiagnosticAiAuthMode): void => { this.authModeChip(mode) },
            (mode: DiagnosticAiAuthMode): string => 'auth-mode-' + mode)
        }.width('100%')
      }
      this.field(this.authModeDraft === 'coding_plan_key' ? 'Coding Plan 专用地址' : '服务地址',
        this.authModeDraft === 'coding_plan_key' ? '只使用服务商声明的专用地址' :
          this.configTab === 'local' ? '本机或局域网内运行模型的地址' : '默认是官方地址，也可改为兼容的 HTTPS 地址')
      TextInput({ placeholder: 'https://', text: this.endpoint }).height(44).fontSize(14)
        .backgroundColor(this.pal().surface).borderRadius(12)
        .enabled(this.authModeDraft !== 'coding_plan_key')
        .onChange((value: string): void => { this.endpoint = value; })
      if (this.authModeDraft !== 'none') {
        this.field(this.authModeDraft === 'coding_plan_key' ? 'Coding Plan Key' : 'API Key',
          '只保存在本机安全存储，不会同步、导出或写入日志')
        TextInput({ placeholder: this.selectedHasSecret() ? '已保存，留空则保持不变' :
          (this.authModeDraft === 'coding_plan_key' ? '粘贴 Coding Plan 专用 Key' : '粘贴 API Key'), text: this.keyText })
          .height(44).fontSize(14).type(InputType.Password).backgroundColor(this.pal().surface).borderRadius(12)
          .onChange((value: string): void => { this.keyText = value; })
        Row({ space: 8 }) {
          Checkbox().select(this.termsAcceptedDraft).selectedColor(this.accent)
            .onChange((value: boolean): void => { this.termsAcceptedDraft = value; })
          Text('我已了解服务商条款（版本 ' + (this.selectedManifest()?.termsVersion ?? '待核验') +
            '）以及诊断助手的用途和数据处理地区。')
            .fontSize(11).lineHeight(16).fontColor(this.pal().text3).layoutWeight(1)
        }.width('100%')
      }
      this.field('模型', '保存后点「拉取模型」可从服务商读取可用模型')
      Row({ space: 8 }) {
        TextInput({ placeholder: '模型 ID', text: this.model }).height(44).fontSize(14).layoutWeight(1)
          .backgroundColor(this.pal().surface).borderRadius(12)
          .onChange((value: string): void => { this.model = value; })
        Button(this.busy ? '…' : '拉取模型').height(44).fontSize(13).padding({ left: 14, right: 14 }).borderRadius(12)
          .backgroundColor(this.pal().surface).fontColor(this.accent).enabled(!this.busy)
          .onClick((): void => { void this.fetchModels(); })
      }.width('100%')
    }
    if (this.availableModels.length > 0) {
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.availableModels, (item: DiagnosticAiModelInfo): void => {
          Text(item.displayName.length > 0 ? item.displayName : item.id).fontSize(12).maxLines(1)
            .fontColor(this.model === item.id ? appUiOnAccentText(this.accent) : this.pal().text)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 }).margin({ right: 6, bottom: 6 }).borderRadius(10)
            .backgroundColor(this.model === item.id ? this.accent : this.pal().surface)
            .onClick((): void => { this.selectModel(item.id); })
        }, (item: DiagnosticAiModelInfo): string => item.id)
      }.width('100%')
    }
  }

  /** Coding Plan is closed for now; the tab explains why and points to API Key. */
  @Builder private codingPlanUnavailable() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.lock_fill')).fontSize(18).fontColor([this.pal().text3])
        Column({ space: 2 }) {
          Text('暂不开放 Coding Plan 接入').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          Text('Coding Plan 专用连接待官方核验').fontSize(12).fontColor(this.pal().text3)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      Text('各家 Coding Plan 多数只允许在指定的编程工具里使用，并且要走专用地址；在 AI 助理里调用可能违反套餐条款，甚至导致 Key 被停用。在服务商明确允许之前，这里不接入 Coding Plan，也不会把普通 API Key 当作 Coding Plan 使用。')
        .fontSize(12).lineHeight(18).fontColor(this.pal().text3).width('100%')
      Button('改用 API Key').height(40).fontSize(13).borderRadius(20).width('100%')
        .backgroundColor(this.pal().surface).fontColor(this.accent)
        .onClick((): void => { this.selectConfigTab('api'); })
    }.width('100%').padding(14).borderRadius(18).backgroundColor(this.pal().card)
    .border({ width: 0.5, color: this.pal().cardBorder })
  }

  /** 辅助 AI 配置: API Key, Coding Plan and on-device models kept apart, each with its own providers and fields. */
  @Builder private configSection() {
    Scroll() {
      Column({ space: 12 }) {
        this.statusCard()
        this.configTabs()
        this.configTabIntro()
        if (this.configTab === 'coding' && (!CODING_PLAN_OPEN || !this.tabManifests('coding').some(
          (m: DiagnosticAiProviderManifest): boolean => this.providerAvailable(m)))) {
          this.codingPlanUnavailable()
        } else {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.tabManifests(this.configTab), (manifest: DiagnosticAiProviderManifest): void => {
              this.providerCard(manifest)
            }, (manifest: DiagnosticAiProviderManifest): string => this.configTab + '-' + manifest.providerId)
          }.width('100%')
          Column({ space: 10 }) {
            this.connectionFields()
          }.width('100%').padding(14).borderRadius(18).backgroundColor(this.pal().card)
          .border({ width: 0.5, color: this.pal().cardBorder })
        }
        if (this.profiles.length > 0) {
          Text('已保存的服务').fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.pal().text3).width('100%')
            .padding({ left: 4, top: 4 })
          Column() {
            ForEach(this.profiles, (profile: DiagnosticAiProviderProfile, index: number): void => {
              Row({ space: 10 }) {
                Column({ space: 3 }) {
                  Row({ space: 6 }) {
                    Text(profile.displayName).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
                    Text(this.profileKind(profile)).fontSize(10).fontColor(this.accent)
                      .padding({ left: 6, right: 6, top: 1, bottom: 1 }).borderRadius(6).backgroundColor(this.pal().surface)
                    if (profile.providerId === this.settings.selectedProviderId && profile.modelId === this.settings.selectedModelId) {
                      Text('使用中').fontSize(10).fontColor('#2BB673')
                    }
                  }
                  Text(profile.modelId === '' ? '尚未选择模型' : profile.modelId).fontSize(11).fontColor(this.pal().text3)
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                Text('编辑').fontSize(12).fontColor(this.accent).padding(6)
                  .onClick((): void => {
                    this.selectedProvider = profile.providerId; this.authModeDraft = profile.authMode;
                    this.termsAcceptedDraft = profile.consentId !== '' && profile.consentAt > 0;
                    this.model = profile.modelId; this.endpoint = profile.endpoint; this.availableModels = [];
                    this.configTab = this.tabForSelection();
                  })
                Text('删除').fontSize(12).fontColor(this.pal().danger).padding(6)
                  .onClick((): void => {
                    this.confirmDanger('删除「' + profile.displayName + '」？',
                      '会删除本机保存的这项服务配置和它的 API Key，之后需要重新填写。', '删除',
                      (): void => { this.revokeProfile(profile); });
                  })
              }.width('100%').padding({ top: 10, bottom: 10 })
              .border({ width: { bottom: index < this.profiles.length - 1 ? 0.5 : 0 }, color: this.pal().divider })
            }, (profile: DiagnosticAiProviderProfile): string => profile.id + profile.modelId)
          }.width('100%').padding({ left: 14, right: 14 }).borderRadius(18).backgroundColor(this.pal().card)
          .border({ width: 0.5, color: this.pal().cardBorder })
        }
      }.width('100%').padding({ bottom: 12 })
    }.layoutWeight(1).width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
    if (this.message.length > 0) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.info_circle_fill')).fontSize(15)
          .fontColor([this.messageIsError() ? '#F08C00' : this.accent])
        Text(this.message).fontSize(12).lineHeight(17).fontColor(this.pal().text).layoutWeight(1)
      }
      .width('100%').padding(10).borderRadius(12).margin({ top: 8 })
      .backgroundColor(this.messageIsError() ? '#1AF08C00' : this.pal().surface)
    }
    if (!(this.configTab === 'coding' && !this.tabManifests('coding').some(
      (m: DiagnosticAiProviderManifest): boolean => this.providerAvailable(m)))) {
      Button(this.busy ? '处理中…' : '保存并使用').width('100%').height(48).fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(appUiOnAccentText(this.accent)).backgroundColor(this.accent).borderRadius(24).margin({ top: 10 })
        .enabled(!this.busy).onClick((): void => { void this.saveProvider(); })
    }
  }

  @Builder private lockedCard() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.lock_fill')).fontSize(30).fontColor([this.pal().text3])
      Text('需要有效的 Pro 权益').fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
      Text('传统日志抓取不受影响，可在「设置 → AI 助理 → 传统日志抓取」中使用。')
        .fontSize(13).lineHeight(19).fontColor(this.pal().text2).textAlign(TextAlign.Center)
    }.width('100%').padding(28).borderRadius(18).backgroundColor(this.pal().card)
  }

  @Builder private usageSection() {
    Scroll() {
      Column({ space: 10 }) { this.usageAndHistorySection() }.width('100%').padding({ bottom: 12 })
    }.layoutWeight(1).width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
  }

  @Builder private personalizationSection() {
    Scroll() {
      Column({ space: 10 }) { this.assistantCustomizationSection() }.width('100%').padding({ bottom: 12 })
    }.layoutWeight(1).width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
  }

  build() {
    Column() {
        this.header()
        if ((this.section === 1 || this.section === 3 || this.section === 4 || this.section === 5 || this.section === 6 ||
          this.section === 7 || this.section === 8) ?
          !this.assistantAllowed() : !this.providerAllowed()) {
          this.lockedCard()
        } else if (this.section === 1) {
          DiagnosticAiAssistantPanel({
            embedded: true,
            resumeSessionId: this.resumeSessionId,
            onAppAction: (action: DiagnosticAiAppActionId): void => { this.onAppAction(action); },
            onClose: (): void => { this.onClose(); }
          }).layoutWeight(1)
        } else if (this.section === 3) {
          this.usageSection()
        } else if (this.section === 4) {
          this.personalizationSection()
        } else if (this.section === 5) {
          this.sessionManagementSection()
        } else if (this.section === 6) {
          AiMotionSettingsPanel()
        } else if (this.section === 7) {
          AiSkillsSettingsPanel({ owner: this.owner })
        } else if (this.section === 8) {
          Scroll() {
            AiVoiceSettingsPanel({ owner: this.owner })
          }.layoutWeight(1).width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
        } else {
          this.configSection()
        }
      }.width('100%').height('100%').padding({ left: 20, right: 20, top: 18, bottom: 28 })
        .backgroundColor(this.pal().sheetBg)
  }
}

/** One usage figure (a component, so it redraws when the range or subscription filter changes). */
@Component
struct AiUsageTile {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop detail: string = '';
  /** 0…1 draws a bar under the value; negative: no bar. */
  @Prop ratio: number = -1;
  @Prop cardColor: string = '#FFFFFF';
  @Prop edgeColor: string = '#14000000';
  @Prop textColor: string = '#000000';
  @Prop mutedColor: string = '#8E8E93';
  @Prop trackColor: string = '#F2F2F7';

  build() {
    Column({ space: 4 }) {
      Text(this.label).fontSize(12).fontColor(this.mutedColor)
      Text(this.value).fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.textColor)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.ratio >= 0) {
        Stack({ alignContent: Alignment.Start }) {
          Row().width('100%').height(4).borderRadius(2).backgroundColor(this.trackColor)
          Row().width((Math.min(1, this.ratio) * 100).toFixed(0) + '%').height(4).borderRadius(2).backgroundColor('#34C759')
            .animation({ duration: 300, curve: Curve.EaseOut })
        }.width('100%').margin({ top: 2 })
      }
      Text(this.detail).fontSize(11).fontColor(this.mutedColor).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width('100%').alignItems(HorizontalAlign.Start).padding(14).borderRadius(18)
    .backgroundColor(this.cardColor).border({ width: 0.5, color: this.edgeColor })
  }
}
