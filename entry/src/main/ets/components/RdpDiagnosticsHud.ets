import { RdpRenderStats } from '../types/rdpnapi';
import { Palette, buildDark } from '../common/Theme';

export const EMPTY_RDP_RENDER_STATS: RdpRenderStats = {
  paintCount: 0,
  renderedPaintCount: 0,
  firstPaintMs: 0,
  lastPaintMs: 0,
  lastRemoteUpdateAgeMs: -1,
  eventLoopAgeMs: -1,
  eventLoopBlockMaxUs: 0,
  lastInputPostAgeMs: -1,
  eventLoopTicks: 0,
  networkCheckCount: 0,
  networkCheckFailures: 0,
  inputPostFailures: 0,
  lastRenderResult: 0,
  skippedPaintCount: 0,
  slowRenderCount: 0,
  minRenderIntervalUs: 0,
  lastRenderCostUs: 0,
  lastRenderBytes: 0,
  pumpSubmitted: 0,
  pumpRendered: 0,
  pumpReplaced: 0,
  pumpRejected: 0,
  invalidEvents: 0,
  invalidPixels: 0,
  copiedBytes: 0,
  presentationRejected: 0,
  surfaceDetachedRejections: 0,
  generationRejections: 0,
  presentationWindowSamples: 0,
  callbackP50Us: 0,
  callbackP95Us: 0,
  callbackMaxUs: 0,
  copyP50Us: 0,
  copyP95Us: 0,
  copyMaxUs: 0,
  queueP50Us: 0,
  queueP95Us: 0,
  queueMaxUs: 0,
  uploadP50Us: 0,
  uploadP95Us: 0,
  uploadMaxUs: 0,
  drawP50Us: 0,
  drawP95Us: 0,
  drawMaxUs: 0,
  swapP50Us: 0,
  swapP95Us: 0,
  swapMaxUs: 0,
  workerP50Us: 0,
  workerP95Us: 0,
  workerMaxUs: 0,
  glUploadGateDecision: 0,
  glUploadEvaluatedSamples: 0,
  glUploadSwapP95Us: 0,
  glUploadSharePermille: 0,
  desktopWidth: 0,
  desktopHeight: 0,
  graphicsEpoch: 0,
  desktopResizeCount: 0,
  desktopResizeFailures: 0,
  desktopResizeInProgress: false,
  gfxChannelConnected: false,
  displayControlReady: false,
  displayControlDisabled: false,
  displayRequestedWidth: 0,
  displayRequestedHeight: 0,
  displayEffectiveWidth: 0,
  displayEffectiveHeight: 0,
  displayScaleFactor: 100,
  displayRequestCount: 0,
  displayChannelRequestCount: 0,
  displayFailureCount: 0,
  displayLayoutPending: false,
  displayLayoutInFlight: false,
  displayLastResult: 'not_negotiated',
  inputGeometryReady: true,
  inputGeometryAcknowledgedEpoch: 0,
  inputGeometryFenceDrops: 0,
  inputQueueDepth: 0,
  inputQueueMax: 0,
  inputTextUnits: 0,
  inputDroppedMouseMoves: 0,
  inputNonDisposableOverflow: 0,
  graphicsMode: 'unknown'
};

interface RdpDiagnosticMetric {
  label: string;
  value: string;
}

function durationUs(value: number): string {
  if (!Number.isFinite(value) || value <= 0) { return '-'; }
  return value >= 1000 ? (value / 1000).toFixed(1) + ' ms' : Math.round(value).toString() + ' us';
}

function ageMs(value: number): string {
  if (!Number.isFinite(value) || value < 0) { return '-'; }
  return Math.round(value).toString() + ' ms';
}

function resultLabel(value: number, lastRemoteUpdateAgeMs: number): string {
  if (!Number.isFinite(lastRemoteUpdateAgeMs) || lastRemoteUpdateAgeMs < 0) { return '待采样'; }
  if (value >= 0) { return '正常'; }
  if (value === -3) { return 'surface detached'; }
  if (value === -4) { return 'generation mismatch'; }
  return '送显恢复中';
}

@Component
export struct RdpDiagnosticsHud {
  @Prop stats: RdpRenderStats = EMPTY_RDP_RENDER_STATS;
  @Prop @Watch('onViewportChange') availableWidth: number = 360;
  @Prop @Watch('onViewportChange') availableHeight: number = 640;
  @Prop @Watch('onViewportChange') topInset: number = 0;
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @State private expanded: boolean = false;
  @State private panelX: number = 10;
  @State private panelY: number = 62;
  @State private dragX: number = 0;
  @State private dragY: number = 0;

  private pal(): Palette { return buildDark(this.accentColor); }

  private panelHeight(expanded: boolean = this.expanded): number {
    return expanded ? 248 : 116;
  }

  private visiblePanelWidth(): number {
    return Math.max(44, Math.min(236, this.availableWidth));
  }

