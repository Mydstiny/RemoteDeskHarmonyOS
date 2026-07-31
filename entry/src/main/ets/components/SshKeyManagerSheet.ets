/**
 * SshKeyManagerSheet.ets — SSH 密钥详情/管理 Sheet
 *
 * 替换旧的 keyVaultEditSheet() + sshEditFormSheet().
 * 分区: 摘要 / 基本信息 / 私钥内容 / 公钥 / 私钥保护 / 导出 / 危险区
 * 旧格式 (formatVersion=0) 密钥隐藏公钥/私钥保护/导出区.
 */
import { promptAction, display } from '@kit.ArkUI';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { SshKey, SshKeyType } from '../model/SshKey';
import { Palette, buildDark, buildLight, AppTheme } from '../common/Theme';
import { showLockGate, lockGateErrorMessage } from './LockGate';
import { ExtensionLoader } from '../services/ExtensionLoader';
import { GeneratedSshKeyPair, SshPrivateKeyInfo } from '../types/rdpnapi';

@Component
export struct SshKeyManagerSheet {
  @Prop sshKey: SshKey;
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  onChange?: (updatedKey: SshKey) => void;
  onDelete?: (keyId: string) => void;
  onInstallToHost?: (key: SshKey) => void;
  onManagePassphrase?: (key: SshKey) => void;
  onDismiss?: () => void;

  @State editLabel: string = '';
  @State editComment: string = '';
  @State showFullPublicKey: boolean = false;
  @State saving: boolean = false;
  /** 私钥内容编辑区（默认收起，展开后可编辑 PEM 全文） */
  @State showPrivateKeyEditor: boolean = false;
  @State editPrivateKey: string = '';
  @State editKeyPassphrase: string = '';
  @State editKeyError: string = '';
  @State savingPrivateKey: boolean = false;

