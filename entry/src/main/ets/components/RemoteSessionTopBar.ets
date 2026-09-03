import { curves } from '@kit.ArkUI';
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
  RemoteSessionPrimaryActionId,
  RustDeskTopBarSubMenuId,
  RustDeskTopBarSubMenuState,
  RemoteTopBarLayout,
  remoteKeyboardSidebarAction,
  remoteKeyboardSurfaceOpen,
  remoteSessionPrimaryActionIds,
  remoteSessionRailDragOffset,
  remoteSessionRailShouldCollapse,
  rustDeskTopBarAutoCollapseDelayMs,
  rustDeskTopBarSubMenuForItem,
  reduceRustDeskTopBarSubMenuState,
  rustDeskTouchpadSpeedOptions,
  remoteSessionActionAvailability
} from '../services/RemoteSessionTopBarPolicy';
import { RemoteSessionCapabilities } from '../services/RemoteSessionCapabilityPolicy';
import {
  RustDeskDisplayCapabilities,
  RustDeskDisplayInfo,
  RustDeskDisplayResolution
} from '../types/rdpnapi';
import { RustDeskDisplaySwitchState } from '../services/RustDeskDisplaySwitchPolicy';
import {
  rustDeskDesktopFlipState,
  toggleRustDeskDesktopFlipAxis,
  RustDeskDesktopFlipAxis,
  RustDeskDesktopFlipMode,
  RustDeskDesktopFlipState
} from '../services/RustDeskDesktopFlipPolicy';
import {
  remoteSessionSidebarAnchoredMenuTop,
  remoteSessionSidebarCanvasHeight,
  remoteSessionSidebarMenuMaxHeight,
  remoteSessionSidebarMenuWidth,
  remoteSessionSidebarVisibleRailHeight
} from '../services/RemoteSessionSidebarLayoutPolicy';

const EMPTY_RUSTDESK_DISPLAY_CAPABILITIES: RustDeskDisplayCapabilities = {
  supported: false,
  currentDisplay: 0,
  switchGeneration: 0,
  readySwitchGeneration: 0,
  pendingDisplay: -1,
    confirmedDisplay: -1,
    inputBlocked: false,
    multiCanvasPreviewSupported: false,
    multiCanvasPreviewMaxDisplays: 2,
    multiCanvasPreviewActive: false,
    multiCanvasPreviewDisplay: -1,
  width: 0,
  height: 0,
  originalWidth: 0,
  originalHeight: 0,
  scaleMilli: 1000,
  geometryEpoch: 0,
  resolutions: [],
  displays: []
};

const EMPTY_RUSTDESK_DISPLAY_SWITCH_STATE: RustDeskDisplaySwitchState = {
  generation: 0,
  pendingDisplay: -1,
  startedAtMs: 0,
  inputBlocked: false,
  timeoutNotified: false
};

const EMPTY_RUSTDESK_DISPLAY_RESOLUTION: RustDeskDisplayResolution = {
  width: 0,
  height: 0
};

export interface RemoteSessionTopBarActions {
  onDisconnect: () => void;
  onHideTopBar: () => void;
  onRefreshFrame: () => void;
  onOpenKeyboard: () => void;
  onOpenModifiers: () => void;
  onCloseKeyboardSurface: () => void;
  onOpenFileTransfer: () => void;
  onCtrlAltDel: () => void;
  onLockRemote: () => void;
  onTogglePrivacy: (on: boolean) => void;
  onToggleAudio: (on: boolean) => void;
  onToggleClipboard: (on: boolean) => void;
  onToggleFilePaste: (on: boolean) => void;
  onSetViewScaleMode: (mode: string) => void;
  onResetCanvasTransform: () => void;
  onRotateRemoteDisplay: () => void;
  onSetRustDeskDesktopFlipMode: (mode: RustDeskDesktopFlipMode) => void;
  onOpenRustDeskResolution: () => void;
  onSelectRustDeskDisplay: (display: number) => void;
  onSetRustDeskDisplayResolution: (width: number, height: number) => void;
  onSetRustDeskImageQuality: (quality: number) => void;
  onSetRustDeskCodec: (codec: number) => void;
  onToggleShowLocalCursor: (on: boolean) => void;
  onToggleBrowseMode: (on: boolean) => void;
  onToggleRelativeMouse: (on: boolean) => void;
  onToggleReverseWheel: (on: boolean) => void;
  onToggleSwapMouseButtons: (on: boolean) => void;
  onSetTouchpadSpeed: (speed: number) => void;
  onToggleDiagnostics: (on: boolean) => void;
  onUnsupported: (actionId: string, reason: string) => void;
}

@Component
export struct RemoteSessionTopBar {
  @Prop protocol: string = 'rustdesk';
  @Prop layout: RemoteTopBarLayout = {
    deviceClass: 'pc',
    iconSize: 44,
    itemGap: 8,
    topOffset: 0,
    maxVisibleButtons: 9,
    menuWidth: 360
  };
  @Prop @Watch('onEdgeRailChanged') edgeRail: boolean = false;
  @Prop privacyMode: boolean = false;
  @Prop audioEnabled: boolean = true;
  @Prop clipboardEnabled: boolean = true;
  @Prop filePasteEnabled: boolean = true;
  @Prop viewScaleMode: string = 'fit';
  @Prop imageQuality: number = 1;
  @Prop codec: number = 0;
  @Prop showLocalCursor: boolean = true;
  @Prop browseMode: boolean = false;
  @Prop relativeMouseMode: boolean = false;
  @Prop reverseWheel: boolean = false;
  @Prop swapMouseButtons: boolean = false;
  @Prop touchpadSpeed: number = 1.0;
  @Prop @Watch('onRustDeskPhoneTargetChange') rustDeskPhoneTarget: boolean = false;
  @Prop rustDeskDesktopFlipMode: RustDeskDesktopFlipMode = 'reset';
  @Prop @Watch('onKeyboardSurfaceChange') keyboardOpen: boolean = false;
  @Prop @Watch('onKeyboardSurfaceChange') shortcutsOpen: boolean = false;
  @Prop diagnosticsEnabled: boolean = false;
  @Prop canvasResetAvailable: boolean = false;
  @Prop rustDeskDisplayCapabilities: RustDeskDisplayCapabilities = EMPTY_RUSTDESK_DISPLAY_CAPABILITIES;
  @Prop rustDeskDisplaySwitchState: RustDeskDisplaySwitchState = EMPTY_RUSTDESK_DISPLAY_SWITCH_STATE;
  @Prop pendingDisplayResolution: RustDeskDisplayResolution = EMPTY_RUSTDESK_DISPLAY_RESOLUTION;
  @Prop capabilities: RemoteSessionCapabilities = {
    connect: { enabled: false, reason: '远程会话尚未连接' },
    clipboardSend: { enabled: false, reason: '远程会话尚未连接' },
    clipboardReceive: { enabled: false, reason: '远程会话尚未连接' },
    fileUpload: { enabled: false, reason: '远程会话尚未连接' },
    fileDownload: { enabled: false, reason: '远程会话尚未连接' },
    multiDisplay: { enabled: false, reason: '远程会话尚未连接' }
  };
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @State private collapsed: boolean = false;
  @State private pinned: boolean = false;
  @State private activeMenu: string = '';
  @State private activeSubMenu: string = '';
  @State private subMenuPinned: boolean = false;
  @State private railSwipeX: number = 0;
  @State private viewportWidth: number = 360;
  @State private viewportHeight: number = 640;
  private autoCollapseTimer: number = -1;

