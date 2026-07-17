import { promptAction } from '@kit.ArkUI';
import { SshKey, SshKeyType } from '../../../model/SshKey';
import { TotpEntry, TotpAlgorithm } from '../../../model/TotpEntry';
import { KeyVaultService, TotpBatchAddResult } from '../../../services/KeyVaultService';
import { SshKeyImportService, SshKeyImportResult } from '../../../services/SshKeyImportService';
import { TotpImportService, TotpImportResult } from '../../../services/TotpImportService';
import { TotpEngine } from '../../../services/TotpEngine';
import { ExtensionLoader } from '../../../services/ExtensionLoader';
import { GeneratedSshKeyPair, SshPrivateKeyInfo } from '../../../types/rdpnapi';
import { Palette, buildDark, buildLight, AppTheme } from '../../../common/Theme';
import { ResourceFabPicker } from '../ResourceFabPicker';
import { QrCodeScanner } from '../../QrCodeScanner';

@Component
export struct ModernKeyVaultAddFlow {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop resourceKind: string = 'ssh_key';
  onClose: () => void = (): void => {};
  onSaved: (resourceId: string) => void = (_resourceId: string): void => {};

  @State step: string = 'method';
  @State busy: boolean = false;
  @State errorText: string = '';
  @State label: string = '';
  @State comment: string = '';
  @State privateKeyText: string = '';
  @State importedFileName: string = '';
  @State importedKey: SshKey | null = null;
  @State keyType: number = SshKeyType.ED25519;
  @State rsaBits: number = 4096;
  @State passphrase: string = '';
  @State generatedKey: SshKey | null = null;
  @State issuer: string = '';
  @State account: string = '';
  @State secret: string = '';
  @State otpUri: string = '';
  @State digits: number = 6;
  @State period: number = 30;
  @State algorithm: number = TotpAlgorithm.SHA1;
  @State importEntries: TotpEntry[] = [];
  @State selectedImportIds: string[] = [];
  @State importFileName: string = '';
  @State importFormat: string = '';

