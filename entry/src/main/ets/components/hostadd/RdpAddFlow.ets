/** Two-step RDP add flow: endpoint first, then an explicit authentication mode. */
import { RdpCredential } from '../../model/RdpCredential';
import {
  RemoteHost,
  RdpAuthMode,
  RdpRestrictedAdminSecretSource,
  normalizeRdpNtlmHash
} from '../../model/RemoteHost';
import { Palette, buildDark, buildLight } from '../../common/Theme';
import { DiscoveredRdpHost } from '../../services/RdpLanDiscoveryService';
import {
  EndpointAddressResult,
  endpointTransportHost,
  parseEndpointFields,
  parseEndpointPortText
} from '../../services/EndpointAddressPolicy';

@Component
export struct RdpAddFlow {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop @Watch('onCredentialsChanged') credentials: RdpCredential[] = [];
  @Prop lanScanning: boolean = false;
  @Prop lanHosts: DiscoveredRdpHost[] = [];
  @Prop lanStatusText: string = '';
  onBackToProtocols: () => void = (): void => {};
  onAddCredential: () => void = (): void => {};
  onStartLanScan: (port: number) => void = (_port: number): void => {};
  onSave: (host: RemoteHost, connectNow: boolean, restrictedAdminHash: string) => void =
    (_host: RemoteHost, _connectNow: boolean, _restrictedAdminHash: string): void => {};
  @State step: number = 1;
  @State label: string = '';
  @State hostAddress: string = '';
  @State portText: string = '3389';
  @State targetServerName: string = '';
  @State clientHostname: string = '';
  @State username: string = '';
  @State password: string = '';
  @State credentialId: string = '';
  @State authMode: RdpAuthMode = 'password';
  @State blankPasswordConfirmed: boolean = false;
  @State restrictedAdminSource: RdpRestrictedAdminSecretSource = 'ntlm_hash';
  @State restrictedAdminHash: string = '';
  @State errorText: string = '';
  @State credentialsViewRevision: number = 0;
  @State useLanSearch: boolean = false;
  @State selectedLanStableId: string = '';
  @State selectedLanDynamicCapable: boolean = false;
  @State lanAddressMode: string = '';
  private awaitingNewCredential: boolean = false;
  private credentialIdsBeforeAdd: string[] = [];

  private onCredentialsChanged(): void {
    this.credentialsViewRevision += 1;
    if (!this.awaitingNewCredential || this.authMode !== 'password') { return; }
    const added: RdpCredential | undefined = this.credentials.find((credential: RdpCredential): boolean =>
      this.credentialIdsBeforeAdd.indexOf(credential.id) < 0);
    if (added === undefined) { return; }
    this.credentialId = added.id;
    this.awaitingNewCredential = false;
    this.credentialIdsBeforeAdd = [];
    this.errorText = '';
  }

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private parsedEndpoint(): EndpointAddressResult {
    return parseEndpointFields(this.hostAddress, parseEndpointPortText(this.portText));
  }

  private endpointIsAccepted(parsed: EndpointAddressResult): boolean {
    if (!parsed.ok) {
      this.errorText = parsed.error === 'invalid_port' ? '端口必须在 1-65535 之间' :
        '请输入有效的域名、IPv4 或 IPv6 地址';
      return false;
    }
    if (parsed.endpoint.scope !== '') {
      this.errorText = 'RDP 链路本地 IPv6 尚未完成网卡作用域验证，请先使用全局 IPv6 地址';
      return false;
    }
    return true;
  }

  private selectAuthMode(mode: RdpAuthMode): void {
    this.authMode = mode;
    this.errorText = '';
    if (mode !== 'password') {
      this.credentialId = '';
      this.password = '';
    }
    if (mode !== 'blank_password') { this.blankPasswordConfirmed = false; }
    if (mode !== 'restricted_admin') { this.restrictedAdminHash = ''; }
  }

