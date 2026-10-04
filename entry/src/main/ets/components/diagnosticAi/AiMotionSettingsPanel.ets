import { AppConfig, Palette, buildDark, buildLight } from '../../common/Theme';
import { AI_MOTION_DONE, AI_MOTION_KINDS, AI_MOTION_OPEN, AI_MOTION_ORB, AI_MOTION_SEND_GLOW, AI_MOTION_SPEED,
  AI_MOTION_THINKING, AiMotionKind, AiMotionOption, DiagnosticAiMotionStore } from '../../services/diagnosticAi/DiagnosticAiMotionPolicy';
import { AiDoneMark, AiFloatingOrb, AiIslandRingsCheck, AiOpenPreview, AiThinkingIndicator } from './AiMotionViews';
import { AiSendButton } from './AiIslandChrome';
import { AiSegmented } from './AiSegmented';
import { AiXiaoyiRing } from './AiXiaoyiRing';
import { AI_STYLE, AI_STYLE_WASH, AiGlassColors, aiStyleIsXiaoyi, aiXiaoyiGlass, aiXiaoyiWash } from '../../services/diagnosticAi/AiStylePolicy';

/**
 * The 小艺 tile: its glass and the ring listening to a voice — here a made-up one, syllables coming and going, so the
 * ripples can be seen following a voice rather than a clock.
 */
@Component
struct AiXiaoyiStylePreview {
  @Prop live: boolean = false;
  @StorageProp('currentTheme') theme: string = 'light';
  @State private level: number = 0;
  private timer: number = -1;
  private next: number = 0;
  private peak: number = 0;
  private born: number = 0;

  aboutToAppear(): void {
    if (!this.live) { return; }
    this.timer = setInterval((): void => {
      const now: number = Date.now();
      if (now > this.next) {
        this.peak = 0.35 + 0.65 * Math.random();
        this.born = now;
        this.next = now + 130 + 220 * Math.random() + (Math.random() < 0.12 ? 500 : 0);
      }
      const d: number = (now - this.born) / 1000;
      this.level = this.peak * (d < 0.03 ? d / 0.03 : Math.exp(-(d - 0.03) / 0.16));
    }, 33);
  }

