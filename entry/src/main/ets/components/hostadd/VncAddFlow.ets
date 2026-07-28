/** VNC add flow used by both the modern FAB picker and the VNC-only owner. */
import { Palette, buildDark, buildLight } from '../../common/Theme';
import {
  VncHostValues,
  VncTransport,
  VncRepeaterMode,
  VncScalingMode,
  VncSecurityPolicy,
  defaultVncSettings,
  validateVncHost
} from '../../services/VncModelPolicy';
import { VncGatewayView } from '../../services/VncGatewayService';

@Component
export struct VncAddFlow {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop gateways: VncGatewayView[] = [];
  onBackToProtocols: () => void = (): void => {};
  onOpenSettings: () => void = (): void => {};
  onSave: (values: VncHostValues, password: string, connectNow: boolean) => void =
    (_values: VncHostValues, _password: string, _connectNow: boolean): void => {};

  @State transport: VncTransport = 'direct_tcp';
  @State repeaterMode: VncRepeaterMode = 'mode12';
  @State label: string = '';
  @State address: string = '';
  @State portText: string = '5900';
  @State username: string = '';
  @State password: string = '';
  @State gatewayId: string = '';
  @State tls: boolean = false;
  @State viewOnly: boolean = true;
  @State scalingMode: VncScalingMode = 'fit';
  @State securityPolicy: VncSecurityPolicy = 'secure_only';
  @State errorText: string = '';

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  aboutToAppear(): void {
    const defaults = defaultVncSettings();
    this.portText = defaults.defaultPort.toString();
    this.repeaterMode = defaults.repeaterMode;
    this.viewOnly = defaults.viewOnly;
    this.scalingMode = defaults.scalingMode;
    this.securityPolicy = defaults.securityPolicy;
  }

  private selectedGateway(): VncGatewayView | undefined {
    return this.gateways.find((gateway: VncGatewayView): boolean => gateway.id === this.gatewayId);
  }

  private selectTransport(value: VncTransport): void {
    this.transport = value;
    this.errorText = '';
    if (value === 'direct_tcp') {
      this.gatewayId = '';
      return;
    }
    if (this.gatewayId === '' && this.gateways.length > 0) {
      this.gatewayId = this.gateways[0].id;
      const gateway: VncGatewayView | undefined = this.selectedGateway();
      if (gateway !== undefined && this.address.trim() === '') {
        this.address = gateway.targetId;
      }
    }
  }

