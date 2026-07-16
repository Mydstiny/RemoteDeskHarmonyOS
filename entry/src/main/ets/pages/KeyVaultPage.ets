/**
 * KeyVaultPage.ets — 密钥保险库页面 v3 (官方图标按钮 + 滑动删除动画)
 *
 * 内嵌 HdsTabs: SSH 密钥 / 2FA 验证器
 * 非 @Entry, 作为 HostListPage 的第三个 Tab 内容。
 */
import { promptAction, curves } from '@kit.ArkUI';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { SshKey, SshKeyType } from '../model/SshKey';
import { ExtensionLoader } from '../services/ExtensionLoader';
import { GeneratedSshKeyPair, SshPrivateKeyInfo } from '../types/rdpnapi';
import { TotpEntry, TotpEntryJSON } from '../model/TotpEntry';
import { KeyVaultService } from '../services/KeyVaultService';
import { SshKeyImportService, SshKeyImportResult } from '../services/SshKeyImportService';
import { TotpEngine } from '../services/TotpEngine';
import { SshKeyCard } from '../components/SshKeyCard';
import { SshKeyManagerSheet, SshKeyPassphraseSubSheet } from '../components/SshKeyManagerSheet';
import { SshKeyInstallSheet } from '../components/SshKeyInstallSheet';
import { HostSyncService } from '../services/HostSyncService';
import { RemoteHost } from '../model/RemoteHost';
import { TotpCodeCard } from '../components/TotpCodeCard';
import { TotpProgressBar } from '../components/TotpProgressBar';
import { QrCodeScanner } from '../components/QrCodeScanner';
import { showLockGate, lockGateErrorMessage } from '../components/LockGate';
import { Palette, buildDark, buildLight, AppTheme } from '../common/Theme';
import { SshKeyDataSource, TotpEntryDataSource } from '../datasources/DataSources';

@Component
export struct KeyVaultPage {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @Link keyVaultInnerTab: number;
  @Prop @Watch('onAddTrigger') addTrigger: number = 0;
  @Prop hideTabBar: boolean = false;
  @StorageProp('totpLocked') totpPageLocked: boolean = false;
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @StorageProp('topRectHeight') topRectHeight: number = 0;
  @State showAddTab: number = 0;
  @State totpUnlocked: boolean = false;
  @State selectionMode: boolean = false;
  // 统一 Sheet: 单 bindSheet + mode 切换内容 (KeyVaultPage 非 @Entry, 限 1 个 bindSheet)
  @State showSheet: boolean = false;
  @State sheetMode: number = 0; // 0=addForm, 1=addChoice, 2=manage, 3=install, 4=passphrase
  @State sheetKey: SshKey = new SshKey();
  @State selectedIds: Set<string> = new Set();
  @State editingSshKey: SshKey = new SshKey();
  @State editingTotpEntry: TotpEntry = new TotpEntry();
  @State sshKeys: SshKey[] = [];
  @State totpEntries: TotpEntry[] = [];
  private sshKeyDataSource: SshKeyDataSource = new SshKeyDataSource();
  private totpEntryDataSource: TotpEntryDataSource = new TotpEntryDataSource();
  @State showQrScan: boolean = false;
  // SSH 表单
  @State formLabel: string = '';
  @State formKeyType: number = SshKeyType.ED25519;
  @State formComment: string = '';
  @State formPasteKey: string = '';
  @State formFileName: string = '';
  @State formMode: number = 0; // 0=paste, 1=generate
  // TOTP 表单
  @State formIssuer: string = '';
  @State formAccount: string = '';
  @State formSecret: string = '';
  @State formDigits: number = 6;
  @State formPeriod: number = 30;
  private kvs: KeyVaultService = KeyVaultService.getInstance();
  private loader: ExtensionLoader = ExtensionLoader.getInstance();
  private sshKeyImporter: SshKeyImportService = new SshKeyImportService();
  private dataUnsubscribe: (() => void) | null = null;
  private pageActive: boolean = false;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private font(): string { return AppTheme.fontFamily; }

  private topSafeHeightVp(): number {
    return this.topRectHeight > 0 ? px2vp(this.topRectHeight) : AppTheme.layout.statusBarH;
  }

  private titleBarHeight(): number {
    return this.topSafeHeightVp() + (this.hideTabBar ? 64 : 96);
  }

  private titleOffsetY(): number {
    return 8;
  }

  aboutToAppear(): void {
    this.pageActive = true;
    this.registerDataRefreshListener();
    this.load();
    this.kvs.whenReady().then((): void => {
      if (this.pageActive) { this.load(); }
    });
  }

  onPageShow(): void { this.load(); }

  aboutToDisappear(): void {
    this.pageActive = false;
    if (this.dataUnsubscribe) {
      this.dataUnsubscribe();
      this.dataUnsubscribe = null;
    }
  }

  private registerDataRefreshListener(): void {
    if (!this.dataUnsubscribe) {
      this.dataUnsubscribe = this.kvs.onDataChange((): void => {
        this.load();
      });
    }
  }

  onAddTrigger(): void {
    if (this.addTrigger > 0) {
      if (this.keyVaultInnerTab === 1) {
        // TOTP: 直接打开添加表单
        this.resetTotpForm();
        this.showAddTab = 1;
        this.sheetMode = 0;
        this.showSheet = true;
      } else {
        // SSH: 三选一
        this.sheetMode = 1;
        this.showSheet = true;
      }
    }
  }

  // ==================== SSH 锁操作 (单对象绑定) ====================
  private async toggleSshLock(key: SshKey): Promise<void> {
    const r = await showLockGate(key.label, 'biometric');
    if (r.ok) {
      key.locked = !key.locked;
      key.lockType = key.locked ? 2 : 0;
      this.kvs.updateSshKey(key);
      this.load();
      promptAction.showToast({ message: key.locked ? '已锁定' : '已解锁', duration: 1500 });
    } else {
      const msg: string = lockGateErrorMessage(r);
      if (msg !== '') { promptAction.showToast({ message: msg, duration: 2000 }); }
    }
  }

  private async handleSshEdit(key: SshKey): Promise<void> {
    if (key.locked) {
      const r = await showLockGate(key.label, 'biometric');
      if (!r.ok) {
        const msg: string = lockGateErrorMessage(r);
        if (msg !== '') { promptAction.showToast({ message: msg, duration: 2000 }); }
        return;
      }
    }
    // 打开管理 Sheet (统一Sheet模式)
    this.sheetKey = key;
    this.sheetMode = 2;
    this.showSheet = true;
  }

  // SshKeyManagerSheet 回调: 保存更新
  private onKeyManagerChange(updated: SshKey): void {
    this.kvs.updateSshKey(updated);
    this.load();
  }

  // SshKeyManagerSheet 回调: 删除
  private onKeyManagerDelete(keyId: string): void {
    this.showSheet = false;
    if (this.kvs.removeSshKey(keyId)) { this.load(); }
  }

  // SshKeyManagerSheet 回调: 安装到主机
  private onKeyManagerInstall(key: SshKey): void {
    this.sheetKey = key;
    this.sheetMode = 3;
    this.showSheet = true;
  }

  private onKeyManagerPassphrase(key: SshKey): void {
    this.sheetKey = key;
    this.sheetMode = 4;
    this.showSheet = true;
  }

