import { settleBeforeLoop } from '../../common/AnimationLoop';
import { curves } from '@kit.ArkUI';
import { AppConfig, buildDark, buildLight, Palette } from '../../common/Theme';
import { appUiOnAccentText } from '../../common/AppUiColorPolicy';
import { GuideContentPage } from '../../services/GuideContentRegistry';
import { ReleaseNotePage } from '../../services/ReleaseNotesRegistry';
import { mixHex } from '../../services/pro/ProBadgeFlowPolicy';

/** Layouts at or above this width split each slide into a hero panel and a content column. */
const WIDE_LAYOUT_MIN_WIDTH: number = 560;
/** Room under the last note for the floating button (its height and a gap). */
const WHATS_NEW_ACTION_ROOM: number = 64;
const KEY_LEFT: number = 2014;
const KEY_RIGHT: number = 2015;
const KEY_ENTER: number = 2054;
const KEY_NUMPAD_ENTER: number = 2124;
const KEY_ESCAPE: number = 2070;

function tint(color: string, alpha: string): string {
  return /^#[0-9A-Fa-f]{6}$/.test(color) ? '#' + alpha + color.substring(1) : color;
}

/**
 * Slide-by-slide introduction used by the first-install guide and 「设置 → 教程 → 快速认识应用」.
 * Phones stack a hero above the text with a full-width button; Pad/PC split hero and text side by side.
 * Arrow keys, Enter and Esc work on PC.
 */
@Component
export struct GuideShowcase {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop pages: GuideContentPage[] = [];
  /** Shown on the first slide's top-right; empty hides it. */
  @Prop skipLabel: string = '跳过';
  @Prop finishLabel: string = '开始使用';
  /** Inside a sheet: sheet background, tighter paddings and a close button. */
  @Prop embedded: boolean = false;
  @Prop heading: string = '';
  onFinish: () => void = (): void => {};
  onSkip: () => void = (): void => {};
  @State index: number = 0;
  @State areaWidth: number = 360;
  /** Angle of the slowly turning orbit around each hero (render-thread animation, started once). */
  @State orbit: number = 0;
  private controller: SwiperController = new SwiperController();

