import { LocalResourceStats, RustDeskDiagnosticsSnapshot } from '../types/rdpnapi';
import {
  formatDiagnosticBitrate,
  formatDiagnosticBytes,
  formatDiagnosticDurationUs,
  formatDiagnosticFrameRate,
  formatDiagnosticLatency,
  rustDeskCodecLabel,
  rustDeskDiagnosticsStreamState
} from '../services/RustDeskDiagnosticsPolicy';

const EMPTY_DIAGNOSTICS: RustDeskDiagnosticsSnapshot = {
  supported: false,
  sessionActive: false,
  protocolSnapshotAvailable: false,
  videoSeen: false,
  receivedRateAvailable: false,
  presentedRateAvailable: false,
  decodeRateAvailable: false,
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
  decodeFps: 0,
  bitrateKbps: 0,
  codec: -1,
  width: 0,
  height: 0,
  connectionPath: 'unknown',
  lastFrameAtMs: 0,
  lastFrameAgeMs: -1,
  decodeOk: 0,
  decodeErrors: 0,
  decodeP50Us: 0,
  decodeP95Us: 0,
  decodeMaxUs: 0,
  presentedFrames: 0,
  presentationWindowSamples: 0,
  presentationWindowMs: 0,
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

interface RustDeskDiagnosticMetric {
  label: string;
  value: string;
}

@Component
export struct RustDeskDiagnosticsHud {
  @Prop diagnostics: RustDeskDiagnosticsSnapshot = EMPTY_DIAGNOSTICS;
  @Prop localResources: LocalResourceStats = EMPTY_RESOURCES;
  @Prop proEnabled: boolean = false;
  @Prop expanded: boolean = false;
  @Prop attachSide: string = 'left';
  @Prop handleX: number = -48;
  @Prop panelX: number = 8;
  @Prop panelY: number = 58;
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  onToggle: () => void = (): void => {};
  onPositionChange: (x: number, y: number, fromPanel: boolean) => void =
    (_x: number, _y: number, _fromPanel: boolean): void => {};
  @State private dragOffsetX: number = 0;
  @State private dragOffsetY: number = 0;
  @State private dragging: boolean = false;

  private isStreamStale(): boolean {
    return this.diagnostics.videoSeen && this.diagnostics.lastFrameAgeMs >= 3000;
  }

  private handleEffectiveX(): number {
    return this.handleX + this.dragOffsetX;
  }

  private panelEffectiveX(): number {
    return this.panelX + this.dragOffsetX;
  }

  private effectiveY(): number {
    return this.panelY + this.dragOffsetY;
  }

  private dockBackground(): string {
    return this.dragging ? 'rgba(12,16,24,0.92)' : 'rgba(12,16,24,0.78)';
  }

  private dockBorder(): string {
    return this.expanded ? this.accentColor + '80' : 'rgba(255,255,255,0.18)';
  }

  private finishDrag(fromPanel: boolean): void {
    const x: number = fromPanel ? this.panelEffectiveX() : this.handleEffectiveX();
    const y: number = this.effectiveY();
    this.dragging = false;
    this.dragOffsetX = 0;
    this.dragOffsetY = 0;
    this.onPositionChange(x, y, fromPanel);
  }

  @Builder
  private metricLine(metric: RustDeskDiagnosticMetric) {
    Row() {
      Text(metric.label).fontSize(10).fontColor('rgba(255,255,255,0.62)').layoutWeight(1)
      Text(metric.value).fontSize(10).fontColor('#FFFFFF').fontFamily('monospace')
    }.width('100%').height(19)
  }

  @Builder
  private panelContent() {
    Column() {
      Row() {
        Text('连接诊断').fontSize(11).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
        Blank().layoutWeight(1)
        Text(this.proEnabled ? 'PRO' : '基础').fontSize(9).fontColor(this.accentColor)
          .fontWeight(FontWeight.Bold)
        Text(this.attachSide === 'left' ? '‹' : '›').fontSize(18).fontColor('#FFFFFF')
          .width(22).textAlign(TextAlign.Center).margin({ left: 4 })
      }
      .width('100%').margin({ bottom: 4 })
      .gesture(
        GestureGroup(GestureMode.Exclusive,
          TapGesture({ count: 1 }).onAction((): void => { this.onToggle(); }),
          PanGesture({ fingers: 1, distance: 5 })
            .onActionStart((_event: GestureEvent): void => {
              this.dragging = true;
              this.dragOffsetX = 0;
              this.dragOffsetY = 0;
            })
            .onActionUpdate((event: GestureEvent): void => {
              this.dragOffsetX = event.offsetX;
              this.dragOffsetY = event.offsetY;
            })
            .onActionEnd((_event: GestureEvent): void => { this.finishDrag(true); })
        )
      )

      // API 23 only retains reactive Builder updates for a single object-literal
      // argument. Do not change these metric rows back to separate label/value
      // arguments: that captures the values from the instant the dock opens.
      this.metricLine({
        label: '状态',
        value: rustDeskDiagnosticsStreamState(this.diagnostics.videoSeen, this.diagnostics.lastFrameAgeMs)
      })
      this.metricLine({
        label: '延迟',
        value: this.diagnostics.protocolSnapshotAvailable ?
          formatDiagnosticLatency(this.diagnostics.latencyMs) : '协议采样不可用'
      })
      this.metricLine({
        label: '帧率 / 送显',
        value: formatDiagnosticFrameRate(this.diagnostics.receivedFps, this.diagnostics.receivedRateAvailable,
          this.diagnostics.videoSeen, this.isStreamStale()) + ' / ' +
          formatDiagnosticFrameRate(this.diagnostics.displayFps, this.diagnostics.presentedRateAvailable,
            this.diagnostics.videoSeen, this.isStreamStale()) + ' FPS'
      })
      this.metricLine({ label: '码率', value: formatDiagnosticBitrate(this.diagnostics.bitrateKbps) })
      this.metricLine({
        label: '画面',
        value: (this.diagnostics.width > 0 ? this.diagnostics.width.toString() : '—') + ' × ' +
          (this.diagnostics.height > 0 ? this.diagnostics.height.toString() : '—')
      })
      this.metricLine({
        label: '编码 / 解码',
        value: rustDeskCodecLabel(this.diagnostics.codec) + ' / ' + this.diagnostics.decoderBackend
      })
      this.metricLine({
        label: '路径',
        value: this.diagnostics.protocolSnapshotAvailable ? this.diagnostics.connectionPath : '协议采样不可用'
      })

      if (this.proEnabled) {
        Divider().color('rgba(255,255,255,0.18)').margin({ top: 3, bottom: 3 })
        this.metricLine({
          label: '解码提交',
          value: formatDiagnosticFrameRate(this.diagnostics.decodeFps, this.diagnostics.decodeRateAvailable,
            this.diagnostics.videoSeen, this.isStreamStale()) + ' FPS'
        })
        this.metricLine({
          label: '队列 / 峰值',
          value: this.diagnostics.queueDepth.toString() + ' / ' + this.diagnostics.queueMax.toString()
        })
        this.metricLine({
          label: '丢帧 / 关键帧',
          value: this.diagnostics.droppedFrames.toString() + ' / ' + this.diagnostics.keyframes.toString()
        })
        this.metricLine({
          label: '解码 p50 / p95',
          value: formatDiagnosticDurationUs(this.diagnostics.decodeP50Us) + ' / ' +
            formatDiagnosticDurationUs(this.diagnostics.decodeP95Us)
        })
        this.metricLine({ label: '解码 max', value: formatDiagnosticDurationUs(this.diagnostics.decodeMaxUs) })
        this.metricLine({
          label: '渲染 p50 / p95',
          value: formatDiagnosticDurationUs(this.diagnostics.renderP50Us) + ' / ' +
            formatDiagnosticDurationUs(this.diagnostics.renderP95Us)
        })
        this.metricLine({ label: '渲染 max', value: formatDiagnosticDurationUs(this.diagnostics.renderMaxUs) })
        this.metricLine({
          label: '本机 CPU / 内存',
          value: this.localResources.cpuAvailable ? this.localResources.cpuPercent.toFixed(1) + '% / ' +
            (this.localResources.memoryAvailable ? formatDiagnosticBytes(this.localResources.memoryBytes) : '不可用') :
            '不可用'
        })
        this.metricLine({
          label: '本机 GPU',
          value: this.localResources.gpuAvailable ? this.localResources.gpuPercent.toFixed(1) + '%' : '不可用'
        })
      }
    }
    .width(270)
    .padding({ left: 12, right: 12, top: 9, bottom: 9 })
    .backgroundColor(this.dockBackground())
    .borderRadius(8)
    .border({ width: 1, color: this.dockBorder() })
    .shadow({ radius: 10, color: 'rgba(0,0,0,0.30)', offsetY: 2 })
  }

  build() {
    if (this.expanded) {
      Stack() {
        this.panelContent()
      }
      .width(270)
        .position({ x: this.panelEffectiveX(), y: this.effectiveY() })
        .hitTestBehavior(HitTestMode.Default)
    } else {
      Row() {
        Text('FPS').fontSize(9).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          .width(28).textAlign(TextAlign.Center)
        Text(this.diagnostics.receivedRateAvailable ? this.diagnostics.receivedFps.toFixed(0) : '…')
          .fontSize(10).fontColor(this.accentColor).fontFamily('monospace')
          .width(48).textAlign(TextAlign.Center)
      }
      .height(38)
      .width(76)
      .borderRadius(12)
      .backgroundColor(this.dockBackground())
      .border({ width: 1, color: this.dockBorder() })
      .shadow({ radius: 8, color: 'rgba(0,0,0,0.30)', offsetY: 2 })
      .position({ x: this.handleEffectiveX(), y: this.effectiveY() })
      .hitTestBehavior(HitTestMode.Default)
      .gesture(
        GestureGroup(GestureMode.Exclusive,
          TapGesture({ count: 1 }).onAction((): void => { this.onToggle(); }),
          PanGesture({ fingers: 1, distance: 5 })
            .onActionStart((_event: GestureEvent): void => {
              this.dragging = true;
              this.dragOffsetX = 0;
              this.dragOffsetY = 0;
            })
            .onActionUpdate((event: GestureEvent): void => {
              this.dragOffsetX = event.offsetX;
              this.dragOffsetY = event.offsetY;
            })
            .onActionEnd((_event: GestureEvent): void => { this.finishDrag(false); })
        )
      )
    }
  }
}
