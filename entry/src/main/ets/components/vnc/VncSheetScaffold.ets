import { Palette, buildDark, buildLight } from '../../common/Theme';
import { protocolIcon } from '../../services/ProtocolIconPolicy';
import {
  resolveVncSheetLayout,
  VNC_SHEET_DENSITY_ACTION_ONLY,
  VNC_SHEET_DENSITY_REGULAR,
  VNC_SHEET_MAX_WIDTH
} from '../../services/VncSheetLayoutPolicy';

@Component
export struct VncSheetScaffold {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop stepText: string = '';
  @Prop leadingBack: boolean = false;
  @Prop showFooter: boolean = true;
  @Prop fitContent: boolean = false;
  @Prop bottomSafePadding: number = 18;
  @State measuredHeight: number = 0;
  onLeadingAction: () => void = (): void => {};

  @Builder
  defaultContent() {
  }

  @BuilderParam contentBuilder: () => void = this.defaultContent;
  @BuilderParam footerBuilder: () => void = this.defaultContent;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private density(): number {
    if (!this.showFooter || !Number.isFinite(this.measuredHeight) || this.measuredHeight <= 0) {
      return VNC_SHEET_DENSITY_REGULAR;
    }
    return resolveVncSheetLayout(this.measuredHeight, 0, this.bottomSafePadding).density;
  }

  private compactHeight(): boolean {
    return this.density() !== VNC_SHEET_DENSITY_REGULAR;
  }

  private actionOnlyHeight(): boolean {
    return this.density() === VNC_SHEET_DENSITY_ACTION_ONLY;
  }

  @Builder
  private header() {
    Row() {
      if (this.leadingBack) {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(this.compactHeight() ? 16 : 18).fontColor([this.pal().text2])
        }
        .width(this.compactHeight() ? 32 : 36).height(this.compactHeight() ? 32 : 36)
        .borderRadius(this.compactHeight() ? 16 : 18).padding(0).backgroundColor(this.pal().surface)
        .onClick((): void => { this.onLeadingAction(); })
      } else {
        SymbolGlyph(protocolIcon('vnc'))
          .fontSize(this.compactHeight() ? 21 : 24).fontColor([this.accentColor])
      }
      Column() {
        Text(this.title).fontSize(this.compactHeight() ? 17 : 19)
          .fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        if (this.stepText !== '') {
          Text(this.stepText).fontSize(this.compactHeight() ? 11 : 12)
            .fontColor(this.pal().text3).margin({ top: this.compactHeight() ? 2 : 3 })
        } else if (this.subtitle !== '' && !this.compactHeight()) {
          Text(this.subtitle).fontSize(11).fontColor(this.pal().text3).margin({ top: 4 })
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        .margin({ left: this.compactHeight() ? 9 : 12 })
      if (!this.leadingBack) {
        Button() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(this.compactHeight() ? 16 : 18).fontColor([this.pal().text2])
        }
        .width(this.compactHeight() ? 32 : 36).height(this.compactHeight() ? 32 : 36)
        .borderRadius(this.compactHeight() ? 16 : 18).padding(0).backgroundColor(this.pal().surface)
        .onClick((): void => { this.onLeadingAction(); })
      }
    }.width('100%').padding({
      left: 20,
      right: 20,
      top: this.compactHeight() ? 8 : 18,
      bottom: this.compactHeight() ? 6 : 14
    })
  }

  @Builder
  private body(inlineFooter: boolean) {
    Column() {
      if (this.subtitle !== '' && (this.stepText !== '' || this.compactHeight())) {
        Text(this.subtitle).fontSize(11).fontColor(this.pal().text3)
          .lineHeight(17).width('100%')
          .margin({ bottom: this.compactHeight() ? 8 : 14 })
      }
      this.contentBuilder()
      if (inlineFooter && this.showFooter) {
        this.footerBuilder()
      }
    }.width('100%').padding({
      left: 20,
      right: 20,
      bottom: this.compactHeight() ? 8 : 18
    })
  }

  @Builder
  private boundedFooter() {
    Column() {
      Divider().strokeWidth(0.5).color(this.pal().divider)
      Row() {
        this.footerBuilder()
      }.width('100%').padding({
        left: 20,
        right: 20,
        top: this.compactHeight() ? 6 : 12,
        bottom: this.compactHeight() ? 4 : 10
      })
    }
    .width('100%')
    .safeAreaPadding({ bottom: this.bottomSafePadding })
    .backgroundColor(this.pal().card)
  }

  build() {
    Column() {
      if (!this.actionOnlyHeight()) {
        this.header()
      }
      if (this.fitContent) {
        // VNC host-add sheets share one intrinsic content tree with their
        // action row so bindSheet can translate and scroll it above the IME.
        this.body(true)
      } else {
        // Settings, trust and Gateway callers retain a bounded body and
        // reachable footer inside their LARGE/fixed-height sheet host.
        Scroll() {
          this.body(false)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
        if (this.showFooter) {
          this.boundedFooter()
        }
      }
    }
    .width('100%')
    .height(this.fitContent ? 'auto' : '100%')
    .constraintSize({ maxWidth: VNC_SHEET_MAX_WIDTH })
    .backgroundColor(this.pal().card)
    .onAreaChange((_old: Area, next: Area): void => {
      const height: number = next.height as number;
      if (Number.isFinite(height) && height > 0 && Math.abs(height - this.measuredHeight) >= 0.5) {
        this.measuredHeight = height;
      }
    })
  }
}
