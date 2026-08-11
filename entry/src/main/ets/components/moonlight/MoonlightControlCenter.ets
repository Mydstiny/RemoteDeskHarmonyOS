import { AppTheme, Palette, buildDark, buildLight } from '../../common/Theme';

export type MoonlightControlMode = 'touch' | 'trackpad' | 'absoluteMouse' | 'relativeMouse';

@Component
export struct MoonlightControlCenter {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @Prop hostName: string = '';
  @Prop appName: string = '';
  @Prop durationLabel: string = '00:00';
  @Prop negotiatedSummary: string = '等待协商';
  @Prop controlMode: MoonlightControlMode = 'touch';
  @Prop muted: boolean = false;
  @Prop volume: number = 100;
  @Prop scaleMode: string = 'fit';
  @Prop latencyMode: string = 'lowLatency';
  @Prop diagnosticsEnabled: boolean = false;
  @Prop sessionChangeCount: number = 0;
  @Prop pipAvailable: boolean = false;
  @Prop controllerAvailable: boolean = false;
  onClose: () => void = (): void => {};
  onOpenKeyboard: () => void = (): void => {};
  onOpenModifiers: () => void = (): void => {};
  onOpenShortcuts: () => void = (): void => {};
  onOpenController: () => void = (): void => {};
  onControlMode: (mode: MoonlightControlMode) => void = (_mode: MoonlightControlMode): void => {};
  onToggleMute: () => void = (): void => {};
  onVolume: (value: number) => void = (_value: number): void => {};
  onScaleMode: (mode: string) => void = (_mode: string): void => {};
  onLatencyMode: (mode: string) => void = (_mode: string): void => {};
  onToggleDiagnostics: () => void = (): void => {};
  onReconnect: () => void = (): void => {};
  onEnterPip: () => void = (): void => {};
  onDisconnect: () => void = (): void => {};
  onQuitHostApp: () => void = (): void => {};
  onSaveProfile: () => void = (): void => {};

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  @Builder private sectionTitle(title: string, subtitle: string = '') {
    Row() {
      Text(title).fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        .fontFamily(AppTheme.fontFamily)
      if (subtitle !== '') {
        Text(subtitle).fontSize(10).fontColor(this.accentColor).margin({ left: 8 })
      }
    }.width('100%').margin({ top: 16, bottom: 8 })
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
    }.width('100%').height(68).padding({ left: 10, right: 12, top: 6, bottom: 6 })
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
            Divider().color(this.pal().divider).margin({ left: 58 })
            this.actionRow($r('sys.symbol.arrow_clockwise'), '立即重连',
              '冻结输入，停止旧 generation 后重新协商', (): void => { this.onReconnect(); })
          }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
            .border({ width: 0.5, color: this.pal().cardBorder })

          this.sectionTitle('控制', '仅本次')
          Row({ space: 7 }) {
            this.choice('触控', this.controlMode === 'touch', (): void => { this.onControlMode('touch'); })
            this.choice('触控板', this.controlMode === 'trackpad', (): void => { this.onControlMode('trackpad'); })
            this.choice('绝对鼠标', this.controlMode === 'absoluteMouse',
              (): void => { this.onControlMode('absoluteMouse'); })
            this.choice('相对鼠标', this.controlMode === 'relativeMouse',
              (): void => { this.onControlMode('relativeMouse'); })
          }.width('100%')
          Column() {
            this.actionRow($r('sys.symbol.keyboard'), '虚拟键盘', 'Esc、Tab、修饰键、方向与文本输入',
              (): void => { this.onOpenKeyboard(); })
            Divider().color(this.pal().divider).margin({ left: 58 })
            this.actionRow($r('sys.symbol.keyboard'), '修饰键与快捷键', '直接复用会话通用状态机',
              (): void => { this.onOpenModifiers(); })
            Divider().color(this.pal().divider).margin({ left: 58 })
            this.actionRow($r('sys.symbol.gamecontroller_fill'), '控制器',
              this.controllerAvailable ? '虚拟与实体手柄状态' : 'native listener 真机验收前保持关闭',
              (): void => { this.onOpenController(); }, this.controllerAvailable)
          }.width('100%').backgroundColor(this.pal().card).borderRadius(16).margin({ top: 8 })
            .border({ width: 0.5, color: this.pal().cardBorder })

          this.sectionTitle('画面', '仅本次')
          Row({ space: 8 }) {
            this.choice('适应', this.scaleMode === 'fit', (): void => { this.onScaleMode('fit'); })
            this.choice('填充', this.scaleMode === 'fill', (): void => { this.onScaleMode('fill'); })
            this.choice('1:1', this.scaleMode === 'oneToOne', (): void => { this.onScaleMode('oneToOne'); })
            Blank().layoutWeight(1)
            this.choice('低延迟', this.latencyMode === 'lowLatency',
              (): void => { this.onLatencyMode('lowLatency'); })
            this.choice('平滑', this.latencyMode === 'smooth',
              (): void => { this.onLatencyMode('smooth'); })
          }.width('100%')
          Text('编码、分辨率与帧率变更需要重新连接，将写入“下次连接”草稿。')
            .fontSize(10).fontColor(this.pal().text3).width('100%').margin({ top: 7 })

          this.sectionTitle('音频', '仅本次')
          Row() {
            Button(this.muted ? '恢复声音' : '静音').height(38).fontSize(12).borderRadius(10)
              .backgroundColor(this.muted ? this.accentColor : this.pal().surface)
              .fontColor(this.muted ? Color.White : this.pal().text)
              .onClick((): void => { this.onToggleMute(); })
            Slider({ value: this.volume, min: 0, max: 100, step: 1 })
              .layoutWeight(1).selectedColor(this.accentColor).trackColor(this.pal().surface)
              .margin({ left: 12, right: 10 }).onChange((value: number, mode: SliderChangeMode): void => {
                if (mode === SliderChangeMode.End) { this.onVolume(Math.round(value)); }
              })
            Text(this.volume.toString() + '%').fontSize(11).fontColor(this.pal().text2).width(42)
          }.width('100%').height(48)

          this.sectionTitle('网络与诊断')
          Column() {
            this.actionRow($r('sys.symbol.info_circle'), '性能 HUD',
              this.diagnosticsEnabled ? '简洁/详细诊断已打开' : '默认关闭，按需采样',
              (): void => { this.onToggleDiagnostics(); })
            Divider().color(this.pal().divider).margin({ left: 58 })
            this.actionRow($r('sys.symbol.text_clipboard'), '复制脱敏诊断',
              '不包含地址、PIN、证书指纹和会话密钥', (): void => { this.onOpenShortcuts(); })
          }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
            .border({ width: 0.5, color: this.pal().cardBorder })

          if (this.sessionChangeCount > 0) {
            Button('保存为此应用默认').height(44).width('100%').fontSize(13).borderRadius(12)
              .backgroundColor(this.accentColor).fontColor(Color.White).margin({ top: 18 })
              .onClick((): void => { this.onSaveProfile(); })
          }

          this.sectionTitle('危险操作')
          Column() {
            this.actionRow($r('sys.symbol.xmark_circle_fill'), '仅断开本地串流',
              '保留主机端应用运行；这是默认停止动作', (): void => { this.onDisconnect(); }, true, true)
            Divider().color(this.pal().divider).margin({ left: 58 })
            this.actionRow($r('sys.symbol.power'), '同时退出主机应用',
              '主机响应失败或未知也不会阻塞本地清理', (): void => { this.onQuitHostApp(); }, true, true)
          }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
            .border({ width: 0.5, color: this.pal().cardBorder })
            .margin({ bottom: 22 })
        }.width('100%')
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off).margin({ top: 6 })
    }
    .width('100%').height('100%').padding({ left: 20, right: 20, top: 20 })
    .backgroundColor(this.pal().sheetBg)
  }
}
