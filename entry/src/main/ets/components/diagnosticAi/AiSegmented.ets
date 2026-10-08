import { curves } from '@kit.ArkUI';

/**
 * A segmented control whose selected thumb slides from one choice to the next, as iOS's does. The thumb moves at
 * once on a tap (the parent's state follows), and again whenever `current` changes from outside. It is a component
 * of its own so the selection is a @Prop: a @Builder given the value by copy would never redraw when it changes.
 */
@Component
export struct AiSegmented {
  /** [id, label] pairs. */
  @Prop options: string[][] = [];
  @Prop @Watch('follow') current: string = '';
  @Prop switchable: boolean = true;
  @Prop trackColor: string = '#1F767680';
  @Prop thumbColor: string = '#FFFFFF';
  @Prop textColor: string = '#000000';
  @Prop mutedColor: string = '#8E8E93';
  @Prop segmentHeight: number = 32;
  @Prop labelSize: number = 13;
  /** Each choice this wide (0: the choices share the control's width). */
  @Prop segmentWidth: number = 0;
  onPick: (id: string) => void = (_id: string): void => {};
  @State private index: number = 0;
  @State private trackWidth: number = 0;

  aboutToAppear(): void {
    this.index = Math.max(0, this.indexOf(this.current));
  }

  private indexOf(id: string): number {
    return this.options.findIndex((pair: string[]): boolean => pair[0] === id);
  }

  private follow(): void {
    const next: number = this.indexOf(this.current);
    if (next < 0 || next === this.index) { return; }
    this.getUIContext().animateTo({ curve: curves.springMotion(0.36, 0.82) }, (): void => { this.index = next; });
  }

  private pick(i: number): void {
    if (!this.switchable || i === this.index) { return; }
    this.getUIContext().animateTo({ curve: curves.springMotion(0.36, 0.82) }, (): void => { this.index = i; });
    this.onPick(this.options[i][0]);
  }

  private cellWidth(): number {
    if (this.segmentWidth > 0) { return this.segmentWidth; }
    return this.options.length > 0 ? this.trackWidth / this.options.length : 0;
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      if (this.cellWidth() > 0) {
        Column()
          .width(this.cellWidth()).height(this.segmentHeight).borderRadius(this.segmentHeight / 2)
          .backgroundColor(this.thumbColor)
          .shadow({ radius: 6, color: '#1F000000', offsetY: 1 })
          .translate({ x: this.index * this.cellWidth() })
      }
      Row() {
        ForEach(this.options, (pair: string[], i: number): void => {
          Text(pair[1]).fontSize(this.labelSize).fontWeight(FontWeight.Medium).maxLines(1)
            .fontColor(i === this.index ? this.textColor : this.mutedColor)
            .textAlign(TextAlign.Center).height(this.segmentHeight)
            .width(this.segmentWidth > 0 ? this.segmentWidth : undefined)
            .layoutWeight(this.segmentWidth > 0 ? 0 : 1)
            .padding({ left: 6, right: 6 })
            .accessibilityText(pair[1] + (i === this.index ? '，已选中' : ''))
            .onClick((): void => { this.pick(i); })
        }, (pair: string[]): string => 'segment-' + pair[0])
      }
      .width(this.segmentWidth > 0 ? undefined : '100%')
    }
    .width(this.segmentWidth > 0 ? undefined : '100%')
    .padding(2).borderRadius(this.segmentHeight / 2 + 2).backgroundColor(this.trackColor)
    .opacity(this.switchable ? 1 : 0.55)
    .onAreaChange((_old: Area, area: Area): void => {
      const width: number = Number(area.width) - 4;
      if (width > 0 && Math.abs(width - this.trackWidth) > 0.5) { this.trackWidth = width; }
    })
  }
}
