import {
  MoonlightDiagnosticsSnapshot,
  moonlightMetric,
  moonlightMetricPairUs
} from '../../services/MoonlightUiPolicy';

const EMPTY_MOONLIGHT_DIAGNOSTICS: MoonlightDiagnosticsSnapshot = {
  available: false, transportReady: false, videoReady: false, audioReady: false,
  inputReady: false, fps: -1, latencyMs: -1, bitrateKbps: -1,
  configuredBitrateKbps: -1, packetLossPercent: -1, codec: '', width: 0, height: 0,
  targetFps: -1, acceptedVideoFrames: 0, droppedVideoFrames: 0,
  decoderQueueDepth: -1,
  decodeP50Us: -1, decodeP95Us: -1, renderP50Us: -1, renderP95Us: -1,
  codecLatencyMs: -1, codecLatencyMaxMs: -1, surfaceUpdateFailures: 0,
  surfaceCoalescedNotifications: 0, acceptedAudioPackets: 0,
  rejectedAudioPackets: 0, audioBytes: 0, audioUnderruns: -1,
  inputAccepted: 0, inputDrops: -1, presentedFrames: 0, videoBytes: 0,
  ingressAgeMs: -1, presentationAgeMs: -1, stalled: false
};

@Component
export struct MoonlightDiagnosticsHud {
  @Prop snapshot: MoonlightDiagnosticsSnapshot = EMPTY_MOONLIGHT_DIAGNOSTICS;
  @Prop sampleEpoch: number = 0;
  @Prop @Watch('onExternalGeometryChange') expanded: boolean = false;
  @Prop @Watch('onExternalGeometryChange') x: number = 18;
  @Prop @Watch('onExternalGeometryChange') y: number = 18;
  @Prop @Watch('onExternalGeometryChange') viewportWidth: number = 360;
  @Prop @Watch('onExternalGeometryChange') viewportHeight: number = 640;
  @State private panelX: number = 18;
  @State private panelY: number = 18;
  @State private dragOffsetX: number = 0;
  @State private dragOffsetY: number = 0;
  @State private dragging: boolean = false;
  private dragAnchorX: number = 18;
  private dragAnchorY: number = 18;
  onToggle: () => void = (): void => {};
  onPositionChange: (x: number, y: number) => void = (_x: number, _y: number): void => {};
  onCopySanitized: () => void = (): void => {};

  aboutToAppear(): void {
    this.panelX = this.clampX(this.x);
    this.panelY = this.clampY(this.y);
  }

  private panelWidth(): number {
    return this.expanded ? 320 : 150;
  }

  private clampX(value: number): number {
    const minimumVisible: number = 64;
    const minimum: number = Math.min(8, -this.panelWidth() + minimumVisible);
    const maximum: number = Math.max(8, this.viewportWidth - minimumVisible);
    return Math.max(minimum, Math.min(maximum, value));
  }

  private clampY(value: number): number {
    // Only the title bar must remain on-screen. The expanded metrics may move
    // outside the viewport so a landscape phone is not artificially limited
    // to a tiny vertical drag range, while the panel can always be recovered.
    const maximum: number = Math.max(8, this.viewportHeight - 36);
    return Math.max(8, Math.min(maximum, value));
  }

  private onExternalGeometryChange(): void {
    if (this.dragging) { return; }
    this.dragOffsetX = 0;
    this.dragOffsetY = 0;
    this.panelX = this.clampX(this.x);
    this.panelY = this.clampY(this.y);
  }

  private finishDrag(): void {
    this.panelX = this.clampX(this.dragAnchorX + this.dragOffsetX);
    this.panelY = this.clampY(this.dragAnchorY + this.dragOffsetY);
    this.dragOffsetX = 0;
    this.dragOffsetY = 0;
    this.dragging = false;
    this.onPositionChange(this.panelX, this.panelY);
  }

  private beginDrag(): void {
    this.dragging = true;
    this.dragAnchorX = this.panelX;
    this.dragAnchorY = this.panelY;
    this.dragOffsetX = 0;
    this.dragOffsetY = 0;
  }

