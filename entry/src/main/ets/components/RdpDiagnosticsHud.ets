import { RdpRenderStats } from '../types/rdpnapi';

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
  gfxChannelConnected: false,
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

function resultLabel(value: number): string {
  if (value >= 0) { return '正常'; }
  if (value === -3) { return 'surface detached'; }
  if (value === -4) { return 'generation mismatch'; }
  return '送显恢复中';
}

@Component
export struct RdpDiagnosticsHud {
  @Prop stats: RdpRenderStats = EMPTY_RDP_RENDER_STATS;
  @StorageProp('accentColor') accentColor: string = '#007DFF';

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
        Text('RDP 性能监视').fontSize(11).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
        Blank().layoutWeight(1)
        Text(this.stats.graphicsMode.toUpperCase()).fontSize(9).fontColor(this.accentColor)
          .fontWeight(FontWeight.Bold)
      }.width('100%').margin({ bottom: 4 })
      this.metric({
        label: '状态',
        value: resultLabel(this.stats.lastRenderResult)
      })
      this.metric({
        label: '送显 / 替换',
        value: this.stats.presentationWindowSamples.toString() + ' / ' +
          this.stats.pumpReplaced.toString()
      })
      this.metric({
        label: '队列 P95',
        value: durationUs(this.stats.queueP95Us)
      })
      this.metric({
        label: '远端更新年龄',
        value: ageMs(this.stats.lastRemoteUpdateAgeMs)
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
        label: 'GFX 通道',
        value: this.stats.gfxChannelConnected ? 'connected' : 'gdi'
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
      Text('详细数据已写入 hilog，可用 HDC 导出').fontSize(9)
        .fontColor('rgba(255,255,255,0.48)').margin({ top: 4 })
    }
    .width(236)
    .padding(12)
    .backgroundColor('rgba(12,16,24,0.84)')
    .border({ width: 0.5, color: this.accentColor + '90' })
    .borderRadius(10)
    .position({ x: 10, y: 62 })
  }
}
