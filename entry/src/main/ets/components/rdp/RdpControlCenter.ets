import { AppTheme, Palette, buildDark } from '../../common/Theme';
import { ProContinuationControls } from '../ProContinuationControls';
import { ProBadge } from '../ProBadge';
import { RdpDisplayProfilePanel } from './RdpDisplayProfilePanel';
import { rdpDisplayProfileSummary, rdpResolutionSelection } from '../../services/RemoteDisplayProfilePolicy';
import { RdpRenderStats } from '../../types/rdpnapi';
import { EMPTY_RDP_RENDER_STATS } from '../RdpDiagnosticsHud';
import {
  normalizeRemoteWheelSpeed,
  remoteWheelSessionSpeedChoices,
  remoteWheelSpeedLabel
} from '../../services/RemoteWheelPreferencePolicy';
import {
  rdpResolutionAspectAssessment,
  rdpResolutionLabel,
  rdpResolutionPresetsForSurface,
  RdpResolutionAspectAssessment,
  RemoteResolutionPreset
} from '../../services/RemoteResolutionPresetPolicy';
import {
  RDP_SESSION_CONTROL_ACCENT,
  RDP_SESSION_CONTROL_ACCENT_SOFT,
  RDP_SESSION_NEUTRAL_ACCENT,
  RDP_SESSION_NEUTRAL_ACCENT_SOFT,
  RdpSessionPerformanceSummary,
  rdpSessionPerformanceSummary
} from '../../services/RdpSessionSidebarPolicy';

function durationUs(value: number): string {
  if (!Number.isFinite(value) || value <= 0) { return '—'; }
  return value >= 1000 ? (value / 1000).toFixed(1) + ' ms' : Math.round(value).toString() + ' μs';
}

