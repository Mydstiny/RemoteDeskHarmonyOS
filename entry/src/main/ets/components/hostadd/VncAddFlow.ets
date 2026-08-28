/**
 * VNC host wizard shared by the modern and classic host FAB paths.
 *
 * The modern wizard uses two user-facing steps: endpoint, then access/control
 * with a non-sensitive summary. Passwords never appear in the summary and no
 * username field is exposed because the current native viewer uses VNC
 * password authentication.
 */
import { promptAction } from '@kit.ArkUI';
import { Palette, buildDark, buildLight } from '../../common/Theme';
import { DataCrypto } from '../../services/DataCrypto';
import {
  VncHostValues,
  VncTransport,
  VncRepeaterMode,
  VncScalingMode,
  VncSecurityPolicy,
  validateVncHost
} from '../../services/VncModelPolicy';
import { VncSettingsService } from '../../services/VncSettingsService';
import { VncGatewayView } from '../../services/VncGatewayService';
import { resolveVncHostDefaults, VncSelectableGateway } from '../../services/VncHostDefaultsPolicy';
import { VncHostService, VncHostView } from '../../services/VncHostService';
import { SecretPresentationStore } from '../../services/SecretPresentationPolicy';
import { SecretEditMutationKind } from '../../services/SecretEditMutationPolicy';
import {
  VncSecretEditDecision,
  vncSecretEditDecision
} from '../../services/VncSecretEditPolicy';
import { vncGatewayAvailability } from '../../services/VncGatewayProtocolPolicy';
import { protocolIcon } from '../../services/ProtocolIconPolicy';
import {
  VNC_HOST_ADD_STEP_COUNT,
  nextVncFlowStep,
  previousVncFlowStep
} from '../../services/VncHostFlowPolicy';
import { VncSheetScaffold } from '../vnc/VncSheetScaffold';

@Component
export struct VncAddFlow {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @StorageLink('remoteDesktopBgFlag') @Watch('onBackgroundStateChange')
  appInBackground: boolean = false;
  @Prop gateways: VncGatewayView[] = [];
  @Prop initialHost: VncHostView | null = null;
  @Prop editingId: string = '';
  @Prop fitContent: boolean = false;
  onBackToProtocols: () => void = (): void => {};
  onOpenSettings: () => void = (): void => {};
  onSave: (values: VncHostValues, password: string, connectNow: boolean,
    plainStorageConfirmed: boolean, passwordMutation: SecretEditMutationKind) => void =
    (_values: VncHostValues, _password: string, _connectNow: boolean,
      _plainStorageConfirmed: boolean, _passwordMutation: SecretEditMutationKind): void => {};

