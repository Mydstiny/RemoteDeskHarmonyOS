import { Palette, buildDark, buildLight } from '../../common/Theme';
import { RemoteHost } from '../../model/RemoteHost';
import { RustDeskRelayConfig } from '../../model/RustDeskRelayConfig';
import { DiscoveredRustDeskPeer } from '../../services/RustDeskLanDiscoveryService';

@Component
export struct RustDeskAddFlow {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop relays: RustDeskRelayConfig[] = [];
  @Prop lanScanning: boolean = false;
  @Prop lanPeers: DiscoveredRustDeskPeer[] = [];
  @Prop defaultDirectPort: number = 21117;
  onBackToProtocols: () => void = (): void => {};
  onStartLanScan: () => void = (): void => {};
  onAddRelay: (relay: RustDeskRelayConfig) => boolean = (_relay: RustDeskRelayConfig): boolean => false;
  onSave: (host: RemoteHost, connectNow: boolean) => void =
    (_host: RemoteHost, _connectNow: boolean): void => {};
  @State step: number = 1;
  @State direct: boolean = false;
  @State useLan: boolean = false;
  @State selectedLanPeerId: string = '';
  @State label: string = '';
  @State controlId: string = '';
  @State directHost: string = '';
  @State directPortText: string = '21117';
  @State relayId: string = '';
  @State password: string = '';
  @State passwordMode: number = 0;
  @State errorText: string = '';
  @State addingRelay: boolean = false;
  @State relayIdServer: string = '';
  @State relayIdServerPortText: string = '21116';
  @State relayServer: string = '';
  @State relayServerPortText: string = '21117';
  @State relayApiServer: string = '';
  @State relayKey: string = '';

