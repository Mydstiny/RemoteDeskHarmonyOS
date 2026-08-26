import { curves } from '@kit.ArkUI';
import { OverlayPlacement, emptyOverlayPlacement } from '../services/RemoteOverlayViewportPolicy';
import {
  REMOTE_SESSION_COLLAPSED_RAIL_BACKGROUND,
  REMOTE_SESSION_COLLAPSED_RAIL_BORDER,
  REMOTE_SESSION_COLLAPSED_RAIL_HEIGHT,
  REMOTE_SESSION_COLLAPSED_RAIL_ICON,
  REMOTE_SESSION_COLLAPSED_RAIL_TOUCH_WIDTH,
  REMOTE_SESSION_COLLAPSED_RAIL_WIDTH,
  remoteSessionRailDragOffset,
  remoteSessionRailShouldCollapse
} from '../services/RemoteSessionTopBarPolicy';
import {
  VncToolbarPrimaryActionId,
  vncToolbarPrimaryActionIds
} from '../services/VncSessionUiPolicy';

export interface VncSessionToolbarActions {
  onExpand: () => void;
  onCollapse: () => void;
  onToggleKeyboard: () => void;
  onCycleControlMode: () => void;
  onOpenShortcuts: () => void;
  onCycleDisplayScale: () => void;
  onToggleDiagnostics: () => void;
  onDisconnect: () => void;
}

export interface VncSessionToolbarPlacementActions {
  onDrag: (offsetX: number, offsetY: number) => void;
}

@Component
export struct VncSessionToolbar {
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop deviceClass: 'pc' | 'pad' | 'phone' = 'pc';
  @Prop viewOnly: boolean = false;
  @Prop keyboardOpen: boolean = false;
  @Prop controlModeLabel: string = '触控板';
  @Prop displayScaleLabel: string = '适应';
  @Prop diagnosticsEnabled: boolean = false;
  @Prop collapsed: boolean = false;
  @Prop placement: OverlayPlacement = emptyOverlayPlacement('vnc-toolbar');
  @State private railSwipeX: number = 0;
  placementActions: VncSessionToolbarPlacementActions = {
    onDrag: (_offsetX: number, _offsetY: number): void => {}
  };
  actions: VncSessionToolbarActions = {
    onExpand: (): void => {},
    onCollapse: (): void => {},
    onToggleKeyboard: (): void => {},
    onCycleControlMode: (): void => {},
    onOpenShortcuts: (): void => {},
    onCycleDisplayScale: (): void => {},
    onToggleDiagnostics: (): void => {},
    onDisconnect: (): void => {}
  };