@Component
export struct RdpControlCenter {
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @Prop hostName: string = '';
  @Prop connectedLabel: string = '已连接';
  @Prop stats: RdpRenderStats = EMPTY_RDP_RENDER_STATS;
  @Prop controlMode: number = 0;
  @Prop clipboardEnabled: boolean = true;
  @Prop clipboardReady: boolean = false;
  @Prop diagnosticsEnabled: boolean = false;
  @Prop displayScaleMode: string = 'fit';
  @Prop canvasZoomEnabled: boolean = false;
  @Prop canvasResetAvailable: boolean = false;
  /**
   * Parent-owned repaint fence for selection controls. The control center is
   * retained while its sheet stays open; a monotonic fence prevents ArkUI
   * from keeping a stale choice visual after a live setting changes.
   */
  @Prop selectionRevision: number = 0;
  @Prop reverseWheel: boolean = false;
  /** 设置 › 远程滚轮's RDP speed (percent): changed here it is saved there too and applies at once. */
  @Prop wheelSpeed: number = 100;
  @Prop resolutionId: string = 'auto';
  @Prop customWidth: number = 1920;
  @Prop customHeight: number = 1080;
  /** RDP 高级显示方案 is visible to this account (ProEntries.visible); otherwise the free chips are shown. */
  @Prop advancedDisplayVisible: boolean = false;
  @Prop surfaceWidthPx: number = 0;
  @Prop surfaceHeightPx: number = 0;
  @Prop remoteUiScale: string = 'auto';
  /** PC 自适应 renegotiates with every window size (off: the whole screen's size, scaled into the window). */
  @Prop followWindow: boolean = false;
  /** Pro 多显示器: the saved choice (0, 2–4), the running session's monitor count (1: single) and the local view. */
  @Prop multimonCount: number = 0;
  @Prop multimonActiveCount: number = 1;
  @Prop monitorFocus: number = -1;
  onMultimonCount: (count: number) => void = (_count: number): void => {};
  onMonitorFocus: (index: number) => void = (_index: number): void => {};
  @Prop desktopScaleMode: string = 'auto';
  @Prop desktopScalePercent: number = 100;
  @Prop colorDepth: number = 32;
  @Prop audioEnabled: boolean = true;
  @Prop driveEnabled: boolean = true;
  @Prop @Watch('onDriveNameChange') driveName: string = 'RemoteDesktop';
  @Prop authIdentityMode: number = 1;
  @Prop tlsWithoutNla: boolean = false;
  /** 安全密钥重定向 is visible to this account on this device (ProEntries.visible); hidden otherwise. */
  @Prop securityKeyVisible: boolean = false;
  @Prop securityKeyEnabled: boolean = false;
  @State private driveNameDraft: string = 'RemoteDesktop';
  @State private displayProfileShown: boolean = false;
  onClose: () => void = (): void => {};
  onOpenKeyboard: () => void = (): void => {};
  onOpenShortcuts: () => void = (): void => {};
  onCtrlAltDel: () => void = (): void => {};
  onRefresh: () => void = (): void => {};
  onPrepareContinuation: () => void = (): void => {};
  onControlMode: (mode: number) => void = (_mode: number): void => {};
  onClipboard: (enabled: boolean) => void = (_enabled: boolean): void => {};
  onDiagnostics: (enabled: boolean) => void = (_enabled: boolean): void => {};
  onDisplayScale: (mode: string) => void = (_mode: string): void => {};
  onCanvasZoom: (enabled: boolean) => void = (_enabled: boolean): void => {};
  onResetCanvas: () => void = (): void => {};
  onReverseWheel: (enabled: boolean) => void = (_enabled: boolean): void => {};
  onWheelSpeed: (speed: number) => void = (_speed: number): void => {};
  onResolution: (id: string) => void = (_id: string): void => {};
  onCustomResolution: (width: string, height: string) => void = (_width: string, _height: string): void => {};
  onRemoteUiScale: (value: string) => void = (_value: string): void => {};
  onFollowWindow: (on: boolean) => void = (_on: boolean): void => {};
  onDesktopScalePercent: (value: string) => void = (_value: string): void => {};
  onColorDepth: (depth: number) => void = (_depth: number): void => {};
  onAudio: (enabled: boolean) => void = (_enabled: boolean): void => {};
  onDrive: (enabled: boolean) => void = (_enabled: boolean): void => {};
  onDriveName: (name: string) => void = (_name: string): void => {};
  onAuthIdentityMode: (mode: number) => void = (_mode: number): void => {};
  onTlsWithoutNla: (enabled: boolean) => void = (_enabled: boolean): void => {};
  onSecurityKey: (enabled: boolean) => void = (_enabled: boolean): void => {};
  onDisconnect: () => void = (): void => {};

  private pal(): Palette { return buildDark(this.accentColor); }

  private panelWidth(): number {
    if (this.breakpoint === 'sm') { return 268; }
    if (this.isDesktopDevice) { return 420; }
    return 370;
  }

  private perf(): RdpSessionPerformanceSummary {
    return rdpSessionPerformanceSummary(this.stats.lastRenderResult,
      this.stats.lastRemoteUpdateAgeMs, this.stats.queueP95Us, this.stats.gfxChannelConnected);
  }

  private controlModeLabel(): string {
    if (this.controlMode === 1) { return '直接触控'; }
    if (this.controlMode === 2) { return '键盘鼠标'; }
    return '触控板';
  }

  private orderedResolutionPresets(): RemoteResolutionPreset[] {
    return rdpResolutionPresetsForSurface(this.surfaceWidthPx, this.surfaceHeightPx);
  }

  /** Free sessions connect a saved custom size as 自适应, so that is what the chips show. */
  private resolutionSelected(): string { return rdpResolutionSelection(this.resolutionId, this.advancedDisplayVisible); }

  private resolutionSelectionSummary(): string {
    const assessment: RdpResolutionAspectAssessment = rdpResolutionAspectAssessment(
      this.resolutionSelected(), this.surfaceWidthPx, this.surfaceHeightPx, this.customWidth, this.customHeight);
    if (assessment.followsWindow) {
      return this.isDesktopDevice ? (this.followWindow ? '跟随当前窗口，自动协商，完整适应时不产生比例黑边' :
        '按整块屏幕的分辨率，窗口里按比例完整显示') :
        '下次连接时适应设备画面；手机与平板不进行窗口实时重协商';
    }
    if (assessment.avoidsRatioBars) {
      return this.resolutionName() + ' · 与当前窗口比例匹配';
    }
    if (this.displayScaleMode === 'fill') {
      return this.resolutionName() + ' · 已填满窗口并居中裁边，可拖动查看';
    }
    return this.resolutionName() + ' · 与当前窗口比例相差 ' +
      assessment.aspectGapPercent.toFixed(1) + '%，可改用自适应或“填满”';
  }

