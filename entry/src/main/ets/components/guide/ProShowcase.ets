import { AppConfig, buildDark, buildLight, Palette } from '../../common/Theme';
import { ProBadge } from '../ProBadge';
import { ProIntroItem, proIntroItems, proIntroPromises, proIntroStatus } from '../../services/ProIntroRegistry';
import { PRO_COMPLIMENTARY_TRIAL } from '../../services/pro/ProComplimentaryPolicy';
import { PRO_BADGE_PALETTES } from '../../services/pro/ProBadgeFlowPolicy';

const WIDE_LAYOUT_MIN_WIDTH: number = 560;

function tint(color: string, alpha: string): string {
  return /^#[0-9A-Fa-f]{6}$/.test(color) ? '#' + alpha + color.substring(1) : color;
}

/** The 极光流彩 Pro mark (capsule, flowing, aurora colors): the default look, and light on the GPU. */
const AURORA_COLORS: string = JSON.stringify(PRO_BADGE_PALETTES[0].colors);

/**
 * Pro 功能介绍: a dark hero with the 极光流彩 Pro mark, the trial promises, AI 助理 as one large featured card, then a
 * card per Pro area. Shown after the first-install guide, after the post-update list and from 「设置 → 教程」. In
 * 1.2.0 everyone has Pro free: the one button is 立即试用 (the startup popup cannot be dismissed any other way).
 */
@Component
export struct ProShowcase {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  /** The one button: 立即试用 (or 继续使用 Pro once the trial is on). The caller records the trial. */
  @Prop actionLabel: string = '立即试用';
  @Prop showClose: boolean = false;
  onAction: () => void = (): void => {};
  onClose: () => void = (): void => {};
  @State areaWidth: number = 360;
  @State entered: boolean = false;
  private items: ProIntroItem[] = proIntroItems().filter((item: ProIntroItem): boolean => item.featured !== true);
  private featured: ProIntroItem[] = proIntroItems().filter((item: ProIntroItem): boolean => item.featured === true);

  aboutToAppear(): void {
    setTimeout((): void => { this.entered = true; }, 30);
  }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private wide(): boolean { return this.areaWidth >= WIDE_LAYOUT_MIN_WIDTH; }
  private rows(): ProIntroItem[][] {
    const size: number = this.wide() ? 2 : 1;
    const result: ProIntroItem[][] = [];
    for (let start: number = 0; start < this.items.length; start += size) {
      result.push(this.items.slice(start, start + size));
    }
    return result;
  }