  actions: RemoteSessionTopBarActions = {
    onDisconnect: (): void => {},
    onHideTopBar: (): void => {},
    onRefreshFrame: (): void => {},
    onOpenKeyboard: (): void => {},
    onOpenModifiers: (): void => {},
    onCloseKeyboardSurface: (): void => {},
    onOpenFileTransfer: (): void => {},
    onCtrlAltDel: (): void => {},
    onLockRemote: (): void => {},
    onTogglePrivacy: (_on: boolean): void => {},
    onToggleAudio: (_on: boolean): void => {},
    onToggleClipboard: (_on: boolean): void => {},
    onToggleFilePaste: (_on: boolean): void => {},
    onSetViewScaleMode: (_mode: string): void => {},
    onResetCanvasTransform: (): void => {},
    onRotateRemoteDisplay: (): void => {},
    onSetRustDeskDesktopFlipMode: (_mode: RustDeskDesktopFlipMode): void => {},
    onOpenRustDeskResolution: (): void => {},
    onSelectRustDeskDisplay: (_display: number): void => {},
    onSetRustDeskDisplayResolution: (_width: number, _height: number): void => {},
    onSetRustDeskImageQuality: (_quality: number): void => {},
    onSetRustDeskCodec: (_codec: number): void => {},
    onToggleShowLocalCursor: (_on: boolean): void => {},
    onToggleBrowseMode: (_on: boolean): void => {},
    onToggleRelativeMouse: (_on: boolean): void => {},
    onToggleReverseWheel: (_on: boolean): void => {},
    onToggleSwapMouseButtons: (_on: boolean): void => {},
    onSetTouchpadSpeed: (_speed: number): void => {},
    onToggleDiagnostics: (_on: boolean): void => {},
    onUnsupported: (_actionId: string, _reason: string): void => {}
  };

  private runAction(actionId: string, action: () => void): void {
    this.noteUserActivity();
    const availability = remoteSessionActionAvailability(
      actionId, this.protocol, this.capabilities);
    if (!availability.enabled) {
      this.actions.onUnsupported(actionId, availability.reason);
      return;
    }
    action();
  }

  private toggleMenu(menu: string): void {
    this.resetSubMenu();
    this.activeMenu = this.activeMenu === menu ? '' : menu;
    this.scheduleAutoCollapse();
  }

  private desktopFlipState(): RustDeskDesktopFlipState {
    return rustDeskDesktopFlipState(this.rustDeskDesktopFlipMode);
  }

  private toggleDesktopFlipAxis(axis: RustDeskDesktopFlipAxis): void {
    this.actions.onSetRustDeskDesktopFlipMode(toggleRustDeskDesktopFlipAxis(
      this.rustDeskDesktopFlipMode, axis));
  }

  private closeMenus(): void {
    this.activeMenu = '';
    this.resetSubMenu();
    this.scheduleAutoCollapse();
  }

  private keyboardSurfaceOpen(): boolean {
    return remoteKeyboardSurfaceOpen(this.keyboardOpen, this.shortcutsOpen);
  }

  private activateKeyboardAffordance(): void {
    if (remoteKeyboardSidebarAction(this.keyboardOpen, this.shortcutsOpen) === 'close') {
      this.closeMenus();
      this.actions.onCloseKeyboardSurface();
      return;
    }
    this.toggleMenu('keyboard');
  }

  private clearAutoCollapseTimer(): void {
    if (this.autoCollapseTimer >= 0) {
      clearTimeout(this.autoCollapseTimer);
      this.autoCollapseTimer = -1;
    }
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
    this.closeMenus();
    animateTo({ duration: 180, curve: curves.responsiveSpringMotion() }, (): void => {
      this.collapsed = true;
    });
  }

  private scheduleAutoCollapse(): void {
    this.clearAutoCollapseTimer();
    if (this.collapsed) {
      return;
    }
    const delayMs: number = rustDeskTopBarAutoCollapseDelayMs(this.pinned,
      this.activeMenu.length > 0 || this.keyboardSurfaceOpen());
    if (delayMs <= 0) {
      return;
    }
    this.autoCollapseTimer = setTimeout((): void => {
      if (!this.pinned && this.activeMenu.length === 0 && !this.keyboardSurfaceOpen()) {
        this.collapsed = true;
      }
      this.clearAutoCollapseTimer();
    }, delayMs);
  }

  private noteUserActivity(): void {
    if (!this.collapsed) {
      this.scheduleAutoCollapse();
    }
  }

  private onKeyboardSurfaceChange(): void {
    this.scheduleAutoCollapse();
  }

  private onRustDeskPhoneTargetChange(): void {
    if (this.rustDeskPhoneTarget && this.activeMenu === 'desktopFlip') {
      this.closeMenus();
    }
  }

  private onEdgeRailChanged(): void {
    this.clearAutoCollapseTimer();
    this.activeMenu = '';
    this.resetSubMenu();
    this.collapsed = false;
    this.pinned = false;
    this.scheduleAutoCollapse();
  }

  aboutToAppear(): void {
    this.collapsed = false;
    this.activeMenu = '';
    this.resetSubMenu();
    this.scheduleAutoCollapse();
  }

  aboutToDisappear(): void {
    this.clearAutoCollapseTimer();
  }

  private toolbarWidth(): number {
    const actionCount: number = remoteSessionPrimaryActionIds(
      this.protocol, this.layout.deviceClass, this.rustDeskPhoneTarget).length;
    const count: number = Math.max(1, Math.min(this.layout.maxVisibleButtons, actionCount));
    return count * this.layout.iconSize + (count + 1) * this.layout.itemGap;
  }

  private effectiveMenuWidth(): number {
    return this.edgeRail ? this.sidebarMenuWidth() : this.layout.menuWidth;
  }

  private menuLeft(width: number = this.effectiveMenuWidth()): number {
    if (this.edgeRail) {
      return 0;
    }
    const fullWidth: number = this.toolbarWidth();
    return Math.max(0, (fullWidth - width) / 2);
  }

  private menuTop(): number {
    return this.edgeRail ? 0 : this.layout.iconSize + 12;
  }

