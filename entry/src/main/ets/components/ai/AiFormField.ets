import { AppConfig, Palette, buildDark, buildLight } from '../../common/Theme';
import { AppUiMetrics } from '../../common/AppUiMetrics';

@Component
export struct AiFormField {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop title: string = '';
  @Prop value: string = '';
  @Prop hint: string = '';
  @Prop isEnabled: boolean = true;
  @Prop inputType: InputType = InputType.Normal;
  @Prop limit: number = 1024;
  onChange: (value: string) => void = (_value: string): void => {};
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  build() {
    Column({ space: 8 }) {
      Text(this.title).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
      TextInput({ text: this.value, placeholder: this.hint }).type(this.inputType).maxLength(this.limit)
        .constraintSize({ minHeight: AppUiMetrics.minTouchTarget }).fontSize(14).fontFamily(AppConfig.fontFamily)
        .padding({ left: 12, right: 12, top: 10, bottom: 10 }).borderRadius(12)
        .backgroundColor(this.pal().surface).fontColor(this.pal().text)
        .enabled(this.isEnabled).accessibilityText(this.title).onChange((value: string): void => {
          if (this.isEnabled) { this.onChange(value); }
        })
    }.width('100%')
  }
}
