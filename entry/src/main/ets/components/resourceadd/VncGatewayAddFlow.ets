/**
 * VNC Gateway / UltraVNC Repeater wizard.
 *
 * This flow is intentionally independent from RustDeskRelayPage's RustDesk
 * form. The page owns the Sheet lifecycle, while this component only returns
 * a typed VNC gateway payload and an optional write-only token.
 */
import { Palette, buildDark, buildLight } from '../../common/Theme';
import {
  VncGatewayValues, VncTransport, VncRepeaterMode
} from '../../services/VncModelPolicy';
import { VncGatewayView } from '../../services/VncGatewayService';
import { VncGatewayAvailability, vncGatewayAvailability } from '../../services/VncGatewayProtocolPolicy';
import { protocolIcon } from '../../services/ProtocolIconPolicy';

@Component
export struct VncGatewayAddFlow {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop initialGateway: VncGatewayView | null = null;
  @Prop editingId: string = '';
  onClose: () => void = (): void => {};
  onSave: (values: VncGatewayValues, id: string, accessToken: string) => void =
    (_values: VncGatewayValues, _id: string, _accessToken: string): void => {};

  @State step: number = 0;
  @State label: string = '';
  @State host: string = '';
  @State portText: string = '5901';
  @State path: string = '/vnc';
  @State targetId: string = '';
  @State transport: VncTransport = 'ultravnc_repeater';
  @State repeaterMode: VncRepeaterMode = 'mode12';
  @State tls: boolean = false;
  @State gatewayEnabled: boolean = true;
  @State accessToken: string = '';
  @State existingTokenConfigured: boolean = false;
  @State errorText: string = '';

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  aboutToAppear(): void {
    const gateway: VncGatewayView | null = this.initialGateway;
    if (gateway === null) { return; }
    this.label = gateway.label;
    this.host = gateway.host;
    this.portText = gateway.port.toString();
    this.path = gateway.path;
    this.targetId = gateway.targetId;
    this.transport = gateway.transport;
    this.repeaterMode = gateway.repeaterMode;
    this.tls = gateway.tls;
    this.gatewayEnabled = gateway.enabled;
    this.existingTokenConfigured = gateway.tokenConfigured;
  }

  private isEditing(): boolean {
    return this.editingId.trim() !== '';
  }

  private stepTitle(): string {
    if (this.step === 0) { return '端点与协议'; }
    if (this.step === 1) { return '安全与可用性'; }
    return this.isEditing() ? '确认更新 Gateway' : '确认 VNC Gateway';
  }

  private stepDetail(): string {
    if (this.step === 0) { return '选择 VNC 专属中继类型并填写服务器端点'; }
    if (this.step === 1) { return '不支持的服务端契约会保持明确的不可用状态'; }
    return '卡片只显示非敏感端点，令牌不会出现在摘要中';
  }

  private selectTransport(value: VncTransport): void {
    this.transport = value;
    this.errorText = '';
    if (value === 'ultravnc_repeater') {
      if (this.portText === '') { this.portText = '5901'; }
    } else if (value === 'websocket_gateway') {
      if (this.path === '') { this.path = '/vnc'; }
    }
  }

  private portValue(): number {
    const value: number = Number(this.portText);
    return Number.isFinite(value) ? value : 0;
  }

  private redactedTargetId(value: string): string {
    const normalized: string = value.trim();
    if (normalized.length <= 4) { return normalized === '' ? '未填写' : '•••'; }
    return normalized.substring(0, 2) + '…' + normalized.substring(normalized.length - 2);
  }

  private endpointValid(): boolean {
    if (this.label.trim() === '') { this.errorText = '请填写 Gateway 名称'; return false; }
    if (this.host.trim() === '') { this.errorText = '请填写 Gateway 地址'; return false; }
    if (this.portValue() < 1 || this.portValue() > 65535) {
      this.errorText = 'Gateway 端口必须在 1-65535 之间'; return false;
    }
    if (this.transport === 'websocket_gateway' && this.path.trim() === '') {
      this.errorText = 'WebSocket Gateway 必须填写路径'; return false;
    }
    if (this.transport === 'ultravnc_repeater' && this.targetId.trim() === '') {
      this.errorText = 'UltraVNC Repeater mode12 必须填写目标 ID'; return false;
    }
    if (this.transport === 'ultravnc_repeater' && this.repeaterMode !== 'mode12') {
      this.errorText = '当前客户端只支持 UltraVNC Repeater Viewer mode12'; return false;
    }
    this.errorText = '';
    return true;
  }

