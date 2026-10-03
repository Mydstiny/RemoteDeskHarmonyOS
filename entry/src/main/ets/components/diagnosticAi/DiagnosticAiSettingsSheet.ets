import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { AppConfig, Palette, buildDark, buildLight } from '../../common/Theme';
import { AppSettingsActionRow } from '../AppSettingsActionRow';
import { AppUiMetrics } from '../../common/AppUiMetrics';
import { DiagnosticAiAssistantPanel } from './DiagnosticAiAssistantPanel';
import { DiagnosticAiAuthMode, DiagnosticAiModelInfo, DiagnosticAiModelPriceEntry, DiagnosticAiProviderManifest, DiagnosticAiProviderProfile, DiagnosticAiSettings } from '../../services/diagnosticAi/DiagnosticAiModels';
import { diagnosticAiHarmonyLocalDeviceSupported, diagnosticAiProviderCodingPlanAvailable, diagnosticAiProviderIsHarmonyLocal, diagnosticAiProviderManifests, diagnosticAiProviderNormalApiAvailable, diagnosticAiProviderSupportsDevice, HARMONY_LOCAL_MODEL_ID } from '../../services/diagnosticAi/DiagnosticAiProviderCatalog';
import { validateDiagnosticAiEndpoint } from '../../services/diagnosticAi/DiagnosticAiEndpointPolicy';
import { DiagnosticAiProfileStore } from '../../services/diagnosticAi/DiagnosticAiProfileStore';
import { DiagnosticAiProviderService, diagnosticAiPrivacySummary } from '../../services/diagnosticAi/DiagnosticAiProviderService';
import { DiagnosticAiModelCatalog } from '../../services/diagnosticAi/DiagnosticAiModelCatalog';
import { AccountSessionCoordinator } from '../../services/AccountSessionCoordinator';
import { ProAppRuntime } from '../../services/pro/ProAppRuntime';
import { ProEntries } from '../../services/pro/ProEntries';
import { PRO_DIAGNOSTICS_ASSISTANT_FEATURE, PRO_DIAGNOSTICS_FEATURE, PRO_DIAGNOSTICS_PROVIDER_FEATURE } from '../../services/pro/ProFeatureCatalog';
import { DiagnosticAiAssistantPreferences, DiagnosticAiConversationSession, DiagnosticAiConversationStore, DiagnosticAiProviderUsage, DiagnosticAiUsageSnapshot, defaultDiagnosticAiAssistantPreferences } from '../../services/diagnosticAi/DiagnosticAiConversationStore';
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

