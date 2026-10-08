import { AppConfig, Palette, buildDark, buildLight } from '../../common/Theme';
import { appUiButtonText } from '../../common/AppUiColorPolicy';
import { AiBackend } from '../../services/ai/AiModels';

/** Large backend option card shared by AI add, settings and install surfaces. */
@Component
export struct AiBackendChoiceCard {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop backend: AiBackend = 'codex';
  @Prop isSelected: boolean = false;
  @Prop title: string = '';
  @Prop subtitle: string = '';
  onSelect: () => void = (): void => {};

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }

  build() {
    // Use the same Row container as the protocol picker. Native Button applies
    // its own rectangular clipping on the device and hides the requested radius.
    Row({ space: 12 }) {
      Column() {
        Text(this.title).fontSize(16).fontWeight(FontWeight.Medium)
          .fontFamily(AppConfig.fontFamily).fontColor(this.pal().text)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.subtitle).fontSize(12).fontFamily(AppConfig.fontFamily)
          .fontColor(this.pal().text3).margin({ top: 3 })
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (this.isSelected) {
        Text('已选').fontSize(11).fontFamily(AppConfig.fontFamily)
          .fontColor(appUiButtonText(this.accent))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(8).backgroundColor(this.accent)
      }
    }
    .width('100%').height(68).padding({ left: 18, right: 18 })
    .borderRadius(16).backgroundColor(this.pal().surface)
    .border({ width: this.isSelected ? 1.5 : 0.5,
      color: this.isSelected ? this.accent : this.pal().cardBorder, style: BorderStyle.Solid })
    .focusable(true).accessibilityText(this.title).accessibilitySelected(this.isSelected)
    .onClick((): void => { this.onSelect(); });
  }
}