  aboutToAppear(): void {
    setTimeout((): void => {
      settleBeforeLoop(this.getUIContext());
      this.getUIContext().animateTo({ duration: 24000, iterations: -1, curve: Curve.Linear,
        expectedFrameRateRange: { min: 15, max: 30, expected: 30 } }, (): void => { this.orbit = 360; });
    }, 60);
  }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  /** Each slide carries its own color; the app accent fills in for pages without one. */
  private hueOf(page: GuideContentPage): string {
    return /^#[0-9A-Fa-f]{6}$/.test(page.hue ?? '') ? (page.hue as string) : this.accentHex();
  }
  private accentHex(): string { return /^#[0-9A-Fa-f]{6}$/.test(this.accent) ? this.accent : '#007DFF'; }
  private currentHue(): string {
    return this.pages.length > 0 ? this.hueOf(this.pages[Math.min(this.index, this.pages.length - 1)]) : this.accentHex();
  }
  private light(hue: string): string { return mixHex(hue, '#FFFFFF', 0.35); }
  private wide(): boolean { return this.areaWidth >= WIDE_LAYOUT_MIN_WIDTH; }
  private last(): boolean { return this.index >= this.pages.length - 1; }
  private next(): void { if (this.last()) { this.onFinish(); } else { this.controller.showNext(); } }
  private previous(): void { if (this.index > 0) { this.controller.showPrevious(); } }
  private handleKey(event: KeyEvent): void {
    if (event.type !== KeyType.Down) { return; }
    if (event.keyCode === KEY_RIGHT) { this.next(); }
    else if (event.keyCode === KEY_LEFT) { this.previous(); }
    else if (event.keyCode === KEY_ENTER || event.keyCode === KEY_NUMPAD_ENTER) { this.next(); }
    else if (event.keyCode === KEY_ESCAPE && this.skipLabel.length > 0) { this.onSkip(); }
  }

  @Builder private icon(page: GuideContentPage, size: number) {
    if (page.glyph !== undefined) {
      SymbolGlyph(page.glyph).fontSize(size).fontColor([Color.White])
    } else {
      Image(page.symbol).width(size).height(size).fillColor(Color.White)
    }
  }

  @Builder private orbitDot(hue: string, size: number, x: number, y: number) {
    Circle().width(size).height(size).fill(hue).position({ x: x - size / 2, y: y - size / 2 })
      .shadow({ radius: 6, color: tint(hue, '80'), offsetY: 0 })
  }

  @Builder private hero(page: GuideContentPage, scale: number, active: boolean) {
    Stack() {
      // Glow, a slowly turning orbit with three lights, an inner disc and a glassy icon tile.
      Column().width(260 * scale).height(260 * scale).borderRadius(130 * scale)
        .radialGradient({ center: ['50%', '50%'], radius: 130 * scale,
          colors: [[tint(this.hueOf(page), '33'), 0], [tint(this.hueOf(page), '00'), 1]] })
      Stack() {
        Circle().width(220 * scale).height(220 * scale).fill(Color.Transparent)
          .stroke(tint(this.hueOf(page), '2E')).strokeWidth(1).strokeDashArray([4, 6])
        this.orbitDot(this.hueOf(page), 10 * scale, 110 * scale, 0)
        this.orbitDot(this.light(this.hueOf(page)), 7 * scale, 220 * scale * 0.93, 220 * scale * 0.75)
        this.orbitDot(tint(this.hueOf(page), 'B3'), 6 * scale, 220 * scale * 0.07, 220 * scale * 0.75)
      }.width(220 * scale).height(220 * scale).rotate({ angle: this.orbit })
      Circle().width(164 * scale).height(164 * scale)
        .fill(tint(this.hueOf(page), '14')).stroke(tint(this.hueOf(page), '2E')).strokeWidth(1)
      Stack() {
        Column().width('100%').height('100%')
          .linearGradient({ angle: 135, colors: [[this.light(this.hueOf(page)), 0], [this.hueOf(page), 0.55],
            [mixHex(this.hueOf(page), '#000000', 0.18), 1]] })
        // Glass highlight across the top half.
        Column().width('100%').height('50%').position({ x: 0, y: 0 })
          .linearGradient({ angle: 180, colors: [['#40FFFFFF', 0], ['#00FFFFFF', 1]] })
        this.icon(page, Math.round(50 * scale))
      }
      .width(112 * scale).height(112 * scale).borderRadius(34 * scale).clip(true)
      .border({ width: 1, color: '#33FFFFFF' })
      .shadow({ radius: 30, color: tint(this.hueOf(page), '66'), offsetY: 14 })
      .scale({ x: active ? 1 : 0.84, y: active ? 1 : 0.84 })
      .rotate({ angle: active ? 0 : -8 })
      .animation({ duration: 420, curve: curves.interpolatingSpring(0, 0.8, 300, 20) })
    }.width(260 * scale).height(260 * scale)
  }

  @Builder private tagChip(text: string, hue: string) {
    if (text.length > 0) {
      Text(text).fontSize(12).fontWeight(FontWeight.Medium).fontColor(hue).fontFamily(AppConfig.fontFamily)
        .padding({ left: 10, right: 10, top: 4, bottom: 4 }).borderRadius(12)
        .backgroundColor(tint(hue, '1A')).border({ width: 0.5, color: tint(hue, '33') })
    }
  }

  /** The active slide's text rises in; others wait below so swiping in replays it. */
  private textShift(at: number): number { return this.index === at ? 0 : 14; }
  private textOpacity(at: number): number { return this.index === at ? 1 : 0; }

  @Builder private points(page: GuideContentPage, wide: boolean, at: number) {
    if ((page.points ?? []).length > 0) {
      Column({ space: wide ? 12 : 10 }) {
        ForEach(page.points ?? [], (point: string, row: number): void => {
          Row({ space: 12 }) {
            Text((row + 1).toString()).fontSize(11).fontWeight(FontWeight.Bold).fontColor(Color.White)
              .width(20).height(20).borderRadius(10).textAlign(TextAlign.Center)
              .linearGradient({ angle: 135, colors: [[this.light(this.hueOf(page)), 0], [this.hueOf(page), 1]] })
              .margin({ top: 1 })
            Text(point).fontSize(wide ? 15 : 14).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily)
              .lineHeight(wide ? 21 : 20).layoutWeight(1)
          }.width('100%').alignItems(VerticalAlign.Top)
        }, (point: string, row: number): string => row.toString() + point)
      }
      .width('100%').padding(wide ? 18 : 16).borderRadius(20)
      .backgroundColor(this.embedded ? this.pal().card : tint(this.pal().card, 'CC'))
      .border({ width: 0.5, color: tint(this.hueOf(page), '26') })
      .opacity(this.textOpacity(at)).translate({ y: this.textShift(at) })
      .animation({ duration: 420, delay: 140, curve: Curve.FastOutSlowIn })
    }
  }

