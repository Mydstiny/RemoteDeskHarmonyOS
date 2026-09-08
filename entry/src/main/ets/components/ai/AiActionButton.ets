import { AppConfig, Palette, buildDark, buildLight } from '../../common/Theme';
import { AppUiMetrics } from '../../common/AppUiMetrics';
import { appUiButtonFill, appUiButtonText } from '../../common/AppUiColorPolicy';

/** AI actions use the application's shared typography, contrast and touch dimensions. */
@Component
export struct AiActionButton {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop label: string = '';
  @Prop primary: boolean = false;
  @Prop isEnabled: boolean = true;
  onAction: () => void = (): void => {};
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  build() {
    Button({ type: ButtonType.Normal }) {
      Text(this.label).fontSize(14).fontFamily(AppConfig.fontFamily).textAlign(TextAlign.Center)
        .fontColor(this.primary ? appUiButtonText(this.accent) : this.pal().text)
    }.width('100%').constraintSize({ minHeight: AppUiMetrics.minTouchTarget })
      .padding({ left: 12, right: 12, top: 10, bottom: 10 }).borderRadius(12)
      .backgroundColor(this.primary ? appUiButtonFill(this.accent) : this.pal().surface)
      .enabled(this.isEnabled).focusable(true).accessibilityText(this.label)
      .onClick((): void => { if (this.isEnabled) { this.onAction(); } })
  }
}
