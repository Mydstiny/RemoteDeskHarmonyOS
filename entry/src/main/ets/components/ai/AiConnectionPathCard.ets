import { AppConfig, Palette, buildDark, buildLight } from '../../common/Theme';
import { appUiButtonText } from '../../common/AppUiColorPolicy';
import { AiTransportKind } from '../../services/ai/AiModels';

/** Connection route card shared by the AI host wizard. */
@Component
export struct AiConnectionPathCard {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop path: AiTransportKind = 'lan';
  @Prop isSelected: boolean = false;
  @Prop isEnabled: boolean = true;
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop status: string = '';
  onSelect: () => void = (): void => {};

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }

  build() {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(this.title).fontSize(16).fontWeight(FontWeight.Medium)
          .fontFamily(AppConfig.fontFamily).fontColor(this.pal().text)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.subtitle).fontSize(12).fontFamily(AppConfig.fontFamily)
          .fontColor(this.pal().text3).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (this.status !== '') {
        Text(this.status).fontSize(11).fontFamily(AppConfig.fontFamily)
          .fontColor(this.isSelected ? appUiButtonText(this.accent) : this.pal().text3)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(8).backgroundColor(this.isSelected ? this.accent : this.pal().surface)
      }
    }
    .width('100%').height(68).padding({ left: 18, right: 18 })
    .borderRadius(16).backgroundColor(this.pal().surface)
    .border({ width: this.isSelected ? 1.5 : 0.5,
      color: this.isSelected ? this.accent : this.pal().cardBorder, style: BorderStyle.Solid })
    .opacity(this.isEnabled ? 1 : 0.52)
    .focusable(this.isEnabled).accessibilityText(this.title).accessibilitySelected(this.isSelected)
    .enabled(this.isEnabled)
    .onClick((): void => { if (this.isEnabled) { this.onSelect(); } });
  }
}
