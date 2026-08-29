import { curves } from '@kit.ArkUI';
import { Palette, buildDark } from '../../common/Theme';
import {
  MoonlightToolbarAction,
  MoonlightToolbarItem,
  MoonlightToolbarLayout,
  moonlightToolbarAutoHideDelayMs,
  moonlightToolbarItems,
  moonlightToolbarLayout
} from '../../services/MoonlightUiPolicy';
import {
  REMOTE_SESSION_COLLAPSED_RAIL_BACKGROUND,
  REMOTE_SESSION_COLLAPSED_RAIL_BORDER,
  REMOTE_SESSION_COLLAPSED_RAIL_HEIGHT,
  REMOTE_SESSION_COLLAPSED_RAIL_ICON,
  REMOTE_SESSION_COLLAPSED_RAIL_TOUCH_WIDTH,
  REMOTE_SESSION_COLLAPSED_RAIL_WIDTH,
  REMOTE_SESSION_COLLAPSED_TOP_HEIGHT,
  REMOTE_SESSION_COLLAPSED_TOP_TOUCH_HEIGHT,
  REMOTE_SESSION_COLLAPSED_TOP_WIDTH,
  remoteSessionRailDragOffset,
  remoteSessionRailShouldCollapse
} from '../../services/RemoteSessionTopBarPolicy';

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
  @Prop diagnosticsVisible: boolean = false;
  @Prop keyboardOpen: boolean = false;
  @Prop modifiersOpen: boolean = false;
  @Prop controlModeLabel: string = '触控板';
  @Prop terminationBusy: boolean = false;
  @Prop @Watch('onMenuOpenChange') menuOpen: boolean = false;
  @Prop qualityColor: string = '#66DD7A';
  @Prop qualityLabel: string = '良好';
  @Prop @Watch('onAvailableHeightChange') availableHeight: number = 640;
  @State private expanded: boolean = false;
  @State private pinned: boolean = false;
  @State private railSwipeX: number = 0;
  private hideTimer: number = -1;
  onAction: (action: MoonlightToolbarAction) => void = (_action: MoonlightToolbarAction): void => {};
  onUnavailable: (reason: string) => void = (_reason: string): void => {};
  onPointerRegionChange: (inside: boolean, expanded: boolean) => void =
    (_inside: boolean, _expanded: boolean): void => {};

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
      layout.maxVisibleItems, this.keyboardAvailable, this.controlModeLabel);
  }

  private railItems(): MoonlightToolbarItem[] {
    const result: MoonlightToolbarItem[] = [];
    const source: MoonlightToolbarItem[] = this.items();
    for (let index: number = 0; index < source.length; index++) {
      if (source[index].action !== 'disconnect') { result.push(source[index]); }
    }
    return result;
  }

  private disconnectItem(): MoonlightToolbarItem {
    const source: MoonlightToolbarItem[] = this.items();
    for (let index: number = 0; index < source.length; index++) {
      if (source[index].action === 'disconnect') { return source[index]; }
    }
    return {
      action: 'disconnect', label: '退出', dangerous: true,
      enabled: true, disabledReason: ''
    };
  }

  private icon(action: MoonlightToolbarAction): Resource {
    if (action === 'control') { return $r('sys.symbol.display'); }
    if (action === 'keyboard') { return $r('sys.symbol.keyboard'); }
    if (action === 'modifiers') { return $r('sys.symbol.keyboard'); }
    if (action === 'controller') { return $r('sys.symbol.gamecontroller_fill'); }
    if (action === 'audio') { return $r('sys.symbol.speaker_slash_fill'); }
    if (action === 'display') { return $r('sys.symbol.display'); }
    if (action === 'diagnostics') { return $r('sys.symbol.info_circle'); }
    if (action === 'more') { return $r('sys.symbol.ellipsis_bubble'); }
    return $r('sys.symbol.xmark_circle_fill');
  }

  private clearTimer(): void {
    if (this.hideTimer >= 0) { clearTimeout(this.hideTimer); this.hideTimer = -1; }
  }

  private resetRailSwipe(): void {
    animateTo({ duration: 220, curve: curves.responsiveSpringMotion() }, (): void => {
      this.railSwipeX = 0;
    });
  }

  private updateRailSwipe(event: GestureEvent): void {
    if (Math.abs(event.offsetX) < Math.abs(event.offsetY)) { return; }
    this.railSwipeX = remoteSessionRailDragOffset(event.offsetX);
  }

  private finishRailSwipe(event: GestureEvent): void {
    const collapse: boolean = remoteSessionRailShouldCollapse(
      event.offsetX, event.velocityX, event.offsetY);
    this.resetRailSwipe();
    if (!collapse) { return; }
    this.clearTimer();
    animateTo({ duration: 180, curve: curves.responsiveSpringMotion() }, (): void => {
      this.expanded = false;
      this.onPointerRegionChange(false, false);
    });
  }

  private handlePointerRegionHover(hover: boolean, expanded: boolean): void {
    this.onPointerRegionChange(hover, expanded);
    if (!expanded) { return; }
    if (hover) { this.clearTimer(); } else { this.scheduleHide(); }
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
      if (!this.pinned && !this.menuOpen) {
        this.expanded = false;
        this.onPointerRegionChange(false, false);
      }
      this.clearTimer();
    }, delayMs);
  }

  private onBreakpointChange(): void { this.scheduleHide(); }

  private onMenuOpenChange(): void { this.scheduleHide(); }

  private invoke(item: MoonlightToolbarItem): void {
    if (item.action === 'disconnect' && this.terminationBusy) {
      this.onUnavailable('Moonlight 正在安全退出并释放连接');
      return;
    }
    if (!item.enabled) {
      this.onUnavailable(item.disabledReason);
      this.scheduleHide();
      return;
    }
    this.onAction(item.action);
    this.scheduleHide();
  }

  private itemEnabled(item: MoonlightToolbarItem): boolean {
    return item.enabled && !(item.action === 'disconnect' && this.terminationBusy);
  }

  private itemActive(item: MoonlightToolbarItem): boolean {
    if (item.action === 'keyboard') { return this.keyboardOpen; }
    if (item.action === 'modifiers') { return this.modifiersOpen; }
    return item.action === 'diagnostics' && this.diagnosticsVisible;
  }

  private sessionPrimary(): string { return '#5B8FF9'; }

  private sessionDanger(): string { return '#FF8A80'; }

  private itemLabel(item: MoonlightToolbarItem): string {
    if (item.action === 'disconnect' && this.terminationBusy) { return '退出中'; }
    if (item.action === 'keyboard' && this.keyboardOpen) { return '收键盘'; }
    if (item.action === 'modifiers' && this.modifiersOpen) { return '收组合键'; }
    return item.label;
  }

  private itemAccessibilityText(item: MoonlightToolbarItem): string {
    if (item.action === 'diagnostics') {
      return '性能监控，' + (this.diagnosticsVisible ? '已开启' : '已关闭');
    }
    if (item.action === 'keyboard') {
      return this.keyboardOpen ? '关闭虚拟键盘' : '打开虚拟键盘';
    }
    if (item.action === 'modifiers') {
      return this.modifiersOpen ? '关闭组合键与功能键' : '打开组合键与功能键';
    }
    if (item.action === 'disconnect' && this.terminationBusy) {
      return '正在安全退出 Moonlight 并释放连接';
    }
    return item.enabled ? item.label : item.label + '，' + item.disabledReason;
  }

  aboutToAppear(): void {
    this.expanded = false;
    this.pinned = false;
    this.onPointerRegionChange(false, false);
    this.scheduleHide();
  }

  aboutToDisappear(): void {
    this.clearTimer();
    this.onPointerRegionChange(false, false);
  }

  private onAvailableHeightChange(): void {
    if (this.layout().edgeRail && this.availableHeight < 176) {
      this.clearTimer();
      this.expanded = false;
      this.railSwipeX = 0;
    }
  }

  private canExpand(): boolean {
    return !this.layout().edgeRail || this.availableHeight >= 176;
  }

  private closeActiveKeyboardSurface(): boolean {
    if (this.keyboardOpen) {
      this.onAction('keyboard');
      this.scheduleHide();
      return true;
    }
    if (this.modifiersOpen) {
      this.onAction('modifiers');
      this.scheduleHide();
      return true;
    }
    return false;
  }

  private collapsedRailHeight(): number {
    const safeAvailable: number = Number.isFinite(this.availableHeight) ? this.availableHeight :
      REMOTE_SESSION_COLLAPSED_RAIL_HEIGHT;
    return Math.max(1, Math.min(REMOTE_SESSION_COLLAPSED_RAIL_HEIGHT, safeAvailable));
  }

  private railScrollMaxHeight(layout: MoonlightToolbarLayout): number {
    const contentHeight: number = this.railItems().length * 40 +
      Math.max(0, this.railItems().length - 1) * layout.itemGap;
    return Math.max(1, Math.min(contentHeight, Math.max(1, layout.maxHeight - 92),
      Math.max(1, this.availableHeight - 102)));
  }

  @Builder private toolItem(item: MoonlightToolbarItem, layout: MoonlightToolbarLayout) {
    Button() {
      Column({ space: 2 }) {
        SymbolGlyph(this.icon(item.action)).fontSize(layout.edgeRail ? 18 : 20)
          .fontColor([item.dangerous ? this.sessionDanger() :
            (this.itemActive(item) ? this.sessionPrimary() :
              (item.enabled ? this.pal().text : this.pal().text3))])
        Text(this.itemLabel(item)).fontSize(layout.edgeRail ? 8 : 9)
          .fontColor(item.dangerous ? this.sessionDanger() :
            (this.itemActive(item) ? this.sessionPrimary() :
              (item.enabled ? this.pal().text : this.pal().text3)))
          .width('100%')
          .textAlign(TextAlign.Center)
          .maxLines(1)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width(layout.edgeRail ? layout.iconSize + 18 : 50)
    .height(layout.edgeRail ? 40 : 50).padding(0).borderRadius(12)
    .backgroundColor(item.dangerous ? 'rgba(255,92,92,0.16)' :
      (this.itemActive(item) ? 'rgba(91,143,249,0.24)' : this.pal().surface))
    .enabled(true)
    .focusable(false).focusOnTouch(false)
    .opacity(this.itemEnabled(item) ? 1 : 0.72)
    .accessibilityText(this.itemAccessibilityText(item))
    .onClick((): void => { this.invoke(item); })
  }

  @Builder private pinItem(layout: MoonlightToolbarLayout) {
    Button() {
      SymbolGlyph(this.pinned ? $r('sys.symbol.pin_fill') : $r('sys.symbol.pin'))
        .fontSize(17).fontColor([this.pinned ? this.accentColor : this.pal().text])
    }.width(layout.edgeRail ? layout.iconSize + 18 : 44)
      .height(layout.edgeRail ? 40 : 50).padding(0).borderRadius(12)
      .backgroundColor(this.pal().surface)
      .focusable(false).focusOnTouch(false)
      .onClick((): void => { this.pinned = !this.pinned; this.scheduleHide(); })
      .accessibilityText(this.pinned ? '取消固定工具条' : '固定工具条')
  }

  @Builder private collapseItem(layout: MoonlightToolbarLayout) {
    Button() {
      SymbolGlyph(layout.edgeRail ? $r('sys.symbol.arrow_right') : $r('sys.symbol.chevron_up'))
        .fontSize(17).fontColor([this.pal().text])
    }.width(layout.edgeRail ? layout.iconSize + 18 : 44)
      .height(layout.edgeRail ? 40 : 50).padding(0).borderRadius(12)
      .backgroundColor(this.pal().surface)
      .focusable(false).focusOnTouch(false)
      .onClick((): void => {
        this.clearTimer();
        this.expanded = false;
        this.onPointerRegionChange(false, false);
      })
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
      Stack() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(15)
            .fontColor([REMOTE_SESSION_COLLAPSED_RAIL_ICON])
        }
        .width(REMOTE_SESSION_COLLAPSED_RAIL_WIDTH)
        .height(this.collapsedRailHeight())
        .justifyContent(FlexAlign.Center)
        .backgroundColor(REMOTE_SESSION_COLLAPSED_RAIL_BACKGROUND)
        .backdropBlur(16)
        .border({ width: 0.5, color: REMOTE_SESSION_COLLAPSED_RAIL_BORDER })
        .borderRadius({ topLeft: 10, bottomLeft: 10, topRight: 0, bottomRight: 0 })
        .shadow({ radius: 6, color: 'rgba(0,0,0,0.14)', offsetX: -1 })
        .position({
          x: REMOTE_SESSION_COLLAPSED_RAIL_TOUCH_WIDTH -
            REMOTE_SESSION_COLLAPSED_RAIL_WIDTH,
          y: 0
        })
      }
      .width(REMOTE_SESSION_COLLAPSED_RAIL_TOUCH_WIDTH)
      .height(this.collapsedRailHeight())
      .focusable(false).focusOnTouch(false)
      .onClick((): void => {
        if (this.closeActiveKeyboardSurface()) { return; }
        if (this.canExpand()) { this.expanded = true; this.scheduleHide(); }
      })
      .onHover((hover: boolean): void => {
        this.handlePointerRegionHover(hover, false);
      })
      .accessibilityText((this.keyboardOpen || this.modifiersOpen) ? '关闭键盘界面' :
        '展开 Moonlight 会话贴边栏，连接质量' + this.qualityLabel)
    } else {
      Stack() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(15)
            .fontColor([REMOTE_SESSION_COLLAPSED_RAIL_ICON])
        }
        .width(REMOTE_SESSION_COLLAPSED_TOP_WIDTH)
        .height(REMOTE_SESSION_COLLAPSED_TOP_HEIGHT)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(REMOTE_SESSION_COLLAPSED_RAIL_BACKGROUND)
        .backdropBlur(16)
        .border({ width: 0.5, color: REMOTE_SESSION_COLLAPSED_RAIL_BORDER })
        .borderRadius({ topLeft: 0, topRight: 0, bottomLeft: 10, bottomRight: 10 })
        .shadow({ radius: 6, color: 'rgba(0,0,0,0.14)', offsetY: 1 })
        .position({ x: 0, y: 0 })
      }
      .width(REMOTE_SESSION_COLLAPSED_TOP_WIDTH)
      .height(REMOTE_SESSION_COLLAPSED_TOP_TOUCH_HEIGHT)
      .focusable(false).focusOnTouch(false)
      .onClick((): void => {
        if (this.closeActiveKeyboardSurface()) { return; }
        this.expanded = true;
        this.scheduleHide();
      })
      .onHover((hover: boolean): void => {
        this.handlePointerRegionHover(hover, false);
      })
      .accessibilityText((this.keyboardOpen || this.modifiersOpen) ? '关闭键盘界面' :
        '展开 Moonlight 会话顶栏，连接质量' + this.qualityLabel)
    }
  }

  @Builder private expandedTools(layout: MoonlightToolbarLayout) {
    if (layout.edgeRail) {
      Column({ space: layout.itemGap }) {
        Scroll() {
          Column({ space: layout.itemGap }) {
            ForEach(this.railItems(), (item: MoonlightToolbarItem): void => {
              this.toolItem(item, layout);
            }, (item: MoonlightToolbarItem): string => item.action)
          }
        }.width(layout.iconSize + 18)
          .constraintSize({ maxHeight: this.railScrollMaxHeight(layout) })
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
      .onHover((hover: boolean): void => {
        this.handlePointerRegionHover(hover, true);
      })
    } else {
      Row({ space: layout.itemGap }) {
        ForEach(this.items(), (item: MoonlightToolbarItem): void => {
          this.toolItem(item, layout);
        }, (item: MoonlightToolbarItem): string => item.action)
        this.trailingItem(layout)
      }
      .padding(8).backgroundColor(this.pal().floatBg).backdropBlur(18).borderRadius(18)
      .border({ width: 1, color: this.pal().floatBorder })
      .shadow({ radius: 18, color: this.pal().fabShadow, offsetY: 5 })
      .onHover((hover: boolean): void => {
        this.handlePointerRegionHover(hover, true);
      })
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
    // Match RDP's proven fence: the concrete handle/rail remains interactive
    // and blocks remote click-through only inside its own bounds, while the
    // full-viewport input plane stays live everywhere else at the right edge.
    .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
  }
}
