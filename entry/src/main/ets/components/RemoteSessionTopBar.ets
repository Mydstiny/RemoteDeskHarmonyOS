import {
  RemoteTopBarLayout,
  rustDeskTopBarAutoCollapseDelayMs,
  rustDeskActionAvailability
} from '../services/RemoteSessionTopBarPolicy';
import { RemoteSessionCapabilities } from '../services/RemoteSessionCapabilityPolicy';

export interface RemoteSessionTopBarActions {
  onDisconnect: () => void;
  onRefreshFrame: () => void;
  onOpenKeyboard: () => void;
  onOpenFileTransfer: () => void;
  onCtrlAltDel: () => void;
  onLockRemote: () => void;
  onTogglePrivacy: (on: boolean) => void;
  onToggleAudio: (on: boolean) => void;
  onToggleClipboard: (on: boolean) => void;
  onToggleFilePaste: (on: boolean) => void;
  onSetViewScaleMode: (mode: string) => void;
  onResetCanvasTransform: () => void;
  onOpenRustDeskResolution: () => void;
  onSetRustDeskImageQuality: (quality: number) => void;
  onSetRustDeskCodec: (codec: number) => void;
  onToggleShowLocalCursor: (on: boolean) => void;
  onToggleBrowseMode: (on: boolean) => void;
  onToggleRelativeMouse: (on: boolean) => void;
  onToggleReverseWheel: (on: boolean) => void;
  onToggleSwapMouseButtons: (on: boolean) => void;
  onSetTouchpadSpeed: (speed: number) => void;
  onUnsupported: (actionId: string, reason: string) => void;
}

@Component
export struct RemoteSessionTopBar {
  @Prop layout: RemoteTopBarLayout = {
    deviceClass: 'pc',
    iconSize: 44,
    itemGap: 8,
    topOffset: 8,
    maxVisibleButtons: 7,
    menuWidth: 360
  };
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
  @Prop keyboardOpen: boolean = false;
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
  private autoCollapseTimer: number = -1;

  actions: RemoteSessionTopBarActions = {
    onDisconnect: (): void => {},
    onRefreshFrame: (): void => {},
    onOpenKeyboard: (): void => {},
    onOpenFileTransfer: (): void => {},
    onCtrlAltDel: (): void => {},
    onLockRemote: (): void => {},
    onTogglePrivacy: (_on: boolean): void => {},
    onToggleAudio: (_on: boolean): void => {},
    onToggleClipboard: (_on: boolean): void => {},
    onToggleFilePaste: (_on: boolean): void => {},
    onSetViewScaleMode: (_mode: string): void => {},
    onResetCanvasTransform: (): void => {},
    onOpenRustDeskResolution: (): void => {},
    onSetRustDeskImageQuality: (_quality: number): void => {},
    onSetRustDeskCodec: (_codec: number): void => {},
    onToggleShowLocalCursor: (_on: boolean): void => {},
    onToggleBrowseMode: (_on: boolean): void => {},
    onToggleRelativeMouse: (_on: boolean): void => {},
    onToggleReverseWheel: (_on: boolean): void => {},
    onToggleSwapMouseButtons: (_on: boolean): void => {},
    onSetTouchpadSpeed: (_speed: number): void => {},
    onUnsupported: (_actionId: string, _reason: string): void => {}
  };

