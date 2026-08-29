import {
  LocalResourceStats,
  RustDeskDiagnosticsSnapshot,
  RustDeskMultiCanvasPreviewSnapshot
} from '../types/rdpnapi';
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
  remoteInputPermissionKnown: false,
  remoteInputAllowed: true,
  remoteClipboardPermissionKnown: false,
  remoteClipboardAllowed: true,
  remoteFilePermissionKnown: false,
  remoteFileAllowed: true,
  sessionId: -1,
  latencyMs: -1,
  targetBitrateKbps: 0,
  requestedImageQuality: -1,
  effectiveImageQuality: -1,
  sentImageQuality: -1,
  qualityProfile: -1,
  qualityFps: 0,
  qualityRequestedGeneration: 0,
  qualityAppliedGeneration: 0,
  qualityUpdateStatus: 0,
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
  lastPresentedAtMs: 0,
  lastPresentedFrameAgeMs: -1,
  decodeOk: 0,
  decodeErrors: 0,
  decodeP50Us: 0,
  decodeP95Us: 0,
  decodeMaxUs: 0,
  presentedFrames: 0,
  presentationRejected: 0,
  lastDirtyX: -1,
  lastDirtyY: -1,
  lastDirtyWidth: 0,
  lastDirtyHeight: 0,
  requestedColorDepth: '',
  effectiveColorDepth: 0,
  inputEventsSent: 0,
  inputEventsDropped: 0,
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
const EMPTY_MULTI_CANVAS_PREVIEW: RustDeskMultiCanvasPreviewSnapshot = {
  supported: false, active: false, display: -1, status: 'inactive', reason: '',
  decoderBackend: 'paused', sourceWidth: 0, sourceHeight: 0, codec: -1,
  lastDecodeResult: 0, receivedFrames: 0, acceptedFrames: 0, droppedFrames: 0,
  presentedFrames: 0, queueDepth: 0, inputDroppedFrames: 0
};
const DRAG_COMMIT_THRESHOLD = 5;

interface RustDeskDiagnosticMetric {
  label: string;
  value: string;
}

@Component
export struct RustDeskDiagnosticsHud {
  @Prop diagnostics: RustDeskDiagnosticsSnapshot = EMPTY_DIAGNOSTICS;
  @Prop localResources: LocalResourceStats = EMPTY_RESOURCES;
  @Prop multiCanvasPreview: RustDeskMultiCanvasPreviewSnapshot = EMPTY_MULTI_CANVAS_PREVIEW;
  @Prop protocolLabel: string = 'RustDesk';
  @Prop geometryEpoch: number = 0;
  @Prop surfaceWidth: number = 0;
  @Prop surfaceHeight: number = 0;
  @Prop refreshMs: number = 1000;
  @Prop requestedEncoding: string = '';
  @Prop requestedColorDepth: string = '';
  @Prop requestedFrameRate: number = 0;
  @Prop metricMask: number = 63;
  @Prop proEnabled: boolean = false;
  @Prop expanded: boolean = false;
  @Prop attachSide: string = 'left';
  @Prop handleX: number = -48;
  @Prop panelX: number = 8;
  @Prop panelY: number = 58;
  @Prop measurementGeneration: number = -1;
  @Prop measurementToken: string = '';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  onToggle: () => void = (): void => {};
  onPositionChange: (x: number, y: number, fromPanel: boolean) => void =
    (_x: number, _y: number, _fromPanel: boolean): void => {};
  onMeasured: (generation: number, measurementToken: string,
    x: number, y: number, width: number, height: number) => void =
    (_generation: number, _token: string, _x: number, _y: number,
      _width: number, _height: number): void => {};
  @State private dragOffsetX: number = 0;
  @State private dragOffsetY: number = 0;
  @State private dragging: boolean = false;
  @State private dragMoved: boolean = false;

  private isStreamStale(): boolean {
    return this.diagnostics.videoSeen && this.diagnostics.lastFrameAgeMs >= 3000;
  }

