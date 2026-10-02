import { DiagnosticAiOrbState } from '../../services/diagnosticAi/DiagnosticAiModels';
import { AiSystemAgentButton } from './XiaoyiOrb';

/**
 * Entry to 启动 AI 辅助 at the right end of the 远程主机 title row: the 小艺 orb with its immersive light, as in the AI
 * island. It breathes at rest and glows brighter
 * while a capture or an analysis runs.
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
  private working(): boolean { return this.state === 'capturing' || this.state === 'thinking'; }

  build() {
    if (this.visible) {
      Stack() {
        AiSystemAgentButton({ buttonSize: 34, active: this.working() })
      }
      .width(40).height(40)
      .responseRegion({ x: -4, y: -4, width: 48, height: 48 })
      .accessibilityText(this.label())
      .onClick((): void => { this.onOpen(); })
    }
  }
}