  @Builder private narrowSlide(page: GuideContentPage, at: number) {
    Scroll() {
      Column() {
        this.hero(page, this.embedded ? 0.72 : 0.92, this.index === at)
        Column({ space: 10 }) {
          this.tagChip(page.tag ?? '', this.hueOf(page))
          Text(page.title).fontSize(this.embedded ? 22 : 26).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
            .fontFamily(AppConfig.fontFamily).textAlign(TextAlign.Center)
          Text(page.desc).fontSize(this.embedded ? 14 : 15).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily)
            .lineHeight(this.embedded ? 21 : 23).textAlign(TextAlign.Center)
        }.alignItems(HorizontalAlign.Center).width('100%').margin({ top: this.embedded ? 4 : 12, bottom: 18 })
        .opacity(this.textOpacity(at)).translate({ y: this.textShift(at) })
        .animation({ duration: 420, delay: 60, curve: Curve.FastOutSlowIn })
        this.points(page, false, at)
      }.width('100%').padding({ left: 24, right: 24, top: 8, bottom: 16 }).alignItems(HorizontalAlign.Center)
      .constraintSize({ maxWidth: 520 })
    }.width('100%').height('100%').scrollBar(BarState.Off).align(Alignment.Center).edgeEffect(EdgeEffect.None)
  }

  @Builder private wideSlide(page: GuideContentPage, at: number) {
    Row({ space: 32 }) {
      Stack() {
        this.hero(page, this.embedded ? 0.85 : 1.1, this.index === at)
        Text((at + 1).toString().padStart(2, '0') + ' / ' + this.pages.length.toString().padStart(2, '0'))
          .fontSize(12).fontWeight(FontWeight.Medium).fontColor(tint(this.hueOf(page), 'CC'))
          .fontFamily(AppConfig.fontFamily).position({ x: 20, y: 18 })
      }
      .layoutWeight(1).height('100%').borderRadius(28)
      .linearGradient({ angle: 160, colors: [[tint(this.hueOf(page), '2A'), 0], [tint(this.hueOf(page), '08'), 1]] })
      .border({ width: 0.5, color: tint(this.hueOf(page), '33') })
      Scroll() {
        Column({ space: 14 }) {
          Column({ space: 14 }) {
            this.tagChip(page.tag ?? '', this.hueOf(page))
            Text(page.title).fontSize(this.embedded ? 24 : 30).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
              .fontFamily(AppConfig.fontFamily)
            Text(page.desc).fontSize(this.embedded ? 15 : 16).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily)
              .lineHeight(this.embedded ? 22 : 25)
          }.alignItems(HorizontalAlign.Start).width('100%')
          .opacity(this.textOpacity(at)).translate({ y: this.textShift(at) })
          .animation({ duration: 420, delay: 60, curve: Curve.FastOutSlowIn })
          this.points(page, true, at)
        }.alignItems(HorizontalAlign.Start).width('100%')
      }.layoutWeight(1.15).height('100%').scrollBar(BarState.Off).align(Alignment.Center).edgeEffect(EdgeEffect.None)
    }.width('100%').height('100%').padding({ left: this.embedded ? 20 : 40, right: this.embedded ? 20 : 40,
      top: 4, bottom: 4 })
  }

  @Builder private dots() {
    Row({ space: 6 }) {
      ForEach(this.pages, (_page: GuideContentPage, at: number): void => {
        Column().width(this.index === at ? 22 : 7).height(7).borderRadius(4)
          .backgroundColor(at <= this.index ? this.currentHue() : this.pal().divider)
          .opacity(at < this.index ? 0.45 : 1)
          .animation({ duration: 260, curve: Curve.FastOutSlowIn })
      }, (page: GuideContentPage): string => page.id)
    }
  }

  /** Thin segmented progress for the top bar on phones. */
  @Builder private progress() {
    Row({ space: 4 }) {
      ForEach(this.pages, (_page: GuideContentPage, at: number): void => {
        Column().layoutWeight(1).height(3).borderRadius(2)
          .backgroundColor(at <= this.index ? this.currentHue() : this.pal().divider)
          .animation({ duration: 260, curve: Curve.FastOutSlowIn })
      }, (page: GuideContentPage): string => 'p' + page.id)
    }.layoutWeight(1).margin({ right: 12 })
  }

  @Builder private primaryButton(fill: boolean) {
    Button(this.last() ? this.finishLabel : '下一步')
      .height(this.embedded ? 44 : 48).fontSize(16).fontWeight(FontWeight.Medium).fontColor(Color.White)
      .borderRadius(this.embedded ? 21 : 24)
      .linearGradient({ angle: 100, colors: [[this.light(this.currentHue()), 0], [this.currentHue(), 1]] })
      .padding({ left: 28, right: 28 })
      .width(fill ? '100%' : undefined)
      .shadow({ radius: 16, color: tint(this.currentHue(), '4D'), offsetY: 6 })
      .onClick((): void => { this.next(); })
  }

  build() {
    Stack() {
      // Soft radial glows; blur() on shapes renders hard edges on some devices.
      Column().width(440).height(440).position({ x: -180, y: -170 })
        .radialGradient({ center: ['50%', '50%'], radius: 220,
          colors: [[tint(this.currentHue(), '2B'), 0], [tint(this.currentHue(), '00'), 1]] })
      Column().width(400).height(400).position({ x: this.areaWidth - 220, y: '56%' })
        .radialGradient({ center: ['50%', '50%'], radius: 200,
          colors: [[tint(this.light(this.currentHue()), '22'), 0], [tint(this.currentHue(), '00'), 1]] })
      Column() {
        Row() {
          if (this.heading.length > 0) {
            Text(this.heading).fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
              .fontFamily(AppConfig.fontFamily)
          } else if (!this.wide()) {
            this.progress()
          }
          if (this.heading.length > 0 || this.wide()) { Blank() }
          if (this.skipLabel.length > 0 && !this.last()) {
            Text(this.skipLabel).fontSize(15).fontColor(this.pal().text2).padding(8)
              .onClick((): void => { this.onSkip(); })
          }
        }.width('100%').height(48).padding({ left: this.wide() && !this.embedded ? 40 : 22, right: 14 })
        Swiper(this.controller) {
          ForEach(this.pages, (page: GuideContentPage, at: number): void => {
            if (this.wide()) { this.wideSlide(page, at) } else { this.narrowSlide(page, at) }
          }, (page: GuideContentPage): string => page.id + (this.wide() ? ':w' : ':n'))
        }
        .loop(false).indicator(false).duration(320).curve(Curve.FastOutSlowIn)
        .onChange((at: number): void => { this.index = at; })
        .layoutWeight(1).width('100%')
        if (this.wide()) {
          Row({ space: 12 }) {
            this.dots()
            Blank()
            if (this.index > 0) {
              Button('上一步').height(this.embedded ? 42 : 48).fontSize(15).fontColor(this.pal().text)
                .backgroundColor(this.pal().surface).borderRadius(this.embedded ? 21 : 24).padding({ left: 22, right: 22 })
                .onClick((): void => { this.previous(); })
            }
            this.primaryButton(false)
          }.width('100%').padding({ left: this.embedded ? 22 : 40, right: this.embedded ? 22 : 40, top: 12,
            bottom: this.embedded ? 20 : 32 })
        } else {
          // 上一步 sits beside the main button: a separate line at the very bottom fell under the system
          // navigation bar and could not be tapped.
          Column({ space: 16 }) {
            this.dots()
            Row({ space: 10 }) {
              if (this.index > 0) {
                Button('上一步').height(this.embedded ? 44 : 48).fontSize(15).fontColor(this.pal().text)
                  .backgroundColor(this.pal().surface).borderRadius(this.embedded ? 22 : 24)
                  .padding({ left: 20, right: 20 })
                  .onClick((): void => { this.previous(); })
              }
              Column() { this.primaryButton(true) }.layoutWeight(1)
            }.width('100%')
          }.width('100%').padding({ left: 24, right: 24, top: 8, bottom: this.embedded ? 30 : 28 })
          .constraintSize({ maxWidth: 520 })
        }
      }.width('100%').height('100%')
    }
    .width('100%').height('100%').clip(true)
    .backgroundColor(this.embedded ? this.pal().sheetBg : this.pal().bg)
    .focusable(true).defaultFocus(true)
    .onKeyEvent((event: KeyEvent): void => { this.handleKey(event); })
    .onAreaChange((_old: Area, area: Area): void => {
      const width: number = Number(area.width);
      if (width > 0 && Math.abs(width - this.areaWidth) > 1) { this.areaWidth = width; }
    })
  }
}