  private values(): VncGatewayValues {
    return {
      label: this.label.trim(), transport: this.transport, host: this.host.trim(),
      port: this.portValue(), path: this.path.trim(), repeaterMode: this.repeaterMode,
      targetId: this.targetId.trim(), tls: this.tls, enabled: this.gatewayEnabled
    };
  }

  private availability(): VncGatewayAvailability {
    return vncGatewayAvailability(this.transport, this.tls,
      this.existingTokenConfigured || this.accessToken.length > 0, this.repeaterMode);
  }

  private next(): void {
    this.errorText = '';
    if (this.step === 0 && !this.endpointValid()) { return; }
    if (this.step < 2) { this.step += 1; }
  }

  private back(): void {
    this.errorText = '';
    if (this.step > 0) { this.step -= 1; } else { this.onClose(); }
  }

  private save(): void {
    if (!this.endpointValid()) { this.step = 0; return; }
    this.onSave(this.values(), this.editingId, this.accessToken);
  }

  @Builder private field(title: string, value: string, hint: string,
    change: (value: string) => void, password: boolean = false) {
    Column() {
      Text(title).fontSize(12).fontColor(this.pal().text2).margin({ bottom: 5 })
      TextInput({ text: value, placeholder: hint }).height(43).fontSize(14)
        .type(password ? InputType.Password : InputType.Normal)
        .fontColor(this.pal().text).placeholderColor(this.pal().text3)
        .backgroundColor(this.pal().surface).borderRadius(11)
        .padding({ left: 12, right: 12 }).onChange(change)
    }.alignItems(HorizontalAlign.Start).width('100%').margin({ bottom: 12 })
  }