  private vncPresentationState(): string {
    if (!this.diagnostics.sessionActive) { return '会话未激活'; }
    if (!this.diagnostics.videoSeen) { return '等待服务器首帧'; }
    const staleThresholdMs: number = Math.max(3000, this.refreshMs * 6);
    if (this.diagnostics.lastFrameAgeMs >= staleThresholdMs) {
      return '服务器停止更新';
    }
    if (this.diagnostics.presentedFrames === 0) {
      return this.diagnostics.presentationRejected > 0 ? '画布拒绝首帧' : '首帧等待送显';
    }
    if (this.diagnostics.lastPresentedFrameAgeMs >= staleThresholdMs) {
      return this.diagnostics.presentationRejected > 0 ? '画布送显受阻' : '送显链路停滞';
    }
    return '画面持续更新';
  }

  private connectionPathLabel(): string {
    if (this.diagnostics.connectionPath === 'direct') { return 'TCP 直连'; }
    if (this.diagnostics.connectionPath === 'repeater') { return 'UltraVNC Repeater'; }
    if (this.diagnostics.connectionPath === 'relay') { return 'RustDesk 中继'; }
    return this.diagnostics.connectionPath === '' ? '未知' : this.diagnostics.connectionPath;
  }

  private remotePermissionLabel(): string {
    if (!this.diagnostics.remoteInputPermissionKnown) { return '等待远端权限同步'; }
    return this.diagnostics.remoteInputAllowed ? '允许控制' : '仅查看';
  }

  private imageQualityLabel(quality: number): string {
    if (quality === 0) { return '流畅'; }
    if (quality === 1) { return '平衡'; }
    if (quality === 2) { return '最高'; }
    return '未上报';
  }

  private imageQualityStateLabel(): string {
    if (this.diagnostics.qualityUpdateStatus === 1) { return '等待发送'; }
    if (this.diagnostics.qualityUpdateStatus === 2) {
      return this.diagnostics.qualityAppliedGeneration === this.diagnostics.qualityRequestedGeneration ?
        '已发送' : '发送代次未对齐';
    }
    if (this.diagnostics.qualityUpdateStatus === 3) { return '发送失败'; }
    return '连接初始值';
  }