  private runAction(actionId: string, action: () => void): void {
    this.noteUserActivity();
    const availability = rustDeskActionAvailability(actionId, this.capabilities);
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

  aboutToAppear(): void {
    this.scheduleAutoCollapse();
  }

  aboutToDisappear(): void {
    this.clearAutoCollapseTimer();
  }

  private toolbarWidth(): number {
    const count: number = Math.max(1, this.layout.maxVisibleButtons);
    return count * this.layout.iconSize + (count + 1) * this.layout.itemGap;
  }

  private menuLeft(): number {
    const fullWidth: number = this.toolbarWidth();
    return Math.max(0, (fullWidth - this.layout.menuWidth) / 2);
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

  @Builder
  private iconButton(icon: Resource, bgColor: string, action: () => void, fontSize?: number) {
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
        .fontSize(16)
        .fontColor(rustDeskActionAvailability(actionId, this.capabilities).enabled ? '#111111' : '#777777')
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(40)
    .padding({ left: 8, right: 8 })
    .borderRadius(6)
    .onClick((): void => {
      this.runAction(actionId, action);
    })
  }

  @Builder
  private controlMenu() {
    Column() {
      this.menuItem('发送剪贴板按键', 'toggleClipboard', (): void => {
        this.actions.onToggleClipboard(!this.clipboardEnabled);
      }, this.clipboardEnabled)
      this.menuItem('传输文件', 'fileTransfer', (): void => { this.actions.onOpenFileTransfer(); })
      this.menuItem('插入 Ctrl + Alt + Del', 'ctrlAltDel', (): void => { this.actions.onCtrlAltDel(); })
      this.menuItem('锁定远程电脑', 'lockRemote', (): void => { this.actions.onLockRemote(); })
      this.menuItem('刷新画面', 'refreshFrame', (): void => { this.actions.onRefreshFrame(); })
      this.menuItem('截屏', 'screenshot', (): void => {})
      this.menuItem('文字聊天', 'textChat', (): void => {})
      this.menuItem('语音通话', 'voiceCall', (): void => {})
      this.menuItem('录制', 'recordSession', (): void => {})
    }
    .width(this.layout.menuWidth)
    .padding(12)
    .backgroundColor('rgba(255,255,255,0.96)')
    .borderRadius(10)
    .shadow({ radius: 10, color: 'rgba(0,0,0,0.22)', offsetY: 2 })
    .position({ x: this.menuLeft(), y: this.layout.iconSize + 12 })
  }

  @Builder
  private displayMenu() {
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
      this.menuItem('画质: ' + this.qualityLabel(this.imageQuality), 'displaySettings', (): void => {
        const next: number = this.imageQuality >= 2 ? 0 : this.imageQuality + 1;
        this.actions.onSetRustDeskImageQuality(next);
      })
      this.menuItem('编解码: ' + this.codecLabel(this.codec), 'displaySettings', (): void => {
        const next: number = this.codec >= 5 ? 0 : this.codec + 1;
        this.actions.onSetRustDeskCodec(next);
      })
      this.menuItem('分辨率', 'resolutionSettings', (): void => {
        this.actions.onOpenRustDeskResolution();
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
    .width(this.layout.menuWidth)
    .padding(12)
    .backgroundColor('rgba(255,255,255,0.96)')
    .borderRadius(10)
    .shadow({ radius: 10, color: 'rgba(0,0,0,0.22)', offsetY: 2 })
    .position({ x: this.menuLeft(), y: this.layout.iconSize + 12 })
  }

  @Builder
  private keyboardMouseMenu() {
    Column() {
      this.menuItem(this.keyboardOpen ? '关闭虚拟键盘' : '打开虚拟键盘', 'toggleKeyboard', (): void => {
        this.actions.onOpenKeyboard();
      }, this.keyboardOpen)
      this.menuItem('浏览模式', 'browseMode', (): void => {
        this.actions.onToggleBrowseMode(!this.browseMode);
      }, this.browseMode)
      this.menuItem('显示我的光标', 'keyboardMouseSettings', (): void => {
        this.actions.onToggleShowLocalCursor(!this.showLocalCursor);
      }, this.showLocalCursor)
      this.menuItem('相对鼠标模式', 'keyboardMouseSettings', (): void => {
        this.actions.onToggleRelativeMouse(!this.relativeMouseMode);
      }, this.relativeMouseMode)
      this.menuItem('远程滚轮反向', 'keyboardMouseSettings', (): void => {
        this.actions.onToggleReverseWheel(!this.reverseWheel);
      }, this.reverseWheel)
      this.menuItem('交换鼠标左右键', 'keyboardMouseSettings', (): void => {
        this.actions.onToggleSwapMouseButtons(!this.swapMouseButtons);
      }, this.swapMouseButtons)
      this.menuItem('触控板速度 ' + this.touchpadSpeed.toFixed(1) + 'x', 'keyboardMouseSettings', (): void => {
        const next: number = this.touchpadSpeed >= 1.6 ? 0.8 : this.touchpadSpeed + 0.4;
        this.actions.onSetTouchpadSpeed(next);
      })
    }
    .width(this.layout.menuWidth)
    .padding(12)
    .backgroundColor('rgba(255,255,255,0.96)')
    .borderRadius(10)
    .shadow({ radius: 10, color: 'rgba(0,0,0,0.22)', offsetY: 2 })
    .position({ x: this.menuLeft(), y: this.layout.iconSize + 12 })
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
    .position({ x: Math.max(0, (this.toolbarWidth() - 180) / 2), y: this.layout.iconSize + 12 })
  }

  @Builder
  private toolbarBody() {
    Stack() {
      Row() {
        this.iconButton(this.pinned ? $r('sys.symbol.lock_fill') : $r('sys.symbol.ohos_lock'), this.pinned ? '#3A3A3A' : this.accentColor, (): void => {
          this.pinned = !this.pinned;
          this.scheduleAutoCollapse();
        })
        Blank().width(this.layout.itemGap)
        this.iconButton($r('sys.symbol.bolt_fill'), this.accentColor, (): void => { this.toggleMenu('control'); })
        Blank().width(this.layout.itemGap)
        this.iconButton($r('sys.symbol.desktop_fill'), this.accentColor, (): void => { this.toggleMenu('display'); })
        Blank().width(this.layout.itemGap)
        this.iconButton($r('sys.symbol.keyboard'), this.keyboardOpen ? '#2A9D8F' : this.accentColor,
          (): void => { this.toggleMenu('keyboardMouse'); })
        Blank().width(this.layout.itemGap)
        this.iconButton($r('sys.symbol.message'), this.accentColor, (): void => { this.toggleMenu('chat'); })
        Blank().width(this.layout.itemGap)
        this.iconButton($r('sys.symbol.record_circle'), this.accentColor, (): void => {
          this.runAction('recordSession', (): void => {});
        }, 18)
        Blank().width(this.layout.itemGap)
        this.iconButton($r('sys.symbol.xmark'), '#FF5353', (): void => { this.actions.onDisconnect(); }, 18)
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

  build() {
    Stack({ alignContent: Alignment.Top }) {
      if (this.collapsed) {
        Row() {
          SymbolGlyph($r('sys.symbol.ellipsis_bubble'))
            .fontSize(18)
            .fontColor(['#444444'])
        }
        .width(58)
        .height(28)
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(255,255,255,0.92)')
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
