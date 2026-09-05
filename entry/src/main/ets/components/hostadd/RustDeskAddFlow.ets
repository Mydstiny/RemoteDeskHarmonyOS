import { Palette, buildDark, buildLight } from '../../common/Theme';
import { RemoteHost } from '../../model/RemoteHost';
import { RustDeskRelayConfig } from '../../model/RustDeskRelayConfig';
import { DiscoveredRustDeskPeer } from '../../services/RustDeskLanDiscoveryService';
import { RustDeskTargetDevice } from '../../services/RemoteOrientationPolicy';
import {
  cloneRustDeskHostAddDraft,
  RustDeskHostAddDraft
} from '../../services/RustDeskHostAddHandoff';
import {
  EndpointAddressResult,
  endpointTransportHost,
  parseEndpointFields,
  parseEndpointPortText
} from '../../services/EndpointAddressPolicy';

@Component
export struct RustDeskAddFlow {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop relays: RustDeskRelayConfig[] = [];
  @Prop lanScanning: boolean = false;
  @Prop lanPeers: DiscoveredRustDeskPeer[] = [];
  @Prop defaultDirectPort: number = 21118;
  @Prop initialDraft: RustDeskHostAddDraft | null = null;
  @Prop @Watch('onInitialDraftChanged')
  initialDraftRevision: number = 0;
  onBackToProtocols: () => void = (): void => {};
  onStartLanScan: () => void = (): void => {};
  onManageRelays: (draft: RustDeskHostAddDraft) => void =
    (_draft: RustDeskHostAddDraft): void => {};
  onOpenTotpBinding: (draft: RustDeskHostAddDraft) => void =
    (_draft: RustDeskHostAddDraft): void => {};
  onSave: (host: RemoteHost, connectNow: boolean) => void =
    (_host: RemoteHost, _connectNow: boolean): void => {};
  @State step: number = 1;
  @State direct: boolean = false;
  @State useLan: boolean = false;
  @State selectedLanPeerId: string = '';
  @State lanAddressMode: string = '';
  @State label: string = '';
  @State controlId: string = '';
  @State directHost: string = '';
  @State directPortText: string = '21118';
  @State relayId: string = '';
  @State password: string = '';
  @State passwordMode: number = 0;
  @State totpEntryId: string = '';
  @State totpAutoSubmit: boolean = false;
  @State errorText: string = '';
  @State targetDevice: RustDeskTargetDevice = 'computer';
  @State adaptiveOrientation: boolean = false;