  private loader: ExtensionLoader = ExtensionLoader.getInstance();

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private font(): string { return AppTheme.fontFamily; }
  /** Scroll 最大高度：按屏幕可用高度动态计算，保证保存按钮不被 Sheet 底部截断。 */
  private scrollMaxHeight(): number {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      const heightVp: number = d.height / d.densityPixels;
      return Math.max(280, Math.min(560, heightVp - 280));
    } catch (_err) {
      return 560;
    }
  }

  aboutToAppear(): void {
    this.editLabel = this.sshKey.label;
    this.editComment = this.sshKey.comment;
    this.editPrivateKey = this.sshKey.privateKey;
  }

  // ====== 基本信息保存 ======
  private saveBasicInfo(): void {
    if (this.editLabel.trim() === '') {
      promptAction.showToast({ message: '名称不能为空', duration: 1500 });
      return;
    }
    this.saving = true;
    const updated: SshKey = new SshKey();
    // 克隆所有字段
    updated.id = this.sshKey.id;
    updated.label = this.editLabel.trim();
    updated.comment = this.editComment.trim();
    updated.keyType = this.sshKey.keyType;
    updated.privateKey = this.sshKey.privateKey;
    updated.publicKey = this.sshKey.publicKey;
    updated.fingerprint = this.sshKey.fingerprint;
    updated.locked = this.sshKey.locked;
    updated.lockType = this.sshKey.lockType;
    updated.createdAt = this.sshKey.createdAt;
    updated.syncVersion = this.sshKey.syncVersion;
    updated.userId = this.sshKey.userId;
    updated.formatVersion = this.sshKey.formatVersion;
    updated.privateKeyEncrypted = this.sshKey.privateKeyEncrypted;
    if (this.onChange) { this.onChange(updated); }
    promptAction.showToast({ message: '已保存', duration: 1500 });
    this.saving = false;
  }

  // ====== 私钥内容保存 ======
  private savePrivateKey(): void {
    if (this.savingPrivateKey) { return; }
    const pem: string = this.editPrivateKey.trim();
    if (pem === '') {
      this.editKeyError = '私钥内容不能为空';
      return;
    }
    if (!SshKey.looksLikeOpenSshPrivateKey(pem)) {
      this.editKeyError = '不是有效的 OpenSSH 私钥格式（缺少 BEGIN/END PRIVATE KEY 标记）';
      return;
    }
    const info: SshPrivateKeyInfo = this.loader.inspectSshPrivateKey(pem, this.editKeyPassphrase);
    if (!info.ok) {
      if (info.encrypted && this.editKeyPassphrase === '') {
        this.editKeyError = '私钥已加密，请输入当前私钥密码后保存';
        return;
      }
      this.editKeyError = '私钥校验失败: ' + (info.error || '无法解析该私钥');
      return;
    }
    this.savingPrivateKey = true;
    const updated: SshKey = new SshKey();
    updated.id = this.sshKey.id;
    updated.label = this.sshKey.label;
    updated.comment = this.sshKey.comment;
    updated.keyType = this.mapKeyType(info.keyType);
    updated.privateKey = pem;
    updated.publicKey = info.publicKeyOpenSsh;
    updated.fingerprint = info.fingerprintSha256;
    updated.locked = this.sshKey.locked;
    updated.lockType = this.sshKey.lockType;
    updated.createdAt = this.sshKey.createdAt;
    updated.syncVersion = this.sshKey.syncVersion;
    updated.userId = this.sshKey.userId;
    updated.formatVersion = 1;
    updated.privateKeyEncrypted = info.encrypted;
    if (this.onChange) { this.onChange(updated); }
    promptAction.showToast({ message: '私钥已保存', duration: 1500 });
    this.savingPrivateKey = false;
    this.showPrivateKeyEditor = false;
    this.editKeyPassphrase = '';
    this.editKeyError = '';
  }

  /** inspectSshPrivateKey 的 keyType 字符串 → SshKeyType 枚举 */
  private mapKeyType(type: string): SshKeyType {
    if (type === 'ssh-ed25519') { return SshKeyType.ED25519; }
    if (type === 'ssh-rsa') { return SshKeyType.RSA; }
    if (type.startsWith('ecdsa-sha2-')) { return SshKeyType.ECDSA; }
    return this.sshKey.keyType;
  }

  // ====== 复制公钥 ======
  private async copyPublicKey(): Promise<void> {
    if (this.sshKey.locked) {
      const r = await showLockGate(this.sshKey.label, 'biometric');
      if (!r.ok) { const m = lockGateErrorMessage(r); if (m !== '') { promptAction.showToast({ message: m, duration: 2000 }); } return; }
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.sshKey.publicKey);
      pasteboard.getSystemPasteboard().setDataSync(data);
      promptAction.showToast({ message: '公钥已复制', duration: 1500 });
    } catch (err) {
      promptAction.showToast({ message: '复制失败', duration: 1500 });
    }
  }

  // ====== 导出公钥文件 ======
  private async exportPublicKey(): Promise<void> {
    try {
      const pickerInstance = new picker.DocumentViewPicker();
      const safeName: string = this.sshKey.label.replace(/[^a-zA-Z0-9_-]/g, '_');
      const saveOptions: picker.DocumentSaveOptions = { newFileNames: [safeName + '.pub'] };
      const uris: string[] = await pickerInstance.save(saveOptions);
      if (uris.length === 0) { return; }
      const file = fileIo.openSync(uris[0], fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      const content: string = this.sshKey.publicKey + '\n';
      const encoder = new util.TextEncoder();
      const buf = encoder.encodeInto(content);
      fileIo.writeSync(file.fd, buf.buffer as ArrayBuffer);
      fileIo.closeSync(file);
      promptAction.showToast({ message: '公钥已导出', duration: 1500 });
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      if (be.code !== 0) {
        promptAction.showToast({ message: '[CC-SSHKEY-05] 导出失败: ' + be.message, duration: 2000 });
      }
    }
  }

  // ====== 导出私钥文件 ======
  private async exportPrivateKey(): Promise<void> {
    // 鉴权
    if (this.sshKey.locked) {
      const r = await showLockGate(this.sshKey.label, 'biometric');
      if (!r.ok) { const m = lockGateErrorMessage(r); if (m !== '') { promptAction.showToast({ message: m, duration: 2000 }); } return; }
    }
    // 未加密私钥二次确认
    if (!this.sshKey.privateKeyEncrypted) {
      const confirmed: boolean = await new Promise<boolean>((resolve: (v: boolean) => void) => {
        promptAction.showDialog({
          title: '安全提示',
          message: '此私钥未设置密码。导出的文件可直接用于登录服务器。\n\n建议先设置密码再导出。\n\n确定导出未加密私钥？',
          buttons: [
            { text: '取消', color: this.pal().text2 },
            { text: '添加密码', color: this.accentColor },
            { text: '仍然导出', color: this.pal().danger }
          ]
        }).then((r: Object) => {
          const result: Record<string, number> = r as Record<string, number>;
          if (result['index'] === 2) { resolve(true); }
          else if (result['index'] === 1) {
            if (this.onManagePassphrase) { this.onManagePassphrase(this.sshKey); }
            resolve(false);
          } else { resolve(false); }
        });
      });
      if (!confirmed) { return; }
    }

    try {
      const pickerInstance = new picker.DocumentViewPicker();
      const safeName: string = this.sshKey.label.replace(/[^a-zA-Z0-9_-]/g, '_');
      const saveOptions: picker.DocumentSaveOptions = { newFileNames: [safeName + '.pem'] };
      const uris: string[] = await pickerInstance.save(saveOptions);
      if (uris.length === 0) { return; }
      const file = fileIo.openSync(uris[0], fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      const encoder = new util.TextEncoder();
      const buf = encoder.encodeInto(this.sshKey.privateKey);
      fileIo.writeSync(file.fd, buf.buffer as ArrayBuffer);
      fileIo.closeSync(file);
      promptAction.showToast({ message: '私钥已导出', duration: 1500 });
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      if (be.code !== 0) {
        promptAction.showToast({ message: '[CC-SSHKEY-06] 导出失败: ' + be.message, duration: 2000 });
      }
    }
  }

  // ====== 删除密钥 ======
  private async deleteKey(): Promise<void> {
    if (this.sshKey.locked) {
      const r = await showLockGate(this.sshKey.label, 'biometric');
      if (!r.ok) { const m = lockGateErrorMessage(r); if (m !== '') { promptAction.showToast({ message: m, duration: 2000 }); } return; }
    }
    promptAction.showDialog({
      title: '确认删除',
      message: '确定要删除密钥 "' + this.sshKey.label + '" 吗？此操作不可恢复。',
      buttons: [
        { text: '取消', color: this.pal().text2 },
        { text: '删除', color: this.pal().danger }
      ]
    }).then((result: Object): void => {
      const r: Record<string, number> = result as Record<string, number>;
      if (r['index'] === 1 && this.onDelete) { this.onDelete(this.sshKey.id); }
    });
  }

  build() {
    Scroll() {
      Column() {
        // ========== 摘要区 ==========
        this.sectionHeader('密钥信息')
        Column() {
          // Legacy warning
          if (this.sshKey.isLegacyFormat()) {
            Row() {
              Text('此密钥为旧格式 (cryptoFramework 生成), 不支持安装到主机和导出。请重新生成标准 OpenSSH 密钥或导入 OpenSSH 格式私钥。')
                .fontSize(13).fontColor('#FF9500').fontFamily(this.font())
            }
            .width('100%').padding(10).borderRadius(8)
            .backgroundColor('#FF950015')
            .margin({ bottom: 10 })
          }

          // 类型 + 指纹
          Row() {
            Text(this.sshKey.isLegacyFormat() ? '类型' : this.sshKey.keyType === 1 ? 'ED25519' : 'RSA')
              .fontSize(12).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .borderRadius(6)
              .backgroundColor(this.sshKey.isLegacyFormat() ? '#FF9500' : this.accentColor)
            Blank()
            if (this.sshKey.locked) {
              SymbolGlyph($r('sys.symbol.ohos_lock')).fontSize(14).fontColor([this.accentColor]).margin({ right: 8 })
            }
            if (this.sshKey.privateKeyEncrypted) {
              SymbolGlyph($r('sys.symbol.key_fill')).fontSize(14).fontColor([this.pal().text2]).margin({ right: 4 })
              Text('有密码').fontSize(13).fontColor(this.pal().text2).fontFamily(this.font())
            } else {
              Text('无密码').fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
            }
          }.width('100%').margin({ bottom: 8 })

          // 指纹
          if (this.sshKey.fingerprint !== '') {
            Text(this.sshKey.fingerprint)
              .fontSize(12).fontColor(this.pal().text2)
              .fontFamily('monospace').maxLines(2)
              .width('100%')
          }

          if (this.sshKey.comment !== '') {
            Text(this.sshKey.comment).fontSize(12).fontColor(this.pal().text3)
              .fontFamily(this.font()).margin({ top: 4 })
          }
        }
        .width('100%').padding(14).borderRadius(12)
        .backgroundColor(this.pal().card)
        .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
        .margin({ bottom: 16 })

        // ========== 基本信息区 ==========
        this.sectionHeader('基本信息')
        Column() {
          this._input('名称', '如 myserver-key', this.editLabel, (v: string) => { this.editLabel = v; })
          this._input('备注', '如 user@host.com', this.editComment, (v: string) => { this.editComment = v; })

          Button('保存修改')
            .width('100%').height(44).fontSize(14).fontWeight(FontWeight.Medium)
            .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10)
            .enabled(!this.saving)
            .onClick(() => { this.saveBasicInfo(); })
        }
        .width('100%').padding(14).borderRadius(12)
        .backgroundColor(this.pal().card)
        .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
        .margin({ bottom: 16 })

        // ========== 私钥内容区 (仅标准格式) ==========
        if (!this.sshKey.isLegacyFormat()) {
          this.sectionHeader('私钥内容')
          Column() {
            Row() {
              Text(this.sshKey.privateKeyEncrypted ? '已有密码保护，编辑后需密码验证' : '未加密私钥，可安全编辑')
                .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
                .layoutWeight(1).margin({ right: 8 })
              this._actionBtn(this.showPrivateKeyEditor ? '收起' : '编辑私钥', () => {
                this.showPrivateKeyEditor = !this.showPrivateKeyEditor;
                if (this.showPrivateKeyEditor && this.editPrivateKey === '') {
                  this.editPrivateKey = this.sshKey.privateKey;
                }
              })
            }.width('100%').margin({ bottom: 8 })

            if (this.showPrivateKeyEditor) {
              TextArea({ placeholder: '粘贴 OpenSSH 格式私钥...', text: this.editPrivateKey })
                .height(160)
                .backgroundColor(this.pal().surface).borderRadius(10)
                .fontColor(this.pal().text).placeholderColor(this.pal().text3)
                .fontFamily('monospace').fontSize(12)
                .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                .width('100%')
                .onChange((v: string) => { this.editPrivateKey = v; this.editKeyError = ''; })

              if (this.sshKey.privateKeyEncrypted) {
                TextInput({ placeholder: '当前私钥密码 (验证用)', text: this.editKeyPassphrase })
                  .type(InputType.Password).height(38)
                  .backgroundColor(this.pal().surface).borderRadius(8)
                  .fontColor(this.pal().text).placeholderColor(this.pal().text3)
                  .fontFamily(this.font()).fontSize(13)
                  .padding({ left: 10, right: 10 }).margin({ top: 8 })
                  .width('100%')
                  .onChange((v: string) => { this.editKeyPassphrase = v; this.editKeyError = ''; })
              }

              if (this.editKeyError !== '') {
                Text(this.editKeyError).fontSize(11).fontColor(this.pal().danger)
                  .fontFamily(this.font()).width('100%').margin({ top: 6 })
              }

              Button('保存私钥')
                .width('100%').height(40).fontSize(13).fontWeight(FontWeight.Medium)
                .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(8)
                .margin({ top: 10 }).enabled(!this.savingPrivateKey)
                .onClick(() => { this.savePrivateKey(); })
            }
          }
          .width('100%').padding(14).borderRadius(12)
          .backgroundColor(this.pal().card)
          .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
          .margin({ bottom: 16 })
        }

        // ========== 公钥区 (仅标准格式) ==========
        if (!this.sshKey.isLegacyFormat()) {
          this.sectionHeader('公钥')
          Column() {
            if (this.showFullPublicKey && this.sshKey.publicKey !== '') {
              Text(this.sshKey.publicKey)
                .fontSize(11).fontColor(this.pal().text2)
                .fontFamily('monospace').maxLines(6)
                .padding(8).borderRadius(6)
                .backgroundColor(this.pal().surface)
                .width('100%').margin({ bottom: 8 })
            }

            Row() {
              this._actionBtn('复制', () => { this.copyPublicKey(); })
              this._actionBtn('安装到主机', () => {
                if (this.onInstallToHost) { this.onInstallToHost(this.sshKey); }
              })
              this._actionBtn('导出.pub', () => { this.exportPublicKey(); })
              this._actionBtn(this.showFullPublicKey ? '收起' : '展开', () => {
                this.showFullPublicKey = !this.showFullPublicKey;
              })
            }.width('100%')
          }
          .width('100%').padding(14).borderRadius(12)
          .backgroundColor(this.pal().card)
          .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
          .margin({ bottom: 16 })
        }

        // ========== 私钥保护区 (仅标准格式) ==========
        if (!this.sshKey.isLegacyFormat()) {
          this.sectionHeader('私钥保护')
          Column() {
            Row() {
              SymbolGlyph($r('sys.symbol.lock_fill'))
                .fontSize(16).fontColor([this.sshKey.privateKeyEncrypted ? this.pal().success : this.pal().text3])
              Text(this.sshKey.privateKeyEncrypted ? '已有密码保护' : '未设置密码')
                .fontSize(13).fontColor(this.pal().text).fontFamily(this.font())
                .margin({ left: 6 })
              Blank()
            }.width('100%').margin({ bottom: 10 })

            Row() {
              if (this.sshKey.privateKeyEncrypted) {
                this._actionBtn('修改密码', () => {
                  if (this.onManagePassphrase) { this.onManagePassphrase(this.sshKey); }
                })
                this._actionBtn('移除密码', () => {
                  if (this.onManagePassphrase) { this.onManagePassphrase(this.sshKey); }
                })
              } else {
                this._actionBtn('设置密码', () => {
                  if (this.onManagePassphrase) { this.onManagePassphrase(this.sshKey); }
                })
              }
            }.width('100%')
          }
          .width('100%').padding(14).borderRadius(12)
          .backgroundColor(this.pal().card)
          .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
          .margin({ bottom: 16 })
        }

        // ========== 导出区 (仅标准格式) ==========
        if (!this.sshKey.isLegacyFormat()) {
          this.sectionHeader('导出')
          Column() {
            this._exportRow('导出公钥文件', '<name>.pub', () => { this.exportPublicKey(); })
            Divider().strokeWidth(0.5).color(this.pal().cardBorder).margin({ top: 8, bottom: 8 })
            this._exportRow('导出私钥文件', '<name>.pem', async () => { await this.exportPrivateKey(); })
          }
          .width('100%').padding(14).borderRadius(12)
          .backgroundColor(this.pal().card)
          .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
          .margin({ bottom: 16 })
        }

        // ========== 危险区 ==========
        this.sectionHeader('')
        Button() {
          Row() {
            SymbolGlyph($r('sys.symbol.ohos_trash')).fontSize(16).fontColor([this.pal().danger])
            Text('删除此密钥').fontSize(14).fontColor(this.pal().danger)
              .fontWeight(FontWeight.Medium).fontFamily(this.font()).margin({ left: 6 })
          }
        }
        .width('100%').height(44)
        .backgroundColor(this.pal().card).borderRadius(10)
        .border({ width: 1, color: this.pal().danger + '44', style: BorderStyle.Solid })
        .onClick(() => { this.deleteKey(); })

        // Passphrase sub-sheet
        Blank().height(4)
      }
      .width('100%')
    }
    .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
    .constraintSize({ maxHeight: this.scrollMaxHeight() })
    .width('100%')
  }

  // ====== Builders ======
  @Builder sectionHeader(title: string) {
    if (title !== '') {
      Text(title).fontSize(13).fontWeight(FontWeight.Medium)
        .fontColor(this.pal().text3).fontFamily(this.font())
        .margin({ bottom: 10 })
    }
  }

  @Builder _input(l: string, h: string, v: string, cb: (v: string) => void) {
    Column() {
      Text(l).fontSize(13).fontColor(this.pal().text2).margin({ bottom: 4 }).fontFamily(this.font())
      TextInput({ placeholder: h, text: v }).height(42).backgroundColor(this.pal().surface).borderRadius(10)
        .fontColor(this.pal().text).placeholderColor(this.pal().text3).fontFamily(this.font())
        .fontSize(14).padding({ left: 12, right: 12 }).onChange(cb)
    }.width('100%').margin({ bottom: 10 })
  }

  @Builder _actionBtn(label: string, onClick: () => void) {
    Button(label).fontSize(13)
      .height(36).padding({ left: 12, right: 12 })
      .backgroundColor(this.pal().surface).fontColor(this.accentColor)
      .borderRadius(8).margin({ right: 6 })
      .onClick(onClick)
  }

  @Builder _exportRow(label: string, hint: string, onClick: () => void) {
    Row() {
      Column() {
        Text(label).fontSize(14).fontColor(this.pal().text).fontFamily(this.font())
        Text(hint).fontSize(11).fontColor(this.pal().text3)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)

      Button('导出').fontSize(13).height(34).padding({ left: 14, right: 14 })
        .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(8)
        .onClick(onClick)
    }.width('100%').padding({ top: 4, bottom: 4 })
  }
}

