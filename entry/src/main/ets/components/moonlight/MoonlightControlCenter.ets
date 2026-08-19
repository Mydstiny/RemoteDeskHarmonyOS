import { AppTheme, Palette, buildDark, buildLight } from '../../common/Theme';
import {
  MoonlightControlCenterLayout,
  moonlightControlCenterLayout
} from '../../services/MoonlightUiPolicy';

export type MoonlightControlMode = 'touch' | 'trackpad' | 'absoluteMouse' | 'relativeMouse';

@Component
export struct MoonlightControlCenter {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @StorageProp('isPadDevice') isPadDevice: boolean = false;
  @Prop hostName: string = '';
  @Prop appName: string = '';
  @Prop durationLabel: string = '00:00';
  @Prop negotiatedSummary: string = '等待协商';
  @Prop controlMode: MoonlightControlMode = 'touch';
  @Prop audioAvailable: boolean = false;
  @Prop sessionChangeCount: number = 0;
  @Prop pipAvailable: boolean = false;
  @Prop controllerAvailable: boolean = false;
  @Prop physicalControllerPathReady: boolean = false;
  @Prop keyboardAvailable: boolean = false;
  @Prop diagnosticsVisible: boolean = false;
  onClose: () => void = (): void => {};
  onOpenKeyboard: () => void = (): void => {};
  onOpenModifiers: () => void = (): void => {};
  onOpenController: () => void = (): void => {};
  onControlMode: (mode: MoonlightControlMode) => void = (_mode: MoonlightControlMode): void => {};
  onEnterPip: () => void = (): void => {};
  onToggleDiagnostics: () => void = (): void => {};
  onDisconnect: () => void = (): void => {};

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private layout(): MoonlightControlCenterLayout {
    return moonlightControlCenterLayout(this.isDesktopDevice, this.breakpoint, this.isPadDevice);
  }

  @Builder private sectionTitle(title: string, subtitle: string = '') {
    Row() {
      Text(title).fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        .fontFamily(AppTheme.fontFamily)
      if (subtitle !== '') {
        Text(subtitle).fontSize(10).fontColor(this.accentColor).margin({ left: 8 })
      }
    }.width('100%').margin({ top: this.layout().sectionGap, bottom: 8 })
  }

  @Builder private actionRow(icon: Resource, title: string, detail: string,
    action: () => void, enabled: boolean = true, dangerous: boolean = false) {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(icon).fontSize(19)
          .fontColor([dangerous ? this.pal().danger : (enabled ? this.pal().text : this.pal().text3)])
      }.width(38).height(38).borderRadius(11).backgroundColor(this.pal().surface)
      Column() {
        Text(title).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(dangerous ? this.pal().danger : (enabled ? this.pal().text : this.pal().text3))
          .fontFamily(AppTheme.fontFamily)
        Text(detail).fontSize(10).fontColor(this.pal().text3).fontFamily(AppTheme.fontFamily)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(15).fontColor([this.pal().text3])
    }.width('100%').height(this.layout().rowHeight)
      .padding({ left: 10, right: 12, top: 6, bottom: 6 })
      .opacity(enabled ? 1 : 0.62).onClick((): void => { if (enabled) { action(); } })
  }

  @Builder private choice(label: string, selected: boolean, action: () => void,
    enabled: boolean = true) {
    Button(label).height(36).fontSize(11).borderRadius(10)
      .backgroundColor(selected ? this.accentColor : this.pal().surface)
      .fontColor(selected ? Color.White : (enabled ? this.pal().text2 : this.pal().text3))
      .enabled(enabled).opacity(enabled ? 1 : 0.58).onClick(action)
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text(this.appName || 'Moonlight 会话').fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
          Text((this.hostName || '未知主机') + ' · ' + this.durationLabel + ' · ' + this.negotiatedSummary)
            .fontSize(11).fontColor(this.pal().text3).fontFamily(AppTheme.fontFamily)
            .maxLines(2).margin({ top: 4 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        if (this.sessionChangeCount > 0) {
          Text('仅本次 ' + this.sessionChangeCount.toString()).fontSize(10).fontColor(this.accentColor)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor(this.accentColor + '18').borderRadius(10).margin({ right: 8 })
        }
        Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(16).fontColor([this.pal().text2]) }
          .width(40).height(40).borderRadius(20).backgroundColor(this.pal().surface)
          .onClick((): void => { this.onClose(); })
      }.width('100%')

      Scroll() {
        Column() {
          this.sectionTitle('会话')
          Column() {
            this.actionRow($r('sys.symbol.rectangle_on_rectangle'), '画中画',
              this.pipAvailable ? '保持串流并进入系统 PIP' : '当前窗口或系统能力不支持',
              (): void => { this.onEnterPip(); }, this.pipAvailable)
          }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
            .border({ width: 0.5, color: this.pal().cardBorder })

          this.sectionTitle('控制', '仅本次')
          Row({ space: 7 }) {
            this.choice('触控', this.controlMode === 'touch', (): void => { this.onControlMode('touch'); })
            this.choice('触控板', this.controlMode === 'trackpad', (): void => { this.onControlMode('trackpad'); })
          }.width('100%')
          Column() {
            this.actionRow($r('sys.symbol.keyboard'), '虚拟键盘',
              this.keyboardAvailable ? '系统输入法、功能键与修饰键' : '输入通道尚未就绪',
              (): void => { this.onOpenKeyboard(); }, this.keyboardAvailable)
            Divider().color(this.pal().divider).margin({ left: 58 })
            this.actionRow($r('sys.symbol.keyboard'), '修饰键与快捷键', '直接复用会话通用状态机',
              (): void => { this.onOpenModifiers(); })
            Divider().color(this.pal().divider).margin({ left: 58 })
            this.actionRow($r('sys.symbol.gamecontroller_fill'), '控制器',
              this.controllerAvailable ?
                (this.physicalControllerPathReady ? '虚拟控制器与实体手柄监听均已就绪' :
                  '虚拟控制器可用；当前设备实体手柄监听不可用') :
                '控制器输入通道尚未就绪',
              (): void => { this.onOpenController(); }, this.controllerAvailable)
          }.width('100%').backgroundColor(this.pal().card).borderRadius(16).margin({ top: 8 })
            .border({ width: 0.5, color: this.pal().cardBorder })

          this.sectionTitle('音频', '仅本次')
          Row() {
            Text(this.audioAvailable ? '音量请使用系统媒体音量调节' : '当前会话未启用音频')
              .fontSize(10).fontColor(this.pal().text3)
              .layoutWeight(1)
          }.width('100%').height(48)

          this.sectionTitle('诊断', '仅本次')
          Column() {
            this.actionRow($r('sys.symbol.info_circle'), '性能悬浮窗',
              this.diagnosticsVisible ? '已显示，可拖动、展开或复制脱敏数据' :
                '显示实测帧率、码率与输入丢弃计数',
              (): void => { this.onToggleDiagnostics(); })
          }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
            .border({ width: 0.5, color: this.pal().cardBorder })

          this.sectionTitle('危险操作')
          Column() {
            this.actionRow($r('sys.symbol.xmark_circle_fill'), '仅断开本地串流',
              '保留主机端应用运行；这是默认停止动作', (): void => { this.onDisconnect(); }, true, true)
          }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
            .border({ width: 0.5, color: this.pal().cardBorder })
            .margin({ bottom: 22 })
        }.width('100%')
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off).margin({ top: 6 })
    }
    .width(this.layout().width).height('100%')
      .padding({ left: this.layout().horizontalPadding, right: this.layout().horizontalPadding, top: 20 })
    .backgroundColor(this.pal().sheetBg)
  }
}
