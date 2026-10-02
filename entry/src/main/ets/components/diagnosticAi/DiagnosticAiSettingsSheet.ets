import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { AppConfig, Palette, buildDark, buildLight } from '../../common/Theme';
import { AppSettingsActionRow } from '../AppSettingsActionRow';
import { AppUiMetrics } from '../../common/AppUiMetrics';
import { DiagnosticAiAssistantPanel } from './DiagnosticAiAssistantPanel';
import { DiagnosticAiModelInfo, DiagnosticAiProviderManifest, DiagnosticAiProviderProfile, DiagnosticAiSettings } from '../../services/diagnosticAi/DiagnosticAiModels';
import { diagnosticAiHarmonyLocalDeviceSupported, diagnosticAiProviderIsHarmonyLocal, diagnosticAiProviderManifests, diagnosticAiProviderSupportsDevice, HARMONY_LOCAL_MODEL_ID } from '../../services/diagnosticAi/DiagnosticAiProviderCatalog';
import { validateDiagnosticAiEndpoint } from '../../services/diagnosticAi/DiagnosticAiEndpointPolicy';
import { DiagnosticAiProfileStore } from '../../services/diagnosticAi/DiagnosticAiProfileStore';
import { DiagnosticAiProviderService, diagnosticAiPrivacySummary } from '../../services/diagnosticAi/DiagnosticAiProviderService';
import { AccountSessionCoordinator } from '../../services/AccountSessionCoordinator';
import { ProAppRuntime } from '../../services/pro/ProAppRuntime';
import { ProEntries } from '../../services/pro/ProEntries';
import { PRO_DIAGNOSTICS_ASSISTANT_FEATURE, PRO_DIAGNOSTICS_FEATURE, PRO_DIAGNOSTICS_PROVIDER_FEATURE } from '../../services/pro/ProFeatureCatalog';
import { DiagnosticAiAssistantPreferences, DiagnosticAiConversationSession, DiagnosticAiConversationStore, DiagnosticAiProviderUsage, DiagnosticAiUsageSnapshot, defaultDiagnosticAiAssistantPreferences } from '../../services/diagnosticAi/DiagnosticAiConversationStore';

class DiagnosticAiPersonalityChoice {
  id: 'balanced' | 'warm' | 'concise' | 'technical';
  label: string;
  constructor(id: 'balanced' | 'warm' | 'concise' | 'technical', label: string) { this.id = id; this.label = label; }
}

const DIAGNOSTIC_AI_PERSONALITY_CHOICES: DiagnosticAiPersonalityChoice[] = [
  new DiagnosticAiPersonalityChoice('balanced', '均衡'), new DiagnosticAiPersonalityChoice('warm', '温和'),
  new DiagnosticAiPersonalityChoice('concise', '简洁'), new DiagnosticAiPersonalityChoice('technical', '技术')
];