  private resolutionName(): string {
    return this.resolutionSelected() === 'custom' ?
      this.customWidth.toString() + ' × ' + this.customHeight.toString() : rdpResolutionLabel(this.resolutionSelected());
  }

  @Builder private displayProfileSheet() {
    RdpDisplayProfilePanel({
      forceDark: true,
      isDesktopDevice: this.isDesktopDevice,
      applyHint: '立即向 Windows 请求；会话不支持时下次连接生效',
      onResolution: (id: string): void => { this.onResolution(id); },
      onCustomResolution: (width: string, height: string): void => { this.onCustomResolution(width, height); },
      onRemoteUiScale: (value: string): void => { this.onRemoteUiScale(value); },
      onDesktopScalePercent: (value: string): void => { this.onDesktopScalePercent(value); }
    })
  }

  /** Pro: the remote size and Windows scale live behind one entry that opens 远端显示方案. */
  @Builder private displayProfileEntry() {
    Row({ space: 8 }) {
      Column({ space: 3 }) {
        Text('远端显示方案').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        Text(rdpDisplayProfileSummary(this.resolutionId, this.customWidth, this.customHeight,
          rdpResolutionLabel(this.resolutionId), this.desktopScaleMode, this.desktopScalePercent))
          .fontSize(10).fontColor(this.pal().text3).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      ProBadge()
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([this.pal().text3])
    }
    .width('100%').padding({ left: 12, right: 10, top: 10, bottom: 10 }).borderRadius(12)
    .backgroundColor(this.pal().surface).border({ width: 0.5, color: this.pal().cardBorder })
    .accessibilityText('远端显示方案，Pro')
    .onClick((): void => { this.displayProfileShown = true; })
    .bindSheet($$this.displayProfileShown, this.displayProfileSheet(), {
      // An explicit type: without one a 2in1 PC shows the sheet as a small popup hanging from this row.
      height: SheetSize.FIT_CONTENT, preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
      dragBar: this.breakpoint === 'sm', showClose: true,
      backgroundColor: this.pal().sheetBg, maskColor: 'rgba(0,0,0,0.4)'
    })
  }

  @Builder private securityKeyEntry() {
    Divider().color(this.pal().divider).margin({ left: 12 })
    Row({ space: 8 }) {
      Column() {
        Text('安全密钥重定向').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          .fontFamily(AppTheme.fontFamily)
        Text('下次连接生效 · 远程电脑里的网站可使用本机 USB 安全密钥，每次都先确认')
          .fontSize(10).fontColor(this.pal().text3).fontFamily(AppTheme.fontFamily)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      ProBadge()
      Toggle({ type: ToggleType.Switch, isOn: this.securityKeyEnabled }).selectedColor(RDP_SESSION_CONTROL_ACCENT)
        .onChange((next: boolean): void => { this.onSecurityKey(next); })
    }.width('100%').height(64).padding({ left: 12, right: 12, top: 7, bottom: 7 })
    .accessibilityText('安全密钥重定向，Pro，下次连接生效')
  }

  private onDriveNameChange(): void { this.driveNameDraft = this.driveName; }

  aboutToAppear(): void { this.driveNameDraft = this.driveName; }

  @Builder private sectionTitle(title: string, activation: string = '') {
    Row() {
      Text(title).fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        .fontFamily(AppTheme.fontFamily)
      if (activation.length > 0) {
        Text(activation).fontSize(9).fontColor(activation === '重连后生效' ?
          RDP_SESSION_NEUTRAL_ACCENT : RDP_SESSION_CONTROL_ACCENT)
          .padding({ left: 7, right: 7, top: 3, bottom: 3 }).borderRadius(9)
          .backgroundColor(activation === '重连后生效' ?
            RDP_SESSION_NEUTRAL_ACCENT_SOFT : RDP_SESSION_CONTROL_ACCENT_SOFT)
          .margin({ left: 8 })
      }
    }.width('100%').margin({ top: 16, bottom: 8 })
  }

  @Builder private actionRow(icon: Resource, title: string, detail: string,
    action: () => void, dangerous: boolean = false) {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(icon).fontSize(18).fontColor([dangerous ? this.pal().danger : this.pal().text])
      }.width(38).height(38).borderRadius(11).backgroundColor(this.pal().surface)
      Column() {
        Text(title).fontSize(13).fontWeight(FontWeight.Medium)
          .fontColor(dangerous ? this.pal().danger : this.pal().text)
          .fontFamily(AppTheme.fontFamily)
        Text(detail).fontSize(10).fontColor(this.pal().text3).fontFamily(AppTheme.fontFamily)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([this.pal().text3])
    }.width('100%').height(60).padding({ left: 10, right: 12, top: 7, bottom: 7 })
      .onClick(action)
  }

  /** 多显示器 (实验): how many monitors to declare next time, and which one to look at now. */
  @Builder private multimonSection() {
    Divider().color(this.pal().divider)
    Text('多显示器（实验）').fontSize(11).fontColor(this.pal().text2)
      .width('100%').margin({ top: 10, bottom: 6 })
    Scroll() {
      Row({ space: 6 }) {
        this.choice('关闭', !(this.multimonCount >= 2), (): void => { this.onMultimonCount(0); })
        this.choice('2 块屏幕', this.multimonCount === 2, (): void => { this.onMultimonCount(2); })
        this.choice('3 块屏幕', this.multimonCount === 3, (): void => { this.onMultimonCount(3); })
        this.choice('4 块屏幕', this.multimonCount === 4, (): void => { this.onMultimonCount(4); })
      }
    }.width('100%').height(38).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
    Text('下次连接时向 Windows 声明多块并排的屏幕，远程程序可以拖到第二块屏；本地可以切换看哪一块。需要 Windows 专业版或服务器版，'
      + '分辨率不跟随窗口；整个桌面太大时每块屏幕降为 1920 × 1080。')
      .fontSize(9).fontColor(this.pal().text3).width('100%').margin({ top: 5, bottom: 10 })
    if (this.multimonActiveCount >= 2) {
      Text('现在看').fontSize(11).fontColor(this.pal().text2).width('100%').margin({ bottom: 6 })
      Scroll() {
        Row({ space: 6 }) {
          this.choice('全部', !(this.monitorFocus >= 0), (): void => { this.onMonitorFocus(-1); })
          ForEach(this.monitorIndexes(), (index: number): void => {
            this.choice('屏幕 ' + (index + 1).toString(), this.monitorFocus === index,
              (): void => { this.onMonitorFocus(index); })
          }, (index: number): string => index.toString())
        }
      }.width('100%').height(38).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
        .margin({ bottom: 10 })
    }
  }

  private monitorIndexes(): number[] {
    const indexes: number[] = [];
    for (let i = 0; i < this.multimonActiveCount; i++) { indexes.push(i); }
    return indexes;
  }

  @Builder private followWindowRow() {
    this.toggleRow('分辨率跟随窗口', this.followWindow ? '窗口大小一变，远端分辨率随之改变' :
      '关闭：远端用整块屏幕的分辨率，窗口缩放时按比例显示',
      this.followWindow, (on: boolean): void => { this.onFollowWindow(on); })
  }

  @Builder private toggleRow(title: string, detail: string, value: boolean,
    action: (enabled: boolean) => void) {
    Row() {
      Column() {
        Text(title).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          .fontFamily(AppTheme.fontFamily)
        Text(detail).fontSize(10).fontColor(this.pal().text3).fontFamily(AppTheme.fontFamily)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: value }).selectedColor(RDP_SESSION_CONTROL_ACCENT)
        // `value` is a builder argument and may be stale when ArkUI retains
        // this Toggle node. Forward the actual target; the state owner is the
        // single source of truth and handles any duplicate request.
        .onChange((next: boolean): void => { action(next); })
    }.width('100%').height(60).padding({ left: 12, right: 12, top: 7, bottom: 7 })
  }

