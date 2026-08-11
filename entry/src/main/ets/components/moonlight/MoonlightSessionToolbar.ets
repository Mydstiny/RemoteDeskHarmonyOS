import { Palette, buildDark } from '../../common/Theme';
import {
  MoonlightToolbarAction,
  MoonlightToolbarItem,
  MoonlightToolbarLayout,
  moonlightToolbarAutoHideDelayMs,
  moonlightToolbarItems,
  moonlightToolbarLayout
} from '../../services/MoonlightUiPolicy';
import { MoonlightBrandIcon } from './MoonlightBrandIcon';

@Component
export struct MoonlightSessionToolbar {
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @StorageProp('isPadDevice') isPadDevice: boolean = false;
  @Prop audioAvailable: boolean = false;
  @Prop controllerAvailable: boolean = false;
  @Prop pipAvailable: boolean = false;
  @Prop qualityColor: string = '#66DD7A';
  @Prop qualityLabel: string = '良好';
  @State private expanded: boolean = false;
  @State private pinned: boolean = false;
  private hideTimer: number = -1;
  onAction: (action: MoonlightToolbarAction) => void = (_action: MoonlightToolbarAction): void => {};
  onUnavailable: (reason: string) => void = (_reason: string): void => {};

  private pal(): Palette {
    // The stream canvas is intentionally dark even when the app shell is light;
    // accent/danger/surface tokens still follow the shared Theme system.
    return buildDark(this.accentColor);
  }

  private layout(): MoonlightToolbarLayout {
    return moonlightToolbarLayout(this.isDesktopDevice, this.breakpoint, this.isPadDevice);
  }

  private items(): MoonlightToolbarItem[] {
    const layout: MoonlightToolbarLayout = this.layout();
    return moonlightToolbarItems(
      this.breakpoint, this.audioAvailable, this.controllerAvailable, this.pipAvailable,
      layout.maxVisibleItems);
  }

  private icon(action: MoonlightToolbarAction): Resource {
    if (action === 'control') { return $r('sys.symbol.display'); }
    if (action === 'keyboard') { return $r('sys.symbol.keyboard'); }
    if (action === 'controller') { return $r('sys.symbol.gamecontroller_fill'); }
    if (action === 'audio') { return $r('sys.symbol.speaker_slash_fill'); }
    if (action === 'display') { return $r('sys.symbol.display'); }
    if (action === 'more') { return $r('sys.symbol.ellipsis_bubble'); }
    return $r('sys.symbol.xmark_circle_fill');
  }

  private clearTimer(): void {
    if (this.hideTimer >= 0) { clearTimeout(this.hideTimer); this.hideTimer = -1; }
  }

  private scheduleHide(): void {
    this.clearTimer();
    const delayMs: number = moonlightToolbarAutoHideDelayMs(this.layout(), this.pinned);
    if (!this.expanded || delayMs <= 0) { return; }
    this.hideTimer = setTimeout((): void => {
      if (!this.pinned) { this.expanded = false; }
      this.clearTimer();
    }, delayMs);
  }

  private invoke(item: MoonlightToolbarItem): void {
    this.scheduleHide();
    if (!item.enabled) { this.onUnavailable(item.disabledReason); return; }
    this.onAction(item.action);
  }

  aboutToAppear(): void {
    this.expanded = false;
    this.pinned = false;
    this.scheduleHide();
  }

  aboutToDisappear(): void { this.clearTimer(); }

