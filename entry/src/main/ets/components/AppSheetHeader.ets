import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';
import { AppUiMetrics } from '../common/AppUiMetrics';
import { appUiButtonFill, appUiButtonText, appUiOnAccentText } from '../common/AppUiColorPolicy';
import { ProBadge } from './ProBadge';
import { SettingsSavedBadge } from './SettingsSavedBadge';

// Free shared chrome. Uses APIs available on the retained API 23 installation target.
@Component
export struct AppSheetHeader {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop closeLabel: string = '';
  @Prop actionLabel: string = '';
  @Prop actionEnabled: boolean = true;
  @Prop showProBadge: boolean = false;
  @Prop horizontalPadding: number = 24;
  /** Settings sheets (全新视觉): white text on the accent unless white is unreadable, like the rest of settings. */
  @Prop whiteOnAccent: boolean = false;
  /** Bump after an instant save to flash 已保存 beside the title; 0 never shows it. */
  @Prop savedTick: number = 0;
  onClose: () => void = (): void => {};
  onAction: () => void = (): void => {};

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }

  build() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(this.title).fontSize(20).fontWeight(FontWeight.Bold)
          .fontFamily(AppConfig.fontFamily).fontColor(this.pal().text)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%').accessibilityText(this.title)
        if (this.subtitle.length > 0) {
          Text(this.subtitle).fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2)
            .width('100%')
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (this.savedTick > 0) {
        SettingsSavedBadge({ savedTick: this.savedTick })
      }
      if (this.showProBadge) {
        ProBadge()
      }
      Button({ type: ButtonType.Normal }) {
        if (this.closeLabel.length > 0) {
          Text(this.closeLabel).fontSize(14).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2)
        } else {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
        }
      }
      .constraintSize({ minWidth: AppUiMetrics.minTouchTarget, minHeight: AppUiMetrics.minTouchTarget })
      .padding(10).borderRadius(22)
      .backgroundColor(Color.Transparent).focusable(true)
      .accessibilityText('关闭' + this.title).onClick(this.onClose)
      if (this.actionLabel.length > 0) {
        Button(this.actionLabel, { type: ButtonType.Normal })
          .fontSize(14).fontFamily(AppConfig.fontFamily).fontWeight(FontWeight.Medium)
          .constraintSize({ minWidth: AppUiMetrics.minTouchTarget, minHeight: AppUiMetrics.minTouchTarget })
          .padding({ left: 12, right: 12, top: 10, bottom: 10 }).borderRadius(22)
          .backgroundColor(appUiButtonFill(this.accent))
          .fontColor(this.whiteOnAccent ? appUiOnAccentText(this.accent) : appUiButtonText(this.accent))
          .enabled(this.actionEnabled).focusable(true)
          .accessibilityText(this.actionLabel + this.title).onClick((): void => {
            if (this.actionEnabled) { this.onAction(); }
          })
      }
    }
    .width('100%').constraintSize({ minHeight: AppUiMetrics.sheetHeaderMinHeight })
    .padding({ left: this.horizontalPadding, right: this.horizontalPadding, top: 10, bottom: 10 })
  }
}
