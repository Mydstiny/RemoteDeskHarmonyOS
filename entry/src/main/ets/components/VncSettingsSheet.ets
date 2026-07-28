import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { DataCrypto } from '../services/DataCrypto';
import { VncSettingsService } from '../services/VncSettingsService';
import { VncTrustService, VncTrustView } from '../services/VncTrustService';
import { VncCloudSyncScope, vncCloudSyncScopes } from '../services/VncCloudSyncSelectionPolicy';
import {
  VncSettingsValues,
  VncTransport,
  VncScalingMode,
  VncSecurityPolicy,
  defaultVncSettings
} from '../services/VncModelPolicy';
import {
  SETTINGS_SHEET_VNC_CLOUD_SYNC,
  SETTINGS_SHEET_VNC_CONNECTION,
  SETTINGS_SHEET_VNC_DISPLAY,
  SETTINGS_SHEET_VNC_GATEWAY,
  SETTINGS_SHEET_VNC_HOSTS,
  SETTINGS_SHEET_VNC_SECURITY,
  SETTINGS_SHEET_VNC_TIMEOUT,
  SETTINGS_SHEET_VNC_TRUST
} from '../services/SettingsSheetRoutePolicy';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { protocolIcon } from '../services/ProtocolIconPolicy';

/**
 * A leaf VNC settings surface hosted by HostListPage's single bindSheet.
 *
 * This component owns only VNC settings and trust services. Host and gateway
 * management deliberately returns to their owning directories through the
 * callbacks instead of nesting another sheet or touching RustDesk state.
 */