  @Builder private transportButton(title: string, subtitle: string, value: VncTransport) {
    Row() {
      SymbolGlyph(protocolIcon(value === 'ultravnc_repeater' ? 'vnc_gateway' : 'vnc'))
        .fontSize(21).fontColor([this.transport === value ? Color.White : this.pal().text2])
      Column() {
        Text(title).fontSize(13).fontWeight(FontWeight.Medium)
          .fontColor(this.transport === value ? Color.White : this.pal().text)
        Text(subtitle).fontSize(10).margin({ top: 3 })
          .fontColor(this.transport === value ? '#DDEEFF' : this.pal().text3)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
    }.width('100%').padding(12).borderRadius(11)
      .backgroundColor(this.transport === value ? this.accentColor : this.pal().surface)
      .margin({ bottom: 8 }).onClick((): void => { this.selectTransport(value); })
  }

  @Builder private progress() {
    Row() {
      ForEach(['端点', '安全', '确认'], (title: string, index: number) => {
        Column() {
          Text((index + 1).toString()).fontSize(11).fontWeight(FontWeight.Bold)
            .fontColor(index <= this.step ? Color.White : this.pal().text3)
            .width(24).height(24).borderRadius(12).textAlign(TextAlign.Center)
            .padding({ top: 4 }).backgroundColor(index <= this.step ? this.accentColor : this.pal().surface)
          Text(title).fontSize(10).fontColor(index <= this.step ? this.accentColor : this.pal().text3)
            .margin({ top: 4 })
        }.alignItems(HorizontalAlign.Center).layoutWeight(1)
      }, (title: string): string => title)
    }.width('100%').margin({ bottom: 16 })
  }

  @Builder private endpointStep() {
    Column() {
      Text('VNC Gateway 类型').fontSize(12).fontColor(this.pal().text2).margin({ bottom: 7 })
      this.transportButton('UltraVNC Repeater', '当前可用：Viewer mode12', 'ultravnc_repeater')
      this.transportButton('WebSocket Gateway', '服务端契约未部署：仅保存，不可连接', 'websocket_gateway')
      this.transportButton('SSH 隧道', '需要独立 SSH tunnel owner：暂不可用', 'ssh_tunnel')
      this.field('名称', this.label, '例如：办公室 VNC Repeater', (value: string): void => { this.label = value; })
      this.field('服务器地址', this.host, 'relay.example.com', (value: string): void => { this.host = value; })
      this.field('服务器端口', this.portText, '5901', (value: string): void => { this.portText = value; })
      if (this.transport === 'websocket_gateway') {
        this.field('WebSocket 路径', this.path, '/vnc', (value: string): void => { this.path = value; })
      }
      if (this.transport === 'ultravnc_repeater') {
        this.field('目标 ID', this.targetId, '例如：office-01', (value: string): void => { this.targetId = value; })
        Text('仅支持 Viewer mode12。mode2 是 server-side listener 角色，不会被伪装成客户端可选项。')
          .fontSize(11).fontColor(this.pal().text3).lineHeight(17).width('100%').margin({ top: 1 })
      }
    }.width('100%')
  }

  @Builder private securityStep() {
    Column() {
      this.field('Gateway 令牌（可选）', this.accessToken,
        this.existingTokenConfigured ? '留空保留现有令牌；输入新令牌将替换' : '先解锁应用加密后保存',
        (value: string): void => { this.accessToken = value; }, true)
      Row() {
        Text('TLS').fontSize(14).fontColor(this.pal().text).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.tls }).selectedColor(this.accentColor)
          .onChange((value: boolean): void => { this.tls = value; })
      }.width('100%').height(48)
      Row() {
        Text('启用 Gateway').fontSize(14).fontColor(this.pal().text).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.gatewayEnabled }).selectedColor(this.accentColor)
          .onChange((value: boolean): void => { this.gatewayEnabled = value; })
      }.width('100%').height(48)
      Text('令牌只进入独立 VNC secret 记录；不会进入 RustDesk 中继、普通备份或卡片文字。')
        .fontSize(11).fontColor(this.pal().text3).lineHeight(17).width('100%').margin({ top: 8 })
      Column() {
        Text('当前状态').fontSize(12).fontColor(this.pal().text2)
        Text(this.availability().enabled ? '可用于当前 VNC viewer' : this.availability().message)
          .fontSize(11).fontColor(this.availability().enabled ? this.pal().success : this.pal().danger)
          .lineHeight(17).margin({ top: 5 })
      }.width('100%').padding(11).borderRadius(10).backgroundColor(this.pal().surface).margin({ top: 14 })
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
        this.reviewRow('类型', this.transport === 'ultravnc_repeater' ? 'VNC Gateway · Repeater' : 'VNC Gateway')
        this.reviewRow('名称', this.label.trim())
        this.reviewRow('端点', this.host.trim() + ':' + this.portValue().toString())
        if (this.transport === 'websocket_gateway') { this.reviewRow('路径', this.path.trim()) }
        if (this.transport === 'ultravnc_repeater') {
          this.reviewRow('目标 ID', this.redactedTargetId(this.targetId) + ' · mode12')
        }
        this.reviewRow('安全', (this.tls ? 'TLS' : '明文') + ' · ' +
          (this.gatewayEnabled && this.availability().enabled ? '已启用' : '已停用'))
        this.reviewRow('令牌', this.accessToken.length > 0 || this.existingTokenConfigured ? '已配置（不显示）' : '未配置')
      }.width('100%').padding(12).borderRadius(12).backgroundColor(this.pal().surface)
      Text(this.availability().enabled ? '保存后可被 VNC 主机添加流程选择。' : this.availability().message)
        .fontSize(11).fontColor(this.availability().enabled ? this.pal().text3 : this.pal().danger)
        .lineHeight(17).width('100%').margin({ top: 12 })
    }.width('100%')
  }

  @Builder private actionBar() {
    Row() {
      Button(this.step === 0 ? '取消' : '上一步').layoutWeight(1).height(44).borderRadius(12)
        .backgroundColor(this.pal().surface).fontColor(this.pal().text2).onClick((): void => { this.back(); })
      if (this.step < 2) {
        Button('下一步').layoutWeight(1).height(44).borderRadius(12).margin({ left: 8 })
          .backgroundColor(this.accentColor).fontColor(Color.White).onClick((): void => { this.next(); })
      } else {
        Button(this.isEditing() ? '更新' : '保存').layoutWeight(1).height(44).borderRadius(12).margin({ left: 8 })
          .backgroundColor(this.accentColor).fontColor(Color.White).onClick((): void => { this.save(); })
      }
    }.width('100%').margin({ top: 18 })
  }

  build() {
    Column() {
      Row() {
        SymbolGlyph(protocolIcon('vnc_gateway')).fontSize(22).fontColor([this.accentColor])
        Column() {
          Text(this.isEditing() ? '编辑 VNC Gateway' : '添加 VNC Gateway')
            .fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          Text(this.stepTitle()).fontSize(12).fontColor(this.pal().text3).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
        Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2]) }
          .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
          .onClick((): void => { this.onClose(); })
      }.width('100%').margin({ bottom: 5 })
      Text(this.stepDetail()).fontSize(11).fontColor(this.pal().text3).width('100%').margin({ bottom: 12 })
      this.progress()
      Scroll() {
        Column() {
          if (this.step === 0) { this.endpointStep() }
          else if (this.step === 1) { this.securityStep() }
          else { this.reviewStep() }
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
