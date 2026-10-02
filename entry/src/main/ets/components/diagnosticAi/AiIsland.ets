import { curves } from '@kit.ArkUI';
import { AppConfig } from '../../common/Theme';
import { DiagnosticAiAssistantPanel } from './DiagnosticAiAssistantPanel';

/** System AI gradient colors (ai_intelligent_gradient_color1–4). */
const AI_ISLAND_COLORS: Array<[ResourceColor, number]> = [
  ['#42CBF7', 0], ['#2A7DFF', 0.28], ['#A479FF', 0.55], ['#FF678C', 0.8], ['#42CBF7', 1]
];
const AI_ISLAND_PLATE: string = '#F2121217';
const AI_ISLAND_MAX_WIDTH: number = 560;

/** The light inside the island: a turning gradient sphere that breathes, and pulses brighter while working. */
@Component
struct AiIslandOrb {
  @Prop orbSize: number = 26;
  @Prop working: boolean = false;
  @State private angle: number = 0;
  @State private breath: number = 0.92;

  aboutToAppear(): void {
    setTimeout((): void => {
      this.getUIContext().animateTo({ duration: 3600, iterations: -1, curve: Curve.Linear,
        expectedFrameRateRange: { min: 30, max: 60, expected: 60 } }, (): void => { this.angle = 360; });
      this.getUIContext().animateTo({ duration: 1300, iterations: -1, playMode: PlayMode.Alternate,
        curve: Curve.EaseInOut }, (): void => { this.breath = 1.08; });
    }, 16);
  }

  build() {
    Stack() {
      // Halo: the same light, blurred, grows brighter while the assistant works.
      Circle().width(this.orbSize).height(this.orbSize).fill(Color.Transparent)
        .sweepGradient({ center: ['50%', '50%'], colors: AI_ISLAND_COLORS }).borderRadius(this.orbSize / 2)
        .blur(this.orbSize * 0.35).opacity(this.working ? 0.95 : 0.55)
        .scale({ x: this.breath * (this.working ? 1.35 : 1.15), y: this.breath * (this.working ? 1.35 : 1.15) })
        .animation({ duration: 400, curve: Curve.EaseInOut })
      Circle().width(this.orbSize).height(this.orbSize).fill(Color.Transparent)
        .sweepGradient({ center: ['50%', '50%'], colors: AI_ISLAND_COLORS }).borderRadius(this.orbSize / 2)
        .rotate({ angle: this.angle }).scale({ x: this.breath, y: this.breath })
      // Glassy highlight.
      Circle().width(this.orbSize * 0.5).height(this.orbSize * 0.5).fill('#59FFFFFF')
        .position({ x: this.orbSize * 0.18, y: this.orbSize * 0.12 }).blur(this.orbSize * 0.12)
    }.width(this.orbSize).height(this.orbSize)
  }
}

/**
 * 启动 AI 辅助 as an island at the top center of the window, after the iOS 27 Siri text mode: no edge glow; a dark
 * capsule with the AI light appears and opens into a translucent dark card where the question is typed directly,
 * with the keyboard up and small pill actions under the text. The result opens in the same card. Tapping outside,
 * the close button or swiping the card's top up folds it back into the capsule. The card hosts the regular
 * DiagnosticAiAssistantPanel in its Siri layout, so capture, analysis and entitlement checks are unchanged.
 */
@Component
export struct AiIsland {
  /** Distance from the window top to the island (status bar / cutout). */
  @Prop topInset: number = 24;
  onDismissed: () => void = (): void => {};
  onOpenMailDraft: (subject: string, body: string) => void = (_subject: string, _body: string): void => {};
  /** 0 hidden · 1 capsule · 2 card. */
  @State private stage: number = 0;
  @State private contentShown: boolean = false;
  @State private working: boolean = false;
  @State private areaWidth: number = 360;
  @State private areaHeight: number = 720;
  /** Natural height of the card content, measured off-screen width-wise and used to size the island. */
  @State private contentHeight: number = 120;
  private timers: number[] = [];
  private closing: boolean = false;

  aboutToAppear(): void { this.later(16, (): void => { this.open(); }); }

  aboutToDisappear(): void { this.clearTimers(); }

  private later(ms: number, action: () => void): void { this.timers.push(setTimeout(action, ms)); }
  private clearTimers(): void { this.timers.forEach((id: number): void => { clearTimeout(id); }); this.timers = []; }

  private morph(stage: number): void {
    this.getUIContext().animateTo({ curve: curves.springMotion(0.48, 0.84) }, (): void => { this.stage = stage; });
  }

  private open(): void {
    this.morph(1);
    this.later(300, (): void => { this.morph(2); });
    this.later(440, (): void => {
      this.getUIContext().animateTo({ duration: 240, curve: Curve.EaseOut }, (): void => { this.contentShown = true; });
    });
  }