  private updateDrag(event: GestureEvent): void {
    // Keep the recognizer's layout origin fixed while rendering the movement
    // as a transform. Repositioning during recognition moves the local
    // gesture space under the finger and causes jitter.
    this.dragOffsetX = this.clampX(this.dragAnchorX + event.offsetX) -
      this.dragAnchorX;
    this.dragOffsetY = this.clampY(this.dragAnchorY + event.offsetY) -
      this.dragAnchorY;
  }

  private cancelDrag(): void {
    this.dragOffsetX = 0;
    this.dragOffsetY = 0;
    this.dragging = false;
  }

  private statusLabel(): string {
    if (!this.reactiveSnapshot().available) { return '等待'; }
    return this.reactiveSnapshot().stalled ? '卡帧' : '实时';
  }

  private statusColor(): string {
    if (!this.reactiveSnapshot().available) { return 'rgba(255,255,255,0.45)'; }
    return this.reactiveSnapshot().stalled ? '#FF6B6B' : '#66DD7A';
  }

  private reactiveSnapshot(): MoonlightDiagnosticsSnapshot {
    // Reading the primitive epoch makes every metric update function depend on
    // the current sample, even if this platform revision does not invalidate a
    // child for an interface-typed object replacement alone.
    if (this.sampleEpoch < 0) { return EMPTY_MOONLIGHT_DIAGNOSTICS; }
    return this.snapshot;
  }

  @Builder private metric(label: string, value: string) {
    Row() {
      Text(label).fontSize(10).fontColor('rgba(255,255,255,0.60)').layoutWeight(1)
      Text(value).fontSize(10).fontColor('#FFFFFF').fontFamily('monospace')
    }.width('100%').height(20)
  }

