import { LocalResourceStats, RustDeskDiagnosticsSnapshot } from '../types/rdpnapi';
import {
  formatDiagnosticBitrate,
  formatDiagnosticBytes,
  formatDiagnosticDurationUs,
  formatDiagnosticLatency,
  formatDiagnosticRate,
  rustDeskCodecLabel
} from '../services/RustDeskDiagnosticsPolicy';

const EMPTY_DIAGNOSTICS: RustDeskDiagnosticsSnapshot = {
  supported: false,
  sessionId: -1,
  latencyMs: -1,
  targetBitrateKbps: 0,
  videoMessages: 0,
  receivedFrames: 0,
  keyframes: 0,
  receivedBytes: 0,
  audioFrames: 0,
  cadenceGaps: 0,
  maxCadenceGapMs: 0,
  testDelayCount: 0,
  receivedFps: 0,
  displayFps: 0,
  bitrateKbps: 0,
  codec: -1,
  width: 0,
  height: 0,
  connectionPath: 'unknown',
  lastFrameAtMs: 0,
  decodeOk: 0,
  decodeErrors: 0,
  decodeP50Us: 0,
  decodeP95Us: 0,
  decodeMaxUs: 0,
  presentedFrames: 0,
  presentationWindowSamples: 0,
  renderP50Us: 0,
  renderP95Us: 0,
  renderMaxUs: 0,
  queueDepth: 0,
  queueMax: 0,
  droppedFrames: 0,
  decoderBackend: 'unknown'
};

const EMPTY_RESOURCES: LocalResourceStats = {
  supported: false,
  cpuAvailable: false,
  cpuPercent: -1,
  memoryBytes: 0,
  memoryAvailable: false,
  gpuAvailable: false,
  gpuPercent: -1,
  sampledAtMs: 0
};

@Component
export struct RustDeskDiagnosticsHud {
  @Prop diagnostics: RustDeskDiagnosticsSnapshot = EMPTY_DIAGNOSTICS;
  @Prop localResources: LocalResourceStats = EMPTY_RESOURCES;
  @Prop proEnabled: boolean = false;
  @StorageProp('accentColor') accentColor: string = '#007DFF';

  @Builder
  private metricLine(label: string, value: string) {
    Row() {
      Text(label).fontSize(10).fontColor('rgba(255,255,255,0.62)').layoutWeight(1)
      Text(value).fontSize(10).fontColor('#FFFFFF').fontFamily('monospace')
    }.width('100%').height(19)
  }

  build() {
    Column() {
      Row() {
        Text('连接诊断').fontSize(11).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
        Blank().layoutWeight(1)
        Text(this.proEnabled ? 'PRO' : '基础').fontSize(9).fontColor(this.accentColor)
          .fontWeight(FontWeight.Bold)
      }.width('100%').margin({ bottom: 4 })

      if (!this.diagnostics.supported) {
        Text('等待 RustDesk 视频流…').fontSize(10).fontColor('rgba(255,255,255,0.62)')
          .width('100%')
      } else {
        this.metricLine('延迟', formatDiagnosticLatency(this.diagnostics.latencyMs))
        this.metricLine('帧率 / 送显', formatDiagnosticRate(this.diagnostics.receivedFps) + ' / ' +
          formatDiagnosticRate(this.diagnostics.displayFps) + ' FPS')
        this.metricLine('码率', formatDiagnosticBitrate(this.diagnostics.bitrateKbps))
        this.metricLine('画面', (this.diagnostics.width > 0 ? this.diagnostics.width.toString() : '—') + ' × ' +
          (this.diagnostics.height > 0 ? this.diagnostics.height.toString() : '—'))
        this.metricLine('编码 / 解码', rustDeskCodecLabel(this.diagnostics.codec) + ' / ' +
          this.diagnostics.decoderBackend)
        this.metricLine('路径', this.diagnostics.connectionPath)

        if (this.proEnabled) {
          Divider().color('rgba(255,255,255,0.18)').margin({ top: 3, bottom: 3 })
          this.metricLine('队列 / 峰值', this.diagnostics.queueDepth.toString() + ' / ' +
            this.diagnostics.queueMax.toString())
          this.metricLine('丢帧 / 关键帧', this.diagnostics.droppedFrames.toString() + ' / ' +
            this.diagnostics.keyframes.toString())
          this.metricLine('解码 p50 / p95', formatDiagnosticDurationUs(this.diagnostics.decodeP50Us) + ' / ' +
            formatDiagnosticDurationUs(this.diagnostics.decodeP95Us))
          this.metricLine('解码 max', formatDiagnosticDurationUs(this.diagnostics.decodeMaxUs))
          this.metricLine('渲染 p50 / p95', formatDiagnosticDurationUs(this.diagnostics.renderP50Us) + ' / ' +
            formatDiagnosticDurationUs(this.diagnostics.renderP95Us))
          this.metricLine('渲染 max', formatDiagnosticDurationUs(this.diagnostics.renderMaxUs))
          this.metricLine('本机 CPU / 内存', this.localResources.supported ?
            (this.localResources.cpuPercent >= 0 ? this.localResources.cpuPercent.toFixed(1) + '%' : '不可用') +
            ' / ' + formatDiagnosticBytes(this.localResources.memoryBytes) : '不可用')
          this.metricLine('本机 GPU', this.localResources.gpuAvailable ?
            this.localResources.gpuPercent.toFixed(1) + '%' : '不可用')
        }
      }
    }
    .width(270)
    .padding({ left: 12, right: 12, top: 9, bottom: 9 })
    .backgroundColor('rgba(12,16,24,0.78)')
    .borderRadius(10)
    .position({ x: 10, y: 58 })
    .hitTestBehavior(HitTestMode.None)
  }
}
