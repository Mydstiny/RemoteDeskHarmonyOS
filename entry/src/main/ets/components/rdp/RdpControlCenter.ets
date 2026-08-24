import { AppTheme, Palette, buildDark } from '../../common/Theme';
import { RdpRenderStats } from '../../types/rdpnapi';
import { EMPTY_RDP_RENDER_STATS } from '../RdpDiagnosticsHud';
import {
  rdpResolutionLabel,
  rdpResolutionPresets,
  RemoteResolutionPreset
} from '../../services/RemoteResolutionPresetPolicy';
import {
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
  @Prop diagnosticsEnabled: boolean = false;
  @Prop displayScaleMode: string = 'fit';
  @Prop canvasZoomEnabled: boolean = false;
  @Prop reverseWheel: boolean = false;
  @Prop resolutionId: string = 'auto';
  @Prop colorDepth: number = 32;
  @Prop audioEnabled: boolean = true;
  @Prop driveEnabled: boolean = true;
  @Prop @Watch('onDriveNameChange') driveName: string = 'RemoteDesktop';
  @Prop authIdentityMode: number = 1;
  @Prop tlsWithoutNla: boolean = false;
  @State private driveNameDraft: string = 'RemoteDesktop';
  onClose: () => void = (): void => {};
  onOpenKeyboard: () => void = (): void => {};
  onOpenShortcuts: () => void = (): void => {};
  onCtrlAltDel: () => void = (): void => {};
  onRefresh: () => void = (): void => {};
  onControlMode: (mode: number) => void = (_mode: number): void => {};
  onClipboard: (enabled: boolean) => void = (_enabled: boolean): void => {};
  onDiagnostics: (enabled: boolean) => void = (_enabled: boolean): void => {};
  onDisplayScale: (mode: string) => void = (_mode: string): void => {};
  onCanvasZoom: (enabled: boolean) => void = (_enabled: boolean): void => {};
  onReverseWheel: (enabled: boolean) => void = (_enabled: boolean): void => {};
  onResolution: (id: string) => void = (_id: string): void => {};
  onColorDepth: (depth: number) => void = (_depth: number): void => {};
  onAudio: (enabled: boolean) => void = (_enabled: boolean): void => {};
  onDrive: (enabled: boolean) => void = (_enabled: boolean): void => {};
  onDriveName: (name: string) => void = (_name: string): void => {};
  onAuthIdentityMode: (mode: number) => void = (_mode: number): void => {};
  onTlsWithoutNla: (enabled: boolean) => void = (_enabled: boolean): void => {};
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

  private onDriveNameChange(): void { this.driveNameDraft = this.driveName; }

  aboutToAppear(): void { this.driveNameDraft = this.driveName; }

  @Builder private sectionTitle(title: string, activation: string = '') {
    Row() {
      Text(title).fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        .fontFamily(AppTheme.fontFamily)
      if (activation.length > 0) {
        Text(activation).fontSize(9).fontColor(activation === '重连后生效' ? '#FFCF70' : this.accentColor)
          .padding({ left: 7, right: 7, top: 3, bottom: 3 }).borderRadius(9)
          .backgroundColor(activation === '重连后生效' ? 'rgba(255,207,112,0.12)' : this.accentColor + '18')
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

  @Builder private toggleRow(title: string, detail: string, value: boolean,
    action: (enabled: boolean) => void) {
    Row() {
      Column() {
        Text(title).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          .fontFamily(AppTheme.fontFamily)
        Text(detail).fontSize(10).fontColor(this.pal().text3).fontFamily(AppTheme.fontFamily)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: value }).selectedColor(this.accentColor)
        .onChange((next: boolean): void => { if (next !== value) { action(next); } })
    }.width('100%').height(60).padding({ left: 12, right: 12, top: 7, bottom: 7 })
  }

  @Builder private choice(label: string, selected: boolean, action: () => void) {
    Button(label).height(34).fontSize(10).borderRadius(9).padding({ left: 8, right: 8 })
      .fontColor(selected ? Color.White : this.pal().text2)
      .backgroundColor(selected ? this.accentColor : this.pal().surface)
      .onClick(action)
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
          Text(this.perf().transport).fontSize(10).fontColor(this.accentColor)
        }.width('100%').margin({ bottom: 6 })
        this.metric('远端更新年龄', this.perf().frameAge)
        this.metric('送显队列 P95', this.perf().queueP95)
        this.metric('上传 / 绘制 / Swap', durationUs(this.stats.uploadP95Us) + ' / ' +
          durationUs(this.stats.drawP95Us) + ' / ' + durationUs(this.stats.swapP95Us))
        this.metric('桌面尺寸', this.stats.desktopWidth.toString() + ' × ' + this.stats.desktopHeight.toString())
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
          this.choice('适应', this.displayScaleMode === 'fit', (): void => { this.onDisplayScale('fit'); })
          this.choice('100%', this.displayScaleMode === '100', (): void => { this.onDisplayScale('100'); })
          this.choice('125%', this.displayScaleMode === '125', (): void => { this.onDisplayScale('125'); })
        }.width('100%').padding(10)
        Divider().color(this.pal().divider)
        this.toggleRow('手势缩放与平移', '在远端画面上双指缩放并移动画布',
          this.canvasZoomEnabled, this.onCanvasZoom)
        Divider().color(this.pal().divider).margin({ left: 12 })
        this.toggleRow('反转滚轮方向', '立即同步到当前 RDP 会话输入', this.reverseWheel, this.onReverseWheel)
    }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
      .border({ width: 0.5, color: this.pal().cardBorder })
  }

  @Builder private channelCard() {
    Column() {
        this.toggleRow('剪贴板同步', this.clipboardEnabled ? '当前已允许双向文本同步' : '当前连接已停止同步',
          this.clipboardEnabled, this.onClipboard)
        Divider().color(this.pal().divider).margin({ left: 12 })
        this.toggleRow('悬浮性能监视器', '控制面板关闭后继续显示可拖动指标卡',
          this.diagnosticsEnabled, this.onDiagnostics)
    }.width('100%').backgroundColor(this.pal().card).borderRadius(16)
      .border({ width: 0.5, color: this.pal().cardBorder })
  }

  @Builder private reconnectCard() {
    Column() {
        Text('远端桌面分辨率').fontSize(11).fontColor(this.pal().text2)
          .width('100%').margin({ bottom: 6 })
        Scroll() {
          Row({ space: 6 }) {
            this.choice('自适应', this.resolutionId === 'auto', (): void => { this.onResolution('auto'); })
            ForEach(rdpResolutionPresets(), (preset: RemoteResolutionPreset): void => {
              this.choice(preset.label, this.resolutionId === preset.id,
                (): void => { this.onResolution(preset.id); })
            }, (preset: RemoteResolutionPreset): string => preset.id)
          }
        }.width('100%').height(38).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
        Text('当前选择：' + rdpResolutionLabel(this.resolutionId)).fontSize(9)
          .fontColor(this.pal().text3).width('100%').margin({ top: 5, bottom: 10 })
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
          this.sectionTitle('RDP 通道')
          this.channelCard()
          this.sectionTitle('下次连接', '重连后生效')
          this.reconnectCard()
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
    .hitTestBehavior(HitTestMode.Block)
  }
}
