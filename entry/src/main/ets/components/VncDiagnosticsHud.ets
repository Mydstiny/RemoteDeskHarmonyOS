import { RustDeskDiagnosticsSnapshot } from '../types/rdpnapi';

const VNC_EMPTY_DIAGNOSTICS: RustDeskDiagnosticsSnapshot = {
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
  decoderBackend: '等待服务器'
};

const VNC_DIAGNOSTICS_DRAG_THRESHOLD: number = 5;

interface VncDiagnosticMetric {
  label: string;
  value: string;
}

function formatRate(value: number, available: boolean): string {
  return available && Number.isFinite(value) ? value.toFixed(1) : '—';
}

function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) { return '0 B'; }
  if (bytes >= 1024 * 1024 * 1024) { return (bytes / (1024 * 1024 * 1024)).toFixed(1) + ' GB'; }
  if (bytes >= 1024 * 1024) { return (bytes / (1024 * 1024)).toFixed(1) + ' MB'; }
  if (bytes >= 1024) { return (bytes / 1024).toFixed(1) + ' KB'; }
  return Math.round(bytes).toString() + ' B';
}

@Component
export struct VncDiagnosticsHud {
  @Prop diagnostics: RustDeskDiagnosticsSnapshot = VNC_EMPTY_DIAGNOSTICS;
  @Prop geometryEpoch: number = 0;
  @Prop surfaceWidth: number = 0;
  @Prop surfaceHeight: number = 0;
  @Prop refreshMs: number = 500;
  @Prop requestedEncoding: string = 'auto';
  @Prop requestedColorDepth: string = 'auto';
  @Prop requestedFrameRate: number = 30;
  @Prop metricMask: number = 63;
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

  private presentationState(): string {
    if (!this.diagnostics.sessionActive) { return '会话未激活'; }
    if (!this.diagnostics.videoSeen) { return '等待服务器首帧'; }
    const staleMs: number = Math.max(3000, this.refreshMs * 6);
    if (this.diagnostics.lastFrameAgeMs >= staleMs) { return '服务器更新停滞'; }
    if (this.diagnostics.presentedFrames === 0) {
      return this.diagnostics.presentationRejected > 0 ? '画布拒绝首帧' : '等待首帧送显';
    }
    if (this.diagnostics.lastPresentedFrameAgeMs >= staleMs) {
      return this.diagnostics.presentationRejected > 0 ? '画布送显受阻' : '送显链路停滞';
    }
    return '画面持续更新';
  }

  private connectionPath(): string {
    if (this.diagnostics.connectionPath === 'direct') { return 'TCP 直连'; }
    if (this.diagnostics.connectionPath === 'repeater') { return 'UltraVNC Repeater'; }
    return '未知';
  }

  private requestedDepth(): string {
    const value: string = this.diagnostics.requestedColorDepth !== '' ?
      this.diagnostics.requestedColorDepth : this.requestedColorDepth;
    return value === '' || value === 'auto' ? '自动' : value + ' bit';
  }

  private effectiveEncoding(): string {
    const value: string = this.diagnostics.decoderBackend.trim();
    return value === '' || value === 'raw-frame' ? 'RAW' : value;
  }

  private effectiveHandleX(): number {
    return this.handleX + this.dragOffsetX;
  }

  private effectivePanelX(): number {
    return this.panelX + this.dragOffsetX;
  }

  private effectiveY(): number {
    return this.panelY + this.dragOffsetY;
  }

  private dockBackground(): string {
    return this.dragging ? 'rgba(12,16,24,0.92)' : 'rgba(12,16,24,0.80)';
  }

  private dockBorder(): string {
    return this.expanded ? this.accentColor + '80' : 'rgba(255,255,255,0.18)';
  }

  private finishDrag(fromPanel: boolean): void {
    const x: number = fromPanel ? this.effectivePanelX() : this.effectiveHandleX();
    const y: number = this.effectiveY();
    const moved: boolean = this.dragMoved;
    this.dragging = false;
    this.dragMoved = false;
    this.dragOffsetX = 0;
    this.dragOffsetY = 0;
    if (moved) {
      this.onPositionChange(x, y, fromPanel);
    }
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
    const x: number = fromPanel ? this.effectivePanelX() : this.effectiveHandleX();
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
  private metric(metric: VncDiagnosticMetric) {
    Row() {
      Text(metric.label).fontSize(10).fontColor('rgba(255,255,255,0.62)').layoutWeight(1)
      Text(metric.value).fontSize(10).fontColor('#FFFFFF').fontFamily('monospace')
    }.width('100%').height(19)
  }

  @Builder
  private panel() {
    Column() {
      Row() {
        Text('VNC 性能监视').fontSize(11).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
        Blank().layoutWeight(1)
        Text(this.effectiveEncoding()).fontSize(9).fontColor(this.accentColor)
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
              this.dragMoved = false;
              this.dragOffsetX = 0;
              this.dragOffsetY = 0;
            })
            .onActionUpdate((event: GestureEvent): void => {
              this.dragOffsetX = event.offsetX;
              this.dragOffsetY = event.offsetY;
              if (Math.sqrt(event.offsetX * event.offsetX + event.offsetY * event.offsetY) >=
                VNC_DIAGNOSTICS_DRAG_THRESHOLD) {
                this.dragMoved = true;
              }
            })
            .onActionEnd((_event: GestureEvent): void => { this.finishDrag(true); })
            .onActionCancel((): void => { this.cancelDrag(); })
        )
      )

