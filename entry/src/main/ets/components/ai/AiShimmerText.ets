import { AppConfig } from '../../common/Theme';

/**
 * A line of status text with a band of light flowing across it, left to right, again and again (正在思考 in the
 * Codex and Claude apps). The band is a gradient drawn only over the glyphs: the row composites offscreen and the
 * band blends SRC_ATOP onto the text.
 */
@Component
export struct AiShimmerText {
  @Prop text: string = '';
  @Prop fontSize: number = 15;
  /** The text's own color, and the color at the middle of the passing band. */
  @Prop baseColor: string = '#8A8A8A';
  @Prop highlight: string = '#FFFFFF';
  @State private widthVp: number = 0;
  @State private sweep: number = 0;
  private generation: number = 0;

  aboutToDisappear(): void { this.generation++; }

  private band(): number { return Math.max(40, this.widthVp * 0.5); }

  /** The highlight with no alpha (#00RRGGBB; ArkUI reads eight hex digits as #AARRGGBB). */
  private clear(): string {
    const hex = this.highlight.replace('#', '');
    return '#00' + (hex.length >= 6 ? hex.slice(hex.length - 6) : 'FFFFFF');
  }

  /** Starts the sweep from just left of the text; a new width restarts it. */
  private start(): void {
    const generation = ++this.generation;
    this.sweep = -this.band();
    setTimeout((): void => {
      if (generation !== this.generation) { return; }
      this.getUIContext().animateTo({ duration: Math.max(1200, Math.round(this.widthVp * 14)), curve: Curve.Linear,
        iterations: -1, delay: 120 }, (): void => { this.sweep = this.widthVp; });
    }, 16);
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      Text(this.text).fontSize(this.fontSize).fontFamily(AppConfig.fontFamily).fontColor(this.baseColor).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.widthVp > 0) {
        Column().width(this.band()).height('100%')
          .linearGradient({ angle: 90, colors: [[this.clear(), 0], [this.highlight, 0.5], [this.clear(), 1]] })
          .translate({ x: this.sweep })
          .blendMode(BlendMode.SRC_ATOP)
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .blendMode(BlendMode.SRC_OVER, BlendApplyType.OFFSCREEN)
    .clip(true)
    .accessibilityText(this.text)
    .onAreaChange((_old: Area, next: Area): void => {
      const width = Number(next.width);
      if (Number.isFinite(width) && width > 0 && Math.abs(width - this.widthVp) > 0.5) {
        this.widthVp = width;
        this.start();
      }
    })
  }
}
