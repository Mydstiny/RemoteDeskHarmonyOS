import { Palette, buildDark, buildLight } from '../../common/Theme';
import { RemoteHost } from '../../model/RemoteHost';
import { SshKey } from '../../model/SshKey';
import { KeyVaultService } from '../../services/KeyVaultService';
import { ModernKeyVaultAddFlow } from '../resourceadd/modern/ModernKeyVaultAddFlow';
import { SshProxyEditor } from '../ssh/SshProxyEditor';
import { SshProxyProfileV1 } from '../../services/SshProxyProfilePolicy';
import {
  SshProxyEditorBuildResult,
  SshProxyEditorValue,
  applySshProxyProfileToLegacyHost,
  buildSshProxyProfile,
  defaultSshProxyEditorValue
} from '../../services/SshProxyEditorPolicy';
import {
  EndpointAddressResult,
  endpointTransportHost,
  parseEndpointFields,
  parseEndpointPortText
} from '../../services/EndpointAddressPolicy';

@Component
export struct SshAddFlow {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop @Watch('onKeysChanged') keys: SshKey[] = [];
  onBackToProtocols: () => void = (): void => {};
  onClose: () => void = (): void => {};
  onSave: (host: RemoteHost, connectNow: boolean, proxyProfile: SshProxyProfileV1) => void =
    (_host: RemoteHost, _connectNow: boolean, _proxyProfile: SshProxyProfileV1): void => {};
  @State step: number = 1;
  @State label: string = '';
  @State address: string = '';
  @State portText: string = '22';
  @State username: string = '';
  @State useKey: boolean = false;
  @State password: string = '';
  @State keyId: string = '';
  @State passphrase: string = '';
  @State proxyEditorValue: SshProxyEditorValue = defaultSshProxyEditorValue();
  @State addingKey: boolean = false;
  @State newlyAddedKeys: SshKey[] = [];
  @State errorText: string = '';

  private keyVault = KeyVaultService.getInstance();
  private pendingProxyProfile: SshProxyProfileV1 | null = null;

