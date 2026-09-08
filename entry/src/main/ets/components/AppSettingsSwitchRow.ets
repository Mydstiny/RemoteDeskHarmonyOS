import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';
import { AppUiMetrics } from '../common/AppUiMetrics';

/** Native Switch keeps its keyboard and accessibility state; the row does not add a second click handler. */
@Component
export struct AppSettingsSwitchRow {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop icon: Resource | undefined = undefined;
  @Prop title: string = '';
  @Prop detail: string = '';
  @Prop isOn: boolean = false;
  @Prop isEnabled: boolean = true;
  @Prop accessibilityLabel: string = '';
  onChange: (value: boolean) => void = (_value: boolean): void => {};
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  build() {
    Row({ space: 12 }) {
      if (this.icon !== undefined) {
        SymbolGlyph(this.icon as Resource).fontSize(22).fontColor([this.pal().text2]).width(24)
          .accessibilityLevel('no')
      }
      Column({ space: 4 }) {
        Text(this.title).fontSize(15).fontWeight(FontWeight.Medium)
          .fontFamily(AppConfig.fontFamily).fontColor(this.pal().text).width('100%')
        if (this.detail.length > 0) {
          Text(this.detail).fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor(this.accent)
        .constraintSize({ minWidth: 52, minHeight: AppUiMetrics.minTouchTarget })
        .enabled(this.isEnabled).opacity(this.isEnabled ? 1 : 0.45).focusable(true)
        .accessibilityText(this.accessibilityLabel.length > 0 ? this.accessibilityLabel : this.title)
        .onChange((value: boolean): void => { if (this.isEnabled) { this.onChange(value); } })
    }.width('100%').constraintSize({ minHeight: AppUiMetrics.settingsRowMinHeight })
      .padding({ left: 15, right: 12, top: 10, bottom: 10 })
  }
}