  private buildValues(): VncHostValues | null {
    const values: VncHostValues = {
      label: this.label.trim(),
      host: this.address.trim(),
      port: parseInt(this.portText),
      username: this.username.trim(),
      gatewayId: this.transport === 'direct_tcp' ? '' : this.gatewayId.trim(),
      transport: this.transport,
      repeaterMode: this.repeaterMode,
      viewOnly: this.viewOnly,
      scalingMode: this.scalingMode,
      securityPolicy: this.securityPolicy,
      tls: this.tls
    };
    const errors: string[] = validateVncHost(values);
    if (errors.length > 0) {
      this.errorText = errors[0];
      return null;
    }
    if (!Number.isFinite(values.port)) {
      this.errorText = 'VNC 端口必须是数字';
      return null;
    }
    if (this.securityPolicy === 'secure_only' && !this.tls) {
      this.errorText = '当前安全策略要求 TLS，请打开 TLS，或选择可信网络/允许明文';
      return null;
    }
    if (this.transport === 'ultravnc_repeater') {
      const gateway: VncGatewayView | undefined = this.selectedGateway();
      if (gateway === undefined || !gateway.enabled) {
        this.errorText = '请选择已启用的 VNC Repeater 网关';
        return null;
      }
      if (gateway.repeaterMode !== 'mode12') {
        this.errorText = '当前 HarmonyOS 客户端只支持 UltraVNC Repeater Viewer mode12';
        return null;
      }
    }
    this.errorText = '';
    return values;
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
      Text(title).fontSize(14).fontWeight(FontWeight.Medium)
        .fontColor(this.transport === value ? Color.White : this.pal().text)
      Text(subtitle).fontSize(10)
        .fontColor(this.transport === value ? '#DDEEFF' : this.pal().text3)
        .margin({ top: 3 })
    }.alignItems(HorizontalAlign.Start).layoutWeight(1).padding(12).borderRadius(12)
      .backgroundColor(this.transport === value ? this.accentColor : this.pal().surface)
      .onClick((): void => { this.selectTransport(value); })
  }

  @Builder private securityButton(title: string, value: VncSecurityPolicy, danger: boolean = false) {
    Button(title).layoutWeight(1).height(34).borderRadius(9)
      .backgroundColor(this.securityPolicy === value
        ? (danger ? this.pal().danger : this.accentColor) : this.pal().surface)
      .fontColor(this.securityPolicy === value ? Color.White : this.pal().text2)
      .fontSize(11).onClick((): void => { this.securityPolicy = value; this.errorText = ''; })
  }

  @Builder private gatewayChoices() {
    if (this.gateways.length === 0) {
      Column() {
        Text('还没有 VNC Repeater 网关。请先在 VNC 设置中添加并启用网关。')
          .fontSize(12).fontColor(this.pal().danger).lineHeight(17)
        Button('打开 VNC 设置').width('100%').height(38).borderRadius(10).margin({ top: 8 })
          .backgroundColor(this.pal().surface).fontColor(this.accentColor)
          .onClick((): void => { this.onOpenSettings(); })
      }.width('100%').padding({ bottom: 10 })
    } else {
      Text('Repeater 网关').fontSize(12).fontColor(this.pal().text2).margin({ bottom: 7 })
      ForEach(this.gateways, (gateway: VncGatewayView) => {
        Row() {
          Column() {
            Text(gateway.label).fontSize(13).fontColor(this.pal().text)
            Text(gateway.host + ':' + gateway.port.toString() +
              (gateway.enabled ? ' · mode12' : ' · 已停用'))
              .fontSize(10).fontColor(this.pal().text3).margin({ top: 2 })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          if (this.gatewayId === gateway.id) {
            SymbolGlyph($r('sys.symbol.checkmark')).fontSize(17).fontColor([this.accentColor])
          }
        }.width('100%').padding(11).borderRadius(10)
          .backgroundColor(this.pal().surface).margin({ bottom: 6 })
          .onClick((): void => {
            this.gatewayId = gateway.id;
            if (this.address.trim() === '') { this.address = gateway.targetId; }
            this.errorText = '';
          })
      }, (gateway: VncGatewayView): string => gateway.id + ':' + gateway.updatedAt.toString())
    }
  }

  @Builder private header() {
    Row() {
      Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(18).fontColor([this.pal().text2]) }
        .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
        .onClick((): void => { this.onBackToProtocols(); })
      Column() {
        Text('添加 VNC 主机').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        Text('独立 VNC owner · 直连或 UltraVNC Repeater mode12')
          .fontSize(11).fontColor(this.pal().text3).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
    }.width('100%').margin({ bottom: 18 })
  }

  build() {
    Scroll() {
      Column() {
        this.header()
        Row() {
          this.transportButton('TCP 直连', '服务器地址 + 端口', 'direct_tcp')
          Blank().width(8)
          this.transportButton('UltraVNC Repeater', '网关 + target ID', 'ultravnc_repeater')
        }.width('100%').margin({ bottom: 14 })
        this.field('名称', this.label, '例如：办公室 VNC', (value: string): void => { this.label = value; })
        this.field(this.transport === 'direct_tcp' ? '服务器地址' : '目标备注 / target ID', this.address,
          this.transport === 'direct_tcp' ? 'IP 地址或域名' : '通常填网关的 target ID',
          (value: string): void => { this.address = value; })
        this.field('端口', this.portText, this.transport === 'direct_tcp' ? '5900' : '由网关配置',
          (value: string): void => { this.portText = value; })
        this.field('用户名（可选）', this.username, 'VNC 服务器用户名（若支持）',
          (value: string): void => { this.username = value; })
        this.field('VNC 密码（可选）', this.password, '需要先解锁应用加密',
          (value: string): void => { this.password = value; }, true)
        if (this.transport === 'ultravnc_repeater') {
          this.gatewayChoices()
        }
        Row() {
          Text('TLS').fontSize(13).fontColor(this.pal().text).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.tls }).selectedColor(this.accentColor)
            .onChange((value: boolean): void => { this.tls = value; })
        }.width('100%').height(46)
        Row() {
          Text('只读模式').fontSize(13).fontColor(this.pal().text).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.viewOnly }).selectedColor(this.accentColor)
            .onChange((value: boolean): void => { this.viewOnly = value; })
        }.width('100%').height(46)
        Text('安全策略').fontSize(12).fontColor(this.pal().text2).margin({ top: 3, bottom: 7 })
        Row() {
          this.securityButton('仅 TLS', 'secure_only')
          this.securityButton('可信网络', 'trusted_network', false)
          this.securityButton('允许明文', 'allow_plaintext', true)
        }.width('100%').margin({ bottom: 10 })
        Text('VNC 密码会进入独立的加密 secret 记录；不会写入 RDP、RustDesk 或 SSH 数据 owner。')
          .fontSize(11).fontColor(this.pal().text3).lineHeight(17).width('100%').margin({ bottom: 12 })
        Row() {
          Button('保存').layoutWeight(1).height(44).borderRadius(12)
            .backgroundColor(this.pal().surface).fontColor(this.accentColor)
            .onClick((): void => {
              const values: VncHostValues | null = this.buildValues();
              if (values !== null) { this.onSave(values, this.password, false); }
            })
          Button('保存并连接').layoutWeight(1).height(44).borderRadius(12).margin({ left: 8 })
            .backgroundColor(this.accentColor).fontColor(Color.White)
            .onClick((): void => {
              const values: VncHostValues | null = this.buildValues();
              if (values !== null) { this.onSave(values, this.password, true); }
            })
        }.width('100%')
        if (this.errorText !== '') {
          Text(this.errorText).fontSize(12).fontColor(this.pal().danger).lineHeight(17).margin({ top: 10 })
        }
      }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 22 }).backgroundColor(this.pal().card)
    }.scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring).width('100%')
  }
}
