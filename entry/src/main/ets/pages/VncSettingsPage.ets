/**
 * VncSettingsPage — VNC 专属设置、主机和网关管理。
 *
 * 该页面不读取 HostSyncService、RemoteHost、RustDesk relay 或普通
 * usersettings。它只通过 VNC 自己的 service 访问 vncrecordv2 overlay。
 */
import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { VncSettingsService } from '../services/VncSettingsService';
import { VncHostService, VncHostView } from '../services/VncHostService';
import { VncGatewayService, VncGatewayView } from '../services/VncGatewayService';
import { VncTrustView } from '../services/VncTrustService';
import { DataCrypto } from '../services/DataCrypto';
import {
  VncSettingsValues,
  VncHostValues,
  VncGatewayValues,
  VncTransport,
  VncRepeaterMode,
  VncScalingMode,
  VncSecurityPolicy,
  VncDisplayScaleMode,
  VncImageQualityPreset,
  VncPreferredEncoding,
  VncColorDepth,
  VncLocalCursorMode
} from '../services/VncModelPolicy';
import { Palette, buildDark, buildLight, AppTheme } from '../common/Theme';
import { VncAddFlow } from '../components/hostadd/VncAddFlow';
import { VncCertificateTrustManagerSheet } from '../components/VncCertificateTrustManagerSheet';
import { buildVncTrustDirectory, VncTrustDirectoryItem } from '../services/VncTrustEndpointDirectory';
import { SETTINGS_PANEL_DISMISS_TO_LEAF_OPEN_MS } from '../services/SettingsSheetRoutePolicy';
import { isSelectableVncDefaultGateway, VncSelectableGateway } from '../services/VncHostDefaultsPolicy';
import { RemoteSessionConnectionIntent } from '../services/RemoteSessionConnectionIntent';
import { VncSessionCredentialHandoff } from '../services/VncSessionCredentialHandoff';
import { SecretPresentationStore } from '../services/SecretPresentationPolicy';

@Entry
@Component
export struct VncSettingsPage {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @StorageProp('topRectHeight') topRectHeight: number = 0;
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';

  @State defaultTransport: VncTransport = 'direct_tcp';
  @State defaultPortText: string = '5900';
  @State connectTimeoutText: string = '10000';
  @State authTimeoutText: string = '15000';
  @State firstFrameTimeoutText: string = '15000';
  @State viewOnly: boolean = false;
  @State controlMode: number = 0;
  @State showDiagnostics: boolean = false;
  @State scalingMode: VncScalingMode = 'fit';
  @State displayScaleMode: VncDisplayScaleMode = 'fit';
  @State customScalePercent: number = 100;
  @State imageQualityPreset: VncImageQualityPreset = 'balanced';
  @State preferredEncoding: VncPreferredEncoding = 'auto';
  @State colorDepth: VncColorDepth = 'auto';
  @State frameRateLimit: number = 30;
  @State jpegQuality: number = 6;
  @State localCursorMode: VncLocalCursorMode = 'auto';
  @State touchpadSpeed: number = 100;
  @State reverseWheel: boolean = false;
  @State swapMouseButtons: boolean = false;
  @State diagnosticsExpanded: boolean = false;
  @State diagnosticsRefreshMs: number = 500;
  @State diagnosticsMetricMask: number = 63;
  @State clipboardEnabled: boolean = false;
  @State securityPolicy: VncSecurityPolicy = 'secure_only';
  @State defaultGatewayId: string = '';
  @State repeaterMode: VncRepeaterMode = 'mode12';
  @State syncPreferences: boolean = true;
  @State syncHosts: boolean = true;
  @State syncGateways: boolean = true;
  @State syncSecrets: boolean = false;
  @State syncTrust: boolean = false;

  @State hosts: VncHostView[] = [];
  @State gateways: VncGatewayView[] = [];
  @State showTrustManagerSheet: boolean = false;
  @State hostFormVisible: boolean = false;
  @State hostFlowVisible: boolean = false;
  @State hostFlowEditingId: string = '';
  @State hostFlowHost: VncHostView | null = null;
  @State pendingHostFlowConnectId: string = '';
  @State pendingHostFlowGatewayDirectory: boolean = false;
  @State gatewayFormVisible: boolean = false;
  @State hostLabel: string = '';
  @State hostAddress: string = '';
  @State hostPortText: string = '5900';
  @State hostUsername: string = '';
  @State hostPassword: string = '';
  @State hostRememberPassword: boolean = false;
  @State hostGatewayId: string = '';
  @State hostTransport: VncTransport = 'direct_tcp';
  @State hostRepeaterMode: VncRepeaterMode = 'mode12';
  @State hostViewOnly: boolean = false;
  @State hostDisplayOverrideEnabled: boolean = false;
  @State hostScalingMode: VncScalingMode = 'fit';
  @State hostClipboardEnabled: boolean = false;
  @State hostSecurityPolicy: VncSecurityPolicy = 'secure_only';
  @State hostTls: boolean = false;
  @State editingHostId: string = '';
  @State gatewayLabel: string = '';
  @State gatewayAddress: string = '';
  @State gatewayPortText: string = '5901';
  @State gatewayPath: string = '/vnc';
  @State gatewayTargetId: string = '';
  @State gatewayToken: string = '';
  @State gatewayTransport: VncTransport = 'ultravnc_repeater';
  @State gatewayRepeaterMode: VncRepeaterMode = 'mode12';
  @State gatewayTls: boolean = false;
  @State gatewayEnabled: boolean = true;
  @State editingGatewayId: string = '';
  @State errorMessage: string = '';
  @State pendingDefaultGatewayCleanupId: string = '';
  @State cryptoReady: boolean = false;
  @State revision: number = 0;

  private readonly settings: VncSettingsService = VncSettingsService.getInstance();
  private readonly hostService: VncHostService = VncHostService.getInstance();
  private readonly gatewayService: VncGatewayService = VncGatewayService.getInstance();
  private readonly secretPresentation: SecretPresentationStore = SecretPresentationStore.getInstance();
  private settingsUnsubscribe: (() => void) | null = null;
  private hostUnsubscribe: (() => void) | null = null;
  private gatewayUnsubscribe: (() => void) | null = null;
  private cryptoUnsubscribe: (() => void) | null = null;
  private pageActive: boolean = false;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private font(): string { return AppTheme.fontFamily; }

