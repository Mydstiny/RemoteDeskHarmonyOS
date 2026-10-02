import { DiagnosticAiOrbState } from '../../services/diagnosticAi/DiagnosticAiModels';
import { AiLiquidGlassButton } from './AiIslandChrome';

/**
 * Entry to 启动 AI 辅助 at the right end of the 远程主机 title row: a liquid-glass (沉浸光感) round button with the
 * assistant's looping light glyph. The glyph turns and the glass glows while a capture or an analysis runs.
 */
@Component
export struct DiagnosticAiOrb {
  @Prop visible: boolean = false;
  @Prop state: DiagnosticAiOrbState = 'idle';
  @Prop reducedMotion: boolean = false;
  @StorageProp('currentTheme') theme: string = 'light';
  onOpen: () => void = (): void => {};

  private label(): string {
    if (this.state === 'capturing') { return '诊断抓取中，打开启动 AI 辅助'; }
    if (this.state === 'thinking') { return 'AI 分析中，打开启动 AI 辅助'; }
    if (this.state === 'error') { return 'AI 诊断出错，打开启动 AI 辅助'; }
    return '启动 AI 辅助';
  }
  private working(): boolean { return this.state === 'capturing' || this.state === 'thinking'; }

  build() {
    if (this.visible) {
      Stack() {
        AiLiquidGlassButton({ buttonSize: 36, dark: this.theme === 'dark', active: this.working() })
      }
      .width(40).height(40)
      .responseRegion({ x: -4, y: -4, width: 48, height: 48 })
      .accessibilityText(this.label())
      .onClick((): void => { this.onOpen(); })
    }
  }
}