  private async deleteSshKeyItem(key: SshKey): Promise<void> {
    if (key.locked) {
      const r = await showLockGate(key.label, 'biometric');
      if (!r.ok) { const msg = lockGateErrorMessage(r); if (msg !== '') { promptAction.showToast({ message: msg, duration: 2000 }); } return; }
    }
    promptAction.showDialog({
      title: '确认删除', message: '确定要删除密钥 "' + key.label + '" 吗？此操作不可恢复。',
      buttons: [{ text: '取消', color: this.pal().text2 }, { text: '删除', color: this.pal().danger }]
    }).then((result: Object): void => {
      const r: Record<string, number> = result as Record<string, number>;
      if (r['index'] === 1) {
        if (this.kvs.removeSshKey(key.id)) { this.load(); }
      }
    });
  }

  // ==================== 滑动操作 Builder ====================

  // SSH 右滑: 编辑(黄) + 上锁(蓝/绿) 方形按钮
  @Builder editLockRow(key: SshKey) {
    Row() {
      Button() {
        SymbolGlyph($r('sys.symbol.square_and_pencil'))
          .fontSize(17)
          .fontColor([Color.White])
      }
      .width(48).height(48).borderRadius(12)
      .backgroundColor(this.pal().editColor)
      .onClick(() => { this.handleSshEdit(key); })

      Button() {
        SymbolGlyph($r('sys.symbol.ohos_lock'))
          .fontSize(17)
          .fontColor([Color.White])
      }
      .width(48).height(48).borderRadius(12)
      .backgroundColor(key.locked ? this.pal().success : this.accentColor)
      .margin({ left: 4 })
      .onClick(() => { this.toggleSshLock(key); })
    }
    .height('100%').alignItems(VerticalAlign.Center)
    .borderRadius(14)
  }

  // TOTP 右滑: 仅编辑(黄) — 页面级锁, 无单对象锁
  @Builder totpEditLockRow(entry: TotpEntry) {
    Row() {
      Button() {
        SymbolGlyph($r('sys.symbol.square_and_pencil'))
          .fontSize(17)
          .fontColor([Color.White])
      }
      .width(48).height(48).borderRadius(12)
      .backgroundColor(this.pal().editColor)
      .onClick(() => {
        if (this.totpPageLocked && !this.totpUnlocked) {
          promptAction.showToast({ message: '请先验证身份', duration: 1500 });
        } else {
          // 编辑 TOTP 名称
          promptAction.showDialog({
            title: '编辑 2FA',
            message: '发行方: ' + entry.issuer + '\n账户: ' + entry.account,
            buttons: [{ text: '关闭', color: this.accentColor }]
          });
        }
      })
    }
    .height('100%').alignItems(VerticalAlign.Center)
    .borderRadius(14)
  }

  // 左滑: 删除按钮 (红色垃圾桶 + Pulse 脉冲 + Bounce 弹跳)
  @Builder deleteBtnSsh(key: SshKey) {
    Column() {
      SymbolGlyph($r('sys.symbol.ohos_trash'))
        .fontSize(24)
        .fontColor([Color.White])
        .symbolEffect(new PulseSymbolEffect(), true)
        .symbolEffect(new BounceSymbolEffect(EffectScope.WHOLE, EffectDirection.UP), true)
      Text('删除')
        .fontSize(9)
        .fontColor(Color.White)
        .margin({ top: 2 })
    }
    .width(60).height(60)
    .justifyContent(FlexAlign.Center)
    .borderRadius(14)
    .backgroundColor(this.pal().danger)
    .onClick(async () => {
      if (key.locked) {
        const r = await showLockGate(key.label, 'biometric');
        if (!r.ok) {
          const msg: string = lockGateErrorMessage(r);
          if (msg !== '') { promptAction.showToast({ message: msg, duration: 2000 }); }
          return;
        }
      }
      promptAction.showDialog({
        title: '确认删除',
        message: '确定要删除密钥 "' + key.label + '" 吗？此操作不可恢复。',
        buttons: [
          { text: '取消', color: this.pal().text2 },
          { text: '删除', color: this.pal().danger }
        ]
      }).then((result: Object): void => {
        const r: Record<string, number> = result as Record<string, number>;
        if (r['index'] === 1) {
          if (this.kvs.removeSshKey(key.id)) { this.load(); }
        }
      });
    })
  }

  @Builder deleteBtnTotp(entry: TotpEntry) {
    Column() {
      SymbolGlyph($r('sys.symbol.ohos_trash'))
        .fontSize(24)
        .fontColor([Color.White])
        .symbolEffect(new PulseSymbolEffect(), true)
        .symbolEffect(new BounceSymbolEffect(EffectScope.WHOLE, EffectDirection.UP), true)
      Text('删除')
        .fontSize(9)
        .fontColor(Color.White)
        .margin({ top: 2 })
    }
    .width(60).height(60)
    .justifyContent(FlexAlign.Center)
    .borderRadius(14)
    .backgroundColor(this.pal().danger)
    .onClick(() => {
      if (this.totpPageLocked && !this.totpUnlocked) {
        promptAction.showToast({ message: '请先验证身份', duration: 1500 });
        return;
      }
      const label: string = entry.issuer || entry.account || '2FA';
      promptAction.showDialog({
        title: '确认删除',
        message: '确定要删除 "' + label + '" 吗？此操作不可恢复。',
        buttons: [
          { text: '取消', color: this.pal().text2 },
          { text: '删除', color: this.pal().danger }
        ]
      }).then((result: Object): void => {
        const r: Record<string, number> = result as Record<string, number>;
        if (r['index'] === 1) {
          if (this.kvs.removeTotpEntry(entry.id)) { this.load(); }
        }
      });
    })
  }

  private load(): void {
    this.sshKeys = this.kvs.getAllSshKeys();
    this.totpEntries = this.kvs.getAllTotpEntries();
    this.sshKeyDataSource.replaceAll(this.sshKeys);
    this.totpEntryDataSource.replaceAll(this.totpEntries);
  }

  // ==================== 批量选择 ====================
  private toggleSelect(id: string, checked: boolean): void {
    const next: Set<string> = new Set(this.selectedIds);
    if (checked) { next.add(id); } else { next.delete(id); }
    this.selectedIds = next;
  }

