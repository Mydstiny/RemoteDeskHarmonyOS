import { curves } from '@kit.ArkUI';
import { Palette, buildDark } from '../../common/Theme';
import {
  MoonlightToolbarLayout,
  moonlightToolbarAutoHideDelayMs,
  moonlightToolbarLayout
} from '../../services/MoonlightUiPolicy';
import {
  REMOTE_SESSION_COLLAPSED_RAIL_BACKGROUND,
  REMOTE_SESSION_COLLAPSED_RAIL_BORDER,
  REMOTE_SESSION_COLLAPSED_RAIL_HEIGHT,
  REMOTE_SESSION_COLLAPSED_RAIL_ICON,
  REMOTE_SESSION_COLLAPSED_RAIL_TOUCH_WIDTH,
  REMOTE_SESSION_COLLAPSED_RAIL_WIDTH,
  remoteSessionRailDragOffset,
  remoteSessionRailShouldCollapse
} from '../../services/RemoteSessionTopBarPolicy';

export type RdpToolbarAction = 'control' | 'keyboard' | 'shortcuts' |
  'ctrlAltDel' | 'refresh' | 'diagnostics' | 'disconnect';

interface RdpToolbarItem {
  action: RdpToolbarAction;
  label: string;
  dangerous: boolean;
}

@Component
export struct RdpSessionToolbar {
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') @Watch('onLayoutChange') breakpoint: string = 'sm';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @StorageProp('isPadDevice') isPadDevice: boolean = false;
  @Prop keyboardOpen: boolean = false;
  @Prop shortcutsOpen: boolean = false;
  @Prop controlCenterOpen: boolean = false;
  @Prop diagnosticsVisible: boolean = false;
  @Prop qualityLabel: string = '实时';
  @Prop qualityColor: string = '#66DD7A';
  @Prop availableHeight: number = 640;
  @State private expanded: boolean = false;
  @State private pinned: boolean = false;
  @State private railSwipeX: number = 0;
  private hideTimer: number = -1;
  onAction: (action: RdpToolbarAction) => void = (_action: RdpToolbarAction): void => {};

  private pal(): Palette { return buildDark(this.accentColor); }

  private layout(): MoonlightToolbarLayout {
    return moonlightToolbarLayout(this.isDesktopDevice, this.breakpoint, this.isPadDevice);
  }

  private items(): Array<RdpToolbarItem> {
    return [
      { action: 'control', label: 'RDP 控制', dangerous: false },
      { action: 'keyboard', label: '键盘', dangerous: false },
      { action: 'shortcuts', label: '组合键', dangerous: false },
      { action: 'ctrlAltDel', label: '安全键', dangerous: false },
      { action: 'refresh', label: '刷新', dangerous: false },
      { action: 'diagnostics', label: '性能', dangerous: false },
      { action: 'disconnect', label: '断开', dangerous: true }
    ];
  }

  private railItems(): Array<RdpToolbarItem> {
    return this.items().filter((item: RdpToolbarItem): boolean => item.action !== 'disconnect');
  }

  private disconnectItem(): RdpToolbarItem {
    return { action: 'disconnect', label: '断开', dangerous: true };
  }

  private icon(action: RdpToolbarAction): Resource {
    if (action === 'control') { return $r('sys.symbol.display'); }
    if (action === 'keyboard' || action === 'shortcuts') { return $r('sys.symbol.keyboard'); }
    if (action === 'ctrlAltDel') { return $r('sys.symbol.exclamationmark_triangle'); }
    if (action === 'refresh') { return $r('sys.symbol.bolt_fill'); }
    if (action === 'diagnostics') { return $r('sys.symbol.info_circle'); }
    return $r('sys.symbol.xmark_circle_fill');
  }

  private active(action: RdpToolbarAction): boolean {
    if (action === 'control') { return this.controlCenterOpen; }
    if (action === 'keyboard') { return this.keyboardOpen; }
    if (action === 'shortcuts') { return this.shortcutsOpen; }
    return action === 'diagnostics' && this.diagnosticsVisible;
  }