  private buildHost(): RemoteHost | null {
    const parsed: EndpointAddressResult = this.parsedEndpoint();
    if (this.label.trim() === '') { this.errorText = '请输入主机名称'; return null; }
    if (!this.endpointIsAccepted(parsed)) { return null; }
    const port: number = parsed.endpoint.port;
    const canonicalHost: string = endpointTransportHost(parsed.endpoint);
    if (this.useLanSearch && this.selectedLanStableId === '') {
      this.errorText = '请先选择局域网搜索结果'; return null;
    }
    const selectedLanHost: DiscoveredRdpHost | undefined = this.lanHosts.find(
      (item: DiscoveredRdpHost): boolean => item.stableId === this.selectedLanStableId);
    if (this.useLanSearch && (selectedLanHost === undefined ||
      selectedLanHost.host !== this.hostAddress || selectedLanHost.port !== port)) {
      this.errorText = '局域网搜索结果已变化，请返回并重新选择'; return null;
    }
    if (this.useLanSearch && this.lanAddressMode !== 'static' && this.lanAddressMode !== 'dynamic') {
      this.errorText = '请选择静态 IP 或动态 IP 策略'; return null;
    }
    if (this.useLanSearch && this.lanAddressMode === 'dynamic' && !this.selectedLanDynamicCapable) {
      this.errorText = '该主机没有可用于自动更新的稳定证书身份，请选择静态 IP'; return null;
    }
    if (this.authMode === 'password') {
      if (this.credentialId === '' && (this.username.trim() === '' || this.password === '')) {
        this.errorText = '请输入账号和密码，或选择 Windows 凭据'; return null;
      }
    } else {
      if (this.username.trim() === '') { this.errorText = '请输入本地账户或 Restricted Admin 用户名'; return null; }
      if (this.authMode === 'blank_password' && !this.blankPasswordConfirmed) {
        this.errorText = '请确认目标是允许远程登录的空密码本地账户'; return null;
      }
      if (this.authMode === 'restricted_admin' && this.restrictedAdminSource === 'ntlm_hash') {
        const normalizedHash: string = normalizeRdpNtlmHash(this.restrictedAdminHash);
        if (normalizedHash === '') { this.errorText = 'NTLM Hash 必须是 32 位十六进制字符'; return null; }
        this.restrictedAdminHash = normalizedHash;
      }
    }
    const host = new RemoteHost();
    host.id = RemoteHost.generateId();
    host.protocol = 'rdp';
    host.label = this.label.trim();
    host.host = canonicalHost;
    host.port = port;
    host.customHostname = this.targetServerName;
    host.rdpClientHostname = this.clientHostname;
    if (this.useLanSearch) {
      host.lanAddressMode = this.lanAddressMode === 'dynamic' ? 'dynamic' : 'static';
      host.lanDiscoveryIdentity = this.selectedLanDynamicCapable ? this.selectedLanStableId : '';
      host.lanLastResolvedAt = Date.now();
    }
    host.rdpAuthMode = this.authMode;
    host.rdpRestrictedAdminSecretSource = this.restrictedAdminSource;
    if (this.authMode === 'password') {
      host.username = this.credentialId === '' ? this.username.trim() : '';
      host.password = this.credentialId === '' ? this.password : '';
      host.rdpCredentialId = this.credentialId;
    } else {
      host.username = this.username.trim();
      host.password = '';
      host.rdpCredentialId = '';
    }
    host.normalizeRdpAuthentication();
    return host;
  }

  @Builder private inputField(title: string, value: string, hint: string,
    onChange: (value: string) => void, password: boolean = false, enabled: boolean = true) {
    Column() {
      Text(title).fontSize(12).fontColor(this.pal().text2).margin({ bottom: 5 })
      TextInput({ text: value, placeholder: hint }).height(44).fontSize(14)
        .type(password ? InputType.Password : InputType.Normal)
        .fontColor(this.pal().text).placeholderColor(this.pal().text3)
        .backgroundColor(this.pal().surface).borderRadius(11).padding({ left: 12, right: 12 })
        .enabled(enabled).opacity(enabled ? 1 : 0.68)
        .onChange(onChange)
    }.alignItems(HorizontalAlign.Start).width('100%').margin({ bottom: 12 })
  }

