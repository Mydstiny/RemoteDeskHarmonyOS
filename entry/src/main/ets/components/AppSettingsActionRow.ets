import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';
import { AppUiMetrics } from '../common/AppUiMetrics';

/** Free navigation row; the owning page keeps all routing and permission decisions. */
@Component
export struct AppSettingsActionRow {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop icon: Resource | undefined = undefined;
  @Prop imageIcon: boolean = false;
  @Prop title: string = '';
  @Prop detail: string = '';
  @Prop isEnabled: boolean = true;
  onAction: () => void = (): void => {};
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  build() {
    // Native Button applies rectangular clipping on some HarmonyOS builds;
    // keep the action semantics on a rounded Row so settings cards render
    // consistently with the other shared protocol cards.
    Row({ space: 12 }) {
      if (this.icon !== undefined) {
        Row() {
          if (this.imageIcon) {
            Image(this.icon as Resource).width(22).height(22).fillColor(this.pal().text2)
              .accessibilityLevel('no')
          } else {
            SymbolGlyph(this.icon as Resource).fontSize(22).fontColor([this.pal().text2])
              .accessibilityLevel('no')
          }
        }.width(34).height(34).borderRadius(10).backgroundColor(this.pal().surface)
          .justifyContent(FlexAlign.Center)
      }
      Column({ space: 4 }) {
        Text(this.title).fontSize(16).fontWeight(FontWeight.Medium)
          .fontFamily(AppConfig.fontFamily).fontColor(this.pal().text).width('100%')
        if (this.detail.length > 0) {
          Text(this.detail).fontSize(12).fontFamily(AppConfig.fontFamily)
            .fontColor(this.pal().text2).width('100%')
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(18).fontColor([this.pal().text2])
        .accessibilityLevel('no')
    }.width('100%').constraintSize({ minHeight: AppUiMetrics.sheetHeaderMinHeight })
      .padding({ left: 16, right: 18, top: 12, bottom: 12 })
      .borderRadius(20).backgroundColor(this.pal().card)
      .border({ width: 0.5, color: this.pal().cardBorder })
      .opacity(this.isEnabled ? 1 : 0.52).enabled(this.isEnabled).focusable(this.isEnabled)
      .accessibilityText(this.title + (this.detail.length > 0 ? '，' + this.detail : ''))
      .onClick((): void => { if (this.isEnabled) { this.onAction(); } })
  }
}
