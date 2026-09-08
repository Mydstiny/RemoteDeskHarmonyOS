import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';
import { AppUiMetrics } from '../common/AppUiMetrics';
import { appUiButtonFill, appUiButtonText } from '../common/AppUiColorPolicy';

/** Free settings choice; its owner retains the value and persistence callback. */
@Component
export struct AppSettingsChoiceButton {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop label: string = '';
  @Prop isSelected: boolean = false;
  onSelect: () => void = (): void => {};

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }

  build() {
    Button({ type: ButtonType.Normal }) {
      Text(this.label).fontSize(13).fontFamily(AppConfig.fontFamily)
        .fontWeight(this.isSelected ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.isSelected ? appUiButtonText(this.accent) : this.pal().text2)
        .textAlign(TextAlign.Center)
    }
    .constraintSize({ minWidth: AppUiMetrics.minTouchTarget, minHeight: AppUiMetrics.minTouchTarget })
    .padding({ left: 12, right: 12, top: 10, bottom: 10 }).borderRadius(10)
    .backgroundColor(this.isSelected ? appUiButtonFill(this.accent) : this.pal().surface)
    .focusable(true).accessibilityText(this.label).accessibilitySelected(this.isSelected)
    .onClick(this.onSelect)
  }
}
