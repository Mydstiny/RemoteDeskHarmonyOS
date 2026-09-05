/**
 * VNC Gateway / UltraVNC Repeater wizard.
 *
 * This flow is intentionally independent from RustDeskRelayPage's RustDesk
 * form. The page owns the Sheet lifecycle, while this component only returns
 * a typed VNC gateway payload and an optional write-only token.
 */
import { Palette, buildDark, buildLight } from '../../common/Theme';
import { promptAction } from '@kit.ArkUI';
import { DataCrypto } from '../../services/DataCrypto';
import {
  VncGatewayValues, VncTransport, VncRepeaterMode,
  canonicalVncNetworkHost, validateVncGateway
} from '../../services/VncModelPolicy';
import { parseEndpointPortText } from '../../services/EndpointAddressPolicy';
import { VncGatewayView } from '../../services/VncGatewayService';
import { VncGatewayAvailability, vncGatewayAvailability } from '../../services/VncGatewayProtocolPolicy';
import {
  VNC_GATEWAY_ADD_STEP_COUNT,
  isVncGatewayTransportSelectable,
  nextVncFlowStep,
  previousVncFlowStep
} from '../../services/VncHostFlowPolicy';
import { VncSheetScaffold } from '../vnc/VncSheetScaffold';

@Component
export struct VncGatewayAddFlow {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop initialGateway: VncGatewayView | null = null;
  @Prop editingId: string = '';
  onClose: () => void = (): void => {};
  onSave: (values: VncGatewayValues, id: string, accessToken: string,
    plainStorageConfirmed: boolean) => void =
    (_values: VncGatewayValues, _id: string, _accessToken: string,
      _plainStorageConfirmed: boolean): void => {};

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
    return this.isEditing() ? '安全与确认更新' : '安全与确认';
  }

  private stepDetail(): string {
    if (this.step === 0) { return '选择 VNC 专属中继类型并填写服务器端点'; }
    return '确认 TLS、启用状态与非敏感摘要';
  }

  private portValue(): number {
    return parseEndpointPortText(this.portText);
  }

  private redactedTargetId(value: string): string {
    const normalized: string = value.trim();
    if (normalized.length <= 4) { return normalized === '' ? '未填写' : '•••'; }
    return normalized.substring(0, 2) + '…' + normalized.substring(normalized.length - 2);
  }

  private endpointValid(): boolean {
    if (!isVncGatewayTransportSelectable(this.transport)) {
      this.errorText = '该旧 Gateway 类型尚未实现连接契约；当前只能新增 UltraVNC Repeater mode12';
      return false;
    }
    const errors: string[] = validateVncGateway(this.values());
    if (errors.length > 0) { this.errorText = errors[0]; return false; }
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
    const port: number = this.portValue();
    return {
      label: this.label.trim(), transport: this.transport,
      host: canonicalVncNetworkHost(this.host, port),
      port, path: this.path.trim(), repeaterMode: this.repeaterMode,
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
    this.step = nextVncFlowStep(this.step, VNC_GATEWAY_ADD_STEP_COUNT);
  }

  private back(): void {
    this.errorText = '';
    if (this.step > 0) {
      this.step = previousVncFlowStep(this.step, VNC_GATEWAY_ADD_STEP_COUNT);
    } else {
      this.onClose();
    }
  }

  private save(): void {
    if (!this.endpointValid()) { this.step = 0; return; }
    const crypto: DataCrypto = DataCrypto.getInstance();
    if (this.accessToken.length > 0 && crypto.isSetupComplete() && !crypto.isReady()) {
      this.errorText = '应用加密已锁定；请先解锁后保存 Gateway 令牌，或留空保留现有令牌';
      return;
    }
    if (this.accessToken.length > 0 && !crypto.isSetupComplete()) {
      promptAction.showDialog({
        title: '确认保存未加密令牌',
        message: '应用加密未启用。Gateway 令牌将以未加密形式保存到 VNC 数据中；也可以留空，仅保存端点。',
        buttons: [{ text: '取消', color: this.pal().text2 }, { text: '确认保存', color: this.pal().danger }]
      }).then((dialog: Object): void => {
        const values: Record<string, number> = dialog as Record<string, number>;
        if (values['index'] === 1) { this.onSave(this.values(), this.editingId, this.accessToken, true); }
      });
      return;
    }
    this.onSave(this.values(), this.editingId, this.accessToken, false);
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

  @Builder private endpointStep() {
    Column() {
      Row() {
        Column() {
          Text('UltraVNC Repeater').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          Text('当前唯一可用的 VNC Gateway · Viewer mode12')
            .fontSize(11).fontColor(this.pal().text3).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text('VNC').fontSize(10).fontColor(this.accentColor)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(8).backgroundColor(this.pal().surface)
      }.width('100%').padding(12).borderRadius(11).backgroundColor(this.pal().surface)
        .margin({ bottom: 14 })
      this.field('名称', this.label, '例如：办公室 VNC Repeater', (value: string): void => { this.label = value; })
      this.field('服务器地址', this.host, 'relay.example.com', (value: string): void => { this.host = value; })
      this.field('服务器端口', this.portText, '5901', (value: string): void => { this.portText = value; })
      if (this.transport === 'ultravnc_repeater') {
        this.field('目标 ID', this.targetId, '例如：office-01', (value: string): void => { this.targetId = value; })
        Text('仅支持 Viewer mode12。mode2 是 server-side listener 角色，不会被伪装成客户端可选项。')
          .fontSize(11).fontColor(this.pal().text3).lineHeight(17).width('100%').margin({ top: 1 })
      }
    }.width('100%')
  }

  @Builder private securityStep() {
    Column() {
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
      Text('mode12 不使用 Gateway 令牌。旧记录中的令牌不会显示，也不会被本次更新清空。')
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
        if (this.transport === 'ultravnc_repeater') {
          this.reviewRow('目标 ID', this.redactedTargetId(this.targetId) + ' · mode12')
        }
        this.reviewRow('安全', (this.tls ? 'TLS' : '明文') + ' · ' +
          (this.gatewayEnabled && this.availability().enabled ? '已启用' : '已停用'))
        this.reviewRow('令牌', 'mode12 不使用')
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
      if (this.step < VNC_GATEWAY_ADD_STEP_COUNT - 1) {
        Button('下一步').layoutWeight(1).height(44).borderRadius(12).margin({ left: 8 })
          .backgroundColor(this.accentColor).fontColor(Color.White).onClick((): void => { this.next(); })
      } else {
        Button(this.isEditing() ? '更新' : '保存').layoutWeight(1).height(44).borderRadius(12).margin({ left: 8 })
          .backgroundColor(this.accentColor).fontColor(Color.White).onClick((): void => { this.save(); })
      }
    }.width('100%')
  }

  @Builder private flowBody() {
    Column() {
      if (this.step === 0) {
        this.endpointStep()
      } else {
        this.securityStep()
        Divider().strokeWidth(0.5).color(this.pal().divider).margin({ top: 16, bottom: 16 })
        Text('Gateway 摘要').fontSize(13).fontWeight(FontWeight.Medium)
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
      title: this.isEditing() ? '编辑 VNC Gateway' : '添加 VNC Gateway',
      subtitle: this.stepDetail(),
      stepText: (this.step + 1).toString() + '/' + VNC_GATEWAY_ADD_STEP_COUNT.toString() +
        '  ' + this.stepTitle(),
      leadingBack: true,
      onLeadingAction: (): void => { this.back(); },
      contentBuilder: (): void => { this.flowBody(); },
      footerBuilder: (): void => { this.actionBar(); }
    })
  }
}