  private clearTimer(): void {
    if (this.hideTimer >= 0) { clearTimeout(this.hideTimer); this.hideTimer = -1; }
  }

  private scheduleHide(): void {
    this.clearTimer();
    const delay: number = moonlightToolbarAutoHideDelayMs(
      this.layout(), this.pinned, this.controlCenterOpen || this.shortcutsOpen);
    if (!this.expanded || delay <= 0) { return; }
    this.hideTimer = setTimeout((): void => {
      if (!this.pinned && !this.controlCenterOpen && !this.shortcutsOpen) { this.expanded = false; }
      this.clearTimer();
    }, delay);
  }

  private onLayoutChange(): void { this.scheduleHide(); }

  private invoke(action: RdpToolbarAction): void {
    this.onAction(action);
    this.scheduleHide();
  }

  private updateRailSwipe(event: GestureEvent): void {
    if (Math.abs(event.offsetX) < Math.abs(event.offsetY)) { return; }
    this.railSwipeX = remoteSessionRailDragOffset(event.offsetX);
  }

  private resetRailSwipe(): void {
    animateTo({ duration: 220, curve: curves.responsiveSpringMotion() }, (): void => {
      this.railSwipeX = 0;
    });
  }

  private finishRailSwipe(event: GestureEvent): void {
    const collapse: boolean = remoteSessionRailShouldCollapse(event.offsetX, event.velocityX);
    this.resetRailSwipe();
    if (!collapse) { return; }
    this.clearTimer();
    animateTo({ duration: 180, curve: curves.responsiveSpringMotion() }, (): void => {
      this.expanded = false;
    });
  }

  aboutToAppear(): void { this.scheduleHide(); }

  aboutToDisappear(): void { this.clearTimer(); }

  @Builder private toolItem(item: RdpToolbarItem, layout: MoonlightToolbarLayout) {
    Button() {
      Column({ space: 2 }) {
        SymbolGlyph(this.icon(item.action)).fontSize(20)
          .fontColor([item.dangerous ? this.pal().danger : this.pal().text])
        Text(item.label).fontSize(9)
          .fontColor(item.dangerous ? this.pal().danger : this.pal().text)
          .maxLines(1)
      }
    }
    .width(layout.edgeRail ? layout.iconSize + 18 : 52)
    .height(layout.edgeRail ? 44 : 50)
    .padding(0).borderRadius(14)
    .backgroundColor(item.dangerous ? this.pal().danger + '20' :
      (this.active(item.action) ? this.accentColor + '36' : this.pal().surface))
    .onClick((): void => { this.invoke(item.action); })
    .accessibilityText(item.label + (this.active(item.action) ? '，已打开' : ''))
  }

  @Builder private collapseItem(layout: MoonlightToolbarLayout) {
    Button() {
      SymbolGlyph(layout.edgeRail ? $r('sys.symbol.arrow_right') : $r('sys.symbol.chevron_up'))
        .fontSize(17).fontColor([this.pal().text])
    }.width(layout.edgeRail ? layout.iconSize + 18 : 44)
      .height(layout.edgeRail ? 44 : 50).padding(0).borderRadius(14)
      .backgroundColor(this.pal().surface)
      .onClick((): void => { this.clearTimer(); this.expanded = false; })
      .accessibilityText('收起 RDP 会话工具栏')
  }

  @Builder private pinItem(layout: MoonlightToolbarLayout) {
    Button() {
      SymbolGlyph(this.pinned ? $r('sys.symbol.pin_fill') : $r('sys.symbol.pin'))
        .fontSize(17).fontColor([this.pinned ? this.accentColor : this.pal().text])
    }.width(44).height(50).padding(0).borderRadius(14)
      .backgroundColor(this.pal().surface)
      .onClick((): void => { this.pinned = !this.pinned; this.scheduleHide(); })
      .accessibilityText(this.pinned ? '取消固定 RDP 工具栏' : '固定 RDP 工具栏')
  }

