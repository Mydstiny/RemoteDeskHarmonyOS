/** Two-step RDP add flow: endpoint first, then authentication. */
import { RdpCredential } from '../../model/RdpCredential';
import { RemoteHost } from '../../model/RemoteHost';
import { Palette, buildDark, buildLight } from '../../common/Theme';

@Component
export struct RdpAddFlow {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop @Watch('onCredentialsChanged') credentials: RdpCredential[] = [];
  onBackToProtocols: () => void = (): void => {};
  onAddCredential: () => void = (): void => {};
  onSave: (host: RemoteHost, connectNow: boolean) => void =
    (_host: RemoteHost, _connectNow: boolean): void => {};
  @State step: number = 1;
  @State label: string = '';
  @State hostAddress: string = '';
  @State portText: string = '3389';
  @State username: string = '';
  @State password: string = '';
  @State credentialId: string = '';
  @State errorText: string = '';
  @State credentialsViewRevision: number = 0;
  private awaitingNewCredential: boolean = false;
  private credentialIdsBeforeAdd: string[] = [];

  private onCredentialsChanged(): void {
    this.credentialsViewRevision += 1;
    if (!this.awaitingNewCredential) { return; }
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

  private buildHost(): RemoteHost | null {
    const port: number = parseInt(this.portText);
    if (this.label.trim() === '') { this.errorText = '请输入主机名称'; return null; }
    if (this.hostAddress.trim() === '') { this.errorText = '请输入主机地址'; return null; }
    if (isNaN(port) || port <= 0 || port > 65535) { this.errorText = '端口必须在 1-65535 之间'; return null; }
    if (this.credentialId === '' && (this.username.trim() === '' || this.password === '')) {
      this.errorText = '请输入账号和密码，或选择 Windows 凭据'; return null;
    }
    const host = new RemoteHost();
    host.id = RemoteHost.generateId();
    host.protocol = 'rdp';
    host.label = this.label.trim();
    host.host = this.hostAddress.trim();
    host.port = port;
    host.username = this.credentialId === '' ? this.username.trim() : '';
    host.password = this.credentialId === '' ? this.password : '';
    host.rdpCredentialId = this.credentialId;
    return host;
  }

  @Builder private inputField(title: string, value: string, hint: string,
    onChange: (value: string) => void, password: boolean = false) {
    Column() {
      Text(title).fontSize(12).fontColor(this.pal().text2).margin({ bottom: 5 })
      TextInput({ text: value, placeholder: hint }).height(44).fontSize(14)
        .type(password ? InputType.Password : InputType.Normal)
        .fontColor(this.pal().text).placeholderColor(this.pal().text3)
        .backgroundColor(this.pal().surface).borderRadius(11).padding({ left: 12, right: 12 })
        .onChange(onChange)
    }.alignItems(HorizontalAlign.Start).width('100%').margin({ bottom: 12 })
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
        this.inputField('名称', this.label, '例如：办公室电脑', (v: string): void => { this.label = v; })
        this.inputField('地址', this.hostAddress, 'IP 地址或域名', (v: string): void => { this.hostAddress = v; })
        this.inputField('端口', this.portText, '3389', (v: string): void => { this.portText = v; })
        Button('下一步').width('100%').height(44).borderRadius(12)
          .backgroundColor(this.accentColor).fontColor(Color.White)
          .onClick((): void => {
            const port: number = parseInt(this.portText);
            if (this.label.trim() === '' || this.hostAddress.trim() === '' || isNaN(port) || port <= 0 || port > 65535) {
              this.errorText = '请完整填写名称、地址和有效端口'; return;
            }
            this.errorText = ''; this.step = 2;
          })
      } else {
        Text('认证方式').fontSize(12).fontColor(this.pal().text2).width('100%').margin({ bottom: 8 })
        Row() {
          Button('账号密码').layoutWeight(1).height(38).borderRadius(10)
            .backgroundColor(this.credentialId === '' ? this.accentColor : this.pal().surface)
            .fontColor(this.credentialId === '' ? Color.White : this.pal().text2)
            .onClick((): void => { this.credentialId = ''; })
          Button('Windows 凭据').layoutWeight(1).height(38).borderRadius(10).margin({ left: 8 })
            .backgroundColor(this.credentialId !== '' ? this.accentColor : this.pal().surface)
            .fontColor(this.credentialId !== '' ? Color.White : this.pal().text2)
            .onClick((): void => {
              if (this.credentials.length > 0) { this.credentialId = this.credentials[0].id; }
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
          }, (credential: RdpCredential): string =>
            credential.id + ':' + this.credentialsViewRevision.toString())
        }
        Button('添加 Windows 凭据').width('100%').height(38).borderRadius(10)
          .backgroundColor(this.pal().surface).fontColor(this.accentColor).margin({ bottom: 12 })
          .onClick((): void => {
            this.credentialIdsBeforeAdd = this.credentials.map((credential: RdpCredential): string => credential.id);
            this.awaitingNewCredential = true;
            this.onAddCredential();
          })
        Row() {
          Button('保存').layoutWeight(1).height(44).borderRadius(12).backgroundColor(this.pal().surface)
            .fontColor(this.accentColor).onClick((): void => {
              const host: RemoteHost | null = this.buildHost(); if (host) { this.onSave(host, false); }
            })
          Button('保存并连接').layoutWeight(1).height(44).borderRadius(12).margin({ left: 8 })
            .backgroundColor(this.accentColor).fontColor(Color.White).onClick((): void => {
              const host: RemoteHost | null = this.buildHost(); if (host) { this.onSave(host, true); }
            })
        }.width('100%')
      }
      if (this.errorText !== '') {
        Text(this.errorText).fontSize(12).fontColor(this.pal().danger).margin({ top: 10 })
      }
    }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 22 })
    .backgroundColor(this.pal().card)
  }
}
