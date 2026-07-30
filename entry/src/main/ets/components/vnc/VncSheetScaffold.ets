import { Palette, buildDark, buildLight } from '../../common/Theme';
import { protocolIcon } from '../../services/ProtocolIconPolicy';
import { VNC_SHEET_MAX_WIDTH } from '../../services/VncSheetLayoutPolicy';

@Component
export struct VncSheetScaffold {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop stepText: string = '';
  @Prop leadingBack: boolean = false;
  @Prop showFooter: boolean = true;
  @Prop bottomSafePadding: number = 18;
  onLeadingAction: () => void = (): void => {};

  @Builder
  defaultContent() {
  }

  @BuilderParam contentBuilder: () => void = this.defaultContent;
  @BuilderParam footerBuilder: () => void = this.defaultContent;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  @Builder
  private header() {
    Row() {
      if (this.leadingBack) {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(18).fontColor([this.pal().text2])
        }
        .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
        .onClick((): void => { this.onLeadingAction(); })
      } else {
        SymbolGlyph(protocolIcon('vnc')).fontSize(24).fontColor([this.accentColor])
      }
      Column() {
        Text(this.title).fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        if (this.stepText !== '') {
          Text(this.stepText).fontSize(12).fontColor(this.pal().text3).margin({ top: 3 })
        } else if (this.subtitle !== '') {
          Text(this.subtitle).fontSize(11).fontColor(this.pal().text3).margin({ top: 4 })
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
      if (!this.leadingBack) {
        Button() {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
        }
        .width(36).height(36).borderRadius(18).padding(0).backgroundColor(this.pal().surface)
        .onClick((): void => { this.onLeadingAction(); })
      }
    }.width('100%').padding({ left: 20, right: 20, top: 18, bottom: 14 })
  }

  build() {
    Column() {
      this.header()
      Scroll() {
        Column() {
          if (this.subtitle !== '' && this.stepText !== '') {
            Text(this.subtitle).fontSize(11).fontColor(this.pal().text3)
              .lineHeight(17).width('100%').margin({ bottom: 14 })
          }
          this.contentBuilder()
        }.width('100%').padding({ left: 20, right: 20, bottom: 18 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      if (this.showFooter) {
        Column() {
          Divider().strokeWidth(0.5).color(this.pal().divider)
          Row() {
            this.footerBuilder()
          }.width('100%').padding({ left: 20, right: 20, top: 12, bottom: 10 })
        }
        .width('100%')
        .safeAreaPadding({ bottom: this.bottomSafePadding })
        .backgroundColor(this.pal().card)
      }
    }
    .width('100%')
    .height('100%')
    .constraintSize({ maxWidth: VNC_SHEET_MAX_WIDTH })
    .backgroundColor(this.pal().bg)
  }
}