function tagColor(tag: string, accent: string): string {
  if (tag === '改进') { return '#30A46C'; }
  if (tag === '修复') { return '#F08C00'; }
  if (tag === '即将推出') { return '#9B5DE5'; }
  if (tag === '免费试用') { return '#E2557B'; }
  if (tag === 'Beta') { return '#7B61FF'; }
  return accent;
}

/**
 * 「新功能」 list for a release: version, a one-line headline and every change with a colored tag. Two columns on
 * wide windows. Used by the post-update sheet and 「设置 → 本版本更新日志」.
 */
@Component
export struct WhatsNewList {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop version: string = '';
  @Prop headline: string = '';
  @Prop items: ReleaseNotePage[] = [];
  @Prop primaryLabel: string = '继续';
  @Prop showClose: boolean = false;
  onPrimary: () => void = (): void => {};
  onClose: () => void = (): void => {};
  @State areaWidth: number = 360;

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private wide(): boolean { return this.areaWidth >= WIDE_LAYOUT_MIN_WIDTH; }
  private rows(): ReleaseNotePage[][] {
    const size: number = this.wide() ? 2 : 1;
    const result: ReleaseNotePage[][] = [];
    for (let start: number = 0; start < this.items.length; start += size) {
      result.push(this.items.slice(start, start + size));
    }
    return result;
  }

