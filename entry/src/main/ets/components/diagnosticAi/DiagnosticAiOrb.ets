import { AppConfig, Palette, buildDark, buildLight } from '../../common/Theme';
import { AppUiMetrics } from '../../common/AppUiMetrics';
import { DiagnosticAiOrbState } from '../../services/diagnosticAi/DiagnosticAiModels';

@Component
export struct DiagnosticAiOrb {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop visible: boolean = false;
  @Prop state: DiagnosticAiOrbState = 'idle';
  @Prop reducedMotion: boolean = false;
  onOpen: () => void = (): void => {};

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private label(): string {
    if (this.state === 'capturing') { return '诊断抓取中'; }
    if (this.state === 'thinking') { return 'AI 分析中'; }
    if (this.state === 'error') { return 'AI 诊断错误'; }
    return '诊断与 AI 帮助';
  }

  build() {
    Row() {
      if (this.visible) {
        Button() {
          Stack({ alignContent: Alignment.Center }) {
            Circle().width(32).height(32).fill(this.accent)
              .rotate({ angle: this.reducedMotion ? 0 : (this.state === 'thinking' ? 360 : 0) })
              .animation({ duration: this.reducedMotion ? 0 : 1400, curve: Curve.Linear, iterations: -1 })
            SymbolGlyph($r('sys.symbol.info_circle')).fontSize(20).fontColor([Color.White])
          }.width(42).height(42)
        }
        .width(AppUiMetrics.minTouchTarget).height(AppUiMetrics.minTouchTarget).padding(0)
        .backgroundColor(this.pal().card).borderRadius(22)
        .border({ width: 1, color: this.accent }).shadow({ radius: 12, color: 'rgba(0,0,0,0.18)', offsetY: 4 })
        .accessibilityText(this.label()).onClick((): void => { this.onOpen(); })
      }
    }.width('100%').height(AppUiMetrics.minTouchTarget)
  }
}
