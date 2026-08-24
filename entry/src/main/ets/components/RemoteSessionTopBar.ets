import { curves } from '@kit.ArkUI';
import {
  REMOTE_SESSION_COLLAPSED_RAIL_BACKGROUND,
  REMOTE_SESSION_COLLAPSED_RAIL_BORDER,
  REMOTE_SESSION_COLLAPSED_RAIL_HEIGHT,
  REMOTE_SESSION_COLLAPSED_RAIL_ICON,
  REMOTE_SESSION_COLLAPSED_RAIL_TOUCH_WIDTH,
  REMOTE_SESSION_COLLAPSED_RAIL_WIDTH,
  RemoteTopBarLayout,
  remoteSessionRailDragOffset,
  remoteSessionRailShouldCollapse,
  rustDeskTopBarAutoCollapseDelayMs,
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
  inputBlocked: false,
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
    topOffset: 8,
    maxVisibleButtons: 8,
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
  @Prop rustDeskPhoneTarget: boolean = false;
  @Prop keyboardOpen: boolean = false;
  @Prop diagnosticsEnabled: boolean = false;
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
    this.activeMenu = this.activeMenu === menu ? '' : menu;
    this.scheduleAutoCollapse();
  }

  private closeMenus(): void {
    this.activeMenu = '';
    this.scheduleAutoCollapse();
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
      event.offsetX, event.velocityX);
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
    const delayMs: number = rustDeskTopBarAutoCollapseDelayMs(this.pinned, this.activeMenu.length > 0);
    if (delayMs <= 0) {
      return;
    }
    this.autoCollapseTimer = setTimeout((): void => {
      if (!this.pinned && this.activeMenu.length === 0) {
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

  private onEdgeRailChanged(): void {
    this.clearAutoCollapseTimer();
    this.activeMenu = '';
    this.collapsed = false;
    this.pinned = false;
    this.scheduleAutoCollapse();
  }

  aboutToAppear(): void {
    this.collapsed = false;
    this.activeMenu = '';
    this.scheduleAutoCollapse();
  }

  aboutToDisappear(): void {
    this.clearAutoCollapseTimer();
  }

  private toolbarWidth(): number {
    const count: number = Math.max(1, this.layout.maxVisibleButtons);
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
    return 8;
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
    return Math.max(88, this.sidebarMenuMaxHeight() - this.menuHeaderHeight());
  }

  private qualityLabel(value: number): string {
    if (value === 0) { return '速度'; }
    if (value === 2) { return '画质'; }
    return '平衡';
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
      .accessibilityText(accessibilityLabel)
      .onClick((): void => {
        this.noteUserActivity();
        action();
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
  private displayMenu() {
    Column() {
      this.menuHeader('显示与画质', $r('sys.symbol.display'))
      Scroll() {
        Column() {
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
          this.menuItem('重新居中画面', 'displaySettings', (): void => {
            this.actions.onResetCanvasTransform();
          })
          if (this.protocol === 'rustdesk') {
            if (this.rustDeskPhoneTarget) {
              this.menuItem('旋转远端画面（顺时针 90°）', 'rotateDisplay', (): void => {
                this.actions.onRotateRemoteDisplay();
              })
            }

            if (this.hasRustDeskDisplayData()) {
            Column({ space: 6 }) {
              Text('远端显示器').fontSize(12).fontColor('#6B7280')
                .margin({ left: 8, top: 4 }).alignSelf(ItemAlign.Start)
              Row() {
                Column() {
                  Text(this.displaySwitchStatusLabel()).fontSize(14).fontWeight(FontWeight.Medium)
                    .fontColor('#111111').maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.displayResolutionStatusLabel()).fontSize(11).fontColor('#6B7280')
                    .margin({ top: 2 })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                if (this.rustDeskDisplaySwitchPending()) {
                  Text('切换中').fontSize(11).fontColor(this.accentColor)
                } else {
                  SymbolGlyph($r('sys.symbol.checkmark')).fontSize(15).fontColor([this.accentColor])
                }
              }
              .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .backgroundColor('rgba(0,125,255,0.08)').borderRadius(6)

              if (this.rustDeskDisplayCapabilities.displays.length > 0) {
                Text('选择显示器').fontSize(12).fontColor('#6B7280')
                  .margin({ left: 8, top: 4 }).alignSelf(ItemAlign.Start)
                ForEach(this.rustDeskDisplayCapabilities.displays,
                  (display: RustDeskDisplayInfo): void => {
                    Row() {
                      Column() {
                        Text(this.rustDeskDisplayLabel(display, display.display)).fontSize(13)
                          .fontColor(this.isRustDeskDisplaySelected(display.display) ? '#FFFFFF' : '#374151').maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text(this.rustDeskDisplaySizeLabel(display)).fontSize(10)
                          .fontColor(this.isRustDeskDisplaySelected(display.display) ?
                            'rgba(255,255,255,0.78)' : '#6B7280')
                          .margin({ top: 2 })
                      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                      if (this.isRustDeskDisplayPending(display.display)) {
                        Text('切换中').fontSize(10).fontColor('#FFFFFF')
                      } else if (this.isRustDeskDisplayCurrent(display.display) &&
                        !this.rustDeskDisplaySwitchPending()) {
                        SymbolGlyph($r('sys.symbol.checkmark')).fontSize(15).fontColor(['#FFFFFF'])
                      }
                    }
                    .width('100%').height(48).padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .backgroundColor(this.isRustDeskDisplaySelected(display.display) ?
                      this.accentColor : '#F3F4F6').borderRadius(6)
                    .opacity(display.online ? 1 : 0.55)
                    .onClick((): void => {
                      this.noteUserActivity();
                      if (!display.online) {
                        this.actions.onUnsupported('resolutionSettings', '该远端显示器当前离线');
                        return;
                      }
                      this.actions.onSelectRustDeskDisplay(display.display);
                    })
                  }, (display: RustDeskDisplayInfo): string => display.display.toString())
              }

              Divider().strokeWidth(1).color('#E5E7EB').margin({ top: 4, bottom: 2 })
              Text('当前显示器分辨率').fontSize(12).fontColor('#6B7280')
                .margin({ left: 8, top: 4 }).alignSelf(ItemAlign.Start)
              ForEach(this.rustDeskDisplayCapabilities.resolutions,
                (resolution: RustDeskDisplayResolution): void => {
                  Row() {
                    Text(this.rustDeskDisplayResolutionLabel(resolution)).fontSize(13)
                      .fontColor(this.isRustDeskDisplayResolutionSelected(resolution) ?
                        '#FFFFFF' : '#374151').layoutWeight(1)
                    if (this.isRustDeskDisplayResolutionSelected(resolution)) {
                      SymbolGlyph($r('sys.symbol.checkmark')).fontSize(15).fontColor(['#FFFFFF'])
                    }
                  }
                  .width('100%').height(40).padding({ left: 12, right: 12 })
                  .backgroundColor(this.isRustDeskDisplayResolutionSelected(resolution) ?
                    this.accentColor : '#F3F4F6').borderRadius(6)
                  .opacity(this.rustDeskDisplaySwitchPending() ? 0.55 : 1)
                  .onClick((): void => {
                    this.noteUserActivity();
                    if (!this.rustDeskDisplaySwitchPending()) {
                      this.actions.onSetRustDeskDisplayResolution(resolution.width, resolution.height);
                    }
                  })
                }, (resolution: RustDeskDisplayResolution): string =>
                  resolution.width.toString() + 'x' + resolution.height.toString())
              if (this.rustDeskDisplayCapabilities.resolutions.length === 0) {
                Text('当前显示器暂无可选分辨率').fontSize(12).fontColor('#6B7280')
                  .width('100%').textAlign(TextAlign.Center).padding({ top: 8, bottom: 4 })
              }
              this.menuItem('打开完整显示器与分辨率面板', 'resolutionSettings', (): void => {
                this.actions.onOpenRustDeskResolution();
              })
            }.width('100%')
            } else {
              this.menuItem('显示器与分辨率', 'resolutionSettings', (): void => {
                this.actions.onOpenRustDeskResolution();
              })
            }

          this.menuItem('画质: ' + this.qualityLabel(this.imageQuality), 'displaySettings', (): void => {
            const next: number = this.imageQuality >= 2 ? 0 : this.imageQuality + 1;
            this.actions.onSetRustDeskImageQuality(next);
          })
          this.menuItem('编解码: ' + this.codecLabel(this.codec), 'displaySettings', (): void => {
            const next: number = this.codec >= 5 ? 0 : this.codec + 1;
            this.actions.onSetRustDeskCodec(next);
          })
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
      }
      .width('100%')
      .constraintSize({ maxHeight: this.menuScrollMaxHeight() })
      .scrollBar(BarState.Auto)
    }
    .width(this.effectiveMenuWidth())
    .constraintSize({ maxHeight: this.sidebarMenuMaxHeight() })
    .padding({ left: this.menuPadding(), right: this.menuPadding(), bottom: this.menuPadding() })
    .backgroundColor('rgba(255,255,255,0.96)')
    .borderRadius(16).clip(true)
    .shadow({ radius: 10, color: 'rgba(0,0,0,0.22)', offsetY: 2 })
    .position({ x: this.menuLeft(), y: this.menuTop() })
    .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
  }

  @Builder
  private keyboardMouseMenu() {
    Column() {
      this.menuHeader('键盘与鼠标', $r('sys.symbol.mouse'))
      Scroll() {
        Column() {
          this.menuItem(this.keyboardOpen ? '关闭虚拟键盘' : '打开虚拟键盘', 'toggleKeyboard', (): void => {
            this.actions.onOpenKeyboard();
          }, this.keyboardOpen)
          this.menuItem('组合键与功能键', 'toggleModifiers', (): void => {
            this.actions.onOpenModifiers();
          })
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
            this.menuItem('触控板速度 ' + this.touchpadSpeed.toFixed(1) + 'x', 'keyboardMouseSettings', (): void => {
              const next: number = this.touchpadSpeed >= 1.6 ? 0.8 : this.touchpadSpeed + 0.4;
              this.actions.onSetTouchpadSpeed(next);
            })
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
  private toolbarBody() {
    Stack() {
      Row() {
        this.iconButton(this.pinned ? $r('sys.symbol.pin_fill') : $r('sys.symbol.pin'),
          this.pinned ? '#3A3A3A' : this.accentColor, (): void => {
          this.pinned = !this.pinned;
          this.scheduleAutoCollapse();
        }, 18, this.pinned ? '取消固定 RustDesk 工具栏' : '固定 RustDesk 工具栏')
        Blank().width(this.layout.itemGap)
        this.iconButton($r('sys.symbol.gearshape_fill'), this.accentColor,
          (): void => { this.toggleMenu('control'); }, 18, '打开会话控制')
        Blank().width(this.layout.itemGap)
        this.iconButton($r('sys.symbol.display'), this.accentColor,
          (): void => { this.toggleMenu('display'); }, 18, '打开显示与画质')
        Blank().width(this.layout.itemGap)
        this.iconButton($r('sys.symbol.mouse'), this.keyboardOpen ? '#2A9D8F' : this.accentColor,
          (): void => { this.toggleMenu('keyboardMouse'); }, 18, '打开键盘与鼠标')
        Blank().width(this.layout.itemGap)
        this.iconButton($r('sys.symbol.keyboard'), this.accentColor, (): void => {
          this.runAction('toggleModifiers', (): void => { this.actions.onOpenModifiers(); });
        }, 18, '打开组合键与功能键')
        Blank().width(this.layout.itemGap)
        this.iconButton($r('sys.symbol.doc'), this.accentColor, (): void => {
          this.runAction('fileTransfer', (): void => { this.actions.onOpenFileTransfer(); });
        }, 18, '发送文件')
        Blank().width(this.layout.itemGap)
        this.iconButton($r('sys.symbol.performance'),
          this.diagnosticsEnabled ? '#2A9D8F' : this.accentColor, (): void => {
            this.runAction('diagnostics', (): void => {
              this.actions.onToggleDiagnostics(!this.diagnosticsEnabled);
            });
          }, 18, this.diagnosticsEnabled ? '关闭性能面板' : '打开性能面板')
        Blank().width(this.layout.itemGap)
        this.iconButton($r('sys.symbol.xmark_circle_fill'), '#FF5353',
          (): void => { this.actions.onDisconnect(); }, 18, '断开 RustDesk 会话')
      }
      .height(this.layout.iconSize + 12)
      .padding({ left: this.layout.itemGap, right: this.layout.itemGap })
      .backgroundColor('rgba(255,255,255,0.94)')
      .borderRadius(8)
      .shadow({ radius: 10, color: 'rgba(0,0,0,0.24)', offsetY: 2 })
      .position({ x: 0, y: 0 })

      Row() {
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(16)
          .fontColor(['#444444'])
        Text('收起')
          .fontSize(10)
          .fontColor('#444444')
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
      if (this.activeMenu === 'keyboardMouse') {
        this.keyboardMouseMenu()
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
          this.iconButton(this.pinned ? $r('sys.symbol.pin_fill') : $r('sys.symbol.pin'),
            this.pinned ? '#3A3A3A' : this.accentColor, (): void => {
              this.pinned = !this.pinned;
              this.scheduleAutoCollapse();
            }, 18, this.pinned ? '取消固定 RustDesk 侧栏' : '固定 RustDesk 侧栏')
          Blank().height(this.layout.itemGap)
          this.iconButton($r('sys.symbol.gearshape_fill'), this.accentColor, (): void => {
            this.toggleMenu('control');
          }, 18, '打开会话控制')
          Blank().height(this.layout.itemGap)
          this.iconButton($r('sys.symbol.display'), this.accentColor, (): void => {
            this.toggleMenu('display');
          }, 18, '打开显示与画质')
          Blank().height(this.layout.itemGap)
          this.iconButton($r('sys.symbol.mouse'), this.keyboardOpen ? '#2A9D8F' : this.accentColor,
            (): void => { this.toggleMenu('keyboardMouse'); }, 18, '打开键盘与鼠标')
          Blank().height(this.layout.itemGap)
          this.iconButton($r('sys.symbol.keyboard'), this.accentColor, (): void => {
            this.runAction('toggleModifiers', (): void => { this.actions.onOpenModifiers(); });
          }, 18, '打开组合键与功能键')
          Blank().height(this.layout.itemGap)
          this.iconButton($r('sys.symbol.doc'), this.accentColor, (): void => {
            this.runAction('fileTransfer', (): void => { this.actions.onOpenFileTransfer(); });
          }, 18, '发送文件')
          Blank().height(this.layout.itemGap)
          this.iconButton($r('sys.symbol.performance'),
            this.diagnosticsEnabled ? '#2A9D8F' : this.accentColor, (): void => {
              this.runAction('diagnostics', (): void => {
                this.actions.onToggleDiagnostics(!this.diagnosticsEnabled);
              });
            }, 18, this.diagnosticsEnabled ? '关闭性能面板' : '打开性能面板')
          Blank().height(this.layout.itemGap)
          this.iconButton($r('sys.symbol.xmark_circle_fill'), '#FF5353', (): void => {
            this.actions.onDisconnect();
          }, 18, '断开 RustDesk 会话')
          Blank().height(this.layout.itemGap)
          Row() {
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(16)
              .fontColor(['#444444'])
            Text('隐藏').fontSize(10).fontColor('#444444').margin({ left: 4 })
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
      .borderRadius({ topLeft: 10, bottomLeft: 10, topRight: 0, bottomRight: 0 })
      .shadow({ radius: 10, color: 'rgba(0,0,0,0.24)', offsetX: -2 })
      .position({ x: this.effectiveMenuWidth() + this.layout.itemGap, y: this.edgeRailOffsetY() })
      .gesture(PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 5 })
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
      if (this.activeMenu === 'keyboardMouse') {
        this.keyboardMouseMenu()
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
      .height(REMOTE_SESSION_COLLAPSED_RAIL_HEIGHT)
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
    .height(REMOTE_SESSION_COLLAPSED_RAIL_HEIGHT)
    .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
    .accessibilityText('展开会话贴边栏')
    .position({ x: '100%', y: '50%' })
    .markAnchor({ x: '100%', y: '50%' })
    .onClick((): void => {
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
            Row() {
              SymbolGlyph($r('sys.symbol.ellipsis_bubble'))
                .fontSize(18)
                .fontColor(['#444444'])
            }
            .width(48)
            .height(28)
            .justifyContent(FlexAlign.Center)
            .backgroundColor('rgba(248,250,252,0.58)')
            .backdropBlur(16)
            .borderRadius({ topLeft: 0, topRight: 0, bottomLeft: 8, bottomRight: 8 })
            .shadow({ radius: 8, color: 'rgba(0,0,0,0.22)', offsetY: 2 })
            .onClick((): void => {
              this.collapsed = false;
              this.scheduleAutoCollapse();
            })
          } else {
            this.toolbarBody()
          }
        }
        .width('100%')
        .height(this.collapsed ? 32 : 540)
        .position({ x: 0, y: this.layout.topOffset })
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