  private topSafeHeightVp(): number {
    return this.topRectHeight > 0 ? px2vp(this.topRectHeight) : AppTheme.layout.statusBarH;
  }

  aboutToAppear(): void {
    this.pageActive = true;
    const context: common.Context = getContext(this) as common.Context;
    this.secretPresentation.init(context);
    this.settings.init(context);
    this.hostService.init(context);
    this.gatewayService.init(context);
    this.bindListeners();
    this.load();
  }

  onPageShow(): void { this.load(); }

  aboutToDisappear(): void {
    this.pageActive = false;
    if (this.settingsUnsubscribe) { this.settingsUnsubscribe(); this.settingsUnsubscribe = null; }
    if (this.hostUnsubscribe) { this.hostUnsubscribe(); this.hostUnsubscribe = null; }
    if (this.gatewayUnsubscribe) { this.gatewayUnsubscribe(); this.gatewayUnsubscribe = null; }
    if (this.cryptoUnsubscribe) { this.cryptoUnsubscribe(); this.cryptoUnsubscribe = null; }
  }

  private bindListeners(): void {
    if (this.settingsUnsubscribe === null) {
      this.settingsUnsubscribe = this.settings.onChange((): void => {
        if (this.pageActive) { this.load(); }
      });
    }
    if (this.hostUnsubscribe === null) {
      this.hostUnsubscribe = this.hostService.onChange((): void => {
        if (this.pageActive) { this.loadHosts(); }
      });
    }
    if (this.gatewayUnsubscribe === null) {
      this.gatewayUnsubscribe = this.gatewayService.onChange((): void => {
        if (this.pageActive) { this.loadGateways(); }
      });
    }
    if (this.cryptoUnsubscribe === null) {
      this.cryptoUnsubscribe = DataCrypto.getInstance().onStateChange((): void => {
        this.cryptoReady = DataCrypto.getInstance().isReady();
      });
    }
  }

  private load(): void {
    const values: VncSettingsValues = this.settings.get();
    this.defaultTransport = values.defaultTransport;
    this.defaultPortText = values.defaultPort.toString();
    this.connectTimeoutText = values.connectTimeoutMs.toString();
    this.authTimeoutText = values.authTimeoutMs.toString();
    this.firstFrameTimeoutText = values.firstFrameTimeoutMs.toString();
    this.viewOnly = values.viewOnly;
    this.controlMode = values.controlMode;
    this.showDiagnostics = values.showDiagnostics;
    this.scalingMode = values.scalingMode;
    this.displayScaleMode = values.displayScaleMode;
    this.customScalePercent = values.customScalePercent;
    this.imageQualityPreset = values.imageQualityPreset;
    this.preferredEncoding = values.preferredEncoding;
    this.colorDepth = values.colorDepth;
    this.frameRateLimit = values.frameRateLimit;
    this.jpegQuality = values.jpegQuality;
    this.localCursorMode = values.localCursorMode;
    this.touchpadSpeed = values.touchpadSpeed;
    this.reverseWheel = values.reverseWheel;
    this.swapMouseButtons = values.swapMouseButtons;
    this.diagnosticsExpanded = values.diagnosticsExpanded;
    this.diagnosticsRefreshMs = values.diagnosticsRefreshMs;
    this.diagnosticsMetricMask = values.diagnosticsMetricMask;
    this.clipboardEnabled = values.clipboardEnabled;
    this.securityPolicy = values.securityPolicy;
    this.defaultGatewayId = values.defaultGatewayId;
    this.repeaterMode = values.repeaterMode;
    this.syncPreferences = values.syncPreferences;
    this.syncHosts = values.syncHosts;
    this.syncGateways = values.syncGateways;
    this.syncSecrets = values.syncSecrets;
    this.syncTrust = values.syncTrust;
    this.cryptoReady = DataCrypto.getInstance().isReady();
    this.loadHosts();
    this.loadGateways();
  }

  private loadHosts(): void {
    this.hosts = this.hostService.list();
    this.revision += 1;
  }

  private loadGateways(): void {
    this.gateways = this.gatewayService.list();
    this.revision += 1;
  }

  private async clearDefaultGatewayReference(gatewayId: string): Promise<boolean> {
    const normalizedId: string = gatewayId.trim();
    if (normalizedId === '') { return true; }
    const ok: boolean = await this.settings.clearDefaultGatewayIf(normalizedId);
    if (ok) {
      if (this.defaultGatewayId.trim() === normalizedId) { this.defaultGatewayId = ''; }
      if (this.pendingDefaultGatewayCleanupId.trim() === normalizedId) {
        this.pendingDefaultGatewayCleanupId = '';
        this.errorMessage = '';
      }
      return true;
    }
    this.pendingDefaultGatewayCleanupId = normalizedId;
    this.errorMessage = '默认 Gateway 引用清理失败，请重试；连接默认值仍保持待清理状态';
    return false;
  }

  private async retryDefaultGatewayCleanup(): Promise<void> {
    if (this.pendingDefaultGatewayCleanupId === '') { return; }
    await this.clearDefaultGatewayReference(this.pendingDefaultGatewayCleanupId);
  }

  private selectableDefaultGateways(): VncGatewayView[] {
    const userId: string = this.settings.getUserId();
    const result: VncGatewayView[] = [];
    for (let i = 0; i < this.gateways.length; i++) {
      const gateway: VncGatewayView = this.gateways[i];
      const selectable: VncSelectableGateway = {
        id: gateway.id, userId: gateway.userId, transport: gateway.transport,
        repeaterMode: gateway.repeaterMode, enabled: gateway.enabled
      };
      if (isSelectableVncDefaultGateway(selectable, userId)) { result.push(gateway); }
    }
    return result;
  }

  private defaultGatewayIsSelectable(): boolean {
    const selected: string = this.defaultGatewayId.trim();
    if (selected === '') { return false; }
    const gateways: VncGatewayView[] = this.selectableDefaultGateways();
    for (let i = 0; i < gateways.length; i++) {
      if (gateways[i].id === selected) { return true; }
    }
    return false;
  }

  private numberValue(text: string, fallback: number): number {
    const value: number = Number(text);
    return Number.isFinite(value) ? Math.floor(value) : fallback;
  }

