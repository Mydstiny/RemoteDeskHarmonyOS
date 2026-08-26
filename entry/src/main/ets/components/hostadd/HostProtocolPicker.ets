/** Protocol entry for the modern add-host wizard. */
import { AppTheme, Palette, buildDark, buildLight } from '../../common/Theme';
import {
  ProtocolIconKey,
  protocolIcon,
  protocolIconDescriptor
} from '../../services/ProtocolIconPolicy';
import {
  dispatchSelectedHostProtocol,
  HostProtocolPickerOptionState,
  resolveHostProtocolPickerIconTint,
  resolveHostProtocolPickerOption,
  resolveMoonlightPickerIconMode
} from '../../services/HostProtocolPickerPolicy';

@Component
export struct HostProtocolPicker {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  // The add-shell entry and the runtime protocol capability are separate
  // gates. The entry can be reviewed before pairing/streaming is released.
  @Prop moonlightFabEntryAvailable: boolean = false;
  @Prop moonlightProtocolAvailable: boolean = false;
  onSelect: (protocol: string) => void = (_protocol: string): void => {};
  onClose: () => void = (): void => {};
  @State moonlightIconFailed: boolean = false;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  @Builder private protocolOption(protocol: string, title: string, subtitle: string,
    enabled: boolean, runtimeAvailable: boolean, entryAvailable: boolean) {
    Row() {
      if (protocol === 'moonlight' &&
        resolveMoonlightPickerIconMode(this.moonlightIconFailed) === 'brand') {
        Image(protocolIconDescriptor('moonlight').resource)
          .width(24).height(24)
          .fillColor(resolveHostProtocolPickerIconTint(
            enabled, this.accentColor, this.pal().text3))
          .margin({ right: 14 })
          .onError((): void => { this.moonlightIconFailed = true; })
      } else {
        SymbolGlyph(protocol === 'moonlight' ?
          protocolIconDescriptor('moonlight').fallback :
          protocolIcon(protocol as ProtocolIconKey)).fontSize(24)
          .fontColor([resolveHostProtocolPickerIconTint(
            enabled, this.accentColor, this.pal().text3)]).margin({ right: 14 })
      }
      Column() {
        Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        Text(subtitle).fontSize(12).fontColor(this.pal().text3).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (enabled) {
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(18).fontColor([this.pal().text3])
      } else {
        Text(resolveHostProtocolPickerOption(protocol, runtimeAvailable, entryAvailable).statusLabel)
          .fontSize(11).fontColor(this.pal().text3)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 }).borderRadius(8)
          .backgroundColor(this.pal().surface)
      }
    }.width('100%').height(68).padding({ left: 18, right: 18 })
    .borderRadius(16).backgroundColor(this.pal().surface).margin({ bottom: 10 })
    .opacity(resolveHostProtocolPickerOption(protocol, runtimeAvailable, entryAvailable).opacity)
    .onClick((): void => {
      const state: HostProtocolPickerOptionState =
        resolveHostProtocolPickerOption(protocol, runtimeAvailable, entryAvailable);
      dispatchSelectedHostProtocol(state, this.onSelect);
    })
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
      this.protocolOption('rdp', 'RDP', '连接 Windows 远程桌面', true, true, false)
      this.protocolOption('rustdesk', 'RustDesk', '中继、直连与局域网发现', true, true, false)
      this.protocolOption('ssh', 'SSH', '密码或密钥登录服务器', true, true, false)
      this.protocolOption('vnc', 'VNC', '跨平台屏幕控制、直连与 UltraVNC Repeater', true, true, false)
      this.protocolOption('moonlight', 'Moonlight', '低延迟游戏与桌面串流',
        this.moonlightProtocolAvailable || this.moonlightFabEntryAvailable,
        this.moonlightProtocolAvailable, this.moonlightFabEntryAvailable)
      Row() {
        SymbolGlyph($r('sys.symbol.info_circle')).fontSize(16)
          .fontColor([this.accentColor]).margin({ top: 1 })
        Text('连接前需先在目标设备启用对应服务；完整准备步骤见“设置 → 教程 → 连接前准备”。')
          .fontSize(11).fontColor(this.pal().text3).lineHeight(17)
          .layoutWeight(1).margin({ left: 8 })
      }
      .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 2 })
    }.width('100%').padding({ left: 20, right: 20, top: 20, bottom: 18 })
    .backgroundColor(this.pal().card)
  }
}
