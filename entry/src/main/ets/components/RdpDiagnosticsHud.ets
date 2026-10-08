import { RdpRenderStats } from '../types/rdpnapi';
import {
  DiagnosticRdpGraphicsFacts,
  rdpGfxCapsLabel,
  rdpGraphicsFactsFromRenderStats,
  rdpGraphicsPresentationLabel,
  rdpH264StatusLabel,
  rdpWireCodecLabel
} from '../services/RdpGraphicsEvidencePolicy';
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

/** Panel width when there is room; the tucked tab's size; how close to an edge a drop tucks it. */
const PANEL_WIDTH: number = 272;
const TAB_WIDTH: number = 46;
const TAB_HEIGHT: number = 40;
const TUCK_DISTANCE: number = 28;

/**
 * RDP 性能监视: a floating card like RustDesk's. Drag it by its header; dropped near the left or right edge (or with its
 * 收起 button) it tucks into a small tab on that edge, which a tap brings back. Expanded, the details scroll and a
 * long value wraps under its own column instead of running into its label.
 */
@Component
export struct RdpDiagnosticsHud {
  @Prop stats: RdpRenderStats = EMPTY_RDP_RENDER_STATS;
  @Prop @Watch('onViewportChange') availableWidth: number = 360;
  @Prop @Watch('onViewportChange') availableHeight: number = 640;
  @Prop @Watch('onViewportChange') topInset: number = 0;
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @State private expanded: boolean = false;
  @State private tucked: boolean = false;
  @State private side: string = 'left';
  @State private panelX: number = 10;
  @State private panelY: number = 62;
  @State private dragX: number = 0;
  @State private dragY: number = 0;

  private pal(): Palette { return buildDark(this.accentColor); }

  private panelWidth(): number {
    return Math.max(44, Math.min(PANEL_WIDTH, this.availableWidth - 16));
  }

  /** Collapsed: header and three lines. Expanded: as tall as the details, at most what the window has. */
  private panelHeight(expanded: boolean = this.expanded): number {
    const wanted: number = expanded ? 420 : 116;
    return Math.max(44, Math.min(wanted, this.availableHeight - 16));
  }

  private clampPosition(expanded: boolean = this.expanded): void {
    this.panelX = Math.max(0, Math.min(this.panelX, Math.max(0, this.availableWidth - this.panelWidth())));
    this.panelY = Math.max(0, Math.min(this.panelY, Math.max(0, this.availableHeight - this.panelHeight(expanded))));
  }

  private onViewportChange(): void {
    this.clampPosition();
  }