  private settingsValues(): VncSettingsValues {
    return {
      defaultTransport: this.defaultTransport,
      defaultPort: this.numberValue(this.defaultPortText, 5900),
      connectTimeoutMs: this.numberValue(this.connectTimeoutText, 10000),
      authTimeoutMs: this.numberValue(this.authTimeoutText, 15000),
      firstFrameTimeoutMs: this.numberValue(this.firstFrameTimeoutText, 15000),
      viewOnly: this.viewOnly,
      controlMode: this.controlMode,
      showDiagnostics: this.showDiagnostics,
      scalingMode: this.scalingMode,
      displayScaleMode: this.displayScaleMode,
      customScalePercent: this.customScalePercent,
      imageQualityPreset: this.imageQualityPreset,
      preferredEncoding: this.preferredEncoding,
      colorDepth: this.colorDepth,
      frameRateLimit: this.frameRateLimit,
      jpegQuality: this.jpegQuality,
      localCursorMode: this.localCursorMode,
      touchpadSpeed: this.touchpadSpeed,
      reverseWheel: this.reverseWheel,
      swapMouseButtons: this.swapMouseButtons,
      diagnosticsExpanded: this.diagnosticsExpanded,
      diagnosticsRefreshMs: this.diagnosticsRefreshMs,
      diagnosticsMetricMask: this.diagnosticsMetricMask,
      clipboardEnabled: this.clipboardEnabled,
      securityPolicy: this.securityPolicy,
      defaultGatewayId: this.defaultGatewayId.trim(),
      repeaterMode: this.repeaterMode,
      syncPreferences: this.syncPreferences,
      syncHosts: this.syncHosts,
      syncGateways: this.syncGateways,
      syncSecrets: this.syncSecrets,
      syncTrust: this.syncTrust
    };
  }

  private saveSettings(): void {
    const current: VncSettingsValues = this.settings.get();
    const needsSecretConfirmation: boolean = this.syncSecrets && !current.syncSecrets;
    const needsTrustConfirmation: boolean = this.syncTrust && !current.syncTrust;
    if (needsSecretConfirmation || needsTrustConfirmation) {
      promptAction.showDialog({
        title: '确认 VNC 敏感数据同步',
        message: needsSecretConfirmation
          ? (DataCrypto.getInstance().isReady()
            ? 'VNC 密码和网关令牌会以绑定上下文的 AES-GCM 密文进入 vncrecordv2。新设备仍需重新确认 trust。'
            : DataCrypto.getInstance().isSetupComplete()
              ? '应用加密已锁定。现有 AES-GCM 密文会保留并等待解锁；未解锁时不会覆盖云端。新密码可关闭“记住密码”后临时使用。'
              : '应用加密未启用。明确选择记住密码的 VNC 凭据可能以未加密形式进入 vncrecordv2；请确认风险。')
          : '只同步 VNC 证书候选和元数据，不同步本机 confirmation marker；新设备仍须人工确认。',
        buttons: [{ text: '取消', color: this.pal().text2 }, { text: '确认开启', color: this.accentColor }]
      }).then((result: Object): void => {
        const values: Record<string, number> = result as Record<string, number>;
        if (values['index'] === 1) {
          void this.persistSettings();
        }
      });
      return;
    }
    void this.persistSettings();
  }

  private async persistSettings(): Promise<void> {
    if (this.defaultTransport === 'ultravnc_repeater' && !this.defaultGatewayIsSelectable()) {
      this.errorMessage = this.selectableDefaultGateways().length === 0
        ? '没有可用的 mode12 Gateway；请先启用一个 VNC Gateway，或改用 TCP'
        : '请选择当前账号下已启用的 mode12 Gateway，或改用 TCP';
      return;
    }
    const result =
      await this.settings.save(
        this.settingsValues());
    this.errorMessage = result.ok ? '' : result.message;
    if (result.ok) {
      promptAction.showToast({ message: 'VNC 设置已保存', duration: 1600 });
    }
  }

  private hostValues(): VncHostValues {
    const existing: VncHostView | undefined = this.editingHostId === '' ? undefined :
      this.hosts.find((host: VncHostView): boolean => host.id === this.editingHostId);
    return {
      label: this.hostLabel,
      host: this.hostAddress,
      port: this.numberValue(this.hostPortText, 5900),
      username: this.hostUsername,
      gatewayId: this.hostGatewayId,
      transport: this.hostTransport,
      repeaterMode: this.hostRepeaterMode,
      rememberPassword: this.hostRememberPassword,
      viewOnly: this.hostViewOnly,
      displayOverrideEnabled: this.hostDisplayOverrideEnabled,
      scalingMode: this.hostScalingMode,
      clipboardEnabled: this.hostClipboardEnabled,
      securityPolicy: this.hostSecurityPolicy,
      tls: this.hostTls,
      locked: existing === undefined ? false : existing.locked,
      lockType: existing === undefined ? 0 : existing.lockType
    };
  }

  private saveHost(): void {
    const saveWithPlaintextConsent = (allowPlaintext: boolean): void => {
      const result = this.hostService.save(this.hostValues(), this.editingHostId, this.hostPassword,
        allowPlaintext);
      if (!result.ok) { this.errorMessage = result.message; return; }
      this.errorMessage = '';
      this.resetHostForm();
      promptAction.showToast({ message: 'VNC 主机已保存', duration: 1600 });
    };
    const crypto: DataCrypto = DataCrypto.getInstance();
    if (this.hostPassword.length > 0 && this.hostRememberPassword && !crypto.isSetupComplete()) {
      promptAction.showDialog({
        title: '确认保存未加密密码',
        message: '应用加密未启用。打开“记住密码”会把 VNC 密码以未加密形式保存；关闭此选项即可仅临时连接。',
        buttons: [{ text: '取消', color: this.pal().text2 }, { text: '确认保存', color: this.pal().danger }]
      }).then((dialog: Object): void => {
        const values: Record<string, number> = dialog as Record<string, number>;
        if (values['index'] === 1) { saveWithPlaintextConsent(true); }
      });
      return;
    }
    if (this.hostPassword.length > 0 && this.hostRememberPassword &&
      crypto.isSetupComplete() && !crypto.isReady()) {
      this.errorMessage = '应用加密已锁定；请先解锁，或关闭“记住密码”后保存';
      return;
    }
    saveWithPlaintextConsent(false);
  }