  @Builder private authModeButton(label: string, mode: RdpAuthMode, marginLeft: number = 0) {
    Button(label).layoutWeight(1).height(38).borderRadius(10).margin({ left: marginLeft })
      .backgroundColor(this.authMode === mode ? this.accentColor : this.pal().surface)
      .fontColor(this.authMode === mode ? Color.White : this.pal().text2)
      .fontSize(12)
      .onClick((): void => { this.selectAuthMode(mode); })
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
        Text(this.selectedLanDynamicCapable
          ? '仅保存在本机；连接前按证书身份自动更新 IP'
          : '未取得稳定证书身份，当前主机不可选')
          .fontSize(10).fontColor(this.lanAddressMode === 'dynamic' ? '#EAF3FF' : this.pal().text3)
          .margin({ top: 4 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).padding(12).borderRadius(10)
      .backgroundColor(this.lanAddressMode === 'dynamic' ? this.accentColor : this.pal().surface)
      .opacity(this.selectedLanDynamicCapable ? 1 : 0.5)
      .enabled(this.selectedLanDynamicCapable)
      .onClick((): void => { this.lanAddressMode = 'dynamic'; this.errorText = ''; })
    }.width('100%').margin({ bottom: 16 })
  }

  @Builder private endpointSourceChoice() {
    Row({ space: 8 }) {
      Button('手动填写').layoutWeight(1).height(38).borderRadius(10)
        .backgroundColor(!this.useLanSearch ? this.accentColor : this.pal().surface)
        .fontColor(!this.useLanSearch ? Color.White : this.pal().text2)
        .onClick((): void => {
          this.useLanSearch = false;
          this.selectedLanStableId = '';
          this.selectedLanDynamicCapable = false;
          this.lanAddressMode = '';
          this.errorText = '';
        })
      Button('局域网搜索').layoutWeight(1).height(38).borderRadius(10)
        .backgroundColor(this.useLanSearch ? this.accentColor : this.pal().surface)
        .fontColor(this.useLanSearch ? Color.White : this.pal().text2)
        .onClick((): void => { this.useLanSearch = true; this.errorText = ''; })
    }.width('100%').margin({ bottom: 14 })
  }

