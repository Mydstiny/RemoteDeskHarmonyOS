import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { RustDeskRelayConfig } from '../../../model/RustDeskRelayConfig';
import { HostSyncService } from '../../../services/HostSyncService';
import { RustDeskProSyncService } from '../../../services/RustDeskProSyncService';
import { Palette, buildDark, buildLight, AppTheme } from '../../../common/Theme';
import { ResourceFabPicker } from '../ResourceFabPicker';
import { RustDeskRelayImportService, RustDeskRelayImportResult } from '../../../services/RustDeskRelayImportService';
import { RustDeskRelayKeyMode, resolveRustDeskRelayKey } from '../../../services/RustDeskRelayKeyPolicy';
import {
  RustDeskControlPlaneProfile,
  RUSTDESK_CONTROL_PLANE_DEFAULT,
  rustDeskControlPlaneProfileDescription,
  rustDeskControlPlaneProfileLabel
} from '../../../services/RustDeskControlPlanePolicy';
import { RustDeskRelayConfigPasteSheet } from './RustDeskRelayConfigPasteSheet';

@Component
export struct ModernRelayAddFlow {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  onClose: () => void = (): void => {};
  onSaved: (resourceId: string) => void = (_resourceId: string): void => {};

  @State step: string = 'protocol';
  @State errorText: string = '';
  @State savedRelayId: string = '';
  @State idServer: string = '';
  @State idPort: number = 21116;
  @State relayServer: string = '';
  @State relayPort: number = 21117;
  @State apiServer: string = '';
  @State serverKey: string = '';
  @State serverKeyMode: RustDeskRelayKeyMode = 'server_public_key';
  @State controlPlaneProfile: RustDeskControlPlaneProfile = RUSTDESK_CONTROL_PLANE_DEFAULT;
  @State proServer: string = '';
  @State proUser: string = '';
  @State proPassword: string = '';
  @State proBusy: boolean = false;
  @State importedFileName: string = '';
  @State importBusy: boolean = false;