  private async clearDefaultGatewayBeforeMutation(gatewayId: string): Promise<boolean> {
    return await this.clearDefaultGatewayReference(gatewayId);
  }

  private saveGateway(): void {
    const values: VncGatewayValues = {
      label: this.gatewayLabel,
      transport: this.gatewayTransport,
      host: this.gatewayAddress,
      port: this.numberValue(this.gatewayPortText, 5901),
      path: this.gatewayPath,
      repeaterMode: this.gatewayRepeaterMode,
      targetId: this.gatewayTargetId,
      tls: this.gatewayTls,
      enabled: this.gatewayEnabled
    };
    const saveWithPlaintextConsent = async (allowPlaintext: boolean): Promise<void> => {
      if (!values.enabled && this.editingGatewayId.trim() !== '' &&
        !await this.clearDefaultGatewayBeforeMutation(this.editingGatewayId)) { return; }
      const result = this.gatewayService.save(values, this.editingGatewayId, this.gatewayToken,
        allowPlaintext);
      if (!result.ok) { this.errorMessage = result.message; return; }
      this.errorMessage = '';
      this.resetGatewayForm();
      promptAction.showToast({ message: 'VNC 网关已保存', duration: 1600 });
    };
    const crypto: DataCrypto = DataCrypto.getInstance();
    if (this.gatewayToken.length > 0 && !crypto.isSetupComplete()) {
      promptAction.showDialog({
        title: '确认保存未加密令牌',
        message: '应用加密未启用。Gateway 令牌将以未加密形式保存；也可以留空，仅保存端点。',
        buttons: [{ text: '取消', color: this.pal().text2 }, { text: '确认保存', color: this.pal().danger }]
      }).then((dialog: Object): void => {
        const values: Record<string, number> = dialog as Record<string, number>;
        if (values['index'] === 1) { void saveWithPlaintextConsent(true); }
      });
      return;
    }
    if (this.gatewayToken.length > 0 && crypto.isSetupComplete() && !crypto.isReady()) {
      this.errorMessage = '应用加密已锁定；请先解锁后保存 Gateway 令牌，或留空保留现有令牌';
      return;
    }
    void saveWithPlaintextConsent(false);
  }

  private deleteHost(host: VncHostView): void {
    promptAction.showDialog({
      title: '删除 VNC 主机', message: '确定删除“' + host.label + '”吗？密码和本地密文也会删除。',
      buttons: [{ text: '取消', color: this.pal().text2 }, { text: '删除', color: this.pal().danger }]
    }).then((result: Object): void => {
      const values: Record<string, number> = result as Record<string, number>;
      if (values['index'] === 1 && this.hostService.remove(host.id)) { this.loadHosts(); }
    });
  }

  private deleteGateway(gateway: VncGatewayView): void {
    promptAction.showDialog({
      title: '删除 VNC 网关', message: '确定删除“' + gateway.label + '”吗？',
      buttons: [{ text: '取消', color: this.pal().text2 }, { text: '删除', color: this.pal().danger }]
    }).then((result: Object): void => {
      const values: Record<string, number> = result as Record<string, number>;
      if (values['index'] === 1) { void this.removeGatewayAfterConfirmation(gateway); }
    });
  }

  private async removeGatewayAfterConfirmation(gateway: VncGatewayView): Promise<void> {
    if (!await this.clearDefaultGatewayBeforeMutation(gateway.id)) { return; }
    if (!this.gatewayService.remove(gateway.id)) {
      this.errorMessage = 'VNC Gateway 删除失败；默认引用已清除为直连，请重试';
      return;
    }
    this.errorMessage = '';
    this.loadGateways();
  }

  private editGateway(gateway: VncGatewayView): void {
    this.editingGatewayId = gateway.id;
    this.gatewayFormVisible = true;
    this.gatewayLabel = gateway.label;
    this.gatewayAddress = gateway.host;
    this.gatewayPortText = gateway.port.toString();
    this.gatewayPath = gateway.path;
    this.gatewayTargetId = gateway.targetId;
    this.gatewayToken = '';
    this.gatewayTransport = gateway.transport;
    this.gatewayRepeaterMode = gateway.repeaterMode;
    this.gatewayTls = gateway.tls;
    this.gatewayEnabled = gateway.enabled;
  }

  private resetHostForm(): void {
    this.hostFormVisible = false;
    this.editingHostId = '';
    this.hostLabel = ''; this.hostAddress = ''; this.hostPortText = this.defaultPortText;
    this.hostUsername = ''; this.hostPassword = ''; this.hostGatewayId = this.defaultGatewayId;
    this.hostTransport = this.defaultTransport; this.hostRepeaterMode = this.repeaterMode;
    this.hostRememberPassword = false;
    this.hostViewOnly = this.viewOnly; this.hostDisplayOverrideEnabled = false;
    this.hostScalingMode = this.scalingMode;
    this.hostClipboardEnabled = this.clipboardEnabled; this.hostSecurityPolicy = this.securityPolicy;
    this.hostTls = this.securityPolicy === 'secure_only' ? true : false;
  }

  private editHost(host: VncHostView): void {
    this.editingHostId = host.id;
    this.hostFormVisible = true;
    this.hostLabel = host.label;
    this.hostAddress = host.host;
    this.hostPortText = host.port.toString();
    // VNC V1 has no username authentication path; keep the legacy field
    // write-only and never re-save it from this editor.
    this.hostUsername = '';
    this.hostPassword = '';
    this.hostRememberPassword = host.rememberPassword;
    this.hostGatewayId = host.gatewayId;
    this.hostTransport = host.transport;
    this.hostRepeaterMode = host.repeaterMode;
    this.hostViewOnly = host.viewOnly;
    this.hostDisplayOverrideEnabled = host.displayOverrideEnabled;
    this.hostScalingMode = host.scalingMode;
    this.hostClipboardEnabled = host.clipboardEnabled;
    this.hostSecurityPolicy = host.securityPolicy;
    this.hostTls = host.tls;
  }

  private connectHost(host: VncHostView): void {
    this.openVncSession(host);
  }

  private openVncSession(host: VncHostView): void {
    // The settings page is not an authentication owner on any device class.
    // HostList owns lock, certificate and password preflight before either
    // Phone/Pad navigation or PC independent-window staging can begin.
    if (!RemoteSessionConnectionIntent.getInstance().put('vnc', host.id)) {
      promptAction.showToast({ message: 'VNC 连接请求无效', duration: 2200 });
      return;
    }
    void router.back();
  }