  @State step: number = 0;
  @State transport: VncTransport = 'direct_tcp';
  @State repeaterMode: VncRepeaterMode = 'mode12';
  @State label: string = '';
  @State directAddress: string = '';
  @State repeaterTargetId: string = '';
  @State portText: string = '5900';
  @State password: string = '';
  @State passwordConfigured: boolean = false;
  @State passwordChanged: boolean = false;
  private passwordFromStoredProjection: boolean = false;
  @State rememberPassword: boolean = false;
  @State gatewayId: string = '';
  @State tls: boolean = true;
  @State viewOnly: boolean = false;
  @State displayOverrideEnabled: boolean = false;
  @State scalingMode: VncScalingMode = 'fit';
  @State clipboardEnabled: boolean = false;
  @State securityPolicy: VncSecurityPolicy = 'secure_only';
  @State errorText: string = '';
  private readonly settings: VncSettingsService = VncSettingsService.getInstance();
  private readonly hosts: VncHostService = VncHostService.getInstance();
  private readonly secretPresentation: SecretPresentationStore = SecretPresentationStore.getInstance();
  private cryptoStateUnsubscribe: (() => void) | null = null;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  aboutToAppear(): void {
    if (this.cryptoStateUnsubscribe === null) {
      this.cryptoStateUnsubscribe = DataCrypto.getInstance().onStateChange(
        (ready: boolean, _configured: boolean): void => {
          this.onCryptoStateChange(ready);
        });
    }
    const defaults = this.settings.get();
    const selectableGateways: VncSelectableGateway[] = this.gateways.map(
      (gateway: VncGatewayView): VncSelectableGateway => ({
        id: gateway.id, userId: gateway.userId, transport: gateway.transport,
        repeaterMode: gateway.repeaterMode, enabled: gateway.enabled
      }));
    const scopeUserId: string = this.gateways.length > 0 ? this.gateways[0].userId : '';
    const resolved = resolveVncHostDefaults(defaults, scopeUserId, selectableGateways);
    this.transport = resolved.transport;
    this.gatewayId = resolved.gatewayId;
    this.portText = resolved.port.toString();
    this.repeaterMode = resolved.repeaterMode;
    this.viewOnly = defaults.viewOnly;
    this.displayOverrideEnabled = false;
    this.scalingMode = defaults.scalingMode;
    this.clipboardEnabled = defaults.clipboardEnabled;
    this.securityPolicy = defaults.securityPolicy;
    this.tls = defaults.securityPolicy === 'secure_only';
    this.passwordConfigured = false;
    this.passwordChanged = false;
    this.passwordFromStoredProjection = false;
    this.password = '';
    if (this.transport === 'ultravnc_repeater') {
      const gateway: VncGatewayView | undefined = this.selectedGateway();
      if (gateway !== undefined) {
        this.portText = gateway.port.toString();
        if (this.repeaterTargetId.trim() === '' && gateway.targetId.trim() !== '') {
          this.repeaterTargetId = gateway.targetId;
        }
      }
    }
    const host: VncHostView | null = this.initialHost;
    if (host !== null) {
      this.label = host.label;
      this.transport = host.transport;
      if (host.transport === 'direct_tcp') { this.directAddress = host.host; }
      else { this.repeaterTargetId = host.host; }
      this.portText = host.port.toString();
      this.rememberPassword = host.rememberPassword;
      this.passwordConfigured = host.passwordConfigured;
      if (!this.passwordHidden()) {
        this.password = this.hosts.passwordFor(host.id);
        this.passwordFromStoredProjection = this.password.length > 0;
      }
      this.gatewayId = host.gatewayId;
      this.repeaterMode = host.repeaterMode;
      this.viewOnly = host.viewOnly;
      this.displayOverrideEnabled = host.displayOverrideEnabled;
      this.scalingMode = host.scalingMode;
      this.clipboardEnabled = host.clipboardEnabled;
      this.securityPolicy = host.securityPolicy;
      this.tls = host.tls;
      const gateway: VncGatewayView | undefined = this.selectedGateway();
      if (host.transport === 'ultravnc_repeater' && gateway !== undefined) {
        this.portText = gateway.port.toString();
      }
    }
  }

  aboutToDisappear(): void {
    if (this.cryptoStateUnsubscribe !== null) {
      this.cryptoStateUnsubscribe();
      this.cryptoStateUnsubscribe = null;
    }
  }

  private selectedGateway(): VncGatewayView | undefined {
    return this.gateways.find((gateway: VncGatewayView): boolean => gateway.id === this.gatewayId);
  }

  private endpointAddress(): string {
    return this.transport === 'direct_tcp' ? this.directAddress : this.repeaterTargetId;
  }

  private redactedValue(value: string): string {
    const normalized: string = value.trim();
    if (normalized.length <= 4) { return normalized === '' ? '未填写' : '•••'; }
    return normalized.substring(0, 2) + '…' + normalized.substring(normalized.length - 2);
  }

  private passwordHidden(): boolean {
    const crypto: DataCrypto = DataCrypto.getInstance();
    return this.secretPresentation.isHidden('vnc_host_password',
      crypto.isSetupComplete() && !crypto.isReady());
  }

  private onBackgroundStateChange(): void {
    if (!this.passwordFromStoredProjection) { return; }
    if (this.appInBackground) {
      this.password = '';
      return;
    }
    this.restoreStoredPasswordProjection();
  }