  aboutToAppear(): void { this.directPortText = this.defaultDirectPort.toString(); }
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor); }

  private selectedRelay(): RustDeskRelayConfig | undefined {
    return this.relays.find((relay: RustDeskRelayConfig): boolean => relay.id === this.relayId);
  }

  private buildHost(): RemoteHost | null {
    const port: number = parseInt(this.directPortText);
    if (this.label.trim() === '') { this.errorText = '请输入主机名称'; return null; }
    if (this.controlId.trim() === '') { this.errorText = '请输入 RustDesk 控制 ID'; return null; }
    if (this.direct && this.directHost.trim() === '') { this.errorText = '请输入直连 IP，或先进行局域网搜索'; return null; }
    if (this.direct && (isNaN(port) || port <= 0 || port > 65535)) { this.errorText = '端口必须在 1-65535 之间'; return null; }
    if (this.direct && this.password === '') { this.errorText = '直连只支持设备密码，请输入密码'; return null; }
    const relay: RustDeskRelayConfig | undefined = this.selectedRelay();
    if (!this.direct && relay === undefined) { this.errorText = '请选择中继服务器'; return null; }
    const host = new RemoteHost();
    host.id = RemoteHost.generateId(); host.protocol = 'rustdesk'; host.label = this.label.trim();
    host.customHostname = this.controlId.trim(); host.password = this.password;
    host.rustdeskPasswordMode = this.passwordMode; host.rustdeskAuthMode = 'password';
    host.rustdeskDirectEnabled = this.direct;
    if (this.direct) {
      host.host = this.directHost.trim(); host.port = port;
      host.rustdeskDirectHost = host.host; host.rustdeskDirectPort = port; host.rustdeskRelayId = '';
    } else if (relay !== undefined) {
      host.host = relay.idServer; host.port = relay.idServerPort; host.rustdeskRelayId = relay.id;
      host.rustdeskDirectHost = ''; host.rustdeskDirectPort = this.defaultDirectPort;
    }
    return host;
  }

  private saveRelay(): void {
    if (this.relayIdServer.trim() === '' || this.relayServer.trim() === '') {
      this.errorText = 'ID 服务器和中继服务器不能为空'; return;
    }
    const idServerPort: number = parseInt(this.relayIdServerPortText);
    const relayPort: number = parseInt(this.relayServerPortText);
    if (isNaN(idServerPort) || idServerPort <= 0 || idServerPort > 65535 ||
      isNaN(relayPort) || relayPort <= 0 || relayPort > 65535) {
      this.errorText = '服务器端口必须在 1-65535 之间'; return;
    }
    const relay = new RustDeskRelayConfig();
    relay.id = RustDeskRelayConfig.generateId();
    relay.idServer = this.relayIdServer.trim();
    relay.idServerPort = idServerPort;
    relay.relayServer = this.relayServer.trim();
    relay.relayPort = relayPort;
    relay.apiServer = this.relayApiServer.trim();
    relay.key = this.relayKey.trim();
    relay.updatedAt = Date.now();
    if (!this.onAddRelay(relay)) { this.errorText = '保存中继服务器失败'; return; }
    this.relayId = relay.id;
    this.addingRelay = false;
    this.errorText = '';
  }

  @Builder private field(title: string, value: string, hint: string, change: (value: string) => void,
    password: boolean = false) {
    Column() {
      Text(title).fontSize(12).fontColor(this.pal().text2).margin({ bottom: 5 })
      TextInput({ text: value, placeholder: hint }).height(44).fontSize(14)
        .type(password ? InputType.Password : InputType.Normal).fontColor(this.pal().text)
        .placeholderColor(this.pal().text3).backgroundColor(this.pal().surface).borderRadius(11)
        .padding({ left: 12, right: 12 }).onChange(change)
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
          if (this.addingRelay) {
            this.field('ID 服务器', this.relayIdServer, 'hbbs.example.com',
              (v: string): void => { this.relayIdServer = v; })
            this.field('ID 服务器端口', this.relayIdServerPortText, '21116',
              (v: string): void => { this.relayIdServerPortText = v; })
            this.field('中继服务器', this.relayServer, 'hbbr.example.com',
              (v: string): void => { this.relayServer = v; })
            this.field('中继服务器端口', this.relayServerPortText, '21117',
              (v: string): void => { this.relayServerPortText = v; })
            this.field('API 地址（可选）', this.relayApiServer, 'https://api.example.com',
              (v: string): void => { this.relayApiServer = v; })
            this.field('服务器密钥（Pro 必填）', this.relayKey, '可选，粘贴 hbbs 公钥',
              (v: string): void => { this.relayKey = v; })
            Row() {
              Button('取消').layoutWeight(1).height(38).borderRadius(10).backgroundColor(this.pal().surface)
                .fontColor(this.pal().text2).onClick((): void => { this.addingRelay = false; })
              Button('保存并选择').layoutWeight(1).height(38).borderRadius(10).margin({ left: 8 })
                .backgroundColor(this.accentColor).fontColor(Color.White).onClick((): void => { this.saveRelay(); })
            }.width('100%')
          } else if (this.relays.length === 0) {
            Text('还没有中继服务器，请先添加后再继续。').fontSize(13).fontColor(this.pal().text3)
              .width('100%').textAlign(TextAlign.Center).padding(18)
            Button('添加中继服务器').width('100%').height(40).borderRadius(10)
              .backgroundColor(this.pal().surface).fontColor(this.accentColor)
              .onClick((): void => { this.addingRelay = true; })
          } else {
            ForEach(this.relays, (relay: RustDeskRelayConfig) => {
              Row() {
                Column() {
                  Text(relay.displayName()).fontSize(14).fontColor(this.pal().text)
                  Text(relay.relayServer + ':' + relay.relayPort.toString()).fontSize(11).fontColor(this.pal().text3)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                if (this.relayId === relay.id) { SymbolGlyph($r('sys.symbol.checkmark')).fontColor([this.accentColor]) }
              }.width('100%').padding(12).borderRadius(10).backgroundColor(this.pal().surface).margin({ bottom: 7 })
              .onClick((): void => { this.relayId = relay.id; })
            }, (relay: RustDeskRelayConfig): string => relay.id + ':' + relay.updatedAt.toString())
            Button('添加其他中继服务器').width('100%').height(36).borderRadius(9)
              .backgroundColor(this.pal().surface).fontColor(this.accentColor)
              .onClick((): void => { this.addingRelay = true; })
          }
        } else {
          Text('直连仅支持设备密码，不能请求被控端批准。').fontSize(12).fontColor(this.pal().danger)
            .width('100%').margin({ bottom: 12 })
          Row() {
            Button('手动配置').layoutWeight(1).height(38).borderRadius(10)
              .backgroundColor(!this.useLan ? this.accentColor : this.pal().surface)
              .fontColor(!this.useLan ? Color.White : this.pal().text2).onClick((): void => { this.useLan = false; })
            Button('局域网搜索').layoutWeight(1).height(38).borderRadius(10).margin({ left: 8 })
              .backgroundColor(this.useLan ? this.accentColor : this.pal().surface)
              .fontColor(this.useLan ? Color.White : this.pal().text2).onClick((): void => {
                this.useLan = true; this.selectedLanPeerId = ''; this.onStartLanScan();
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
        this.field('名称', this.label, '例如：办公室电脑', (v: string): void => { this.label = v; })
        this.field('控制 ID', this.controlId, 'RustDesk 设备 ID', (v: string): void => { this.controlId = v; })
        if (this.direct) {
          this.field('直连 IP', this.directHost, '例如：192.168.1.10', (v: string): void => { this.directHost = v; })
          this.field('直连端口', this.directPortText, this.defaultDirectPort.toString(),
            (v: string): void => { this.directPortText = v; })
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
        Row() {
          Button('保存').layoutWeight(1).height(44).borderRadius(12).backgroundColor(this.pal().surface)
            .fontColor(this.accentColor).onClick((): void => { const host = this.buildHost(); if (host) { this.onSave(host, false); } })
          Button('保存并连接').layoutWeight(1).height(44).borderRadius(12).margin({ left: 8 })
            .backgroundColor(this.accentColor).fontColor(Color.White)
            .onClick((): void => { const host = this.buildHost(); if (host) { this.onSave(host, true); } })
        }.width('100%')
      }
      if (this.errorText !== '') { Text(this.errorText).fontSize(12).fontColor(this.pal().danger).margin({ top: 10 }) }
    }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 22 }).backgroundColor(this.pal().card)
  }
}
