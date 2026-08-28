import { Binding, promptAction, UIUtils } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { DataCrypto } from '../services/DataCrypto';
import { VncSettingsService } from '../services/VncSettingsService';
import { VncGatewayService, VncGatewayView } from '../services/VncGatewayService';
import { isSelectableVncDefaultGateway, VncSelectableGateway } from '../services/VncHostDefaultsPolicy';
import {
  VncSettingsValues,
  VncTransport,
  VncScalingMode,
  VncSecurityPolicy,
  VncDisplayScaleMode,
  VncImageQualityPreset,
  VncPreferredEncoding,
  VncColorDepth,
  VncLocalCursorMode,
  defaultVncSettings
} from '../services/VncModelPolicy';
import {
  SETTINGS_SHEET_VNC_CLIPBOARD,
  SETTINGS_SHEET_VNC_CONNECTION,
  SETTINGS_SHEET_VNC_DISPLAY,
  SETTINGS_SHEET_VNC_GATEWAY,
  SETTINGS_SHEET_VNC_HOSTS,
  SETTINGS_SHEET_VNC_INPUT,
  SETTINGS_SHEET_VNC_PERFORMANCE,
  SETTINGS_SHEET_VNC_SECURITY,
  SETTINGS_SHEET_VNC_TIMEOUT,
  SETTINGS_SHEET_VNC_TRUST
} from '../services/SettingsSheetRoutePolicy';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { VncSheetScaffold } from './vnc/VncSheetScaffold';
import { VNC_REVERSE_WHEEL_KEY } from '../services/RemoteWheelPreferencePolicy';

/**
 * A leaf VNC settings surface hosted by HostListPage's single bindSheet.
 *
 * This component owns only VNC settings. Trust records are managed by the
 * shared certificate manager opened through the callback below. Host and gateway
 * management deliberately returns to their owning directories through the
 * callbacks instead of nesting another sheet or touching RustDesk state.
 */