  private onCryptoStateChange(ready: boolean): void {
    if (!this.passwordFromStoredProjection) { return; }
    if (!ready) {
      this.password = '';
      return;
    }
    this.restoreStoredPasswordProjection();
  }

  private restoreStoredPasswordProjection(): void {
    const host: VncHostView | null = this.initialHost;
    this.password = host === null || this.passwordHidden() ? '' :
      this.hosts.passwordFor(host.id);
  }

  private passwordDecision(values: VncHostValues,
    connectNow: boolean): VncSecretEditDecision {
    const existing: string = this.initialHost === null ? '' :
      this.hosts.passwordFor(this.initialHost.id);
    return vncSecretEditDecision(existing, this.password, this.passwordChanged,
      this.rememberPassword, connectNow, this.initialHost, values);
  }

  private gatewaySelectable(gateway: VncGatewayView): boolean {
    return gateway.enabled && gateway.transport === 'ultravnc_repeater' &&
      gateway.repeaterMode === 'mode12' &&
      vncGatewayAvailability(gateway.transport, gateway.tls, gateway.tokenConfigured,
        gateway.repeaterMode).enabled;
  }

  private selectTransport(value: VncTransport): void {
    this.transport = value;
    this.errorText = '';
    if (value === 'direct_tcp') {
      this.gatewayId = '';
      return;
    }
    const firstAvailable: VncGatewayView | undefined = this.gateways.find(
      (gateway: VncGatewayView): boolean => this.gatewaySelectable(gateway));
    if (this.gatewayId === '' && firstAvailable !== undefined) {
      this.gatewayId = firstAvailable.id;
    }
    const gateway: VncGatewayView | undefined = this.selectedGateway();
    if (gateway !== undefined) {
      this.portText = gateway.port.toString();
      if (this.repeaterTargetId.trim() === '' && gateway.targetId.trim() !== '') {
        this.repeaterTargetId = gateway.targetId;
      }
    }
  }

  private selectGateway(gateway: VncGatewayView): void {
    if (!this.gatewaySelectable(gateway)) {
      this.errorText = '只有已启用且支持 mode12 的 VNC Repeater Gateway 可以用于当前 viewer';
      return;
    }
    this.gatewayId = gateway.id;
    if (this.repeaterTargetId.trim() === '' && gateway.targetId.trim() !== '') {
      this.repeaterTargetId = gateway.targetId;
    }
    this.portText = gateway.port.toString();
    this.errorText = '';
  }

  private stepTitle(): string {
    if (this.step === 0) { return '连接方式与基础信息'; }
    return this.editingId.trim() === '' ? '访问、操控与确认' : '访问、操控与确认更新';
  }

  private stepDetail(): string {
    if (this.step === 0) { return '先确定直连还是已保存的 VNC Gateway'; }
    return '密码、TLS、控制与显示在一处确认；摘要不会显示密码';
  }

  private endpointValid(): boolean {
    if (this.label.trim() === '') { this.errorText = '请填写 VNC 主机名称'; return false; }
    if (this.endpointAddress().trim() === '') {
      this.errorText = this.transport === 'direct_tcp' ? '请填写服务器地址' : '请填写 Repeater target ID';
      return false;
    }
    const port: number = Number(this.portText);
    if (!Number.isFinite(port) || port < 1 || port > 65535) {
      this.errorText = 'VNC 端口必须在 1-65535 之间';
      return false;
    }
    if (this.transport === 'ultravnc_repeater') {
      const gateway: VncGatewayView | undefined = this.selectedGateway();
      if (gateway === undefined || !this.gatewaySelectable(gateway)) {
        this.errorText = '请选择已启用的 VNC Repeater Gateway';
        return false;
      }
      if (gateway.repeaterMode !== 'mode12') {
        this.errorText = '当前 HarmonyOS viewer 仅支持 UltraVNC Repeater mode12';
        return false;
      }
    }
    this.errorText = '';
    return true;
  }