  @Builder private lanSearchResults() {
    Text('使用上方当前端口扫描同一局域网；只显示通过 RDP 预检的主机。')
      .fontSize(11).fontColor(this.pal().text3).width('100%').margin({ bottom: 8 })
    Button(this.lanScanning ? '正在搜索…' : '搜索 RDP 主机')
      .width('100%').height(40).borderRadius(10).enabled(!this.lanScanning)
      .backgroundColor(this.pal().surface).fontColor(this.accentColor).margin({ bottom: 10 })
      .onClick((): void => {
        const port: number = parseEndpointPortText(this.portText);
        if (port === 0) {
          this.errorText = '请先填写 1-65535 之间的扫描端口'; return;
        }
        this.onStartLanScan(port);
      })
    if (this.lanStatusText !== '') {
      Text(this.lanStatusText).fontSize(11).fontColor(this.pal().text3)
        .width('100%').margin({ bottom: 8 })
    }
    ForEach(this.lanHosts, (item: DiscoveredRdpHost) => {
      Row() {
        Column() {
          Text(item.deviceName).fontSize(14).fontColor(this.pal().text)
          Text((item.host.indexOf(':') >= 0 ? '[' + item.host + ']' : item.host) + ':' + item.port.toString() +
            (item.dynamicCapable ? ' · 支持动态 IP' : ' · 仅静态 IP'))
            .fontSize(11).fontColor(this.pal().text3).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        if (this.selectedLanStableId === item.stableId) {
          SymbolGlyph($r('sys.symbol.checkmark')).fontSize(18).fontColor([this.accentColor])
        }
      }.width('100%').padding(12).borderRadius(10).margin({ bottom: 6 })
      .backgroundColor(this.pal().surface)
      .onClick((): void => {
        this.selectedLanStableId = item.stableId;
        this.selectedLanDynamicCapable = item.dynamicCapable;
        this.label = item.deviceName;
        this.hostAddress = item.host;
        this.portText = item.port.toString();
        this.lanAddressMode = '';
        this.errorText = '';
      })
    }, (item: DiscoveredRdpHost): string => item.stableId)
  }

  @Builder private passwordAuthenticationFields() {
    Text('普通密码/凭据').fontSize(12).fontColor(this.pal().text3).width('100%').margin({ bottom: 8 })
    Row() {
      Button('账号密码').layoutWeight(1).height(38).borderRadius(10)
        .backgroundColor(this.credentialId === '' ? this.accentColor : this.pal().surface)
        .fontColor(this.credentialId === '' ? Color.White : this.pal().text2)
        .onClick((): void => { this.credentialId = ''; this.errorText = ''; })
      Button('Windows 凭据').layoutWeight(1).height(38).borderRadius(10).margin({ left: 8 })
        .backgroundColor(this.credentialId !== '' ? this.accentColor : this.pal().surface)
        .fontColor(this.credentialId !== '' ? Color.White : this.pal().text2)
        .onClick((): void => {
          if (this.credentials.length > 0) { this.credentialId = this.credentials[0].id; }
          this.errorText = '';
        })
    }.width('100%').margin({ bottom: 14 })
    if (this.credentialId === '') {
      this.inputField('账号', this.username, '邮箱、DOMAIN\\user 或本地用户名',
        (v: string): void => { this.username = v; })
      this.inputField('密码', this.password, 'Windows 登录密码',
        (v: string): void => { this.password = v; }, true)
    } else {
      ForEach(this.credentials, (credential: RdpCredential) => {
        Row() {
          Column() {
            Text(credential.displayName()).fontSize(14).fontColor(this.pal().text)
            Text(credential.username).fontSize(11).fontColor(this.pal().text3).margin({ top: 2 })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          if (this.credentialId === credential.id) {
            SymbolGlyph($r('sys.symbol.checkmark')).fontSize(18).fontColor([this.accentColor])
          }
        }.width('100%').padding(12).borderRadius(10).margin({ bottom: 6 })
        .backgroundColor(this.pal().surface)
        .onClick((): void => { this.credentialId = credential.id; })
      }, (credential: RdpCredential): string => credential.id + ':' + this.credentialsViewRevision.toString())
    }
    Button('添加 Windows 凭据').width('100%').height(38).borderRadius(10)
      .backgroundColor(this.pal().surface).fontColor(this.accentColor).margin({ bottom: 12 })
      .onClick((): void => {
        this.credentialIdsBeforeAdd = this.credentials.map((credential: RdpCredential): string => credential.id);
        this.awaitingNewCredential = true;
        this.onAddCredential();
      })
  }

  @Builder private blankPasswordFields() {
    this.inputField('本地账户', this.username, '.\\user 或 HOST\\user',
      (v: string): void => { this.username = v; })
    Text('密码：空').fontSize(13).fontColor(this.pal().text).width('100%').margin({ bottom: 6 })
    Text('目标 Windows 必须允许空密码本地账户通过远程桌面登录；应用不会修改目标机策略。')
      .fontSize(11).fontColor(this.pal().text3).width('100%').margin({ bottom: 10 })
    Row({ space: 8 }) {
      Checkbox({ name: 'confirmBlankPassword', group: 'rdpAuth' })
        .select(this.blankPasswordConfirmed).selectedColor(this.accentColor)
        .onChange((value: boolean): void => { this.blankPasswordConfirmed = value; })
      Text('我确认这是空密码本地账户，且目标机已允许远程登录。')
        .fontSize(11).fontColor(this.pal().text2).layoutWeight(1)
    }.width('100%').margin({ bottom: 12 })
  }

  @Builder private restrictedAdminFields() {
    this.inputField('账号', this.username, 'DOMAIN\\user 或本地管理员账户',
      (v: string): void => { this.username = v; })
    Text('凭据来源：账户 NTLM Hash（必填）').fontSize(12).fontColor(this.pal().text2)
      .width('100%').margin({ bottom: 6 })
    this.inputField('NTLM Hash', this.restrictedAdminHash, '32 位十六进制 Hash',
      (v: string): void => { this.restrictedAdminHash = v; }, true)
    Text('目标机需开启 Restricted Admin（DisableRestrictedAdmin=0）。应用不会从“空密码”推导 Hash；Hash 仅加密保存在本机，不会云同步。')
      .fontSize(11).fontColor(this.pal().text3).width('100%').margin({ bottom: 12 })
  }

  @Builder private header() {
    Row() {
      Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(18).fontColor([this.pal().text2]) }
        .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
        .onClick((): void => { if (this.step === 1) { this.onBackToProtocols(); } else { this.step = 1; } })
      Column() {
        Text('添加 RDP 主机').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        Text(this.step === 1 ? '1/2  基础信息' : '2/2  Windows 认证')
          .fontSize(12).fontColor(this.pal().text3).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
    }.width('100%').margin({ bottom: 18 })
  }

  build() {
    Column() {
      this.header()
      if (this.step === 1) {
        this.endpointSourceChoice()
        this.inputField('名称', this.label, '例如：办公室电脑', (v: string): void => { this.label = v; })
        this.inputField('地址', this.hostAddress, 'IP 地址或域名',
          (v: string): void => { this.hostAddress = v; }, false,
          !this.useLanSearch || this.selectedLanStableId === '')
        this.inputField('端口', this.portText, '3389',
          (v: string): void => { this.portText = v; }, false,
          !this.useLanSearch || this.selectedLanStableId === '')
        this.inputField('目标服务器名（可选）', this.targetServerName, '证书或 DNS 名称',
          (v: string): void => { this.targetServerName = v; })
        this.inputField('客户端主机名（可选）', this.clientHostname, '发送给 Windows 的客户端名称',
          (v: string): void => { this.clientHostname = v; })
        if (this.useLanSearch) { this.lanSearchResults() }
        Button('下一步').width('100%').height(44).borderRadius(12)
          .backgroundColor(this.accentColor).fontColor(Color.White)
          .onClick((): void => {
            const parsed: EndpointAddressResult = this.parsedEndpoint();
            if (this.label.trim() === '') { this.errorText = '请输入主机名称'; return; }
            if (!this.endpointIsAccepted(parsed)) { return; }
            if (this.useLanSearch && this.selectedLanStableId === '') {
              this.errorText = '请从局域网搜索结果中选择一台主机'; return;
            }
            this.errorText = ''; this.step = 2;
          })
      } else {
        if (this.useLanSearch) { this.addressPolicyChoice() }
        Text('认证方式').fontSize(12).fontColor(this.pal().text2).width('100%').margin({ bottom: 8 })
        Row() {
          this.authModeButton('普通密码/凭据', 'password')
          this.authModeButton('空密码账户', 'blank_password', 6)
          this.authModeButton('Restricted Admin', 'restricted_admin', 6)
        }.width('100%').margin({ bottom: 14 })
        if (this.authMode === 'password') {
          this.passwordAuthenticationFields()
        } else if (this.authMode === 'blank_password') {
          this.blankPasswordFields()
        } else {
          this.restrictedAdminFields()
        }
        Row() {
          Button('保存').layoutWeight(1).height(44).borderRadius(12).backgroundColor(this.pal().surface)
            .fontColor(this.accentColor).onClick((): void => {
              const host: RemoteHost | null = this.buildHost();
              if (host) { this.onSave(host, false, this.authMode === 'restricted_admin' ? this.restrictedAdminHash : ''); }
            })
          Button('保存并连接').layoutWeight(1).height(44).borderRadius(12).margin({ left: 8 })
            .backgroundColor(this.accentColor).fontColor(Color.White).onClick((): void => {
              const host: RemoteHost | null = this.buildHost();
              if (host) { this.onSave(host, true, this.authMode === 'restricted_admin' ? this.restrictedAdminHash : ''); }
            })
        }.width('100%')
      }
      if (this.errorText !== '') {
        Text(this.errorText).fontSize(12).fontColor(this.pal().danger).margin({ top: 10 })
      }
    }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 22 })
    .backgroundColor(this.pal().sheetBg)
  }
}