@Component
export struct VncSettingsSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @StorageLink(VNC_REVERSE_WHEEL_KEY) vncReverseWheelPreference: boolean = false;
  @Prop mode: number = SETTINGS_SHEET_VNC_CONNECTION;
  onClose: () => void = (): void => {};
  onOpenHostManager: () => void = (): void => {};
  onOpenGatewayManager: () => void = (): void => {};
  onOpenTrustManager: () => void = (): void => {};
  onSaved: () => void = (): void => {};
  onReverseWheelSaved: (reverse: boolean) => boolean = (_reverse: boolean): boolean => true;
  onDirtyChanged: (dirty: boolean) => void = (_dirty: boolean): void => {};

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
  @State syncPreferences: boolean = true;
  @State syncHosts: boolean = true;
  @State syncGateways: boolean = true;
  @State syncSecrets: boolean = false;
  @State syncTrust: boolean = false;
  @State gateways: VncGatewayView[] = [];
  @State cryptoReady: boolean = false;
  @State errorText: string = '';
  @State dirty: boolean = false;
  @State saving: boolean = false;

  private readonly settings: VncSettingsService = VncSettingsService.getInstance();
  private readonly gatewayService: VncGatewayService = VncGatewayService.getInstance();
  private settingsUnsubscribe: (() => void) | null = null;
  private gatewayUnsubscribe: (() => void) | null = null;
  private cryptoUnsubscribe: (() => void) | null = null;
  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  aboutToAppear(): void {
    const context: common.Context = getContext(this) as common.Context;
    this.settings.init(context);
    this.gatewayService.init(context);
    this.settingsUnsubscribe = this.settings.onChange((): void => { this.load(); });
    this.gatewayUnsubscribe = this.gatewayService.onChange((): void => { this.loadGateways(); });
    this.cryptoUnsubscribe = DataCrypto.getInstance().onStateChange((_ready: boolean, _configured: boolean): void => {
      this.cryptoReady = DataCrypto.getInstance().isReady();
    });
    this.load();
    this.loadGateways();
  }

  aboutToDisappear(): void {
    if (this.settingsUnsubscribe) { this.settingsUnsubscribe(); this.settingsUnsubscribe = null; }
    if (this.gatewayUnsubscribe) { this.gatewayUnsubscribe(); this.gatewayUnsubscribe = null; }
    if (this.cryptoUnsubscribe) { this.cryptoUnsubscribe(); this.cryptoUnsubscribe = null; }
  }

  private load(): void {
    const values: VncSettingsValues = this.settings.get();
    this.defaultTransport = values.defaultTransport === 'direct_tcp' ||
      values.defaultTransport === 'ultravnc_repeater' ? values.defaultTransport : 'direct_tcp';
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
    this.reverseWheel = this.vncReverseWheelPreference;
    this.swapMouseButtons = values.swapMouseButtons;
    this.diagnosticsExpanded = values.diagnosticsExpanded;
    this.diagnosticsRefreshMs = values.diagnosticsRefreshMs;
    this.diagnosticsMetricMask = values.diagnosticsMetricMask;
    this.clipboardEnabled = values.clipboardEnabled;
    this.securityPolicy = values.securityPolicy;
    this.defaultGatewayId = values.defaultGatewayId;
    this.syncPreferences = values.syncPreferences;
    this.syncHosts = values.syncHosts;
    this.syncGateways = values.syncGateways;
    this.syncSecrets = values.syncSecrets;
    this.syncTrust = values.syncTrust;
    this.cryptoReady = DataCrypto.getInstance().isReady();
    this.dirty = false;
    this.onDirtyChanged(false);
  }

  private markDirty(): void {
    if (!this.dirty) {
      this.dirty = true;
      this.onDirtyChanged(true);
    }
  }

  private loadGateways(): void {
    this.gateways = this.gatewayService.list();
  }

  private selectableGateways(): VncGatewayView[] {
    return this.gateways.filter((gateway: VncGatewayView): boolean => {
      const selectable: VncSelectableGateway = {
        id: gateway.id, userId: gateway.userId, transport: gateway.transport,
        repeaterMode: gateway.repeaterMode, enabled: gateway.enabled
      };
      return isSelectableVncDefaultGateway(selectable, this.gatewayService.currentUserId());
    });
  }

  private numberValue(text: string, fallback: number): number {
    const value: number = Number(text);
    return Number.isFinite(value) ? Math.floor(value) : fallback;
  }

  private settingsValues(): VncSettingsValues {
    const defaults: VncSettingsValues = defaultVncSettings();
    return {
      defaultTransport: this.defaultTransport,
      defaultPort: this.numberValue(this.defaultPortText, defaults.defaultPort),
      connectTimeoutMs: this.numberValue(this.connectTimeoutText, defaults.connectTimeoutMs),
      authTimeoutMs: this.numberValue(this.authTimeoutText, defaults.authTimeoutMs),
      firstFrameTimeoutMs: this.numberValue(this.firstFrameTimeoutText, defaults.firstFrameTimeoutMs),
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
      repeaterMode: 'mode12',
      syncPreferences: this.syncPreferences,
      syncHosts: this.syncHosts,
      syncGateways: this.syncGateways,
      syncSecrets: this.syncSecrets,
      syncTrust: this.syncTrust
    };
  }

  private save(): void {
    if (!this.dirty || this.saving) { return; }
    this.errorText = '';
    const current: VncSettingsValues = this.settings.get();
    const needsSecretConfirmation: boolean = this.syncSecrets && !current.syncSecrets;
    const needsTrustConfirmation: boolean = this.syncTrust && !current.syncTrust;
    const needsPlaintextConfirmation: boolean = this.securityPolicy === 'allow_plaintext' &&
      current.securityPolicy !== 'allow_plaintext';
    if (needsSecretConfirmation || needsTrustConfirmation || needsPlaintextConfirmation) {
      let message: string = '';
      if (needsSecretConfirmation) {
        const crypto: DataCrypto = DataCrypto.getInstance();
        message += crypto.isReady()
          ? 'VNC 密码和网关令牌会以绑定上下文的 AES-GCM 密文进入 vncrecordv2。'
          : crypto.isSetupComplete()
            ? '应用加密已锁定。现有 AES-GCM 密文会保留；新凭据可关闭“记住密码”后临时使用。'
            : '应用加密未启用。明确选择记住密码的 VNC 凭据可能以未加密形式进入 vncrecordv2，请确认风险。';
      }
      if (needsTrustConfirmation) {
        message += (message === '' ? '' : '\n') + 'trust 指纹只同步记录，不会自动信任新设备。';
      }
      if (needsPlaintextConfirmation) {
        message += (message === '' ? '' : '\n') + '允许明文连接可能暴露密码和屏幕内容，请确认当前网络可信。';
      }
      promptAction.showDialog({
        title: '确认 VNC 安全设置',
        message,
        buttons: [{ text: '取消', color: this.pal().text2 }, { text: '确认保存', color: this.needsDangerousConfirmation(needsPlaintextConfirmation) ? this.pal().danger : this.accentColor }]
      }).then((result: Object): void => {
        const dialogResult: Record<string, number> = result as Record<string, number>;
        if (dialogResult['index'] === 1) {
          void this.persistSettings();
        }
        else { this.load(); }
      });
      return;
    }
    void this.persistSettings();
  }

  private needsDangerousConfirmation(needsPlaintextConfirmation: boolean): boolean {
    return needsPlaintextConfirmation;
  }

  private async persistSettings(): Promise<void> {
    this.saving = true;
    try {
      // VncSettingsService emits synchronously and load() replaces this draft,
      // so capture the requested device-local value before saving. Keep the
      // legacy payload field unchanged: it is migration input for old builds,
      // not the authoritative per-device preference.
      const requestedReverseWheel: boolean = this.reverseWheel;
      const values: VncSettingsValues = this.settingsValues();
      values.reverseWheel = this.settings.get().reverseWheel;
      const result = await this.settings.save(values);
      if (!result.ok) {
        this.errorText = result.message;
        return;
      }
      if (!this.onReverseWheelSaved(requestedReverseWheel)) {
        this.errorText = 'VNC 设置已保存，但滚轮方向偏好写入失败，请重试';
        this.reverseWheel = requestedReverseWheel;
        this.dirty = true;
        this.onDirtyChanged(true);
        return;
      }
      this.vncReverseWheelPreference = requestedReverseWheel;
      this.reverseWheel = requestedReverseWheel;
      this.dirty = false;
      this.onDirtyChanged(false);
      promptAction.showToast({ message: 'VNC 设置已保存', duration: 1500 });
      this.onSaved();
    } finally {
      this.saving = false;
    }
  }

  private title(): string {
    if (this.mode === SETTINGS_SHEET_VNC_CONNECTION) { return '连接默认值'; }
    if (this.mode === SETTINGS_SHEET_VNC_TIMEOUT) { return '超时与连接行为'; }
    if (this.mode === SETTINGS_SHEET_VNC_DISPLAY) { return '显示与画面'; }
    if (this.mode === SETTINGS_SHEET_VNC_INPUT) { return '输入与光标'; }
    if (this.mode === SETTINGS_SHEET_VNC_PERFORMANCE) { return '性能监视看板'; }
    if (this.mode === SETTINGS_SHEET_VNC_CLIPBOARD) { return 'VNC 剪贴板'; }
    if (this.mode === SETTINGS_SHEET_VNC_SECURITY) { return '安全策略与 TLS'; }
    if (this.mode === SETTINGS_SHEET_VNC_TRUST) { return 'Trust / 证书管理'; }
    if (this.mode === SETTINGS_SHEET_VNC_HOSTS) { return 'VNC 主机管理'; }
    return 'VNC Gateway 管理';
  }

  private subtitle(): string {
    if (this.mode === SETTINGS_SHEET_VNC_CONNECTION) { return 'VNC 独立传输与默认端口'; }
    if (this.mode === SETTINGS_SHEET_VNC_TIMEOUT) { return '只影响 VNC 会话，不读取其他协议的超时'; }
    if (this.mode === SETTINGS_SHEET_VNC_DISPLAY) { return '本地缩放与 native 实际画面能力'; }
    if (this.mode === SETTINGS_SHEET_VNC_INPUT) { return '鼠标与键盘默认可用，可按需切换只读'; }
    if (this.mode === SETTINGS_SHEET_VNC_PERFORMANCE) { return '连接内显示帧率、送显和停滞状态'; }
    if (this.mode === SETTINGS_SHEET_VNC_CLIPBOARD) { return '只控制 VNC 文本剪贴板通道'; }
    if (this.mode === SETTINGS_SHEET_VNC_SECURITY) { return '安全策略不替代服务器能力协商'; }
    if (this.mode === SETTINGS_SHEET_VNC_TRUST) { return 'VNC trust 独立于 RDP 证书和 SSH 主机指纹'; }
    if (this.mode === SETTINGS_SHEET_VNC_HOSTS) { return '主机记录不会进入 remotehosts'; }
    return 'VNC Gateway 与 RustDesk 中继分属不同 owner';
  }

  @Builder private field(label: string, placeholder: string, value: string, onChange: (value: string) => void) {
    Column() {
      Text(label).fontSize(12).fontColor(this.pal().text2).margin({ bottom: 5 })
      TextInput({ placeholder, text: value }).height(40).fontSize(13)
        .backgroundColor(this.pal().surface).fontColor(this.pal().text)
        .placeholderColor(this.pal().text3).borderRadius(9).padding({ left: 11, right: 11 })
        .onChange(onChange)
    }.width('100%').margin({ bottom: 10 })
  }

  @Builder private choice(title: string, selected: Binding<boolean>, onClick: () => void,
    marginLeft: number = 0) {
    Button(title).layoutWeight(1).height(36).fontSize(12).borderRadius(9)
      .backgroundColor(selected.value ? this.accentColor : this.pal().surface)
      .fontColor(selected.value ? Color.White : this.pal().text2)
      .margin({ left: marginLeft }).onClick(onClick)
  }

  @Builder private toggle(title: string, detail: string, value: boolean, onChange: (value: boolean) => void) {
    Row() {
      Column() {
        Text(title).fontSize(14).fontColor(this.pal().text)
        Text(detail).fontSize(11).fontColor(this.pal().text3).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: value }).selectedColor(this.accentColor)
        .onChange(onChange).scale({ x: 0.86, y: 0.86 })
    }.width('100%').padding({ top: 8, bottom: 8 })
  }

  @Builder private connectionContent() {
    Column() {
      Text('默认传输').fontSize(12).fontColor(this.pal().text3).margin({ bottom: 7 })
      Row() {
        this.choice('TCP 直连', UIUtils.makeBinding<boolean>(
          (): boolean => this.defaultTransport === 'direct_tcp'), (): void => {
          this.defaultTransport = 'direct_tcp'; this.markDirty();
        })
        this.choice('Repeater mode12', UIUtils.makeBinding<boolean>(
          (): boolean => this.defaultTransport === 'ultravnc_repeater'), (): void => {
          this.defaultTransport = 'ultravnc_repeater'; this.markDirty();
        }, 8)
      }.width('100%').margin({ bottom: 12 })
      this.field('默认端口', '5900', this.defaultPortText, (value: string): void => {
        this.defaultPortText = value; this.markDirty();
      })
      if (this.defaultTransport === 'ultravnc_repeater') {
        this.defaultGatewayChoices()
      }
      Text('WebSocket Gateway 和 SSH tunnel 仍处于 fail-closed，部署并验证服务端契约后才会开放。')
        .fontSize(11).fontColor(this.pal().text3).lineHeight(18).width('100%').margin({ top: 2 })
    }.width('100%')
  }

  @Builder private defaultGatewayChoices() {
    Column() {
      Text('默认 Gateway').fontSize(12).fontColor(this.pal().text3).margin({ top: 2, bottom: 7 })
      if (this.selectableGateways().length === 0) {
        Text('当前账号没有可用的 mode12 Gateway；请先添加并启用 Gateway。')
          .fontSize(11).fontColor(this.pal().danger).lineHeight(17).margin({ bottom: 8 })
        Button('打开 Gateway 管理').width('100%').height(38).borderRadius(9)
          .backgroundColor(this.pal().surface).fontColor(this.accentColor)
          .onClick((): void => { this.onOpenGatewayManager(); })
      } else {
        ForEach(this.selectableGateways(), (gateway: VncGatewayView) => {
          Row() {
            Column() {
              Text(gateway.label === '' ? gateway.host : gateway.label)
                .fontSize(13).fontColor(this.pal().text)
              Text(gateway.host + ':' + gateway.port.toString() + ' · mode12')
                .fontSize(10).fontColor(this.pal().text3).margin({ top: 2 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            if (this.defaultGatewayId === gateway.id) {
              SymbolGlyph($r('sys.symbol.checkmark')).fontSize(17).fontColor([this.accentColor])
            }
          }.width('100%').padding(10).borderRadius(9)
            .backgroundColor(this.defaultGatewayId === gateway.id ? this.pal().surface : this.pal().card)
            .margin({ bottom: 6 })
            .onClick((): void => {
              this.defaultGatewayId = gateway.id;
              this.markDirty();
            })
        }, (gateway: VncGatewayView): string => gateway.id + ':' + gateway.updatedAt.toString())
      }
    }.width('100%').margin({ bottom: 10 })
  }

  @Builder private timeoutContent() {
    Column() {
      this.field('连接超时（ms）', '10000', this.connectTimeoutText, (value: string): void => {
        this.connectTimeoutText = value; this.markDirty();
      })
      this.field('认证超时（ms）', '15000', this.authTimeoutText, (value: string): void => {
        this.authTimeoutText = value; this.markDirty();
      })
      this.field('首帧超时（ms）', '15000', this.firstFrameTimeoutText, (value: string): void => {
        this.firstFrameTimeoutText = value; this.markDirty();
      })
      Text('最小值为 1000ms。连接失败只结束当前 VNC 会话，不改变其他协议的重试策略。')
        .fontSize(11).fontColor(this.pal().text3).lineHeight(18).margin({ bottom: 12 })
    }.width('100%')
  }

  @Builder private displayContent() {
    Column() {
      Text('本地缩放').fontSize(12).fontColor(this.pal().text3).margin({ bottom: 7 })
      Row() {
        this.choice('适应窗口', UIUtils.makeBinding<boolean>(
          (): boolean => this.displayScaleMode === 'fit'), (): void => {
          this.displayScaleMode = 'fit'; this.scalingMode = 'fit'; this.markDirty();
        })
        this.choice('100%', UIUtils.makeBinding<boolean>(
          (): boolean => this.displayScaleMode === '100'), (): void => {
          this.displayScaleMode = '100'; this.scalingMode = 'one_to_one'; this.markDirty();
        }, 6)
      }.width('100%').margin({ bottom: 6 })
      Row() {
        this.choice('整数倍率', UIUtils.makeBinding<boolean>(
          (): boolean => this.displayScaleMode === 'integer'), (): void => {
          this.displayScaleMode = 'integer'; this.scalingMode = 'integer'; this.markDirty();
        })
        this.choice('自定义', UIUtils.makeBinding<boolean>(
          (): boolean => this.displayScaleMode === 'custom'), (): void => {
          this.displayScaleMode = 'custom'; this.scalingMode = 'fit'; this.markDirty();
        }, 6)
      }.width('100%').margin({ bottom: 8 })
      if (this.displayScaleMode === 'custom') {
        Row() {
          Text('缩放比例').fontSize(13).fontColor(this.pal().text2).layoutWeight(1)
          Text(this.customScalePercent.toString() + '%').fontSize(13).fontColor(this.accentColor)
        }.width('100%')
        Slider({ style: SliderStyle.OutSet, value: this.customScalePercent, min: 50, max: 300, step: 5 })
          .selectedColor(this.accentColor)
          .onChange((value: number): void => {
            this.customScalePercent = Math.round(value); this.markDirty();
          })
          .width('100%').margin({ bottom: 8 })
      }
      Row() {
        Column() {
          Text('远端分辨率').fontSize(13).fontColor(this.pal().text2)
          Text('连接后由 VNC 服务器报告，实际值显示在性能看板')
            .fontSize(10).fontColor(this.pal().text3).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text('自动').fontSize(12).fontColor(this.pal().text3)
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(8).backgroundColor(this.pal().surface)
      }.width('100%').margin({ bottom: 8 })
      Text('macOS 标准 VNC 会报告当前远端分辨率，但不能由 Viewer 强制改变。请在 Mac“系统设置 → 显示器”中调整远端分辨率。')
        .fontSize(11).fontColor(this.pal().text3).lineHeight(18).width('100%').margin({ bottom: 12 })

      Text('画质预设').fontSize(12).fontColor(this.pal().text3).margin({ bottom: 7 })
      Row() {
        this.choice('极速', UIUtils.makeBinding<boolean>(
          (): boolean => this.imageQualityPreset === 'speed'), (): void => {
          this.imageQualityPreset = 'speed'; this.markDirty();
        })
        this.choice('均衡', UIUtils.makeBinding<boolean>(
          (): boolean => this.imageQualityPreset === 'balanced'), (): void => {
          this.imageQualityPreset = 'balanced'; this.markDirty();
        }, 6)
        this.choice('质量', UIUtils.makeBinding<boolean>(
          (): boolean => this.imageQualityPreset === 'quality'), (): void => {
          this.imageQualityPreset = 'quality'; this.markDirty();
        }, 6)
      }.width('100%').margin({ bottom: 10 })
      Text('色深为“自动”时，极速和 Retina 级均衡会优先使用 8 位色；自动或显式 8 位连接 RFB 3.3 服务端（包括 macOS 屏幕共享）时会回退到兼容的 16 位色，避免首帧断连。质量或显式 16/32 位保持原画质。')
        .fontSize(11).fontColor(this.pal().text3).lineHeight(18).width('100%').margin({ bottom: 10 })

      Text('编码偏好').fontSize(12).fontColor(this.pal().text3).margin({ bottom: 7 })
      Row() {
        this.choice('自动', UIUtils.makeBinding<boolean>(
          (): boolean => this.preferredEncoding === 'auto'), (): void => {
          this.preferredEncoding = 'auto'; this.markDirty();
        })
        this.choice('ZRLE', UIUtils.makeBinding<boolean>(
          (): boolean => this.preferredEncoding === 'zrle'), (): void => {
          this.preferredEncoding = 'zrle'; this.markDirty();
        }, 6)
        this.choice('RAW', UIUtils.makeBinding<boolean>(
          (): boolean => this.preferredEncoding === 'raw'), (): void => {
          this.preferredEncoding = 'raw'; this.markDirty();
        }, 6)
      }.width('100%').margin({ bottom: 10 })
      Text('自动模式优先请求 ZRLE，并在服务器不支持时自动回退 RAW/CopyRect；RAW 适合诊断兼容问题。Tight 尚未开放。')
        .fontSize(11).fontColor(this.pal().text3).lineHeight(18).width('100%').margin({ bottom: 12 })

      Text('色深').fontSize(12).fontColor(this.pal().text3).margin({ bottom: 7 })
      Row() {
        this.choice('自动', UIUtils.makeBinding<boolean>(
          (): boolean => this.colorDepth === 'auto'), (): void => {
          this.colorDepth = 'auto'; this.markDirty();
        })
        this.choice('32 位', UIUtils.makeBinding<boolean>(
          (): boolean => this.colorDepth === '32'), (): void => {
          this.colorDepth = '32'; this.markDirty();
        }, 6)
        this.choice('16 位', UIUtils.makeBinding<boolean>(
          (): boolean => this.colorDepth === '16'), (): void => {
          this.colorDepth = '16'; this.markDirty();
        }, 6)
        this.choice('8 位', UIUtils.makeBinding<boolean>(
          (): boolean => this.colorDepth === '8'), (): void => {
          this.colorDepth = '8'; this.markDirty();
        }, 6)
      }.width('100%').margin({ bottom: 10 })

      Text('帧率上限').fontSize(12).fontColor(this.pal().text3).margin({ bottom: 7 })
      Row() {
        this.choice('15', UIUtils.makeBinding<boolean>(
          (): boolean => this.frameRateLimit === 15), (): void => {
          this.frameRateLimit = 15; this.markDirty();
        })
        this.choice('30', UIUtils.makeBinding<boolean>(
          (): boolean => this.frameRateLimit === 30), (): void => {
          this.frameRateLimit = 30; this.markDirty();
        }, 6)
        this.choice('60', UIUtils.makeBinding<boolean>(
          (): boolean => this.frameRateLimit === 60), (): void => {
          this.frameRateLimit = 60; this.markDirty();
        }, 6)
        this.choice('不限', UIUtils.makeBinding<boolean>(
          (): boolean => this.frameRateLimit === 0), (): void => {
          this.frameRateLimit = 0; this.markDirty();
        }, 6)
      }.width('100%').margin({ bottom: 10 })
    }.width('100%')
  }

  @Builder private inputContent() {
    Column() {
      this.toggle('只读连接', '开启后禁止 VNC 键盘、鼠标和触控输入', this.viewOnly,
        (value: boolean): void => { this.viewOnly = value; this.markDirty(); })
      Text('默认控制模式').fontSize(12).fontColor(this.pal().text3).margin({ top: 10, bottom: 7 })
      Row() {
        this.choice('触控板', UIUtils.makeBinding<boolean>(
          (): boolean => this.controlMode === 0), (): void => {
          this.controlMode = 0; this.markDirty();
        })
        this.choice('直接触控', UIUtils.makeBinding<boolean>(
          (): boolean => this.controlMode === 1), (): void => {
          this.controlMode = 1; this.markDirty();
        }, 6)
        this.choice('键盘鼠标', UIUtils.makeBinding<boolean>(
          (): boolean => this.controlMode === 2), (): void => {
          this.controlMode = 2; this.markDirty();
        }, 6)
      }.width('100%').margin({ bottom: 12 })

      Text('本地光标').fontSize(12).fontColor(this.pal().text3).margin({ bottom: 7 })
      Row() {
        this.choice('自动', UIUtils.makeBinding<boolean>(
          (): boolean => this.localCursorMode === 'auto'), (): void => {
          this.localCursorMode = 'auto'; this.markDirty();
        })
        this.choice('箭头', UIUtils.makeBinding<boolean>(
          (): boolean => this.localCursorMode === 'arrow'), (): void => {
          this.localCursorMode = 'arrow'; this.markDirty();
        }, 6)
        this.choice('圆点', UIUtils.makeBinding<boolean>(
          (): boolean => this.localCursorMode === 'circle'), (): void => {
          this.localCursorMode = 'circle'; this.markDirty();
        }, 6)
        this.choice('隐藏', UIUtils.makeBinding<boolean>(
          (): boolean => this.localCursorMode === 'hidden'), (): void => {
          this.localCursorMode = 'hidden'; this.markDirty();
        }, 6)
      }.width('100%').margin({ bottom: 10 })
      Text('服务器没有下发光标形状时，“隐藏”会安全回退为圆点，避免鼠标位置完全不可见。')
        .fontSize(11).fontColor(this.pal().text3).lineHeight(18).width('100%').margin({ bottom: 10 })

      Row() {
        Text('触控板速度').fontSize(13).fontColor(this.pal().text2).layoutWeight(1)
        Text(this.touchpadSpeed.toString() + '%').fontSize(13).fontColor(this.accentColor)
      }.width('100%')
      Slider({ style: SliderStyle.OutSet, value: this.touchpadSpeed, min: 50, max: 200, step: 5 })
        .selectedColor(this.accentColor)
        .onChange((value: number): void => {
          this.touchpadSpeed = Math.round(value); this.markDirty();
        })
        .width('100%').margin({ bottom: 8 })
      this.toggle('反转滚轮方向', '与“显示与交互 > 远程滚轮方向”中的 VNC 共用', this.reverseWheel,
        (value: boolean): void => { this.reverseWheel = value; this.markDirty(); })
      this.toggle('交换左右键', '左键与右键互换，只作用于 VNC', this.swapMouseButtons,
        (value: boolean): void => { this.swapMouseButtons = value; this.markDirty(); })
    }.width('100%')
  }

  @Builder private performanceContent() {
    Column() {
      this.toggle('显示性能监视看板', '连接后显示帧率、送显、停滞、分辨率和编码实况', this.showDiagnostics,
        (value: boolean): void => { this.showDiagnostics = value; this.markDirty(); })
      this.toggle('连接后默认展开', '关闭时仅显示可拖动的 FPS 胶囊', this.diagnosticsExpanded,
        (value: boolean): void => { this.diagnosticsExpanded = value; this.markDirty(); })
      Text('采样频率').fontSize(12).fontColor(this.pal().text3).margin({ top: 10, bottom: 7 })
      Row() {
        this.choice('250 ms', UIUtils.makeBinding<boolean>(
          (): boolean => this.diagnosticsRefreshMs === 250), (): void => {
          this.diagnosticsRefreshMs = 250; this.markDirty();
        })
        this.choice('500 ms', UIUtils.makeBinding<boolean>(
          (): boolean => this.diagnosticsRefreshMs === 500), (): void => {
          this.diagnosticsRefreshMs = 500; this.markDirty();
        }, 6)
        this.choice('1000 ms', UIUtils.makeBinding<boolean>(
          (): boolean => this.diagnosticsRefreshMs === 1000), (): void => {
          this.diagnosticsRefreshMs = 1000; this.markDirty();
        }, 6)
      }.width('100%').margin({ bottom: 12 })
      Text('指标范围').fontSize(12).fontColor(this.pal().text3).margin({ bottom: 7 })
      Row() {
        this.choice('核心指标', UIUtils.makeBinding<boolean>(
          (): boolean => this.diagnosticsMetricMask === 31), (): void => {
          this.diagnosticsMetricMask = 31; this.markDirty();
        })
        this.choice('完整指标', UIUtils.makeBinding<boolean>(
          (): boolean => this.diagnosticsMetricMask !== 31), (): void => {
          this.diagnosticsMetricMask = 63; this.markDirty();
        }, 6)
      }.width('100%').margin({ bottom: 10 })
      Text('性能看板使用 VNC 独立开关和采样频率，不读取 RustDesk Pro 看板设置。')
        .fontSize(11).fontColor(this.pal().text3).lineHeight(18).width('100%').margin({ bottom: 12 })
    }.width('100%')
  }

  @Builder private clipboardContent() {
    Column() {
      this.toggle('文本剪贴板', '在 RFB 剪贴板能力可用时同步纯文本，默认关闭', this.clipboardEnabled,
        (value: boolean): void => { this.clipboardEnabled = value; this.markDirty(); })
      Text('该开关不启用文件粘贴，不读取 RustDesk 或 RDP 的剪贴板设置。服务器不支持剪贴板时会保持关闭。')
        .fontSize(11).fontColor(this.pal().text3).lineHeight(18).width('100%').margin({ top: 8, bottom: 14 })
    }.width('100%')
  }

  @Builder private securityContent() {
    Column() {
      Text('连接安全策略').fontSize(12).fontColor(this.pal().text3).margin({ bottom: 7 })
      Row() {
        this.choice('仅安全', UIUtils.makeBinding<boolean>(
          (): boolean => this.securityPolicy === 'secure_only'), (): void => {
          this.securityPolicy = 'secure_only'; this.markDirty();
        })
        this.choice('可信网络', UIUtils.makeBinding<boolean>(
          (): boolean => this.securityPolicy === 'trusted_network'), (): void => {
          this.securityPolicy = 'trusted_network'; this.markDirty();
        }, 7)
        this.choice('允许明文', UIUtils.makeBinding<boolean>(
          (): boolean => this.securityPolicy === 'allow_plaintext'), (): void => {
          this.securityPolicy = 'allow_plaintext'; this.markDirty();
        }, 7)
      }.width('100%').margin({ bottom: 12 })
      Text(this.securityPolicy === 'secure_only'
        ? '仅允许已协商 TLS/安全安全类型；未满足时连接失败。'
        : (this.securityPolicy === 'trusted_network'
          ? '允许可信局域网使用明文，但仍建议优先启用 TLS。'
          : '允许明文只适合受控网络，连接卡片会明确标出风险。'))
        .fontSize(12).fontColor(this.securityPolicy === 'allow_plaintext' ? this.pal().danger : this.pal().text3)
        .lineHeight(19).width('100%').margin({ bottom: 12 })
    }.width('100%')
  }

  @Builder private trustContent() {
    Column() {
      Text('VNC TLS 证书信任由“数据安全”中的统一管理器维护。云恢复记录不会自动转为本机信任。')
        .fontSize(12).fontColor(this.pal().text3).lineHeight(19).width('100%').margin({ bottom: 12 })
      Button('打开 VNC TLS 证书信任管理').width('100%').height(42).borderRadius(10)
        .backgroundColor(this.accentColor).fontColor(Color.White)
        .onClick((): void => { this.onOpenTrustManager(); })
      Text('同一管理器也可从主设置“数据安全”进入；不会创建第二份可变 trust 列表。')
        .fontSize(11).fontColor(this.pal().text3).lineHeight(18).width('100%').margin({ top: 10 })
    }.width('100%')
  }

  @Builder private directoryContent(hosts: boolean) {
    Column() {
      Text(hosts ? '主机编辑、删除和连接仍由 VNC host owner 管理。' :
        'Gateway 编辑、删除和连通性测试统一放在第三页中继服务器目录。')
        .fontSize(13).fontColor(this.pal().text2).lineHeight(20).width('100%').margin({ bottom: 14 })
      Button(hosts ? '打开 VNC 主机目录' : '打开中继服务器目录').width('100%').height(44)
        .borderRadius(11).backgroundColor(this.accentColor).fontColor(Color.White)
        .onClick((): void => { if (hosts) { this.onOpenHostManager(); } else { this.onOpenGatewayManager(); } })
      Text(hosts ? '不会写入 remotehosts' : '不会写入 rustdeskrelays；卡片会标出 VNC Gateway')
        .fontSize(11).fontColor(this.pal().text3).margin({ top: 10 })
    }.width('100%')
  }

  private hasSaveAction(): boolean {
    return this.mode === SETTINGS_SHEET_VNC_CONNECTION ||
      this.mode === SETTINGS_SHEET_VNC_TIMEOUT ||
      this.mode === SETTINGS_SHEET_VNC_DISPLAY ||
      this.mode === SETTINGS_SHEET_VNC_INPUT ||
      this.mode === SETTINGS_SHEET_VNC_PERFORMANCE ||
      this.mode === SETTINGS_SHEET_VNC_CLIPBOARD ||
      this.mode === SETTINGS_SHEET_VNC_SECURITY;
  }

  @Builder private sheetBody() {
    Column() {
      if (this.mode === SETTINGS_SHEET_VNC_CONNECTION) {
        this.connectionContent()
      } else if (this.mode === SETTINGS_SHEET_VNC_TIMEOUT) {
        this.timeoutContent()
      } else if (this.mode === SETTINGS_SHEET_VNC_DISPLAY) {
        this.displayContent()
      } else if (this.mode === SETTINGS_SHEET_VNC_INPUT) {
        this.inputContent()
      } else if (this.mode === SETTINGS_SHEET_VNC_PERFORMANCE) {
        this.performanceContent()
      } else if (this.mode === SETTINGS_SHEET_VNC_CLIPBOARD) {
        this.clipboardContent()
      } else if (this.mode === SETTINGS_SHEET_VNC_SECURITY) {
        this.securityContent()
      } else if (this.mode === SETTINGS_SHEET_VNC_TRUST) {
        this.trustContent()
      } else if (this.mode === SETTINGS_SHEET_VNC_HOSTS) {
        this.directoryContent(true)
      } else {
        this.directoryContent(false)
      }
      if (this.errorText !== '') {
        Text(this.errorText).fontSize(12).fontColor(this.pal().danger).lineHeight(18)
          .width('100%').margin({ top: 12 })
      }
    }.width('100%')
  }

  @Builder private saveFooter() {
    Button(this.saving ? '保存中…' : '保存')
      .width('100%').height(44).borderRadius(11)
      .backgroundColor(this.dirty && !this.saving ? this.accentColor : this.pal().surface)
      .fontColor(this.dirty && !this.saving ? Color.White : this.pal().text3)
      .enabled(this.dirty && !this.saving)
      .onClick((): void => { this.save(); })
  }

  build() {
    VncSheetScaffold({
      title: this.title(),
      subtitle: this.subtitle(),
      showFooter: this.hasSaveAction(),
      onLeadingAction: (): void => { this.onClose(); },
      contentBuilder: (): void => { this.sheetBody(); },
      footerBuilder: (): void => { this.saveFooter(); }
    })
  }
}
