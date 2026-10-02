import { DiagnosticAiOrbState } from '../../services/diagnosticAi/DiagnosticAiModels';

/** System AI gradient colors (ai_intelligent_gradient_color1–4). */
const AI_ORB_COLORS: Array<[ResourceColor, number]> = [
  ['#42CBF7', 0], ['#2A7DFF', 0.3], ['#A479FF', 0.6], ['#FF678C', 0.85], ['#42CBF7', 1]
];

/** The turning gradient disc; mounted only while the assistant works, so it always starts from rest. */
@Component
struct DiagnosticAiOrbSpin {
  @Prop discSize: number = 36;
  @State private angle: number = 0;

  aboutToAppear(): void {
    setTimeout((): void => {
      this.getUIContext().animateTo({ duration: 2400, iterations: -1, curve: Curve.Linear,
        expectedFrameRateRange: { min: 30, max: 60, expected: 60 } }, (): void => { this.angle = 360; });
    }, 16);
  }

  build() {
    Circle().width(this.discSize).height(this.discSize).fill(Color.Transparent)
      .sweepGradient({ center: ['50%', '50%'], colors: AI_ORB_COLORS })
      .borderRadius(this.discSize / 2).rotate({ angle: this.angle })
  }
}

/**
 * Entry to 启动 AI 辅助 at the right end of the 远程主机 title row: a disc in the system AI gradient with the system
 * 智能 symbol. While a capture or an analysis runs, the gradient turns. Uses only public system symbols and colors.
 */
@Component
export struct DiagnosticAiOrb {
  @Prop visible: boolean = false;
  @Prop state: DiagnosticAiOrbState = 'idle';
  @Prop reducedMotion: boolean = false;
  onOpen: () => void = (): void => {};

  private label(): string {
    if (this.state === 'capturing') { return '诊断抓取中，打开启动 AI 辅助'; }
    if (this.state === 'thinking') { return 'AI 分析中，打开启动 AI 辅助'; }
    if (this.state === 'error') { return 'AI 诊断出错，打开启动 AI 辅助'; }
    return '启动 AI 辅助';
  }
  private working(): boolean { return !this.reducedMotion && (this.state === 'capturing' || this.state === 'thinking'); }

  build() {
    if (this.visible) {
      Stack() {
        if (this.working()) {
          DiagnosticAiOrbSpin({ discSize: 38 })
        } else {
          Circle().width(38).height(38).fill(Color.Transparent)
            .sweepGradient({ center: ['50%', '50%'], colors: AI_ORB_COLORS }).borderRadius(19)
        }
        // Soft white sheen over the top half, like the system assistant's glassy disc.
        Column().width(38).height(19).position({ x: 0, y: 0 })
          .borderRadius({ topLeft: 19, topRight: 19 })
          .linearGradient({ angle: 180, colors: [['#40FFFFFF', 0], ['#00FFFFFF', 1]] })
        SymbolGlyph($r('sys.symbol.intelligent')).fontSize(20).fontColor([Color.White])
      }
      .width(38).height(38).borderRadius(19).clip(true)
      .shadow({ radius: 14, color: '#552A7DFF', offsetY: 4 })
      .responseRegion({ x: -5, y: -5, width: 48, height: 48 })
      .accessibilityText(this.label())
      .onClick((): void => { this.onOpen(); })
    }
  }
}