  private tuck(side: string): void {
    this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, (): void => {
      this.side = side;
      this.tucked = true;
      this.panelY = Math.max(0, Math.min(this.panelY, this.availableHeight - TAB_HEIGHT));
    });
  }

  private untuck(): void {
    this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, (): void => {
      this.tucked = false;
      this.panelX = this.side === 'left' ? 10 : Math.max(0, this.availableWidth - this.panelWidth() - 10);
      this.clampPosition();
    });
  }

  private finishDrag(): void {
    const x: number = this.panelX + this.dragX;
    this.panelX = x;
    this.panelY += this.dragY;
    this.dragX = 0;
    this.dragY = 0;
    if (x <= TUCK_DISTANCE) { this.tuck('left'); return; }
    if (x + this.panelWidth() >= this.availableWidth - TUCK_DISTANCE) { this.tuck('right'); return; }
    this.clampPosition();
  }

  private finishTabDrag(): void {
    this.panelY = Math.max(0, Math.min(this.panelY + this.dragY, this.availableHeight - TAB_HEIGHT));
    this.dragX = 0;
    this.dragY = 0;
  }

  @Builder
  private metric(metric: RdpDiagnosticMetric) {
    Row() {
      Text(metric.label).fontSize(10).fontColor('rgba(255,255,255,0.62)')
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1).margin({ right: 8 })
      Text(metric.value).fontSize(10).fontColor('#FFFFFF').fontFamily('monospace')
        .textAlign(TextAlign.End).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '58%' })
    }.width('100%').constraintSize({ minHeight: 19 }).alignItems(VerticalAlign.Top).padding({ top: 2, bottom: 2 })
  }

  private graphicsFacts(): DiagnosticRdpGraphicsFacts {
    return rdpGraphicsFactsFromRenderStats(this.stats);
  }

  private graphicsBadge(): string {
    const facts: DiagnosticRdpGraphicsFacts = this.graphicsFacts();
    return facts.wireCodec !== 'none' ? rdpWireCodecLabel(facts) :
      this.stats.graphicsMode.toUpperCase();
  }

  private statusColor(): string {
    return this.stats.lastRemoteUpdateAgeMs < 0 ? '#A8B0BF' :
      (this.stats.lastRenderResult < 0 ? this.pal().danger : '#66DD7A');
  }

  @Builder
  private details() {
    this.metric({ label: '状态', value: resultLabel(this.stats.lastRenderResult, this.stats.lastRemoteUpdateAgeMs) })
    this.metric({ label: '队列 P95', value: durationUs(this.stats.queueP95Us) })
    this.metric({ label: '远端更新年龄', value: ageMs(this.stats.lastRemoteUpdateAgeMs) })
    if (this.expanded) {
      Divider().color('rgba(255,255,255,0.14)').margin({ top: 3, bottom: 3 })
      this.metric({
        label: '送显 / 替换',
        value: this.stats.presentationWindowSamples.toString() + ' / ' + this.stats.pumpReplaced.toString()
      })
      this.metric({ label: '事件循环年龄', value: ageMs(this.stats.eventLoopAgeMs) })
      this.metric({ label: '事件循环阻塞', value: durationUs(this.stats.eventLoopBlockMaxUs) })
      this.metric({ label: '上传 P95', value: durationUs(this.stats.uploadP95Us) })
      this.metric({ label: '绘制 P95', value: durationUs(this.stats.drawP95Us) })
      this.metric({ label: 'swap P95', value: durationUs(this.stats.swapP95Us) })
      this.metric({
        label: '画面尺寸',
        value: this.stats.desktopWidth.toString() + ' × ' + this.stats.desktopHeight.toString()
      })
      this.metric({ label: '图形管线', value: rdpGraphicsPresentationLabel(this.graphicsFacts()) })
      this.metric({
        label: '动态布局',
        value: this.stats.displayControlDisabled ? 'fallback' :
          (this.stats.displayControlReady ? this.stats.displayLastResult : 'unavailable')
      })
      this.metric({ label: 'GFX 能力', value: rdpGfxCapsLabel(this.graphicsFacts()) })
      this.metric({ label: '线上编码', value: rdpWireCodecLabel(this.graphicsFacts()) })
      this.metric({ label: 'H.264', value: rdpH264StatusLabel(this.graphicsFacts()) })
      this.metric({
        label: '停滞 / 拒绝',
        value: this.stats.pumpRejected.toString() + ' / ' + this.stats.presentationRejected.toString()
      })
      this.metric({
        label: '输入失败 / 网络检查',
        value: this.stats.inputPostFailures.toString() + ' / ' + this.stats.networkCheckFailures.toString()
      })
    }
  }

  @Builder
  private panel() {
    Column() {
      Row() {
        Column().width(7).height(7).borderRadius(4).backgroundColor(this.statusColor())
        Text('RDP 性能监视').fontSize(11).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
          .margin({ left: 7 }).maxLines(1)
        Blank().layoutWeight(1)
        Text(this.graphicsBadge()).fontSize(9).fontColor(this.accentColor).fontWeight(FontWeight.Bold).maxLines(1)
        SymbolGlyph(this.expanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(12).fontColor(['rgba(255,255,255,0.72)']).margin({ left: 8 })
        // 收起到边 (the nearer edge).
        SymbolGlyph(this.panelX + this.panelWidth() / 2 < this.availableWidth / 2 ?
          $r('sys.symbol.chevron_left') : $r('sys.symbol.chevron_right'))
          .fontSize(12).fontColor(['rgba(255,255,255,0.72)']).margin({ left: 6 })
          .padding(6).accessibilityText('收起到边上')
          .onClick((): void => {
            this.tuck(this.panelX + this.panelWidth() / 2 < this.availableWidth / 2 ? 'left' : 'right');
          })
      }.width('100%').height(28).margin({ bottom: 4 })
        .onClick((): void => {
          const next: boolean = !this.expanded;
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
      Scroll() {
        Column() { this.details() }.width('100%')
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
    }
    .width(this.panelWidth()).height(this.panelHeight())
    .padding(12)
    .backgroundColor('rgba(12,16,24,0.82)').backdropBlur(18)
    .border({ width: 0.5, color: this.pal().floatBorder })
    .borderRadius(16)
    .shadow({ radius: 16, color: this.pal().fabShadow, offsetY: 4 })
    .position({ x: this.panelX, y: this.topInset + this.panelY })
    .translate({ x: this.dragX, y: this.dragY })
    .clip(true)
    .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
  }

  /** Tucked: a small tab on the edge with the status dot; tap to bring the card back, drag to move it up or down. */
  @Builder
  private tab() {
    Row({ space: 5 }) {
      Column().width(7).height(7).borderRadius(4).backgroundColor(this.statusColor())
      Text('RDP').fontSize(9).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
    }
    .width(TAB_WIDTH).height(TAB_HEIGHT).justifyContent(FlexAlign.Center)
    .backgroundColor('rgba(12,16,24,0.82)').backdropBlur(18)
    .border({ width: 0.5, color: this.pal().floatBorder })
    .borderRadius(this.side === 'left' ? { topRight: 12, bottomRight: 12 } : { topLeft: 12, bottomLeft: 12 })
    .shadow({ radius: 8, color: 'rgba(0,0,0,0.30)', offsetY: 2 })
    .position({ x: this.side === 'left' ? 0 : this.availableWidth - TAB_WIDTH, y: this.topInset + this.panelY })
    .translate({ y: this.dragY })
    .accessibilityText('展开 RDP 性能监视')
    .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
    .gesture(
      GestureGroup(GestureMode.Exclusive,
        TapGesture({ count: 1 }).onAction((): void => { this.untuck(); }),
        PanGesture({ fingers: 1, direction: PanDirection.All, distance: 5 })
          .onActionUpdate((event: GestureEvent): void => { this.dragY = event.offsetY; })
          .onActionEnd((): void => { this.finishTabDrag(); })
          .onActionCancel((): void => { this.dragY = 0; })))
  }

  build() {
    if (this.tucked) {
      this.tab()
    } else {
      this.panel()
    }
  }
}