  private buildValues(): VncHostValues | null {
    const initialHost: VncHostView | null = this.initialHost;
    const values: VncHostValues = {
      label: this.label.trim(),
      host: this.endpointAddress().trim(),
      port: Number(this.portText),
      username: '',
      gatewayId: this.transport === 'direct_tcp' ? '' : this.gatewayId.trim(),
      transport: this.transport,
      repeaterMode: this.repeaterMode,
      rememberPassword: this.rememberPassword,
      viewOnly: this.viewOnly,
      displayOverrideEnabled: this.displayOverrideEnabled,
      scalingMode: this.scalingMode,
      clipboardEnabled: this.clipboardEnabled,
      securityPolicy: this.securityPolicy,
      tls: this.tls,
      locked: initialHost === null ? false : initialHost.locked,
      lockType: initialHost === null ? 0 : initialHost.lockType
    };
    const errors: string[] = validateVncHost(values);
    if (errors.length > 0) { this.errorText = errors[0]; return null; }
    if (this.securityPolicy === 'secure_only' && !this.tls) {
      this.errorText = '当前安全策略要求 TLS，请打开 TLS 或选择可信网络/允许明文';
      return null;
    }
    return values;
  }

  private next(): void {
    this.errorText = '';
    if (this.step === 0 && !this.endpointValid()) { return; }
    this.step = nextVncFlowStep(this.step, VNC_HOST_ADD_STEP_COUNT);
  }

  private back(): void {
    this.errorText = '';
    if (this.step > 0) {
      this.step = previousVncFlowStep(this.step, VNC_HOST_ADD_STEP_COUNT);
    } else {
      this.onBackToProtocols();
    }
  }

  private dispatchSave(values: VncHostValues, password: string,
    connectNow: boolean, plainStorageConfirmed: boolean,
    passwordMutation: SecretEditMutationKind): void {
    if (this.securityPolicy === 'allow_plaintext') {
      promptAction.showDialog({
        title: '确认允许 VNC 明文连接',
        message: '该策略会允许不加密的 VNC 连接。请确认当前网络可信，并了解密码和屏幕内容可能被窃听。',
        buttons: [{ text: '取消', color: this.pal().text2 }, { text: '确认保存', color: this.pal().danger }]
      }).then((result: Object): void => {
        const dialogResult: Record<string, number> = result as Record<string, number>;
        if (dialogResult['index'] === 1) {
          this.onSave(values, password, connectNow, plainStorageConfirmed, passwordMutation);
        }
      });
      return;
    }
    this.onSave(values, password, connectNow, plainStorageConfirmed, passwordMutation);
  }

  private save(connectNow: boolean): void {
    const values: VncHostValues | null = this.buildValues();
    if (values === null) { return; }
    const decision: VncSecretEditDecision = this.passwordDecision(values, connectNow);
    const password: string = decision.submissionValue;
    if (password.length > 0 && this.rememberPassword) {
      const crypto: DataCrypto = DataCrypto.getInstance();
      if (crypto.isSetupComplete() && !crypto.isReady()) {
        this.errorText = '应用加密已锁定；请先解锁，或关闭“记住密码”后保存';
        return;
      }
      if (!crypto.isSetupComplete()) {
        promptAction.showDialog({
          title: '确认保存未加密密码',
          message: '应用加密未启用。打开“记住密码”会把 VNC 密码以未加密形式保存到 VNC 数据中；也可以关闭此选项，仅在连接时临时输入。',
          buttons: [{ text: '关闭记住密码', color: this.pal().text2 },
            { text: '确认保存', color: this.pal().danger }]
        }).then((result: Object): void => {
          const dialogResult: Record<string, number> = result as Record<string, number>;
          if (dialogResult['index'] === 1) {
            this.dispatchSave(values, password, connectNow, true,
              decision.storageMutation);
          }
        });
        return;
      }
    }
    this.dispatchSave(values, password, connectNow, false,
      decision.storageMutation);
  }

  private rememberPasswordDetail(): string {
    if (!this.rememberPassword) { return '关闭后不保存密码；连接时可以临时输入'; }
    const crypto: DataCrypto = DataCrypto.getInstance();
    if (crypto.isReady()) { return '使用应用加密保存到独立 VNC secret'; }
    if (crypto.isSetupComplete()) { return '应用加密已锁定，解锁后才能保存；仍可临时连接'; }
    return '应用加密未启用，保存前会单独确认未加密风险';
  }

