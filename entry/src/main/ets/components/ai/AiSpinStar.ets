/**
 * The Claude style's ✳ while a turn works: it turns slowly and breathes. The animations run on the glyph's own
 * rotation and scale (an implicit .animation() looping forever also animated every move of the row it sat in, so
 * the star slid about whenever the transcript changed).
 */
@Component
export struct AiSpinStar {
  @Prop color: string = '#D97757';
  @Prop glyphSize: number = 20;
  @State private angle: number = 0;
  @State private grow: number = 1;
  private generation: number = 0;

  aboutToDisappear(): void { this.generation++; }

  private start(): void {
    const generation = ++this.generation;
    setTimeout((): void => {
      if (generation !== this.generation) { return; }
      this.getUIContext().animateTo({ duration: 2600, curve: Curve.Linear, iterations: -1 }, (): void => { this.angle = 360; });
      this.getUIContext().animateTo({ duration: 900, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate },
        (): void => { this.grow = 0.78; });
    }, 16);
  }

  build() {
    Stack() {
      Text('✳').fontSize(this.glyphSize).fontColor(this.color)
        .rotate({ angle: this.angle, centerX: '50%', centerY: '50%' })
        .scale({ x: this.grow, y: this.grow, centerX: '50%', centerY: '50%' })
    }.width(this.glyphSize + 4).height(this.glyphSize + 4).accessibilityText('正在工作')
    .onAppear((): void => { this.start(); })
  }
}
