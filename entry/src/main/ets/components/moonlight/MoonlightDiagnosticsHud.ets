import {
  MoonlightDiagnosticsSnapshot,
  moonlightMetric,
  moonlightMetricPairUs
} from '../../services/MoonlightUiPolicy';

const EMPTY_MOONLIGHT_DIAGNOSTICS: MoonlightDiagnosticsSnapshot = {
  available: false, fps: -1, latencyMs: -1, bitrateKbps: -1,
  packetLossPercent: -1, codec: '', width: 0, height: 0,
  decodeP50Us: -1, decodeP95Us: -1, renderP50Us: -1, renderP95Us: -1,
  audioUnderruns: -1, inputDrops: -1
};

@Component
export struct MoonlightDiagnosticsHud {
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @Prop snapshot: MoonlightDiagnosticsSnapshot = EMPTY_MOONLIGHT_DIAGNOSTICS;
  @Prop expanded: boolean = false;
  @Prop x: number = 18;
  @Prop y: number = 90;
  @State private offsetX: number = 0;
  @State private offsetY: number = 0;
  @State private dragging: boolean = false;
  onToggle: () => void = (): void => {};
  onPositionChange: (x: number, y: number) => void = (_x: number, _y: number): void => {};
  onCopySanitized: () => void = (): void => {};

  @Builder private metric(label: string, value: string) {
    Row() {
      Text(label).fontSize(10).fontColor('rgba(255,255,255,0.60)').layoutWeight(1)
      Text(value).fontSize(10).fontColor('#FFFFFF').fontFamily('monospace')
    }.width('100%').height(20)
  }

  build() {
    Column() {
      Row() {
        Text('Moonlight 性能').fontSize(11).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
        Blank().layoutWeight(1)
        Text(this.snapshot.available ? 'LIVE' : '—').fontSize(9).fontWeight(FontWeight.Bold)
          .fontColor(this.snapshot.available ? this.accentColor : 'rgba(255,255,255,0.45)')
        SymbolGlyph(this.expanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(14).fontColor(['#FFFFFF']).margin({ left: 6 })
      }.width('100%').height(24).onClick((): void => { if (!this.dragging) { this.onToggle(); } })

      Row() {
        Text(moonlightMetric(this.snapshot.fps, ' FPS')).fontSize(12).fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF').fontFamily('monospace')
        Text(' · ').fontSize(12).fontColor('rgba(255,255,255,0.45)')
        Text(moonlightMetric(this.snapshot.latencyMs, ' ms')).fontSize(12)
          .fontColor('#FFFFFF').fontFamily('monospace')
      }.width('100%').margin({ top: 2, bottom: this.expanded ? 6 : 0 })

      if (this.expanded) {
        this.metric('码率', moonlightMetric(this.snapshot.bitrateKbps, ' Kbps'))
        this.metric('丢包', moonlightMetric(this.snapshot.packetLossPercent, '%', 2))
        this.metric('编码', this.snapshot.codec === '' ? '—' : this.snapshot.codec)
        this.metric('画面', this.snapshot.width > 0 && this.snapshot.height > 0 ?
          this.snapshot.width.toString() + ' × ' + this.snapshot.height.toString() : '—')
        this.metric('解码 p50 / p95', moonlightMetricPairUs(
          this.snapshot.decodeP50Us, this.snapshot.decodeP95Us))
        this.metric('渲染 p50 / p95', moonlightMetricPairUs(
          this.snapshot.renderP50Us, this.snapshot.renderP95Us))
        this.metric('音频 underrun', moonlightMetric(this.snapshot.audioUnderruns, ''))
        this.metric('输入丢弃', moonlightMetric(this.snapshot.inputDrops, ''))
        Button('复制脱敏诊断').height(32).width('100%').fontSize(11).borderRadius(9)
          .backgroundColor('rgba(255,255,255,0.10)').fontColor('#FFFFFF').margin({ top: 8 })
          .onClick((): void => { this.onCopySanitized(); })
      }
    }
    .width(this.expanded ? 264 : 150).padding(12)
    .backgroundColor('rgba(14,18,28,0.82)').borderRadius(15)
    .border({ width: 1, color: this.expanded ? this.accentColor + '80' : 'rgba(255,255,255,0.16)' })
    .position({ x: this.x + this.offsetX, y: this.y + this.offsetY })
    .gesture(PanGesture({ fingers: 1, distance: 5 })
      .onActionStart((): void => { this.dragging = true; this.offsetX = 0; this.offsetY = 0; })
      .onActionUpdate((event: GestureEvent): void => {
        this.offsetX = event.offsetX; this.offsetY = event.offsetY;
      })
      .onActionEnd((): void => {
        const nextX: number = this.x + this.offsetX;
        const nextY: number = this.y + this.offsetY;
        this.dragging = false; this.offsetX = 0; this.offsetY = 0;
        this.onPositionChange(nextX, nextY);
      })
      .onActionCancel((): void => {
        this.dragging = false; this.offsetX = 0; this.offsetY = 0;
      }))
    .accessibilityGroup(true)
  }
}