  private keyboardMenuHeight(): number {
    return this.menuHeaderHeight() + this.menuPadding() * 2 + this.menuItemHeight() * 2;
  }

  private keyboardButtonIndex(): number {
    const actions: RemoteSessionPrimaryActionId[] = remoteSessionPrimaryActionIds(
      this.protocol, this.layout.deviceClass, this.rustDeskPhoneTarget);
    const index: number = actions.indexOf('keyboard');
    return index >= 0 ? index : 0;
  }

  private keyboardMenuLeft(): number {
    if (this.edgeRail) {
      return 0;
    }
    const width: number = this.effectiveMenuWidth();
    const anchorCenter: number = this.layout.itemGap +
      this.keyboardButtonIndex() * (this.layout.iconSize + this.layout.itemGap) +
      this.layout.iconSize / 2;
    const maxLeft: number = Math.max(0, this.toolbarWidth() - width);
    return Math.max(0, Math.min(anchorCenter - width / 2, maxLeft));
  }

  private keyboardMenuTop(): number {
    if (!this.edgeRail) {
      return this.menuTop();
    }
    const anchorTop: number = this.edgeRailOffsetY() + 6 +
      this.keyboardButtonIndex() * (this.layout.iconSize + this.layout.itemGap);
    return remoteSessionSidebarAnchoredMenuTop(this.viewportHeight, anchorTop,
      this.layout.iconSize, this.keyboardMenuHeight());
  }

  private edgeRailWidth(): number {
    return this.layout.iconSize + 12;
  }

  private sidebarMenuWidth(): number {
    return remoteSessionSidebarMenuWidth(this.viewportWidth, this.layout.menuWidth,
      this.edgeRailWidth(), this.layout.itemGap);
  }

  private sidebarMenuMaxHeight(): number {
    return remoteSessionSidebarMenuMaxHeight(this.viewportHeight, this.menuTop());
  }

  private edgeRailButtonCount(): number {
    return remoteSessionPrimaryActionIds(
      this.protocol, this.layout.deviceClass, this.rustDeskPhoneTarget).length;
  }

  private edgeRailHeight(): number {
    const buttonCount: number = this.edgeRailButtonCount();
    return buttonCount * this.layout.iconSize +
      Math.max(0, buttonCount - 1) * this.layout.itemGap + 12 +
      this.layout.itemGap + 30;
  }

  private edgeRailCanvasHeight(): number {
    return remoteSessionSidebarCanvasHeight(this.viewportHeight);
  }

  private edgeRailVisibleHeight(): number {
    return remoteSessionSidebarVisibleRailHeight(this.viewportHeight, this.edgeRailHeight());
  }

  private edgeRailOffsetY(): number {
    return Math.max(0, (this.edgeRailCanvasHeight() - this.edgeRailVisibleHeight()) / 2);
  }

  private collapsedEdgeRailHeight(): number {
    return Math.max(1, Math.min(REMOTE_SESSION_COLLAPSED_RAIL_HEIGHT,
      this.edgeRailCanvasHeight()));
  }

  private compactMenu(): boolean {
    return this.layout.deviceClass === 'phone' || this.viewportHeight < 440;
  }

  private menuItemHeight(): number {
    return this.compactMenu() ? 38 : 44;
  }

  private menuFontSize(): number {
    if (this.layout.deviceClass === 'pc') { return 15; }
    return this.compactMenu() ? 13 : 14;
  }

  private menuPadding(): number {
    return this.compactMenu() ? 8 : 12;
  }

  private menuHeaderHeight(): number {
    return this.compactMenu() ? 40 : 44;
  }

  private menuScrollMaxHeight(): number {
    return Math.max(1, this.sidebarMenuMaxHeight() - this.menuHeaderHeight());
  }

  private qualityLabel(value: number): string {
    if (value === 0) { return '速度'; }
    if (value === 2) { return '画质'; }
    return '平衡';
  }

  private viewScaleLabel(): string {
    if (this.viewScaleMode === 'fit') { return '适应窗口'; }
    if (this.viewScaleMode === 'custom') { return '自定义'; }
    return this.viewScaleMode + '%';
  }

  private codecLabel(value: number): string {
    if (value === 1) { return 'VP8'; }
    if (value === 2) { return 'VP9'; }
    if (value === 3) { return 'AV1'; }
    if (value === 4) { return 'H264'; }
    if (value === 5) { return 'H265'; }
    return '自动';
  }

  private hasRustDeskDisplayData(): boolean {
    return this.rustDeskDisplayCapabilities.supported &&
      (this.rustDeskDisplayCapabilities.displays.length > 0 ||
        this.rustDeskDisplayCapabilities.resolutions.length > 0);
  }

  private rustDeskDisplaySwitchPending(): boolean {
    return this.rustDeskDisplaySwitchState.inputBlocked ||
      this.rustDeskDisplayCapabilities.inputBlocked ||
      this.rustDeskDisplayCapabilities.pendingDisplay >= 0;
  }

  private rustDeskDisplayTarget(): number {
    if (this.rustDeskDisplaySwitchState.inputBlocked &&
      this.rustDeskDisplaySwitchState.pendingDisplay >= 0) {
      return this.rustDeskDisplaySwitchState.pendingDisplay;
    }
    if (this.rustDeskDisplayCapabilities.pendingDisplay >= 0) {
      return this.rustDeskDisplayCapabilities.pendingDisplay;
    }
    return this.rustDeskDisplayCapabilities.currentDisplay;
  }

  private rustDeskDisplayInfo(displayId: number): RustDeskDisplayInfo | null {
    for (const display of this.rustDeskDisplayCapabilities.displays) {
      if (display.display === displayId) {
        return display;
      }
    }
    return null;
  }

  private rustDeskDisplayLabel(display: RustDeskDisplayInfo | null, displayId: number): string {
    if (display !== null && display.name.trim().length > 0) {
      return display.name;
    }
    return '显示器 ' + (displayId + 1).toString();
  }

  private rustDeskDisplaySizeLabel(display: RustDeskDisplayInfo | null): string {
    if (display === null) {
      return '';
    }
    const width: number = display.width > 0 ? display.width : display.originalWidth;
    const height: number = display.height > 0 ? display.height : display.originalHeight;
    return width > 0 && height > 0 ? width.toString() + ' × ' + height.toString() : '';
  }

  private rustDeskDisplayResolutionLabel(resolution: RustDeskDisplayResolution): string {
    return resolution.width.toString() + ' × ' + resolution.height.toString();
  }

  private currentRustDeskDisplayLabel(): string {
    const displayId: number = this.rustDeskDisplayCapabilities.currentDisplay;
    return this.rustDeskDisplayLabel(this.rustDeskDisplayInfo(displayId), displayId);
  }