  private securityStorageHint(): string {
    if (this.password.length === 0 && this.passwordConfigured) {
      return this.rememberPassword
        ? (this.passwordHidden()
          ? '当前已有已保存密码（不回显）；留空会继续保留，输入新密码才会替换'
          : '当前已有已保存密码；未修改会保留，输入新密码会替换')
        : '当前已有已保存密码；关闭“记住密码”并保存会删除它';
    }
    if (this.password.length === 0) { return '未填写密码；连接时可按需输入'; }
    return this.rememberPassword ? '密码将按上方选项保存；不会出现在确认摘要' :
      '密码仅用于本次保存并连接；关闭后不会保留';
  }

  @Builder private field(title: string, value: string, hint: string,
    change: (value: string) => void, password: boolean = false) {
    Column() {
      Text(title).fontSize(12).fontColor(this.pal().text2).margin({ bottom: 5 })
      TextInput({ text: value, placeholder: hint }).height(44).fontSize(14)
        .type(password ? InputType.Password : InputType.Normal)
        .fontColor(this.pal().text).placeholderColor(this.pal().text3)
        .backgroundColor(this.pal().surface).borderRadius(11)
        .padding({ left: 12, right: 12 }).onChange(change)
    }.alignItems(HorizontalAlign.Start).width('100%').margin({ bottom: 12 })
  }

  @Builder private transportButton(title: string, subtitle: string, value: VncTransport) {
    Column() {
      SymbolGlyph(protocolIcon(value === 'direct_tcp' ? 'vnc' : 'vnc_gateway')).fontSize(22)
        .fontColor([this.transport === value ? Color.White : this.pal().text2])
      Text(title).fontSize(14).fontWeight(FontWeight.Medium)
        .fontColor(this.transport === value ? Color.White : this.pal().text).margin({ top: 6 })
      Text(subtitle).fontSize(10)
        .fontColor(this.transport === value ? '#DDEEFF' : this.pal().text3)
        .margin({ top: 3 })
    }.alignItems(HorizontalAlign.Start).layoutWeight(1).padding(12).borderRadius(12)
      .backgroundColor(this.transport === value ? this.accentColor : this.pal().surface)
      .onClick((): void => { this.selectTransport(value); })
  }

  @Builder private securityButton(title: string, value: VncSecurityPolicy, danger: boolean = false,
    marginLeft: number = 0) {
    Button(title).layoutWeight(1).height(36).borderRadius(9)
      .backgroundColor(this.securityPolicy === value
        ? (danger ? this.pal().danger : this.accentColor) : this.pal().surface)
      .fontColor(this.securityPolicy === value ? Color.White : this.pal().text2)
      .fontSize(11).margin({ left: marginLeft })
      .onClick((): void => { this.securityPolicy = value; this.errorText = ''; })
  }