@Component
export struct DiagnosticAiSettingsSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @StorageProp('breakpoint') breakpoint: string = 'md';
  onClose: () => void = (): void => {};
  onOpenMailDraft: (subject: string, body: string) => void = (_subject: string, _body: string): void => {};
  /** Which sub-setting this sheet shows: 0 = 辅助 AI 配置, 1 = 启动 AI 辅助. 传统日志 has its own free sheet. */
  @Prop section: number = 0;
  @State manifests: DiagnosticAiProviderManifest[] = [];
  @State profiles: DiagnosticAiProviderProfile[] = [];
  @State settings: DiagnosticAiSettings = { selectedProviderId: '', selectedModelId: '', showOrbOnHostPage: false, reducedMotion: false, retentionDays: 7 };
  @State selectedProvider: string = 'deepseek';
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
  @State assistantNameDraft: string = '小远';
  @State resumeSessionId: string = '';
  @State usageProviderFilter: string = '';
  @State private personalityDraft: 'balanced' | 'warm' | 'concise' | 'technical' = 'balanced';
  @State private memoryEnabledDraft: boolean = true;
  private readonly providerService: DiagnosticAiProviderService = new DiagnosticAiProviderService();
  private readonly conversationStore: DiagnosticAiConversationStore = new DiagnosticAiConversationStore();
  private store: DiagnosticAiProfileStore = new DiagnosticAiProfileStore();
  private owner: string = 'device-local';

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }

  aboutToAppear(): void {
    try { this.deviceType = deviceInfo.deviceType; } catch (_error) { this.deviceType = 'unknown'; }
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    this.owner = scope.ownerScopeId.trim() === '' ? 'device-local' : scope.ownerScopeId.trim();
    this.manifests = diagnosticAiProviderManifests(); this.store.init(getContext(this) as common.UIAbilityContext, this.owner);
    this.conversationStore.init(getContext(this) as common.UIAbilityContext, this.owner);
    this.profiles = this.store.list(); this.settings = this.store.settingsSnapshot();
    this.sessions = this.conversationStore.listSessions();
    this.usageSnapshot = this.conversationStore.usage();
    this.assistantPreferences = this.conversationStore.assistantPreferences();
    this.assistantNameDraft = this.assistantPreferences.name;
    this.personalityDraft = this.assistantPreferences.personality;
    this.memoryEnabledDraft = this.assistantPreferences.memoryEnabled;
    this.memoryDraft = this.assistantPreferences.memorySummary;
    if (this.settings.selectedProviderId !== '') { this.selectedProvider = this.settings.selectedProviderId; }
    this.model = this.settings.selectedModelId;
    const selected = this.manifests.find((value: DiagnosticAiProviderManifest): boolean => value.providerId === this.selectedProvider);
    this.endpoint = selected?.endpoint ?? '';
  }

  private allowed(): boolean { return ProEntries.visible(PRO_DIAGNOSTICS_FEATURE, ProAppRuntime.getInstance().context()); }
  private providerAllowed(): boolean { return ProEntries.visible(PRO_DIAGNOSTICS_PROVIDER_FEATURE, ProAppRuntime.getInstance().context()); }
  private assistantAllowed(): boolean {
    return ProEntries.visible(PRO_DIAGNOSTICS_ASSISTANT_FEATURE, ProAppRuntime.getInstance().context());
  }

  private providerAvailable(manifest: DiagnosticAiProviderManifest): boolean {
    if (!diagnosticAiProviderSupportsDevice(manifest, this.deviceType)) { return false; }
    return diagnosticAiProviderIsHarmonyLocal(manifest.providerId) ||
      (manifest.endpoint !== '' && manifest.chatPath !== '');
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
    this.endpoint = manifest?.endpoint ?? ''; this.availableModels = [];
    if (manifest !== undefined && diagnosticAiProviderIsHarmonyLocal(id)) { this.model = HARMONY_LOCAL_MODEL_ID; }
    else { this.model = ''; }
    this.message = '';
  }

  private async saveProvider(): Promise<void> {
    if (!this.providerAllowed() || this.busy) { return; }
    const manifest = this.manifests.find((value: DiagnosticAiProviderManifest): boolean => value.providerId === this.selectedProvider);
    const localProvider: boolean = manifest !== undefined && diagnosticAiProviderIsHarmonyLocal(manifest.providerId);
    if (manifest === undefined || (!localProvider && (manifest.endpoint === '' || manifest.chatPath === ''))) {
      this.message = '该 Provider 尚未完成请求适配'; return;
    }
    if (localProvider && !diagnosticAiHarmonyLocalDeviceSupported(this.deviceType)) {
      this.message = '鸿蒙端侧小模型当前仅支持 PC/2in1；手机和 Pad 暂不可用，后续开放后将上线。'; return;
    }
    if (!localProvider) {
      const endpointDecision = validateDiagnosticAiEndpoint(this.endpoint, manifest.adapterFamily, false);
      if (!endpointDecision.ok) { this.message = '保存失败：' + endpointDecision.message; return; }
    }
    this.busy = true; this.message = '';
    const existing = this.profiles.find((value: DiagnosticAiProviderProfile): boolean => value.providerId === manifest.providerId);
    const nextRevision: number = existing === undefined ? 1 : Math.max(1, existing.revision + 1);
    const profile: DiagnosticAiProviderProfile = { id: this.selectedProvider + '-' + this.owner.slice(-8), owner: this.owner,
      providerId: manifest.providerId, displayName: manifest.displayName, endpoint: localProvider ? '' : this.endpoint.trim(),
      modelId: localProvider ? HARMONY_LOCAL_MODEL_ID : this.model.trim(),
      authKind: manifest.authKind, authHeader: manifest.authHeader, secretRef: '', secretFingerprint: '', manifestVersion: manifest.schemaVersion,
      privacy: { region: manifest.privacy.region, retention: manifest.privacy.retention,
        trainingUse: manifest.privacy.trainingUse, policyRef: manifest.privacy.policyRef },
      showOrbOnHostPage: this.settings.showOrbOnHostPage, revision: nextRevision, updatedAt: Date.now() };
    if (!this.store.saveProfile(profile, this.keyText.trim())) { this.message = '保存失败：请检查 API Key 和 Provider 地址'; }
    else {
      this.settings.selectedProviderId = profile.providerId;
      this.settings.selectedModelId = profile.modelId;
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
        'Provider 配置已保存；密钥只保存在本机安全存储。';
    }
    this.busy = false;
  }

  private async fetchModels(): Promise<void> {
    const profile = this.store.list().find((value: DiagnosticAiProviderProfile): boolean => value.providerId === this.selectedProvider);
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

  private persistModelSelection(modelId: string): boolean {
    const profile = this.store.list().find((value: DiagnosticAiProviderProfile): boolean => value.providerId === this.selectedProvider);
    if (profile === undefined || modelId.trim() === '') { return false; }
    profile.modelId = modelId.trim();
    if (!this.store.saveProfile(profile, '')) { return false; }
    const next = this.store.settingsSnapshot();
    next.selectedProviderId = profile.providerId; next.selectedModelId = profile.modelId;
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

  private saveAssistantPreferences(): void {
    const next: DiagnosticAiAssistantPreferences = {
      name: this.assistantNameDraft.trim() === '' ? '小远' : this.assistantNameDraft.trim().slice(0, 32),
      personality: this.personalityDraft, memoryEnabled: this.memoryEnabledDraft,
      memorySummary: this.memoryDraft.trim().slice(0, 4000), updatedAt: Date.now()
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

  private selectedUsageProvider(): DiagnosticAiProviderProfile | undefined {
    return this.profiles.find((item: DiagnosticAiProviderProfile): boolean => item.providerId === this.settings.selectedProviderId && item.modelId === this.settings.selectedModelId) ??
      this.profiles.find((item: DiagnosticAiProviderProfile): boolean => item.providerId === this.settings.selectedProviderId) ?? this.profiles[0];
  }

  private useProviderForNewRequests(profile: DiagnosticAiProviderProfile): void {
    const next: DiagnosticAiSettings = {
      selectedProviderId: profile.providerId, selectedModelId: profile.modelId,
      showOrbOnHostPage: true, reducedMotion: this.settings.reducedMotion, retentionDays: this.settings.retentionDays
    };
    if (this.store.saveSettings(next)) {
      this.settings = next; this.selectedProvider = profile.providerId; this.model = profile.modelId;
      this.usageProviderFilter = profile.providerId; this.message = '已切换当前 AI 订阅：' + profile.displayName + ' / ' + profile.modelId;
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
    return this.profiles.find((value: DiagnosticAiProviderProfile): boolean =>
      value.providerId === this.settings.selectedProviderId) ?? this.profiles[0];
  }
  /** The selected provider already has a stored key, so an empty field keeps it (saveProfile reuses the same ref). */
  private selectedHasSecret(): boolean {
    return this.profiles.some((value: DiagnosticAiProviderProfile): boolean =>
      value.providerId === this.selectedProvider && value.secretFingerprint !== '');
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
    return '辅助 AI 配置';
  }
  private headerDetail(): string {
    if (this.section === 1) { return '询问应用、协助设置、诊断问题并生成反馈草稿'; }
    if (this.section === 3) { return '按订阅查看 Token、缓存命中和费用估算'; }
    if (this.section === 4) { return '名称、语气和仅保存在本机的助手记忆'; }
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
      Text((this.usageProviderFilter === '' ? '全部订阅' : '当前筛选：' + this.usageProviderFilter) + ' · 统计只保存在当前账号的本机偏好中；Provider 未返回真实计费时按 ¥0.30/百万 Token 估算。').fontSize(11).lineHeight(16).fontColor(this.pal().text3).width('100%')
      if (this.sessions.length === 0) {
        Text('还没有已保存的对话。每次完成一次问答后会自动创建会话。').fontSize(12).fontColor(this.pal().text2).width('100%')
      } else {
        ForEach(this.sessions.slice(0, 8), (session: DiagnosticAiConversationSession): void => {
          AppSettingsActionRow({ title: session.title, detail: session.turns.length.toString() + ' 轮 · ' + new Date(session.updatedAt).toLocaleString(), isEnabled: true,
            onAction: (): void => { this.resumeSessionId = session.id; this.message = '已选择会话：' + session.title + '；请切换到「启动 AI 辅助」查看'; } })
        }, (session: DiagnosticAiConversationSession): string => session.id)
      }
    }.width('100%').padding(14).borderRadius(18).backgroundColor(this.pal().card)
      .border({ width: 0.5, color: this.pal().cardBorder })
  }

  @Builder private assistantCustomizationSection() {
    this.sectionLabel('助手个性与本地记忆')
    Column({ space: 10 }) {
      Text('助手名称').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
      TextInput({ placeholder: '例如：小远', text: this.assistantNameDraft }).height(42).fontSize(14)
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
      Row({ space: 8 }) {
        Column({ space: 2 }) { Text('允许本地记忆').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text); Text('只把你主动填写的偏好附加到后续请求').fontSize(11).fontColor(this.pal().text3) }.layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.memoryEnabledDraft }).selectedColor(this.accent).onChange((value: boolean): void => { this.memoryEnabledDraft = value; })
      }.width('100%')
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
            this.field('服务地址', '可改为兼容的 HTTPS 地址')
            TextInput({ placeholder: 'https://', text: this.endpoint }).height(44).fontSize(14)
              .backgroundColor(this.pal().surface).borderRadius(12)
              .onChange((value: string): void => { this.endpoint = value; })
            this.field('API Key', '只保存在本机安全存储，不会同步或写入日志')
            TextInput({ placeholder: this.selectedHasSecret() ? '已保存；留空则保持不变' : '粘贴 API Key', text: this.keyText })
              .height(44).fontSize(14).type(InputType.Password).backgroundColor(this.pal().surface).borderRadius(12)
              .onChange((value: string): void => { this.keyText = value; })
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
            AppSettingsActionRow({ title: profile.displayName, detail: profile.modelId === '' ? '已配置 · 尚未选择模型' :
              '模型：' + profile.modelId + ' · ' + diagnosticAiPrivacySummary(profile), isEnabled: true,
              onAction: (): void => { this.selectedProvider = profile.providerId; this.model = profile.modelId;
                this.endpoint = profile.endpoint; this.availableModels = []; } })
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
      if ((this.section === 1 || this.section === 3 || this.section === 4) ? !this.assistantAllowed() : !this.providerAllowed()) {
        this.lockedCard()
      } else if (this.section === 1) {
        DiagnosticAiAssistantPanel({
          embedded: true,
          resumeSessionId: this.resumeSessionId,
          onClose: (): void => { this.onClose(); },
          onOpenMailDraft: (subject: string, body: string): void => {
            this.onOpenMailDraft(subject, body);
          }
        }).layoutWeight(1)
      } else if (this.section === 3) {
        this.usageSection()
      } else if (this.section === 4) {
        this.personalizationSection()
      } else {
        this.configSection()
      }
    }.width('100%').height('100%').padding({ left: 20, right: 20, top: 18, bottom: 28 })
    .backgroundColor(this.pal().sheetBg)
  }
}