  private openHostFlow(host: VncHostView | null = null): void {
    this.hostFlowHost = host;
    this.hostFlowEditingId = host === null ? '' : host.id;
    this.pendingHostFlowConnectId = '';
    this.pendingHostFlowGatewayDirectory = false;
    this.hostFlowVisible = true;
  }

  private saveHostFromFlow(values: VncHostValues, password: string, connectNow: boolean,
    plainStorageConfirmed: boolean = false): void {
    if (!this.hostService.isReady()) {
      promptAction.showToast({ message: 'VNC 服务尚未完成云同步初始化，请稍后重试', duration: 2200 });
      return;
    }
    const result = this.hostService.save(values, this.hostFlowEditingId, password, plainStorageConfirmed);
    if (!result.ok) {
      promptAction.showToast({ message: result.message || 'VNC 主机保存失败', duration: 2200 });
      return;
    }
    if (connectNow && !values.rememberPassword && password.length > 0) {
      VncSessionCredentialHandoff.getInstance().put(
        this.hostService.currentUserId(), result.id, password);
    }
    this.pendingHostFlowConnectId = connectNow ? result.id : '';
    promptAction.showToast({
      message: connectNow ? 'VNC 主机已保存，正在准备连接' :
        (this.hostFlowEditingId === '' ? 'VNC 主机已保存' : 'VNC 主机已更新'),
      duration: 1800
    });
    this.hostFlowVisible = false;
  }

  private finishHostFlowDismiss(): void {
    const pendingId: string = this.pendingHostFlowConnectId;
    const openGatewayDirectory: boolean = this.pendingHostFlowGatewayDirectory;
    this.pendingHostFlowConnectId = '';
    this.pendingHostFlowGatewayDirectory = false;
    this.hostFlowVisible = false;
    this.hostFlowEditingId = '';
    this.hostFlowHost = null;
    this.loadHosts();
    if (pendingId !== '') { this.connectHostById(pendingId); }
    if (openGatewayDirectory) {
      setTimeout((): void => {
        if (this.pageActive) { this.openGatewayDirectory(); }
      }, SETTINGS_PANEL_DISMISS_TO_LEAF_OPEN_MS);
    }
  }

  private connectHostById(id: string): void {
    const host: VncHostView | null = this.hostService.find(id);
    if (host !== null) { this.connectHost(host); }
  }

  private openGatewayDirectory(): void {
    router.replaceUrl({
      url: 'pages/HostListPage',
      params: { openVncGateway: true, vncRelayRequestId: Date.now().toString() }
    });
  }

  @Builder private hostFlowContent() {
    VncAddFlow({
      gateways: this.gatewayService.list(),
      initialHost: this.hostFlowHost,
      editingId: this.hostFlowEditingId,
      onBackToProtocols: (): void => { this.hostFlowVisible = false; },
      onOpenSettings: (): void => {
        this.hostFlowVisible = false;
        this.pendingHostFlowGatewayDirectory = true;
      },
      onSave: (values: VncHostValues, password: string, connectNow: boolean,
        plainStorageConfirmed: boolean): void => {
        this.saveHostFromFlow(values, password, connectNow, plainStorageConfirmed);
      }
    })
  }

  private resetGatewayForm(): void {
    this.gatewayFormVisible = false;
    this.editingGatewayId = '';
    this.gatewayLabel = ''; this.gatewayAddress = ''; this.gatewayPortText = '5901';
    this.gatewayPath = '/vnc'; this.gatewayTargetId = ''; this.gatewayToken = '';
    this.gatewayTransport = 'ultravnc_repeater'; this.gatewayRepeaterMode = this.repeaterMode;
    this.gatewayTls = false; this.gatewayEnabled = true;
  }

  @Builder private header() {
    Row() {
      SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(22).fontColor([this.pal().text])
        .width(42).height(42).onClick((): void => { router.back(); })
      Text('VNC 数据管理').fontSize(24).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        .fontFamily(this.font()).layoutWeight(1)
    }.width('100%').padding({ top: this.topSafeHeightVp() + 8, left: 18, right: 18, bottom: 10 })
  }