  @Builder private hero() {
    Stack() {
      // Deep plate (the Stack's own gradient) with two soft glows behind the Pro mark. The glows are positioned, so
      // only the text column sizes the hero.
      Column().width(320).height(320).position({ x: -120, y: -150 })
        .radialGradient({ center: ['50%', '50%'], radius: 160, colors: [['#553A5BC8', 0], ['#003A5BC8', 1]] })
      Column().width(260).height(260).position({ x: this.areaWidth - 180, y: 40 })
        .radialGradient({ center: ['50%', '50%'], radius: 130, colors: [[tint(this.accent, '40'), 0], [tint(this.accent, '00'), 1]] })
      Column({ space: 12 }) {
        ProBadge({ large: true, previewStyle: 'capsule', previewMotion: 'sweep', previewColors: AURORA_COLORS })
          .scale({ x: 1.5, y: 1.5 }).margin({ bottom: 8 })
        Text('RemoteDesktop Pro').fontSize(this.wide() ? 30 : 26).fontWeight(FontWeight.Bold)
          .fontColor(Color.White).fontFamily(AppConfig.fontFamily)
        Text('让每次连接更得心应手').fontSize(15).fontColor('#C8D2F0').fontFamily(AppConfig.fontFamily)
        if (PRO_COMPLIMENTARY_TRIAL) {
          Text('1.2.0 起 · 全部 Pro 功能免费试用').fontSize(13).fontWeight(FontWeight.Medium).fontColor(Color.White)
            .fontFamily(AppConfig.fontFamily).padding({ left: 12, right: 12, top: 5, bottom: 5 }).borderRadius(14)
            .linearGradient({ angle: 100, colors: [['#665B8CFF', 0], ['#66B455FF', 1]] })
            .border({ width: 0.5, color: '#4DFFFFFF' })
        }
        Row({ space: 8 }) {
          ForEach(proIntroPromises(), (promise: string): void => {
            Text(promise).fontSize(12).fontColor('#E8EEF8').fontFamily(AppConfig.fontFamily)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 }).borderRadius(12)
              .backgroundColor('#26FFFFFF').border({ width: 0.5, color: '#33FFFFFF' })
          }, (promise: string): string => promise)
        }.margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Center).padding({ top: 28, bottom: 24, left: 16, right: 16 })
      .opacity(this.entered ? 1 : 0).translate({ y: this.entered ? 0 : 12 })
      .animation({ duration: 420, curve: Curve.FastOutSlowIn })
    }
    .width('100%').borderRadius(26).clip(true)
    .linearGradient({ angle: 150, colors: [['#1D2856', 0], ['#0B1028', 0.6], ['#121A3C', 1]] })
    .shadow({ radius: 24, color: '#401D2856', offsetY: 10 })
  }

  /** AI 助理: first, across the whole width, larger, with its own gradient rim and what it does line by line. */
  @Builder private featuredCard(item: ProIntroItem) {
    Column({ space: 14 }) {
      Row({ space: 14 }) {
        Column() {
          SymbolGlyph(item.glyph).fontSize(30).fontColor([Color.White])
        }
        .width(60).height(60).borderRadius(18).justifyContent(FlexAlign.Center)
        .linearGradient({ angle: 135, colors: [[item.hue, 0], [item.hue2, 1]] })
        .shadow({ radius: 16, color: tint(item.hue, '66'), offsetY: 6 })
        Column({ space: 4 }) {
          Text(item.title).fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
            .fontFamily(AppConfig.fontFamily)
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(item.tags, (tag: string): void => {
              Text(tag).fontSize(12).fontColor(item.hue).fontFamily(AppConfig.fontFamily)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 }).borderRadius(9).margin({ right: 6, top: 4 })
                .backgroundColor(tint(item.hue, '1A'))
            }, (tag: string): string => tag)
          }.width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      Text(item.desc).fontSize(15).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily).lineHeight(23)
        .width('100%')
      Column({ space: 9 }) {
        ForEach(item.points ?? [], (point: string): void => {
          Row({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(16).fontColor([item.hue])
              .margin({ top: 2 })
            Text(point).fontSize(13).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily).lineHeight(20)
              .layoutWeight(1)
          }.width('100%').alignItems(VerticalAlign.Top)
        }, (point: string): string => point)
      }.width('100%')
    }
    .width('100%').padding(20).borderRadius(24).alignItems(HorizontalAlign.Start)
    .backgroundColor(this.pal().card)
    .border({ width: 1.5, color: tint(item.hue, '8C') })
    .shadow({ radius: 22, color: tint(item.hue2, '33'), offsetY: 8 })
    .opacity(this.entered ? 1 : 0).translate({ y: this.entered ? 0 : 16 })
    .animation({ duration: 420, delay: 80, curve: Curve.FastOutSlowIn })
  }

  @Builder private card(item: ProIntroItem, order: number) {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        Column() {
          SymbolGlyph(item.glyph).fontSize(22).fontColor([Color.White])
        }
        .width(44).height(44).borderRadius(14).justifyContent(FlexAlign.Center)
        .linearGradient({ angle: 135, colors: [[item.hue, 0], [item.hue2, 1]] })
        .shadow({ radius: 12, color: tint(item.hue, '55'), offsetY: 4 })
        Text(item.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          .fontFamily(AppConfig.fontFamily).layoutWeight(1)
      }.width('100%')
      Text(item.desc).fontSize(13).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily).lineHeight(20)
        .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(item.tags, (tag: string): void => {
          Text(tag).fontSize(11).fontColor(item.hue).fontFamily(AppConfig.fontFamily)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 }).borderRadius(9).margin({ right: 6, bottom: 4 })
            .backgroundColor(tint(item.hue, '1A'))
        }, (tag: string): string => tag)
      }.width('100%')
    }
    .width('100%').padding(16).borderRadius(20).alignItems(HorizontalAlign.Start)
    .backgroundColor(this.pal().card).border({ width: 0.5, color: this.pal().cardBorder })
    .opacity(this.entered ? 1 : 0).translate({ y: this.entered ? 0 : 16 })
    .animation({ duration: 380, delay: 120 + Math.min(order, 6) * 50, curve: Curve.FastOutSlowIn })
  }

  build() {
    Column() {
      Row() {
        Text('Pro 功能介绍').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text3)
          .fontFamily(AppConfig.fontFamily)
        Blank()
        if (this.showClose) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2]).padding(8)
            .onClick((): void => { this.onClose(); })
        }
      }.width('100%').height(36)
      Scroll() {
        Column({ space: 12 }) {
          this.hero()
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.info_circle_fill')).fontSize(15).fontColor([this.pal().text3])
            Text(proIntroStatus(PRO_COMPLIMENTARY_TRIAL)).fontSize(12).fontColor(this.pal().text2)
              .fontFamily(AppConfig.fontFamily).lineHeight(18).layoutWeight(1)
          }.width('100%').alignItems(VerticalAlign.Top).padding({ left: 4, right: 4, top: 2, bottom: 2 })
          ForEach(this.featured, (item: ProIntroItem): void => { this.featuredCard(item) },
            (item: ProIntroItem): string => 'featured-' + item.id)
          ForEach(this.rows(), (line: ProIntroItem[], at: number): void => {
            Row({ space: 12 }) {
              ForEach(line, (item: ProIntroItem, column: number): void => {
                Column() { this.card(item, at * 2 + column) }.layoutWeight(1)
              }, (item: ProIntroItem): string => item.id)
              if (line.length === 1 && this.wide()) { Blank().layoutWeight(1) }
            }.width('100%').alignItems(VerticalAlign.Top)
          }, (line: ProIntroItem[], at: number): string => at.toString() + (this.wide() ? 'w' : 'n') +
            line.map((item: ProIntroItem): string => item.id).join(','))
          Text('全部协议的连接、正常画质、键鼠操作、基础文件传输与安全更新永久免费；试用期间其余 Pro 功能也全部免费。')
            .fontSize(12).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily).lineHeight(18)
            .width('100%').textAlign(TextAlign.Center).margin({ top: 4 })
        }.width('100%').padding({ top: 4, bottom: 12 })
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off).align(Alignment.Top).edgeEffect(EdgeEffect.Spring)
      // One button: 立即试用. There is nothing to decline — the trial is on for everyone.
      Row() {
        Button(this.actionLabel).layoutWeight(1).height(50).fontSize(17).fontWeight(FontWeight.Bold)
          .fontColor(Color.White).borderRadius(25)
          .linearGradient({ angle: 100, colors: [['#5B8CFF', 0], ['#B455FF', 1]] })
          .shadow({ radius: 18, color: '#665B8CFF', offsetY: 6 })
          .onClick((): void => { this.onAction(); })
      }.width('100%')
    }
    // Bottom room for the system navigation bar under sheets.
    .width('100%').height('100%').padding({ left: 20, right: 20, top: 10, bottom: 28 })
    .onAreaChange((_old: Area, area: Area): void => {
      const width: number = Number(area.width);
      if (width > 0 && Math.abs(width - this.areaWidth) > 1) { this.areaWidth = width; }
    })
  }
}
