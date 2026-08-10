import { Palette, buildDark, buildLight } from '../../common/Theme';
import { SshKey } from '../../model/SshKey';
import {
  SshProxyEditorAuthMethod,
  SshProxyEditorKind,
  SshProxyEditorValue,
  SshProxyHopDraft,
  defaultSshProxyEditorValue,
  defaultSshProxyHop
} from '../../services/SshProxyEditorPolicy';

@Component
export struct SshProxyEditor {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @Prop keys: SshKey[] = [];
  @Prop value: SshProxyEditorValue = defaultSshProxyEditorValue();
  onChange: (value: SshProxyEditorValue) => void = (_value: SshProxyEditorValue): void => {};
  @State kind: SshProxyEditorKind = 'direct';
  @State proxyHost: string = '';
  @State proxyPortText: string = '8080';
  @State proxyUsername: string = '';
  @State proxyAuthRequired: boolean = false;
  @State hops: SshProxyHopDraft[] = [defaultSshProxyHop(0)];
  @State selectedHop: number = 0;

  private cloneHop(hop: SshProxyHopDraft): SshProxyHopDraft {
    return {
      hopId: hop.hopId, label: hop.label, host: hop.host, portText: hop.portText,
      username: hop.username, authMethod: hop.authMethod, keyId: hop.keyId,
      expectedHostKeyFingerprintSha256: hop.expectedHostKeyFingerprintSha256,
      connectTimeoutMs: hop.connectTimeoutMs
    };
  }

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private snapshot(): SshProxyEditorValue {
    return {
      kind: this.kind, proxyHost: this.proxyHost, proxyPortText: this.proxyPortText,
      proxyUsername: this.proxyUsername, proxyAuthRequired: this.proxyAuthRequired,
      hops: this.hops.map((hop: SshProxyHopDraft): SshProxyHopDraft => this.cloneHop(hop))
    };
  }

  private publish(): void { this.onChange(this.snapshot()); }

  private selectKind(kind: SshProxyEditorKind): void {
    this.kind = kind;
    if (kind === 'http_connect' && this.proxyPortText === '') { this.proxyPortText = '8080'; }
    if (kind === 'socks5' && (this.proxyPortText === '' || this.proxyPortText === '8080')) {
      this.proxyPortText = '1080';
    }
    if (kind === 'frp_tcp' && (this.proxyPortText === '' || this.proxyPortText === '1080')) {
      this.proxyPortText = '60022';
    }
    if (kind === 'ssh_jump' && this.hops.length === 0) { this.hops = [defaultSshProxyHop(0)]; }
    this.publish();
  }

  private updateHop(index: number, update: (hop: SshProxyHopDraft) => void): void {
    if (index < 0 || index >= this.hops.length) { return; }
    const next: SshProxyHopDraft[] = this.hops.map(
      (hop: SshProxyHopDraft): SshProxyHopDraft => this.cloneHop(hop));
    update(next[index]);
    if (next[index].authMethod !== 'publickey') { next[index].keyId = ''; }
    this.hops = next;
    this.publish();
  }

  private addHop(): void {
    if (this.hops.length >= 3) { return; }
    this.hops = this.hops.concat([defaultSshProxyHop(this.hops.length)]);
    this.selectedHop = this.hops.length - 1;
    this.publish();
  }

  private removeHop(index: number): void {
    if (this.hops.length <= 1 || index < 0 || index >= this.hops.length) { return; }
    const next: SshProxyHopDraft[] = this.hops.filter((_hop: SshProxyHopDraft, itemIndex: number): boolean =>
      itemIndex !== index).map((hop: SshProxyHopDraft, itemIndex: number): SshProxyHopDraft => {
        const cloned: SshProxyHopDraft = this.cloneHop(hop);
        cloned.label = hop.label.trim().length === 0 ? '跳板机 ' + (itemIndex + 1).toString() : hop.label;
        return cloned;
      });
    this.hops = next;
    this.selectedHop = Math.min(this.selectedHop, next.length - 1);
    this.publish();
  }

  @Builder private field(title: string, value: string, hint: string, change: (value: string) => void) {
    Column({ space: 5 }) {
      Text(title).fontSize(12).fontColor(this.pal().text2)
      TextInput({ text: value, placeholder: hint }).height(44).fontSize(14)
        .fontColor(this.pal().text).placeholderColor(this.pal().text3)
        .backgroundColor(this.pal().surface).borderRadius(10)
        .padding({ left: 12, right: 12 }).onChange(change)
    }.alignItems(HorizontalAlign.Start).width('100%').margin({ bottom: 12 })
  }

