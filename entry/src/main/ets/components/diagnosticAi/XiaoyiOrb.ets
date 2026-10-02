/**
 * The 小艺 orb with an immersive light effect: the orb image slowly turns and breathes, and a blurred copy of it glows
 * behind in its own colors, brighter while the assistant works.
 */
@Component
export struct AiIslandOrb {
  @Prop orbSize: number = 26;
  @Prop working: boolean = false;
  @State private angle: number = 0;
  @State private breath: number = 0.94;

  aboutToAppear(): void {
    setTimeout((): void => {
      this.getUIContext().animateTo({ duration: 9000, iterations: -1, curve: Curve.Linear,
        expectedFrameRateRange: { min: 30, max: 60, expected: 60 } }, (): void => { this.angle = 360; });
      this.getUIContext().animateTo({ duration: 1500, iterations: -1, playMode: PlayMode.Alternate,
        curve: Curve.EaseInOut }, (): void => { this.breath = 1.06; });
    }, 16);
  }

  build() {
    Stack() {
      Image($r('app.media.xiaoyi_orb')).width(this.orbSize).height(this.orbSize).borderRadius(this.orbSize / 2)
        .blur(this.orbSize * 0.4).opacity(this.working ? 1 : 0.7)
        .scale({ x: this.breath * (this.working ? 1.45 : 1.22), y: this.breath * (this.working ? 1.45 : 1.22) })
        .animation({ duration: 400, curve: Curve.EaseInOut })
      Image($r('app.media.xiaoyi_orb')).width(this.orbSize).height(this.orbSize).borderRadius(this.orbSize / 2)
        .clip(true).rotate({ angle: this.angle }).scale({ x: this.breath, y: this.breath })
      // Glass highlight on the upper left.
      Circle().width(this.orbSize * 0.42).height(this.orbSize * 0.42).fill('#66FFFFFF')
        .position({ x: this.orbSize * 0.16, y: this.orbSize * 0.1 }).blur(this.orbSize * 0.14)
    }.width(this.orbSize).height(this.orbSize)
  }
}

/** Official HarmonyOS assistant glyph wrapped in the app's HDS-compatible glass button. The public SDK exposes the
 * Celia assistant media glyph, but no embeddable proprietary 小艺 Agent surface; the glyph therefore remains a safe
 * visual adapter and falls back to the existing local orb treatment around it. */
@Component
export struct AiSystemAgentButton {
  @Prop buttonSize: number = 38;
  @Prop active: boolean = false;

  build() {
    Stack() {
      Circle().width(this.buttonSize).height(this.buttonSize)
        .backgroundBlurStyle(BlurStyle.COMPONENT_THICK,
          { colorMode: ThemeColorMode.DARK, adaptiveColor: AdaptiveColor.DEFAULT })
        .backgroundColor(this.active ? '#CC15151B' : '#B8141419')
        .border({ width: 0.8, color: this.active ? '#66FFFFFF' : '#33FFFFFF' })
        .shadow({ radius: this.active ? 20 : 14, color: this.active ? '#663D8BFF' : '#40000000', offsetY: 4 })
      if (this.active) {
        AiThinkingRing({ ringSize: this.buttonSize + 7 })
      }
      Image($r('sys.media.Celia_fill')).width(this.buttonSize * 0.56).height(this.buttonSize * 0.56)
        .fillColor('#FFFFFFFF')
    }.width(this.buttonSize + (this.active ? 8 : 0)).height(this.buttonSize + (this.active ? 8 : 0))
  }
}

/** Six-kernel compact indicator used by the reference interaction's processing capsule. */
@Component
export struct AiKernelRing {
  @Prop ringSize: number = 24;
  @State private turn: number = 0;
  private readonly count: number = 6;

  aboutToAppear(): void {
    setTimeout((): void => {
      this.getUIContext().animateTo({ duration: 1800, iterations: -1, curve: Curve.Linear }, (): void => {
        this.turn = 360;
      });
    }, 16);
  }

  private x(i: number): number {
    const radius = this.ringSize * 0.28;
    return this.ringSize / 2 + Math.cos(i * Math.PI * 2 / this.count) * radius - this.dot(i) / 2;
  }

  private y(i: number): number {
    const radius = this.ringSize * 0.28;
    return this.ringSize / 2 + Math.sin(i * Math.PI * 2 / this.count) * radius - this.dot(i) / 2;
  }

  private dot(i: number): number { return this.ringSize * (i % 2 === 0 ? 0.22 : 0.16); }