  private hosts = HostSyncService.getInstance();
  private pro = RustDeskProSyncService.getInstance();
  private relayImporter = new RustDeskRelayImportService();

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor); }
  private font(): string { return AppTheme.fontFamily; }

  aboutToAppear(): void {
    const context = getContext(this) as common.Context;
    this.pro.init(context); this.reset();
  }

  private reset(): void {
    this.step = 'protocol'; this.errorText = ''; this.savedRelayId = '';
    this.idServer = ''; this.idPort = 21116; this.relayServer = ''; this.relayPort = 21117;
    this.apiServer = ''; this.serverKey = ''; this.serverKeyMode = 'server_public_key';
    this.controlPlaneProfile = RUSTDESK_CONTROL_PLANE_DEFAULT;
    this.proServer = ''; this.proUser = ''; this.proPassword = '';
    this.proBusy = false;
    this.importedFileName = ''; this.importBusy = false;
  }

  // 仅请求宿主关闭；等待 Sheet onDisappear 后再清理，避免退出动画中闪现第一步。
  private close(): void { this.onClose(); }
  private back(): void {
    this.errorText = '';
    if (this.step === 'pro') { this.step = 'saved'; }
    else if (this.step === 'rustdesk-paste') { this.step = 'rustdesk'; }
    else { this.step = 'protocol'; }
  }

  private selectProtocol(option: string): void {
    this.errorText = '';
    if (option === 'rustdesk') { this.step = 'rustdesk'; }
  }

  private saveRustDesk(): string {
    if (this.idServer.trim().length === 0) {
      this.errorText = 'ID 服务器不能为空'; return this.errorText;
    }
    if (!this.validPort(this.idPort) || !this.validPort(this.relayPort)) {
      this.errorText = '服务器端口必须在 1–65535 之间'; return this.errorText;
    }
    const key = resolveRustDeskRelayKey(this.serverKey, this.serverKeyMode, false);
    if (!key.ok) { this.errorText = key.error; return this.errorText; }
    const relay = new RustDeskRelayConfig(); relay.id = RustDeskRelayConfig.generateId();
    relay.idServer = this.idServer.trim(); relay.idServerPort = this.idPort;
    // RustDesk permits the relay endpoint to be omitted; use the ID endpoint
    // locally so the rest of the model never needs a fake duplicate entry.
    relay.relayServer = this.relayServer.trim() === '' ? relay.idServer : this.relayServer.trim();
    relay.relayPort = this.relayPort;
    relay.apiServer = this.apiServer.trim(); relay.key = key.value; relay.keyMode = key.mode;
    relay.controlPlaneProfile = this.controlPlaneProfile;
    if (!this.hosts.addRelay(relay)) { this.errorText = '中继服务器保存失败'; return this.errorText; }
    this.savedRelayId = relay.id; this.proServer = relay.apiServer; this.step = 'saved'; this.errorText = '';
    this.onSaved(relay.id);
    return '';
  }

  private applyRustDeskImport(result: RustDeskRelayImportResult): void {
    this.idServer = result.idServer; this.idPort = result.idServerPort;
    this.relayServer = result.relayServer; this.relayPort = result.relayPort;
    this.apiServer = result.apiServer; this.serverKey = result.key;
    this.serverKeyMode = resolveRustDeskRelayKey(result.key, 'auto', false).mode;
    this.importedFileName = result.fileName;
  }

  private importAndSavePastedRustDesk(result: RustDeskRelayImportResult): string {
    this.applyRustDeskImport(result);
    this.step = 'rustdesk';
    return '';
  }

  private async importRustDeskConfig(): Promise<void> {
    if (this.importBusy) { return; }
    this.importBusy = true; this.errorText = '';
    const result: RustDeskRelayImportResult | null = await this.relayImporter.pickAndParse();
    this.importBusy = false;
    if (result === null) { return; }
    if (!result.ok) { this.errorText = result.error; return; }
    this.applyRustDeskImport(result);
    promptAction.showToast({ message: '已导入 RustDesk 配置，请确认后保存', duration: 1800 });
  }

  private confirmRustDesk(): void {
    promptAction.showToast({ message: '中继服务器已保存', duration: 1600 }); this.close();
  }

  private async loginPro(): Promise<void> {
    if (this.savedRelayId.length === 0 || this.proServer.trim().length === 0 ||
      this.proUser.trim().length === 0 || this.proPassword.length === 0) {
      this.errorText = 'API 地址、用户名和密码不能为空'; return;
    }
    if (this.proBusy) { return; }
    this.proBusy = true; this.errorText = '';
    try {
      const accountId = 'rdpro_' + Date.now().toString(36);
      const result = await this.pro.loginAndSync({
        id: accountId, relayId: this.savedRelayId, serverUrl: this.proServer.trim(),
        username: this.proUser.trim(), password: this.proPassword
      });
      const count = result.addedIds.length + result.updatedIds.length;
      promptAction.showToast({ message: 'Pro 登录成功，已同步 ' + count.toString() + ' 台设备', duration: 2000 });
      this.proPassword = ''; this.close();
    } catch (err) {
      this.errorText = err instanceof Error ? err.message : 'Pro 登录失败';
    } finally { this.proBusy = false; }
  }

  private validPort(port: number): boolean { return port > 0 && port <= 65535; }
  private port(value: string, fallback: number): number { const parsed = parseInt(value); return isNaN(parsed) ? fallback : parsed; }

  @Builder private header(title: string, subtitle: string) {
    Row() {
      Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(18).fontColor([this.pal().text2]) }
        .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
        .onClick((): void => { this.back(); })
      Column() {
        Text(title).fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.pal().text).fontFamily(this.font())
        Text(subtitle).fontSize(12).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
      Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2]) }
        .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
        .onClick((): void => { this.close(); })
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

  @Builder private rustDeskForm() {
    this.header('添加 RustDesk 中继', '填写服务器内置连接选项')
    Scroll() {
      Column() {
        Button('粘贴从Rustdesk复制来的加密配置')
          .width('100%').height(40).borderRadius(10).backgroundColor(this.pal().surface)
          .fontColor(this.accentColor).enabled(!this.importBusy)
          .onClick((): void => { this.errorText = ''; this.step = 'rustdesk-paste'; })
        Button('从文件导入配置（兼容）')
          .width('100%').height(36).borderRadius(10).backgroundColor(this.pal().surface)
          .fontColor(this.pal().text2).enabled(!this.importBusy).margin({ top: 7 })
          .onClick((): void => { void this.importRustDeskConfig(); })
        if (this.importedFileName.length > 0) {
          Text('已读取：' + this.importedFileName + '（请检查字段后保存）')
            .fontSize(11).fontColor(this.pal().success).fontFamily(this.font())
            .width('100%').margin({ top: 7, bottom: 4 })
        }
        this.field('ID / Rendezvous 服务器', 'rs.example.com', this.idServer,
          (value: string): void => { this.idServer = value; })
        this.field('ID 服务器端口', '21116', this.idPort.toString(),
          (value: string): void => { this.idPort = this.port(value, 21116); })
        this.field('Relay 服务器', 'relay.example.com', this.relayServer,
          (value: string): void => { this.relayServer = value; })
        this.field('Relay 端口', '21117', this.relayPort.toString(),
          (value: string): void => { this.relayPort = this.port(value, 21117); })
        this.field('Server Pro API 地址（可选）', 'http://pro.example.com:21114', this.apiServer,
          (value: string): void => { this.apiServer = value; })
        Text('Relay 控制面认证策略').fontSize(12).fontColor(this.pal().text2).fontFamily(this.font())
          .margin({ bottom: 5 })
        Row() {
          Button('OSS Key-only').layoutWeight(1).height(32).fontSize(11).borderRadius(8)
            .backgroundColor(this.controlPlaneProfile === 'oss_key_only' ? this.accentColor : this.pal().surface)
            .fontColor(this.controlPlaneProfile === 'oss_key_only' ? Color.White : this.pal().text2)
            .onClick((): void => { this.controlPlaneProfile = 'oss_key_only'; })
          Button('地址簿 API').layoutWeight(1).height(32).fontSize(11).borderRadius(8).margin({ left: 6 })
            .backgroundColor(this.controlPlaneProfile === 'addressbook_only_custom' ? this.accentColor : this.pal().surface)
            .fontColor(this.controlPlaneProfile === 'addressbook_only_custom' ? Color.White : this.pal().text2)
            .onClick((): void => { this.controlPlaneProfile = 'addressbook_only_custom'; })
        }.width('100%').margin({ bottom: 6 })
        Row() {
          Button('官方 Server Pro').layoutWeight(1).height(32).fontSize(11).borderRadius(8)
            .backgroundColor(this.controlPlaneProfile === 'official_server_pro_token' ? this.accentColor : this.pal().surface)
            .fontColor(this.controlPlaneProfile === 'official_server_pro_token' ? Color.White : this.pal().text2)
            .onClick((): void => { this.controlPlaneProfile = 'official_server_pro_token'; })
          Button('自定义控制面').layoutWeight(1).height(32).fontSize(11).borderRadius(8).margin({ left: 6 })
            .backgroundColor(this.controlPlaneProfile === 'custom_control_plane' ? this.accentColor : this.pal().surface)
            .fontColor(this.controlPlaneProfile === 'custom_control_plane' ? Color.White : this.pal().text2)
            .onClick((): void => { this.controlPlaneProfile = 'custom_control_plane'; })
        }.width('100%').margin({ bottom: 4 })
        Text(rustDeskControlPlaneProfileLabel(this.controlPlaneProfile) + '：' +
          rustDeskControlPlaneProfileDescription(this.controlPlaneProfile))
          .fontSize(10).fontColor(this.pal().text3).fontFamily(this.font()).width('100%').lineHeight(15)
          .margin({ bottom: 10 })
        Text('服务器 Key（可选）').fontSize(12).fontColor(this.pal().text2).fontFamily(this.font()).margin({ bottom: 5 })
        Row() {
          Button('服务器公钥').layoutWeight(1).height(32).borderRadius(8)
            .backgroundColor(this.serverKeyMode === 'server_public_key' ? this.accentColor : this.pal().surface)
            .fontColor(this.serverKeyMode === 'server_public_key' ? Color.White : this.pal().text2)
            .onClick((): void => { this.serverKeyMode = 'server_public_key'; })
          Button('自定义共享 Key').layoutWeight(1).height(32).borderRadius(8).margin({ left: 8 })
            .backgroundColor(this.serverKeyMode === 'shared_access_key' ? this.accentColor : this.pal().surface)
            .fontColor(this.serverKeyMode === 'shared_access_key' ? Color.White : this.pal().text2)
            .onClick((): void => { this.serverKeyMode = 'shared_access_key'; })
        }.width('100%').margin({ bottom: 7 })
        this.field(this.serverKeyMode === 'shared_access_key' ? '共享 Key（原样发送）' : '服务器公钥',
          this.serverKeyMode === 'shared_access_key' ? '与 hbbs/hbbr -k 完全一致' : 'Base64 32 字节 Ed25519 公钥',
          this.serverKey, (value: string): void => { this.serverKey = value; },
          this.serverKeyMode === 'shared_access_key')
        Text(this.serverKeyMode === 'shared_access_key' ?
          '不会删除空格或 =；此模式只验证同一共享值，不能验证服务器身份。' :
          '留空将使用 RustDesk 默认公钥；公钥复制残留空白会自动规范化。')
          .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).width('100%').margin({ bottom: 11 })
        this.error()
        Button('保存').width('100%').height(42).borderRadius(10).backgroundColor(this.accentColor)
          .fontColor(Color.White).onClick((): void => { this.saveRustDesk(); })
      }.width('100%')
    }.constraintSize({ maxHeight: 460 }).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
  }

  @Builder private savedResult() {
    this.header('中继服务器已保存', '服务器配置已立即生效')
    Column() {
      SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(44).fontColor([this.pal().success])
      Text('你可以直接完成，也可以继续登录 RustDesk Server Pro 账户，同步 Pro 地址簿和设备。')
        .fontSize(13).fontColor(this.pal().text2).fontFamily(this.font()).lineHeight(20)
        .textAlign(TextAlign.Center).margin({ top: 14 })
    }.width('100%').padding({ top: 10, bottom: 22 })
    Row() {
      Button('确定保存').layoutWeight(1).height(42).borderRadius(10).backgroundColor(this.pal().surface)
        .fontColor(this.pal().text2).onClick((): void => { this.confirmRustDesk(); })
      Button('下一步').layoutWeight(1).height(42).borderRadius(10).backgroundColor(this.accentColor)
        .fontColor(Color.White).margin({ left: 10 }).onClick((): void => { this.step = 'pro'; })
    }.width('100%')
  }

  @Builder private proForm() {
    this.header('登录 Server Pro', '登录后同步 Pro 地址簿和设备')
    this.field('Server Pro API 地址', 'http://pro.example.com:21114', this.proServer,
      (value: string): void => { this.proServer = value; })
    this.field('用户名', 'user@example.com', this.proUser, (value: string): void => { this.proUser = value; })
    this.field('密码', '仅用于本次登录', this.proPassword,
      (value: string): void => { this.proPassword = value; }, true)
    this.error()
    Button(this.proBusy ? '登录中…' : '登录并同步').width('100%').height(42).borderRadius(10)
      .backgroundColor(this.proBusy ? this.pal().text3 : this.accentColor).fontColor(Color.White)
      .enabled(!this.proBusy).onClick((): void => { void this.loginPro(); })
  }

  build() {
    Column() {
      if (this.step === 'protocol') {
        ResourceFabPicker({ kind: 'gateway', onSelect: (option: string): void => { this.selectProtocol(option); },
          onClose: (): void => { this.close(); } })
      } else {
        Column() {
          if (this.step === 'rustdesk') { this.rustDeskForm() }
          else if (this.step === 'rustdesk-paste') {
            RustDeskRelayConfigPasteSheet({
              onCancel: (): void => { this.step = 'rustdesk'; },
              onImported: (result: RustDeskRelayImportResult): string => this.importAndSavePastedRustDesk(result)
            })
          }
          else if (this.step === 'saved') { this.savedResult() }
          else if (this.step === 'pro') { this.proForm() }
        }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 28 })
      }
    }.width('100%').constraintSize({ maxWidth: 760 }).backgroundColor(this.pal().sheetBg)
  }
}
