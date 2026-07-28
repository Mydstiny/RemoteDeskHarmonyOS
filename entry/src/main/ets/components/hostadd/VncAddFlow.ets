/**
 * VNC host wizard shared by the modern and classic host FAB paths.
 *
 * The wizard deliberately separates endpoint, security, display and review
 * decisions. Passwords never appear in the review step and no username field
 * is exposed: the current VNC viewer/native path uses VNC password
 * authentication, not a general username credential.
 */
import { promptAction } from '@kit.ArkUI';
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
import { VncHostView } from '../../services/VncHostService';
import { vncGatewayAvailability } from '../../services/VncGatewayProtocolPolicy';
import { protocolIcon } from '../../services/ProtocolIconPolicy';

@Component
export struct VncAddFlow {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop gateways: VncGatewayView[] = [];
  @Prop initialHost: VncHostView | null = null;
  @Prop editingId: string = '';
  onBackToProtocols: () => void = (): void => {};
  onOpenSettings: () => void = (): void => {};
  onSave: (values: VncHostValues, password: string, connectNow: boolean) => void =
    (_values: VncHostValues, _password: string, _connectNow: boolean): void => {};

  @State step: number = 0;
  @State transport: VncTransport = 'direct_tcp';
  @State repeaterMode: VncRepeaterMode = 'mode12';
  @State label: string = '';
  @State directAddress: string = '';
  @State repeaterTargetId: string = '';
  @State portText: string = '5900';
  @State password: string = '';
  @State gatewayId: string = '';
  @State tls: boolean = true;
  @State viewOnly: boolean = true;
  @State scalingMode: VncScalingMode = 'fit';
  @State clipboardEnabled: boolean = false;
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
    this.clipboardEnabled = defaults.clipboardEnabled;
    this.securityPolicy = defaults.securityPolicy;
    this.tls = defaults.securityPolicy === 'secure_only';
    const host: VncHostView | null = this.initialHost;
    if (host !== null) {
      this.label = host.label;
      this.transport = host.transport;
      if (host.transport === 'direct_tcp') { this.directAddress = host.host; }
      else { this.repeaterTargetId = host.host; }
      this.portText = host.port.toString();
      this.gatewayId = host.gatewayId;
      this.repeaterMode = host.repeaterMode;
      this.viewOnly = host.viewOnly;
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
    if (this.step === 1) { return '认证与安全'; }
    if (this.step === 2) { return '显示与交互'; }
    return this.editingId.trim() === '' ? '确认 VNC 主机' : '确认更新 VNC 主机';
  }

