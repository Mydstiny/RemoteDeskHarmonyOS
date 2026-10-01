import { common } from '@kit.AbilityKit';
import { AppConfig, Palette, buildDark, buildLight } from '../../common/Theme';
import { AppSettingsActionRow } from '../AppSettingsActionRow';
import { AppUiMetrics } from '../../common/AppUiMetrics';
import { DiagnosticCaptureSettingsSheet } from '../DiagnosticCaptureSettingsSheet';
import { DiagnosticAiAssistantPanel } from './DiagnosticAiAssistantPanel';
import { DiagnosticAiProviderManifest, DiagnosticAiProviderProfile, DiagnosticAiSettings } from '../../services/diagnosticAi/DiagnosticAiModels';
import { diagnosticAiProviderManifests } from '../../services/diagnosticAi/DiagnosticAiProviderCatalog';
import { validateDiagnosticAiEndpoint } from '../../services/diagnosticAi/DiagnosticAiEndpointPolicy';
import { DiagnosticAiProfileStore } from '../../services/diagnosticAi/DiagnosticAiProfileStore';
import { DiagnosticAiProviderService, diagnosticAiPrivacySummary } from '../../services/diagnosticAi/DiagnosticAiProviderService';
import { AccountSessionCoordinator } from '../../services/AccountSessionCoordinator';
import { ProAppRuntime } from '../../services/pro/ProAppRuntime';
import { ProEntries } from '../../services/pro/ProEntries';
import { PRO_DIAGNOSTICS_FEATURE, PRO_DIAGNOSTICS_PROVIDER_FEATURE } from '../../services/pro/ProFeatureCatalog';