  @Builder private cardTitle(title: string, subtitle: string) {
    Column() {
      Text(title).fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font())
      Text(subtitle).fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 4 })
    }.alignItems(HorizontalAlign.Start).width('100%').margin({ bottom: 14 })
  }

  @Builder private input(label: string, placeholder: string, value: string, onChange: (value: string) => void,
    password: boolean = false) {
    Row() {
      Text(label).fontSize(13).fontColor(this.pal().text2).fontFamily(this.font()).width(112)
      TextInput({ placeholder, text: value }).layoutWeight(1).height(40).fontSize(13)
        .backgroundColor(this.pal().surface).fontColor(this.pal().text).placeholderColor(this.pal().text3)
        .type(password ? InputType.Password : InputType.Normal).onChange(onChange)
    }.width('100%').margin({ bottom: 8 }).alignItems(VerticalAlign.Center)
  }

  @Builder private transportChoices(current: VncTransport, onChoose: (value: VncTransport) => void) {
    Row() {
      Button('TCP').layoutWeight(1).height(34).fontSize(12).borderRadius(8)
        .backgroundColor(current === 'direct_tcp' ? this.accentColor : this.pal().surface)
        .fontColor(current === 'direct_tcp' ? Color.White : this.pal().text2)
        .onClick((): void => { onChoose('direct_tcp'); })
      Button('Repeater').layoutWeight(1).height(34).fontSize(12).borderRadius(8).margin({ left: 6 })
        .backgroundColor(current === 'ultravnc_repeater' ? this.accentColor : this.pal().surface)
        .fontColor(current === 'ultravnc_repeater' ? Color.White : this.pal().text2)
        .onClick((): void => { onChoose('ultravnc_repeater'); })
      Button('WebSocket').layoutWeight(1).height(34).fontSize(12).borderRadius(8).margin({ left: 6 })
        .backgroundColor(current === 'websocket_gateway' ? this.accentColor : this.pal().surface)
        .fontColor(current === 'websocket_gateway' ? Color.White : this.pal().text2)
        .onClick((): void => { onChoose('websocket_gateway'); })
    }.width('100%').margin({ bottom: 10 })
  }

  @Builder private settingToggle(title: string, detail: string, checked: boolean, onChange: (value: boolean) => void) {
    Row() {
      Column() {
        Text(title).fontSize(14).fontColor(this.pal().text).fontFamily(this.font())
        Text(detail).fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: checked }).selectedColor(this.accentColor)
        .onChange(onChange).scale({ x: 0.85, y: 0.85 })
    }.width('100%').padding({ top: 7, bottom: 7 })
  }

  @Builder private settingsCard() {
    Column() {
      this.cardTitle('连接与显示', '只影响 VNC；RDP、RustDesk 和 SSH 使用自己的设置')
      Text('默认传输').fontSize(12).fontColor(this.pal().text3).margin({ bottom: 6 })
      this.transportChoices(this.defaultTransport, (value: VncTransport): void => {
        this.defaultTransport = value;
        if (value !== 'ultravnc_repeater') { this.defaultGatewayId = ''; }
      })
      if (this.defaultTransport === 'ultravnc_repeater') {
        Text('默认 Gateway').fontSize(12).fontColor(this.pal().text3).margin({ top: 2, bottom: 6 })
        if (this.selectableDefaultGateways().length === 0) {
          Text('暂无可用的 mode12 Gateway；保存 Repeater 默认前请先启用 Gateway。')
            .fontSize(11).fontColor(this.pal().danger).margin({ bottom: 8 })
        } else {
          Column() {
            ForEach(this.selectableDefaultGateways(), (gateway: VncGatewayView): void => {
              Button(gateway.label.trim() === '' ? gateway.host + ':' + gateway.port.toString() : gateway.label)
                .width('100%').height(36).fontSize(12).borderRadius(8)
                .backgroundColor(this.defaultGatewayId === gateway.id ? this.accentColor : this.pal().surface)
                .fontColor(this.defaultGatewayId === gateway.id ? Color.White : this.pal().text2)
                .onClick((): void => { this.defaultGatewayId = gateway.id; });
            }, (gateway: VncGatewayView): string => gateway.id + ':' + this.revision.toString())
          }.width('100%').margin({ bottom: 8 })
        }
      }
      this.input('默认端口', '5900', this.defaultPortText, (value: string): void => { this.defaultPortText = value; })
      this.input('连接超时', '10000 ms', this.connectTimeoutText, (value: string): void => { this.connectTimeoutText = value; })
      this.input('认证超时', '15000 ms', this.authTimeoutText, (value: string): void => { this.authTimeoutText = value; })
      this.input('首帧超时', '15000 ms', this.firstFrameTimeoutText, (value: string): void => { this.firstFrameTimeoutText = value; })
      Text('缩放模式').fontSize(12).fontColor(this.pal().text3).margin({ top: 4, bottom: 6 })
      Row() {
        Button('适应').layoutWeight(1).height(34).fontSize(12).borderRadius(8)
          .backgroundColor(this.scalingMode === 'fit' ? this.accentColor : this.pal().surface)
          .fontColor(this.scalingMode === 'fit' ? Color.White : this.pal().text2)
          .onClick((): void => { this.scalingMode = 'fit'; })
        Button('整数').layoutWeight(1).height(34).fontSize(12).margin({ left: 6 }).borderRadius(8)
          .backgroundColor(this.scalingMode === 'integer' ? this.accentColor : this.pal().surface)
          .fontColor(this.scalingMode === 'integer' ? Color.White : this.pal().text2)
          .onClick((): void => { this.scalingMode = 'integer'; })
        Button('原始').layoutWeight(1).height(34).fontSize(12).margin({ left: 6 }).borderRadius(8)
          .backgroundColor(this.scalingMode === 'one_to_one' ? this.accentColor : this.pal().surface)
          .fontColor(this.scalingMode === 'one_to_one' ? Color.White : this.pal().text2)
          .onClick((): void => { this.scalingMode = 'one_to_one'; })
        Button('平移').layoutWeight(1).height(34).fontSize(12).margin({ left: 6 }).borderRadius(8)
          .backgroundColor(this.scalingMode === 'pan' ? this.accentColor : this.pal().surface)
          .fontColor(this.scalingMode === 'pan' ? Color.White : this.pal().text2)
          .onClick((): void => { this.scalingMode = 'pan'; })
      }.width('100%').margin({ bottom: 8 })
      this.settingToggle('只读连接', '默认禁止键鼠控制，连接后仍可按会话能力开启', this.viewOnly,
        (value: boolean): void => { this.viewOnly = value; })
      Text('输入模式').fontSize(12).fontColor(this.pal().text3).margin({ top: 8, bottom: 6 })
      Row() {
        Button('触控板').layoutWeight(1).height(34).fontSize(12).borderRadius(8)
          .backgroundColor(this.controlMode === 0 ? this.accentColor : this.pal().surface)
          .fontColor(this.controlMode === 0 ? Color.White : this.pal().text2)
          .onClick((): void => { this.controlMode = 0; })
        Button('直接触控').layoutWeight(1).height(34).fontSize(12).margin({ left: 6 }).borderRadius(8)
          .backgroundColor(this.controlMode === 1 ? this.accentColor : this.pal().surface)
          .fontColor(this.controlMode === 1 ? Color.White : this.pal().text2)
          .onClick((): void => { this.controlMode = 1; })
        Button('键鼠').layoutWeight(1).height(34).fontSize(12).margin({ left: 6 }).borderRadius(8)
          .backgroundColor(this.controlMode === 2 ? this.accentColor : this.pal().surface)
          .fontColor(this.controlMode === 2 ? Color.White : this.pal().text2)
          .onClick((): void => { this.controlMode = 2; })
      }.width('100%').margin({ bottom: 8 })
      this.settingToggle('连接诊断', '在 VNC 会话中显示帧率、送显和停滞状态', this.showDiagnostics,
        (value: boolean): void => { this.showDiagnostics = value; })
      this.settingToggle('文本剪贴板', '只有 RFB ServerCutText/ClientCutText 能力通过后才启用', this.clipboardEnabled,
        (value: boolean): void => { this.clipboardEnabled = value; })
      Text('安全策略').fontSize(12).fontColor(this.pal().text3).margin({ top: 5, bottom: 6 })
      Row() {
        Button('仅安全').layoutWeight(1).height(34).fontSize(12).borderRadius(8)
          .backgroundColor(this.securityPolicy === 'secure_only' ? this.accentColor : this.pal().surface)
          .fontColor(this.securityPolicy === 'secure_only' ? Color.White : this.pal().text2)
          .onClick((): void => { this.securityPolicy = 'secure_only'; })
        Button('可信网络').layoutWeight(1).height(34).fontSize(12).margin({ left: 6 }).borderRadius(8)
          .backgroundColor(this.securityPolicy === 'trusted_network' ? this.accentColor : this.pal().surface)
          .fontColor(this.securityPolicy === 'trusted_network' ? Color.White : this.pal().text2)
          .onClick((): void => { this.securityPolicy = 'trusted_network'; })
        Button('允许明文').layoutWeight(1).height(34).fontSize(12).margin({ left: 6 }).borderRadius(8)
          .backgroundColor(this.securityPolicy === 'allow_plaintext' ? this.pal().danger : this.pal().surface)
          .fontColor(this.securityPolicy === 'allow_plaintext' ? Color.White : this.pal().text2)
          .onClick((): void => { this.securityPolicy = 'allow_plaintext'; })
      }.width('100%')
      Button('保存 VNC 设置').width('100%').height(42).margin({ top: 14 }).borderRadius(10)
        .backgroundColor(this.accentColor).fontColor(Color.White).onClick((): void => { this.saveSettings(); })
    }.width('100%').padding(16).borderRadius(18).backgroundColor(this.pal().card)
      .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
  }

  @Builder private hostCard(host: VncHostView) {
    Column() {
      Row() {
        Column() {
          Text(host.label).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
          Text(host.host + ':' + host.port.toString() + ' · ' + host.transport).fontSize(11).fontColor(this.pal().text3).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(host.passwordConfigured ? '密码已保存' : '未设置密码').fontSize(11)
          .fontColor(host.passwordConfigured ? this.pal().success : this.pal().text3)
        Button('连接').height(30).fontSize(11).borderRadius(7).backgroundColor(this.accentColor).fontColor(Color.White)
          .onClick((): void => { this.connectHost(host); })
        Button('编辑').height(30).fontSize(11).margin({ left: 6 }).borderRadius(7)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2)
          .onClick((): void => { this.openHostFlow(host); })
        Button('删除').height(30).fontSize(11).margin({ left: 6 }).borderRadius(7)
          .backgroundColor(this.pal().surface).fontColor(this.pal().danger).onClick((): void => { this.deleteHost(host); })
      }.width('100%')
    }.width('100%').padding(12).borderRadius(12).backgroundColor(this.pal().surface).margin({ bottom: 8 })
  }

  @Builder private hostCardSection() {
    Column() {
      Row() {
        Text('VNC 主机').fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text).layoutWeight(1)
        Button('添加').height(32).fontSize(12).borderRadius(8)
          .backgroundColor(this.accentColor).fontColor(Color.White)
          .onClick((): void => { this.openHostFlow(); })
      }.width('100%').margin({ bottom: 12 })
      Text('添加和编辑统一使用四步 VNC 流程；密码、显示偏好和连接方式不会与其他协议共用。')
        .fontSize(12).fontColor(this.pal().text3).lineHeight(18).width('100%').margin({ bottom: 10 })
      if (this.hosts.length === 0) {
        Text('暂无独立 VNC 主机。添加后不会写入 remotehosts。').fontSize(12).fontColor(this.pal().text3)
          .width('100%').padding({ top: 8, bottom: 4 })
      } else {
        ForEach(this.hosts, (host: VncHostView) => { this.hostCard(host); },
          (host: VncHostView): string => host.id + ':' + this.revision.toString())
      }
    }.width('100%').padding(16).borderRadius(18).backgroundColor(this.pal().card)
      .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
  }

  @Builder private gatewayCard(gateway: VncGatewayView) {
    Row() {
      Column() {
        Text(gateway.label).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        Text(gateway.host + ':' + gateway.port.toString() + ' · ' + gateway.transport + (gateway.tls ? ' · TLS' : '') +
          (gateway.tokenConfigured ? ' · 令牌已保存' : ''))
          .fontSize(11).fontColor(this.pal().text3).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Button('编辑').height(30).fontSize(11).borderRadius(7).backgroundColor(this.pal().surface).fontColor(this.pal().text2)
        .onClick((): void => { this.editGateway(gateway); })
      Button('删除').height(30).fontSize(11).borderRadius(7).backgroundColor(this.pal().surface).fontColor(this.pal().danger)
        .onClick((): void => { this.deleteGateway(gateway); })
    }.width('100%').padding(12).borderRadius(12).backgroundColor(this.pal().surface).margin({ bottom: 8 })
  }

  @Builder private gatewayCardSection() {
    Column() {
      Row() {
        Text('VNC Repeater / Gateway').fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.pal().text).layoutWeight(1)
        Button(this.gatewayFormVisible ? '收起' : '添加').height(32).fontSize(12).borderRadius(8)
          .backgroundColor(this.accentColor).fontColor(Color.White)
          .onClick((): void => { this.gatewayFormVisible = !this.gatewayFormVisible; })
      }.width('100%').margin({ bottom: 12 })
      if (this.gatewayFormVisible) {
        this.input('名称', '办公室 Repeater', this.gatewayLabel, (value: string): void => { this.gatewayLabel = value; })
        this.input('地址', 'relay.example.com', this.gatewayAddress, (value: string): void => { this.gatewayAddress = value; })
        this.input('端口', '5901', this.gatewayPortText, (value: string): void => { this.gatewayPortText = value; })
        this.input('WS 路径', '/vnc', this.gatewayPath, (value: string): void => { this.gatewayPath = value; })
        this.input('目标 ID', 'Repeater mode 2/12', this.gatewayTargetId, (value: string): void => { this.gatewayTargetId = value; })
        this.input('网关令牌', '仅版本化网关使用；留空保留原值', this.gatewayToken,
          (value: string): void => { this.gatewayToken = value; }, true)
        this.transportChoices(this.gatewayTransport, (value: VncTransport): void => { this.gatewayTransport = value; })
        this.settingToggle('TLS', 'WebSocket gateway 启用 TLS 时才会使用', this.gatewayTls,
          (value: boolean): void => { this.gatewayTls = value; })
        this.settingToggle('启用网关', '停用后不参与新的 VNC 连接', this.gatewayEnabled,
          (value: boolean): void => { this.gatewayEnabled = value; })
        Button(this.editingGatewayId === '' ? '保存网关' : '更新网关').width('100%').height(40).borderRadius(9)
          .backgroundColor(this.accentColor).fontColor(Color.White)
          .onClick((): void => { this.saveGateway(); }).margin({ bottom: 10 })
      }
      if (this.gateways.length === 0) {
        Text('暂无网关。Repeater 和 WebSocket 配置只属于 VNC，不会出现在 RustDesk 中继页。')
          .fontSize(12).fontColor(this.pal().text3).width('100%').padding({ top: 8, bottom: 4 })
      } else {
        ForEach(this.gateways, (gateway: VncGatewayView) => { this.gatewayCard(gateway); },
          (gateway: VncGatewayView): string => gateway.id + ':' + this.revision.toString())
      }
    }.width('100%').padding(16).borderRadius(18).backgroundColor(this.pal().card)
      .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
  }

  @Builder private gatewayDirectorySection() {
    Column() {
      this.cardTitle('VNC Gateway', 'Gateway 资源统一在第三页“中继服务器”管理')
      Text(this.gateways.length === 0 ? '暂无 VNC Gateway' :
        '当前有 ' + this.gateways.length.toString() + ' 个 VNC Gateway；RustDesk 中继与 VNC Gateway 分属不同 owner。')
        .fontSize(12).fontColor(this.pal().text3).lineHeight(19).width('100%').margin({ bottom: 12 })
      Button('打开第三页中继服务器').width('100%').height(42).borderRadius(10)
        .backgroundColor(this.accentColor).fontColor(Color.White)
        .onClick((): void => { this.openGatewayDirectory(); })
    }.width('100%').padding(16).borderRadius(18).backgroundColor(this.pal().card)
      .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
  }

  private openTrustManager(): void {
    this.showTrustManagerSheet = true;
  }

  private recheckTrust(trust: VncTrustView, selectedHostId: string): void {
    const directory: VncTrustDirectoryItem[] = buildVncTrustDirectory([trust], this.hostService.list(), this.gatewayService.list());
    const directoryItem: VncTrustDirectoryItem | undefined = directory[0];
    if (directoryItem === undefined || directoryItem.selectedHostId === '' ||
      directoryItem.selectedHostId !== selectedHostId || directoryItem.status !== 'current') {
      promptAction.showToast({ message: 'VNC endpoint 已变化或无法唯一定位，请从当前主机重新检查', duration: 2200 });
      return;
    }
    const host: VncHostView | null = this.hostService.find(selectedHostId);
    if (host === null) {
      promptAction.showToast({ message: '找不到当前账号下的 VNC endpoint，请先确认主机或 Gateway 仍存在', duration: 2200 });
      return;
    }
    this.showTrustManagerSheet = false;
    setTimeout((): void => {
      if (this.pageActive) {
        this.connectHost(host);
      }
    }, 360);
  }

  @Builder private trustCardSection() {
    Column() {
      this.cardTitle('VNC TLS 证书信任', '统一在数据安全中查看、忘记和重新检查')
      Text('主机与 Gateway 使用各自的 endpoint-bound 信任记录；云恢复只带候选和元数据，本机 confirmation marker 永不上传。')
        .fontSize(12).fontColor(this.pal().text3).lineHeight(19).width('100%').margin({ bottom: 12 })
      Button('打开 VNC TLS 证书信任管理').width('100%').height(42).borderRadius(10)
        .backgroundColor(this.accentColor).fontColor(Color.White)
        .onClick((): void => { this.openTrustManager(); })
    }.width('100%').padding(16).borderRadius(18).backgroundColor(this.pal().card)
      .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
  }

  build() {
    Column() {
      this.header()
      Scroll() {
        Column({ space: 14 }) {
          if (this.errorMessage !== '') {
            Text(this.errorMessage).fontSize(12).fontColor(this.pal().danger).fontFamily(this.font())
              .width('100%').padding(12).borderRadius(12).backgroundColor(this.pal().surface)
            if (this.pendingDefaultGatewayCleanupId !== '') {
              Button('重试清理默认 Gateway 引用').width('100%').height(38).borderRadius(9)
                .backgroundColor(this.pal().surface).fontColor(this.accentColor)
                .onClick((): void => { void this.retryDefaultGatewayCleanup(); })
            }
          }
          Text('主机、Gateway 与 trust 由 VNC owner 独立管理；默认设置请从主设置页的 VNC 分组进入。')
            .fontSize(12).fontColor(this.pal().text3).lineHeight(19).width('100%')
            .padding(12).borderRadius(12).backgroundColor(this.pal().surface)
          this.hostCardSection()
          this.gatewayDirectorySection()
          this.trustCardSection()
          Text('VNC trust：首次 TLS/VeNCrypt 指纹必须由用户确认；云端恢复的候选记录不会自动变成信任。')
            .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).width('100%').padding({ left: 4, right: 4, bottom: 20 })
        }.width('100%').padding({ left: 16, right: 16, bottom: 24 })
      }.layoutWeight(1).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
    }.width('100%').height('100%').backgroundColor(this.pal().bg)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      .bindSheet($$this.hostFlowVisible, this.hostFlowContent(), {
        height: SheetSize.LARGE,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        dragBar: this.breakpoint === 'sm',
        keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY,
        backgroundColor: this.pal().sheetBg,
        blurStyle: BlurStyle.NONE,
        showClose: false,
        maskColor: 'rgba(0,0,0,0.4)',
        onDisappear: (): void => { this.finishHostFlowDismiss(); }
      })
      .bindSheet($$this.showTrustManagerSheet, this.trustManagerSheet(), {
        height: SheetSize.LARGE,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        dragBar: this.breakpoint === 'sm',
        backgroundColor: this.pal().sheetBg,
        blurStyle: BlurStyle.NONE,
        showClose: false,
        maskColor: 'rgba(0,0,0,0.4)',
        onDisappear: (): void => { this.showTrustManagerSheet = false; }
      })
  }

  @Builder private trustManagerSheet() {
    VncCertificateTrustManagerSheet({
      onClose: (): void => { this.showTrustManagerSheet = false; },
      onRecheck: (trust: VncTrustView, hostId: string): void => { this.recheckTrust(trust, hostId); }
    })
  }
}