  private stepDetail(): string {
    if (this.step === 0) { return '先确定直连还是已保存的 VNC Gateway'; }
    if (this.step === 1) { return '密码只进入 VNC secret owner，不能写入普通主机表'; }
    if (this.step === 2) { return '默认只读；高级连接超时在 VNC 设置中统一管理'; }
    return '只展示非敏感连接摘要，密码不会出现在这里';
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
    const values: VncHostValues = {
      label: this.label.trim(),
      host: this.endpointAddress().trim(),
      port: Number(this.portText),
      username: '',
      gatewayId: this.transport === 'direct_tcp' ? '' : this.gatewayId.trim(),
      transport: this.transport,
      repeaterMode: this.repeaterMode,
      viewOnly: this.viewOnly,
      scalingMode: this.scalingMode,
      clipboardEnabled: this.clipboardEnabled,
      securityPolicy: this.securityPolicy,
      tls: this.tls
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
    if (this.step < 3) { this.step += 1; }
  }

  private back(): void {
    this.errorText = '';
    if (this.step > 0) { this.step -= 1; } else { this.onBackToProtocols(); }
  }

  private save(connectNow: boolean): void {
    const values: VncHostValues | null = this.buildValues();
    if (values === null) { return; }
    if (this.securityPolicy === 'allow_plaintext') {
      promptAction.showDialog({
        title: '确认允许 VNC 明文连接',
        message: '该策略会允许不加密的 VNC 连接。请确认当前网络可信，并了解密码和屏幕内容可能被窃听。',
        buttons: [{ text: '取消', color: this.pal().text2 }, { text: '确认保存', color: this.pal().danger }]
      }).then((result: Object): void => {
        const dialogResult: Record<string, number> = result as Record<string, number>;
        if (dialogResult['index'] === 1) { this.onSave(values, this.password, connectNow); }
      });
      return;
    }
    this.onSave(values, this.password, connectNow);
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

  @Builder private progress() {
    Row() {
      ForEach(['连接', '安全', '显示', '确认'], (title: string, index: number) => {
        Column() {
          Text((index + 1).toString()).fontSize(11).fontWeight(FontWeight.Bold)
            .fontColor(index <= this.step ? Color.White : this.pal().text3)
            .width(24).height(24).borderRadius(12).textAlign(TextAlign.Center)
            .padding({ top: 4 }).backgroundColor(index <= this.step ? this.accentColor : this.pal().surface)
          Text(title).fontSize(10).fontColor(index <= this.step ? this.accentColor : this.pal().text3)
            .margin({ top: 4 })
        }.alignItems(HorizontalAlign.Center).layoutWeight(1)
      }, (title: string): string => title)
    }.width('100%').margin({ bottom: 18 })
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
      this.field('VNC 密码（可选）', this.password, '需要先解锁应用加密',
        (value: string): void => { this.password = value; }, true)
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
          Text('默认关闭远端输入，适合第一次连接').fontSize(11).fontColor(this.pal().text3).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.viewOnly }).selectedColor(this.accentColor)
          .onChange((value: boolean): void => { this.viewOnly = value; })
      }.width('100%').padding({ top: 4, bottom: 12 })
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
        this.reviewRow('交互', (this.viewOnly ? '只读' : '可控制') + ' · ' + this.scalingMode +
          (this.clipboardEnabled ? ' · 剪贴板' : ' · 无剪贴板'))
      }.width('100%').padding(12).borderRadius(12).backgroundColor(this.pal().surface)
      Text(this.password.length > 0 ? '密码已填写，将进入加密 VNC secret；不会显示在确认摘要。' :
        '未填写密码；连接时可能由 VNC 服务器要求重新认证。')
        .fontSize(11).fontColor(this.pal().text3).lineHeight(17).width('100%').margin({ top: 12 })
    }.width('100%')
  }

  @Builder private actionBar() {
    Row() {
      Button(this.step === 0 ? '返回协议' : '上一步').layoutWeight(1).height(44).borderRadius(12)
        .backgroundColor(this.pal().surface).fontColor(this.pal().text2).onClick((): void => { this.back(); })
      if (this.step < 3) {
        Button('下一步').layoutWeight(1).height(44).borderRadius(12).margin({ left: 8 })
          .backgroundColor(this.accentColor).fontColor(Color.White).onClick((): void => { this.next(); })
      } else {
        Button(this.editingId.trim() === '' ? '保存' : '更新').layoutWeight(1).height(44).borderRadius(12).margin({ left: 8 })
          .backgroundColor(this.pal().surface).fontColor(this.accentColor).onClick((): void => { this.save(false); })
        Button(this.editingId.trim() === '' ? '保存并连接' : '更新并连接')
          .layoutWeight(1).height(44).borderRadius(12).margin({ left: 8 })
          .backgroundColor(this.accentColor).fontColor(Color.White).onClick((): void => { this.save(true); })
      }
    }.width('100%').margin({ top: 18 })
  }

  build() {
    Column() {
      Row() {
        Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(18).fontColor([this.pal().text2]) }
          .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
          .onClick((): void => { this.back(); })
        Column() {
          Text(this.editingId.trim() === '' ? '添加 VNC 主机' : '编辑 VNC 主机')
            .fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          Text(this.stepTitle()).fontSize(12).fontColor(this.pal().text3).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
      }.width('100%').margin({ bottom: 4 })
      Text(this.stepDetail()).fontSize(11).fontColor(this.pal().text3).width('100%').margin({ bottom: 14 })
      this.progress()
      Scroll() {
        Column() {
          if (this.step === 0) {
            this.endpointStep()
          } else if (this.step === 1) {
            this.securityStep()
          } else if (this.step === 2) {
            this.displayStep()
          } else {
            this.reviewStep()
          }
          if (this.errorText !== '') {
            Text(this.errorText).fontSize(12).fontColor(this.pal().danger).lineHeight(18)
              .width('100%').margin({ top: 12 })
          }
        }.width('100%')
      }.scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring).layoutWeight(1)
      this.actionBar()
    }.width('100%').height('100%').padding({ left: 20, right: 20, top: 18, bottom: 20 })
      .backgroundColor(this.pal().card)
  }
}