@Component
export struct VncSettingsSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop mode: number = SETTINGS_SHEET_VNC_CONNECTION;
  onClose: () => void = (): void => {};
  onOpenHostManager: () => void = (): void => {};
  onOpenGatewayManager: () => void = (): void => {};
  onSaved: () => void = (): void => {};
  onDirtyChanged: (dirty: boolean) => void = (_dirty: boolean): void => {};

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
  @State syncPreferences: boolean = true;
  @State syncHosts: boolean = true;
  @State syncGateways: boolean = true;
  @State syncSecrets: boolean = false;
  @State syncTrust: boolean = false;
  @State trusts: VncTrustView[] = [];
  @State cryptoReady: boolean = false;
  @State errorText: string = '';
  @State revision: number = 0;

  private readonly settings: VncSettingsService = VncSettingsService.getInstance();
  private readonly trustService: VncTrustService = VncTrustService.getInstance();
  private settingsUnsubscribe: (() => void) | null = null;
  private trustUnsubscribe: (() => void) | null = null;
  private cryptoUnsubscribe: (() => void) | null = null;
  private dirty: boolean = false;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  aboutToAppear(): void {
    const context: common.Context = getContext(this) as common.Context;
    this.settings.init(context);
    this.trustService.init(context);
    this.settingsUnsubscribe = this.settings.onChange((): void => { this.load(); });
    this.trustUnsubscribe = this.trustService.onChange((): void => { this.loadTrusts(); });
    this.cryptoUnsubscribe = DataCrypto.getInstance().onStateChange((_ready: boolean, _configured: boolean): void => {
      this.cryptoReady = DataCrypto.getInstance().isReady();
    });
    this.load();
  }

  aboutToDisappear(): void {
    if (this.settingsUnsubscribe) { this.settingsUnsubscribe(); this.settingsUnsubscribe = null; }
    if (this.trustUnsubscribe) { this.trustUnsubscribe(); this.trustUnsubscribe = null; }
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
    this.scalingMode = values.scalingMode;
    this.clipboardEnabled = values.clipboardEnabled;
    this.securityPolicy = values.securityPolicy;
    this.defaultGatewayId = values.defaultGatewayId;
    this.syncPreferences = values.syncPreferences;
    this.syncHosts = values.syncHosts;
    this.syncGateways = values.syncGateways;
    this.syncSecrets = values.syncSecrets;
    this.syncTrust = values.syncTrust;
    this.cryptoReady = DataCrypto.getInstance().isReady();
    this.loadTrusts();
    this.dirty = false;
    this.onDirtyChanged(false);
  }

  private markDirty(): void {
    if (!this.dirty) {
      this.dirty = true;
      this.onDirtyChanged(true);
    }
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
    const defaults: VncSettingsValues = defaultVncSettings();
    return {
      defaultTransport: this.defaultTransport,
      defaultPort: this.numberValue(this.defaultPortText, defaults.defaultPort),
      connectTimeoutMs: this.numberValue(this.connectTimeoutText, defaults.connectTimeoutMs),
      authTimeoutMs: this.numberValue(this.authTimeoutText, defaults.authTimeoutMs),
      firstFrameTimeoutMs: this.numberValue(this.firstFrameTimeoutText, defaults.firstFrameTimeoutMs),
      viewOnly: this.viewOnly,
      scalingMode: this.scalingMode,
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

  private redactedFingerprint(value: string): string {
    const normalized: string = value.trim().toLowerCase();
    if (normalized.length <= 12) { return normalized === '' ? '未知指纹' : '•••'; }
    return normalized.substring(0, 8) + '…' + normalized.substring(normalized.length - 8);
  }

  private save(): void {
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
          ? 'VNC 密码和网关令牌会以绑定上下文的 AES-GCM 密文进入 vncrecord。'
          : crypto.isSetupComplete()
            ? '应用加密已锁定。现有 AES-GCM 密文会保留；新凭据可关闭“记住密码”后临时使用。'
            : '应用加密未启用。明确选择记住密码的 VNC 凭据可能以未加密形式进入 vncrecord，请确认风险。';
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
        if (dialogResult['index'] === 1) { this.persistSettings(); }
        else { this.load(); }
      });
      return;
    }
    this.persistSettings();
  }

  private needsDangerousConfirmation(needsPlaintextConfirmation: boolean): boolean {
    return needsPlaintextConfirmation;
  }

  private persistSettings(): void {
    const result = this.settings.save(this.settingsValues());
    if (!result.ok) {
      this.errorText = result.message;
      return;
    }
    this.dirty = false;
    this.onDirtyChanged(false);
    promptAction.showToast({ message: 'VNC 设置已保存', duration: 1500 });
    this.onSaved();
  }

  private scopeChecked(scope: VncCloudSyncScope): boolean {
    if (scope === 'settings') { return this.syncPreferences; }
    if (scope === 'hosts') { return this.syncHosts; }
    if (scope === 'gateways') { return this.syncGateways; }
    if (scope === 'secrets') { return this.syncSecrets; }
    return this.syncTrust;
  }

  private setScope(scope: VncCloudSyncScope, selected: boolean): void {
    if (scope === 'settings') { this.syncPreferences = selected; }
    if (scope === 'hosts') { this.syncHosts = selected; }
    if (scope === 'gateways') { this.syncGateways = selected; }
    if (scope === 'secrets') { this.syncSecrets = selected; }
    if (scope === 'trust') { this.syncTrust = selected; }
    this.errorText = '';
    this.markDirty();
  }

  private scopeTitle(scope: VncCloudSyncScope): string {
    if (scope === 'settings') { return 'VNC 默认设置'; }
    if (scope === 'hosts') { return 'VNC 主机'; }
    if (scope === 'gateways') { return 'VNC Gateway'; }
    if (scope === 'secrets') { return '密码与令牌'; }
    return 'trust 指纹';
  }

  private scopeDetail(scope: VncCloudSyncScope): string {
    if (scope === 'settings') { return '连接、显示和安全默认值'; }
    if (scope === 'hosts') { return '主机地址和非敏感连接配置'; }
    if (scope === 'gateways') { return 'Repeater/Gateway 地址和能力'; }
    if (scope === 'secrets') { return '默认关闭；按“记住密码”策略保存，明文需再次确认'; }
    return '云恢复后仍需在本设备重新确认';
  }

  private title(): string {
    if (this.mode === SETTINGS_SHEET_VNC_CONNECTION) { return '连接方式与默认端口'; }
    if (this.mode === SETTINGS_SHEET_VNC_TIMEOUT) { return '超时与连接行为'; }
    if (this.mode === SETTINGS_SHEET_VNC_DISPLAY) { return '显示与交互'; }
    if (this.mode === SETTINGS_SHEET_VNC_SECURITY) { return '安全策略与 TLS'; }
    if (this.mode === SETTINGS_SHEET_VNC_TRUST) { return 'Trust / 证书管理'; }
    if (this.mode === SETTINGS_SHEET_VNC_CLOUD_SYNC) { return 'VNC 云同步范围'; }
    if (this.mode === SETTINGS_SHEET_VNC_HOSTS) { return 'VNC 主机管理'; }
    return 'VNC Gateway 管理';
  }

  private subtitle(): string {
    if (this.mode === SETTINGS_SHEET_VNC_CONNECTION) { return '直连 TCP 或已保存的 UltraVNC Repeater mode12'; }
    if (this.mode === SETTINGS_SHEET_VNC_TIMEOUT) { return '只影响 VNC 会话，不读取其他协议的超时'; }
    if (this.mode === SETTINGS_SHEET_VNC_DISPLAY) { return '默认只读，剪贴板需要显式开启'; }
    if (this.mode === SETTINGS_SHEET_VNC_SECURITY) { return '安全策略不替代服务器能力协商'; }
    if (this.mode === SETTINGS_SHEET_VNC_TRUST) { return 'VNC trust 独立于 RDP 证书和 SSH 主机指纹'; }
    if (this.mode === SETTINGS_SHEET_VNC_CLOUD_SYNC) { return '物理表仍只有 vncrecord，逻辑范围独立选择'; }
    if (this.mode === SETTINGS_SHEET_VNC_HOSTS) { return '主机记录不会进入 remotehosts'; }
    return 'VNC Gateway 与 RustDesk 中继分属不同 owner';
  }

  @Builder private header() {
    Row() {
      SymbolGlyph(protocolIcon('vnc')).fontSize(24).fontColor([this.accentColor])
      Column() {
        Text(this.title()).fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        Text(this.subtitle()).fontSize(11).fontColor(this.pal().text3).margin({ top: 4 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
      SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
        .width(36).height(36).onClick((): void => { this.onClose(); })
    }.width('100%').padding({ left: 22, right: 18, top: 20, bottom: 16 })
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

  @Builder private choice(title: string, selected: boolean, onClick: () => void, marginLeft: number = 0) {
    Button(title).layoutWeight(1).height(36).fontSize(12).borderRadius(9)
      .backgroundColor(selected ? this.accentColor : this.pal().surface)
      .fontColor(selected ? Color.White : this.pal().text2).margin({ left: marginLeft }).onClick(onClick)
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
        this.choice('TCP 直连', this.defaultTransport === 'direct_tcp', (): void => {
          this.defaultTransport = 'direct_tcp'; this.markDirty();
        })
        this.choice('Repeater mode12', this.defaultTransport === 'ultravnc_repeater', (): void => {
          this.defaultTransport = 'ultravnc_repeater'; this.markDirty();
        }, 8)
      }.width('100%').margin({ bottom: 12 })
      this.field('默认端口', '5900', this.defaultPortText, (value: string): void => {
        this.defaultPortText = value; this.markDirty();
      })
      Text('WebSocket Gateway 和 SSH tunnel 仍处于 fail-closed，部署并验证服务端契约后才会开放。')
        .fontSize(11).fontColor(this.pal().text3).lineHeight(18).width('100%').margin({ top: 2, bottom: 12 })
      Button('保存').width('100%').height(42).borderRadius(10).backgroundColor(this.accentColor)
        .fontColor(Color.White).onClick((): void => { this.save(); })
    }.width('100%')
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
      Button('保存').width('100%').height(42).borderRadius(10).backgroundColor(this.accentColor)
        .fontColor(Color.White).onClick((): void => { this.save(); })
    }.width('100%')
  }

  @Builder private displayContent() {
    Column() {
      this.toggle('只读连接', '默认禁止 VNC 键盘和鼠标输入', this.viewOnly,
        (value: boolean): void => { this.viewOnly = value; this.markDirty(); })
      Text('缩放模式').fontSize(12).fontColor(this.pal().text3).margin({ top: 10, bottom: 7 })
      Row() {
        this.choice('适应', this.scalingMode === 'fit', (): void => { this.scalingMode = 'fit'; this.markDirty(); })
        this.choice('整数', this.scalingMode === 'integer', (): void => {
          this.scalingMode = 'integer'; this.markDirty();
        }, 6)
        this.choice('原始', this.scalingMode === 'one_to_one', (): void => {
          this.scalingMode = 'one_to_one'; this.markDirty();
        }, 6)
        this.choice('平移', this.scalingMode === 'pan', (): void => {
          this.scalingMode = 'pan'; this.markDirty();
        }, 6)
      }.width('100%').margin({ bottom: 10 })
      this.toggle('文本剪贴板', '仅在 RFB 剪贴板能力协商成功后生效，默认关闭', this.clipboardEnabled,
        (value: boolean): void => { this.clipboardEnabled = value; this.markDirty(); })
      Button('保存').width('100%').height(42).borderRadius(10).backgroundColor(this.accentColor)
        .fontColor(Color.White).margin({ top: 10 }).onClick((): void => { this.save(); })
    }.width('100%')
  }

  @Builder private securityContent() {
    Column() {
      Text('连接安全策略').fontSize(12).fontColor(this.pal().text3).margin({ bottom: 7 })
      Row() {
        this.choice('仅安全', this.securityPolicy === 'secure_only', (): void => {
          this.securityPolicy = 'secure_only'; this.markDirty();
        })
        this.choice('可信网络', this.securityPolicy === 'trusted_network', (): void => {
          this.securityPolicy = 'trusted_network'; this.markDirty();
        }, 7)
        this.choice('允许明文', this.securityPolicy === 'allow_plaintext', (): void => {
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
      Button('保存').width('100%').height(42).borderRadius(10).backgroundColor(this.accentColor)
        .fontColor(Color.White).onClick((): void => { this.save(); })
    }.width('100%')
  }

  @Builder private trustContent() {
    Column() {
      Text('trust 只表示本设备已确认的服务器指纹。云恢复记录不会自动转为信任。')
        .fontSize(12).fontColor(this.pal().text3).lineHeight(19).width('100%').margin({ bottom: 12 })
      if (this.trusts.length === 0) {
        Text('暂无已确认的 VNC TLS / VeNCrypt 指纹').fontSize(13).fontColor(this.pal().text3)
          .width('100%').textAlign(TextAlign.Center).padding({ top: 20, bottom: 20 })
      } else {
        ForEach(this.trusts, (trust: VncTrustView) => {
          Row() {
            Column() {
              Text(trust.ownerId).fontSize(13).fontColor(this.pal().text)
              Text(this.redactedFingerprint(trust.fingerprintSha256)).fontSize(10).fontColor(this.pal().text3)
                .maxLines(2).margin({ top: 3 })
              Text(trust.confirmed ? '本设备已确认' : '待本设备重新确认')
                .fontSize(10).fontColor(trust.confirmed ? this.pal().success : this.pal().danger)
                .margin({ top: 3 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button('忘记').height(30).fontSize(11).borderRadius(8).backgroundColor(this.pal().surface)
              .fontColor(this.pal().danger).onClick((): void => { this.trustService.remove(trust.id); })
          }.width('100%').padding(10).borderRadius(10).backgroundColor(this.pal().surface).margin({ bottom: 7 })
        }, (trust: VncTrustView): string => trust.id + ':' + this.revision.toString())
      }
    }.width('100%')
  }

  @Builder private cloudContent() {
    Column() {
      Text('物理云表固定为 vncrecord；以下是该表内的逻辑 scope。关闭某个 scope 不会删除共享云行。')
        .fontSize(12).fontColor(this.pal().text3).lineHeight(19).width('100%').margin({ bottom: 10 })
      ForEach(vncCloudSyncScopes(), (scope: VncCloudSyncScope) => {
        Row() {
          Checkbox().select(this.scopeChecked(scope)).selectedColor(this.accentColor)
            .onChange((selected: boolean): void => { this.setScope(scope, selected); })
          Column() {
            Text(this.scopeTitle(scope)).fontSize(14).fontColor(this.pal().text)
            Text(this.scopeDetail(scope)).fontSize(11).fontColor(this.pal().text3).margin({ top: 3 })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 9 })
        }.width('100%').padding(10).borderRadius(10).backgroundColor(this.pal().surface).margin({ bottom: 7 })
      }, (scope: VncCloudSyncScope): string => scope)
      Text(DataCrypto.getInstance().isReady()
        ? '加密已解锁，可按选择保存 VNC 密文'
        : (DataCrypto.getInstance().isSetupComplete()
          ? '应用加密已锁定：现有密文保持 opaque；新凭据可关闭记住密码后临时使用'
          : '应用加密未启用：VNC 元数据可同步；明文凭据只有在明确确认风险后才会保存/同步'))
        .fontSize(11)
        .fontColor(DataCrypto.getInstance().isReady() ? this.pal().success : this.pal().text3)
        .margin({ top: 4, bottom: 12 })
      Button('保存同步范围').width('100%').height(42).borderRadius(10).backgroundColor(this.accentColor)
        .fontColor(Color.White).onClick((): void => { this.save(); })
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

  build() {
    Column() {
      this.header()
      Scroll() {
        Column() {
          if (this.mode === SETTINGS_SHEET_VNC_CONNECTION) {
            this.connectionContent()
          } else if (this.mode === SETTINGS_SHEET_VNC_TIMEOUT) {
            this.timeoutContent()
          } else if (this.mode === SETTINGS_SHEET_VNC_DISPLAY) {
            this.displayContent()
          } else if (this.mode === SETTINGS_SHEET_VNC_SECURITY) {
            this.securityContent()
          } else if (this.mode === SETTINGS_SHEET_VNC_TRUST) {
            this.trustContent()
          } else if (this.mode === SETTINGS_SHEET_VNC_CLOUD_SYNC) {
            this.cloudContent()
          } else if (this.mode === SETTINGS_SHEET_VNC_HOSTS) {
            this.directoryContent(true)
          } else {
            this.directoryContent(false)
          }
          if (this.errorText !== '') {
            Text(this.errorText).fontSize(12).fontColor(this.pal().danger).lineHeight(18)
              .width('100%').margin({ top: 12 })
          }
        }.width('100%').padding({ left: 22, right: 22, bottom: 26 })
      }.scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring).width('100%')
    }.width('100%').constraintSize({ maxWidth: 620, maxHeight: 620 })
      .backgroundColor(this.pal().bg)
  }
}