  aboutToDisappear(): void { if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; } }

  private glass(): AiGlassColors { return aiXiaoyiGlass(this.theme === 'dark'); }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // The camera island the panel grows from.
      Column().width(44).height(12).borderRadius(6).backgroundColor('#FF000000').margin({ top: 8 })
      AiXiaoyiRing({ ringSize: 116, mode: 'listen', level: this.level, still: !this.live, maxFps: 24 })
        .margin({ top: 14 })
    }
    .width('100%').height('100%')
    .linearGradient({ angle: 135, colors: [[this.glass().from, 0], [this.glass().to, 1]] })
  }
}

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
  @StorageProp(AI_STYLE) style: string = 'siri';
  @StorageProp(AI_STYLE_WASH) wash: string = 'on';
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
    if (key === AI_STYLE) { return this.style; }
    if (key === AI_STYLE_WASH) { return this.wash; }
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
    if (key === AI_STYLE_WASH) {
      Stack({ alignContent: Alignment.Top }) {
        Column().width(56).height(28).borderRadius(10).margin({ top: 10 })
          .linearGradient({ angle: 135, colors: [[aiXiaoyiGlass(this.theme === 'dark').from, 0],
            [aiXiaoyiGlass(this.theme === 'dark').to, 1]] })
      }
      .width(84).height(84)
      .linearGradient({ angle: 135, colors: id === 'on' ?
        [[aiXiaoyiWash(this.theme === 'dark')[0], 0], [aiXiaoyiWash(this.theme === 'dark')[1], 1]] :
        [['#00000000', 0], ['#00000000', 1]] })
    } else if (key === AI_MOTION_THINKING) {
      AiThinkingIndicator({ indicatorSize: 36, style: id, still: !live, maxFps: 20 })
    } else if (key === AI_MOTION_ORB) {
      AiFloatingOrb({ orbSize: 46, style: id, still: !live, maxFps: 20 })
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

  /** AI 风格: the two looks as two mini panels, side by side; the 小艺 one plays while it is chosen. */
  @Builder private stylePreview(id: string, live: boolean) {
    if (id === 'xiaoyi') {
      AiXiaoyiStylePreview({ live: live })
    } else {
      // Siri: the dark smoky glass growing from the island, its thinking dots (a still frame — the thinking row
      // below plays them).
      Stack({ alignContent: Alignment.Top }) {
        Column().width(44).height(12).borderRadius(6).backgroundColor('#FF000000').margin({ top: 8 })
        AiThinkingIndicator({ indicatorSize: 40, style: 'dots', still: true }).margin({ top: 44 })
      }
      .width('100%').height('100%')
      .linearGradient({ angle: 180, colors: [['#FF050506', 0], ['#FF0A0A0C', 0.55], ['#FF26262B', 1]] })
    }
  }

  @Builder private styleCard(option: AiMotionOption) {
    Column({ space: 8 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        // Separate branches, so the card that becomes chosen remounts and starts playing.
        if (this.style === option.id) {
          this.stylePreview(option.id, true)
        } else {
          this.stylePreview(option.id, false)
        }
        if (this.style === option.id) {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(20).fontColor([this.accent])
            .margin({ top: 8, right: 8 })
        }
      }
      .width('100%').height(132).borderRadius(20).clip(true)
      .border({ width: this.style === option.id ? 2 : 0.5,
        color: this.style === option.id ? this.accent : this.pal().cardBorder })
      Column({ space: 2 }) {
        Text(option.label).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          .fontFamily(AppConfig.fontFamily)
        Text(option.detail).fontSize(11).lineHeight(15).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).width('100%').padding({ left: 4, right: 4 })
    }
    .layoutWeight(1)
    .accessibilityText('AI 风格：' + option.label)
    .onClick((): void => { this.choose(AI_STYLE, option.id); })
  }

  /** The 小艺 options of the other kinds sit on the 小艺 glass: their light is made for it. */
  private tileGlass(key: string, id: string): LinearGradientOptions {
    const xy: boolean = (key === AI_MOTION_THINKING || key === AI_MOTION_DONE) && id === 'xiaoyi';
    const glass: AiGlassColors = aiXiaoyiGlass(this.theme === 'dark');
    return xy ? { angle: 135, colors: [[glass.from, 0], [glass.to, 1]] } :
      { angle: 135, colors: [['#00000000', 0], ['#00000000', 1]] };
  }

  @Builder private tile(kind: AiMotionKind, option: AiMotionOption) {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        // Separate branches, so a tile that becomes selected remounts and starts playing.
        if (this.current(kind.key) === option.id) {
          Stack() { this.preview(kind.key, option.id, true) }
            .width(84).height(84).borderRadius(22).clip(true)
            .backgroundColor(kind.key === AI_MOTION_OPEN ? '#3A3A3C' : '#0B0B0F')
            .linearGradient(this.tileGlass(kind.key, option.id))
        } else {
          Stack() { this.preview(kind.key, option.id, false) }
            .width(84).height(84).borderRadius(22).clip(true)
            .backgroundColor(kind.key === AI_MOTION_OPEN ? '#3A3A3C' : '#0B0B0F')
            .linearGradient(this.tileGlass(kind.key, option.id))
        }
        if (this.current(kind.key) === option.id) {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(18).fontColor([this.accent])
            .margin({ top: 5, right: 5 })
        }
      }
      .width(84).height(84).borderRadius(22).clip(true)
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
    AiSegmented({ options: kind.options.map((option: AiMotionOption): string[] => [option.id, option.label]),
      current: this.speed, segmentHeight: 36, labelSize: 14, trackColor: this.pal().surface, thumbColor: this.accent,
      textColor: '#FFFFFF', mutedColor: this.pal().text,
      onPick: (id: string): void => { this.choose(kind.key, id); } })
  }

  build() {
    Scroll() {
      Column({ space: 18 }) {
        if (this.reduced) {
          Text('已开启「减少动态效果」：各项动效暂时使用最简洁的样式，关闭后恢复这里的选择。')
            .fontSize(12).lineHeight(17).fontColor(this.pal().text3).width('100%')
            .padding(12).borderRadius(14).backgroundColor(this.pal().surface)
        }
        ForEach(AI_MOTION_KINDS.filter((kind: AiMotionKind): boolean =>
          kind.key !== AI_STYLE_WASH || aiStyleIsXiaoyi(this.style)), (kind: AiMotionKind): void => {
          Column({ space: 10 }) {
            Column({ space: 2 }) {
              Text(kind.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
                .fontFamily(AppConfig.fontFamily)
              Text(kind.detail).fontSize(12).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily)
            }.alignItems(HorizontalAlign.Start).width('100%')
            if (kind.key === AI_MOTION_SPEED) {
              this.speedRow(kind)
            } else if (kind.key === AI_STYLE) {
              Row({ space: 12 }) {
                ForEach(kind.options, (option: AiMotionOption): void => { this.styleCard(option) },
                  (option: AiMotionOption): string => 'style' + option.id)
              }.width('100%').alignItems(VerticalAlign.Top)
            } else {
              Scroll() {
                Row({ space: 10 }) {
                  ForEach(kind.options, (option: AiMotionOption): void => {
                    this.tile(kind, option)
                  }, (option: AiMotionOption): string => kind.key + option.id)
                }.alignItems(VerticalAlign.Top)
              }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
              .align(Alignment.Start)
              .edgeEffect(EdgeEffect.Spring)
            }
          }.width('100%')
        }, (kind: AiMotionKind): string => kind.key)
      }.width('100%').padding({ bottom: 16 })
    }.layoutWeight(1).width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
  }
}