  private displaySwitchStatusLabel(): string {
    const target: number = this.rustDeskDisplayTarget();
    if (this.rustDeskDisplaySwitchPending()) {
      return '正在切换到 ' + this.rustDeskDisplayLabel(this.rustDeskDisplayInfo(target), target);
    }
    return '当前：' + this.currentRustDeskDisplayLabel();
  }

  private displayResolutionStatusLabel(): string {
    if (this.pendingDisplayResolution.width > 0 && this.pendingDisplayResolution.height > 0) {
      return '待应用：' + this.rustDeskDisplayResolutionLabel(this.pendingDisplayResolution);
    }
    if (this.rustDeskDisplayCapabilities.width > 0 && this.rustDeskDisplayCapabilities.height > 0) {
      return this.rustDeskDisplayCapabilities.width.toString() + ' × ' +
        this.rustDeskDisplayCapabilities.height.toString();
    }
    return '分辨率读取中';
  }

  private isRustDeskDisplaySelected(displayId: number): boolean {
    return displayId === this.rustDeskDisplayTarget();
  }

  private isRustDeskDisplayCurrent(displayId: number): boolean {
    return displayId === this.rustDeskDisplayCapabilities.currentDisplay;
  }

  private isRustDeskDisplayPending(displayId: number): boolean {
    return this.isRustDeskDisplaySelected(displayId) && this.rustDeskDisplaySwitchPending() &&
      !this.isRustDeskDisplayCurrent(displayId);
  }

  private isRustDeskDisplayResolutionSelected(resolution: RustDeskDisplayResolution): boolean {
    if (this.pendingDisplayResolution.width > 0 && this.pendingDisplayResolution.height > 0) {
      return resolution.width === this.pendingDisplayResolution.width &&
        resolution.height === this.pendingDisplayResolution.height;
    }
    return resolution.width === this.rustDeskDisplayCapabilities.width &&
      resolution.height === this.rustDeskDisplayCapabilities.height;
  }

  @Builder
  private iconButton(icon: Resource, bgColor: string, action: () => void, fontSize?: number,
    accessibilityLabel: string = 'RustDesk 会话工具栏操作') {
    Button() {
      SymbolGlyph(icon)
        .fontSize(fontSize ?? 20)
        .fontColor([Color.White])
    }
      .width(this.layout.iconSize)
      .height(this.layout.iconSize)
      .backgroundColor(bgColor)
      .borderRadius(10)
      .padding(0)
      .focusable(false)
      .focusOnTouch(false)
      .accessibilityText(accessibilityLabel)
      .bindTips(accessibilityLabel, {
        appearingTime: 300,
        disappearingTime: 0,
        appearingTimeWithContinuousOperation: 100,
        disappearingTimeWithContinuousOperation: 0,
        enableArrow: true
      })
      .onClick((): void => {
        this.noteUserActivity();
        action();
      })
  }

  private openSubMenu(itemId: string, hovered: boolean, clicked: boolean): void {
    if (!hovered && !clicked) {
      return;
    }
    const next: RustDeskTopBarSubMenuState = reduceRustDeskTopBarSubMenuState(
      { active: this.activeSubMenu as RustDeskTopBarSubMenuId | '', pinned: this.subMenuPinned },
      itemId, clicked ? 'click' : 'hover-enter');
    this.activeSubMenu = next.active;
    this.subMenuPinned = next.pinned;
    this.noteUserActivity();
  }

  private onExpandableMenuHover(isHover: boolean): void {
    if (isHover) { return; }
    const next: RustDeskTopBarSubMenuState = reduceRustDeskTopBarSubMenuState(
      { active: this.activeSubMenu as RustDeskTopBarSubMenuId | '', pinned: this.subMenuPinned },
      '', 'menu-leave');
    this.activeSubMenu = next.active;
    this.subMenuPinned = next.pinned;
  }

  private resetSubMenu(): void {
    const next: RustDeskTopBarSubMenuState = reduceRustDeskTopBarSubMenuState(
      { active: this.activeSubMenu as RustDeskTopBarSubMenuId | '', pinned: this.subMenuPinned },
      '', 'reset');
    this.activeSubMenu = next.active;
    this.subMenuPinned = next.pinned;
  }