  private vncRequestedColorDepth(): string {
    const requested: string = this.diagnostics.requestedColorDepth !== '' ?
      this.diagnostics.requestedColorDepth : this.requestedColorDepth;
    return requested === '' || requested === 'auto' ? '自动' : requested + ' bit';
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

  private visiblePanelWidth(): number {
    const viewportWidth: number = this.surfaceWidth > 0 ? this.surfaceWidth : 360;
    return Math.min(270, Math.max(1, viewportWidth - 16));
  }

  private desiredPanelHeight(): number {
    if (this.protocolLabel === 'VNC') { return 520; }
    return this.proEnabled ? 450 : 285;
  }

  private visiblePanelHeight(): number {
    if (this.surfaceHeight <= 0) { return this.desiredPanelHeight(); }
    const available: number = this.surfaceHeight - Math.max(8, this.effectiveY()) - 8;
    return Math.max(112, Math.min(this.desiredPanelHeight(), available));
  }

  private finishDrag(fromPanel: boolean): void {
    const x: number = fromPanel ? this.panelEffectiveX() : this.handleEffectiveX();
    const y: number = this.effectiveY();
    const moved: boolean = this.dragMoved;
    this.dragging = false;
    this.dragMoved = false;
    this.dragOffsetX = 0;
    this.dragOffsetY = 0;
    if (!moved) {
      return;
    }
    this.onPositionChange(x, y, fromPanel);
  }

  private cancelDrag(): void {
    this.dragging = false;
    this.dragMoved = false;
    this.dragOffsetX = 0;
    this.dragOffsetY = 0;
  }

  private overlayAreaChangeHandler(fromPanel: boolean): (oldArea: Area, next: Area) => void {
    const generation: number = this.measurementGeneration;
    const token: string = this.measurementToken;
    const x: number = fromPanel ? this.panelEffectiveX() : this.handleEffectiveX();
    const y: number = this.effectiveY();
    return (_old: Area, next: Area): void => {
      const width: number = next.width as number;
      const height: number = next.height as number;
      if (Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0) {
        this.onMeasured(generation, token, x, y, width, height);
      }
    };
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
        Text(this.protocolLabel === 'VNC' ? 'VNC 性能监视' : '连接诊断')
          .fontSize(11).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
        Blank().layoutWeight(1)
        if (this.protocolLabel === 'VNC') {
          Text('RAW BGRA').fontSize(9).fontColor(this.accentColor).fontWeight(FontWeight.Bold)
        } else {
          Text(this.proEnabled ? 'PRO' : '基础').fontSize(9).fontColor(this.accentColor)
            .fontWeight(FontWeight.Bold)
        }
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
              this.dragMoved = false;
              this.dragOffsetX = 0;
              this.dragOffsetY = 0;
            })
            .onActionUpdate((event: GestureEvent): void => {
              this.dragOffsetX = event.offsetX;
              this.dragOffsetY = event.offsetY;
              if (Math.sqrt(event.offsetX * event.offsetX + event.offsetY * event.offsetY) >=
                DRAG_COMMIT_THRESHOLD) {
                this.dragMoved = true;
              }
            })
            .onActionEnd((_event: GestureEvent): void => { this.finishDrag(true); })
            .onActionCancel((): void => { this.cancelDrag(); })
        )
      )

      Scroll() {
        Column() {
          // API 23 only retains reactive Builder updates for a single object-literal
          // argument. Do not change these metric rows back to separate label/value
          // arguments: that captures the values from the instant the dock opens.
          this.metricLine({
        label: '状态',
        value: this.protocolLabel === 'VNC' ? this.vncPresentationState() :
          rustDeskDiagnosticsStreamState(this.diagnostics.videoSeen, this.diagnostics.lastFrameAgeMs)
      })
      this.metricLine({
        label: '延迟',
        value: this.diagnostics.protocolSnapshotAvailable ?
          formatDiagnosticLatency(this.diagnostics.latencyMs) : '等待往返采样'
      })
      if (this.protocolLabel !== 'VNC') {
        this.metricLine({
          label: '远端权限',
          value: this.remotePermissionLabel()
        })
        this.metricLine({
          label: '画质 偏好/生效/已发送',
          value: this.imageQualityLabel(this.diagnostics.requestedImageQuality) + '/' +
            this.imageQualityLabel(this.diagnostics.effectiveImageQuality) + '/' +
            this.imageQualityLabel(this.diagnostics.sentImageQuality)
        })
        this.metricLine({
          label: '画质更新',
          value: this.imageQualityStateLabel() + ' #' +
            this.diagnostics.qualityAppliedGeneration.toString() + '/' +
            this.diagnostics.qualityRequestedGeneration.toString()
        })
        if (this.multiCanvasPreview.active || this.multiCanvasPreview.reason.length > 0) {
          this.metricLine({
            label: '第二画布',
            value: 'D' + this.multiCanvasPreview.display.toString() + ' ' +
              this.multiCanvasPreview.status + ' / ' + this.multiCanvasPreview.decoderBackend
          })
          this.metricLine({
            label: '预览 送显/丢帧/队列',
            value: this.multiCanvasPreview.presentedFrames.toString() + '/' +
              this.multiCanvasPreview.droppedFrames.toString() + '/' +
              this.multiCanvasPreview.queueDepth.toString()
          })
        }
      }
      this.metricLine({
        label: '帧率 / 送显',
        value: formatDiagnosticFrameRate(this.diagnostics.receivedFps, this.diagnostics.receivedRateAvailable,
          this.diagnostics.videoSeen, this.isStreamStale()) + ' / ' +
          formatDiagnosticFrameRate(this.diagnostics.displayFps, this.diagnostics.presentedRateAvailable,
          this.diagnostics.videoSeen, this.isStreamStale()) + ' FPS'
      })
      this.metricLine({
        label: '送显拒绝',
        value: this.diagnostics.presentationRejected.toString()
      })
      this.metricLine({
        label: this.protocolLabel === 'VNC' ? '帧缓冲吞吐' : '码率',
        value: formatDiagnosticBitrate(this.diagnostics.bitrateKbps)
      })
      this.metricLine({
        label: '画面',
        value: (this.diagnostics.width > 0 ? this.diagnostics.width.toString() : '—') + ' × ' +
          (this.diagnostics.height > 0 ? this.diagnostics.height.toString() : '—')
      })
      this.metricLine({
        label: '编码 / 解码',
        value: this.protocolLabel === 'VNC' ? 'RAW BGRA' :
          rustDeskCodecLabel(this.diagnostics.codec) + ' / ' + this.diagnostics.decoderBackend
      })
      this.metricLine({
        label: '路径',
        value: this.diagnostics.protocolSnapshotAvailable ?
          this.connectionPathLabel() : '连接路径未上报'
      })

          if (this.protocolLabel === 'VNC') {
        Divider().color('rgba(255,255,255,0.18)').margin({ top: 3, bottom: 3 })
        this.metricLine({
          label: '接收 / 送显总帧',
          value: this.diagnostics.receivedFrames.toString() + ' / ' +
            this.diagnostics.presentedFrames.toString()
        })
        this.metricLine({
          label: '帧缓冲处理量',
          value: formatDiagnosticBytes(this.diagnostics.receivedBytes)
        })
        this.metricLine({
          label: '服务器帧距今',
          value: this.diagnostics.lastFrameAgeMs >= 0 ?
            this.diagnostics.lastFrameAgeMs.toString() + ' ms' : '尚无画面'
        })
        this.metricLine({
          label: '成功送显距今',
          value: this.diagnostics.lastPresentedFrameAgeMs >= 0 ?
            this.diagnostics.lastPresentedFrameAgeMs.toString() + ' ms' : '尚未送显'
        })
        if ((this.metricMask & 32) !== 0) {
          this.metricLine({
            label: '本地画布 / 几何代',
            value: Math.round(this.surfaceWidth).toString() + '×' +
              Math.round(this.surfaceHeight).toString() + ' / ' + this.geometryEpoch.toString()
          })
          this.metricLine({
            label: '请求 / 当前编码',
            value: (this.requestedEncoding === '' ? 'auto' : this.requestedEncoding.toUpperCase()) +
              ' / RAW'
          })
          this.metricLine({
            label: '请求 / 实际色深',
            value: this.vncRequestedColorDepth() + ' / ' +
              (this.diagnostics.effectiveColorDepth > 0 ?
                this.diagnostics.effectiveColorDepth.toString() + ' bit' : '待协商')
          })
          this.metricLine({
            label: '帧率上限',
            value: this.requestedFrameRate > 0 ?
              this.requestedFrameRate.toString() + ' FPS' : '无限制'
          })
          this.metricLine({
            label: '最后脏矩形',
            value: this.diagnostics.lastDirtyWidth > 0 && this.diagnostics.lastDirtyHeight > 0 ?
              this.diagnostics.lastDirtyX.toString() + ',' + this.diagnostics.lastDirtyY.toString() +
                ' ' + this.diagnostics.lastDirtyWidth.toString() + '×' +
                this.diagnostics.lastDirtyHeight.toString() : '完整帧'
          })
          this.metricLine({
            label: '输入提交 / 丢弃',
            value: this.diagnostics.inputEventsSent.toString() + ' / ' +
              this.diagnostics.inputEventsDropped.toString()
          })
          this.metricLine({
            label: '采样间隔',
            value: this.refreshMs.toString() + ' ms'
          })
        }
          }

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
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width(this.visiblePanelWidth())
    .height(this.visiblePanelHeight())
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
      .width(this.visiblePanelWidth())
        .position({ x: this.panelEffectiveX(), y: this.effectiveY() })
        .hitTestBehavior(HitTestMode.Default)
        .onAreaChange(this.overlayAreaChangeHandler(true))
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
      .onAreaChange(this.overlayAreaChangeHandler(false))
      .gesture(
        GestureGroup(GestureMode.Exclusive,
          TapGesture({ count: 1 }).onAction((): void => { this.onToggle(); }),
          PanGesture({ fingers: 1, distance: 5 })
            .onActionStart((_event: GestureEvent): void => {
              this.dragging = true;
              this.dragMoved = false;
              this.dragOffsetX = 0;
              this.dragOffsetY = 0;
            })
            .onActionUpdate((event: GestureEvent): void => {
              this.dragOffsetX = event.offsetX;
              this.dragOffsetY = event.offsetY;
              if (Math.sqrt(event.offsetX * event.offsetX + event.offsetY * event.offsetY) >=
                DRAG_COMMIT_THRESHOLD) {
                this.dragMoved = true;
              }
            })
            .onActionEnd((_event: GestureEvent): void => { this.finishDrag(false); })
            .onActionCancel((): void => { this.cancelDrag(); })
        )
      )
    }
  }
}