  @Builder private readiness(label: string, ready: boolean) {
    Row({ space: 4 }) {
      Column().width(6).height(6).borderRadius(3)
        .backgroundColor(ready ? '#66DD7A' : 'rgba(255,255,255,0.24)')
      Text(label).fontSize(9)
        .fontColor(ready ? 'rgba(255,255,255,0.86)' : 'rgba(255,255,255,0.42)')
    }
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('Moonlight 性能').fontSize(11).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
          Blank().layoutWeight(1)
          Text(this.statusLabel()).fontSize(9).fontWeight(FontWeight.Bold)
            .fontColor(this.statusColor())
          SymbolGlyph(this.expanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
            .fontSize(14).fontColor(['#FFFFFF']).margin({ left: 6 })
        }
        .width('100%').height(24)
        .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
        // A tap expands/collapses; a drag moves the HUD. Keeping both
        // recognizers on the title itself avoids the child tap recognizer
        // starving the parent pan recognizer on API 23.
        .gesture(
          GestureGroup(GestureMode.Exclusive,
            TapGesture({ count: 1 }).onAction((): void => { this.onToggle(); }),
            PanGesture({ fingers: 1, direction: PanDirection.All, distance: 3 })
              .onActionStart((_event: GestureEvent): void => { this.beginDrag(); })
              .onActionUpdate((event: GestureEvent): void => { this.updateDrag(event); })
              .onActionEnd((_event: GestureEvent): void => { this.finishDrag(); })
              .onActionCancel((): void => { this.cancelDrag(); })
          )
        )

        Row() {
          Text(moonlightMetric(this.reactiveSnapshot().fps, ' FPS')).fontSize(12).fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF').fontFamily('monospace')
          Text(' · ').fontSize(12).fontColor('rgba(255,255,255,0.45)')
          Text(moonlightMetric(this.reactiveSnapshot().latencyMs, ' ms')).fontSize(12)
            .fontColor('#FFFFFF').fontFamily('monospace')
        }.width('100%').margin({ top: 2, bottom: this.expanded ? 6 : 0 })

        if (this.expanded) {
          Row({ space: 10 }) {
            this.readiness('网络', this.reactiveSnapshot().transportReady)
            this.readiness('视频', this.reactiveSnapshot().videoReady)
            this.readiness('音频', this.reactiveSnapshot().audioReady)
            this.readiness('输入', this.reactiveSnapshot().inputReady)
          }.width('100%').margin({ bottom: 6 })
          this.metric('实时 VBR / 请求上限', moonlightMetric(this.reactiveSnapshot().bitrateKbps, ' Kbps') + ' / ' +
            moonlightMetric(this.reactiveSnapshot().configuredBitrateKbps, ' Kbps'))
          this.metric('视频丢帧率', moonlightMetric(this.reactiveSnapshot().packetLossPercent, '%', 2))
          this.metric('编码', this.reactiveSnapshot().codec === '' ? '—' : this.reactiveSnapshot().codec)
          this.metric('画面', this.reactiveSnapshot().width > 0 && this.reactiveSnapshot().height > 0 ?
            this.reactiveSnapshot().width.toString() + ' × ' + this.reactiveSnapshot().height.toString() + ' @ ' +
              moonlightMetric(this.reactiveSnapshot().targetFps, ' FPS') : '—')
          this.metric('视频接收 / 丢弃', this.reactiveSnapshot().acceptedVideoFrames.toString() + ' / ' +
            this.reactiveSnapshot().droppedVideoFrames.toString())
          this.metric('解码队列', moonlightMetric(this.reactiveSnapshot().decoderQueueDepth, ''))
          this.metric('解码延迟 / 峰值', moonlightMetric(this.reactiveSnapshot().codecLatencyMs, ' ms') + ' / ' +
            moonlightMetric(this.reactiveSnapshot().codecLatencyMaxMs, ' ms'))
          this.metric('解码 p50 / p95', moonlightMetricPairUs(
            this.reactiveSnapshot().decodeP50Us, this.reactiveSnapshot().decodeP95Us))
          this.metric('渲染 p50 / p95', moonlightMetricPairUs(
            this.reactiveSnapshot().renderP50Us, this.reactiveSnapshot().renderP95Us))
          this.metric('Surface 无缓冲 / 合并', this.reactiveSnapshot().surfaceUpdateFailures.toString() + ' / ' +
            this.reactiveSnapshot().surfaceCoalescedNotifications.toString())
          this.metric('画面推进距今', moonlightMetric(this.reactiveSnapshot().presentationAgeMs, ' ms'))
          this.metric('码流推进距今', moonlightMetric(this.reactiveSnapshot().ingressAgeMs, ' ms'))
          this.metric('音频接收 / 拒绝', this.reactiveSnapshot().acceptedAudioPackets.toString() + ' / ' +
            this.reactiveSnapshot().rejectedAudioPackets.toString())
          this.metric('音频 underrun', moonlightMetric(this.reactiveSnapshot().audioUnderruns, ''))
          this.metric('输入接收 / 拒绝', this.reactiveSnapshot().inputAccepted.toString() + ' / ' +
            moonlightMetric(this.reactiveSnapshot().inputDrops, ''))
          this.metric('已呈现帧', this.reactiveSnapshot().presentedFrames.toString())
          this.metric('接收视频字节', this.reactiveSnapshot().videoBytes.toString())
          Button('复制脱敏诊断').height(32).width('100%').fontSize(11).borderRadius(9)
            .backgroundColor('rgba(255,255,255,0.10)').fontColor('#FFFFFF').margin({ top: 8 })
            .onClick((): void => { this.onCopySanitized(); })
        }
      }
      .width(this.panelWidth()).padding(12)
      .backgroundColor('rgba(14,18,28,0.82)').borderRadius(15)
      .border({ width: 1, color: this.expanded ? 'rgba(91,143,249,0.66)' : 'rgba(255,255,255,0.16)' })
      .position({ x: this.panelX, y: this.panelY })
      .translate({ x: this.dragOffsetX, y: this.dragOffsetY })
      .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
      // The collapsed HUD is mostly its FPS row. Keeping the pan recognizer on
      // the title alone left less than half of the visible card draggable and
      // made a body drag fall through to the stream input surface. The whole
      // card is the drag target; the title tap above remains the expand toggle.
      .priorityGesture(
        PanGesture({ fingers: 1, direction: PanDirection.All, distance: 3 })
          .onActionStart((_event: GestureEvent): void => { this.beginDrag(); })
          .onActionUpdate((event: GestureEvent): void => { this.updateDrag(event); })
          .onActionEnd((_event: GestureEvent): void => { this.finishDrag(); })
          .onActionCancel((): void => { this.cancelDrag(); })
      )
      .accessibilityGroup(true)
      .accessibilityText('Moonlight 性能监控，' + this.statusLabel() + '，' +
        moonlightMetric(this.reactiveSnapshot().fps, ' FPS'))
    }
    .width('100%').height('100%').backgroundColor(Color.Transparent)
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