  @Builder selectionToolbar(allIds: string[]) {
    Row() {
      Button(this.selectedIds.size === allIds.length ? '取消全选' : '全选').fontSize(12)
        .height(32).borderRadius(8)
        .backgroundColor(this.pal().surface).fontColor(this.accentColor)
        .onClick(() => {
          if (this.selectedIds.size === allIds.length) { this.selectedIds = new Set(); }
          else { this.selectedIds = new Set(allIds); }
        })
      Blank()
      Text('已选 ' + this.selectedIds.size).fontSize(13).fontColor(this.pal().text2)
      Blank()
      if (this.selectedIds.size > 0) {
        Button('删除(' + this.selectedIds.size + ')').fontSize(12)
          .height(32).borderRadius(8)
          .backgroundColor(this.pal().danger).fontColor('#FFFFFF')
          .margin({ right: 6 })
          .onClick(() => { this.doBatchDelete(); })
      }
      Button('取消').fontSize(12)
        .height(32).borderRadius(8)
        .backgroundColor(this.pal().surface).fontColor(this.pal().text2)
        .onClick(() => {
          animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => {
            this.selectionMode = false; this.selectedIds = new Set();
          });
        })
    }.width('100%').padding({ left: 20, right: 20, top: 6, bottom: 6 })
    .transition(
      TransitionEffect.asymmetric(
        TransitionEffect.translate({ y: -40 }).combine(TransitionEffect.OPACITY)
          .animation({ duration: 250, curve: Curve.FastOutSlowIn }),
        TransitionEffect.translate({ y: -40 }).combine(TransitionEffect.OPACITY)
          .animation({ duration: 200, curve: Curve.FastOutSlowIn })
      )
    )
  }

  private doBatchDelete(): void {
    promptAction.showDialog({
      title: '批量删除',
      message: '确定要删除选中的 ' + this.selectedIds.size + ' 个对象吗？',
      buttons: [
        { text: '取消', color: this.pal().text2 },
        { text: '删除', color: this.pal().danger }
      ]
    }).then((result: Object): void => {
      const r: Record<string, number> = result as Record<string, number>;
      if (r['index'] === 1) {
        const ids: string[] = [];
        this.selectedIds.forEach((id: string) => {
          ids.push(id);
        });
        if (this.keyVaultInnerTab === 0) {
          this.kvs.removeSshKeys(ids);
        } else {
          this.kvs.removeTotpEntries(ids);
        }
        this.selectionMode = false;
        this.selectedIds = new Set<string>();
        this.load();
      }
    });
  }

  @Builder selectionDeleteBtn() {
    Row() {
      Button('删除已选 (' + this.selectedIds.size + ')').width('100%').height(40).fontSize(14)
        .backgroundColor('#FF3B30').fontColor('#FFFFFF').borderRadius(10)
        .onClick(() => {
          promptAction.showDialog({
            title: '批量删除',
            message: '确定要删除选中的 ' + this.selectedIds.size + ' 个对象吗？此操作不可恢复。',
            buttons: [
              { text: '取消', color: this.pal().text2 },
              { text: '删除', color: this.pal().danger }
            ]
          }).then((result: Object): void => {
            const r: Record<string, number> = result as Record<string, number>;
            if (r['index'] === 1) {
              const ids: string[] = [];
              this.selectedIds.forEach((id: string) => {
                ids.push(id);
              });
              if (this.keyVaultInnerTab === 0) {
                this.kvs.removeSshKeys(ids);
              } else {
                this.kvs.removeTotpEntries(ids);
              }
              this.selectionMode = false;
              this.selectedIds = new Set<string>();
              this.load();
            }
          });
        })
    }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 12 })
  }

  // ==================== SSH 表单 ====================
  private resetSshForm(): void {
    this.editingSshKey = new SshKey();
    this.formLabel = ''; this.formKeyType = SshKeyType.ED25519;
    this.formComment = ''; this.formPasteKey = ''; this.formFileName = ''; this.formMode = 0;
  }

  private async importSshKeyFile(): Promise<void> {
    const result: SshKeyImportResult | null = await this.sshKeyImporter.pickAndInspect();
    if (result === null) { return; }
    if (!result.ok || result.key === null) {
      promptAction.showToast({ message: result.error || '私钥文件不可用', duration: 2500 });
      return;
    }
    const imported: SshKey = result.key;
    this.formPasteKey = imported.privateKey;
    this.formFileName = result.fileName;
    this.formKeyType = imported.keyType;
    if (this.formLabel.trim() === '') { this.formLabel = imported.label; }
    this.formMode = 0;
    promptAction.showToast({ message: '私钥已读取，请保存到密钥保险库', duration: 1800 });
  }

  private async doAddSshKey(): Promise<void> {
    if (this.formLabel.trim() === '') {
      promptAction.showToast({ message: '请输入密钥名称', duration: 1500 });
      return;
    }
    const isEdit: boolean = this.editingSshKey.id !== '';
    if (!isEdit && this.formMode === 0 && this.formPasteKey.trim() === '') {
      promptAction.showToast({ message: '请粘贴私钥内容', duration: 1500 });
      return;
    }

    const key: SshKey = new SshKey();
    if (isEdit) {
      // 编辑模式: 继承原有不可变字段
      key.id = this.editingSshKey.id;
      key.privateKey = this.editingSshKey.privateKey;
      key.publicKey = this.editingSshKey.publicKey;
      key.fingerprint = this.editingSshKey.fingerprint;
      key.createdAt = this.editingSshKey.createdAt;
      key.syncVersion = this.editingSshKey.syncVersion;
      key.locked = this.editingSshKey.locked;
      key.lockType = this.editingSshKey.lockType;
      key.userId = this.editingSshKey.userId;
      key.formatVersion = this.editingSshKey.formatVersion;
      key.privateKeyEncrypted = this.editingSshKey.privateKeyEncrypted;
    } else {
      key.id = SshKey.generateId();
    }
    key.label = this.formLabel.trim();
    key.keyType = this.formKeyType as SshKeyType;
    key.comment = this.formComment.trim();

    if (this.formMode === 0 && this.formPasteKey.trim() !== '' &&
        this.formPasteKey !== '(HUKS encrypted)') {
      // 粘贴模式 — 使用 native inspectSshPrivateKey 提取真实公钥/fingerprint
      const info: SshPrivateKeyInfo =
        this.loader.inspectSshPrivateKey(this.formPasteKey.trim(), '');
      if (!info['ok']) {
        if (info['encrypted']) {
          key.privateKey = this.formPasteKey.trim();
          key.publicKey = '';
          key.fingerprint = '';
          key.privateKeyEncrypted = true;
          key.formatVersion = 1;
        } else {
          promptAction.showToast({
            message: '[CC-SSHKEY-02] 私钥解析失败: ' + (info['error'] || '未知错误'),
            duration: 2500
          });
          return;
        }
      } else {
        key.privateKey = this.formPasteKey.trim();
        key.publicKey = info['publicKeyOpenSsh'];
        key.fingerprint = info['fingerprintSha256'];
        key.privateKeyEncrypted = info['encrypted'];
        key.formatVersion = 1;
      }
    } else if (!isEdit) {
      // 生成模式 — 使用 native OpenSSL EVP_PKEY 生成标准 OpenSSH 密钥对
      const keyTypeStr: string =
        this.formKeyType === SshKeyType.RSA ? 'rsa' : 'ed25519';
      const bits: number = this.formKeyType === SshKeyType.RSA ? 4096 : 256;
      const result: GeneratedSshKeyPair =
        this.loader.generateSshKeyPair(keyTypeStr, bits, this.formComment.trim(), '');
      if (!result['ok']) {
        promptAction.showToast({
          message: '[CC-SSHKEY-03] 密钥生成失败: ' + (result['error'] || '未知错误'),
          duration: 2500
        });
        return;
      }
      key.privateKey = result['privateKeyPem'];
      key.publicKey = result['publicKeyOpenSsh'];
      key.fingerprint = result['fingerprintSha256'];
      key.privateKeyEncrypted = false;
      key.formatVersion = 1;
    }

    const ok: boolean = isEdit ? this.kvs.updateSshKey(key) : this.kvs.addSshKey(key);
    if (ok) {
      this.showSheet = false;
      this.editingSshKey = new SshKey();
      this.resetSshForm();
      this.load();
      promptAction.showToast({ message: isEdit ? '密钥已更新' : '密钥已保存', duration: 1500 });
    }
  }

  // ==================== TOTP 表单 ====================
  private resetTotpForm(): void {
    this.formIssuer = ''; this.formAccount = ''; this.formSecret = '';
    this.formDigits = 6; this.formPeriod = 30;
  }

  private doAddTotp(): void {
    if (this.formIssuer.trim() === '' || this.formSecret.trim() === '') {
      promptAction.showToast({ message: 'Issuer 和 Secret 不能为空', duration: 1500 });
      return;
    }
    const entry: TotpEntry = new TotpEntry();
    entry.id = TotpEntry.generateId();
    entry.issuer = this.formIssuer.trim();
    entry.account = this.formAccount.trim();
    entry.secret = this.formSecret.trim().replace(/\s+/g, '');
    entry.digits = this.formDigits;
    entry.period = this.formPeriod;
    entry.algorithm = 0; // SHA1 default

    if (this.kvs.addTotpEntry(entry)) {
      this.showSheet = false;
      this.resetTotpForm();
      this.load();
      promptAction.showToast({ message: '2FA 已添加', duration: 1500 });
    }
  }

  // TOTP 导入
  private async importTotpFile(): Promise<void> {
    try {
      const selectOptions = new picker.DocumentSelectOptions();
      const viewPicker = new picker.DocumentViewPicker();
      const uris: string[] = await viewPicker.select(selectOptions);
      if (uris.length === 0) { return; }
      const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(file.fd);
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      const view = new Uint8Array(buf);
      let jsonStr = '';
      for (let i = 0; i < view.length; i++) {
        jsonStr += String.fromCharCode(view[i]);
      }
      const parsed: Object = JSON.parse(jsonStr);
      let entriesArr: TotpEntryJSON[];
      if (parsed instanceof Array) {
        entriesArr = parsed as TotpEntryJSON[];
      } else {
        const data: Record<string, Object> = parsed as Record<string, Object>;
        entriesArr = data['entries'] as TotpEntryJSON[];
      }
      if (!entriesArr || entriesArr.length === 0) {
        promptAction.showToast({ message: '[importTotp] 无有效条目', duration: 2000 });
        return;
      }
      let imported = 0;
      for (let i = 0; i < entriesArr.length; i++) {
        const entry: TotpEntry = TotpEntry.fromJSON(entriesArr[i]);
        entry.id = TotpEntry.generateId();
        if (this.kvs.addTotpEntry(entry)) { imported++; }
      }
      this.load();
      promptAction.showToast({ message: '已导入 ' + imported + ' 个条目', duration: 1500 });
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      if (be.code !== 0) {
        promptAction.showToast({ message: '[importTotp] 导入失败: code=' + be.code, duration: 2000 });
      }
    }
  }

  private onQrScanned(entry: TotpEntry): void {
    this.showQrScan = false;
    if (this.kvs.addTotpEntry(entry)) {
      this.load();
      promptAction.showToast({ message: '2FA 已添加', duration: 1500 });
    }
  }

  build() {
    Stack() {
      // 内容列表 — bg直接附着在List上, 与主机页一致
      List({ space: 8 }) {
        // 顶栏占位: 跟随真实系统避让区, 与渐变玻璃层高度一致
        ListItem() { Column().height(this.titleBarHeight() + 8) }

        // 选择工具栏
        if (this.selectionMode) {
          ListItem() {
            if (this.keyVaultInnerTab === 0) {
              this.selectionToolbar(this.sshKeys.map((k: SshKey) => k.id))
            } else {
              this.selectionToolbar(this.totpEntries.map((e: TotpEntry) => e.id))
            }
          }
        }

        // SSH 密钥列表
        if (this.keyVaultInnerTab === 0) {
          if (this.sshKeys.length === 0) {
            ListItem() {
              Column() {
                SymbolGlyph($r('sys.symbol.key_fill'))
                  .fontSize(48).fontColor([this.pal().text3])
                Text('还没有 SSH 密钥')
                  .fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
                  .margin({ top: 16 })
                Text('点击底部 + 添加 SSH 密钥')
                  .fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
                  .margin({ top: 6 }).lineHeight(20)
              }.width('100%').constraintSize({ minHeight: 400 }).justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            }
          } else {
            LazyForEach(this.sshKeyDataSource, (key: SshKey) => {
              ListItem() {
                SshKeyCard({
                  sshKey: key,
                  showCheckbox: this.selectionMode,
                  checkboxSelected: this.selectedIds.has(key.id),
                  onCheckChange: (v: boolean) => { this.toggleSelect(key.id, v); },
                  onEdit: () => { this.handleSshEdit(key); },
                  onToggleLock: () => { this.toggleSshLock(key); },
                  onSelect: () => { this.selectionMode = true; this.selectedIds = new Set(); this.selectedIds.add(key.id); },
                  onDelete: () => { this.deleteSshKeyItem(key); }
                })
              }
              .gesture(
                LongPressGesture().onAction(() => {
                  if (!this.selectionMode) {
                    animateTo({ duration: 250, curve: Curve.FastOutSlowIn }, () => {
                      this.selectionMode = true; this.selectedIds = new Set(); this.selectedIds.add(key.id);
                    });
                  }
                })
              )
              .onClick(() => {
                if (this.selectionMode) { this.toggleSelect(key.id, !this.selectedIds.has(key.id)); }
              })
              .swipeAction((this.selectionMode || this.isDesktopDevice) ? {
                start: { builder: () => {} }, end: { builder: () => {} }, edgeEffect: SwipeEdgeEffect.Spring
              } : {
                start: { builder: () => { this.editLockRow(key); } },
                end: { builder: () => { this.deleteBtnSsh(key); } },
                edgeEffect: SwipeEdgeEffect.Spring
              })
              .transition(
                TransitionEffect.asymmetric(
                  TransitionEffect.translate({ x: -200 })
                    .animation({ duration: 250, curve: Curve.FastOutSlowIn }),
                  TransitionEffect.translate({ x: -200, y: -10 })
                    .combine(TransitionEffect.scale({ x: 0.7, y: 0.7 }))
                    .combine(TransitionEffect.OPACITY)
                    .animation({ duration: 350, curve: curves.interpolatingSpring(0, 0.8, 300, 20) })
                )
              )
            }, (key: SshKey) => key.id)
          }
        }

        // 2FA 验证器列表
        if (this.keyVaultInnerTab === 1) {
          if (this.totpPageLocked && !this.totpUnlocked) {
            ListItem() {
              Column() {
                Text('需要验证身份')
                  .fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.pal().text).margin({ bottom: 6 })
                Text('此内容已通过 TOTP 隐私保护加密')
                  .fontSize(13).fontColor(this.pal().text2).textAlign(TextAlign.Center)
                  .padding({ left: 24, right: 24 }).margin({ bottom: 20 })
                Button('验证身份').width('60%').height(40).fontSize(14).fontWeight(FontWeight.Medium)
                  .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10)
                  .onClick(async () => {
                    const r = await showLockGate('2FA 验证器', 'biometric');
                    if (r.ok) { this.totpUnlocked = true; }
                    else {
                      const msg: string = lockGateErrorMessage(r);
                      if (msg !== '') { promptAction.showToast({ message: msg, duration: 2000 }); }
                    }
                  })
              }.width('100%').constraintSize({ minHeight: 400 }).justifyContent(FlexAlign.Center)
            }
          } else if (this.totpEntries.length === 0) {
            ListItem() {
              Column() {
                SymbolGlyph($r('sys.symbol.checkmark_shield'))
                  .fontSize(48).fontColor([this.pal().text3])
                Text('还没有 2FA 验证器')
                  .fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
                  .margin({ top: 16 })
                Text('点击底部 + 添加 2FA 验证器')
                  .fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
                  .margin({ top: 6 }).lineHeight(20)
              }.width('100%').constraintSize({ minHeight: 400 }).justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            }
          } else {
            LazyForEach(this.totpEntryDataSource, (entry: TotpEntry) => {
              ListItem() {
                TotpCodeCard({
                  entry: entry,
                  pageLocked: this.totpPageLocked && !this.totpUnlocked,
                  showCheckbox: this.selectionMode,
                  checkboxSelected: this.selectedIds.has(entry.id),
                  onCheckChange: (v: boolean) => { this.toggleSelect(entry.id, v); }
                })
              }
              .gesture(
                LongPressGesture().onAction(() => {
                  if (!this.selectionMode) {
                    animateTo({ duration: 250, curve: Curve.FastOutSlowIn }, () => {
                      this.selectionMode = true; this.selectedIds = new Set(); this.selectedIds.add(entry.id);
                    });
                  }
                })
              )
              .onClick(() => {
                if (this.selectionMode) { this.toggleSelect(entry.id, !this.selectedIds.has(entry.id)); }
              })
              .swipeAction((this.selectionMode || this.isDesktopDevice) ? {
                start: { builder: () => {} }, end: { builder: () => {} }, edgeEffect: SwipeEdgeEffect.Spring
              } : {
                start: { builder: () => { this.totpEditLockRow(entry); } },
                end: { builder: () => { this.deleteBtnTotp(entry); } },
                edgeEffect: SwipeEdgeEffect.Spring
              })
              .transition(
                TransitionEffect.asymmetric(
                  TransitionEffect.translate({ x: -200 })
                    .animation({ duration: 250, curve: Curve.FastOutSlowIn }),
                  TransitionEffect.translate({ x: -200, y: -10 })
                    .combine(TransitionEffect.scale({ x: 0.7, y: 0.7 }))
                    .combine(TransitionEffect.OPACITY)
                    .animation({ duration: 350, curve: curves.interpolatingSpring(0, 0.8, 300, 20) })
                )
              )
            }, (entry: TotpEntry) => entry.id)
          }
        }

        // 底部 FAB 占位
        ListItem() { Column().height(140) }
      }
      .width('100%').height('100%')
      .padding({ left: 16, right: 16, top: 0, bottom: 0 })
      .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .overlay(this.TitleBarOverlay(), { align: Alignment.Top })
    }
    .width('100%').height('100%')
    // KeyVaultPage 非 @Entry — 单 bindSheet + sheetMode 切换 (参考 HostListPage @Entry 的 settings Builder 内多子 Sheet 模式)
    .bindSheet($$this.showSheet, this.unifiedSheet(), {
      height: SheetSize.FIT_CONTENT,
      preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
      dragBar: this.sheetMode !== 1,
      backgroundColor: Color.Transparent, blurStyle: BlurStyle.NONE, showClose: false,
      onDisappear: () => {
        if (this.sheetMode === 0) { this.resetSshForm(); this.resetTotpForm(); }
        else { this.load(); }
      }
    })
  }

  // ==================== 统一 Sheet Builder ====================
  @Builder unifiedSheet() {
    if (this.sheetMode === 0) {
      this.addFormWrapper()
    } else if (this.sheetMode === 1) {
      this.addChoiceWrapper()
    } else if (this.sheetMode === 2) {
      this.manageWrapper()
    } else if (this.sheetMode === 3) {
      this.installWrapper()
    } else if (this.sheetMode === 4) {
      this.passphraseWrapper()
    }
  }

  @Builder addFormWrapper() {
    Column() {
      Text(this.showAddTab === 0
        ? (this.editingSshKey.id !== '' ? '编辑 SSH 密钥' : '添加 SSH 密钥')
        : '添加 2FA 验证器')
        .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        .margin({ bottom: 10 }).width('100%').fontFamily(this.font())
      Scroll() {
        Column() {
          if (this.showAddTab === 0) { this.sshFormSheet() }
          if (this.showAddTab === 1) { this.totpFormSheet() }
        }.width('100%')
      }
      .constraintSize({ maxHeight: 400 }).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring).width('100%')
    }
    .padding({ left: 24, right: 24, top: 24, bottom: 40 }).width('100%')
    .constraintSize({ maxWidth: 760 })
    .borderRadius(this.breakpoint === 'sm' ? { topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 } : 20)
    .backgroundColor(this.pal().bg).backgroundBlurStyle(BlurStyle.Regular)
  }

  @Builder addChoiceWrapper() {
    Column() {
      this.choiceItem2('导入已有私钥', $r('sys.symbol.doc_plaintext'), () => {
        this.resetSshForm(); this.formMode = 0; this.showAddTab = 0; this.sheetMode = 0;
      })
      this.choiceItem2('生成新密钥', $r('sys.symbol.star_fill'), () => {
        this.resetSshForm(); this.formMode = 1; this.showAddTab = 0; this.sheetMode = 0;
      })
      this.choiceItem2('生成并安装到主机', $r('sys.symbol.arrowshape_right_fill'), () => {
        const tempKey: SshKey = new SshKey();
        tempKey.id = SshKey.generateId();
        tempKey.label = '';
        tempKey.keyType = SshKeyType.ED25519;
        this.sheetKey = tempKey;
        this.sheetMode = 3;
      })
    }
    .padding({ left: 24, right: 24, top: 24, bottom: 40 }).width('100%')
    .borderRadius(this.breakpoint === 'sm' ? { topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 } : 20)
    .backgroundColor(this.pal().bg).backgroundBlurStyle(BlurStyle.Regular)
  }

  @Builder manageWrapper() {
    Column() {
      this.keyManagerSheet()
    }
    .width('100%')
    .constraintSize({ maxWidth: 760 })
  }

  @Builder installWrapper() {
    Column() {
      this.installSheetWrapper()
    }
    .width('100%')
    .constraintSize({ maxWidth: 760 })
  }

  @Builder passphraseWrapper() {
    Column() {
      Row() {
        Text(this.sheetKey.privateKeyEncrypted ? '修改密钥密码' : '设置密钥密码')
          .fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(this.font())
          .layoutWeight(1)
        Text('返回').fontSize(13).fontColor(this.accentColor)
          .fontFamily(this.font()).onClick(() => { this.sheetMode = 2; })
      }.width('100%').margin({ bottom: 14 })

      SshKeyPassphraseSubSheet({
        sshKey: this.sheetKey,
        onComplete: (newPrivateKey: string, newEncrypted: boolean) => {
          const updated: SshKey = new SshKey();
          updated.id = this.sheetKey.id;
          updated.label = this.sheetKey.label;
          updated.comment = this.sheetKey.comment;
          updated.keyType = this.sheetKey.keyType;
          updated.privateKey = newPrivateKey;
          updated.publicKey = this.sheetKey.publicKey;
          updated.fingerprint = this.sheetKey.fingerprint;
          updated.locked = this.sheetKey.locked;
          updated.lockType = this.sheetKey.lockType;
          updated.createdAt = this.sheetKey.createdAt;
          updated.syncVersion = this.sheetKey.syncVersion;
          updated.userId = this.sheetKey.userId;
          updated.formatVersion = this.sheetKey.formatVersion;
          updated.privateKeyEncrypted = newEncrypted;
          this.onKeyManagerChange(updated);
          this.sheetKey = updated;
          this.sheetMode = 2;
        }
      })
    }
    .padding({ left: 24, right: 24, top: 24, bottom: 40 }).width('100%')
    .constraintSize({ maxWidth: 760 })
    .borderRadius(this.breakpoint === 'sm' ? { topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 } : 20)
    .backgroundColor(this.pal().bg).backgroundBlurStyle(BlurStyle.Regular)
    .border(this.breakpoint === 'sm'
      ? { width: 0, color: Color.Transparent, style: BorderStyle.Solid }
      : { width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
  }

  @Builder choiceItem2(l: string, icon: Resource, cb: () => void) {
    Row() {
      SymbolGlyph(icon).fontSize(22).fontColor([this.accentColor])
      Text(l).fontSize(14).fontWeight(FontWeight.Medium)
        .fontColor(this.pal().text).fontFamily(this.font())
        .layoutWeight(1).margin({ left: 12 })
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([this.pal().text3])
    }
    .width('100%').padding(12).borderRadius(10)
    .backgroundColor(this.pal().card)
    .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
    .margin({ bottom: 8 })
    .onClick(cb)
  }

  /** 沉浸顶栏 (参照设置页: 常驻透明overlay, 无模糊切换) */
  @Builder TitleBarOverlay() {
    Stack() {
      Column() {
        Row().width('100%').height(this.topSafeHeightVp() + this.titleOffsetY())
        Row() {
          Text('密钥保险库').fontSize(27).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text).fontFamily(this.font())
        }.width('100%').padding({ left: 24, right: 24, bottom: 8 })

        // 居中悬浮 Tab 栏 (xl 由侧边栏控制, 隐藏此栏)
        if (!this.hideTabBar) {
          Row() {
            Stack({ alignContent: Alignment.Start }) {
              Column()
                .width(80).height(32).borderRadius(16)
                .backgroundColor(this.accentColor)
                .translate({ x: this.keyVaultInnerTab === 0 ? 0 : 82, y: 0 })
                .animation({ duration: 300, curve: Curve.FastOutSlowIn })
              Row() {
                Column() {
                  Text('SSH 密钥').fontSize(13)
                    .fontColor(this.keyVaultInnerTab === 0 ? '#FFFFFF' : this.pal().text2)
                    .fontWeight(this.keyVaultInnerTab === 0 ? FontWeight.Medium : FontWeight.Normal)
                }.width(80).height(32).borderRadius(16).justifyContent(FlexAlign.Center)
                .onClick(() => { this.showSheet = false; this.showSheet = false; this.keyVaultInnerTab = 0; })
                Blank().width(2)
                Column() {
                  Text('2FA 验证器').fontSize(13)
                    .fontColor(this.keyVaultInnerTab === 1 ? '#FFFFFF' : this.pal().text2)
                    .fontWeight(this.keyVaultInnerTab === 1 ? FontWeight.Medium : FontWeight.Normal)
                }.width(80).height(32).borderRadius(16).justifyContent(FlexAlign.Center)
                .onClick(async () => {
                  if (this.totpPageLocked && !this.totpUnlocked) {
                    const r = await showLockGate('2FA 验证器', 'biometric');
                    if (r.ok) { this.showSheet = false; this.showSheet = false; this.totpUnlocked = true; this.keyVaultInnerTab = 1; }
                    else {
                      const msg: string = lockGateErrorMessage(r);
                      if (msg !== '') { promptAction.showToast({ message: msg, duration: 2000 }); }
                      this.keyVaultInnerTab = 0;
                    }
                  } else {
                    this.showSheet = false; this.showSheet = false; this.keyVaultInnerTab = 1;
                  }
                })
              }
            }
            .borderRadius(20).backgroundColor(this.pal().surface)
            .backgroundBlurStyle(BlurStyle.Regular)
            .padding({ left: 4, right: 4, top: 4, bottom: 4 })
          }
          .width('100%').justifyContent(FlexAlign.Center)
          .padding({ top: 8 })
        }
      }.width('100%')
      .backgroundColor(Color.Transparent)
    }
    .width('100%')
    .height(this.titleBarHeight())
    .hitTestBehavior(HitTestMode.Transparent)
  }

  // addFormWrapper() 已替换 keyVaultAddSheet() — 见统一 Sheet Builder 区域

  // ==================== SSH 密钥列表 ====================
  @Builder sshKeyContent() {
    Stack() {
      Column() {
        // 选择工具栏
        if (this.selectionMode && this.sshKeys.length > 0 && this.keyVaultInnerTab === 0) {
          this.selectionToolbar(this.sshKeys.map((k: SshKey) => k.id))
        }
        if (this.sshKeys.length === 0) {
          Column() {
            SymbolGlyph($r('sys.symbol.key_fill'))
              .fontSize(48).fontColor([this.pal().text3])
            Text('还没有 SSH 密钥')
              .fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
              .margin({ top: 16 })
            Text('点击底部 + 添加 SSH 密钥')
              .fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
              .margin({ top: 6 }).lineHeight(20)
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else {
          List({ space: 8 }) {
            LazyForEach(this.sshKeyDataSource, (key: SshKey) => {
              ListItem() {
                SshKeyCard({
                  sshKey: key,
                  showCheckbox: this.selectionMode,
                  checkboxSelected: this.selectedIds.has(key.id),
                  onCheckChange: (v: boolean) => { this.toggleSelect(key.id, v); },
                  onEdit: () => { this.handleSshEdit(key); },
                  onToggleLock: () => { this.toggleSshLock(key); },
                  onSelect: () => { this.selectionMode = true; this.selectedIds = new Set(); this.selectedIds.add(key.id); },
                  onDelete: () => { this.deleteSshKeyItem(key); }
                })
              }
              .gesture(
                LongPressGesture().onAction(() => {
                  if (!this.selectionMode) {
                    animateTo({ duration: 250, curve: Curve.FastOutSlowIn }, () => {
                      this.selectionMode = true; this.selectedIds = new Set(); this.selectedIds.add(key.id);
                    });
                  }
                })
              )
              .onClick(() => {
                if (this.selectionMode) { this.toggleSelect(key.id, !this.selectedIds.has(key.id)); }
              })
              .swipeAction((this.selectionMode || this.isDesktopDevice) ? {
                start: { builder: () => {} }, end: { builder: () => {} }, edgeEffect: SwipeEdgeEffect.Spring
              } : {
                start: { builder: () => { this.editLockRow(key); } },
                end: { builder: () => { this.deleteBtnSsh(key); } },
                edgeEffect: SwipeEdgeEffect.Spring
              })
              .transition(
                TransitionEffect.asymmetric(
                  TransitionEffect.translate({ x: -200 })
                    .animation({ duration: 250, curve: Curve.FastOutSlowIn }),
                  TransitionEffect.translate({ x: -200, y: -10 })
                    .combine(TransitionEffect.scale({ x: 0.7, y: 0.7 }))
                    .combine(TransitionEffect.OPACITY)
                    .animation({ duration: 350, curve: curves.interpolatingSpring(0, 0.8, 300, 20) })
                )
              )
            }, (key: SshKey) => key.id)
          }
          .layoutWeight(1).padding({ left: 16, right: 16, top: 4, bottom: 140 })
        }
      }.width('100%').height('100%')
    }.width('100%').height('100%')
  }

  // ==================== TOTP 列表 ====================
  @Builder totpContent() {
    Stack() {
      Column() {
        if (this.totpEntries.length === 0) {
          Column() {
            SymbolGlyph($r('sys.symbol.checkmark_shield'))
              .fontSize(48).fontColor([this.pal().text3])
            Text('还没有 2FA 验证器')
              .fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(this.font())
              .margin({ top: 16 })
            Text('点击底部 + 添加 2FA 验证器')
              .fontSize(13).fontColor(this.pal().text3).fontFamily(this.font())
              .margin({ top: 6 }).lineHeight(20)
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else {
          // 选择工具栏
          if (this.selectionMode && this.keyVaultInnerTab === 1) {
            this.selectionToolbar(this.totpEntries.map((e: TotpEntry) => e.id))
          }
          List({ space: 8 }) {
            LazyForEach(this.totpEntryDataSource, (entry: TotpEntry) => {
              ListItem() {
                TotpCodeCard({
                  entry: entry,
                  pageLocked: this.totpPageLocked && !this.totpUnlocked,
                  showCheckbox: this.selectionMode,
                  checkboxSelected: this.selectedIds.has(entry.id),
                  onCheckChange: (v: boolean) => { this.toggleSelect(entry.id, v); }
                })
              }
              .gesture(
                LongPressGesture().onAction(() => {
                  if (!this.selectionMode) {
                    animateTo({ duration: 250, curve: Curve.FastOutSlowIn }, () => {
                      this.selectionMode = true; this.selectedIds = new Set(); this.selectedIds.add(entry.id);
                    });
                  }
                })
              )
              .onClick(() => {
                if (this.selectionMode) { this.toggleSelect(entry.id, !this.selectedIds.has(entry.id)); }
              })
              .swipeAction((this.selectionMode || this.isDesktopDevice) ? {
                start: { builder: () => {} }, end: { builder: () => {} }, edgeEffect: SwipeEdgeEffect.Spring
              } : {
                start: { builder: () => { this.totpEditLockRow(entry); } },
                end: { builder: () => { this.deleteBtnTotp(entry); } },
                edgeEffect: SwipeEdgeEffect.Spring
              })
              .transition(
                TransitionEffect.asymmetric(
                  TransitionEffect.translate({ x: -200 })
                    .animation({ duration: 250, curve: Curve.FastOutSlowIn }),
                  TransitionEffect.translate({ x: -200, y: -10 })
                    .combine(TransitionEffect.scale({ x: 0.7, y: 0.7 }))
                    .combine(TransitionEffect.OPACITY)
                    .animation({ duration: 350, curve: curves.interpolatingSpring(0, 0.8, 300, 20) })
                )
              )
            }, (entry: TotpEntry) => entry.id)
          }
          .layoutWeight(1).padding({ left: 16, right: 16, top: 4, bottom: 140 })
        }
      }.width('100%').height('100%')

      // 2FA 隐私遮盖层 (官方风格)
      if (this.totpPageLocked && !this.totpUnlocked) {
        Column() {
          Column() {
            Text('需要验证身份')
              .fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.pal().text).margin({ bottom: 6 })
            Text('此内容已通过 TOTP 隐私保护加密')
              .fontSize(13).fontColor(this.pal().text2).textAlign(TextAlign.Center)
              .padding({ left: 24, right: 24 }).margin({ bottom: 20 })
            Button('验证身份').width('60%').height(40).fontSize(14).fontWeight(FontWeight.Medium)
              .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10)
              .shadow({ radius: 10, color: this.pal().fabGlow, offsetY: 2 })
              .onClick(async () => {
                const r = await showLockGate('2FA 验证器', 'biometric');
                if (r.ok) { this.totpUnlocked = true; }
                else {
                  const msg: string = lockGateErrorMessage(r);
                  if (msg !== '') { promptAction.showToast({ message: msg, duration: 2000 }); }
                }
              })
          }
          .width('86%').padding(28).borderRadius(20)
          .backgroundColor(this.pal().bg).backgroundBlurStyle(BlurStyle.Regular)
          .shadow({ radius: 32, color: 'rgba(0,0,0,0.15)', offsetY: 8 })
          .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
        }
        .width('100%').height('100%')
        .backgroundColor(this.pal().lockOverlay)
        .backdropBlur(20)
        .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      }
    }.width('100%').height('100%')
  }

  // ==================== SSH 添加表单 Sheet ====================
  @Builder sshFormSheet() {
    Column() {
      // 模式切换 (仅添加时显示, 编辑时不显示)
      if (this.editingSshKey.id === '') {
        Row() {
          this._tabBtn('粘贴私钥', 0)
          this._tabBtn('生成新密钥', 1)
        }.margin({ bottom: 14 })
      }

      this._f('名称', '如 myserver-key', this.formLabel,
        (v: string) => { this.formLabel = v; })

      // 密钥类型
      Row() {
        Text('密钥类型').fontSize(13).fontColor(this.pal().text).fontFamily(this.font())
        Blank()
        Text('ED25519').fontSize(12)
          .fontColor(this.formKeyType === SshKeyType.ED25519 ? '#FFFFFF' : this.pal().text2)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 }).borderRadius(8)
          .backgroundColor(this.formKeyType === SshKeyType.ED25519 ? this.accentColor : this.pal().surface)
          .onClick(() => { this.formKeyType = SshKeyType.ED25519; })
        Text('RSA').fontSize(12).margin({ left: 8 })
          .fontColor(this.formKeyType === SshKeyType.RSA ? '#FFFFFF' : this.pal().text2)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 }).borderRadius(8)
          .backgroundColor(this.formKeyType === SshKeyType.RSA ? this.accentColor : this.pal().surface)
          .onClick(() => { this.formKeyType = SshKeyType.RSA; })
      }.width('100%').height(44).margin({ bottom: 10 })

      // 私钥内容 (仅粘贴模式 formMode=0 或编辑模式显示)
      if (this.formMode === 0 || this.editingSshKey.id !== '') {
        Column() {
          if (this.editingSshKey.id === '') {
            Button(this.formFileName === '' ? '从文件导入私钥' : '重新选择私钥文件')
              .width('100%').height(36).fontSize(12)
              .backgroundColor(this.pal().surface).fontColor(this.accentColor).borderRadius(8)
              .margin({ bottom: 8 }).onClick(() => { this.importSshKeyFile(); })
            if (this.formFileName !== '') {
              Text('已读取: ' + this.formFileName).fontSize(11).fontColor(this.pal().text3)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%').margin({ bottom: 6 })
            }
          }
          Text('私钥内容').fontSize(11).fontColor(this.pal().text2).margin({ bottom: 4 })
          TextInput({ placeholder: '粘贴 OpenSSH 格式私钥...', text: this.formPasteKey })
            .height(100).backgroundColor(this.pal().surface).borderRadius(8)
            .fontColor(this.pal().text).placeholderColor(this.pal().text3)
            .fontFamily('monospace').fontSize(12)
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .onChange((v: string) => { this.formPasteKey = v; this.formFileName = ''; })
        }.width('100%').margin({ bottom: 10 })
      }

      // 编辑时显示公钥
      if (this.editingSshKey.id !== '') {
        Column() {
          Text('公钥').fontSize(11).fontColor(this.pal().text2).margin({ bottom: 4 })
          Text(this.editingSshKey.publicKey || '(无)')
            .fontSize(11).fontColor(this.pal().text3)
            .fontFamily('monospace').maxLines(3)
            .padding({ left: 10, right: 10, top: 8, bottom: 8 })
            .backgroundColor(this.pal().surface).borderRadius(8).width('100%')
        }.width('100%').margin({ bottom: 10 })
      }

      if (this.editingSshKey.id !== '') {
        Column() {
          Text('指纹').fontSize(11).fontColor(this.pal().text2).margin({ bottom: 4 })
          Text(this.editingSshKey.fingerprint || '(无)')
            .fontSize(11).fontColor(this.pal().text3)
            .fontFamily('monospace').maxLines(1)
        }.width('100%').margin({ bottom: 10 })
      }

      this._f('备注', '如 server@example.com', this.formComment,
        (v: string) => { this.formComment = v; })

      Button(this.editingSshKey.id !== '' ? '保存修改' : '保存').width('100%').height(40).fontSize(14).fontWeight(FontWeight.Medium)
        .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10).margin({ top: 12 })
        .onClick(() => { this.doAddSshKey(); })
    }
  }

  // ==================== TOTP 添加表单 Sheet ====================
  @Builder totpFormSheet() {
    Column() {
      // 扫码按钮 (相机图标)
      Button() {
        Row() {
          SymbolGlyph($r('sys.symbol.camera_fill'))
            .fontSize(16)
            .fontColor([this.accentColor])
          Text('导入 otpauth URI').fontSize(13)
            .fontColor(this.accentColor)
            .margin({ left: 6 })
        }
      }
      .width('100%').height(40)
      .backgroundColor(this.pal().surface)
      .borderRadius(10).margin({ bottom: 12 })
      .onClick(() => { this.showQrScan = true; })
      .bindSheet($$this.showQrScan, this.qrScanSheet(), {
        height: SheetSize.FIT_CONTENT,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        dragBar: false,
        backgroundColor: Color.Transparent, blurStyle: BlurStyle.NONE, showClose: false
      })

      // 导入 .atsf 文件
      Button('导入 .atsf 文件').width('100%').height(40).fontSize(13)
        .backgroundColor(this.pal().surface).fontColor(this.accentColor)
        .borderRadius(10).margin({ bottom: 12 })
        .onClick(() => { this.importTotpFile(); })

      Text('— 或手动输入 —').fontSize(11).fontColor(this.pal().text3)
        .width('100%').textAlign(TextAlign.Center).margin({ bottom: 12 })

      this._f('发行方 (Issuer)', '如 GitHub', this.formIssuer,
        (v: string) => { this.formIssuer = v; })
      this._f('账户名 (可选)', '如 user@example.com', this.formAccount,
        (v: string) => { this.formAccount = v; })
      this._f('密钥 (Secret)', 'Base32 字符串', this.formSecret,
        (v: string) => { this.formSecret = v; })

      Row() {
        Column() {
          Text('验证码位数').fontSize(11).fontColor(this.pal().text2).margin({ bottom: 4 })
          Row() {
            Text('6 位').fontSize(12)
              .fontColor(this.formDigits === 6 ? '#FFFFFF' : this.pal().text2)
              .padding({ left: 10, right: 10, top: 6, bottom: 6 }).borderRadius(8)
              .backgroundColor(this.formDigits === 6 ? this.accentColor : this.pal().surface)
              .onClick(() => { this.formDigits = 6; })
            Text('8 位').fontSize(12).margin({ left: 8 })
              .fontColor(this.formDigits === 8 ? '#FFFFFF' : this.pal().text2)
              .padding({ left: 10, right: 10, top: 6, bottom: 6 }).borderRadius(8)
              .backgroundColor(this.formDigits === 8 ? this.accentColor : this.pal().surface)
              .onClick(() => { this.formDigits = 8; })
          }
        }.width('48%')
        Column() {
          Text('时间间隔').fontSize(11).fontColor(this.pal().text2).margin({ bottom: 4 })
          Row() {
            Text('30s').fontSize(12)
              .fontColor(this.formPeriod === 30 ? '#FFFFFF' : this.pal().text2)
              .padding({ left: 10, right: 10, top: 6, bottom: 6 }).borderRadius(8)
              .backgroundColor(this.formPeriod === 30 ? this.accentColor : this.pal().surface)
              .onClick(() => { this.formPeriod = 30; })
            Text('60s').fontSize(12).margin({ left: 8 })
              .fontColor(this.formPeriod === 60 ? '#FFFFFF' : this.pal().text2)
              .padding({ left: 10, right: 10, top: 6, bottom: 6 }).borderRadius(8)
              .backgroundColor(this.formPeriod === 60 ? this.accentColor : this.pal().surface)
              .onClick(() => { this.formPeriod = 60; })
          }
        }.width('44%').margin({ left: 12 })
      }.width('100%').margin({ bottom: 12 })

      Button('添加').width('100%').height(40).fontSize(14).fontWeight(FontWeight.Medium)
        .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10).margin({ top: 12 })
        .onClick(() => { this.doAddTotp(); })
    }
  }

  // 扫码 Sheet — 1:1 复制 sheetBuilder 结构
  @Builder qrScanSheet() {
    Column() {
      Text('扫码添加')
        .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        .margin({ bottom: 10 }).width('100%').fontFamily(this.font())
      Scroll() {
        Column() {
          QrCodeScanner({ onScanned: (entry: TotpEntry) => { this.onQrScanned(entry); } })
          Blank().height(16)
        }.width('100%')
      }
      .constraintSize({ maxHeight: 400 })
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
    }
    .padding({ left: 24, right: 24, top: 24, bottom: 40 })
    .width('100%')
    .borderRadius(this.breakpoint === 'sm' ? 0 : 20)
    .backgroundColor(this.pal().bg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .shadow(this.breakpoint === 'sm'
      ? { radius: 0, color: 'rgba(0,0,0,0)', offsetY: 0 } as ShadowOptions
      : { radius: 24, color: 'rgba(0,0,0,0.12)', offsetY: 6 } as ShadowOptions)
    .border(this.breakpoint === 'sm'
      ? { width: 0, color: Color.Transparent, style: BorderStyle.Solid }
      : { width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
  }

  // ==================== 安装到主机 Sheet ====================
  @Builder installSheetWrapper() {
    Column() {
      Text(this.sheetKey.label !== '' ? '安装公钥到主机' : '生成并安装到主机')
        .fontSize(16).fontWeight(FontWeight.Bold)
        .fontColor(this.pal().text).fontFamily(this.font())
        .margin({ bottom: 14 }).width('100%')
      SshKeyInstallSheet({
        targetKey: this.sheetKey,
        onComplete: () => { this.showSheet = false; this.load(); }
      })
    }
    .padding({ left: 24, right: 24, top: 24, bottom: 40 }).width('100%')
    .constraintSize({ maxWidth: 760 })
    .borderRadius(this.breakpoint === 'sm' ? { topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 } : 20)
    .backgroundColor(this.pal().bg).backgroundBlurStyle(BlurStyle.Regular)
    .border(this.breakpoint === 'sm'
      ? { width: 0, color: Color.Transparent, style: BorderStyle.Solid }
      : { width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
  }

  // ==================== SSH 密钥管理 Sheet ====================
  @Builder keyManagerSheet() {
    Column() {
      Text('密钥管理').fontSize(16).fontWeight(FontWeight.Bold)
        .fontColor(this.pal().text).fontFamily(this.font())
        .margin({ bottom: 14 }).width('100%')
      SshKeyManagerSheet({
        sshKey: this.sheetKey,
        onChange: (updated: SshKey) => { this.onKeyManagerChange(updated); },
        onDelete: (keyId: string) => { this.onKeyManagerDelete(keyId); },
        onInstallToHost: (key: SshKey) => {
          this.sheetKey = key; this.sheetMode = 3;
        },
        onManagePassphrase: (key: SshKey) => {
          this.onKeyManagerPassphrase(key);
        }
      })
    }
    .padding({ left: 24, right: 24, top: 24, bottom: 40 }).width('100%')
    .borderRadius(this.breakpoint === 'sm' ? { topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 } : 20)
    .backgroundColor(this.pal().bg).backgroundBlurStyle(BlurStyle.Regular)
    .border(this.breakpoint === 'sm'
      ? { width: 0, color: Color.Transparent, style: BorderStyle.Solid }
      : { width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
  }

  // ==================== 表单辅助 ====================
  @Builder _tabBtn(label: string, mode: number) {
    Text(label).fontSize(13)
      .fontColor(this.formMode === mode ? '#FFFFFF' : this.pal().text2)
      .fontWeight(this.formMode === mode ? FontWeight.Medium : FontWeight.Normal)
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .borderRadius(8).backgroundColor(this.formMode === mode ? this.accentColor : this.pal().surface)
      .margin({ right: mode === 0 ? 8 : 0 })
      .onClick(() => { this.formMode = mode; })
  }

  @Builder _f(l: string, h: string, v: string, cb: (v: string) => void) {
    Column() {
      Text(l).fontSize(11).fontColor(this.pal().text2).margin({ bottom: 4 }).fontFamily(this.font())
      TextInput({ placeholder: h, text: v }).height(38).backgroundColor(this.pal().surface).borderRadius(8)
        .fontColor(this.pal().text).placeholderColor(this.pal().text3).fontFamily(this.font())
        .fontSize(13).padding({ left: 10, right: 10 }).onChange(cb)
    }.width('100%').margin({ bottom: 10 })
  }
}