  @Builder private routeButton(label: string, value: SshProxyEditorKind) {
    Button(label).width('100%').height(44).borderRadius(10).fontSize(13)
      .backgroundColor(this.kind === value ? this.accentColor : this.pal().surface)
      .fontColor(this.kind === value ? Color.White : this.pal().text2)
      .onClick((): void => { this.selectKind(value); })
  }

  @Builder private compactRouteButton(label: string, value: SshProxyEditorKind) {
    Button(label).layoutWeight(1).height(40).borderRadius(10).fontSize(11)
      .backgroundColor(this.kind === value ? this.accentColor : this.pal().surface)
      .fontColor(this.kind === value ? Color.White : this.pal().text2)
      .onClick((): void => { this.selectKind(value); })
  }

  @Builder private routeSelector() {
    Column({ space: 8 }) {
      this.routeButton('直连', 'direct')
      this.routeButton('HTTP CONNECT', 'http_connect')
      this.routeButton('SOCKS5', 'socks5')
      this.routeButton('SSH 跳板', 'ssh_jump')
      this.routeButton('FRP TCP/Visitor', 'frp_tcp')
    }.width('100%')
  }

  @Builder private authButtons(index: number, hop: SshProxyHopDraft) {
    Row({ space: 8 }) {
      ForEach(['password', 'publickey', 'kbd-interactive'], (method: string): void => {
        Button(method === 'password' ? '密码' : (method === 'publickey' ? '私钥' : '交互认证'))
          .layoutWeight(1).height(38).borderRadius(9).fontSize(12)
          .backgroundColor(hop.authMethod === method ? this.accentColor : this.pal().surface)
          .fontColor(hop.authMethod === method ? Color.White : this.pal().text2)
          .onClick((): void => {
            this.updateHop(index, (next: SshProxyHopDraft): void => {
              next.authMethod = method as SshProxyEditorAuthMethod;
            });
          })
      }, (method: string): string => method)
    }.width('100%').margin({ bottom: 12 })
  }

  @Builder private keyPicker(index: number, hop: SshProxyHopDraft) {
    Column({ space: 6 }) {
      Text('跳板机私钥').fontSize(12).fontColor(this.pal().text2).width('100%')
      if (this.keys.length === 0) {
        Text('密钥库为空，请先在 SSH 密钥中添加。').fontSize(12).fontColor(this.pal().text3)
          .width('100%').padding(12).backgroundColor(this.pal().surface).borderRadius(10)
      } else {
        ForEach(this.keys, (key: SshKey): void => {
          Row() {
            Column({ space: 2 }) {
              Text(key.label).fontSize(13).fontColor(this.pal().text).maxLines(1)
              Text(key.fingerprint).fontSize(10).fontColor(this.pal().text3).maxLines(1)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            if (hop.keyId === key.id) {
              SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([this.accentColor])
            }
          }.width('100%').height(52).padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor(this.pal().surface).borderRadius(10)
            .onClick((): void => { this.updateHop(index, (next: SshProxyHopDraft): void => { next.keyId = key.id; }); })
        }, (key: SshKey): string => 'proxy-key-' + key.id)
      }
    }.width('100%').margin({ bottom: 12 })
  }

  @Builder private hopEditor(index: number) {
    if (index >= 0 && index < this.hops.length) {
      Column() {
        Row() {
          Text('第 ' + (index + 1).toString() + ' 跳').fontSize(16).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text).layoutWeight(1)
          if (this.hops.length > 1) {
            Button('删除').height(36).width(64).borderRadius(9).fontSize(12)
              .backgroundColor(this.pal().surface).fontColor(this.pal().danger)
              .onClick((): void => { this.removeHop(index); })
          }
        }.width('100%').margin({ bottom: 12 })
        this.field('名称', this.hops[index].label, '例如：入口跳板机', (value: string): void => {
          this.updateHop(index, (hop: SshProxyHopDraft): void => { hop.label = value; });
        })
        this.field('地址', this.hops[index].host, 'bastion.example.com', (value: string): void => {
          this.updateHop(index, (hop: SshProxyHopDraft): void => { hop.host = value; });
        })
        Row({ space: 12 }) {
          Column() {
            this.field('端口', this.hops[index].portText, '22', (value: string): void => {
              this.updateHop(index, (hop: SshProxyHopDraft): void => { hop.portText = value; });
            })
          }.layoutWeight(1)
          Column() {
            this.field('用户名', this.hops[index].username, 'jump-user', (value: string): void => {
              this.updateHop(index, (hop: SshProxyHopDraft): void => { hop.username = value; });
            })
          }.layoutWeight(2)
        }.width('100%')
        this.authButtons(index, this.hops[index])
        if (this.hops[index].authMethod === 'publickey') { this.keyPicker(index, this.hops[index]) }
        this.field('Host key 指纹（必填）',
          this.hops[index].expectedHostKeyFingerprintSha256, 'SHA256:...', (value: string): void => {
            this.updateHop(index, (hop: SshProxyHopDraft): void => {
              hop.expectedHostKeyFingerprintSha256 = value;
            });
          })
      }.width('100%')
    }
  }