  @Builder
  private subMenuItem(label: string, status: string, actionId: string, itemId: string) {
    Row() {
      Blank().width(30)
      Column() {
        Text(label)
          .fontSize(this.menuFontSize())
          .fontColor(remoteSessionActionAvailability(
            actionId, this.protocol, this.capabilities).enabled ? '#111111' : '#777777')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (status.length > 0) {
          Text(status).fontSize(11).fontColor('#6B7280').margin({ top: 2 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      SymbolGlyph(this.activeSubMenu === rustDeskTopBarSubMenuForItem(itemId) ?
        $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
        .fontSize(14).fontColor(['#6B7280'])
    }
    .width('100%')
    .height(status.length > 0 ? this.menuItemHeight() + 8 : this.menuItemHeight())
    .padding({ left: 8, right: 8 })
    .borderRadius(6)
    .focusable(false)
    .focusOnTouch(false)
    .onHover((isHover: boolean): void => {
      if (remoteSessionActionAvailability(actionId, this.protocol, this.capabilities).enabled) {
        this.openSubMenu(itemId, isHover, false);
      }
    })
    .onClick((): void => {
      this.runAction(actionId, (): void => { this.openSubMenu(itemId, false, true); });
    })
  }

  @Builder
  private menuItem(label: string, actionId: string, action: () => void, checked?: boolean) {
    Row() {
      if (checked === undefined) {
        Blank().width(30)
      } else if (checked) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .width(30)
          .fontSize(16)
          .fontColor([this.accentColor])
      } else {
        Blank().width(30)
      }
      Text(label)
        .fontSize(this.menuFontSize())
        .fontColor(remoteSessionActionAvailability(
          actionId, this.protocol, this.capabilities).enabled ? '#111111' : '#777777')
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(this.menuItemHeight())
    .padding({ left: 8, right: 8 })
    .borderRadius(6)
    .focusable(false)
    .focusOnTouch(false)
    .onClick((): void => {
      this.runAction(actionId, action);
    })
  }

  @Builder
  private menuHeader(title: string, icon: Resource) {
    Row() {
      SymbolGlyph(icon).fontSize(18).fontColor([this.accentColor])
      Text(title).fontSize(this.compactMenu() ? 14 : 16).fontWeight(FontWeight.Bold)
        .fontColor('#111827').margin({ left: 8 }).layoutWeight(1)
      Button() {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(14).fontColor(['#4B5563'])
      }
      .width(34).height(34).padding(0).borderRadius(17)
      .backgroundColor('rgba(17,24,39,0.06)')
      .focusable(false).focusOnTouch(false)
      .accessibilityText('关闭' + title)
      .onClick((): void => { this.closeMenus(); })
    }
    .width('100%').height(this.menuHeaderHeight())
    .padding({ left: this.menuPadding(), right: this.menuPadding() })
    .border({ width: { bottom: 0.5 }, color: 'rgba(17,24,39,0.10)' })
  }

  @Builder
  private controlMenu() {
    Column() {
      this.menuHeader('会话控制', $r('sys.symbol.gearshape_fill'))
      Scroll() {
        Column() {
          this.menuItem('发送剪贴板按键', 'toggleClipboard', (): void => {
            this.actions.onToggleClipboard(!this.clipboardEnabled);
          }, this.clipboardEnabled)
          this.menuItem('传输文件', 'fileTransfer', (): void => { this.actions.onOpenFileTransfer(); })
          this.menuItem('插入 Ctrl + Alt + Del', 'ctrlAltDel', (): void => { this.actions.onCtrlAltDel(); })
          this.menuItem('刷新画面', 'refreshFrame', (): void => { this.actions.onRefreshFrame(); })
          if (this.protocol === 'rustdesk') {
            this.menuItem('锁定远程电脑', 'lockRemote', (): void => { this.actions.onLockRemote(); })
            this.menuItem('截屏', 'screenshot', (): void => {})
            this.menuItem('文字聊天', 'textChat', (): void => {})
            this.menuItem('语音通话', 'voiceCall', (): void => {})
            this.menuItem('录制', 'recordSession', (): void => {})
          }
        }
        .width('100%').padding(this.menuPadding())
      }
      .width('100%').constraintSize({ maxHeight: this.menuScrollMaxHeight() })
      .scrollable(ScrollDirection.Vertical).scrollBar(BarState.Auto)
    }
    .width(this.effectiveMenuWidth())
    .constraintSize({ maxHeight: this.sidebarMenuMaxHeight() })
    .backgroundColor('rgba(255,255,255,0.96)')
    .borderRadius(16).clip(true)
    .shadow({ radius: 10, color: 'rgba(0,0,0,0.22)', offsetY: 2 })
    .position({ x: this.menuLeft(), y: this.menuTop() })
    .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
  }

  @Builder
  private displayRootMenuContent() {
    this.subMenuItem('缩放', this.viewScaleLabel(), 'displaySettings', 'viewScale')
    if (this.activeSubMenu === 'viewScale') {
      this.viewScaleSubMenuContent()
    }
    this.menuItem(this.canvasResetAvailable ? '复位画面（已缩放）' : '复位画面',
      'displaySettings', (): void => { this.actions.onResetCanvasTransform(); })
    if (this.protocol === 'rustdesk') {
      if (this.rustDeskPhoneTarget) {
        this.menuItem('旋转远端画面（顺时针 90°）', 'rotateDisplay', (): void => {
          this.actions.onRotateRemoteDisplay();
        })
      }
      if (this.hasRustDeskDisplayData()) {
        if (this.rustDeskDisplayCapabilities.displays.length > 0) {
          this.subMenuItem('远端显示器', this.displaySwitchStatusLabel(),
            'displaySettings', 'remoteDisplay')
          if (this.activeSubMenu === 'remoteDisplay') {
            this.remoteDisplaySubMenuContent()
          }
        }
        if (this.rustDeskDisplayCapabilities.resolutions.length > 0) {
          this.subMenuItem('分辨率', this.displayResolutionStatusLabel(),
            'displaySettings', 'resolution')
          if (this.activeSubMenu === 'resolution') {
            this.resolutionSubMenuContent()
          }
        }
        this.menuItem('打开完整显示器与分辨率面板', 'resolutionSettings', (): void => {
          this.actions.onOpenRustDeskResolution();
        })
      } else {
        this.menuItem('显示器与分辨率', 'resolutionSettings', (): void => {
          this.actions.onOpenRustDeskResolution();
        })
      }
      this.subMenuItem('画质', this.qualityLabel(this.imageQuality),
        'displaySettings', 'imageQuality')
      if (this.activeSubMenu === 'imageQuality') {
        this.imageQualitySubMenuContent()
      }
      this.subMenuItem('编解码', this.codecLabel(this.codec),
        'displaySettings', 'codec')
      if (this.activeSubMenu === 'codec') {
        this.codecSubMenuContent()
      }
      this.menuItem('虚拟显示器', 'virtualDisplay', (): void => {})
      this.menuItem('隐私模式', 'togglePrivacyMode', (): void => {
        this.actions.onTogglePrivacy(!this.privacyMode);
      }, this.privacyMode)
      this.menuItem('静音', 'toggleAudio', (): void => {
        this.actions.onToggleAudio(!this.audioEnabled);
      }, !this.audioEnabled)
      this.menuItem('允许复制粘贴文件', 'toggleFilePaste', (): void => {
        this.actions.onToggleFilePaste(!this.filePasteEnabled);
      }, this.filePasteEnabled)
    }
  }

  @Builder
  private viewScaleSubMenuContent() {
    this.menuItem('适应窗口', 'displaySettings', (): void => {
      this.actions.onSetViewScaleMode('fit');
    }, this.viewScaleMode === 'fit')
    this.menuItem('100%', 'displaySettings', (): void => {
      this.actions.onSetViewScaleMode('100');
    }, this.viewScaleMode === '100')
    this.menuItem('125%', 'displaySettings', (): void => {
      this.actions.onSetViewScaleMode('125');
    }, this.viewScaleMode === '125')
    this.menuItem('150%', 'displaySettings', (): void => {
      this.actions.onSetViewScaleMode('150');
    }, this.viewScaleMode === '150')
    this.menuItem('175%', 'displaySettings', (): void => {
      this.actions.onSetViewScaleMode('175');
    }, this.viewScaleMode === '175')
    this.menuItem('200%', 'displaySettings', (): void => {
      this.actions.onSetViewScaleMode('200');
    }, this.viewScaleMode === '200')
    this.menuItem('自定义缩放', 'displaySettings', (): void => {
      this.actions.onSetViewScaleMode('custom');
    }, this.viewScaleMode === 'custom')
  }

  @Builder
  private remoteDisplaySubMenuContent() {
    ForEach(this.rustDeskDisplayCapabilities.displays,
      (display: RustDeskDisplayInfo): void => {
        Row() {
          if (this.isRustDeskDisplaySelected(display.display)) {
            SymbolGlyph($r('sys.symbol.checkmark')).width(30).fontSize(16)
              .fontColor([this.accentColor])
          } else {
            Blank().width(30)
          }
          Column() {
            Text(this.rustDeskDisplayLabel(display, display.display)).fontSize(this.menuFontSize())
              .fontColor(display.online ? '#111111' : '#777777').maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.rustDeskDisplaySizeLabel(display)).fontSize(11).fontColor('#6B7280')
              .margin({ top: 2 })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          if (this.isRustDeskDisplayPending(display.display)) {
            Text('切换中').fontSize(11).fontColor(this.accentColor)
          }
        }
        .width('100%').height(this.menuItemHeight() + 8).padding({ left: 8, right: 8 })
        .borderRadius(6).opacity(display.online ? 1 : 0.55)
        .onClick((): void => {
          this.noteUserActivity();
          if (!display.online) {
            this.actions.onUnsupported('displaySettings', '该远端显示器当前离线');
            return;
          }
          this.actions.onSelectRustDeskDisplay(display.display);
        })
      }, (display: RustDeskDisplayInfo): string => display.display.toString())
  }

  @Builder
  private resolutionSubMenuContent() {
    ForEach(this.rustDeskDisplayCapabilities.resolutions,
      (resolution: RustDeskDisplayResolution): void => {
        this.menuItem(this.rustDeskDisplayResolutionLabel(resolution), 'displaySettings', (): void => {
          if (!this.rustDeskDisplaySwitchPending()) {
            this.actions.onSetRustDeskDisplayResolution(resolution.width, resolution.height);
          }
        }, this.isRustDeskDisplayResolutionSelected(resolution))
      }, (resolution: RustDeskDisplayResolution): string =>
        resolution.width.toString() + 'x' + resolution.height.toString())
  }

  @Builder
  private imageQualitySubMenuContent() {
    this.menuItem('速度优先', 'displaySettings', (): void => {
      this.actions.onSetRustDeskImageQuality(0);
    }, this.imageQuality === 0)
    this.menuItem('平衡', 'displaySettings', (): void => {
      this.actions.onSetRustDeskImageQuality(1);
    }, this.imageQuality === 1)
    this.menuItem('画质优先', 'displaySettings', (): void => {
      this.actions.onSetRustDeskImageQuality(2);
    }, this.imageQuality === 2)
  }

  @Builder
  private codecSubMenuContent() {
    this.menuItem('自动', 'displaySettings', (): void => {
      this.actions.onSetRustDeskCodec(0);
    }, this.codec === 0)
    this.menuItem('VP8', 'displaySettings', (): void => {
      this.actions.onSetRustDeskCodec(1);
    }, this.codec === 1)
    this.menuItem('VP9', 'displaySettings', (): void => {
      this.actions.onSetRustDeskCodec(2);
    }, this.codec === 2)
    this.menuItem('AV1', 'displaySettings', (): void => {
      this.actions.onSetRustDeskCodec(3);
    }, this.codec === 3)
    this.menuItem('H264', 'displaySettings', (): void => {
      this.actions.onSetRustDeskCodec(4);
    }, this.codec === 4)
    this.menuItem('H265', 'displaySettings', (): void => {
      this.actions.onSetRustDeskCodec(5);
    }, this.codec === 5)
  }

  @Builder
  private displayMenu() {
    Column() {
      this.menuHeader('显示与画质', $r('sys.symbol.display'))
      Scroll() {
        Column() {
          this.displayRootMenuContent()
        }.width('100%').padding(this.menuPadding())
      }
      .width('100%').constraintSize({ maxHeight: this.menuScrollMaxHeight() })
      .scrollable(ScrollDirection.Vertical).scrollBar(BarState.Auto)
    }
    .width(this.effectiveMenuWidth())
    .constraintSize({ maxHeight: this.sidebarMenuMaxHeight() })
    .backgroundColor('rgba(255,255,255,0.96)')
    .borderRadius(16).clip(true)
    .shadow({ radius: 10, color: 'rgba(0,0,0,0.22)', offsetY: 2 })
    .position({ x: this.menuLeft(), y: this.menuTop() })
    .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
    .onHover((isHover: boolean): void => { this.onExpandableMenuHover(isHover); })
  }

  @Builder
  private desktopFlipMenu() {
    Column() {
      this.menuHeader('画面翻转', $r('sys.symbol.rectangle_rotate'))
      Column() {
        this.menuItem('画面上下翻转', 'desktopFlip', (): void => {
          this.toggleDesktopFlipAxis('visual_y');
        }, this.desktopFlipState().visualFlipY)
        this.menuItem('画面左右翻转', 'desktopFlip', (): void => {
          this.toggleDesktopFlipAxis('visual_x');
        }, this.desktopFlipState().visualFlipX)
        this.menuItem('控制层上下翻转', 'desktopFlip', (): void => {
          this.toggleDesktopFlipAxis('control_y');
        }, this.desktopFlipState().controlFlipY)
        this.menuItem('控制层左右翻转', 'desktopFlip', (): void => {
          this.toggleDesktopFlipAxis('control_x');
        }, this.desktopFlipState().controlFlipX)
        this.menuItem('复位', 'desktopFlip', (): void => {
          this.actions.onSetRustDeskDesktopFlipMode('reset');
        }, this.rustDeskDesktopFlipMode === 'reset')
      }
      .width('100%').padding(this.menuPadding())
    }
    .width(260)
    .backgroundColor('rgba(255,255,255,0.96)')
    .borderRadius(16).clip(true)
    .shadow({ radius: 10, color: 'rgba(0,0,0,0.22)', offsetY: 2 })
    .position({ x: this.menuLeft(260), y: this.menuTop() })
    .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
  }

  @Builder
  private keyboardMenu() {
    Column() {
      this.menuHeader('键盘', $r('sys.symbol.keyboard'))
      Column() {
        this.menuItem(this.keyboardOpen ? '关闭虚拟键盘' : '打开虚拟键盘',
          'toggleKeyboard', (): void => {
            this.closeMenus();
            this.actions.onOpenKeyboard();
          }, this.keyboardOpen)
        this.menuItem(this.shortcutsOpen ? '关闭组合键与功能键' : '组合键与功能键',
          'toggleModifiers', (): void => {
            this.closeMenus();
            this.actions.onOpenModifiers();
          }, this.shortcutsOpen)
      }
      .width('100%').padding(this.menuPadding())
    }
    .width(this.effectiveMenuWidth())
    .constraintSize({ maxHeight: this.sidebarMenuMaxHeight() })
    .backgroundColor('rgba(255,255,255,0.96)')
    .borderRadius(16).clip(true)
    .shadow({ radius: 10, color: 'rgba(0,0,0,0.22)', offsetY: 2 })
    .position({ x: this.keyboardMenuLeft(), y: this.keyboardMenuTop() })
    .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
  }

  @Builder
  private keyboardMouseRootMenuContent() {
    if (this.protocol === 'rustdesk') {
      this.menuItem('浏览模式', 'browseMode', (): void => {
        this.actions.onToggleBrowseMode(!this.browseMode);
      }, this.browseMode)
      this.menuItem('显示我的光标', 'keyboardMouseSettings', (): void => {
        this.actions.onToggleShowLocalCursor(!this.showLocalCursor);
      }, this.showLocalCursor)
      this.menuItem('相对鼠标模式', 'keyboardMouseSettings', (): void => {
        this.actions.onToggleRelativeMouse(!this.relativeMouseMode);
      }, this.relativeMouseMode)
    }
    this.menuItem('远程滚轮反向', 'keyboardMouseSettings', (): void => {
      this.actions.onToggleReverseWheel(!this.reverseWheel);
    }, this.reverseWheel)
    if (this.protocol === 'rustdesk') {
      this.menuItem('交换鼠标左右键', 'keyboardMouseSettings', (): void => {
        this.actions.onToggleSwapMouseButtons(!this.swapMouseButtons);
      }, this.swapMouseButtons)
      this.subMenuItem('触控板速度', this.touchpadSpeed.toFixed(1) + 'x',
        'keyboardMouseSettings', 'touchpadSpeed')
      if (this.activeSubMenu === 'touchpadSpeed') {
        this.touchpadSpeedSubMenuContent()
      }
    }
  }

  @Builder
  private touchpadSpeedSubMenuContent() {
    ForEach(rustDeskTouchpadSpeedOptions(), (speed: number): void => {
      this.menuItem((Math.abs(speed - 1.0) < 0.05 ? '标准 ' : '') +
        speed.toFixed(1) + 'x', 'keyboardMouseSettings', (): void => {
        this.actions.onSetTouchpadSpeed(speed);
      }, Math.abs(this.touchpadSpeed - speed) < 0.05)
    }, (speed: number): string => speed.toFixed(1))
  }

  @Builder
  private keyboardMouseMenu() {
    Column() {
      this.menuHeader('鼠标与触控', $r('sys.symbol.mouse'))
      Scroll() {
        Column() {
          this.keyboardMouseRootMenuContent()
        }.width('100%').padding(this.menuPadding())
      }
      .width('100%').constraintSize({ maxHeight: this.menuScrollMaxHeight() })
      .scrollable(ScrollDirection.Vertical).scrollBar(BarState.Auto)
    }
    .width(this.effectiveMenuWidth())
    .constraintSize({ maxHeight: this.sidebarMenuMaxHeight() })
    .backgroundColor('rgba(255,255,255,0.96)')
    .borderRadius(16).clip(true)
    .shadow({ radius: 10, color: 'rgba(0,0,0,0.22)', offsetY: 2 })
    .position({ x: this.menuLeft(), y: this.menuTop() })
    .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
    .onHover((isHover: boolean): void => { this.onExpandableMenuHover(isHover); })
  }

  @Builder
  private chatMenu() {
    Column() {
      this.menuItem('文字聊天', 'textChat', (): void => {})
      this.menuItem('语音通话', 'voiceCall', (): void => {})
    }
    .width(180)
    .padding(12)
    .backgroundColor('rgba(255,255,255,0.96)')
    .borderRadius(10)
    .shadow({ radius: 10, color: 'rgba(0,0,0,0.22)', offsetY: 2 })
    .position({ x: this.menuLeft(180), y: this.menuTop() })
  }

  @Builder
  private primaryActionButton(actionId: RemoteSessionPrimaryActionId) {
    if (actionId === 'pin') {
      this.iconButton(this.pinned ? $r('sys.symbol.pin_fill') : $r('sys.symbol.pin'),
        this.pinned ? '#3A3A3A' : this.accentColor, (): void => {
          this.pinned = !this.pinned;
          this.scheduleAutoCollapse();
        }, 18, this.pinned ? '取消固定会话工具栏' : '固定会话工具栏')
    } else if (actionId === 'control') {
      this.iconButton($r('sys.symbol.gearshape_fill'), this.accentColor,
        (): void => { this.toggleMenu('control'); }, 18, '打开会话控制')
    } else if (actionId === 'display') {
      this.iconButton($r('sys.symbol.display'),
        this.canvasResetAvailable ? '#2A9D8F' : this.accentColor,
        (): void => { this.toggleMenu('display'); }, 18,
        this.canvasResetAvailable ? '打开显示与画质，画面可复位' : '打开显示与画质')
    } else if (actionId === 'desktopFlip') {
      this.iconButton($r('sys.symbol.rectangle_rotate'),
        this.rustDeskDesktopFlipMode === 'reset' ? this.accentColor : '#2A9D8F',
        (): void => { this.toggleMenu('desktopFlip'); }, 18, '打开画面翻转选项')
    } else if (actionId === 'keyboardMouse') {
      this.iconButton($r('sys.symbol.mouse'), this.accentColor,
        (): void => { this.toggleMenu('keyboardMouse'); }, 18, '打开鼠标与触控设置')
    } else if (actionId === 'keyboard') {
      this.iconButton($r('sys.symbol.keyboard'),
        this.keyboardSurfaceOpen() ? '#2A9D8F' : this.accentColor,
        (): void => { this.activateKeyboardAffordance(); }, 18,
        this.keyboardSurfaceOpen() ? '关闭键盘界面' : '选择虚拟键盘或组合键')
    } else if (actionId === 'fileTransfer') {
      this.iconButton($r('sys.symbol.doc'), this.accentColor, (): void => {
        this.runAction('fileTransfer', (): void => { this.actions.onOpenFileTransfer(); });
      }, 18, '发送文件')
    } else if (actionId === 'diagnostics') {
      this.iconButton($r('sys.symbol.performance'),
        this.diagnosticsEnabled ? '#2A9D8F' : this.accentColor, (): void => {
          this.runAction('diagnostics', (): void => {
            this.actions.onToggleDiagnostics(!this.diagnosticsEnabled);
          });
        }, 18, this.diagnosticsEnabled ? '关闭性能面板' : '打开性能面板')
    } else {
      this.iconButton($r('sys.symbol.xmark_circle_fill'), '#FF5353',
        (): void => { this.actions.onDisconnect(); }, 18, '断开 RustDesk 会话')
    }
  }

  @Builder
  private primaryActionButtons(vertical: boolean) {
    if (vertical) {
      Column({ space: this.layout.itemGap }) {
        ForEach(remoteSessionPrimaryActionIds(
          this.protocol, this.layout.deviceClass, this.rustDeskPhoneTarget),
          (actionId: RemoteSessionPrimaryActionId): void => {
            this.primaryActionButton(actionId)
          }, (actionId: RemoteSessionPrimaryActionId): string => actionId)
      }
    } else {
      Row({ space: this.layout.itemGap }) {
        ForEach(remoteSessionPrimaryActionIds(
          this.protocol, this.layout.deviceClass, this.rustDeskPhoneTarget),
          (actionId: RemoteSessionPrimaryActionId): void => {
            this.primaryActionButton(actionId)
          }, (actionId: RemoteSessionPrimaryActionId): string => actionId)
      }
    }
  }

  @Builder
  private toolbarBody() {
    Stack() {
      Row() {
        this.primaryActionButtons(false)
      }
      .height(this.layout.iconSize + 12)
      .padding({ left: this.layout.itemGap, right: this.layout.itemGap })
      .backgroundColor('rgba(255,255,255,0.94)')
      .backdropBlur(16)
      .border({ width: 0.5, color: REMOTE_SESSION_COLLAPSED_RAIL_BORDER })
      .borderRadius({ topLeft: 0, topRight: 0, bottomLeft: 10, bottomRight: 10 })
      .shadow({ radius: 10, color: 'rgba(0,0,0,0.24)', offsetY: 2 })
      .position({ x: 0, y: 0 })

      Row() {
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(16)
          .fontColor([REMOTE_SESSION_COLLAPSED_RAIL_ICON])
        Text('收起')
          .fontSize(10)
          .fontColor(REMOTE_SESSION_COLLAPSED_RAIL_ICON)
          .margin({ left: 4 })
      }
      .height(28)
      .padding({ left: 10, right: 10 })
      .backgroundColor('rgba(255,255,255,0.92)')
      .borderRadius({ topLeft: 0, topRight: 0, bottomLeft: 7, bottomRight: 7 })
      .position({ x: Math.max(0, this.toolbarWidth() / 2 - 32), y: this.layout.iconSize + 8 })
      .onClick((): void => {
        this.collapsed = true;
        this.closeMenus();
      })

      if (this.activeMenu === 'control') {
        this.controlMenu()
      }
      if (this.activeMenu === 'display') {
        this.displayMenu()
      }
      if (this.activeMenu === 'desktopFlip' && this.layout.deviceClass === 'pc' &&
        !this.rustDeskPhoneTarget) {
        this.desktopFlipMenu()
      }
      if (this.activeMenu === 'keyboardMouse') {
        this.keyboardMouseMenu()
      }
      if (this.activeMenu === 'keyboard') {
        this.keyboardMenu()
      }
      if (this.activeMenu === 'chat') {
        this.chatMenu()
      }
    }
    .width(this.toolbarWidth())
    .height(520)
    .onHover((isHover: boolean): void => {
      if (isHover) {
        this.noteUserActivity();
      } else {
        this.scheduleAutoCollapse();
      }
    })
  }

  @Builder
  private edgeRailBody() {
    Stack() {
      Scroll() {
        Column() {
          this.primaryActionButtons(true)
          Blank().height(this.layout.itemGap)
          Row() {
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(16)
              .fontColor([REMOTE_SESSION_COLLAPSED_RAIL_ICON])
            Text('收起').fontSize(10)
              .fontColor(REMOTE_SESSION_COLLAPSED_RAIL_ICON).margin({ left: 4 })
          }
          .height(30)
          .width(this.edgeRailWidth() - 12)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('rgba(255,255,255,0.92)')
          .borderRadius(7)
          .accessibilityText('收起会话贴边栏')
          .onClick((): void => {
            this.collapsed = true;
            this.closeMenus();
          })
        }
        .width('100%').padding(6)
      }
      .width(this.edgeRailWidth())
      .height(this.edgeRailVisibleHeight())
      .scrollable(ScrollDirection.Vertical).scrollBar(BarState.Auto)
      .backgroundColor('rgba(255,255,255,0.94)')
      .backdropBlur(16)
      .border({ width: 0.5, color: REMOTE_SESSION_COLLAPSED_RAIL_BORDER })
      .borderRadius({ topLeft: 10, bottomLeft: 10, topRight: 0, bottomRight: 0 })
      .shadow({ radius: 10, color: 'rgba(0,0,0,0.24)', offsetX: -2 })
      .position({ x: this.effectiveMenuWidth() + this.layout.itemGap, y: this.edgeRailOffsetY() })
      .parallelGesture(PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 5 })
        .onActionUpdate((event: GestureEvent): void => { this.updateRailSwipe(event); })
        .onActionEnd((event: GestureEvent): void => { this.finishRailSwipe(event); })
        .onActionCancel((): void => { this.resetRailSwipe(); }))
      .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)

      if (this.activeMenu === 'control') {
        this.controlMenu()
      }
      if (this.activeMenu === 'display') {
        this.displayMenu()
      }
      if (this.activeMenu === 'desktopFlip' && this.layout.deviceClass === 'pc' &&
        !this.rustDeskPhoneTarget) {
        this.desktopFlipMenu()
      }
      if (this.activeMenu === 'keyboardMouse') {
        this.keyboardMouseMenu()
      }
      if (this.activeMenu === 'keyboard') {
        this.keyboardMenu()
      }
      if (this.activeMenu === 'chat') {
        this.chatMenu()
      }
    }
    .width(this.effectiveMenuWidth() + this.edgeRailWidth() + this.layout.itemGap)
    .height(this.edgeRailCanvasHeight())
    .position({ x: '100%', y: '50%' })
    .markAnchor({ x: '100%', y: '50%' })
    .translate({ x: this.railSwipeX })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  private edgeRailHandle() {
    Stack() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(15)
          .fontColor([REMOTE_SESSION_COLLAPSED_RAIL_ICON])
      }
      .width(REMOTE_SESSION_COLLAPSED_RAIL_WIDTH)
      .height(this.collapsedEdgeRailHeight())
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
    .height(this.collapsedEdgeRailHeight())
    .focusable(false).focusOnTouch(false)
    .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
    .accessibilityText(this.keyboardSurfaceOpen() ? '关闭键盘界面' : '展开会话贴边栏')
    .position({ x: '100%', y: '50%' })
    .markAnchor({ x: '100%', y: '50%' })
    .onClick((): void => {
      if (this.keyboardSurfaceOpen()) {
        this.actions.onCloseKeyboardSurface();
        return;
      }
      this.collapsed = false;
      this.scheduleAutoCollapse();
    })
  }

  @Builder
  private topBarHandle() {
    Stack() {
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(15)
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
    .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
    .accessibilityText(this.keyboardSurfaceOpen() ? '关闭键盘界面' : '展开会话顶栏')
    .onClick((): void => {
      if (this.keyboardSurfaceOpen()) {
        this.actions.onCloseKeyboardSurface();
        return;
      }
      this.collapsed = false;
      this.scheduleAutoCollapse();
    })
  }

  build() {
    Stack() {
      if (this.edgeRail) {
        if (this.collapsed) {
          this.edgeRailHandle()
        } else {
          this.edgeRailBody()
        }
      } else {
        Stack({ alignContent: Alignment.Top }) {
          if (this.collapsed) {
            this.topBarHandle()
          } else {
            this.toolbarBody()
          }
        }
        .width('100%')
        .height(this.collapsed ? REMOTE_SESSION_COLLAPSED_TOP_TOUCH_HEIGHT : 540)
        .position({ x: 0, y: 0 })
        .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
    .onAreaChange((_old: Area, next: Area): void => {
      const width: number = next.width as number;
      const height: number = next.height as number;
      if (Number.isFinite(width) && width > 0) { this.viewportWidth = width; }
      if (Number.isFinite(height) && height > 0) { this.viewportHeight = height; }
    })
  }
}