  @Builder private item(note: ReleaseNotePage) {
    Row({ space: 14 }) {
      Column() {
        if (note.glyph !== undefined) {
          SymbolGlyph(note.glyph).fontSize(22).fontColor([tagColor(note.tag ?? '', this.accent)])
        } else {
          Image(note.symbol).width(22).height(22).fillColor(tagColor(note.tag ?? '', this.accent))
        }
      }.width(44).height(44).borderRadius(14).justifyContent(FlexAlign.Center)
      .backgroundColor(tint(tagColor(note.tag ?? '', this.accent), '1F'))
      Column({ space: 5 }) {
        Row({ space: 8 }) {
          Text(note.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
            .fontFamily(AppConfig.fontFamily).layoutWeight(1).maxLines(2)
          if ((note.tag ?? '').length > 0) {
            Text(note.tag).fontSize(11).fontColor(tagColor(note.tag ?? '', this.accent))
              .padding({ left: 7, right: 7, top: 2, bottom: 2 }).borderRadius(8)
              .backgroundColor(tint(tagColor(note.tag ?? '', this.accent), '1A'))
          }
        }.width('100%').alignItems(VerticalAlign.Top)
        Text(note.desc).fontSize(13).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily).lineHeight(20)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }
    .width('100%').padding(14).borderRadius(18).alignItems(VerticalAlign.Top)
    .backgroundColor(this.pal().card).border({ width: 0.5, color: this.pal().cardBorder })
  }

  build() {
    Column() {
      Row() {
        Text('版本 ' + this.version).fontSize(12).fontWeight(FontWeight.Medium).fontColor(Color.White)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 }).borderRadius(12)
          .linearGradient({ angle: 120, colors: [[this.accent, 0], [tint(this.accent, 'B3'), 1]] })
        Blank()
        if (this.showClose) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2]).padding(8)
            .onClick((): void => { this.onClose(); })
        }
      }.width('100%').height(40)
      Text('新功能').fontSize(this.wide() ? 30 : 28).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        .fontFamily(AppConfig.fontFamily).width('100%').margin({ top: 6 })
      if (this.headline.length > 0) {
        Text(this.headline).fontSize(14).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily).lineHeight(21)
          .width('100%').margin({ top: 6 })
      }
      // The button floats over the list (the list scrolls under it) instead of a bar that cut the cards off.
      Stack({ alignContent: Alignment.Bottom }) {
      Scroll() {
        Column({ space: 10 }) {
          ForEach(this.rows(), (line: ReleaseNotePage[]): void => {
            Row({ space: 10 }) {
              ForEach(line, (note: ReleaseNotePage): void => {
                Column() { this.item(note) }.layoutWeight(1)
              }, (note: ReleaseNotePage): string => note.id)
              if (line.length === 1 && this.wide()) { Blank().layoutWeight(1) }
            }.width('100%').alignItems(VerticalAlign.Top)
          }, (line: ReleaseNotePage[], at: number): string => at.toString() + (this.wide() ? 'w' : 'n') +
            line.map((note: ReleaseNotePage): string => note.id).join(','))
          Text('可在「设置 → 教程 → 本版本更新日志」随时回看').fontSize(11).fontColor(this.pal().text3)
            .fontFamily(AppConfig.fontFamily).width('100%').textAlign(TextAlign.Center).margin({ top: 6 })
        }.width('100%').padding({ top: 16, bottom: 12 + WHATS_NEW_ACTION_ROOM })
      }.width('100%').height('100%').scrollBar(BarState.Off).align(Alignment.Top).edgeEffect(EdgeEffect.Spring)
      Button(this.primaryLabel).width('100%').height(48).fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(appUiOnAccentText(this.accent)).backgroundColor(this.accent).borderRadius(24)
        .shadow({ radius: 20, color: tint(this.accent, '59'), offsetY: 8 })
        .constraintSize({ maxWidth: 520 })
        .onClick((): void => { this.onPrimary(); })
      }.layoutWeight(1).width('100%')
    }
    .width('100%').height('100%').padding({ left: 22, right: 22, top: 14, bottom: 28 })
    .onAreaChange((_old: Area, area: Area): void => {
      const width: number = Number(area.width);
      if (width > 0 && Math.abs(width - this.areaWidth) > 1) { this.areaWidth = width; }
    })
  }
}