  @Builder private choice(label: string, selected: boolean, action: () => void) {
    Button(selected ? '✓ ' + label : label).height(34).fontSize(10).borderRadius(9)
      .padding({ left: 8, right: 8 })
      .fontColor(selected ? Color.White : this.pal().text2)
      .backgroundColor(selected ? RDP_SESSION_CONTROL_ACCENT : this.pal().surface)
      .border({ width: selected ? 1.5 : 0.5,
        color: selected ? RDP_SESSION_CONTROL_ACCENT : this.pal().cardBorder })
      .accessibilityText(label + (selected ? '，已选择' : ''))
      .onClick(action)
  }

  /** 滚轮速度: the session's short list of speeds, the same value as 设置 › 远程滚轮 › RDP. */
  @Builder private wheelSpeedRow() {
    Column({ space: 8 }) {
      Row() {
        Text('滚轮速度').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          .fontFamily(AppTheme.fontFamily).layoutWeight(1)
        Text(remoteWheelSpeedLabel(normalizeRemoteWheelSpeed(this.wheelSpeed))).fontSize(12)
          .fontColor(this.pal().text2).fontFamily(AppTheme.fontFamily)
      }.width('100%')
      Scroll() {
        Row({ space: 6 }) {
          ForEach(remoteWheelSessionSpeedChoices('rdp'), (speed: number): void => {
            this.choice(speed.toString() + '%', normalizeRemoteWheelSpeed(this.wheelSpeed) === speed,
              (): void => { this.onWheelSpeed(speed); })
          }, (speed: number): string => speed.toString() + '|' + this.selectionRevision.toString() + '|' +
            (normalizeRemoteWheelSpeed(this.wheelSpeed) === speed ? '1' : '0'))
        }
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
      Text('鼠标滚轮、实体触控板和三指上下滑动都按这个速度滚动').fontSize(10).fontColor(this.pal().text3)
        .fontFamily(AppTheme.fontFamily).width('100%')
    }.width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 })
  }

  @Builder private metric(label: string, value: string, color: string = '') {
    Row() {
      Text(label).fontSize(10).fontColor(this.pal().text3).layoutWeight(1)
      Text(value).fontSize(10).fontColor(color.length > 0 ? color : this.pal().text)
        .fontFamily('monospace').maxLines(1)
    }.width('100%').height(22)
  }

  @Builder private quickActions() {
    Column() {
      this.actionRow($r('sys.symbol.keyboard'), '虚拟键盘', '输入文字并发送功能键', this.onOpenKeyboard)
      Divider().color(this.pal().divider).margin({ left: 58 })
      this.actionRow($r('sys.symbol.keyboard'), '组合键与功能键', 'Windows / macOS 目录及自定义组合',
        this.onOpenShortcuts)
      Divider().color(this.pal().divider).margin({ left: 58 })
      this.actionRow($r('sys.symbol.exclamationmark_triangle'), 'Ctrl + Alt + Del',
        '向远端 Windows 请求安全序列', this.onCtrlAltDel)
      Divider().color(this.pal().divider).margin({ left: 58 })
      this.actionRow($r('sys.symbol.bolt_fill'), '刷新远端画面', '请求一次完整重绘', this.onRefresh)
    }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
      .border({ width: 0.5, color: this.pal().cardBorder })
  }

  @Builder private performanceCard() {
    Column() {
        Row() {
          Column().width(8).height(8).borderRadius(4).backgroundColor(this.perf().color)
          Text(this.perf().status).fontSize(12).fontWeight(FontWeight.Bold)
            .fontColor(this.perf().color).margin({ left: 7 })
          Blank()
          Text(this.perf().transport).fontSize(10).fontColor(RDP_SESSION_CONTROL_ACCENT)
        }.width('100%').margin({ bottom: 6 })
        this.metric('远端更新年龄', this.perf().frameAge)
        this.metric('送显队列 P95', this.perf().queueP95)
        this.metric('上传 / 绘制 / Swap', durationUs(this.stats.uploadP95Us) + ' / ' +
          durationUs(this.stats.drawP95Us) + ' / ' + durationUs(this.stats.swapP95Us))
        this.metric('桌面尺寸', this.stats.desktopWidth.toString() + ' × ' + this.stats.desktopHeight.toString())
        this.metric('动态布局', this.stats.displayControlDisabled ? '本次已降级' :
          (this.stats.displayControlReady ? '可用 · ' + this.stats.displayLastResult : '未协商'),
          this.stats.displayControlDisabled ? this.pal().danger : '')
        this.metric('远端 UI 比例', this.stats.displayScaleFactor.toString() + '%')
        this.metric('送显 / 替换 / 拒绝', this.stats.pumpRendered.toString() + ' / ' +
          this.stats.pumpReplaced.toString() + ' / ' + this.stats.pumpRejected.toString())
        this.metric('输入队列 / 峰值', this.stats.inputQueueDepth.toString() + ' / ' +
          this.stats.inputQueueMax.toString())
        this.metric('输入失败 / 网络失败', this.stats.inputPostFailures.toString() + ' / ' +
          this.stats.networkCheckFailures.toString(),
          this.stats.inputPostFailures + this.stats.networkCheckFailures > 0 ? this.pal().danger : '')
    }.width('100%').padding(12).backgroundColor(this.pal().card).borderRadius(16)
      .border({ width: 0.5, color: this.pal().cardBorder })
  }

  @Builder private liveControlCard() {
    Column() {
        Row({ space: 6 }) {
          this.choice('触控板', this.controlMode === 0, (): void => { this.onControlMode(0); })
          this.choice('直接触控', this.controlMode === 1, (): void => { this.onControlMode(1); })
          this.choice('键鼠', this.controlMode === 2, (): void => { this.onControlMode(2); })
        }.width('100%').padding(10)
        Divider().color(this.pal().divider)
        Row({ space: 6 }) {
          this.choice('完整', this.displayScaleMode === 'fit', (): void => { this.onDisplayScale('fit'); })
          this.choice('填满', this.displayScaleMode === 'fill', (): void => { this.onDisplayScale('fill'); })
          this.choice('1:1', this.displayScaleMode === '100', (): void => { this.onDisplayScale('100'); })
          this.choice('125%', this.displayScaleMode === '125', (): void => { this.onDisplayScale('125'); })
        }.width('100%').padding({ left: 10, right: 10, top: 10, bottom: 4 })
        Text(this.displayScaleMode === 'fill' ?
          '填满窗口不拉伸画面；比例不同时会居中裁边，可拖动画面查看' :
          (this.displayScaleMode === 'fit' ? '完整显示远端桌面；自适应分辨率可同时避免比例黑边' :
            '1:1 与百分比只改变本地画布，不会伪装成远端分辨率'))
          .fontSize(9).fontColor(this.pal().text3).width('100%')
          .padding({ left: 12, right: 12, bottom: 8 })
        Divider().color(this.pal().divider)
        this.toggleRow('手势缩放与平移', '双指缩放并移动画面；开启后滚动改用三指上下滑动',
          this.canvasZoomEnabled, this.onCanvasZoom)
        Divider().color(this.pal().divider).margin({ left: 12 })
        this.actionRow($r('sys.symbol.display'), '复位画面',
          this.canvasResetAvailable ? '恢复当前显示模式的基线缩放与居中位置' : '画面已处于当前显示模式的基线位置',
          this.onResetCanvas)
        Divider().color(this.pal().divider).margin({ left: 12 })
        this.toggleRow('反转滚轮方向', '立即同步到当前 RDP 会话输入', this.reverseWheel, this.onReverseWheel)
        Divider().color(this.pal().divider).margin({ left: 12 })
        this.wheelSpeedRow()
    }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
      .border({ width: 0.5, color: this.pal().cardBorder })
  }

  @Builder private channelCard() {
    Column() {
        this.toggleRow('剪贴板同步', this.clipboardEnabled ?
          (this.clipboardReady ? '当前已允许双向文本同步' : '偏好已保存，本次未协商通道，重连后生效') :
          '当前连接已立即停止同步；重新开启可能需要重连',
          this.clipboardEnabled, this.onClipboard)
        Divider().color(this.pal().divider).margin({ left: 12 })
        this.toggleRow('悬浮性能监视器', '控制面板关闭后继续显示可拖动指标卡',
          this.diagnosticsEnabled, this.onDiagnostics)
    }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
      .border({ width: 0.5, color: this.pal().cardBorder })
  }

  @Builder private reconnectCard() {
    Column() {
        if (this.advancedDisplayVisible) {
          this.displayProfileEntry()
          Text(this.resolutionSelectionSummary()).fontSize(9)
            .fontColor(this.pal().text3).width('100%').margin({ top: 6, bottom: 10 })
          if (this.isDesktopDevice && this.resolutionSelected() === 'auto') {
            this.followWindowRow()
          }
          this.multimonSection()
        } else {
          Text('Windows 远端分辨率').fontSize(11).fontColor(this.pal().text2)
            .width('100%').margin({ bottom: 6 })
          Scroll() {
            Row({ space: 6 }) {
              this.choice('自适应（推荐）', this.resolutionSelected() === 'auto', (): void => { this.onResolution('auto'); })
              ForEach(this.orderedResolutionPresets(), (preset: RemoteResolutionPreset): void => {
                this.choice(preset.label, this.resolutionSelected() === preset.id,
                  (): void => { this.onResolution(preset.id); })
              }, (preset: RemoteResolutionPreset): string => preset.id)
            }
          }.width('100%').height(38).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
          Text(this.resolutionSelectionSummary()).fontSize(9)
            .fontColor(this.pal().text3).width('100%').margin({ top: 5, bottom: 10 })
          if (this.isDesktopDevice && this.resolutionSelected() === 'auto') {
            this.followWindowRow()
          }
          Divider().color(this.pal().divider)
          Text('远端界面大小').fontSize(11).fontColor(this.pal().text2)
            .width('100%').margin({ top: 10, bottom: 6 })
          Scroll() {
            Row({ space: 6 }) {
              this.choice('自动', this.remoteUiScale === 'auto', (): void => { this.onRemoteUiScale('auto'); })
              this.choice('标准', this.remoteUiScale === '100', (): void => { this.onRemoteUiScale('100'); })
              this.choice('大', this.remoteUiScale === '140', (): void => { this.onRemoteUiScale('140'); })
              this.choice('特大', this.remoteUiScale === '180', (): void => { this.onRemoteUiScale('180'); })
            }
          }.width('100%').height(38).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
          Text('调整 Windows 字体与控件；与本地画面缩放相互独立').fontSize(9)
            .fontColor(this.pal().text3).width('100%').margin({ top: 5, bottom: 10 })
        }
        Divider().color(this.pal().divider)
        Text('色彩深度').fontSize(11).fontColor(this.pal().text2).width('100%').margin({ top: 10, bottom: 6 })
        Row({ space: 6 }) {
          this.choice('16 位', this.colorDepth === 16, (): void => { this.onColorDepth(16); })
          this.choice('24 位', this.colorDepth === 24, (): void => { this.onColorDepth(24); })
          this.choice('32 位', this.colorDepth === 32, (): void => { this.onColorDepth(32); })
        }.width('100%')
        Divider().color(this.pal().divider).margin({ top: 10 })
        Text('登录身份格式').fontSize(11).fontColor(this.pal().text2)
          .width('100%').margin({ top: 10, bottom: 6 })
        Scroll() {
          Row({ space: 6 }) {
            this.choice('MSA 前缀', this.authIdentityMode === 0,
              (): void => { this.onAuthIdentityMode(0); })
            this.choice('MSA 域', this.authIdentityMode === 1,
              (): void => { this.onAuthIdentityMode(1); })
            this.choice('仅邮箱', this.authIdentityMode === 2,
              (): void => { this.onAuthIdentityMode(2); })
            this.choice('AAD 前缀', this.authIdentityMode === 3,
              (): void => { this.onAuthIdentityMode(3); })
            this.choice('AAD 域', this.authIdentityMode === 4,
              (): void => { this.onAuthIdentityMode(4); })
          }
        }.width('100%').height(38).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
        Divider().color(this.pal().divider).margin({ top: 10 })
        this.toggleRow('TLS 兼容登录', '仅用于已取消强制 NLA 的可信 Windows，安全性较低',
          this.tlsWithoutNla, this.onTlsWithoutNla)
        Divider().color(this.pal().divider).margin({ left: 12 })
        this.toggleRow('远端音频', '下次连接时协商 rdpsnd 通道', this.audioEnabled, this.onAudio)
        Divider().color(this.pal().divider).margin({ left: 12 })
        this.toggleRow('共享文件夹', '下次连接时挂载 RDPDR 文件通道', this.driveEnabled, this.onDrive)
        if (this.driveEnabled) {
          TextInput({ text: this.driveNameDraft, placeholder: 'RemoteDesktop' })
            .height(40).fontSize(12).fontColor(this.pal().text)
            .backgroundColor(this.pal().surface).borderRadius(10)
            .margin({ left: 12, right: 12, bottom: 12 })
            .onChange((value: string): void => { this.driveNameDraft = value; })
            .onSubmit((_enterKey: EnterKeyType): void => { this.onDriveName(this.driveNameDraft); })
            .onBlur((): void => { this.onDriveName(this.driveNameDraft); })
        }
        if (this.securityKeyVisible) {
          this.securityKeyEntry()
        }
    }.width('100%').padding({ left: 12, right: 12, top: 12 })
      .backgroundColor(this.pal().card).borderRadius(16)
      .border({ width: 0.5, color: this.pal().cardBorder })
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text('Windows RDP').fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
          Text((this.hostName || '远端主机') + ' · ' + this.connectedLabel + ' · ' +
            this.controlModeLabel()).fontSize(10).fontColor(this.pal().text3)
            .maxLines(2).margin({ top: 4 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(16).fontColor([this.pal().text2]) }
          .width(40).height(40).padding(0).borderRadius(20).backgroundColor(this.pal().surface)
          .onClick(this.onClose).accessibilityText('关闭 RDP 控制中心')
      }.width('100%')
      Scroll() {
        Column() {
          this.sectionTitle('快捷操作', '立即生效')
          this.quickActions()
          this.sectionTitle('性能监视', '实时')
          this.performanceCard()
          this.sectionTitle('控制与显示', '立即生效')
          this.liveControlCard()
          this.sectionTitle('RDP 通道', this.clipboardEnabled && !this.clipboardReady ?
            '重连后生效' : '立即生效')
          this.channelCard()
          this.sectionTitle('远端会话参数',
            this.isDesktopDevice && this.stats.displayControlReady ? '分辨率可实时生效' : '重连后生效')
          this.reconnectCard()
          ProContinuationControls({ protocol: 'rdp', forceDark: true, onPrepare: this.onPrepareContinuation })
          this.sectionTitle('连接操作')
          Column() {
            this.actionRow($r('sys.symbol.xmark_circle_fill'), '断开 RDP 会话',
              '仅断开当前客户端连接', this.onDisconnect, true)
          }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
            .border({ width: 0.5, color: this.pal().cardBorder })
          Column().height(20)
        }.width('100%')
      }.layoutWeight(1).width('100%').scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
        .margin({ top: 4 })
    }
    .width(this.panelWidth()).height('100%')
    .padding({ left: 16, right: 16, top: 16 })
    .backgroundColor('rgba(16,20,28,0.91)').backdropBlur(20)
    .border({ width: 1, color: this.pal().floatBorder }).borderRadius(22)
    .shadow({ radius: 22, color: this.pal().fabShadow, offsetX: -4, offsetY: 5 })
    // HitTestMode.Block targets only this container and suppresses its
    // descendants. The hierarchy variant keeps buttons/Scroll interactive
    // and prevents the same pointer transaction reaching the remote canvas.
    .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
  }
}