  private onKeysChanged(): void {
    this.newlyAddedKeys = [];
  }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor); }

  private parsedEndpoint(): EndpointAddressResult {
    return parseEndpointFields(this.address, parseEndpointPortText(this.portText));
  }

  private endpointIsAccepted(parsed: EndpointAddressResult): boolean {
    if (!parsed.ok) {
      this.errorText = parsed.error === 'invalid_port' ? '端口必须在 1-65535 之间' :
        '请输入有效的域名、IPv4 或 IPv6 地址';
      return false;
    }
    if (parsed.endpoint.scope !== '') {
      this.errorText = 'SSH 链路本地 IPv6 尚未完成网卡作用域验证，请先使用全局 IPv6 地址';
      return false;
    }
    return true;
  }

  private buildHost(): RemoteHost | null {
    const parsed: EndpointAddressResult = this.parsedEndpoint();
    if (this.label.trim() === '' || this.username.trim() === '') {
      this.errorText = '请完整填写名称、地址和用户名'; return null;
    }
    if (!this.endpointIsAccepted(parsed)) { return null; }
    const port: number = parsed.endpoint.port;
    if (!this.useKey && this.password === '') { this.errorText = '请输入 SSH 密码'; return null; }
    if (this.useKey && this.keyId === '') { this.errorText = '请选择或导入 SSH 私钥'; return null; }
    const host = new RemoteHost();
    host.id = RemoteHost.generateId(); host.protocol = 'ssh'; host.label = this.label.trim();
    host.host = endpointTransportHost(parsed.endpoint); host.port = port; host.username = this.username.trim();
    host.password = this.useKey ? '' : this.password; host.sshUseKey = this.useKey;
    host.sshKeyId = this.useKey ? this.keyId : ''; host.sshKeyPassphrase = this.useKey ? this.passphrase : '';
    host.sshKeyData = ''; host.sshKeyPath = '';
    const proxy: SshProxyEditorBuildResult = buildSshProxyProfile(
      host.id, host.host, host.port, this.proxyEditorValue);
    if (!proxy.valid || proxy.profile === null) {
      this.errorText = proxy.message || '连接方式配置无效';
      return null;
    }
    applySshProxyProfileToLegacyHost(host, proxy.profile);
    this.pendingProxyProfile = proxy.profile;
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
      Button() {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
      }.width(44).height(44).borderRadius(22).padding(0).backgroundColor(this.pal().surface)
        .onClick((): void => { this.onClose(); })
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
        Column() {
            this.header()
            if (this.step === 1) {
              this.field('名称', this.label, '例如：生产服务器', (v: string): void => { this.label = v; })
              this.field('地址', this.address, 'IP 地址或域名', (v: string): void => { this.address = v; })
              this.field('端口', this.portText, '22', (v: string): void => { this.portText = v; })
              this.field('用户名', this.username, 'SSH 登录用户名', (v: string): void => { this.username = v; })
              SshProxyEditor({
                keys: this.availableKeys(),
                onChange: (value: SshProxyEditorValue): void => { this.proxyEditorValue = value; }
              })
              Button('下一步').width('100%').height(44).borderRadius(12).backgroundColor(this.accentColor)
                .fontColor(Color.White).onClick((): void => {
                  const parsed: EndpointAddressResult = this.parsedEndpoint();
                  if (this.label.trim() === '' || this.username.trim() === '') {
                    this.errorText = '请完整填写基础信息和有效端口'; return;
                  }
                  if (!this.endpointIsAccepted(parsed)) { return; }
                  const port: number = parsed.endpoint.port;
                  const proxy: SshProxyEditorBuildResult = buildSshProxyProfile(
                    'draft-host', endpointTransportHost(parsed.endpoint), port, this.proxyEditorValue);
                  if (!proxy.valid) { this.errorText = proxy.message || '连接方式配置无效'; return; }
                  this.errorText = ''; this.step = 2;
                })
            } else {
              Row() {
                Button('密码登录').layoutWeight(1).height(38).borderRadius(10)
                  .backgroundColor(!this.useKey ? this.accentColor : this.pal().surface)
                  .fontColor(!this.useKey ? Color.White : this.pal().text2)
                  .onClick((): void => { this.useKey = false; })
                Button('密钥登录').layoutWeight(1).height(38).borderRadius(10).margin({ left: 8 })
                  .backgroundColor(this.useKey ? this.accentColor : this.pal().surface)
                  .fontColor(this.useKey ? Color.White : this.pal().text2).onClick((): void => {
                    const keys = this.availableKeys();
                    this.useKey = true;
                    if (this.keyId === '' && keys.length > 0) { this.keyId = keys[0].id; }
                  })
              }.width('100%').margin({ bottom: 14 })
              if (!this.useKey) {
                this.field('密码', this.password, 'SSH 登录密码',
                  (v: string): void => { this.password = v; }, true)
              } else {
                if (this.availableKeys().length === 0) {
                  Text('密钥保险库为空，请添加或导入 SSH 私钥。').fontSize(12).fontColor(this.pal().text3)
                    .width('100%').textAlign(TextAlign.Center).padding(14)
                } else {
                  ForEach(this.availableKeys(), (key: SshKey) => {
                    Row() {
                      Column() {
                        Text(key.label !== '' ? key.label : SshKey.typeLabel(key.keyType))
                          .fontSize(14).fontColor(this.pal().text)
                        Text(key.fingerprint !== '' ? key.fingerprint : SshKey.typeLabel(key.keyType))
                          .fontSize(10).fontColor(this.pal().text3).maxLines(1)
                      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                      if (this.keyId === key.id) {
                        SymbolGlyph($r('sys.symbol.checkmark')).fontColor([this.accentColor])
                      }
                    }.width('100%').padding(11).borderRadius(10)
                      .backgroundColor(this.pal().surface).margin({ bottom: 6 })
                      .onClick((): void => { this.keyId = key.id; })
                  }, (key: SshKey): string => key.id + ':' + key.createdAt.toString())
                }
                Button('添加到 SSH 密钥保险库').width('100%').height(38).borderRadius(10)
                  .backgroundColor(this.pal().surface).fontColor(this.accentColor)
                  .onClick((): void => { this.addingKey = true; }).margin({ bottom: 12 })
                this.field('私钥密码（如有）', this.passphrase, '加密私钥的 passphrase',
                  (v: string): void => { this.passphrase = v; }, true)
              }
              Row() {
                Button('保存').layoutWeight(1).height(44).borderRadius(12)
                  .backgroundColor(this.pal().surface).fontColor(this.accentColor)
                  .onClick((): void => {
                    const host = this.buildHost();
                    if (host && this.pendingProxyProfile) {
                      this.onSave(host, false, this.pendingProxyProfile);
                    }
                  })
                Button('保存并连接').layoutWeight(1).height(44).borderRadius(12).margin({ left: 8 })
                  .backgroundColor(this.accentColor).fontColor(Color.White)
                  .onClick((): void => {
                    const host = this.buildHost();
                    if (host && this.pendingProxyProfile) {
                      this.onSave(host, true, this.pendingProxyProfile);
                    }
                  })
              }.width('100%')
            }
            if (this.errorText !== '') {
              Text(this.errorText).fontSize(12).fontColor(this.pal().danger).margin({ top: 10 })
            }
          }.width('100%')
      }
      // The host-add sheet owns the responsive width on PC. A fixed 900vp
      // child overflows the centered system sheet (roughly 500vp on the
      // current PC profile), clipping the proxy choices and action buttons.
      // Keep the SSH flow inside its parent just like the other host flows.
      .width('100%')
      .height('auto')
        .padding({ left: 20, right: 20, top: 20, bottom: 22 })
        .backgroundColor(this.pal().sheetBg)
    }
  }
}
