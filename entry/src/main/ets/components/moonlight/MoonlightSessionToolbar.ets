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
  @StorageProp('currentBreakpoint') @Watch('onBreakpointChange') breakpoint: string = 'sm';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @StorageProp('isPadDevice') isPadDevice: boolean = false;
  @Prop audioAvailable: boolean = false;
  @Prop controllerAvailable: boolean = false;
  @Prop pipAvailable: boolean = false;
  @Prop keyboardAvailable: boolean = false;
  @Prop @Watch('onMenuOpenChange') menuOpen: boolean = false;
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
      layout.maxVisibleItems, this.keyboardAvailable);
  }

  private icon(action: MoonlightToolbarAction): Resource {
    if (action === 'control') { return $r('sys.symbol.display'); }
    if (action === 'keyboard') { return $r('sys.symbol.keyboard'); }
    if (action === 'modifiers') { return $r('sys.symbol.keyboard'); }
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
    const delayMs: number = moonlightToolbarAutoHideDelayMs(this.layout(), this.pinned, this.menuOpen);
    if (!this.expanded || delayMs <= 0) { return; }
    const scheduledAutoHideMs: number = this.layout().autoHideMs;
    this.hideTimer = setTimeout((): void => {
      // A Sheet open or a breakpoint switch can race with a queued callback.
      // Re-read the current policy before collapsing; the watcher also clears
      // and rebuilds the timer, so stale callbacks cannot hide the new layout.
      const currentDelayMs: number = moonlightToolbarAutoHideDelayMs(
        this.layout(), this.pinned, this.menuOpen);
      if (currentDelayMs !== delayMs || this.layout().autoHideMs !== scheduledAutoHideMs) {
        this.scheduleHide();
        return;
      }
      if (!this.pinned && !this.menuOpen) { this.expanded = false; }
      this.clearTimer();
    }, delayMs);
  }

  private onBreakpointChange(): void { this.scheduleHide(); }

  private onMenuOpenChange(): void { this.scheduleHide(); }

  private invoke(item: MoonlightToolbarItem): void {
    if (!item.enabled) {
      this.onUnavailable(item.disabledReason);
      this.scheduleHide();
      return;
    }
    this.onAction(item.action);
    this.scheduleHide();
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
    .width(layout.edgeRail ? layout.iconSize + 18 : 50)
    .height(layout.edgeRail ? 44 : 50).borderRadius(14)
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
    }.width(layout.edgeRail ? layout.iconSize + 18 : 44)
      .height(layout.edgeRail ? 44 : 50).borderRadius(14)
      .backgroundColor(this.pal().surface)
      .onClick((): void => { this.pinned = !this.pinned; this.scheduleHide(); })
      .accessibilityText(this.pinned ? '取消固定工具条' : '固定工具条')
  }

  @Builder private collapseItem(layout: MoonlightToolbarLayout) {
    Button() {
      SymbolGlyph(layout.edgeRail ? $r('sys.symbol.arrow_right') : $r('sys.symbol.chevron_up'))
        .fontSize(17).fontColor([this.pal().text])
    }.width(layout.edgeRail ? layout.iconSize + 18 : 44)
      .height(layout.edgeRail ? 44 : 50).borderRadius(14)
      .backgroundColor(this.pal().surface)
      .onClick((): void => { this.clearTimer(); this.expanded = false; })
      .accessibilityText('收起串流控制工具栏')
  }

  @Builder private trailingItem(layout: MoonlightToolbarLayout) {
    if (layout.autoHideMs > 0) {
      this.pinItem(layout)
    } else {
      this.collapseItem(layout)
    }
  }

  @Builder private collapsedHandle(layout: MoonlightToolbarLayout) {
    if (layout.edgeRail) {
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(18).fontColor(['#444444'])
      }
      .width(30).height(72).padding(0)
      .backgroundColor('rgba(255,255,255,0.92)')
      .borderRadius({ topLeft: 10, bottomLeft: 10, topRight: 0, bottomRight: 0 })
      .shadow({ radius: 8, color: 'rgba(0,0,0,0.22)', offsetX: -2 })
      .onClick((): void => { this.expanded = true; this.scheduleHide(); })
      .accessibilityText('展开 Moonlight 会话贴边栏，连接质量' + this.qualityLabel)
    } else {
      Button() {
        Row({ space: 5 }) {
          MoonlightBrandIcon({ iconSize: 20,
            tint: this.pal().text, accessibilityLabel: '打开 Moonlight 控制' })
          Column().width(7).height(7).borderRadius(4).backgroundColor(this.qualityColor)
        }.justifyContent(FlexAlign.Center)
      }
      .width(58).height(54).padding(0)
      .backgroundColor(this.pal().floatBg)
      .borderRadius(18)
      .border({ width: 1, color: this.pal().floatBorder })
      .shadow({ radius: 12, color: this.pal().fabShadow, offsetY: 4 })
      .onClick((): void => { this.expanded = true; this.scheduleHide(); })
      .accessibilityText('打开串流控制，连接质量' + this.qualityLabel)
    }
  }

  @Builder private expandedTools(layout: MoonlightToolbarLayout) {
    if (layout.edgeRail) {
      Column({ space: layout.itemGap }) {
        Scroll() {
          Column({ space: layout.itemGap }) {
            ForEach(this.items(), (item: MoonlightToolbarItem): void => {
              this.toolItem(item, layout);
            }, (item: MoonlightToolbarItem): string => item.action)
            this.trailingItem(layout)
          }
        }.width(layout.iconSize + 32).constraintSize({ maxHeight: layout.maxHeight })
          .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
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
        this.trailingItem(layout)
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
