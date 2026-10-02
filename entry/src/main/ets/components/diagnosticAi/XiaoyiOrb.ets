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

const AI_THINKING_COLORS: Array<[ResourceColor, number]> = [
  ['#42CBF7', 0], ['#2A7DFF', 0.3], ['#A479FF', 0.6], ['#FF678C', 0.85], ['#42CBF7', 1]
];

/** One small disc of the thinking ring; it spins on its own while the ring turns the other way. */
@Component
struct AiThinkingDot {
  @Prop dotSize: number = 6;
  @Prop phase: number = 0;
  @State private spin: number = 0;

  aboutToAppear(): void {
    setTimeout((): void => {
      this.getUIContext().animateTo({ duration: 1400, iterations: -1, curve: Curve.Linear,
        expectedFrameRateRange: { min: 30, max: 60, expected: 60 } }, (): void => { this.spin = -360; });
    }, 16);
  }

  build() {
    Circle().width(this.dotSize).height(this.dotSize).fill(Color.Transparent)
      .sweepGradient({ center: ['50%', '50%'], colors: AI_THINKING_COLORS, rotation: this.phase })
      .borderRadius(this.dotSize / 2)
      .rotate({ angle: this.spin })
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