  @Builder private gatewayChoices() {
    if (this.gateways.length === 0) {
      Column() {
        Text('还没有 VNC Gateway。请先在第三页中继服务器添加。')
          .fontSize(12).fontColor(this.pal().danger).lineHeight(17)
        Button('去添加 VNC Gateway').width('100%').height(40).borderRadius(10).margin({ top: 8 })
          .backgroundColor(this.pal().surface).fontColor(this.accentColor)
          .onClick((): void => { this.onOpenSettings(); })
      }.width('100%').padding({ bottom: 10 })
    } else {
      Text('选择 VNC Gateway').fontSize(12).fontColor(this.pal().text2).margin({ bottom: 7 })
      ForEach(this.gateways, (gateway: VncGatewayView) => {
          Row() {
            Column() {
              Text(gateway.label).fontSize(13).fontColor(this.pal().text)
              Text(gateway.host + ':' + gateway.port.toString() +
                (this.gatewaySelectable(gateway) ? ' · mode12' : ' · 当前 viewer 不可用'))
                .fontSize(10).fontColor(this.gatewaySelectable(gateway) ? this.pal().text3 : this.pal().danger)
                .margin({ top: 2 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          if (this.gatewayId === gateway.id) {
            SymbolGlyph($r('sys.symbol.checkmark')).fontSize(17).fontColor([this.accentColor])
          }
        }.width('100%').padding(11).borderRadius(10)
          .backgroundColor(this.gatewayId === gateway.id ? this.pal().surface : this.pal().card)
          .opacity(this.gatewaySelectable(gateway) ? 1 : 0.65)
          .margin({ bottom: 6 }).onClick((): void => { this.selectGateway(gateway); })
      }, (gateway: VncGatewayView): string => gateway.id + ':' + gateway.updatedAt.toString())
    }
  }

  @Builder private endpointStep() {
    Column() {
      Row() {
        this.transportButton('TCP 直连', '服务器地址 + 端口', 'direct_tcp')
        Blank().width(8)
        this.transportButton('Repeater', 'Gateway + target ID', 'ultravnc_repeater')
      }.width('100%').margin({ bottom: 14 })
      this.field('名称', this.label, '例如：办公室 VNC', (value: string): void => { this.label = value; })
      this.field(this.transport === 'direct_tcp' ? '服务器地址' : 'Repeater target ID', this.endpointAddress(),
        this.transport === 'direct_tcp' ? 'IP 地址或域名' : '例如：office-01',
        (value: string): void => {
          if (this.transport === 'direct_tcp') { this.directAddress = value; }
          else { this.repeaterTargetId = value; }
        })
      if (this.transport === 'direct_tcp') {
        this.field('端口', this.portText, '5900',
          (value: string): void => { this.portText = value; })
      } else {
        Row() {
          Column() {
            Text('Gateway 端口').fontSize(12).fontColor(this.pal().text2)
            Text(this.selectedGateway() === undefined ? '请先选择 Gateway' :
              (this.selectedGateway() as VncGatewayView).host + ':' +
              (this.selectedGateway() as VncGatewayView).port.toString() + '（由第三页维护）')
              .fontSize(11).fontColor(this.pal().text3).margin({ top: 4 })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          SymbolGlyph($r('sys.symbol.lock_fill')).fontSize(16).fontColor([this.pal().text3])
        }.width('100%').padding({ top: 8, bottom: 12 })
      }
      if (this.transport === 'ultravnc_repeater') {
        this.gatewayChoices()
        Text('mode12 是 viewer pairing；mode2 是 server-side listener，本客户端不开放。')
          .fontSize(11).fontColor(this.pal().text3).lineHeight(17).margin({ top: 3 })
      }
    }.width('100%')
  }

  @Builder private securityStep() {
    Column() {
      this.field('VNC 密码（可选）', this.password,
        this.passwordConfigured && this.passwordHidden() ? '已保存密码（不回显；留空保留）' :
          '留空表示连接时输入',
        (value: string): void => {
          this.password = value;
          this.passwordChanged = true;
          this.passwordFromStoredProjection = false;
        }, true)
      if (this.passwordConfigured && this.password.length === 0 && this.passwordHidden()) {
        Text('已保存密码由本地隐藏策略保护。留空保存可保留现有密码；输入新密码会替换现有密码。')
          .fontSize(11).fontColor(this.pal().text3).lineHeight(17).width('100%').margin({ top: -5, bottom: 8 })
      }
      Row() {
        Column() {
          Text('记住密码').fontSize(14).fontColor(this.pal().text)
          Text(this.rememberPasswordDetail()).fontSize(11).fontColor(this.pal().text3)
            .lineHeight(16).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.rememberPassword }).selectedColor(this.accentColor)
          .onChange((value: boolean): void => { this.rememberPassword = value; })
      }.width('100%').padding({ top: 2, bottom: 12 })
      Row() {
        Text('TLS').fontSize(14).fontColor(this.pal().text).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.tls }).selectedColor(this.accentColor)
          .onChange((value: boolean): void => { this.tls = value; })
      }.width('100%').height(48)
      Text('安全策略').fontSize(12).fontColor(this.pal().text2).margin({ top: 7, bottom: 7 })
      Row() {
        this.securityButton('仅 TLS', 'secure_only')
        this.securityButton('可信网络', 'trusted_network', false, 6)
        this.securityButton('允许明文', 'allow_plaintext', true, 6)
      }.width('100%').margin({ bottom: 10 })
      Text('密码只进入独立 VNC secret 记录；不会写入 RDP、RustDesk、SSH 或普通 remotehosts。')
        .fontSize(11).fontColor(this.pal().text3).lineHeight(17).width('100%')
    }.width('100%')
  }

  @Builder private displayStep() {
    Column() {
      Row() {
        Column() {
          Text('只读模式').fontSize(14).fontColor(this.pal().text)
          Text(this.viewOnly ? '当前禁止远端键盘和鼠标输入' : '当前允许远端键盘和鼠标输入')
            .fontSize(11).fontColor(this.pal().text3).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.viewOnly }).selectedColor(this.accentColor)
          .onChange((value: boolean): void => { this.viewOnly = value; })
      }.width('100%').padding({ top: 4, bottom: 12 })
      Row() {
        Column() {
          Text('此主机单独设置缩放').fontSize(14).fontColor(this.pal().text)
          Text(this.displayOverrideEnabled ? '覆盖 VNC 全局显示设置' : '跟随 VNC 全局显示设置')
            .fontSize(11).fontColor(this.pal().text3).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.displayOverrideEnabled }).selectedColor(this.accentColor)
          .onChange((value: boolean): void => { this.displayOverrideEnabled = value; })
      }.width('100%').padding({ top: 2, bottom: 10 })
      if (this.displayOverrideEnabled) {
        Text('缩放模式').fontSize(12).fontColor(this.pal().text2).margin({ bottom: 7 })
        Row() {
          Button('适应').layoutWeight(1).height(36).borderRadius(9)
            .backgroundColor(this.scalingMode === 'fit' ? this.accentColor : this.pal().surface)
            .fontColor(this.scalingMode === 'fit' ? Color.White : this.pal().text2)
            .onClick((): void => { this.scalingMode = 'fit'; })
          Button('整数').layoutWeight(1).height(36).borderRadius(9).margin({ left: 6 })
            .backgroundColor(this.scalingMode === 'integer' ? this.accentColor : this.pal().surface)
            .fontColor(this.scalingMode === 'integer' ? Color.White : this.pal().text2)
            .onClick((): void => { this.scalingMode = 'integer'; })
          Button('1:1').layoutWeight(1).height(36).borderRadius(9).margin({ left: 6 })
            .backgroundColor(this.scalingMode === 'one_to_one' ? this.accentColor : this.pal().surface)
            .fontColor(this.scalingMode === 'one_to_one' ? Color.White : this.pal().text2)
            .onClick((): void => { this.scalingMode = 'one_to_one'; })
          Button('平移').layoutWeight(1).height(36).borderRadius(9).margin({ left: 6 })
            .backgroundColor(this.scalingMode === 'pan' ? this.accentColor : this.pal().surface)
            .fontColor(this.scalingMode === 'pan' ? Color.White : this.pal().text2)
            .onClick((): void => { this.scalingMode = 'pan'; })
        }.width('100%').margin({ bottom: 12 })
      }
      Row() {
        Column() {
          Text('文本剪贴板').fontSize(14).fontColor(this.pal().text)
          Text('默认关闭，需服务器支持 RFB 剪贴板能力').fontSize(11).fontColor(this.pal().text3).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.clipboardEnabled }).selectedColor(this.accentColor)
          .onChange((value: boolean): void => { this.clipboardEnabled = value; })
      }.width('100%').padding({ top: 4, bottom: 4 })
    }.width('100%')
  }

  @Builder private reviewRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(12).fontColor(this.pal().text3).width(92)
      Text(value).fontSize(13).fontColor(this.pal().text).layoutWeight(1)
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width('100%').padding({ top: 7, bottom: 7 })
  }

  @Builder private reviewStep() {
    Column() {
      Column() {
        this.reviewRow('连接方式', this.transport === 'direct_tcp' ? 'TCP 直连' : 'UltraVNC Repeater mode12')
        this.reviewRow('名称', this.label.trim())
        if (this.transport === 'direct_tcp') {
          this.reviewRow('服务器', this.redactedValue(this.endpointAddress()))
          this.reviewRow('端口', this.portText)
        } else {
          this.reviewRow('Gateway', this.selectedGateway() === undefined ? '未选择' :
            (this.selectedGateway() as VncGatewayView).label)
          this.reviewRow('Gateway 端点', this.selectedGateway() === undefined ? '未选择' :
            this.redactedValue((this.selectedGateway() as VncGatewayView).host) + ':' + this.portText)
          this.reviewRow('target ID', this.redactedValue(this.endpointAddress()))
        }
        this.reviewRow('TLS / 策略', (this.tls ? 'TLS' : '明文') + ' · ' + this.securityPolicy)
        this.reviewRow('交互', (this.viewOnly ? '只读' : '可控制') + ' · ' +
          (this.displayOverrideEnabled ? this.scalingMode : '跟随全局显示') +
          (this.clipboardEnabled ? ' · 剪贴板' : ' · 无剪贴板'))
      }.width('100%').padding(12).borderRadius(12).backgroundColor(this.pal().surface)
      Text(this.securityStorageHint())
        .fontSize(11).fontColor(this.pal().text3).lineHeight(17).width('100%').margin({ top: 12 })
    }.width('100%')
  }

  @Builder private actionBar() {
    Row() {
      Button(this.step === 0 ? '返回协议' : '上一步').layoutWeight(1).height(44).borderRadius(12)
        .backgroundColor(this.pal().surface).fontColor(this.pal().text2).onClick((): void => { this.back(); })
      if (this.step < VNC_HOST_ADD_STEP_COUNT - 1) {
        Button('下一步').layoutWeight(1).height(44).borderRadius(12).margin({ left: 8 })
          .backgroundColor(this.accentColor).fontColor(Color.White).onClick((): void => { this.next(); })
      } else {
        Button(this.editingId.trim() === '' ? '保存' : '更新').layoutWeight(1).height(44).borderRadius(12).margin({ left: 8 })
          .backgroundColor(this.pal().surface).fontColor(this.accentColor).onClick((): void => { this.save(false); })
        Button(this.editingId.trim() === '' ? '保存并连接' : '更新并连接')
          .layoutWeight(1).height(44).borderRadius(12).margin({ left: 8 })
          .backgroundColor(this.accentColor).fontColor(Color.White).onClick((): void => { this.save(true); })
      }
    }.width('100%')
  }

  @Builder private flowBody() {
    Column() {
      if (this.step === 0) {
        this.endpointStep()
      } else {
        Text('认证与安全').fontSize(13).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).width('100%').margin({ bottom: 10 })
        this.securityStep()
        Divider().strokeWidth(0.5).color(this.pal().divider).margin({ top: 16, bottom: 16 })
        Text('显示与交互').fontSize(13).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).width('100%').margin({ bottom: 10 })
        this.displayStep()
        Divider().strokeWidth(0.5).color(this.pal().divider).margin({ top: 16, bottom: 16 })
        Text('连接摘要').fontSize(13).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).width('100%').margin({ bottom: 10 })
        this.reviewStep()
      }
      if (this.errorText !== '') {
        Text(this.errorText).fontSize(12).fontColor(this.pal().danger).lineHeight(18)
          .width('100%').margin({ top: 12 })
      }
    }.width('100%')
  }

  build() {
    VncSheetScaffold({
      title: this.editingId.trim() === '' ? '添加 VNC 主机' : '编辑 VNC 主机',
      subtitle: this.stepDetail(),
      stepText: (this.step + 1).toString() + '/' + VNC_HOST_ADD_STEP_COUNT.toString() + '  ' + this.stepTitle(),
      leadingBack: true,
      fitContent: this.fitContent,
      onLeadingAction: (): void => { this.back(); },
      contentBuilder: (): void => { this.flowBody(); },
      footerBuilder: (): void => { this.actionBar(); }
    })
  }
}