      this.metric({ label: '状态', value: this.presentationState() })
      this.metric({
        label: '接收 / 送显',
        value: formatRate(this.diagnostics.receivedFps, this.diagnostics.receivedRateAvailable) +
          ' / ' + formatRate(this.diagnostics.displayFps, this.diagnostics.presentedRateAvailable) + ' FPS'
      })
      this.metric({
        label: '帧缓冲',
        value: (this.diagnostics.width > 0 ? this.diagnostics.width.toString() : '—') + ' × ' +
          (this.diagnostics.height > 0 ? this.diagnostics.height.toString() : '—')
      })
      this.metric({ label: '连接路径', value: this.connectionPath() })
      this.metric({
        label: '请求 / 当前编码',
        value: this.requestedEncoding.toUpperCase() + ' / ' + this.effectiveEncoding()
      })
      this.metric({
        label: '请求 / 实际色深',
        value: this.requestedDepth() + ' / ' +
          (this.diagnostics.effectiveColorDepth > 0 ?
            this.diagnostics.effectiveColorDepth.toString() + ' bit' : '待协商')
      })
      this.metric({
        label: '帧率上限',
        value: this.requestedFrameRate > 0 ?
          this.requestedFrameRate.toString() + ' FPS' : '无限制'
      })
      this.metric({
        label: '接收 / 送显总帧',
        value: this.diagnostics.receivedFrames.toString() + ' / ' +
          this.diagnostics.presentedFrames.toString()
      })
      this.metric({ label: '帧缓冲处理量', value: formatBytes(this.diagnostics.receivedBytes) })
      this.metric({
        label: '服务器帧距今',
        value: this.diagnostics.lastFrameAgeMs >= 0 ?
          this.diagnostics.lastFrameAgeMs.toString() + ' ms' : '尚无画面'
      })
      this.metric({
        label: '成功送显距今',
        value: this.diagnostics.lastPresentedFrameAgeMs >= 0 ?
          this.diagnostics.lastPresentedFrameAgeMs.toString() + ' ms' : '尚未送显'
      })
      this.metric({
        label: '送显拒绝',
        value: this.diagnostics.presentationRejected.toString()
      })
      if ((this.metricMask & 32) !== 0) {
        Divider().color('rgba(255,255,255,0.18)').margin({ top: 3, bottom: 3 })
        this.metric({
          label: '本地画布 / 几何代',
          value: Math.round(this.surfaceWidth).toString() + '×' +
            Math.round(this.surfaceHeight).toString() + ' / ' + this.geometryEpoch.toString()
        })
        this.metric({
          label: '最后脏矩形',
          value: this.diagnostics.lastDirtyWidth > 0 && this.diagnostics.lastDirtyHeight > 0 ?
            this.diagnostics.lastDirtyX.toString() + ',' + this.diagnostics.lastDirtyY.toString() +
              ' ' + this.diagnostics.lastDirtyWidth.toString() + '×' +
              this.diagnostics.lastDirtyHeight.toString() : '完整帧'
        })
        this.metric({
          label: '输入提交 / 丢弃',
          value: this.diagnostics.inputEventsSent.toString() + ' / ' +
            this.diagnostics.inputEventsDropped.toString()
        })
        this.metric({ label: '采样间隔', value: this.refreshMs.toString() + ' ms' })
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
        this.panel()
      }
      .width(270)
      .position({ x: this.effectivePanelX(), y: this.effectiveY() })
      .hitTestBehavior(HitTestMode.Default)
      .onAreaChange(this.overlayAreaChangeHandler(true))
    } else {
      Row() {
        Text('VNC').fontSize(9).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          .width(28).textAlign(TextAlign.Center)
        Text(this.diagnostics.receivedRateAvailable ? this.diagnostics.receivedFps.toFixed(0) : '…')
          .fontSize(10).fontColor(this.accentColor).fontFamily('monospace')
          .width(48).textAlign(TextAlign.Center)
      }
      .height(38).width(76).borderRadius(12)
      .backgroundColor(this.dockBackground())
      .border({ width: 1, color: this.dockBorder() })
      .shadow({ radius: 8, color: 'rgba(0,0,0,0.30)', offsetY: 2 })
      .position({ x: this.effectiveHandleX(), y: this.effectiveY() })
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
                VNC_DIAGNOSTICS_DRAG_THRESHOLD) {
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