  @Builder
  private actionButton(icon: Resource, label: string, active: boolean,
    action: () => void, danger: boolean = false) {
    Button() {
      Column() {
        SymbolGlyph(icon).fontSize(17).fontColor([Color.White])
        Text(label).fontSize(8).fontColor('#FFFFFF').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 2 })
      }.justifyContent(FlexAlign.Center)
    }
    .width(56)
    .height(44)
    .padding(0).borderRadius(9)
    .backgroundColor(danger ? '#D93B3B' : (active ? '#168C78' : this.accentColor))
    .accessibilityText(label)
    .onClick(action)
  }

  @Builder
  private primaryActionButton(actionId: VncToolbarPrimaryActionId) {
    if (actionId === 'keyboard') {
      this.actionButton($r('sys.symbol.keyboard'), this.keyboardOpen ? '收键盘' : '键盘',
        this.keyboardOpen, (): void => { this.actions.onToggleKeyboard(); })
    } else if (actionId === 'controlMode') {
      this.actionButton($r('sys.symbol.arrow_up_left'), this.controlModeLabel, false,
        (): void => { this.actions.onCycleControlMode(); })
    } else if (actionId === 'shortcuts') {
      this.actionButton($r('sys.symbol.bolt_fill'), '组合键', false,
        (): void => { this.actions.onOpenShortcuts(); })
    } else if (actionId === 'displayScale') {
      this.actionButton($r('sys.symbol.desktop_fill'), this.displayScaleLabel, false,
        (): void => { this.actions.onCycleDisplayScale(); })
    } else if (actionId === 'diagnostics') {
      this.actionButton($r('sys.symbol.list_bullet'), '性能', this.diagnosticsEnabled,
        (): void => { this.actions.onToggleDiagnostics(); })
    } else {
      this.actionButton($r('sys.symbol.xmark'), '断开', false,
        (): void => { this.actions.onDisconnect(); }, true)
    }
  }

  @Builder
  private primaryActionButtons(vertical: boolean) {
    if (vertical) {
      Column({ space: 5 }) {
        ForEach(vncToolbarPrimaryActionIds(),
          (actionId: VncToolbarPrimaryActionId): void => {
            this.primaryActionButton(actionId)
          }, (actionId: VncToolbarPrimaryActionId): string => actionId)
      }
    } else {
      Row({ space: 5 }) {
        ForEach(vncToolbarPrimaryActionIds(),
          (actionId: VncToolbarPrimaryActionId): void => {
            this.primaryActionButton(actionId)
          }, (actionId: VncToolbarPrimaryActionId): string => actionId)
      }
    }
  }

  private mobileRailHeight(fallback: number): number {
    return this.placement.railRect.height > 0 ? this.placement.railRect.height : fallback;
  }

  private resetRailSwipe(): void {
    animateTo({ duration: 220, curve: curves.responsiveSpringMotion() }, (): void => {
      this.railSwipeX = 0;
    });
  }

  private updateRailSwipe(event: GestureEvent): void {
    if (this.placement.side !== 'right' ||
        Math.abs(event.offsetX) < Math.abs(event.offsetY)) { return; }
    this.railSwipeX = remoteSessionRailDragOffset(event.offsetX);
  }

  private finishRailSwipe(event: GestureEvent): void {
    const collapse: boolean = this.placement.side === 'right' &&
      remoteSessionRailShouldCollapse(event.offsetX, event.velocityX);
    this.resetRailSwipe();
    if (collapse) {
      animateTo({ duration: 180, curve: curves.responsiveSpringMotion() }, (): void => {
        this.actions.onCollapse();
      });
      return;
    }
    this.placementActions.onDrag(event.offsetX, event.offsetY);
  }

  @Builder
  private mobileCollapsedRail() {
    Stack() {
      Row() {
        SymbolGlyph(this.placement.side === 'left' ?
          $r('sys.symbol.chevron_right') : $r('sys.symbol.chevron_left'))
          .fontSize(15).fontColor([REMOTE_SESSION_COLLAPSED_RAIL_ICON])
      }
      .width(REMOTE_SESSION_COLLAPSED_RAIL_WIDTH)
      .height(this.mobileRailHeight(REMOTE_SESSION_COLLAPSED_RAIL_HEIGHT))
      .justifyContent(FlexAlign.Center)
      .backgroundColor(REMOTE_SESSION_COLLAPSED_RAIL_BACKGROUND)
      .backdropBlur(16)
      .border({ width: 0.5, color: REMOTE_SESSION_COLLAPSED_RAIL_BORDER })
      .borderRadius(this.placement.side === 'left' ?
        { topLeft: 0, topRight: 10, bottomLeft: 0, bottomRight: 10 } :
        { topLeft: 10, topRight: 0, bottomLeft: 10, bottomRight: 0 })
      .shadow({ radius: 6, color: 'rgba(0,0,0,0.14)',
        offsetX: this.placement.side === 'left' ? 1 : -1 })
      .position({
        x: this.placement.side === 'left' ? 0 :
          REMOTE_SESSION_COLLAPSED_RAIL_TOUCH_WIDTH -
            REMOTE_SESSION_COLLAPSED_RAIL_WIDTH,
        y: 0
      })
    }
    .width(REMOTE_SESSION_COLLAPSED_RAIL_TOUCH_WIDTH)
    .height(this.mobileRailHeight(REMOTE_SESSION_COLLAPSED_RAIL_HEIGHT))
    .position({ x: this.placement.railRect.x, y: this.placement.railRect.y })
    .gesture(PanGesture({ fingers: 1, distance: 5 })
      .onActionEnd((event: GestureEvent): void => {
        this.placementActions.onDrag(event.offsetX, event.offsetY);
      }))
    .accessibilityText(this.viewOnly ? '展开 VNC 只读会话工具栏' : '展开 VNC 会话工具栏')
    .onClick((): void => { this.actions.onExpand(); })
  }

  @Builder
  private mobileExpandedRail() {
    Column({ space: 5 }) {
      Stack() {
        Row() {
          SymbolGlyph(this.placement.side === 'left' ?
            $r('sys.symbol.chevron_left') : $r('sys.symbol.chevron_right'))
            .fontSize(16).fontColor(['#444444'])
        }
        .width(56).height(30)
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(255,255,255,0.92)')
        .borderRadius(7)
        .position({ x: 0, y: 7 })
      }
      .width('100%').height(44)
      .accessibilityText('收起 VNC 会话工具栏')
      .onClick((): void => { this.actions.onCollapse(); })
      Scroll() {
        Column({ space: 5 }) {
          if (this.viewOnly) {
            Row() {
              SymbolGlyph($r('sys.symbol.eye')).fontSize(13).fontColor(['#FFFFFF'])
              Text('只读').fontSize(10).fontColor('#FFFFFF').margin({ left: 4 })
            }
            .height(24).width('100%').justifyContent(FlexAlign.Center)
          }
          this.primaryActionButtons(true)
        }
      }
      .width('100%').layoutWeight(1)
      .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
    }
    .width(this.placement.railRect.width > 0 ? this.placement.railRect.width : 68)
    .height(this.mobileRailHeight(350))
    .padding(6)
    .borderRadius(this.placement.side === 'left' ?
      { topLeft: 0, bottomLeft: 0, topRight: 10, bottomRight: 10 } :
      { topLeft: 10, bottomLeft: 10, topRight: 0, bottomRight: 0 })
    .backgroundColor('rgba(255,255,255,0.94)')
    .shadow({ radius: 10, color: 'rgba(0,0,0,0.24)',
      offsetX: this.placement.side === 'left' ? 2 : -2 })
    .position({ x: this.placement.railRect.x, y: this.placement.railRect.y })
    .translate({ x: this.railSwipeX })
    .gesture(PanGesture({ fingers: 1, distance: 5 })
      .onActionUpdate((event: GestureEvent): void => { this.updateRailSwipe(event); })
      .onActionEnd((event: GestureEvent): void => {
        this.finishRailSwipe(event);
      })
      .onActionCancel((): void => { this.resetRailSwipe(); }))
  }

  @Builder
  private pcCollapsedToolbar() {
    Row() {
      SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(16).fontColor(['#444444'])
    }
    .width(48).height(28).justifyContent(FlexAlign.Center)
    .borderRadius({ topLeft: 0, topRight: 0, bottomLeft: 8, bottomRight: 8 })
    .backgroundColor(REMOTE_SESSION_COLLAPSED_RAIL_BACKGROUND)
    .backdropBlur(16)
    .border({ width: 0.5, color: REMOTE_SESSION_COLLAPSED_RAIL_BORDER })
    .shadow({ radius: 6, color: 'rgba(0,0,0,0.14)', offsetY: 2 })
    .position({ x: '50%', y: 8 }).markAnchor({ x: '50%', y: 0 })
    .accessibilityText(this.viewOnly ? '展开 VNC 只读会话工具栏' : '展开 VNC 会话工具栏')
    .onClick((): void => { this.actions.onExpand(); })
  }

  @Builder
  private pcExpandedToolbar() {
    Column() {
      if (this.viewOnly) {
        Row() {
          SymbolGlyph($r('sys.symbol.eye')).fontSize(13).fontColor(['#FFFFFF'])
          Text('只读').fontSize(10).fontColor('#FFFFFF').margin({ left: 5 })
        }
        .height(24).padding({ left: 10, right: 10 })
        .borderRadius({ topLeft: 9, topRight: 9, bottomLeft: 0, bottomRight: 0 })
        .backgroundColor('rgba(20,24,32,0.84)')
      }
      Row({ space: 5 }) {
        this.primaryActionButtons(false)
      }
      .padding(6)
      .borderRadius(this.viewOnly ?
        { topLeft: 0, topRight: 0, bottomLeft: 10, bottomRight: 10 } : 10)
      .backgroundColor('rgba(255,255,255,0.94)')
      .shadow({ radius: 8, color: 'rgba(0,0,0,0.24)', offsetY: 2 })
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_up')).fontSize(16).fontColor(['#444444'])
      }
      .width(56).height(28).justifyContent(FlexAlign.Center)
      .borderRadius({ topLeft: 0, topRight: 0, bottomLeft: 8, bottomRight: 8 })
      .backgroundColor(REMOTE_SESSION_COLLAPSED_RAIL_BACKGROUND)
      .backdropBlur(16)
      .border({ width: 0.5, color: REMOTE_SESSION_COLLAPSED_RAIL_BORDER })
      .accessibilityText('收起 VNC 会话工具栏')
      .onClick((): void => { this.actions.onCollapse(); })
    }
    .position({ x: '50%', y: 8 })
    .markAnchor({ x: '50%', y: 0 })
  }

  build() {
    Stack() {
      if (this.deviceClass !== 'pc') {
        if (this.collapsed) {
          this.mobileCollapsedRail()
        } else {
          this.mobileExpandedRail()
        }
      } else if (this.collapsed) {
        this.pcCollapsedToolbar()
      } else {
        this.pcExpandedToolbar()
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