/**
 * Passphrase 子组件 (在管理 Sheet 内部使用)
 */
@Component
export struct SshKeyPassphraseSubSheet {
  @Prop sshKey: SshKey;
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  onComplete?: (newPrivateKey: string, newEncrypted: boolean) => void;

  @State oldPass: string = '';
  @State newPass: string = '';
  @State confirmPass: string = '';
  @State showOldPass: boolean = false;
  @State showNewPass: boolean = false;
  @State error: string = '';
  private loader: ExtensionLoader = ExtensionLoader.getInstance();

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private font(): string { return AppTheme.fontFamily; }

  private submit(): void {
    this.error = '';

    // 验证
    if (this.newPass !== this.confirmPass) {
      this.error = '两次输入的新密码不一致';
      return;
    }

    const oldPass: string = this.sshKey.privateKeyEncrypted ? this.oldPass : '';
    const newPass: string = this.newPass; // "" means remove

    const result: string = this.loader.changeSshPrivateKeyPassphrase(
      this.sshKey.privateKey, oldPass, newPass);

    if (result === '' || result.length < 20) {
      this.error = '密码修改失败。' +
        (this.sshKey.privateKeyEncrypted ? '请确认旧密码是否正确。' : '请重试。');
      return;
    }

    if (this.onComplete) {
      this.onComplete(result, newPass !== '');
    }
  }

