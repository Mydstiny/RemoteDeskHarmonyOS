import { AppTheme, Palette, buildDark, buildLight } from '../../common/Theme';

@Component
export struct MoonlightPhysicalControllerSheet {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @Prop inputReady: boolean = false;
  @Prop controllerReady: boolean = false;
  @Prop physicalListenerReady: boolean = false;
  @Prop rumbleEnabled: boolean = false;
  onRefresh: () => void = (): void => {};
  onOpenVirtualController: () => void = (): void => {};
  onClose: () => void = (): void => {};

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private sessionPrimary(): string { return '#5B8FF9'; }

  // Readiness is an ordinary session state, not a success celebration. Keep
  // it in Moonlight's blue family so the sheet does not inherit the global
  // yellow-green success chips used elsewhere in the app.
  private readyColor(): string { return this.sessionPrimary(); }

  @Builder private statusRow(icon: Resource, title: string, detail: string,
    ready: boolean) {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(icon).fontSize(19)
          .fontColor([ready ? this.readyColor() : this.pal().text3])
      }.width(40).height(40).borderRadius(12)
        .backgroundColor(ready ? this.readyColor() + '18' : this.pal().surface)
      Column() {
        Text(title).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
        Text(detail).fontSize(10).fontColor(this.pal().text3)
          .fontFamily(AppTheme.fontFamily).lineHeight(15).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 11 })
      Text(ready ? '就绪' : '不可用').fontSize(10)
        .fontColor(ready ? this.readyColor() : this.pal().text3)
        .padding({ left: 9, right: 9, top: 4, bottom: 4 })
        .backgroundColor(ready ? this.readyColor() + '16' : this.pal().surface)
        .borderRadius(10)
    }.width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 })
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text('实体手柄管理').fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
          Text('Moonlight 会话 · Sunshine 槽位 1')
            .fontSize(11).fontColor(this.pal().text3).margin({ top: 4 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button() {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(16).fontColor([this.pal().text2])
        }.width(40).height(40).borderRadius(20).backgroundColor(this.pal().surface)
          .onClick((): void => { this.onClose(); })
          .accessibilityText('关闭实体手柄管理')
      }.width('100%')

      Column() {
        this.statusRow($r('sys.symbol.gamecontroller_fill'), '系统实体手柄监听',
          this.physicalListenerReady ?
            'GameControllerKit 已监听；连接手柄后会自动接管槽位 1' :
            '当前系统未建立实体手柄监听，可重新检测或使用虚拟手柄',
          this.physicalListenerReady)
        Divider().color(this.pal().divider).margin({ left: 62 })
        this.statusRow($r('sys.symbol.gamecontroller_fill'), '串流控制器通道',
          this.controllerReady ? 'Sunshine 控制器输入通道已协商完成' :
            (this.inputReady ? '正在等待控制器通道就绪' : '串流输入通道尚未就绪'),
          this.controllerReady)
        Divider().color(this.pal().divider).margin({ left: 62 })
        this.statusRow($r('sys.symbol.info_circle'), '震动反馈',
          this.rumbleEnabled ? '已按当前会话设置请求；实际能力以手柄与系统为准' :
            '当前会话未启用震动反馈', this.rumbleEnabled)
      }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
        .border({ width: 0.5, color: this.pal().cardBorder }).margin({ top: 18 })

      Text('实体手柄由系统自动发现并使用标准映射；插拔后点击“重新检测”即可刷新当前监听状态。')
        .fontSize(11).fontColor(this.pal().text3).lineHeight(17)
        .width('100%').margin({ top: 14 })

      Row({ space: 10 }) {
        Button('重新检测').height(44).layoutWeight(1).borderRadius(12)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text)
          .onClick((): void => { this.onRefresh(); })
        Button('打开虚拟手柄（备用）').height(44).layoutWeight(1).borderRadius(12)
          .backgroundColor(this.sessionPrimary()).fontColor(Color.White)
          .enabled(this.controllerReady).opacity(this.controllerReady ? 1 : 0.55)
          .onClick((): void => { this.onOpenVirtualController(); })
      }.width('100%').margin({ top: 18 })
    }
    .width('100%').padding({ left: 22, right: 22, top: 22, bottom: 22 })
    .backgroundColor(this.pal().sheetBg)
  }
}