  build() {
    Stack() {
      ForEach([0, 1, 2, 3, 4, 5], (i: number): void => {
        Circle().width(this.dot(i)).height(this.dot(i)).fill('#F6FBFF')
          .shadow({ radius: this.ringSize * 0.28, color: ['#42CBF7', '#A479FF', '#FF678C'][i % 3] })
          .position({ x: this.x(i), y: this.y(i) })
      }, (i: number): string => 'kernel' + i.toString())
    }.width(this.ringSize).height(this.ringSize).rotate({ angle: this.turn })
  }
}

const AI_THINKING_COLORS: Array<[ResourceColor, number]> = [
  ['#42CBF7', 0], ['#2A7DFF', 0.3], ['#A479FF', 0.6], ['#FF678C', 0.85], ['#42CBF7', 1]
];

/** One small disc of the thinking ring; it spins on its own while the ring turns the other way. */
@Component
struct AiThinkingDot {
  @Prop dotSize: number = 6;
  @Prop phase: number = 0;
  @State private spin: number = 0;
  @State private stretch: number = 0.9;
  @State private drift: number = 0;

  aboutToAppear(): void {
    setTimeout((): void => {
      // Each particle has its own orientation, stretch and small drift. The parent ring also orbits, so the result is
      // a field of independently moving light chips rather than one fixed circular spinner.
      this.getUIContext().animateTo({ duration: 1700, iterations: -1, curve: Curve.Linear,
        expectedFrameRateRange: { min: 30, max: 60, expected: 60 } }, (): void => { this.spin = -360; });
      this.getUIContext().animateTo({ duration: 920, iterations: -1, playMode: PlayMode.Alternate,
        curve: Curve.EaseInOut }, (): void => { this.stretch = 1.35; });
      this.getUIContext().animateTo({ duration: 1250, iterations: -1, playMode: PlayMode.Alternate,
        curve: Curve.EaseInOut }, (): void => { this.drift = 1; });
    }, 16);
  }

  build() {
    Stack() {
      Row().width(this.dotSize * 1.55 * this.stretch).height(this.dotSize * 0.72).borderRadius(this.dotSize)
        .linearGradient({ angle: 90, colors: AI_THINKING_COLORS })
        .shadow({ radius: this.dotSize * 0.85, color: '#6642CBF7', offsetY: 0 })
      Circle().width(this.dotSize * 0.34).height(this.dotSize * 0.34).fill('#F8FFFFFF')
        .position({ x: this.dotSize * 0.62, y: this.dotSize * 0.2 })
        .opacity(0.5 + this.stretch * 0.35)
    }
    .width(this.dotSize * 1.7).height(this.dotSize * 1.25)
    .translate({ x: this.drift * this.dotSize * 0.18 })
    .rotate({ angle: this.spin + this.phase })
  }
}

/**
 * Thinking animation after Siri AI: small spinning discs form a larger ring, and the ring turns while each disc spins
 * the other way. Sizes alternate so the ring has depth. All motion runs on the render thread.
 */
@Component
export struct AiThinkingRing {
  @Prop ringSize: number = 28;
  @State private turn: number = 0;
  private readonly count: number = 10;

  aboutToAppear(): void {
    setTimeout((): void => {
      this.getUIContext().animateTo({ duration: 2600, iterations: -1, curve: Curve.Linear,
        expectedFrameRateRange: { min: 30, max: 60, expected: 60 } }, (): void => { this.turn = 360; });
    }, 16);
  }

  private indexes(): number[] {
    const list: number[] = [];
    for (let i: number = 0; i < this.count; i++) { list.push(i); }
    return list;
  }
  private dotSize(i: number): number { return this.ringSize * (i % 2 === 0 ? 0.24 : 0.17); }
  private dotX(i: number): number {
    const r: number = this.ringSize / 2 - this.ringSize * 0.13;
    return this.ringSize / 2 + Math.cos(i * Math.PI * 2 / this.count) * r - this.dotSize(i) / 2;
  }
  private dotY(i: number): number {
    const r: number = this.ringSize / 2 - this.ringSize * 0.13;
    return this.ringSize / 2 + Math.sin(i * Math.PI * 2 / this.count) * r - this.dotSize(i) / 2;
  }

  build() {
    Stack() {
      ForEach(this.indexes(), (i: number): void => {
        AiThinkingDot({ dotSize: this.dotSize(i), phase: i * 36 })
          .position({ x: this.dotX(i), y: this.dotY(i) })
      }, (i: number): string => 'dot' + i.toString())
    }
    .width(this.ringSize).height(this.ringSize)
    .rotate({ angle: this.turn })
  }
}