  @Builder private collapsedHandle(layout: MoonlightToolbarLayout) {
    if (layout.edgeRail) {
      Stack() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(15)
            .fontColor([REMOTE_SESSION_COLLAPSED_RAIL_ICON])
        }
        .width(REMOTE_SESSION_COLLAPSED_RAIL_WIDTH)
        .height(REMOTE_SESSION_COLLAPSED_RAIL_HEIGHT)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(REMOTE_SESSION_COLLAPSED_RAIL_BACKGROUND)
        .backdropBlur(16)
        .border({ width: 0.5, color: REMOTE_SESSION_COLLAPSED_RAIL_BORDER })
        .borderRadius({ topLeft: 10, bottomLeft: 10, topRight: 0, bottomRight: 0 })
        .position({ x: REMOTE_SESSION_COLLAPSED_RAIL_TOUCH_WIDTH -
          REMOTE_SESSION_COLLAPSED_RAIL_WIDTH, y: 0 })
      }
      .width(REMOTE_SESSION_COLLAPSED_RAIL_TOUCH_WIDTH)
      .height(REMOTE_SESSION_COLLAPSED_RAIL_HEIGHT)
      .onClick((): void => { this.expanded = true; this.scheduleHide(); })
      .accessibilityText('展开 RDP 会话工具栏，性能状态' + this.qualityLabel)
    } else {
      Button() {
        Row({ space: 6 }) {
          Text('RDP').fontSize(11).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          Column().width(7).height(7).borderRadius(4).backgroundColor(this.qualityColor)
        }
      }.width(58).height(52).padding(0)
        .backgroundColor('rgba(26,28,34,0.58)').backdropBlur(16).borderRadius(18)
        .border({ width: 1, color: this.pal().floatBorder })
        .shadow({ radius: 12, color: this.pal().fabShadow, offsetY: 4 })
        .onClick((): void => { this.expanded = true; this.scheduleHide(); })
        .accessibilityText('打开 RDP 控制，性能状态' + this.qualityLabel)
    }
  }

  @Builder private expandedTools(layout: MoonlightToolbarLayout) {
    if (layout.edgeRail) {
      Column({ space: layout.itemGap }) {
        Scroll() {
          Column({ space: layout.itemGap }) {
            ForEach(this.railItems(), (item: RdpToolbarItem): void => {
              this.toolItem(item, layout);
            }, (item: RdpToolbarItem): string => item.action)
          }
        }.width(layout.iconSize + 32)
          .constraintSize({ maxHeight: Math.max(80,
            Math.min(layout.maxHeight - 120, this.availableHeight - 116)) })
          .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
        this.toolItem(this.disconnectItem(), layout)
        this.collapseItem(layout)
      }
      .padding(7).backgroundColor(this.pal().floatBg).backdropBlur(18).borderRadius(18)
      .border({ width: 1, color: this.pal().floatBorder })
      .shadow({ radius: 18, color: this.pal().fabShadow, offsetY: 5 })
      .translate({ x: this.railSwipeX })
      .parallelGesture(PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 5 })
        .onActionUpdate((event: GestureEvent): void => { this.updateRailSwipe(event); })
        .onActionEnd((event: GestureEvent): void => { this.finishRailSwipe(event); })
        .onActionCancel((): void => { this.resetRailSwipe(); }))
    } else {
      Row({ space: layout.itemGap }) {
        ForEach(this.items(), (item: RdpToolbarItem): void => {
          this.toolItem(item, layout);
        }, (item: RdpToolbarItem): string => item.action)
        if (layout.autoHideMs > 0) { this.pinItem(layout) } else { this.collapseItem(layout) }
      }
      .padding(8).backgroundColor(this.pal().floatBg).backdropBlur(18).borderRadius(18)
      .border({ width: 1, color: this.pal().floatBorder })
      .shadow({ radius: 18, color: this.pal().fabShadow, offsetY: 5 })
    }
  }

  build() {
    Stack() {
      if (this.expanded) { this.expandedTools(this.layout()) } else { this.collapsedHandle(this.layout()) }
    }
  }
}
