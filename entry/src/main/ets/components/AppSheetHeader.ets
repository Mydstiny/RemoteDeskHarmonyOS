import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';

// Free shared chrome. Uses APIs available on the retained API 23 installation target.
@Component
export struct AppSheetHeader {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop title: string = '';
  @Prop closeLabel: string = '';
  @Prop horizontalPadding: number = 24;
  onClose: () => void = (): void => {};

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }

  build() {
    Row({ space: 12 }) {
      Text(this.title).fontSize(20).fontWeight(FontWeight.Bold)
        .fontFamily(AppConfig.fontFamily).fontColor(this.pal().text)
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1).accessibilityText(this.title)
      Button({ type: ButtonType.Normal }) {
        if (this.closeLabel.length > 0) {
          Text(this.closeLabel).fontSize(14).fontFamily(AppConfig.fontFamily).fontColor(this.accent)
        } else {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
        }
      }
      .constraintSize({ minWidth: 44, minHeight: 44 }).padding(10).borderRadius(22)
      .backgroundColor(Color.Transparent).focusable(true)
      .accessibilityText('关闭' + this.title).onClick(this.onClose)
    }
    .width('100%').constraintSize({ minHeight: 64 })
    .padding({ left: this.horizontalPadding, right: this.horizontalPadding, top: 10, bottom: 10 })
  }
}
