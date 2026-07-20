/** Four-protocol entry for the modern add-host wizard. */
import { AppTheme, Palette, buildDark, buildLight } from '../../common/Theme';

@Component
export struct HostProtocolPicker {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  onSelect: (protocol: string) => void = (_protocol: string): void => {};
  onClose: () => void = (): void => {};

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  @Builder private protocolOption(protocol: string, title: string, subtitle: string, enabled: boolean) {
    Row() {
      Column() {
        Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        Text(subtitle).fontSize(12).fontColor(this.pal().text3).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (enabled) {
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(18).fontColor([this.pal().text3])
      } else {
        Text('即将支持').fontSize(11).fontColor(this.pal().text3)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 }).borderRadius(8)
          .backgroundColor(this.pal().surface)
      }
    }.width('100%').height(68).padding({ left: 18, right: 18 })
    .borderRadius(16).backgroundColor(this.pal().surface).margin({ bottom: 10 })
    .opacity(enabled ? 1 : 0.58)
    .onClick((): void => { if (enabled) { this.onSelect(protocol); } })
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text('添加远程主机').fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          Text('选择要连接的协议').fontSize(13).fontColor(this.pal().text3).margin({ top: 4 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2]) }
          .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
          .onClick((): void => { this.onClose(); })
      }.width('100%').margin({ bottom: 18 })
      this.protocolOption('rdp', 'RDP', '连接 Windows 远程桌面', true)
      this.protocolOption('rustdesk', 'RustDesk', '中继、直连与局域网发现', true)
      this.protocolOption('ssh', 'SSH', '密码或密钥登录服务器', true)
      this.protocolOption('vnc', 'VNC', '跨平台屏幕控制', false)
    }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 18 })
    .backgroundColor(this.pal().card)
  }
}
