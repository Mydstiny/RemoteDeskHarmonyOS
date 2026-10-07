import { curves } from '@kit.ArkUI';
import { DiagnosticAiOrbState } from '../../services/diagnosticAi/DiagnosticAiModels';
import { AiLiquidGlassButton } from './AiIslandChrome';
import { AI_VOICE_HOLD } from '../../services/diagnosticAi/AiVoiceSettings';

/** AppStorage: 按住说话 presses ('down:<time>' / 'up:<time>'); AiVoiceIsland listens while it is held. */
const AI_VOICE_HOLD_EVENT: string = 'aiVoice.hold';

/**
 * Entry to 启动 AI 辅助 at the right end of the 远程主机 title row: a liquid-glass (沉浸光感) round button with the
 * assistant's looping light glyph. The glyph turns and the glass glows while a capture or an analysis runs.
 */
@Component
export struct DiagnosticAiOrb {
  @Prop visible: boolean = false;
  @Prop state: DiagnosticAiOrbState = 'idle';
  @Prop reducedMotion: boolean = false;
  @StorageProp('diagnosticAiReducedMotion') storedReducedMotion: boolean = false;
  @StorageProp('currentTheme') theme: string = 'light';
  /** AI 语音 (Beta) › 按住 AI 按钮说话 is on. */
  @StorageProp(AI_VOICE_HOLD) holdToTalk: boolean = false;
  @State private held: boolean = false;
  onOpen: () => void = (): void => {};

  private label(): string {
    if (this.state === 'capturing') { return '诊断抓取中，打开启动 AI 辅助'; }
    if (this.state === 'thinking') { return 'AI 分析中，打开启动 AI 辅助'; }
    if (this.state === 'error') { return 'AI 诊断出错，打开启动 AI 辅助'; }
    return '启动 AI 辅助';
  }
  private working(): boolean { return this.state === 'capturing' || this.state === 'thinking'; }

  private release(): void {
    if (!this.held) { return; }
    this.held = false;
    AppStorage.setOrCreate(AI_VOICE_HOLD_EVENT, 'up:' + Date.now().toString());
  }

  build() {
    if (this.visible) {
      Stack() {
        // Dark mode: the glass sits on the host list's own black (the page background there), so it looks the same
        // on every page instead of taking on whatever each page has behind its title.
        if (this.theme === 'dark') {
          Column().width(36).height(36).borderRadius(18).backgroundColor('#000000')
        }
        AiLiquidGlassButton({ buttonSize: 36, dark: this.theme === 'dark', active: this.working(),
          reducedMotion: this.reducedMotion || this.storedReducedMotion })
      }
      .width(40).height(40)
      .scale({ x: this.held ? 1.18 : 1, y: this.held ? 1.18 : 1 })
      .animation({ curve: curves.springMotion(0.35, 0.65) })
      .responseRegion({ x: -4, y: -4, width: 48, height: 48 })
      .accessibilityText(this.label())
      .onClick((): void => { this.onOpen(); })
      // 按住说话: hold to talk, let go to send.
      .gesture(LongPressGesture({ duration: 380 })
        .onAction((): void => {
          if (!this.holdToTalk) { return; }
          this.held = true;
          AppStorage.setOrCreate(AI_VOICE_HOLD_EVENT, 'down:' + Date.now().toString());
        })
        .onActionEnd((): void => { this.release(); })
        .onActionCancel((): void => { this.release(); }))
    }
  }
}
