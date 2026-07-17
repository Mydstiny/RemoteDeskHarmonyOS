import { Palette, buildDark, buildLight } from '../../common/Theme';
import { RemoteHost } from '../../model/RemoteHost';
import { SshKey } from '../../model/SshKey';
import { KeyVaultService } from '../../services/KeyVaultService';
import { ModernKeyVaultAddFlow } from '../resourceadd/modern/ModernKeyVaultAddFlow';

@Component
export struct SshAddFlow {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop keys: SshKey[] = [];
  onBackToProtocols: () => void = (): void => {};
  onSave: (host: RemoteHost, connectNow: boolean) => void =
    (_host: RemoteHost, _connectNow: boolean): void => {};
  @State step: number = 1;
  @State label: string = '';
  @State address: string = '';
  @State portText: string = '22';
  @State username: string = '';
  @State useKey: boolean = false;
  @State password: string = '';
  @State keyId: string = '';
  @State passphrase: string = '';
  @State addingKey: boolean = false;
  @State newlyAddedKeys: SshKey[] = [];
  @State errorText: string = '';

  private keyVault = KeyVaultService.getInstance();

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor); }
  private buildHost(): RemoteHost | null {
    const port: number = parseInt(this.portText);
    if (this.label.trim() === '' || this.address.trim() === '' || this.username.trim() === '') {
      this.errorText = '请完整填写名称、地址和用户名'; return null;
    }
    if (isNaN(port) || port <= 0 || port > 65535) { this.errorText = '端口必须在 1-65535 之间'; return null; }
    if (!this.useKey && this.password === '') { this.errorText = '请输入 SSH 密码'; return null; }
    if (this.useKey && this.keyId === '') { this.errorText = '请选择或导入 SSH 私钥'; return null; }
    const host = new RemoteHost();
    host.id = RemoteHost.generateId(); host.protocol = 'ssh'; host.label = this.label.trim();
    host.host = this.address.trim(); host.port = port; host.username = this.username.trim();
    host.password = this.useKey ? '' : this.password; host.sshUseKey = this.useKey;
    host.sshKeyId = this.useKey ? this.keyId : ''; host.sshKeyPassphrase = this.useKey ? this.passphrase : '';
    host.sshKeyData = ''; host.sshKeyPath = '';
    return host;
  }

  private availableKeys(): SshKey[] {
    const result: SshKey[] = this.keys.slice();
    for (let i = 0; i < this.newlyAddedKeys.length; i++) {
      const key = this.newlyAddedKeys[i];
      if (result.find((item: SshKey): boolean => item.id === key.id) === undefined) { result.push(key); }
    }
    return result;
  }

  private onKeySaved(id: string): void {
    const key = this.keyVault.getAllSshKeys().find((item: SshKey): boolean => item.id === id);
    if (key !== undefined && this.newlyAddedKeys.find((item: SshKey): boolean => item.id === id) === undefined) {
      this.newlyAddedKeys = this.newlyAddedKeys.concat([key]);
    }
    this.useKey = true; this.keyId = id; this.passphrase = ''; this.errorText = ''; this.addingKey = false;
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
        .onClick((): void => { if (this.step === 1) { this.onBackToProtocols(); } else { this.step = 1; } })
      Column() {
        Text('添加 SSH 主机').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        Text(this.step === 1 ? '1/2  基础信息' : '2/2  登录认证').fontSize(12).fontColor(this.pal().text3).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
    }.width('100%').margin({ bottom: 18 })
  }

  build() {
    if (this.addingKey) {
      ModernKeyVaultAddFlow({
        resourceKind: 'ssh_key',
        onClose: (): void => { this.addingKey = false; },
        onSaved: (id: string): void => { this.onKeySaved(id); }
      })
    } else {
      Column() {
      this.header()
      if (this.step === 1) {
        this.field('名称', this.label, '例如：生产服务器', (v: string): void => { this.label = v; })
        this.field('地址', this.address, 'IP 地址或域名', (v: string): void => { this.address = v; })
        this.field('端口', this.portText, '22', (v: string): void => { this.portText = v; })
        this.field('用户名', this.username, 'SSH 登录用户名', (v: string): void => { this.username = v; })
        Button('下一步').width('100%').height(44).borderRadius(12).backgroundColor(this.accentColor)
          .fontColor(Color.White).onClick((): void => {
            const port: number = parseInt(this.portText);
            if (this.label.trim() === '' || this.address.trim() === '' || this.username.trim() === '' ||
              isNaN(port) || port <= 0 || port > 65535) { this.errorText = '请完整填写基础信息和有效端口'; return; }
            this.errorText = ''; this.step = 2;
          })
      } else {
        Row() {
          Button('密码登录').layoutWeight(1).height(38).borderRadius(10)
            .backgroundColor(!this.useKey ? this.accentColor : this.pal().surface)
            .fontColor(!this.useKey ? Color.White : this.pal().text2).onClick((): void => { this.useKey = false; })
          Button('密钥登录').layoutWeight(1).height(38).borderRadius(10).margin({ left: 8 })
            .backgroundColor(this.useKey ? this.accentColor : this.pal().surface)
            .fontColor(this.useKey ? Color.White : this.pal().text2).onClick((): void => {
              const keys = this.availableKeys();
              this.useKey = true; if (this.keyId === '' && keys.length > 0) { this.keyId = keys[0].id; }
            })
        }.width('100%').margin({ bottom: 14 })
        if (!this.useKey) {
          this.field('密码', this.password, 'SSH 登录密码', (v: string): void => { this.password = v; }, true)
        } else {
          if (this.availableKeys().length === 0) {
            Text('密钥保险库为空，请添加或导入 SSH 私钥。').fontSize(12).fontColor(this.pal().text3)
              .width('100%').textAlign(TextAlign.Center).padding(14)
          } else {
            ForEach(this.availableKeys(), (key: SshKey) => {
              Row() {
                Column() {
                  Text(key.label !== '' ? key.label : SshKey.typeLabel(key.keyType)).fontSize(14).fontColor(this.pal().text)
                  Text(key.fingerprint !== '' ? key.fingerprint : SshKey.typeLabel(key.keyType))
                    .fontSize(10).fontColor(this.pal().text3).maxLines(1)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                if (this.keyId === key.id) { SymbolGlyph($r('sys.symbol.checkmark')).fontColor([this.accentColor]) }
              }.width('100%').padding(11).borderRadius(10).backgroundColor(this.pal().surface).margin({ bottom: 6 })
              .onClick((): void => { this.keyId = key.id; })
            }, (key: SshKey): string => key.id)
          }
          Button('添加到 SSH 密钥保险库').width('100%').height(38).borderRadius(10)
            .backgroundColor(this.pal().surface).fontColor(this.accentColor)
            .onClick((): void => { this.addingKey = true; }).margin({ bottom: 12 })
          this.field('私钥密码（如有）', this.passphrase, '加密私钥的 passphrase',
            (v: string): void => { this.passphrase = v; }, true)
        }
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
}