@Component
export struct DiagnosticAiSettingsSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @StorageProp('breakpoint') breakpoint: string = 'md';
  onClose: () => void = (): void => {};
  onOpenMailDraft: (subject: string, body: string) => void = (_subject: string, _body: string): void => {};
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
    this.resumeSessionId = this.initialResumeSessionId.trim();
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

  private costText(): string {
    const row: DiagnosticAiProviderUsage | undefined = this.usageProviderFilter === '' ? undefined :
      this.usageSnapshot.providerUsage.find((item: DiagnosticAiProviderUsage): boolean => this.usageRowKey(item) === this.usageProviderFilter);
    return '¥' + (row === undefined ? this.usageSnapshot.estimatedCostCny : row.estimatedCostCny).toFixed(4);
  }
  private cacheHitText(): string {
    const row: DiagnosticAiProviderUsage | undefined = this.usageProviderFilter === '' ? undefined :
      this.usageSnapshot.providerUsage.find((item: DiagnosticAiProviderUsage): boolean => this.usageRowKey(item) === this.usageProviderFilter);
    const prompt: number = row === undefined ? this.usageSnapshot.promptTokens : row.promptTokens;
    const cached: number = row === undefined ? this.usageSnapshot.cachedTokens : row.cachedTokens;
    if (prompt <= 0) { return '0%'; }
    return Math.round(cached / prompt * 100).toString() + '%';
  }

  private usageRowKey(row: DiagnosticAiProviderUsage): string { return row.providerId + '\u001f' + row.modelId; }

  private priceText(value: number): string { return value < 0 ? '待确认' : '¥' + value.toFixed(2); }

  private usageFilterText(): string {
    if (this.usageProviderFilter === '') { return '全部订阅'; }
    const row: DiagnosticAiProviderUsage | undefined = this.usageSnapshot.providerUsage.find((item: DiagnosticAiProviderUsage): boolean =>
      this.usageRowKey(item) === this.usageProviderFilter);
    return row === undefined ? '当前订阅筛选' : '当前筛选：' + row.providerId + ' · ' + (row.modelId === '' ? '未知模型' : row.modelId);
  }

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
    if (this.section === 5) { return 'AI 会话管理'; }
    return '辅助 AI 配置';
  }
  private headerDetail(): string {
    if (this.section === 1) { return '询问应用、协助设置、诊断问题并生成反馈草稿'; }
    if (this.section === 3) { return '按订阅查看 Token、缓存命中和费用估算'; }
    if (this.section === 4) { return '名称、语气和仅保存在本机的助手记忆'; }
    if (this.section === 5) { return '查看历史对话并在原 Provider 上继续交流'; }
    return '选择 Provider、模型和数据外发策略';
  }

  @Builder private header() {
    Row({ space: 12 }) {
      Column() {
        SymbolGlyph(this.section === 1 ? $r('sys.symbol.performance') : $r('sys.symbol.gearshape_fill'))
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
      .fontColor(this.authModeDraft === mode ? Color.White : this.pal().text)
      .padding({ left: 10, right: 10, top: 7, bottom: 7 }).margin({ right: 7, bottom: 6 }).borderRadius(14)
      .backgroundColor(this.authModeDraft === mode ? this.accent : this.pal().surface)
      .onClick((): void => { this.selectAuthMode(mode); })
  }

  @Builder private authModeSection() {
    if (!diagnosticAiProviderIsHarmonyLocal(this.selectedProvider)) {
      Text('普通 API 连接').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
      if (this.selectedNormalApiAvailable()) {
        Row({ space: 8 }) {
          Text('API Key · 独立按量/Token Plan').fontSize(12)
            .fontColor(this.authModeDraft === 'api_key' ? Color.White : this.pal().text).layoutWeight(1)
          if (this.authModeDraft === 'api_key') { SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(16).fontColor([Color.White]) }
        }.width('100%').padding(10).borderRadius(12)
          .backgroundColor(this.authModeDraft === 'api_key' ? this.accent : this.pal().surface)
          .onClick((): void => { this.selectAuthMode('api_key'); })
      } else {
        Text('当前 Provider 未声明可用于诊断助手的普通 API 连接').fontSize(11).fontColor(this.pal().text3).width('100%')
      }
      Text('Coding Plan 专用连接').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text).margin({ top: 6 })
      if (this.selectedCodingPlanAvailable()) {
        Row({ space: 8 }) {
          Text('Coding Plan Key · 独立密钥、独立模型白名单').fontSize(12)
            .fontColor(this.authModeDraft === 'coding_plan_key' ? Color.White : this.pal().text).layoutWeight(1)
          if (this.authModeDraft === 'coding_plan_key') { SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(16).fontColor([Color.White]) }
        }.width('100%').padding(10).borderRadius(12)
          .backgroundColor(this.authModeDraft === 'coding_plan_key' ? this.accent : this.pal().surface)
          .onClick((): void => { this.selectAuthMode('coding_plan_key'); })
      } else {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.lock_fill')).fontSize(16).fontColor([this.pal().text3])
          Text(this.codingPlanDeclared() ? 'Coding Plan 已声明但等待官方用途/端点核验' :
            'Coding Plan 专用连接待官方核验；不会把普通 API Key 当作 Coding Plan')
            .fontSize(11).lineHeight(16).fontColor(this.pal().text3).layoutWeight(1)
        }.width('100%').padding(10).borderRadius(12).backgroundColor(this.pal().surface).opacity(0.7)
      }
      if (this.extraAuthModesForSelected().length > 0) {
        Text('官方授权方式').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text).margin({ top: 6 })
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.extraAuthModesForSelected(), (mode: DiagnosticAiAuthMode): void => { this.authModeChip(mode) },
            (mode: DiagnosticAiAuthMode): string => 'auth-mode-' + mode)
        }.width('100%')
      }
      Text(this.authModeDraft === 'coding_plan_key'
        ? 'Coding Plan Key 只可发送到 Manifest 声明的专用 Base URL，并且模型必须在官方白名单内。'
        : '普通 API 与 Coding Plan 分开保存；RemoteDesktop 不接收账户密码、Cookie 或网页 Session。')
        .fontSize(11).lineHeight(16).fontColor(this.pal().text3).width('100%')
    } else {
      Text('连接方式：本机/端侧模型').fontSize(11).fontColor(this.pal().text3).width('100%')
    }
  }

  @Builder private usageAndHistorySection() {
    this.sectionLabel('用量与本地会话')
    Column({ space: 10 }) {
      Text('当前 AI 订阅').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
      if (this.selectedUsageProvider() !== undefined) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.checkmark_shield_fill')).fontSize(18).fontColor([this.accent])
          Column({ space: 2 }) {
            Text((this.selectedUsageProvider() as DiagnosticAiProviderProfile).displayName).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
            Text('模型：' + (this.selectedUsageProvider() as DiagnosticAiProviderProfile).modelId + ' · 新请求使用此订阅').fontSize(11).fontColor(this.pal().text3)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%').padding(10).borderRadius(14).backgroundColor(this.pal().surface)
      } else {
        Text('尚未配置可用的 AI 订阅').fontSize(12).fontColor(this.pal().text3).width('100%')
      }
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text('模型与价格维护表').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          Text('本地保留完整基线；保存 Provider 后可从其官方 /models 清单刷新').fontSize(11).fontColor(this.pal().text3)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button(this.updatingModelPricing ? '更新中…' : '联网更新模型与价格').height(36).fontSize(11)
          .padding({ left: 10, right: 10 }).borderRadius(18).backgroundColor(this.pal().surface).fontColor(this.accent)
          .enabled(!this.updatingModelPricing && !this.busy && this.selectedUsageProvider() !== undefined)
          .onClick((): void => { void this.updateModelPricing(); })
      }.width('100%').padding(10).borderRadius(14).backgroundColor(this.pal().surface)
      if (this.modelPricing.length > 0) {
        Text('维护价格表（元 / 百万 Token）').fontSize(12).fontColor(this.pal().text2).width('100%')
        ForEach(this.modelPricing, (row: DiagnosticAiModelPriceEntry): void => {
          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Text(row.providerId + ' · ' + row.displayName).fontSize(12).fontColor(this.pal().text)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(row.modelId + ' · 输入 ' + this.priceText(row.inputCnyPerMillion) + ' · 输出 ' + this.priceText(row.outputCnyPerMillion) +
                ' · 缓存 ' + this.priceText(row.cachedInputCnyPerMillion)).fontSize(10).fontColor(this.pal().text3)
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Text((row.sourceKind === 'provider' ? '在线' : '维护') + ' · ' + new Date(row.updatedAt).toLocaleDateString())
              .fontSize(10).fontColor(row.sourceKind === 'provider' ? '#2BB673' : this.pal().text3)
          }.width('100%').padding({ top: 5, bottom: 5 })
        }, (row: DiagnosticAiModelPriceEntry): string => 'price-' + row.providerId + '-' + row.modelId)
        Text('来源与更新时间以每行标记为准；价格不是 Provider 账单，缺少官方单价时显示“待确认”。').fontSize(10).lineHeight(15)
          .fontColor(this.pal().text3).width('100%')
      }
      if (this.profiles.length > 1) {
        Text('已配置订阅（点击切换新请求）').fontSize(12).fontColor(this.pal().text2).width('100%')
        ForEach(this.profiles, (profile: DiagnosticAiProviderProfile): void => {
          Row({ space: 8 }) {
            SymbolGlyph(profile.providerId === this.settings.selectedProviderId && profile.modelId === this.settings.selectedModelId ?
              $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle')).fontSize(16)
              .fontColor([profile.providerId === this.settings.selectedProviderId && profile.modelId === this.settings.selectedModelId ? this.accent : this.pal().text3])
            Text(profile.displayName + ' · ' + (profile.modelId === '' ? '未选择模型' : profile.modelId)).fontSize(12).fontColor(this.pal().text).layoutWeight(1)
          }.width('100%').padding({ top: 7, bottom: 7 }).onClick((): void => { this.useProviderForNewRequests(profile); })
        }, (profile: DiagnosticAiProviderProfile): string => 'usage-provider-' + profile.id)
      }
      if (this.usageSnapshot.providerUsage.length > 0) {
        Text('订阅用量明细').fontSize(12).fontColor(this.pal().text2).width('100%')
        ForEach(this.usageSnapshot.providerUsage, (row: DiagnosticAiProviderUsage): void => {
          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Text(row.providerId + ' · ' + (row.modelId === '' ? '未知模型' : row.modelId)).fontSize(12).fontColor(this.pal().text)
              Text(row.requestCount.toString() + ' 次 · ' + (row.promptTokens + row.completionTokens).toString() + ' Token · ¥' + row.estimatedCostCny.toFixed(4)).fontSize(11).fontColor(this.pal().text3)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Text('查看').fontSize(11).fontColor(this.accent)
          }.width('100%').padding({ top: 6, bottom: 6 }).onClick((): void => { this.usageProviderFilter = this.usageRowKey(row); })
        }, (row: DiagnosticAiProviderUsage): string => 'usage-row-' + this.usageRowKey(row))
      }
      Row({ space: 8 }) {
        Column({ space: 2 }) { Text(this.usageSnapshot.requestCount.toString()).fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.pal().text); Text('请求').fontSize(11).fontColor(this.pal().text3) }.layoutWeight(1)
        Column({ space: 2 }) { Text((this.usageSnapshot.promptTokens + this.usageSnapshot.completionTokens).toString()).fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.pal().text); Text('估算 Token').fontSize(11).fontColor(this.pal().text3) }.layoutWeight(1)
        Column({ space: 2 }) { Text(this.cacheHitText()).fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.pal().text); Text('缓存命中').fontSize(11).fontColor(this.pal().text3) }.layoutWeight(1)
        Column({ space: 2 }) { Text(this.costText()).fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.pal().text); Text('估算费用').fontSize(11).fontColor(this.pal().text3) }.layoutWeight(1)
      }.width('100%')
      Text(this.usageFilterText() + ' · 统计只保存在当前账号的本机偏好中；Provider 未返回真实计费时按 ¥0.30/百万 Token 估算。').fontSize(11).lineHeight(16).fontColor(this.pal().text3).width('100%')
    }.width('100%').padding(14).borderRadius(18).backgroundColor(this.pal().card)
      .border({ width: 0.5, color: this.pal().cardBorder })
  }

  @Builder private sessionManagementSection() {
    Scroll() {
      Column({ space: 10 }) {
        Column({ space: 4 }) {
          Text('历史会话').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
          Text('每个会话保留自己的 Provider、模型和上下文。点击后会替换当前设置页，并在原 Provider 上继续提问。').fontSize(12).lineHeight(17).fontColor(this.pal().text3).width('100%')
        }.width('100%').alignItems(HorizontalAlign.Start)
        if (this.sessions.length === 0) {
          Text('还没有已保存的对话。完成一次问答后会自动创建会话。').fontSize(12).fontColor(this.pal().text2).width('100%')
        } else {
          ForEach(this.sessions.slice(0, 50), (session: DiagnosticAiConversationSession): void => {
            AppSettingsActionRow({ title: session.title, detail: session.turns.length.toString() + ' 轮 · ' + new Date(session.updatedAt).toLocaleString(), isEnabled: true,
              onAction: (): void => {
                const profile: DiagnosticAiProviderProfile | undefined = this.profiles.find((item: DiagnosticAiProviderProfile): boolean =>
                  item.providerId === session.providerId && item.modelId === session.modelId);
                if (profile !== undefined) { this.useProviderForNewRequests(profile); }
                this.onOpenSession(session.id);
              } })
          }, (session: DiagnosticAiConversationSession): string => 'session-' + session.id)
        }
      }.width('100%').padding({ bottom: 16 })
    }.layoutWeight(1).width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
  }

  @Builder private assistantCustomizationSection() {
    this.sectionLabel('助手个性与本地记忆')
    Column({ space: 10 }) {
      Text('助手名称').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
      TextInput({ placeholder: '例如：RD Assistant', text: this.assistantNameDraft }).height(42).fontSize(14)
        .backgroundColor(this.pal().surface).borderRadius(12).onChange((value: string): void => { this.assistantNameDraft = value; })
      Text('回答风格').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(DIAGNOSTIC_AI_PERSONALITY_CHOICES, (item: DiagnosticAiPersonalityChoice): void => {
          Text(item.label).fontSize(12).fontColor(this.personalityDraft === item.id ? Color.White : this.pal().text)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 }).margin({ right: 8, bottom: 6 }).borderRadius(14)
            .backgroundColor(this.personalityDraft === item.id ? this.accent : this.pal().surface)
            .onClick((): void => { this.personalityDraft = item.id; })
        }, (item: DiagnosticAiPersonalityChoice): string => item.id)
      }.width('100%')
      Text('回答长度').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(DIAGNOSTIC_AI_VERBOSITY_CHOICES, (item: DiagnosticAiChoice): void => {
          Text(item.label).fontSize(12).fontColor(this.verbosityDraft === item.id ? Color.White : this.pal().text)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 }).margin({ right: 8, bottom: 6 }).borderRadius(14)
            .backgroundColor(this.verbosityDraft === item.id ? this.accent : this.pal().surface)
            .onClick((): void => { this.verbosityDraft = item.id as 'concise' | 'standard' | 'detailed'; })
        }, (item: DiagnosticAiChoice): string => 'verbosity-' + item.id)
      }.width('100%')
      Text('助手角色').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(DIAGNOSTIC_AI_ROLE_CHOICES, (item: DiagnosticAiChoice): void => {
          Text(item.label).fontSize(12).fontColor(this.roleDraft === item.id ? Color.White : this.pal().text)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 }).margin({ right: 8, bottom: 6 }).borderRadius(14)
            .backgroundColor(this.roleDraft === item.id ? this.accent : this.pal().surface)
            .onClick((): void => { this.roleDraft = item.id as 'remote-expert' | 'beginner-guide' | 'diagnostic-first' | 'privacy-first'; })
        }, (item: DiagnosticAiChoice): string => 'role-' + item.id)
      }.width('100%')
      Text('回答语言').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
      Row({ space: 8 }) {
        Text('简体中文').fontSize(12).fontColor(this.languageDraft === 'zh-CN' ? Color.White : this.pal().text)
          .padding({ left: 12, right: 12, top: 7, bottom: 7 }).borderRadius(14)
          .backgroundColor(this.languageDraft === 'zh-CN' ? this.accent : this.pal().surface)
          .onClick((): void => { this.languageDraft = 'zh-CN'; })
        Text('English').fontSize(12).fontColor(this.languageDraft === 'en-US' ? Color.White : this.pal().text)
          .padding({ left: 12, right: 12, top: 7, bottom: 7 }).borderRadius(14)
          .backgroundColor(this.languageDraft === 'en-US' ? this.accent : this.pal().surface)
          .onClick((): void => { this.languageDraft = 'en-US'; })
      }.width('100%')
      Row({ space: 8 }) {
        Column({ space: 2 }) { Text('允许本地记忆').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text); Text('会话摘要和你手动填写的偏好只附加到后续请求').fontSize(11).fontColor(this.pal().text3) }.layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.memoryEnabledDraft }).selectedColor(this.accent).onChange((value: boolean): void => { this.memoryEnabledDraft = value; })
      }.width('100%')
      Row({ space: 8 }) {
        Column({ space: 2 }) { Text('减少 AI 动效').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text); Text('关闭持续旋转和弹簧转场，保留状态与可用操作').fontSize(11).fontColor(this.pal().text3) }.layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.settings.reducedMotion }).selectedColor(this.accent)
          .onChange((value: boolean): void => { this.saveReducedMotion(value); })
      }.width('100%')
      Row({ space: 8 }) {
        Column({ space: 2 }) { Text('主动建议').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text); Text('在回答末尾显示下一步操作卡片').fontSize(11).fontColor(this.pal().text3) }.layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.proactiveSuggestionsDraft }).selectedColor(this.accent).onChange((value: boolean): void => { this.proactiveSuggestionsDraft = value; })
      }.width('100%')
      Row({ space: 8 }) {
        Column({ space: 2 }) { Text('敏感操作先确认').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text); Text('断开、传输、隐私、凭据等操作始终建议保持开启').fontSize(11).fontColor(this.pal().text3) }.layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.confirmBeforeActionsDraft }).selectedColor(this.accent).onChange((value: boolean): void => { this.confirmBeforeActionsDraft = value; })
      }.width('100%')
      Text('自动会话摘要').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
      Text(this.sessionMemorySummary === '' ? '完成问答后，这里会显示最近会话的本机摘要。' : this.sessionMemorySummary)
        .fontSize(11).lineHeight(16).fontColor(this.pal().text3).width('100%').maxLines(8)
      Text('手动补充偏好').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
      TextArea({ placeholder: '例如：我主要使用 RDP，回答请先给出最短操作路径。', text: this.memoryDraft }).height(86).fontSize(13)
        .backgroundColor(this.pal().surface).borderRadius(12).onChange((value: string): void => { this.memoryDraft = value; })
      Button('保存助手偏好').width('100%').height(42).borderRadius(21).backgroundColor(this.pal().surface).fontColor(this.accent)
        .onClick((): void => { this.saveAssistantPreferences(); })
    }.width('100%').padding(14).borderRadius(18).backgroundColor(this.pal().card)
      .border({ width: 0.5, color: this.pal().cardBorder })
  }

  @Builder private configSection() {
    Scroll() {
      Column({ space: 10 }) {
        this.statusCard()
        this.sectionLabel('选择服务商 · 优先支持中国大陆服务')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.manifests, (manifest: DiagnosticAiProviderManifest): void => { this.providerCard(manifest) },
            (manifest: DiagnosticAiProviderManifest): string => manifest.providerId)
        }.width('100%')
        this.sectionLabel('连接信息')
        Column({ space: 10 }) {
          this.authModeSection()
          if (diagnosticAiProviderIsHarmonyLocal(this.selectedProvider)) {
            this.field('鸿蒙端侧小模型', '由 HarmonyOS 系统管理，不需要服务地址、API Key 或模型 ID')
            Row({ space: 10 }) {
              SymbolGlyph($r('sys.symbol.lock_shield_fill')).fontSize(22).fontColor([this.accent])
              Text(this.selectedProviderSupported() ?
                '当前设备允许使用 PC/2in1 端侧问答模型' :
                '当前设备不可用：手机和 Pad 暂未开放').fontSize(13).lineHeight(19)
                .fontColor(this.pal().text).layoutWeight(1)
            }.width('100%').padding(12).borderRadius(14).backgroundColor(this.pal().surface)
            Button(this.busy ? '检测中…' : '检测端侧模型').height(44).fontSize(13).borderRadius(12)
              .backgroundColor(this.pal().surface).fontColor(this.accent)
              .enabled(!this.busy && this.selectedProviderSupported())
              .onClick((): void => { void this.fetchModels(); })
          } else {
            this.field(this.authModeDraft === 'coding_plan_key' ? 'Coding Plan 专用 Base URL' : '服务地址',
              this.authModeDraft === 'coding_plan_key' ? '仅使用 Provider Manifest 声明的专用地址，不会把专用 Key 发到自定义端点' : '可改为兼容的 HTTPS 地址')
            TextInput({ placeholder: 'https://', text: this.endpoint }).height(44).fontSize(14)
              .backgroundColor(this.pal().surface).borderRadius(12)
              .enabled(this.authModeDraft !== 'coding_plan_key')
              .onChange((value: string): void => { this.endpoint = value; })
            this.field(this.authModeDraft === 'coding_plan_key' ? 'Coding Plan 专用 Key' : 'API Key',
              this.authModeDraft === 'coding_plan_key' ? '与普通 API Key 分开保存；仅用于已核验的 Coding Plan' : '只保存在本机安全存储，不会同步或写入日志')
            TextInput({ placeholder: this.selectedHasSecret() ? '已保存；留空则保持不变' :
              (this.authModeDraft === 'coding_plan_key' ? '粘贴 Coding Plan 专用 Key' : '粘贴 API Key'), text: this.keyText })
              .height(44).fontSize(14).type(InputType.Password).backgroundColor(this.pal().surface).borderRadius(12)
              .onChange((value: string): void => { this.keyText = value; })
            if (this.authModeDraft !== 'none') {
              Row({ space: 8 }) {
                Checkbox().select(this.termsAcceptedDraft).selectedColor(this.accent)
                  .onChange((value: boolean): void => { this.termsAcceptedDraft = value; })
                Text('我已查看 Provider 条款版本 ' + (this.selectedManifest()?.termsVersion ?? '待核验') +
                  '，确认当前诊断助手用途和数据处理地区已向我说明。')
                  .fontSize(11).lineHeight(16).fontColor(this.pal().text3).layoutWeight(1)
              }.width('100%')
            }
            this.field('模型', '保存服务后可拉取可用模型列表')
            Row({ space: 8 }) {
              TextInput({ placeholder: '模型 ID', text: this.model }).height(44).fontSize(14).layoutWeight(1)
                .backgroundColor(this.pal().surface).borderRadius(12)
                .onChange((value: string): void => { this.model = value; })
              Button('拉取模型').height(44).fontSize(13).padding({ left: 14, right: 14 }).borderRadius(12)
                .backgroundColor(this.pal().surface).fontColor(this.accent).enabled(!this.busy)
                .onClick((): void => { void this.fetchModels(); })
            }.width('100%')
          }
          if (this.availableModels.length > 0) {
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.availableModels, (item: DiagnosticAiModelInfo): void => {
                Text(item.displayName.length > 0 ? item.displayName : item.id).fontSize(12).maxLines(1)
                  .fontColor(this.model === item.id ? Color.White : this.pal().text)
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 }).margin({ right: 6, bottom: 6 }).borderRadius(10)
                  .backgroundColor(this.model === item.id ? this.accent : this.pal().surface)
                  .onClick((): void => { this.selectModel(item.id); })
              }, (item: DiagnosticAiModelInfo): string => item.id)
            }.width('100%')
          }
        }
        .width('100%').padding(14).borderRadius(18).backgroundColor(this.pal().card)
        .border({ width: 0.5, color: this.pal().cardBorder })
        if (this.profiles.length > 1) {
          this.sectionLabel('已保存的服务')
          ForEach(this.profiles, (profile: DiagnosticAiProviderProfile): void => {
            Row({ space: 8 }) {
              AppSettingsActionRow({ title: profile.displayName, detail: (profile.modelId === '' ? '已配置 · 尚未选择模型' :
                '模型：' + profile.modelId) + ' · ' + this.authModeLabel(profile.authMode) + ' · ' + diagnosticAiPrivacySummary(profile), isEnabled: true,
                onAction: (): void => { this.selectedProvider = profile.providerId; this.authModeDraft = profile.authMode;
                  this.termsAcceptedDraft = profile.consentId !== '' && profile.consentAt > 0;
                this.model = profile.modelId;
                  this.endpoint = profile.endpoint; this.availableModels = []; } }).layoutWeight(1)
              Button('删除').height(40).fontSize(12).fontColor(this.pal().danger).backgroundColor(this.pal().surface)
                .borderRadius(12).onClick((): void => { this.revokeProfile(profile); })
            }.width('100%')
          }, (profile: DiagnosticAiProviderProfile): string => profile.id)
        }
        Row({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.performance')).fontSize(20).fontColor([this.accent])
          Column({ space: 2 }) {
            Text('AI 入口已常驻').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
            Text('主机页右上角始终保留入口；点击即可唤起 Siri 风格 AI 浮窗。').fontSize(11).fontColor(this.pal().text3)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Text('已开启').fontSize(11).fontColor('#2BB673').padding({ left: 8, right: 8, top: 3, bottom: 3 }).borderRadius(9).backgroundColor('#1A2BB673')
        }.width('100%').padding(14).borderRadius(18).backgroundColor(this.pal().card)
          .border({ width: 0.5, color: this.pal().cardBorder })
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
    Button(this.busy ? '处理中…' : '保存配置').width('100%').height(48).fontSize(16).fontWeight(FontWeight.Medium)
      .fontColor(Color.White).backgroundColor(this.accent).borderRadius(24).margin({ top: 10 })
      .enabled(!this.busy).onClick((): void => { void this.saveProvider(); })
  }

  @Builder private lockedCard() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.lock_fill')).fontSize(30).fontColor([this.pal().text3])
      Text('需要有效的 Pro 权益').fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
      Text('传统日志抓取不受影响，可在「设置 → 诊断与 AI 帮助 → 传统日志抓取」中使用。')
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
        if ((this.section === 1 || this.section === 3 || this.section === 4 || this.section === 5) ? !this.assistantAllowed() : !this.providerAllowed()) {
          this.lockedCard()
        } else if (this.section === 1) {
          DiagnosticAiAssistantPanel({
            embedded: true,
            resumeSessionId: this.resumeSessionId,
            onAppAction: (action: DiagnosticAiAppActionId): void => { this.onAppAction(action); },
            onClose: (): void => { this.onClose(); },
            onOpenMailDraft: (subject: string, body: string): void => { this.onOpenMailDraft(subject, body); }
          }).layoutWeight(1)
        } else if (this.section === 3) {
          this.usageSection()
        } else if (this.section === 4) {
          this.personalizationSection()
        } else if (this.section === 5) {
          this.sessionManagementSection()
        } else {
          this.configSection()
        }
      }.width('100%').height('100%').padding({ left: 20, right: 20, top: 18, bottom: 28 })
        .backgroundColor(this.pal().sheetBg)
  }
}