  @Builder private toolItem(item: MoonlightToolbarItem, layout: MoonlightToolbarLayout) {
    Button() {
      Column({ space: 2 }) {
        SymbolGlyph(this.icon(item.action)).fontSize(20)
          .fontColor([item.dangerous ? this.pal().danger :
            (item.enabled ? this.pal().text : this.pal().text3)])
        Text(item.label).fontSize(9)
          .fontColor(item.dangerous ? this.pal().danger :
            (item.enabled ? this.pal().text : this.pal().text3))
          .maxLines(1)
      }
    }
    .width(layout.edgeRail ? layout.iconSize + 18 : 50).height(50).borderRadius(14)
    .backgroundColor(item.dangerous ? this.pal().danger + '20' : this.pal().surface)
    .enabled(true)
    .opacity(item.enabled ? 1 : 0.72)
    .accessibilityText(item.enabled ? item.label : item.label + '，' + item.disabledReason)
    .onClick((): void => { this.invoke(item); })
  }

  @Builder private pinItem(layout: MoonlightToolbarLayout) {
    Button() {
      SymbolGlyph(this.pinned ? $r('sys.symbol.pin_fill') : $r('sys.symbol.pin'))
        .fontSize(17).fontColor([this.pinned ? this.accentColor : this.pal().text])
    }.width(layout.edgeRail ? layout.iconSize + 18 : 44).height(50).borderRadius(14)
      .backgroundColor(this.pal().surface)
      .onClick((): void => { this.pinned = !this.pinned; this.scheduleHide(); })
      .accessibilityText(this.pinned ? '取消固定工具条' : '固定工具条')
  }

  @Builder private collapsedHandle(layout: MoonlightToolbarLayout) {
    Button() {
      Row({ space: 5 }) {
        MoonlightBrandIcon({ iconSize: layout.edgeRail ? 18 : 20,
          tint: this.pal().text, accessibilityLabel: '打开 Moonlight 控制' })
        if (layout.edgeRail) {
          SymbolGlyph($r('sys.symbol.arrow_left')).fontSize(13).fontColor([this.pal().text2])
        } else {
          Column().width(7).height(7).borderRadius(4).backgroundColor(this.qualityColor)
        }
      }.justifyContent(FlexAlign.Center)
    }
    .width(layout.edgeRail ? 54 : 58).height(54).padding(0)
    .backgroundColor(this.pal().floatBg)
    .borderRadius(layout.edgeRail ?
      { topLeft: 18, bottomLeft: 18, topRight: 7, bottomRight: 7 } : 18)
    .border({ width: 1, color: this.pal().floatBorder })
    .shadow({ radius: 12, color: this.pal().fabShadow, offsetY: 4 })
    .onClick((): void => { this.expanded = true; this.scheduleHide(); })
    .accessibilityText('打开串流控制，连接质量' + this.qualityLabel)
  }

  @Builder private expandedTools(layout: MoonlightToolbarLayout) {
    if (layout.edgeRail) {
      Column({ space: layout.itemGap }) {
        ForEach(this.items(), (item: MoonlightToolbarItem): void => {
          this.toolItem(item, layout);
        }, (item: MoonlightToolbarItem): string => item.action)
        this.pinItem(layout)
      }
      .padding(7).backgroundColor(this.pal().floatBg).borderRadius(18)
      .border({ width: 1, color: this.pal().floatBorder })
      .shadow({ radius: 18, color: this.pal().fabShadow, offsetY: 5 })
      .onHover((hover: boolean): void => { if (hover) { this.clearTimer(); } else { this.scheduleHide(); } })
    } else {
      Row({ space: layout.itemGap }) {
        ForEach(this.items(), (item: MoonlightToolbarItem): void => {
          this.toolItem(item, layout);
        }, (item: MoonlightToolbarItem): string => item.action)
        this.pinItem(layout)
      }
      .padding(8).backgroundColor(this.pal().floatBg).borderRadius(18)
      .border({ width: 1, color: this.pal().floatBorder })
      .shadow({ radius: 18, color: this.pal().fabShadow, offsetY: 5 })
      .onHover((hover: boolean): void => { if (hover) { this.clearTimer(); } else { this.scheduleHide(); } })
    }
  }

  build() {
    Stack() {
      if (!this.expanded) {
        this.collapsedHandle(this.layout())
      } else {
        this.expandedTools(this.layout())
      }
    }
  }
}
