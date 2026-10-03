import { AppConfig, Palette, buildDark, buildLight } from '../../common/Theme';
import { AI_MOTION_DONE, AI_MOTION_KINDS, AI_MOTION_OPEN, AI_MOTION_ORB, AI_MOTION_SEND_GLOW, AI_MOTION_SPEED,
  AI_MOTION_THINKING, AiMotionKind, AiMotionOption, DiagnosticAiMotionStore } from '../../services/diagnosticAi/DiagnosticAiMotionPolicy';
import { AiDoneMark, AiFloatingOrb, AiIslandRingsCheck, AiOpenPreview, AiThinkingIndicator } from './AiMotionViews';
import { AiSendButton } from './AiIslandChrome';

/**
 * AI 动效: one section per kind of motion, its styles side by side as small dark tiles that play the motion live.
 * A tap applies the style everywhere at once (and keeps it on this device). Done animations play once, so their
 * previews replay every few seconds.
 */
@Component
export struct AiMotionSettingsPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @StorageProp('diagnosticAiReducedMotion') reduced: boolean = false;
  @StorageProp(AI_MOTION_THINKING) thinking: string = 'dots';
  @StorageProp(AI_MOTION_ORB) orb: string = 'voice';
  @StorageProp(AI_MOTION_DONE) done: string = 'check';
  @StorageProp(AI_MOTION_OPEN) open: string = 'morph';
  @StorageProp(AI_MOTION_SEND_GLOW) sendGlow: string = 'flow';
  @StorageProp(AI_MOTION_SPEED) speed: string = 'normal';
  /** Flips to remount the done previews so they play again. */
  @State private replay: boolean = true;
  private replayTimer: number = -1;

  aboutToAppear(): void {
    this.replayTimer = setInterval((): void => {
      this.replay = false;
      setTimeout((): void => { this.replay = true; }, 60);
    }, 2600);
  }

  aboutToDisappear(): void {
    if (this.replayTimer !== -1) { clearInterval(this.replayTimer); this.replayTimer = -1; }
  }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }

  private current(key: string): string {
    if (key === AI_MOTION_THINKING) { return this.thinking; }
    if (key === AI_MOTION_ORB) { return this.orb; }
    if (key === AI_MOTION_DONE) { return this.done; }
    if (key === AI_MOTION_OPEN) { return this.open; }
    if (key === AI_MOTION_SEND_GLOW) { return this.sendGlow; }
    return this.speed;
  }

  private choose(key: string, id: string): void {
    DiagnosticAiMotionStore.save(getContext(this), key, id);
  }

  /**
   * Only the selected style of each kind plays; the others show a still frame. Two dozen live canvases at once
   * overloaded the render pipeline on phones (UI→render IPC blocked for seconds), so live is one per kind.
   */
  @Builder private preview(key: string, id: string, live: boolean) {
    if (key === AI_MOTION_THINKING) {
      AiThinkingIndicator({ indicatorSize: 36, style: id, still: !live })
    } else if (key === AI_MOTION_ORB) {
      AiFloatingOrb({ orbSize: 46, style: id, still: !live })
    } else if (key === AI_MOTION_DONE) {
      if (this.replay || !live) {
        if (id === 'island') {
          Stack() { AiIslandRingsCheck({ markSize: 34, still: !live }) }
            .width(50).height(50).borderRadius(16).backgroundColor('#000000')
        } else if (id === 'none') {
          Text('—').fontSize(18).fontColor('#8E8E93')
        } else {
          Stack() { AiDoneMark({ markSize: 30, style: id, still: !live }) }
            .width(58).height(28).borderRadius(14).backgroundColor('#000000')
        }
      }
    } else if (key === AI_MOTION_OPEN) {
      AiOpenPreview({ style: id })
    } else if (key === AI_MOTION_SEND_GLOW) {
      AiSendButton({ active: true, buttonSize: 28, glowStyle: id })
    }
  }

  @Builder private tile(kind: AiMotionKind, option: AiMotionOption) {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        // Separate branches, so a tile that becomes selected remounts and starts playing.
        if (this.current(kind.key) === option.id) {
          Stack() { this.preview(kind.key, option.id, true) }
            .width(84).height(84).borderRadius(22)
            .backgroundColor(kind.key === AI_MOTION_OPEN ? '#3A3A3C' : '#0B0B0F')
        } else {
          Stack() { this.preview(kind.key, option.id, false) }
            .width(84).height(84).borderRadius(22)
            .backgroundColor(kind.key === AI_MOTION_OPEN ? '#3A3A3C' : '#0B0B0F')
        }
        if (this.current(kind.key) === option.id) {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(18).fontColor([this.accent])
            .margin({ top: 5, right: 5 })
        }
      }
      .width(84).height(84).borderRadius(22)
      .border({ width: this.current(kind.key) === option.id ? 2 : 0.5,
        color: this.current(kind.key) === option.id ? this.accent : this.pal().cardBorder })
      Text(option.label).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
        .fontFamily(AppConfig.fontFamily)
      Text(option.detail).fontSize(10).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily)
        .width(88).maxLines(2).textAlign(TextAlign.Center).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width(92)
    .accessibilityText(kind.title + '：' + option.label)
    .onClick((): void => { this.choose(kind.key, option.id); })
  }

  @Builder private speedRow(kind: AiMotionKind) {
    Row({ space: 6 }) {
      ForEach(kind.options, (option: AiMotionOption): void => {
        Text(option.label).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(this.speed === option.id ? Color.White : this.pal().text)
          .layoutWeight(1).height(36).textAlign(TextAlign.Center).borderRadius(18)
          .backgroundColor(this.speed === option.id ? this.accent : this.pal().surface)
          .onClick((): void => { this.choose(kind.key, option.id); })
      }, (option: AiMotionOption): string => option.id)
    }.width('100%')
  }

  build() {
    Scroll() {
      Column({ space: 18 }) {
        if (this.reduced) {
          Text('已开启「减少动态效果」：各项动效暂时使用最简洁的样式，关闭后恢复这里的选择。')
            .fontSize(12).lineHeight(17).fontColor(this.pal().text3).width('100%')
            .padding(12).borderRadius(14).backgroundColor(this.pal().surface)
        }
        ForEach(AI_MOTION_KINDS, (kind: AiMotionKind): void => {
          Column({ space: 10 }) {
            Column({ space: 2 }) {
              Text(kind.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
                .fontFamily(AppConfig.fontFamily)
              Text(kind.detail).fontSize(12).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily)
            }.alignItems(HorizontalAlign.Start).width('100%')
            if (kind.key === AI_MOTION_SPEED) {
              this.speedRow(kind)
            } else {
              Scroll() {
                Row({ space: 10 }) {
                  ForEach(kind.options, (option: AiMotionOption): void => {
                    this.tile(kind, option)
                  }, (option: AiMotionOption): string => kind.key + option.id)
                }.alignItems(VerticalAlign.Top)
              }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
              .edgeEffect(EdgeEffect.Spring)
            }
          }.width('100%')
        }, (kind: AiMotionKind): string => kind.key)
      }.width('100%').padding({ bottom: 16 })
    }.layoutWeight(1).width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
  }
}