  @Builder private jumpContent() {
    // Keep every form factor on one predictable vertical flow. This avoids
    // the route selector changing shape between phone, tablet, and PC sheets.
    Column() {
      Row({ space: 8 }) {
        ForEach(this.hops, (hop: SshProxyHopDraft, index: number): void => {
          Button((index + 1).toString()).width(44).height(44).borderRadius(10)
            .backgroundColor(this.selectedHop === index ? this.accentColor : this.pal().surface)
            .fontColor(this.selectedHop === index ? Color.White : this.pal().text2)
            .onClick((): void => { this.selectedHop = index; })
        }, (hop: SshProxyHopDraft): string => hop.hopId)
        if (this.hops.length < 3) {
          Button('+').width(44).height(44).borderRadius(10).backgroundColor(this.pal().surface)
            .fontColor(this.accentColor).onClick((): void => { this.addHop(); })
        }
      }.width('100%').margin({ bottom: 14 })
      this.hopEditor(this.selectedHop)
    }.width('100%')
  }

  @Builder private details() {
    Column() {
      if (this.kind === 'direct') {
        Text('直接连接 SSH 主机，不经过代理或跳板。').fontSize(13)
          .fontColor(this.pal().text2).width('100%').padding(16)
          .backgroundColor(this.pal().surface).borderRadius(12)
      } else if (this.kind === 'ssh_jump') {
        this.jumpContent()
      } else {
        Text(this.kind === 'frp_tcp' ? '填写外部 frpc/frps 或 Visitor 已在本机/网络中暴露的 TCP 入口；App 只连接该入口，不运行 FRP 控制面。' :
          '代理只用于建立到目标 SSH 的 TCP 连接。')
          .fontSize(12).fontColor(this.pal().text2).width('100%').margin({ bottom: 12 })
        this.field(this.kind === 'frp_tcp' ? '外部 FRP TCP/Visitor 入口' : '代理地址', this.proxyHost,
          this.kind === 'frp_tcp' ? '127.0.0.1 或 frps.example.com' : 'proxy.example.com', (value: string): void => {
            this.proxyHost = value; this.publish();
          })
        this.field('端口', this.proxyPortText, this.kind === 'frp_tcp' ? '60022' :
          (this.kind === 'socks5' ? '1080' : '8080'), (value: string): void => {
            this.proxyPortText = value; this.publish();
          })
        if (this.kind === 'http_connect' || this.kind === 'socks5') {
          Row() {
            Column({ space: 3 }) {
              Text('代理认证').fontSize(13).fontColor(this.pal().text)
              Text('密码仅在连接时询问，不保存。').fontSize(11).fontColor(this.pal().text3)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.proxyAuthRequired }).selectedColor(this.accentColor)
              .onChange((enabled: boolean): void => { this.proxyAuthRequired = enabled; this.publish(); })
          }.width('100%').height(52).margin({ bottom: 12 })
          if (this.proxyAuthRequired) {
            this.field('代理用户名', this.proxyUsername, 'proxy-user', (value: string): void => {
              this.proxyUsername = value; this.publish();
            })
          }
        }
      }
    }.width('100%')
  }

  aboutToAppear(): void {
    this.kind = this.value.kind;
    this.proxyHost = this.value.proxyHost;
    this.proxyPortText = this.value.proxyPortText;
    this.proxyUsername = this.value.proxyUsername;
    this.proxyAuthRequired = this.value.proxyAuthRequired;
    this.hops = this.value.hops.map((hop: SshProxyHopDraft): SshProxyHopDraft => this.cloneHop(hop));
    if (this.hops.length === 0) { this.hops = [defaultSshProxyHop(0)]; }
    this.selectedHop = 0;
    this.publish();
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 3 }) {
          Text('连接方式').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          Text('路由与认证相互独立').fontSize(11).fontColor(this.pal().text3)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%')
      // Keep the phone-style compact selector on phone, tablet, and PC.
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          this.compactRouteButton('直连', 'direct')
          this.compactRouteButton('HTTP CONNECT', 'http_connect')
          this.compactRouteButton('SOCKS5', 'socks5')
        }.width('100%')
        Row({ space: 8 }) {
          this.compactRouteButton('SSH 跳板', 'ssh_jump')
          this.compactRouteButton('FRP TCP', 'frp_tcp')
          Blank().layoutWeight(1)
        }.width('100%')
      }.width('100%').margin({ bottom: 2 })
      this.details()
    }.width('100%').padding(16).borderRadius(12).backgroundColor(this.pal().card)
  }
}
