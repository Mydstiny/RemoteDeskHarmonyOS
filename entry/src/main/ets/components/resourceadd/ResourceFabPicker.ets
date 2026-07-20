import { Palette, buildDark, buildLight } from '../../common/Theme';

/** Shared first-step picker matching HostProtocolPicker exactly. */
@Component
export struct ResourceFabPicker {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop kind: string = 'ssh_key';
  onSelect: (option: string) => void = (_option: string): void => {};
  onClose: () => void = (): void => {};

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private title(): string {
    if (this.kind === 'totp') { return '添加 2FA 验证器'; }
    if (this.kind === 'gateway') { return '添加中继服务器'; }
    if (this.kind === 'relay') { return '添加 RustDesk 中继'; }
    return '添加 SSH 密钥';
  }

  private subtitle(): string {
    if (this.kind === 'totp') { return '选择验证器配置方式'; }
    if (this.kind === 'gateway') { return '选择中继协议'; }
    if (this.kind === 'relay') { return '选择服务器类型'; }
    return '选择密钥添加方式';
  }

  @Builder private option(id: string, title: string, subtitle: string) {
    Row() {
      Column() {
        Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        Text(subtitle).fontSize(12).fontColor(this.pal().text3).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(18).fontColor([this.pal().text3])
    }.width('100%').height(68).padding({ left: 18, right: 18 })
      .borderRadius(16).backgroundColor(this.pal().surface).margin({ bottom: 10 })
      .onClick((): void => { this.onSelect(id); })
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text(this.title()).fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          Text(this.subtitle()).fontSize(13).fontColor(this.pal().text3).margin({ top: 4 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2]) }
          .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
          .onClick((): void => { this.onClose(); })
      }.width('100%').margin({ bottom: 18 })
      if (this.kind === 'ssh_key') {
        this.option('file', '从文件导入', '选择现有 OpenSSH 私钥文件')
        this.option('generate', '生成新密钥', '创建 ED25519 或 RSA 密钥对')
        this.option('paste', '粘贴私钥', '粘贴已有私钥文本并检查')
      } else if (this.kind === 'totp') {
        this.option('scan', '扫描二维码', '使用相机读取 TOTP 配置')
        this.option('file', '从文件导入', '支持 ATSF、TXT、JSON 和 CSV')
        this.option('uri', '导入 otpauth 配置', '粘贴 otpauth:// URI 后解析')
        this.option('manual', '手动输入', '填写发行方、账户和 Secret')
      } else if (this.kind === 'gateway') {
        this.option('rustdesk', 'RustDesk 中继', '配置 RustDesk ID、Relay 与 Server Pro')
        this.option('vnc', 'VNC 中继', '配置 UltraVNC Repeater 服务器')
      } else {
        this.option('oss', 'RustDesk OSS', '自建开源 ID 与 Relay 服务')
        this.option('pro', 'RustDesk Server Pro', 'API 登录与地址簿设备同步')
        this.option('advanced', '高级自定义', '配置完整服务器地址与端口')
      }
    }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 18 })
      .backgroundColor(this.pal().sheetBg)
  }
}