@Component
export struct DiagnosticAiSettingsSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @StorageProp('breakpoint') breakpoint: string = 'md';
  onClose: () => void = (): void => {};
  onOpenMailDraft: (subject: string, body: string) => void = (_subject: string, _body: string): void => {};
  @State tab: number = 0;
  @State manifests: DiagnosticAiProviderManifest[] = [];
  @State profiles: DiagnosticAiProviderProfile[] = [];
  @State settings: DiagnosticAiSettings = { selectedProviderId: '', selectedModelId: '', showOrbOnHostPage: false, reducedMotion: false, retentionDays: 7 };
  @State selectedProvider: string = 'deepseek';
  @State endpoint: string = '';
  @State keyText: string = '';
  @State model: string = '';
  @State message: string = '';
  @State busy: boolean = false;
  @State showAssistant: boolean = false;
  private readonly providerService: DiagnosticAiProviderService = new DiagnosticAiProviderService();
  private store: DiagnosticAiProfileStore = new DiagnosticAiProfileStore();
  private owner: string = 'device-local';

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }

  aboutToAppear(): void {
    const scope = AccountSessionCoordinator.getInstance().currentScope(); this.owner = scope.ownerScopeId || 'device-local';
    this.manifests = diagnosticAiProviderManifests(); this.store.init(getContext(this) as common.UIAbilityContext, this.owner);
    this.profiles = this.store.list(); this.settings = this.store.settingsSnapshot();
    if (this.settings.selectedProviderId !== '') { this.selectedProvider = this.settings.selectedProviderId; }
    this.model = this.settings.selectedModelId;
    const selected = this.manifests.find((value: DiagnosticAiProviderManifest): boolean => value.providerId === this.selectedProvider);
    this.endpoint = selected?.endpoint ?? '';
  }

  private allowed(): boolean { return ProEntries.visible(PRO_DIAGNOSTICS_FEATURE, ProAppRuntime.getInstance().context()); }
  private providerAllowed(): boolean { return ProEntries.visible(PRO_DIAGNOSTICS_PROVIDER_FEATURE, ProAppRuntime.getInstance().context()); }

  private providerAvailable(manifest: DiagnosticAiProviderManifest): boolean {
    return manifest.endpoint !== '' && manifest.chatPath !== '';
  }

  private selectProvider(id: string): void {
    this.selectedProvider = id; const manifest = this.manifests.find((value: DiagnosticAiProviderManifest): boolean => value.providerId === id);
    if (manifest !== undefined && (manifest.endpoint === '' || manifest.chatPath === '')) {
      this.message = '该 Provider 已列入路线图，当前版本尚未开放请求适配';
      return;
    }
    this.endpoint = manifest?.endpoint ?? ''; this.message = '';
  }

  private async saveProvider(): Promise<void> {
    if (!this.providerAllowed() || this.busy) { return; }
    const manifest = this.manifests.find((value: DiagnosticAiProviderManifest): boolean => value.providerId === this.selectedProvider);
    if (manifest === undefined || manifest.endpoint === '' || manifest.chatPath === '') {
      this.message = '该 Provider 尚未完成请求适配'; return;
    }
    const endpointDecision = validateDiagnosticAiEndpoint(this.endpoint, manifest.adapterFamily, false);
    if (!endpointDecision.ok) { this.message = '保存失败：' + endpointDecision.message; return; }
    this.busy = true; this.message = '';
    const profile: DiagnosticAiProviderProfile = { id: this.selectedProvider + '-' + this.owner.slice(-8), owner: this.owner,
      providerId: manifest.providerId, displayName: manifest.displayName, endpoint: this.endpoint.trim(), modelId: this.model.trim(),
      authKind: manifest.authKind, authHeader: manifest.authHeader, secretRef: '', secretFingerprint: '', manifestVersion: manifest.schemaVersion,
      privacy: { region: manifest.privacy.region, retention: manifest.privacy.retention,
        trainingUse: manifest.privacy.trainingUse, policyRef: manifest.privacy.policyRef },
      showOrbOnHostPage: this.settings.showOrbOnHostPage, revision: 0, updatedAt: Date.now() };
    if (!this.store.saveProfile(profile, this.keyText.trim())) { this.message = '保存失败：请检查 API Key 和 Provider 地址'; }
    else {
      this.settings.selectedProviderId = profile.providerId;
      this.settings.selectedModelId = profile.modelId;
      this.store.saveSettings(this.settings);
      this.keyText = ''; this.profiles = this.store.list(); this.message = 'Provider 配置已保存；密钥只保存在本机安全存储。';
    }
    this.busy = false;
  }

  private async fetchModels(): Promise<void> {
    const profile = this.profiles.find((value: DiagnosticAiProviderProfile): boolean => value.providerId === this.selectedProvider);
    if (profile === undefined || this.busy) { this.message = '请先保存 Provider 配置'; return; }
    this.busy = true; this.message = '正在拉取模型列表…';
    try {
      const models = await this.providerService.listModels(profile, this.store.secret(profile));
      this.model = models.length > 0 ? models[0].id : this.model; this.message = '已读取 ' + models.length.toString() + ' 个模型；请选择并再次保存。';
    } catch (error) { this.message = error instanceof Error ? error.message : '模型列表读取失败'; }
    finally { this.busy = false; }
  }

  private saveOrbPreference(value: boolean): void {
    this.settings.showOrbOnHostPage = value; this.store.saveSettings(this.settings);
    AppStorage.setOrCreate('diagnosticAiOrbEnabled', value);
    this.message = value ? '远程主机页 AI 入口已开启' : '远程主机页 AI 入口已关闭';
  }

  build() {
    Column() {
      if (!this.allowed()) {
        Column({ space: 12 }) {
          Text('诊断与 AI 帮助需要有效 Pro 权益').fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          Text('传统日志仍可单独使用。').fontSize(13).fontColor(this.pal().text2)
          Button('关闭').onClick((): void => { this.onClose(); })
        }.padding(24).width('100%')
      } else if (this.showAssistant) {
        DiagnosticAiAssistantPanel({
          onClose: (): void => { this.showAssistant = false; },
          onOpenMailDraft: (subject: string, body: string): void => {
            this.onOpenMailDraft(subject, body);
          }
        })
      } else {
      Row({ space: 10 }) {
        Text('诊断与 AI 帮助').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily).layoutWeight(1)
        Button('关闭').height(40).backgroundColor(Color.Transparent).fontColor(this.accent).onClick((): void => { this.onClose(); })
      }.width('100%')
      Row({ space: 8 }) {
        Button('辅助 AI 配置').layoutWeight(1).height(42).enabled(this.tab !== 0).onClick((): void => { this.tab = 0; })
        Button('启动 AI 辅助').layoutWeight(1).height(42).enabled(this.tab !== 1).onClick((): void => { this.tab = 1; })
        Button('传统日志').layoutWeight(1).height(42).enabled(this.tab !== 2).onClick((): void => { this.tab = 2; })
      }.width('100%')
      if (this.tab === 0) {
        Scroll() {
          Column({ space: 12 }) {
            Text('优先支持中国大陆 Provider；OpenAI 等国际 Provider 后续加入。').fontSize(12).fontColor(this.pal().text2).width('100%')
            ForEach(this.manifests, (manifest: DiagnosticAiProviderManifest): void => {
              Row({ space: 8 }) {
                Text(manifest.displayName).fontSize(14).fontColor(this.pal().text).layoutWeight(1)
                Text(this.providerAvailable(manifest) ? (manifest.market === 'local' ? '本机' : '大陆') : '后续适配')
                  .fontSize(11).fontColor(this.providerAvailable(manifest) ? this.accent : this.pal().text3)
              }.width('100%').height(48).padding({ left: 12, right: 12 }).borderRadius(12)
                .backgroundColor(this.selectedProvider === manifest.providerId ? this.pal().surface : this.pal().card)
                .opacity(this.providerAvailable(manifest) ? 1 : 0.62)
                .onClick((): void => { if (this.providerAvailable(manifest)) { this.selectProvider(manifest.providerId); } })
            }, (manifest: DiagnosticAiProviderManifest): string => manifest.providerId)
            TextInput({ placeholder: 'Provider HTTPS 地址（预设为空时手动填写）', text: this.endpoint }).height(44).onChange((value: string): void => { this.endpoint = value; })
            TextInput({ placeholder: 'API Key（仅写入本机安全存储）', text: this.keyText }).height(44).type(InputType.Password).onChange((value: string): void => { this.keyText = value; })
            TextInput({ placeholder: '模型 ID', text: this.model }).height(44).onChange((value: string): void => { this.model = value; })
            Row({ space: 8 }) {
              Button('保存 Provider').layoutWeight(1).height(44).backgroundColor(this.accent).fontColor(Color.White).enabled(!this.busy).onClick((): void => { void this.saveProvider(); })
              Button('拉取模型').layoutWeight(1).height(44).enabled(!this.busy).onClick((): void => { void this.fetchModels(); })
            }.width('100%')
            ForEach(this.profiles, (profile: DiagnosticAiProviderProfile): void => {
              AppSettingsActionRow({ title: profile.displayName, detail: profile.modelId === '' ? '已配置 · 尚未选择模型' : '模型：' + profile.modelId + ' · ' + diagnosticAiPrivacySummary(profile), isEnabled: true, onAction: (): void => { this.selectedProvider = profile.providerId; this.model = profile.modelId; this.endpoint = profile.endpoint; } })
            }, (profile: DiagnosticAiProviderProfile): string => profile.id)
            Row() { Text('远程主机页显示 AI 入口').fontSize(14).fontColor(this.pal().text).layoutWeight(1); Toggle({ type: ToggleType.Switch, isOn: this.settings.showOrbOnHostPage }).selectedColor(this.accent).onChange((value: boolean): void => { this.saveOrbPreference(value); }) }.width('100%').height(52)
            Text(this.message).fontSize(12).fontColor(this.pal().text2).width('100%')
          }.padding(4).width('100%')
        }.layoutWeight(1).scrollBar(BarState.Auto)
      } else if (this.tab === 1) {
        DiagnosticAiAssistantPanel({
          onClose: (): void => { this.tab = 0; },
          onOpenMailDraft: (subject: string, body: string): void => {
            this.onOpenMailDraft(subject, body);
          }
        }).layoutWeight(1)
      } else {
        DiagnosticCaptureSettingsSheet({ onClose: (): void => { this.tab = 0; } }).layoutWeight(1)
      }
      }
    }.width('100%').height('100%').padding(20).backgroundColor(this.pal().sheetBg)
  }
}