  aboutToAppear(): void {
    if (this.initialDraft === null) {
      this.directPortText = this.defaultDirectPort.toString();
    } else {
      this.applyDraft(this.initialDraft);
    }
  }
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor); }

  private onInitialDraftChanged(): void {
    if (this.initialDraft !== null) {
      this.applyDraft(this.initialDraft);
    }
  }

  private applyDraft(source: RustDeskHostAddDraft): void {
    const draft: RustDeskHostAddDraft =
      cloneRustDeskHostAddDraft(source);
    this.step = draft.step;
    this.direct = draft.direct;
    this.useLan = draft.useLan;
    this.selectedLanPeerId = draft.selectedLanPeerId;
    this.lanAddressMode = draft.lanAddressMode;
    this.label = draft.label;
    this.controlId = draft.controlId;
    this.directHost = draft.directHost;
    this.directPortText = draft.directPortText;
    this.relayId = draft.relayId;
    this.password = draft.password;
    this.passwordMode = draft.passwordMode;
    this.totpEntryId = draft.totpEntryId;
    this.totpAutoSubmit = draft.totpAutoSubmit && draft.totpEntryId !== '';
    this.targetDevice = draft.targetDevice;
    this.adaptiveOrientation = draft.adaptiveOrientation;
    this.errorText = '';
  }

  private currentDraft(): RustDeskHostAddDraft {
    const draft = new RustDeskHostAddDraft();
    draft.step = this.step;
    draft.direct = this.direct;
    draft.useLan = this.useLan;
    draft.selectedLanPeerId = this.selectedLanPeerId;
    draft.lanAddressMode = this.lanAddressMode;
    draft.label = this.label;
    draft.controlId = this.controlId;
    draft.directHost = this.directHost;
    draft.directPortText = this.directPortText;
    draft.relayId = this.relayId;
    draft.password = this.password;
    draft.passwordMode = this.passwordMode;
    draft.totpEntryId = this.totpEntryId;
    draft.totpAutoSubmit = this.totpAutoSubmit && this.totpEntryId !== '';
    draft.targetDevice = this.targetDevice;
    draft.adaptiveOrientation = this.adaptiveOrientation;
    return draft;
  }

  private manageRelays(): void {
    this.errorText = '';
    this.onManageRelays(this.currentDraft());
  }

  private selectedRelay(): RustDeskRelayConfig | undefined {
    return this.relays.find((relay: RustDeskRelayConfig): boolean => relay.id === this.relayId);
  }

  private parsedDirectEndpoint(): EndpointAddressResult {
    return parseEndpointFields(this.directHost, parseEndpointPortText(this.directPortText));
  }

  private buildHost(): RemoteHost | null {
    const directEndpoint: EndpointAddressResult = this.parsedDirectEndpoint();
    if (this.label.trim() === '') { this.errorText = '请输入主机名称'; return null; }
    if (this.controlId.trim() === '') { this.errorText = '请输入 RustDesk 控制 ID'; return null; }
    if (this.direct && !directEndpoint.ok) {
      this.errorText = directEndpoint.error === 'invalid_port' ? '端口必须在 1-65535 之间' :
        '请输入有效的直连域名、IPv4 或 IPv6 地址';
      return null;
    }
    if (this.direct && directEndpoint.endpoint.scope !== '') {
      this.errorText = 'RustDesk 链路本地 IPv6 尚未完成网卡作用域验证，请先使用全局 IPv6 地址';
      return null;
    }
    if (this.direct && this.password === '') { this.errorText = '直连只支持设备密码，请输入密码'; return null; }
    if (this.direct && this.useLan && this.lanAddressMode !== 'static' &&
      this.lanAddressMode !== 'dynamic') {
      this.errorText = '请选择静态 IP 或动态 IP 策略'; return null;
    }
    if (this.direct && this.useLan &&
      this.controlId.trim() !== this.selectedLanPeerId.trim()) {
      this.errorText = '局域网设备身份已变化，请返回并重新选择'; return null;
    }
    const relay: RustDeskRelayConfig | undefined = this.selectedRelay();
    if (!this.direct && relay === undefined) { this.errorText = '请选择中继服务器'; return null; }
    const host = new RemoteHost();
    host.id = RemoteHost.generateId(); host.protocol = 'rustdesk'; host.label = this.label.trim();
    host.customHostname = this.controlId.trim(); host.password = this.password;
    host.rustdeskPasswordMode = this.passwordMode; host.rustdeskAuthMode = 'password';
    host.rustdeskTotpEntryId = this.totpEntryId;
    host.rustdeskTotpAutoSubmit = this.totpAutoSubmit && this.totpEntryId !== '';
    host.rustdeskDirectEnabled = this.direct;
    host.rustdeskTargetDevice = this.targetDevice;
    host.rustdeskAdaptiveOrientation = this.targetDevice === 'phone' && this.adaptiveOrientation;
    if (this.direct) {
      const canonicalHost: string = endpointTransportHost(directEndpoint.endpoint);
      const port: number = directEndpoint.endpoint.port;
      host.host = canonicalHost; host.port = port;
      host.rustdeskDirectHost = canonicalHost; host.rustdeskDirectPort = port; host.rustdeskRelayId = '';
      if (this.useLan) {
        host.lanAddressMode = this.lanAddressMode === 'dynamic' ? 'dynamic' : 'static';
        host.lanDiscoveryIdentity = this.selectedLanPeerId.trim();
        host.lanLastResolvedAt = Date.now();
      }
    } else if (relay !== undefined) {
      host.host = relay.idServer; host.port = relay.idServerPort; host.rustdeskRelayId = relay.id;
      host.rustdeskDirectHost = ''; host.rustdeskDirectPort = this.defaultDirectPort;
    }
    return host;
  }

  @Builder private field(title: string, value: string, hint: string, change: (value: string) => void,
    password: boolean = false, enabled: boolean = true) {
    Column() {
      Text(title).fontSize(12).fontColor(this.pal().text2).margin({ bottom: 5 })
      TextInput({ text: value, placeholder: hint }).height(44).fontSize(14)
        .type(password ? InputType.Password : InputType.Normal).fontColor(this.pal().text)
        .placeholderColor(this.pal().text3).backgroundColor(this.pal().surface).borderRadius(11)
        .padding({ left: 12, right: 12 }).enabled(enabled).opacity(enabled ? 1 : 0.68)
        .onChange(change)
    }.alignItems(HorizontalAlign.Start).width('100%').margin({ bottom: 12 })
  }

  @Builder private header() {
    Row() {
      Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(18).fontColor([this.pal().text2]) }
        .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
        .onClick((): void => { if (this.step === 1) { this.onBackToProtocols(); } else { this.step--; } })
      Column() {
        Text('添加 RustDesk 主机').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        Text(this.step === 1 ? '1/2  连接模式' : '2/2  主机与认证')
          .fontSize(12).fontColor(this.pal().text3).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
    }.width('100%').margin({ bottom: 18 })
  }

  @Builder private modeButton(title: string, subtitle: string, directMode: boolean) {
    Column() {
      Text(title).fontSize(15).fontWeight(FontWeight.Medium)
        .fontColor(this.direct === directMode ? Color.White : this.pal().text)
      Text(subtitle).fontSize(11)
        .fontColor(this.direct === directMode ? '#DDEEFF' : this.pal().text3).margin({ top: 4 })
    }.alignItems(HorizontalAlign.Start).layoutWeight(1).padding(14).borderRadius(12)
    .backgroundColor(this.direct === directMode ? this.accentColor : this.pal().surface)
    .onClick((): void => { this.direct = directMode; })
  }

  @Builder private targetButton(title: string, subtitle: string, target: RustDeskTargetDevice) {
    Column() {
      Text(title).fontSize(14).fontWeight(FontWeight.Medium)
        .fontColor(this.targetDevice === target ? Color.White : this.pal().text)
      Text(subtitle).fontSize(11)
        .fontColor(this.targetDevice === target ? '#DDEEFF' : this.pal().text3).margin({ top: 4 })
    }.alignItems(HorizontalAlign.Start).layoutWeight(1).padding(12).borderRadius(10)
      .backgroundColor(this.targetDevice === target ? this.accentColor : this.pal().surface)
      .onClick((): void => {
        this.targetDevice = target;
        if (target === 'computer') { this.adaptiveOrientation = false; }
      })
  }

  @Builder private addressPolicyChoice() {
    Text('局域网地址策略（必选）').fontSize(12).fontColor(this.pal().text2)
      .width('100%').margin({ bottom: 8 })
    Row({ space: 8 }) {
      Column() {
        Text('静态 IP').fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(this.lanAddressMode === 'static' ? Color.White : this.pal().text)
        Text('按当前地址保存；正常参与云同步，不自动改地址')
          .fontSize(10).fontColor(this.lanAddressMode === 'static' ? '#EAF3FF' : this.pal().text3)
          .margin({ top: 4 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).padding(12).borderRadius(10)
      .backgroundColor(this.lanAddressMode === 'static' ? this.accentColor : this.pal().surface)
      .onClick((): void => { this.lanAddressMode = 'static'; this.errorText = ''; })
      Column() {
        Text('动态 IP').fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(this.lanAddressMode === 'dynamic' ? Color.White : this.pal().text)
        Text('仅保存在本机；连接前按 RustDesk ID 自动更新 IP')
          .fontSize(10).fontColor(this.lanAddressMode === 'dynamic' ? '#EAF3FF' : this.pal().text3)
          .margin({ top: 4 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).padding(12).borderRadius(10)
      .backgroundColor(this.lanAddressMode === 'dynamic' ? this.accentColor : this.pal().surface)
      .onClick((): void => { this.lanAddressMode = 'dynamic'; this.errorText = ''; })
    }.width('100%').margin({ bottom: 16 })
  }

  build() {
    Column() {
      this.header()
      if (this.step === 1) {
        Row() {
          this.modeButton('中继连接', '通过已配置服务器连接', false)
          Blank().width(8)
          this.modeButton('局域网直连', 'IP + 端口直接连接', true)
        }.width('100%').margin({ bottom: 16 })
        if (!this.direct) {
          if (this.relays.length === 0) {
            Text('还没有中继服务器，请先到中继目录添加。').fontSize(13).fontColor(this.pal().text3)
              .width('100%').textAlign(TextAlign.Center).padding(18)
            Button('前往中继目录').width('100%').height(40).borderRadius(10)
              .backgroundColor(this.pal().surface).fontColor(this.accentColor)
              .onClick((): void => { this.manageRelays(); })
          } else {
            ForEach(this.relays, (relay: RustDeskRelayConfig) => {
              Row() {
                Column() {
                  Text(relay.displayName()).fontSize(14).fontColor(this.pal().text)
                  Text((relay.relayServer.indexOf(':') >= 0 ? '[' + relay.relayServer + ']' : relay.relayServer) +
                    ':' + relay.relayPort.toString()).fontSize(11).fontColor(this.pal().text3)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                if (this.relayId === relay.id) { SymbolGlyph($r('sys.symbol.checkmark')).fontColor([this.accentColor]) }
              }.width('100%').padding(12).borderRadius(10).backgroundColor(this.pal().surface).margin({ bottom: 7 })
              .onClick((): void => { this.relayId = relay.id; })
            }, (relay: RustDeskRelayConfig): string => relay.id + ':' + relay.updatedAt.toString())
            Button('管理中继服务器').width('100%').height(36).borderRadius(9)
              .backgroundColor(this.pal().surface).fontColor(this.accentColor)
              .onClick((): void => { this.manageRelays(); })
          }
        } else {
          Text('直连仅支持设备密码，不能请求被控端批准。').fontSize(12).fontColor(this.pal().danger)
            .width('100%').margin({ bottom: 12 })
          Row() {
            Button('手动配置').layoutWeight(1).height(38).borderRadius(10)
              .backgroundColor(!this.useLan ? this.accentColor : this.pal().surface)
              .fontColor(!this.useLan ? Color.White : this.pal().text2).onClick((): void => {
                this.useLan = false; this.selectedLanPeerId = ''; this.lanAddressMode = '';
              })
            Button('局域网搜索').layoutWeight(1).height(38).borderRadius(10).margin({ left: 8 })
              .backgroundColor(this.useLan ? this.accentColor : this.pal().surface)
              .fontColor(this.useLan ? Color.White : this.pal().text2).onClick((): void => {
                this.useLan = true; this.selectedLanPeerId = ''; this.lanAddressMode = ''; this.onStartLanScan();
              })
          }.width('100%').margin({ bottom: 10 })
          if (this.useLan) {
            if (this.lanScanning) {
              Row() {
                LoadingProgress().width(18).height(18).color(this.accentColor)
                Text('正在搜索同一局域网设备… 已发现 ' + this.lanPeers.length.toString() + ' 台')
                  .fontSize(12).fontColor(this.pal().text3).margin({ left: 8 })
              }.width('100%').margin({ bottom: 8 })
            } else {
              Text(this.lanPeers.length === 0 ? '暂未发现设备，可重试搜索' :
                '发现 ' + this.lanPeers.length.toString() + ' 台设备，请选择一台')
                .fontSize(12).fontColor(this.pal().text3).margin({ bottom: 8 })
            }
            ForEach(this.lanPeers, (peer: DiscoveredRustDeskPeer) => {
              Row() {
                Column() {
                  Text(peer.deviceName).fontSize(14).fontColor(this.pal().text)
                  Text(peer.peerId + ' · ' + peer.host).fontSize(11).fontColor(this.pal().text3)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                if (this.selectedLanPeerId === peer.peerId) {
                  SymbolGlyph($r('sys.symbol.checkmark')).fontSize(18).fontColor([this.accentColor])
                } else {
                  Text('选择').fontSize(12).fontColor(this.accentColor)
                }
              }.width('100%').padding(11).borderRadius(10).backgroundColor(this.pal().surface).margin({ bottom: 6 })
              .border({ width: this.selectedLanPeerId === peer.peerId ? 1 : 0, color: this.accentColor })
              .onClick((): void => {
                this.selectedLanPeerId = peer.peerId; this.label = peer.deviceName; this.controlId = peer.peerId;
                this.directHost = peer.host; this.directPortText = peer.port.toString();
                this.lanAddressMode = '';
              })
            }, (peer: DiscoveredRustDeskPeer): string => peer.peerId)
          }
        }
        Button('下一步').width('100%').height(44).borderRadius(12).margin({ top: 10 })
          .backgroundColor(this.accentColor).fontColor(Color.White).onClick((): void => {
            if (!this.direct && this.selectedRelay() === undefined) { this.errorText = '请选择中继服务器'; return; }
            if (this.direct && this.useLan && this.selectedLanPeerId === '') {
              this.errorText = '请先选择一台已发现的设备'; return;
            }
            this.errorText = ''; this.step = 2;
          })
      } else {
        if (this.direct && this.useLan) { this.addressPolicyChoice() }
        this.field('名称', this.label, '例如：办公室电脑', (v: string): void => { this.label = v; })
        this.field('控制 ID', this.controlId, 'RustDesk 设备 ID',
          (v: string): void => { this.controlId = v; }, false, !this.useLan)
        if (this.direct && this.useLan) {
          Text('控制 ID、直连 IP 和端口来自已选择的搜索结果；如需修改，请返回重新选择或改用手动配置。')
            .fontSize(10).fontColor(this.pal().text3).width('100%').margin({ bottom: 10 })
        }
        Text('控制目标').fontSize(12).fontColor(this.pal().text2).margin({ bottom: 5 })
        Row() {
          this.targetButton('控制电脑', 'Windows / macOS / Linux', 'computer')
          Blank().width(8)
          this.targetButton('控制手机', 'Android / iPhone / 平板', 'phone')
        }.width('100%').margin({ bottom: 10 })
        Row() {
          Column() {
            Text('自适应翻转').fontSize(13).fontColor(this.pal().text)
            Text(this.targetDevice === 'phone' ?
              '根据手机方向切换本机窗口，默认关闭' : '仅控制手机时可用')
              .fontSize(10).fontColor(this.pal().text3).margin({ top: 3 })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.adaptiveOrientation })
            .selectedColor(this.accentColor).scale({ x: 0.86, y: 0.86 })
            .enabled(this.targetDevice === 'phone')
            .onChange((on: boolean): void => {
              this.adaptiveOrientation = this.targetDevice === 'phone' && on;
            })
        }.width('100%').margin({ bottom: 12 })
        if (this.direct) {
          this.field('直连 IP', this.directHost, '例如：192.168.1.10',
            (v: string): void => { this.directHost = v; }, false, !this.useLan)
          this.field('直连端口', this.directPortText, this.defaultDirectPort.toString(),
            (v: string): void => { this.directPortText = v; }, false, !this.useLan)
        }
        this.field(this.direct ? '设备密码' : '设备密码（可选）', this.password,
          this.direct ? '直连必须填写' : '留空时连接前选择密码或请求批准',
          (v: string): void => { this.password = v; }, true)
        Row() {
          Button('一次性密码').layoutWeight(1).height(36).borderRadius(9)
            .backgroundColor(this.passwordMode === 0 ? this.accentColor : this.pal().surface)
            .fontColor(this.passwordMode === 0 ? Color.White : this.pal().text2).onClick((): void => { this.passwordMode = 0; })
          Button('永久密码').layoutWeight(1).height(36).borderRadius(9).margin({ left: 8 })
            .backgroundColor(this.passwordMode === 1 ? this.accentColor : this.pal().surface)
            .fontColor(this.passwordMode === 1 ? Color.White : this.pal().text2).onClick((): void => { this.passwordMode = 1; })
        }.width('100%').margin({ bottom: 14 })
        Column({ space: 6 }) {
          Row() {
            Column() {
              Text('RustDesk 2FA 验证器（可选）').fontSize(12).fontColor(this.pal().text)
              Text(this.totpEntryId === '' ? '未绑定，点击选择本机验证器' : '已绑定本机验证器')
                .fontSize(10).fontColor(this.pal().text3).margin({ top: 2 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([this.pal().text3])
          }.width('100%').padding({ left: 12, right: 10, top: 10, bottom: 10 })
            .borderRadius(10).backgroundColor(this.pal().surface)
            .onClick((): void => { this.onOpenTotpBinding(this.currentDraft()); })
          if (this.totpEntryId !== '') {
            Row() {
              Column() {
                Text('连接时自动生成并填写').fontSize(12).fontColor(this.pal().text)
                Text('仅保存条目 ID，连接前仍需系统身份认证').fontSize(10).fontColor(this.pal().text3)
                  .margin({ top: 2 })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.totpAutoSubmit })
                .selectedColor(this.accentColor).scale({ x: 0.82, y: 0.82 })
                .onChange((on: boolean): void => {
                  this.totpAutoSubmit = this.totpEntryId !== '' && on;
                })
            }.width('100%').padding({ left: 12, right: 8, top: 4, bottom: 4 })
          }
        }.width('100%').margin({ bottom: 14 })
        Row() {
          Button('保存').layoutWeight(1).height(44).borderRadius(12).backgroundColor(this.pal().surface)
            .fontColor(this.accentColor).onClick((): void => { const host = this.buildHost(); if (host) { this.onSave(host, false); } })
          Button('保存并连接').layoutWeight(1).height(44).borderRadius(12).margin({ left: 8 })
            .backgroundColor(this.accentColor).fontColor(Color.White)
            .onClick((): void => { const host = this.buildHost(); if (host) { this.onSave(host, true); } })
        }.width('100%')
      }
      if (this.errorText !== '') {
        Text(this.errorText).fontSize(12).fontColor(this.pal().danger)
          .width('100%').margin({ top: 10 })
      }
    }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 22 })
      .backgroundColor(this.pal().sheetBg)
  }
}