  close(): void {
    if (this.closing) { return; }
    this.closing = true;
    this.clearTimers();
    focusControl.requestFocus('aiIslandRoot');
    this.getUIContext().animateTo({ duration: 120, curve: Curve.EaseIn }, (): void => { this.contentShown = false; });
    this.later(110, (): void => { this.morph(1); });
    this.later(380, (): void => {
      this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseIn }, (): void => { this.stage = 0; });
    });
    this.later(600, (): void => { this.onDismissed(); });
  }

  private cardWidth(): number { return Math.min(this.areaWidth - 16, AI_ISLAND_MAX_WIDTH); }
  private islandWidth(): number { return this.stage <= 1 ? 128 : this.cardWidth(); }
  private islandHeight(): number {
    if (this.stage <= 1) { return 36; }
    return Math.min(this.contentHeight, this.areaHeight * 0.72);
  }
  private islandRadius(): number { return this.stage <= 1 ? 18 : 28; }

  @Builder private card() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        AiIslandOrb({ orbSize: 18, working: this.working })
        Text(this.working ? 'AI 辅助 · 处理中' : 'AI 辅助').fontSize(12).fontColor('#9AA3B5')
          .fontFamily(AppConfig.fontFamily).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(14).fontColor(['#9AA3B5']).padding(6)
          .accessibilityText('收起').onClick((): void => { this.close(); })
      }.width('100%')
      // Swipe the card's top up to fold it away.
      .gesture(PanGesture({ direction: PanDirection.Up, distance: 12 }).onActionEnd((event: GestureEvent): void => {
        if (event.offsetY < -28) { this.close(); }
      }))
      DiagnosticAiAssistantPanel({
        siriMode: true,
        forceDark: true,
        embedded: true,
        onActivityChanged: (active: boolean): void => { this.working = active; },
        onClose: (): void => { this.close(); },
        onOpenMailDraft: (subject: string, body: string): void => { this.onOpenMailDraft(subject, body); }
      }).width('100%')
    }
    .width(this.cardWidth()).padding({ left: 18, right: 14, top: 12, bottom: 16 })
    .onAreaChange((_old: Area, area: Area): void => {
      const h: number = Number(area.height);
      if (h > 0 && Math.abs(h - this.contentHeight) > 1) {
        // Later growth (a result arriving) animates the island with the same spring.
        if (this.stage >= 2) {
          this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.86) }, (): void => { this.contentHeight = h; });
        } else {
          this.contentHeight = h;
        }
      }
    })
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column().width('100%').height('100%').backgroundColor('#000000')
        .opacity(this.stage >= 2 && !this.closing ? 0.22 : 0)
        .animation({ duration: 260, curve: Curve.EaseInOut })
        .onClick((): void => { this.close(); })
      Stack({ alignContent: Alignment.Top }) {
        if (this.stage <= 1) {
          Row() { AiIslandOrb({ orbSize: 20, working: this.working }) }
            .width('100%').height(36).justifyContent(FlexAlign.Center)
        }
        Column() { this.card() }
          .width(this.cardWidth()).opacity(this.contentShown ? 1 : 0)
          .position({ x: 0, y: 0 })
          .hitTestBehavior(this.contentShown ? HitTestMode.Default : HitTestMode.None)
        if (this.stage >= 2) {
          // The faint rainbow reflection along the card's lower edge.
          Row().width('58%').height(1.5).borderRadius(1).opacity(0.7)
            .linearGradient({ angle: 90, colors: AI_ISLAND_COLORS })
            .position({ x: '21%', y: this.islandHeight() - 2 })
        }
      }
      .id('aiIslandRoot').focusable(true)
      .width(this.islandWidth()).height(this.islandHeight()).borderRadius(this.islandRadius()).clip(true)
      .backgroundColor(AI_ISLAND_PLATE).backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
      .border({ width: 0.5, color: '#26FFFFFF' })
      .shadow({ radius: this.stage >= 2 ? 34 : 16, color: this.working ? '#662A7DFF' : '#59000000', offsetY: 10 })
      .margin({ top: this.topInset + 6 })
      .opacity(this.stage > 0 ? 1 : 0)
      .scale({ x: this.stage > 0 ? 1 : 0.6, y: this.stage > 0 ? 1 : 0.6 })
    }
    .width('100%').height('100%')
    .hitTestBehavior(this.stage > 0 ? HitTestMode.Default : HitTestMode.None)
    .onAreaChange((_old: Area, area: Area): void => {
      const w: number = Number(area.width);
      const h: number = Number(area.height);
      if (w > 0 && h > 0 && (Math.abs(w - this.areaWidth) > 1 || Math.abs(h - this.areaHeight) > 1)) {
        this.areaWidth = w; this.areaHeight = h;
      }
    })
  }
}