  build() {
    Column() {
      if (this.sshKey.privateKeyEncrypted) {
        this._pwField('当前密码', '输入现有密码', this.oldPass,
          this.showOldPass, (v: string) => { this.oldPass = v; },
          () => { this.showOldPass = !this.showOldPass; })
      }

      this._pwField(
        this.sshKey.privateKeyEncrypted ? '新密码 (留空=移除密码)' : '新密码 (留空=不设密码)',
        '输入新密码', this.newPass,
        this.showNewPass, (v: string) => { this.newPass = v; },
        () => { this.showNewPass = !this.showNewPass; })

      if (this.newPass !== '') {
        this._pwField('确认新密码', '再次输入新密码', this.confirmPass,
          false, (v: string) => { this.confirmPass = v; }, undefined)
      }

      if (this.error !== '') {
        Text(this.error).fontSize(12).fontColor(this.pal().danger)
          .fontFamily(this.font()).width('100%').margin({ top: 8, bottom: 8 })
      }

      Button(this.newPass === '' && this.sshKey.privateKeyEncrypted ? '移除密码'
        : this.sshKey.privateKeyEncrypted ? '修改密码' : '设置密码')
        .width('100%').height(40).fontSize(14).fontWeight(FontWeight.Medium)
        .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10)
        .margin({ top: 12 })
        .onClick(() => { this.submit(); })

      if (this.newPass === '' && this.sshKey.privateKeyEncrypted) {
        Text('移除密码后, 私钥将以明文存储')
          .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
          .margin({ top: 8 }).width('100%').textAlign(TextAlign.Center)
      }
    }
  }

  @Builder _pwField(l: string, h: string, v: string, show: boolean,
                     onChange: (v: string) => void, onEye?: (() => void) | undefined) {
    Column() {
      Text(l).fontSize(11).fontColor(this.pal().text2).margin({ bottom: 4 }).fontFamily(this.font())
      Row() {
        TextInput({ placeholder: h, text: v })
          .type(show ? InputType.Normal : InputType.Password)
          .height(38).backgroundColor(this.pal().surface).borderRadius(8)
          .fontColor(this.pal().text).placeholderColor(this.pal().text3)
          .fontFamily(this.font()).fontSize(13).layoutWeight(1)
          .padding({ left: 10, right: 10 })
          .onChange(onChange)
        if (onEye) {
          SymbolGlyph(show ? $r('sys.symbol.eye_slash') : $r('sys.symbol.eye'))
            .fontSize(16).fontColor([this.pal().text3])
            .margin({ left: 8 })
            .onClick(onEye)
        }
      }.width('100%')
    }.width('100%').margin({ bottom: 10 })
  }
}