  private visiblePanelHeight(expanded: boolean = this.expanded): number {
    return Math.max(44, Math.min(this.panelHeight(expanded), this.availableHeight));
  }

  private canExpand(): boolean {
    return this.availableWidth >= 236 && this.availableHeight >= 248;
  }

  private clampPosition(expanded: boolean = this.expanded): void {
    this.panelX = Math.max(0, Math.min(this.panelX,
      Math.max(0, this.availableWidth - this.visiblePanelWidth())));
    this.panelY = Math.max(0, Math.min(this.panelY,
      Math.max(0, this.availableHeight - this.visiblePanelHeight(expanded))));
  }

  private onViewportChange(): void {
    if (!this.canExpand()) { this.expanded = false; }
    this.clampPosition();
  }

  private finishDrag(): void {
    this.panelX += this.dragX;
    this.panelY += this.dragY;
    this.dragX = 0;
    this.dragY = 0;
    this.clampPosition();
  }

  @Builder
  private metric(metric: RdpDiagnosticMetric) {
    Row() {
      Text(metric.label).fontSize(10).fontColor('rgba(255,255,255,0.62)').layoutWeight(1)
      Text(metric.value).fontSize(10).fontColor('#FFFFFF').fontFamily('monospace')
    }.width('100%').height(19)
  }

  build() {
    Column() {
      Row() {
        Column().width(7).height(7).borderRadius(4)
          .backgroundColor(this.stats.lastRemoteUpdateAgeMs < 0 ? '#A8B0BF' :
            (this.stats.lastRenderResult < 0 ? this.pal().danger : '#66DD7A'))
        Text('RDP 性能监视').fontSize(11).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
          .margin({ left: 7 })
        Blank().layoutWeight(1)
        Text(this.stats.graphicsMode.toUpperCase()).fontSize(9).fontColor(this.accentColor)
          .fontWeight(FontWeight.Bold)
        SymbolGlyph(this.expanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(12).fontColor(['rgba(255,255,255,0.72)']).margin({ left: 8 })
      }.width('100%').height(28).margin({ bottom: 4 })
        .onClick((): void => {
          const next: boolean = !this.expanded && this.canExpand();
          this.expanded = next;
          this.clampPosition(next);
        })
        .gesture(PanGesture({ fingers: 1, direction: PanDirection.All, distance: 4 })
          .onActionUpdate((event: GestureEvent): void => {
            this.dragX = event.offsetX;
            this.dragY = event.offsetY;
          })
          .onActionEnd((): void => { this.finishDrag(); })
          .onActionCancel((): void => { this.dragX = 0; this.dragY = 0; }))
      this.metric({
        label: '状态',
        value: resultLabel(this.stats.lastRenderResult, this.stats.lastRemoteUpdateAgeMs)
      })
      this.metric({
        label: '队列 P95',
        value: durationUs(this.stats.queueP95Us)
      })
      this.metric({
        label: '远端更新年龄',
        value: ageMs(this.stats.lastRemoteUpdateAgeMs)
      })
      if (this.expanded) {
        this.metric({
          label: '送显 / 替换',
          value: this.stats.presentationWindowSamples.toString() + ' / ' +
            this.stats.pumpReplaced.toString()
        })
        this.metric({
          label: '事件循环年龄 / 阻塞',
          value: ageMs(this.stats.eventLoopAgeMs) + ' / ' + durationUs(this.stats.eventLoopBlockMaxUs)
        })
        this.metric({
          label: '上传 / 绘制 / swap',
          value: durationUs(this.stats.uploadP95Us) + ' / ' +
            durationUs(this.stats.drawP95Us) + ' / ' + durationUs(this.stats.swapP95Us)
        })
        this.metric({
          label: '画面尺寸',
          value: this.stats.desktopWidth.toString() + ' x ' + this.stats.desktopHeight.toString()
        })
        this.metric({
          label: 'GFX / 动态布局',
          value: (this.stats.gfxChannelConnected ? 'connected' : 'gdi') + ' / ' +
            (this.stats.displayControlDisabled ? 'fallback' :
              (this.stats.displayControlReady ? this.stats.displayLastResult : 'unavailable'))
        })
        this.metric({
          label: '停滞/拒绝',
          value: this.stats.pumpRejected.toString() + ' / ' + this.stats.presentationRejected.toString()
        })
        this.metric({
          label: '输入失败 / 网络检查',
          value: this.stats.inputPostFailures.toString() + ' / ' +
            this.stats.networkCheckFailures.toString()
        })
      }
    }
    .width(this.visiblePanelWidth()).height(this.visiblePanelHeight())
    .padding(12)
    .backgroundColor('rgba(12,16,24,0.78)').backdropBlur(18)
    .border({ width: 0.5, color: this.pal().floatBorder })
    .borderRadius(16)
    .shadow({ radius: 16, color: this.pal().fabShadow, offsetY: 4 })
    .position({ x: this.panelX, y: this.topInset + this.panelY })
    .translate({ x: this.dragX, y: this.dragY })
    .clip(true)
    .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
  }
}
