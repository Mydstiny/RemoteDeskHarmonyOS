/**
 * VncSettingsPage — VNC 专属设置、主机和网关管理。
 *
 * 该页面不读取 HostSyncService、RemoteHost、RustDesk relay 或普通
 * usersettings。它只通过 VNC 自己的 service 访问 vncrecord overlay。
 */
import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { VncSettingsService } from '../services/VncSettingsService';
import { VncHostService, VncHostView } from '../services/VncHostService';
import { VncGatewayService, VncGatewayView } from '../services/VncGatewayService';
import { VncTrustService, VncTrustView } from '../services/VncTrustService';
import { DataCrypto } from '../services/DataCrypto';
import {
  VncSettingsValues,
  VncHostValues,
  VncGatewayValues,
  VncTransport,
  VncRepeaterMode,
  VncScalingMode,
  VncSecurityPolicy
} from '../services/VncModelPolicy';
import { VncCloudSyncScope, vncCloudSyncScopes } from '../services/VncCloudSyncSelectionPolicy';
import { Palette, buildDark, buildLight, AppTheme } from '../common/Theme';
import { VncAddFlow } from '../components/hostadd/VncAddFlow';
import { SETTINGS_PANEL_DISMISS_TO_LEAF_OPEN_MS } from '../services/SettingsSheetRoutePolicy';

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
  @State viewOnly: boolean = true;
  @State scalingMode: VncScalingMode = 'fit';
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
  @State trusts: VncTrustView[] = [];
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
  @State hostGatewayId: string = '';
  @State hostTransport: VncTransport = 'direct_tcp';
  @State hostRepeaterMode: VncRepeaterMode = 'mode12';
  @State hostViewOnly: boolean = true;
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
  @State cloudStatus: string = '本机数据加载中';
  @State cryptoReady: boolean = false;
  @State revision: number = 0;

  private readonly settings: VncSettingsService = VncSettingsService.getInstance();
  private readonly hostService: VncHostService = VncHostService.getInstance();
  private readonly gatewayService: VncGatewayService = VncGatewayService.getInstance();
  private readonly trustService: VncTrustService = VncTrustService.getInstance();
  private settingsUnsubscribe: (() => void) | null = null;
  private hostUnsubscribe: (() => void) | null = null;
  private gatewayUnsubscribe: (() => void) | null = null;
  private trustUnsubscribe: (() => void) | null = null;
  private cryptoUnsubscribe: (() => void) | null = null;
  private pageActive: boolean = false;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private font(): string { return AppTheme.fontFamily; }

  private redactedFingerprint(value: string): string {
    const normalized: string = value.trim().toLowerCase();
    if (normalized.length <= 12) { return normalized === '' ? '未知指纹' : '•••'; }
    return normalized.substring(0, 8) + '…' + normalized.substring(normalized.length - 8);
  }

  private topSafeHeightVp(): number {
    return this.topRectHeight > 0 ? px2vp(this.topRectHeight) : AppTheme.layout.statusBarH;
  }

  aboutToAppear(): void {
    this.pageActive = true;
    const context: common.Context = getContext(this) as common.Context;
    this.settings.init(context);
    this.hostService.init(context);
    this.gatewayService.init(context);
    this.trustService.init(context);
    this.bindListeners();
    this.load();
  }

  onPageShow(): void { this.load(); }

  aboutToDisappear(): void {
    this.pageActive = false;
    if (this.settingsUnsubscribe) { this.settingsUnsubscribe(); this.settingsUnsubscribe = null; }
    if (this.hostUnsubscribe) { this.hostUnsubscribe(); this.hostUnsubscribe = null; }
    if (this.gatewayUnsubscribe) { this.gatewayUnsubscribe(); this.gatewayUnsubscribe = null; }
    if (this.trustUnsubscribe) { this.trustUnsubscribe(); this.trustUnsubscribe = null; }
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
    if (this.trustUnsubscribe === null) {
      this.trustUnsubscribe = this.trustService.onChange((): void => {
        if (this.pageActive) { this.loadTrusts(); }
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
    this.scalingMode = values.scalingMode;
    this.clipboardEnabled = values.clipboardEnabled;
    this.securityPolicy = values.securityPolicy;
    this.defaultGatewayId = values.defaultGatewayId;
    this.repeaterMode = values.repeaterMode;
    this.syncPreferences = values.syncPreferences;
    this.syncHosts = values.syncHosts;
    this.syncGateways = values.syncGateways;
    this.syncSecrets = values.syncSecrets;
    this.syncTrust = values.syncTrust;
    this.cloudStatus = this.settings.cloudSyncStatus();
    this.cryptoReady = DataCrypto.getInstance().isReady();
    this.loadHosts();
    this.loadGateways();
    this.loadTrusts();
  }

  private loadHosts(): void {
    this.hosts = this.hostService.list();
    this.revision += 1;
  }

  private loadGateways(): void {
    this.gateways = this.gatewayService.list();
    this.revision += 1;
  }

  private loadTrusts(): void {
    this.trusts = this.trustService.list();
    this.revision += 1;
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
      scalingMode: this.scalingMode,
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
    if ((needsSecretConfirmation || needsTrustConfirmation) && !this.cryptoReady) {
      this.errorMessage = '启用 VNC 密钥或 trust 同步前，请先在主设置中解锁应用加密';
      return;
    }
    if (needsSecretConfirmation || needsTrustConfirmation) {
      promptAction.showDialog({
        title: '确认 VNC 敏感数据同步',
        message: needsSecretConfirmation
          ? 'VNC 密码和网关令牌会以绑定上下文的 AES-GCM 密文进入 vncrecord。新设备仍需重新确认 trust。'
          : 'trust 指纹只同步记录，不会自动信任新设备；每台新设备仍须人工确认。',
        buttons: [{ text: '取消', color: this.pal().text2 }, { text: '确认开启', color: this.accentColor }]
      }).then((result: Object): void => {
        const values: Record<string, number> = result as Record<string, number>;
        if (values['index'] === 1) { this.persistSettings(); }
      });
      return;
    }
    this.persistSettings();
  }

  private persistSettings(): void {
    const result = this.settings.save(this.settingsValues());
    this.errorMessage = result.ok ? '' : result.message;
    if (result.ok) {
      this.cloudStatus = this.settings.cloudSyncStatus();
      promptAction.showToast({ message: 'VNC 设置已保存', duration: 1600 });
    }
  }

  private hostValues(): VncHostValues {
    return {
      label: this.hostLabel,
      host: this.hostAddress,
      port: this.numberValue(this.hostPortText, 5900),
      username: this.hostUsername,
      gatewayId: this.hostGatewayId,
      transport: this.hostTransport,
      repeaterMode: this.hostRepeaterMode,
      viewOnly: this.hostViewOnly,
      scalingMode: this.hostScalingMode,
      clipboardEnabled: this.hostClipboardEnabled,
      securityPolicy: this.hostSecurityPolicy,
      tls: this.hostTls
    };
  }

  private saveHost(): void {
    if (this.hostPassword.length > 0 && !this.cryptoReady) {
      this.errorMessage = 'VNC 密码只允许在应用加密已解锁时保存';
      return;
    }
    const result = this.hostService.save(this.hostValues(), this.editingHostId, this.hostPassword);
    if (!result.ok) { this.errorMessage = result.message; return; }
    this.errorMessage = '';
    this.resetHostForm();
    promptAction.showToast({ message: 'VNC 主机已保存', duration: 1600 });
  }

  private saveGateway(): void {
    if (this.gatewayToken.length > 0 && !this.cryptoReady) {
      this.errorMessage = 'VNC 网关令牌只允许在应用加密已解锁时保存';
      return;
    }
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
    const result = this.gatewayService.save(values, this.editingGatewayId, this.gatewayToken);
    if (!result.ok) { this.errorMessage = result.message; return; }
    this.errorMessage = '';
    this.resetGatewayForm();
    promptAction.showToast({ message: 'VNC 网关已保存', duration: 1600 });
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
      if (values['index'] === 1 && this.gatewayService.remove(gateway.id)) { this.loadGateways(); }
    });
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
    this.hostViewOnly = this.viewOnly; this.hostScalingMode = this.scalingMode;
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
    this.hostGatewayId = host.gatewayId;
    this.hostTransport = host.transport;
    this.hostRepeaterMode = host.repeaterMode;
    this.hostViewOnly = host.viewOnly;
    this.hostScalingMode = host.scalingMode;
    this.hostClipboardEnabled = host.clipboardEnabled;
    this.hostSecurityPolicy = host.securityPolicy;
    this.hostTls = host.tls;
  }

  private connectHost(host: VncHostView): void {
    router.pushUrl({ url: 'pages/RemoteDesktop', params: { vncHostId: host.id } });
  }

  private openHostFlow(host: VncHostView | null = null): void {
    this.hostFlowHost = host;
    this.hostFlowEditingId = host === null ? '' : host.id;
    this.pendingHostFlowConnectId = '';
    this.pendingHostFlowGatewayDirectory = false;
    this.hostFlowVisible = true;
  }

  private saveHostFromFlow(values: VncHostValues, password: string, connectNow: boolean): void {
    if (!this.hostService.isReady()) {
      promptAction.showToast({ message: 'VNC 服务尚未完成云同步初始化，请稍后重试', duration: 2200 });
      return;
    }
    const result = this.hostService.save(values, this.hostFlowEditingId, password);
    if (!result.ok) {
      promptAction.showToast({ message: result.message || 'VNC 主机保存失败', duration: 2200 });
      return;
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
    if (this.hostService.find(id) !== null) {
      router.pushUrl({ url: 'pages/RemoteDesktop', params: { vncHostId: id } });
    }
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
      onSave: (values: VncHostValues, password: string, connectNow: boolean): void => {
        this.saveHostFromFlow(values, password, connectNow);
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

  private scopeChecked(scope: VncCloudSyncScope): boolean {
    const selected: VncCloudSyncScope[] = this.settings.selectedScopes();
    return selected.indexOf(scope) >= 0;
  }

  private scopeTitle(scope: VncCloudSyncScope): string {
    if (scope === 'settings') { return 'VNC 设置'; }
    if (scope === 'hosts') { return 'VNC 主机'; }
    if (scope === 'gateways') { return 'VNC 网关与 Repeater'; }
    if (scope === 'secrets') { return 'VNC 密码与令牌'; }
    return 'VNC trust 指纹';
  }

  private scopeDescription(scope: VncCloudSyncScope): string {
    if (scope === 'settings') { return '连接、显示和安全默认值'; }
    if (scope === 'hosts') { return '不包含明文密码'; }
    if (scope === 'gateways') { return '端点和配对能力，不包含令牌'; }
    if (scope === 'secrets') { return '仅 AES-GCM 密文，默认关闭'; }
    return '只同步指纹记录，新设备不自动信任';
  }

  private toggleScope(scope: VncCloudSyncScope): void {
    if (scope === 'secrets' && !this.cryptoReady) {
      this.errorMessage = '请先解锁应用加密，再开启 VNC 密钥同步';
      return;
    }
    const selected: VncCloudSyncScope[] = this.settings.selectedScopes();
    const next: VncCloudSyncScope[] = selected.indexOf(scope) >= 0
      ? selected.filter((item: VncCloudSyncScope): boolean => item !== scope)
      : selected.concat([scope]);
    if (scope === 'secrets') { this.syncSecrets = next.indexOf('secrets') >= 0; }
    if (scope === 'trust') { this.syncTrust = next.indexOf('trust') >= 0; }
    if (scope === 'settings') { this.syncPreferences = next.indexOf('settings') >= 0; }
    if (scope === 'hosts') { this.syncHosts = next.indexOf('hosts') >= 0; }
    if (scope === 'gateways') { this.syncGateways = next.indexOf('gateways') >= 0; }
    this.saveSettings();
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
      this.transportChoices(this.defaultTransport, (value: VncTransport): void => { this.defaultTransport = value; })
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

  @Builder private syncCard() {
    Column() {
      this.cardTitle('VNC 云同步', '唯一云表：vncrecord；本地覆盖表：vnclocalrecords')
      Text(this.cloudStatus).fontSize(12).fontColor(this.pal().text3).fontFamily(this.font()).margin({ bottom: 10 })
      ForEach(vncCloudSyncScopes(), (scope: VncCloudSyncScope) => {
        Row() {
          Checkbox().select(this.scopeChecked(scope)).selectedColor(this.accentColor)
            .onChange((): void => { this.toggleScope(scope); })
          Column() {
            Text(this.scopeTitle(scope)).fontSize(14).fontColor(this.pal().text).fontFamily(this.font())
            Text(this.scopeDescription(scope)).fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 3 })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 8 })
        }.width('100%').padding({ top: 8, bottom: 8 })
      }, (scope: VncCloudSyncScope): string => scope)
      this.settingToggle('设置同步', '同步开关状态也只属于 VNC', this.syncPreferences,
        (value: boolean): void => { this.syncPreferences = value; })
      Row() {
        Text('加密状态').fontSize(13).fontColor(this.pal().text2).layoutWeight(1)
        Text(this.cryptoReady ? '已解锁，可保存 VNC 密文' : '未解锁，密码/令牌不可保存')
          .fontSize(11).fontColor(this.cryptoReady ? this.pal().success : this.pal().danger)
      }.width('100%').margin({ top: 8 })
      Button('保存同步选择').width('100%').height(40).margin({ top: 12 }).borderRadius(10)
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
        Text(host.passwordConfigured ? '密码已加密' : '未设置密码').fontSize(11)
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

  @Builder private trustCardSection() {
    Column() {
      this.cardTitle('VNC trust', '仅显示已由用户确认的指纹；云恢复不会自动信任')
      if (this.trusts.length === 0) {
        Text('当前没有已确认的 TLS / VeNCrypt 指纹。首次连接时由 VNC 会话完成二次确认。')
          .fontSize(12).fontColor(this.pal().text3).width('100%')
      } else {
        ForEach(this.trusts, (trust: VncTrustView) => {
          Row() {
            Column() {
              Text(trust.ownerId).fontSize(13).fontColor(this.pal().text)
              Text(this.redactedFingerprint(trust.fingerprintSha256)).fontSize(10).fontColor(this.pal().text3).fontFamily('monospace')
                .maxLines(2).margin({ top: 3 })
              Text(trust.confirmed ? '本设备已确认' : '待本设备重新确认')
                .fontSize(10).fontColor(trust.confirmed ? this.pal().success : this.pal().danger)
                .margin({ top: 3 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button('忘记').height(30).fontSize(11).borderRadius(7).backgroundColor(this.pal().surface)
              .fontColor(this.pal().danger).onClick((): void => { this.trustService.remove(trust.id); })
          }.width('100%').padding(10).borderRadius(10).backgroundColor(this.pal().surface).margin({ bottom: 7 })
        }, (trust: VncTrustView): string => trust.id + ':' + this.revision.toString())
      }
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
          }
          Text('主机、Gateway 与 trust 由 VNC owner 独立管理；默认设置和云同步范围请从主设置页的 VNC 分组进入。')
            .fontSize(12).fontColor(this.pal().text3).lineHeight(19).width('100%')
            .padding(12).borderRadius(12).backgroundColor(this.pal().surface)
          this.hostCardSection()
          this.gatewayDirectorySection()
          this.trustCardSection()
          Text('VNC trust：首次 TLS/VeNCrypt 指纹必须由用户确认；云端恢复的 trust 记录不会自动变成信任。')
            .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).width('100%').padding({ left: 4, right: 4, bottom: 20 })
        }.width('100%').padding({ left: 16, right: 16, bottom: 24 })
      }.layoutWeight(1).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
    }.width('100%').height('100%').backgroundColor(this.pal().bg)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      .bindSheet($$this.hostFlowVisible, this.hostFlowContent(), {
        height: SheetSize.FIT_CONTENT,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        dragBar: this.breakpoint === 'sm',
        backgroundColor: this.pal().sheetBg,
        blurStyle: BlurStyle.NONE,
        showClose: false,
        maskColor: 'rgba(0,0,0,0.4)',
        onDisappear: (): void => { this.finishHostFlowDismiss(); }
      })
  }
}
