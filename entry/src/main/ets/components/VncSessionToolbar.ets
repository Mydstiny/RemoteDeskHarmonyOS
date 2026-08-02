export interface VncSessionToolbarActions {
  onExpand: () => void;
  onToggleKeyboard: () => void;
  onCycleControlMode: () => void;
  onOpenShortcuts: () => void;
  onCycleDisplayScale: () => void;
  onToggleDiagnostics: () => void;
  onOpenConsole: () => void;
  onDisconnect: () => void;
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
  actions: VncSessionToolbarActions = {
    onExpand: (): void => {},
    onToggleKeyboard: (): void => {},
    onCycleControlMode: (): void => {},
    onOpenShortcuts: (): void => {},
    onCycleDisplayScale: (): void => {},
    onToggleDiagnostics: (): void => {},
    onOpenConsole: (): void => {},
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
    .width(40).height(42).padding(0).borderRadius(9)
    .backgroundColor(danger ? '#D93B3B' : (active ? '#168C78' : this.accentColor))
    .accessibilityText(label)
    .onClick(action)
  }

  build() {
    if (this.collapsed) {
      Button() {
        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.arrow_up_left')).fontSize(16).fontColor(['#FFFFFF'])
          Text(this.viewOnly ? 'VNC 只读' : 'VNC 控制').fontSize(10).fontColor('#FFFFFF')
        }
      }
      .height(36).padding({ left: 12, right: 12 }).borderRadius(18)
      .backgroundColor(this.viewOnly ? 'rgba(92,96,104,0.90)' : 'rgba(20,24,32,0.86)')
      .shadow({ radius: 8, color: 'rgba(0,0,0,0.24)', offsetY: 2 })
      .position({ x: '50%', y: 8 }).markAnchor({ x: '50%', y: 0 })
      .accessibilityText(this.viewOnly ? '展开 VNC 只读会话工具栏' : '展开 VNC 会话工具栏')
      .onClick((): void => { this.actions.onExpand(); })
    } else {
      Column() {
        if (this.viewOnly) {
          Row() {
            SymbolGlyph($r('sys.symbol.eye')).fontSize(13).fontColor(['#FFFFFF'])
            Text('VNC 只读：输入已禁用').fontSize(10).fontColor('#FFFFFF').margin({ left: 5 })
          }
          .height(24).padding({ left: 10, right: 10 })
          .borderRadius({ topLeft: 9, topRight: 9, bottomLeft: 0, bottomRight: 0 })
          .backgroundColor('rgba(20,24,32,0.84)')
        }
        Row({ space: 5 }) {
          this.actionButton($r('sys.symbol.keyboard'), this.keyboardOpen ? '收键盘' : '键盘',
            this.keyboardOpen, (): void => { this.actions.onToggleKeyboard(); })
          this.actionButton($r('sys.symbol.arrow_up_left'), this.controlModeLabel, false,
            (): void => { this.actions.onCycleControlMode(); })
          this.actionButton($r('sys.symbol.bolt_fill'), '组合键', false,
            (): void => { this.actions.onOpenShortcuts(); })
          this.actionButton($r('sys.symbol.desktop_fill'), this.displayScaleLabel, false,
            (): void => { this.actions.onCycleDisplayScale(); })
          if (this.deviceClass !== 'phone') {
            this.actionButton($r('sys.symbol.list_bullet'), '性能', this.diagnosticsEnabled,
              (): void => { this.actions.onToggleDiagnostics(); })
          }
          if (this.deviceClass === 'pc') {
            this.actionButton($r('sys.symbol.gearshape_fill'), '控制台', false,
              (): void => { this.actions.onOpenConsole(); })
          }
          this.actionButton($r('sys.symbol.xmark'), '断开', false,
            (): void => { this.actions.onDisconnect(); }, true)
        }
        .padding(6)
        .borderRadius(this.viewOnly ?
          { topLeft: 0, topRight: 0, bottomLeft: 10, bottomRight: 10 } : 10)
        .backgroundColor('rgba(20,24,32,0.82)')
        .shadow({ radius: 8, color: 'rgba(0,0,0,0.24)', offsetY: 2 })
      }
      .position({ x: '50%', y: 8 })
      .markAnchor({ x: '50%', y: 0 })
    }
  }
}