  private kvs = KeyVaultService.getInstance();
  private sshImporter = new SshKeyImportService();
  private totpImporter = new TotpImportService();
  private loader = ExtensionLoader.getInstance();

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor); }
  private font(): string { return AppTheme.fontFamily; }

  aboutToAppear(): void { this.reset(); }

  private reset(): void {
    this.step = 'method'; this.busy = false; this.errorText = '';
    this.label = ''; this.comment = ''; this.privateKeyText = ''; this.importedFileName = '';
    this.importedKey = null; this.keyType = SshKeyType.ED25519; this.rsaBits = 4096;
    this.passphrase = ''; this.generatedKey = null;
    this.issuer = ''; this.account = ''; this.secret = ''; this.otpUri = '';
    this.digits = 6; this.period = 30; this.algorithm = TotpAlgorithm.SHA1;
    this.importEntries = []; this.selectedImportIds = []; this.importFileName = ''; this.importFormat = '';
  }

  private goBack(): void {
    this.errorText = '';
    if (this.step === 'ssh-preview') { this.step = 'method'; this.privateKeyText = ''; this.importedKey = null; }
    else if (this.step === 'ssh-generate-preview') { this.step = 'ssh-generate'; this.generatedKey = null; }
    else if (this.step === 'totp-file-preview') { this.step = 'method'; this.importEntries = []; this.selectedImportIds = []; }
    else { this.step = 'method'; }
  }

  private selectMethod(option: string): void {
    this.errorText = '';
    if (this.resourceKind === 'ssh_key') {
      if (option === 'file') { void this.pickSshFile(); }
      else if (option === 'generate') { this.step = 'ssh-generate'; }
      else { this.step = 'ssh-paste'; }
      return;
    }
    if (option === 'scan') { this.step = 'totp-scan'; }
    else if (option === 'file') { void this.pickTotpFile(); }
    else if (option === 'uri') { this.step = 'totp-uri'; }
    else { this.step = 'totp-manual'; }
  }

  private async pickSshFile(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true; this.errorText = '';
    const result: SshKeyImportResult | null = await this.sshImporter.pickAndInspect();
    this.busy = false;
    if (result === null) { return; }
    if (!result.ok || result.key === null) { this.errorText = result.error || '私钥文件不可用'; return; }
    this.importedKey = result.key; this.importedFileName = result.fileName;
    this.privateKeyText = result.key.privateKey; this.label = result.key.label;
    this.keyType = result.key.keyType; this.step = 'ssh-preview';
  }

  private inspectPastedKey(): void {
    const result = this.sshImporter.inspectText(this.label.trim() || '粘贴的私钥', this.privateKeyText);
    if (!result.ok || result.key === null) { this.errorText = result.error || '私钥不可用'; return; }
    this.importedKey = result.key; this.keyType = result.key.keyType; this.step = 'ssh-preview'; this.errorText = '';
  }

  private saveImportedKey(): void {
    if (this.importedKey === null || this.label.trim().length === 0) { this.errorText = '请输入密钥名称'; return; }
    const key = SshKey.fromJSON((this.importedKey as SshKey).toJSON());
    if (key.privateKeyEncrypted && this.passphrase.length > 0) {
      const info: SshPrivateKeyInfo = this.loader.inspectSshPrivateKey(key.privateKey, this.passphrase);
      if (!info.ok) { this.errorText = '密钥密码不正确，无法验证私钥'; return; }
      key.publicKey = info.publicKeyOpenSsh; key.fingerprint = info.fingerprintSha256;
    }
    key.id = SshKey.generateId(); key.label = this.label.trim(); key.comment = this.comment.trim();
    if (!this.kvs.addSshKey(key)) { this.errorText = '密钥保存失败'; return; }
    this.finish(key.id, 'SSH 密钥已保存');
  }

  private generateKey(): void {
    if (this.label.trim().length === 0) { this.errorText = '请输入密钥名称'; return; }
    const kind = this.keyType === SshKeyType.RSA ? 'rsa' : 'ed25519';
    const bits = this.keyType === SshKeyType.RSA ? this.rsaBits : 256;
    const result: GeneratedSshKeyPair = this.loader.generateSshKeyPair(kind, bits, this.comment.trim(), this.passphrase);
    if (!result.ok) { this.errorText = result.error || '密钥生成失败'; return; }
    const key = new SshKey();
    key.id = SshKey.generateId(); key.label = this.label.trim(); key.comment = this.comment.trim();
    key.keyType = this.keyType as SshKeyType; key.privateKey = result.privateKeyPem;
    key.publicKey = result.publicKeyOpenSsh; key.fingerprint = result.fingerprintSha256;
    key.privateKeyEncrypted = this.passphrase.length > 0; key.formatVersion = 1;
    this.generatedKey = key; this.step = 'ssh-generate-preview'; this.errorText = '';
  }

  private saveGeneratedKey(): void {
    if (this.generatedKey === null) { return; }
    const key = SshKey.fromJSON((this.generatedKey as SshKey).toJSON());
    if (!this.kvs.addSshKey(key)) { this.errorText = '密钥保存失败'; return; }
    this.finish(key.id, 'SSH 密钥已生成并保存');
  }

  private parseOtpUri(): void {
    const entry = TotpEngine.parseOtpAuthUri(this.otpUri.trim());
    if (entry === null) { this.errorText = 'otpauth URI 无效，请检查格式'; return; }
    this.issuer = entry.issuer; this.account = entry.account; this.secret = entry.secret;
    this.digits = entry.digits; this.period = entry.period; this.algorithm = entry.algorithm;
    this.step = 'totp-manual'; this.errorText = '';
  }

  private onQrScanned(entry: TotpEntry): void {
    this.issuer = entry.issuer; this.account = entry.account; this.secret = entry.secret;
    this.digits = entry.digits; this.period = entry.period; this.algorithm = entry.algorithm;
    this.step = 'totp-manual'; this.errorText = '';
  }

  private saveTotp(): void {
    const normalized = this.secret.trim().replace(/\s+/g, '').toUpperCase();
    if (this.issuer.trim().length === 0 || normalized.length === 0) { this.errorText = '发行方和 Secret 不能为空'; return; }
    if (!/^[A-Z2-7]+=*$/.test(normalized)) { this.errorText = 'Secret 不是有效的 Base32 字符串'; return; }
    const duplicate = this.kvs.getAllTotpEntries().find((item: TotpEntry): boolean => item.secret === normalized);
    if (duplicate !== undefined) { this.errorText = '该 Secret 已存在，请勿重复添加'; return; }
    const entry = new TotpEntry(); entry.id = TotpEntry.generateId(); entry.issuer = this.issuer.trim();
    entry.account = this.account.trim(); entry.secret = normalized; entry.digits = this.digits;
    entry.period = this.period; entry.algorithm = this.algorithm as TotpAlgorithm;
    if (!this.kvs.addTotpEntry(entry)) { this.errorText = '2FA 保存失败'; return; }
    this.finish(entry.id, '2FA 验证器已保存');
  }

  private async pickTotpFile(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true; this.errorText = '';
    const result: TotpImportResult | null = await this.totpImporter.pickAndParse();
    this.busy = false;
    if (result === null) { return; }
    if (!result.ok) { this.errorText = result.error; return; }
    const existing = this.kvs.getAllTotpEntries();
    const valid: TotpEntry[] = [];
    for (let i = 0; i < result.entries.length; i++) {
      const entry = result.entries[i];
      const duplicate = existing.find((item: TotpEntry): boolean => item.secret === entry.secret) !== undefined ||
        valid.find((item: TotpEntry): boolean => item.secret === entry.secret) !== undefined;
      if (!duplicate) { valid.push(entry); }
    }
    this.importEntries = result.entries; this.selectedImportIds = valid.map((entry: TotpEntry): string => entry.id);
    this.importFileName = result.fileName; this.importFormat = result.format; this.step = 'totp-file-preview';
    if (valid.length === 0) { this.errorText = '文件中的账户均已存在或无效'; }
  }

  private isImportSelected(id: string): boolean { return this.selectedImportIds.includes(id); }
  private isExistingSecret(secret: string): boolean {
    return this.kvs.getAllTotpEntries().find((entry: TotpEntry): boolean => entry.secret === secret) !== undefined;
  }
  private toggleImport(entry: TotpEntry): void {
    if (this.isExistingSecret(entry.secret)) { return; }
    if (this.isImportSelected(entry.id)) {
      this.selectedImportIds = this.selectedImportIds.filter((id: string): boolean => id !== entry.id);
    } else { this.selectedImportIds = this.selectedImportIds.concat([entry.id]); }
  }

  private saveImportedTotp(): void {
    const pending: TotpEntry[] = [];
    for (let i = 0; i < this.importEntries.length; i++) {
      const source = this.importEntries[i];
      if (!this.isImportSelected(source.id) || this.isExistingSecret(source.secret)) { continue; }
      const entry = TotpEntry.fromJSON(source.toJSON()); entry.id = TotpEntry.generateId();
      pending.push(entry);
    }
    if (pending.length === 0) { this.errorText = '没有可保存的账户'; return; }
    const result: TotpBatchAddResult = this.kvs.addTotpEntries(pending);
    if (result.savedIds.length === 0) { this.errorText = '账户导入失败，请稍后重试'; return; }
    const detail = result.failedCount > 0 ? '，' + result.failedCount.toString() + ' 个失败' : '';
    this.finish(result.savedIds[0], '已导入 ' + result.savedIds.length.toString() + ' 个 2FA 账户' + detail);
  }

  private finish(id: string, message: string): void {
    promptAction.showToast({ message, duration: 1600 });
    this.onSaved(id); this.onClose(); this.reset();
  }

  @Builder private header(title: string, subtitle: string) {
    Row() {
      Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(18).fontColor([this.pal().text2]) }
        .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
        .onClick((): void => { this.goBack(); })
      Column() {
        Text(title).fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font())
        Text(subtitle).fontSize(12).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
      Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2]) }
        .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
        .onClick((): void => { this.onClose(); this.reset(); })
    }.width('100%').margin({ bottom: 18 })
  }

  @Builder private field(label: string, placeholder: string, value: string, onChange: (value: string) => void,
    password: boolean = false) {
    Column() {
      Text(label).fontSize(12).fontColor(this.pal().text2).fontFamily(this.font()).margin({ bottom: 5 })
      TextInput({ placeholder, text: value }).height(42).borderRadius(10).backgroundColor(this.pal().surface)
        .fontSize(13).fontColor(this.pal().text).placeholderColor(this.pal().text3).padding({ left: 12, right: 12 })
        .type(password ? InputType.Password : InputType.Normal).onChange(onChange)
    }.width('100%').alignItems(HorizontalAlign.Start).margin({ bottom: 11 })
  }

  @Builder private error() {
    if (this.errorText.length > 0) {
      Text(this.errorText).fontSize(12).fontColor(this.pal().danger).fontFamily(this.font())
        .width('100%').padding(10).borderRadius(9).backgroundColor(this.pal().surface).margin({ bottom: 10 })
    }
  }

  @Builder private sshPaste() {
    this.header('粘贴私钥', '检查私钥后再保存到保险库')
    this.field('密钥名称', '例如：生产服务器', this.label, (value: string): void => { this.label = value; })
    TextArea({ placeholder: '粘贴 OpenSSH、PEM 或 PKCS#8 私钥', text: this.privateKeyText })
      .height(150).borderRadius(10).backgroundColor(this.pal().surface).fontSize(12).fontFamily('monospace')
      .fontColor(this.pal().text).placeholderColor(this.pal().text3).padding(12)
      .onChange((value: string): void => { this.privateKeyText = value; })
      .margin({ bottom: 11 })
    this.error()
    Button('检查私钥').width('100%').height(42).borderRadius(10).backgroundColor(this.accentColor)
      .fontColor(Color.White).onClick((): void => { this.inspectPastedKey(); })
  }

  @Builder private sshPreview() {
    this.header('确认 SSH 密钥', this.importedFileName.length > 0 ? this.importedFileName : '私钥检查通过')
    Column() {
      Text('密钥类型 · ' + SshKey.typeLabel(this.keyType as SshKeyType)).fontSize(13).fontColor(this.pal().text)
      Text(this.importedKey !== null && (this.importedKey as SshKey).privateKeyEncrypted ? '已使用密码加密' : '未使用密钥密码')
        .fontSize(11).fontColor(this.pal().text3).margin({ top: 5 })
      if (this.importedKey !== null && (this.importedKey as SshKey).fingerprint.length > 0) {
        Text((this.importedKey as SshKey).fingerprint).fontSize(10).fontColor(this.pal().text3)
          .fontFamily('monospace').margin({ top: 5 }).maxLines(2)
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(13).borderRadius(12)
      .backgroundColor(this.pal().surface).margin({ bottom: 12 })
    this.field('密钥名称', '例如：生产服务器', this.label, (value: string): void => { this.label = value; })
    this.field('备注（可选）', 'user@example.com', this.comment, (value: string): void => { this.comment = value; })
    if (this.importedKey !== null && (this.importedKey as SshKey).privateKeyEncrypted) {
      this.field('密钥密码（用于验证，可留空）', '不会保存密码', this.passphrase,
        (value: string): void => { this.passphrase = value; }, true)
    }
    this.error()
    Button('导入并保存').width('100%').height(42).borderRadius(10).backgroundColor(this.accentColor)
      .fontColor(Color.White).onClick((): void => { this.saveImportedKey(); })
  }

  @Builder private sshGenerate() {
    this.header('生成新密钥', '推荐使用 ED25519')
    this.field('密钥名称', '例如：我的 ED25519 密钥', this.label, (value: string): void => { this.label = value; })
    Row() {
      Button('ED25519').layoutWeight(1).height(38).borderRadius(9)
        .backgroundColor(this.keyType === SshKeyType.ED25519 ? this.accentColor : this.pal().surface)
        .fontColor(this.keyType === SshKeyType.ED25519 ? Color.White : this.pal().text2)
        .onClick((): void => { this.keyType = SshKeyType.ED25519; })
      Button('RSA').layoutWeight(1).height(38).borderRadius(9).margin({ left: 8 })
        .backgroundColor(this.keyType === SshKeyType.RSA ? this.accentColor : this.pal().surface)
        .fontColor(this.keyType === SshKeyType.RSA ? Color.White : this.pal().text2)
        .onClick((): void => { this.keyType = SshKeyType.RSA; })
    }.width('100%').margin({ bottom: 11 })
    if (this.keyType === SshKeyType.RSA) {
      Row() {
        Button('3072 位').layoutWeight(1).height(36).borderRadius(9)
          .backgroundColor(this.rsaBits === 3072 ? this.accentColor : this.pal().surface)
          .fontColor(this.rsaBits === 3072 ? Color.White : this.pal().text2)
          .onClick((): void => { this.rsaBits = 3072; })
        Button('4096 位').layoutWeight(1).height(36).borderRadius(9).margin({ left: 8 })
          .backgroundColor(this.rsaBits === 4096 ? this.accentColor : this.pal().surface)
          .fontColor(this.rsaBits === 4096 ? Color.White : this.pal().text2)
          .onClick((): void => { this.rsaBits = 4096; })
      }.width('100%').margin({ bottom: 11 })
    }
    this.field('备注（可选）', 'user@example.com', this.comment, (value: string): void => { this.comment = value; })
    this.field('密钥密码（可选）', '用于保护生成的私钥', this.passphrase,
      (value: string): void => { this.passphrase = value; }, true)
    this.error()
    Button('生成密钥').width('100%').height(42).borderRadius(10).backgroundColor(this.accentColor)
      .fontColor(Color.White).onClick((): void => { this.generateKey(); })
  }

  @Builder private sshGeneratePreview() {
    this.header('密钥已生成', '确认指纹后保存')
    if (this.generatedKey !== null) {
      Column() {
        Text((this.generatedKey as SshKey).label).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        Text(SshKey.typeLabel((this.generatedKey as SshKey).keyType)).fontSize(11).fontColor(this.pal().text3).margin({ top: 4 })
        Text((this.generatedKey as SshKey).fingerprint).fontSize(10).fontColor(this.pal().text3)
          .fontFamily('monospace').margin({ top: 8 }).maxLines(3)
      }.width('100%').alignItems(HorizontalAlign.Start).padding(14).borderRadius(12).backgroundColor(this.pal().surface)
    }
    this.error()
    Button('保存到密钥保险库').width('100%').height(42).borderRadius(10).backgroundColor(this.accentColor)
      .fontColor(Color.White).margin({ top: 14 }).onClick((): void => { this.saveGeneratedKey(); })
  }

  @Builder private totpUri() {
    this.header('导入 otpauth 配置', '粘贴一条 otpauth:// URI')
    TextArea({ placeholder: 'otpauth://totp/...', text: this.otpUri }).height(120).borderRadius(10)
      .backgroundColor(this.pal().surface).fontSize(12).fontFamily('monospace').fontColor(this.pal().text)
      .padding(12).onChange((value: string): void => { this.otpUri = value; }).margin({ bottom: 11 })
    this.error()
    Button('解析并继续').width('100%').height(42).borderRadius(10).backgroundColor(this.accentColor)
      .fontColor(Color.White).onClick((): void => { this.parseOtpUri(); })
  }

  @Builder private totpManual() {
    this.header('确认 2FA 账户', '检查账户信息后保存')
    this.field('发行方', '例如：GitHub', this.issuer, (value: string): void => { this.issuer = value; })
    this.field('账户', 'user@example.com', this.account, (value: string): void => { this.account = value; })
    this.field('Secret', 'Base32 字符串', this.secret, (value: string): void => { this.secret = value; }, true)
    Row() {
      Button('6 位').layoutWeight(1).height(36).borderRadius(9)
        .backgroundColor(this.digits === 6 ? this.accentColor : this.pal().surface)
        .fontColor(this.digits === 6 ? Color.White : this.pal().text2).onClick((): void => { this.digits = 6; })
      Button('8 位').layoutWeight(1).height(36).borderRadius(9).margin({ left: 8 })
        .backgroundColor(this.digits === 8 ? this.accentColor : this.pal().surface)
        .fontColor(this.digits === 8 ? Color.White : this.pal().text2).onClick((): void => { this.digits = 8; })
      Button(this.period.toString() + ' 秒').layoutWeight(1).height(36).borderRadius(9).margin({ left: 8 })
        .backgroundColor(this.pal().surface).fontColor(this.pal().text2)
        .onClick((): void => { this.period = this.period === 30 ? 60 : 30; })
    }.width('100%').margin({ bottom: 11 })
    this.error()
    Button('保存 2FA 账户').width('100%').height(42).borderRadius(10).backgroundColor(this.accentColor)
      .fontColor(Color.White).onClick((): void => { this.saveTotp(); })
  }

  @Builder private totpScan() {
    this.header('扫描二维码', '读取后会先进入确认步骤')
    QrCodeScanner({ onScanned: (entry: TotpEntry): void => { this.onQrScanned(entry); } })
    this.error()
  }

  @Builder private totpFilePreview() {
    this.header('选择要导入的账户', this.importFormat + ' · ' + this.importFileName)
    Scroll() {
      Column() {
        ForEach(this.importEntries, (entry: TotpEntry) => {
          Row() {
            SymbolGlyph(this.isImportSelected(entry.id) ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
              .fontSize(20).fontColor([this.isExistingSecret(entry.secret) ? this.pal().text3 : this.accentColor])
            Column() {
              Text(entry.issuer).fontSize(14).fontColor(this.pal().text).maxLines(1)
              Text(this.isExistingSecret(entry.secret) ? '已存在，将跳过' : entry.account)
                .fontSize(11).fontColor(this.pal().text3).margin({ top: 3 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
          }.width('100%').height(58).padding({ left: 12, right: 12 }).borderRadius(11)
            .backgroundColor(this.pal().surface).margin({ bottom: 8 })
            .onClick((): void => { this.toggleImport(entry); })
        }, (entry: TotpEntry): string => entry.id)
      }.width('100%')
    }.constraintSize({ maxHeight: 300 }).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
    this.error()
    Button('导入选中账户（' + this.selectedImportIds.length.toString() + '）').width('100%').height(42)
      .borderRadius(10).backgroundColor(this.accentColor).fontColor(Color.White).margin({ top: 8 })
      .onClick((): void => { this.saveImportedTotp(); })
  }

  build() {
    Column() {
      if (this.step === 'method') {
        ResourceFabPicker({ kind: this.resourceKind, onSelect: (option: string): void => { this.selectMethod(option); },
          onClose: (): void => { this.onClose(); this.reset(); } })
      } else {
        Column() {
          if (this.step === 'ssh-paste') { this.sshPaste() }
          else if (this.step === 'ssh-preview') { this.sshPreview() }
          else if (this.step === 'ssh-generate') { this.sshGenerate() }
          else if (this.step === 'ssh-generate-preview') { this.sshGeneratePreview() }
          else if (this.step === 'totp-uri') { this.totpUri() }
          else if (this.step === 'totp-manual') { this.totpManual() }
          else if (this.step === 'totp-scan') { this.totpScan() }
          else if (this.step === 'totp-file-preview') { this.totpFilePreview() }
        }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 28 })
      }
    }.width('100%').constraintSize({ maxWidth: 760 }).backgroundColor(this.pal().card)
      .borderRadius(this.resourceKind === 'ssh_key' || this.resourceKind === 'totp' ? 0 : 20)
  }
}
