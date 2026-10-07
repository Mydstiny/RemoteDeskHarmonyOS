import { curves } from '@kit.ArkUI';
import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';

/**
 * A segmented switch whose selected pill slides to the chosen option with a spring (the system's segmented button),
 * the labels easing between their colours. Used for 手机 / Pad / PC in the operation guide and 作为密钥 / 使用手机密钥
 * in 手机通行密钥.
 */
@Component
export struct SlidingSegment {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop labels: string[] = [];
  @Prop @Watch('follow') selected: number = 0;
  @Prop itemHeight: number = 34;
  @Prop radius: number = 9;
  onSelect: (index: number) => void = (_index: number): void => {};
  /** Where the pill is drawn (it chases `selected` with a spring). */
  @State private shown: number = 0;
  @State private trackWidth: number = 0;

  aboutToAppear(): void { this.shown = this.selected; }

  /** A change made from outside (a default chosen later, a search) slides the pill too. */
  private follow(): void {
    if (this.shown === this.selected) { return; }
    this.getUIContext().animateTo({ curve: curves.springMotion(0.36, 0.86) }, (): void => { this.shown = this.selected; });
  }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }

  private itemWidth(): number {
    const count = Math.max(1, this.labels.length);
    return Math.max(0, (this.trackWidth - 6 - (count - 1) * 4) / count);
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      if (this.trackWidth > 0) {
        Column().width(this.itemWidth()).height(this.itemHeight).borderRadius(this.radius)
          .backgroundColor(this.pal().card)
          .shadow({ radius: 6, color: this.theme === 'light' ? '#1A000000' : '#40000000', offsetY: 1 })
          .translate({ x: this.shown * (this.itemWidth() + 4) })
      }
      Row({ space: 4 }) {
        ForEach(this.labels, (label: string, index: number): void => {
          Text(label).fontSize(13).fontFamily(AppConfig.fontFamily)
            .fontWeight(this.shown === index ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.shown === index ? this.pal().text : this.pal().text2)
            .animation({ duration: 200, curve: Curve.FastOutSlowIn })
            .textAlign(TextAlign.Center).layoutWeight(1).height(this.itemHeight)
            .accessibilityText((this.selected === index ? '已选择 ' : '') + label)
            .onClick((): void => {
              if (this.selected === index) { return; }
              this.getUIContext().animateTo({ curve: curves.springMotion(0.36, 0.86) }, (): void => { this.shown = index; });
              this.onSelect(index);
            })
        }, (label: string): string => label)
      }.width('100%')
    }.width('100%').padding(3).borderRadius(this.radius + 3).backgroundColor(this.pal().surface)
    .onAreaChange((_old: Area, next: Area): void => {
      const width = Number(next.width);
      if (Number.isFinite(width) && Math.abs(width - this.trackWidth) > 0.5) { this.trackWidth = width; }
    })
  }
}
