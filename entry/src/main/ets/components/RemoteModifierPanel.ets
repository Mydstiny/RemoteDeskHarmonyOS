/**
 * RemoteModifierPanel.ets — 修饰键面板 (紧凑版) + 快捷键面板
 *
 * 主面板: 修饰键行 + 动作键行 + Fn 层 (约 100vp, 含 Fn 约 300vp)
 * 快捷键面板: 长按胶囊独立弹出, 2 列 Grid + Ctrl+Alt+Del
 *
 * Phase 3 — 瘦身 + 半透明 + 快捷键分离
 * 动画: 180ms Curve.EaseOut, opacity + translateX 从吸附侧抽屉式展开
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'ModifierPanel';
const DOMAIN = 0x0014;

@Component
export struct RemoteModifierPanel {
  @Prop visible: boolean = false;
  @Prop shortcutVisible: boolean = false;
  @Prop attachSide: string = 'right';
  @Prop ctrlLatch: string = 'off';
  @Prop altLatch: string = 'off';
  @Prop shiftLatch: string = 'off';
  @Prop winLatch: string = 'off';
  @Prop fnLayer: boolean = false;
  @Prop panelX: number = 8;
  @Prop panelY: number = 70;
  @Prop shortcutX: number = 8;
  @Prop shortcutY: number = 200;
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';

  onClose: () => void = (): void => {};
  onCloseShortcut: () => void = (): void => {};
  onToggleModifier: (mod: string) => void = (_mod: string): void => {};
  onLockModifier: (mod: string) => void = (_mod: string): void => {};
  onToggleFnLayer: () => void = (): void => {};
  /** 功能键点击回调 (Esc/Tab/Del/Enter/F1-F12 等) */
  onKeyTap: (keyCode: number, label: string) => void = (_kc: number, _lb: string): void => {};
  /** 快捷键点击回调 — keyCodes: [modifier, ..., key] → 全部 down → 逆序 up */
  onShortcutTap: (keyCodes: number[], label: string) => void = (_keys: number[], _label: string): void => {};
  /** 主面板拖动结束, 上报父组件持久状态 */
  onPanelPositionChange: (x: number, y: number) => void = (_x: number, _y: number): void => {};
  /** 快捷键面板拖动结束, 上报父组件持久状态 */
  onShortcutPositionChange: (x: number, y: number) => void = (_x: number, _y: number): void => {};

  @State private panelDragOffsetX: number = 0;
  @State private panelDragOffsetY: number = 0;
  @State private shortcutDragOffsetX: number = 0;
  @State private shortcutDragOffsetY: number = 0;
  @State private pressedKeyId: string = '';
  private suppressModTapName: string = '';
  private suppressModTapUntilMs: number = 0;

  // ============================================================
  // 内部状态辅助
  // ============================================================

  private getModLatch(mod: string): string {
    if (mod === 'ctrl') {
      return this.ctrlLatch;
    }
    if (mod === 'alt') {
      return this.altLatch;
    }
    if (mod === 'shift') {
      return this.shiftLatch;
    }
    if (mod === 'win') {
      return this.winLatch;
    }
    return 'off';
  }

  private isModActive(mod: string): boolean {
    return this.getModLatch(mod) !== 'off';
  }

  private isModLocked(mod: string): boolean {
    return this.getModLatch(mod) === 'locked';
  }

  private modLabel(mod: string): string {
    if (mod === 'ctrl') {
      return 'Ctrl';
    }
    if (mod === 'alt') {
      return 'Alt';
    }
    if (mod === 'shift') {
      return '⇧';
    }
    return 'Win';
  }

  private panelEffectiveX(): number {
    return this.panelX + this.panelDragOffsetX;
  }

  private panelEffectiveY(): number {
    return this.panelY + this.panelDragOffsetY;
  }

  private shortcutEffectiveX(): number {
    return this.shortcutX + this.shortcutDragOffsetX;
  }

  private shortcutEffectiveY(): number {
    return this.shortcutY + this.shortcutDragOffsetY;
  }

  private isPressed(id: string): boolean {
    return this.pressedKeyId === id;
  }

  private updatePressedKey(id: string, event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.pressedKeyId = id;
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (this.pressedKeyId === id) {
        this.pressedKeyId = '';
      }
    }
  }

  private keyBgFor(id: string, base: string): string {
    return this.isPressed(id) ? 'rgba(255,255,255,0.18)' : base;
  }

  private keyBorderFor(id: string, base: string): string {
    return this.isPressed(id) ? 'rgba(255,255,255,0.34)' : base;
  }

  private suppressNextModTap(mod: string): void {
    this.suppressModTapName = mod;
    this.suppressModTapUntilMs = Date.now() + 650;
  }

  private shouldSuppressModTap(mod: string): boolean {
    return this.suppressModTapName === mod && Date.now() < this.suppressModTapUntilMs;
  }

  // ============================================================
  // 样式 (深色半透明 — Phase 3: 提高透明度, 减轻遮挡)
  // ============================================================

  private panelBg(): string {
    return 'rgba(14,18,28,0.55)';
  }

  private panelBorder(): string {
    return 'rgba(255,255,255,0.10)';
  }

  private keyBg(): string {
    return 'rgba(255,255,255,0.05)';
  }

  private keyBorder(): string {
    return 'rgba(255,255,255,0.08)';
  }

  private modOnceBg(): string {
    return this.accentColor + '44';
  }

  private modOnceBorder(): string {
    return this.accentColor;
  }

  private modLockedBg(): string {
    return this.accentColor + '66';
  }

  private modLockedBorder(): string {
    return this.accentColor + 'CC';
  }

  private fnActiveBg(): string {
    return 'rgba(102,221,122,0.24)';
  }

  private fnActiveBorder(): string {
    return 'rgba(102,221,122,0.45)';
  }

  private dangerBg(): string {
    return 'rgba(255,138,128,0.24)';
  }

  private dangerBorder(): string {
    return 'rgba(255,138,128,0.40)';
  }

  private panelWidth(): number {
    if (this.breakpoint === 'xl') {
      return 320;
    }
    if (this.breakpoint === 'lg') {
      return 300;
    }
    if (this.breakpoint === 'md') {
      return 280;
    }
    return 260;
  }

  // ============================================================
  // @Builder 构建器 — 直接读 @Prop 避免参数缓存陷阱
  // ============================================================

  /** 修饰键按钮 (Ctrl/Alt/Shift/Win) — once/locked 双态 */
  @Builder
  ModKey(mod: string) {
    Stack() {
      Text(this.modLabel(mod))
        .fontSize(12)
        .fontColor(this.isModActive(mod) ? '#FFFFFF' : 'rgba(242,244,247,0.82)')
        .fontWeight(this.isModActive(mod) ? FontWeight.Bold : FontWeight.Normal)
        .height(34)
        .width('100%')
        .textAlign(TextAlign.Center)
        .borderRadius(10)
        .backgroundColor(this.keyBgFor('mod-' + mod, this.isModLocked(mod) ? this.modLockedBg() :
          (this.isModActive(mod) ? this.modOnceBg() : this.keyBg())))
        .border({
          width: this.isModActive(mod) ? 2 : 0.5,
          color: this.keyBorderFor('mod-' + mod, this.isModLocked(mod) ? this.modLockedBorder() :
            (this.isModActive(mod) ? this.modOnceBorder() : this.keyBorder()))
        })
        .shadow({
          radius: this.isPressed('mod-' + mod) ? 20 : (this.isModLocked(mod) ? 18 : (this.isModActive(mod) ? 14 : 6)),
          color: this.isPressed('mod-' + mod) ? 'rgba(255,255,255,0.24)' : (this.isModLocked(mod) ? this.accentColor + '66' :
            (this.isModActive(mod) ? this.accentColor + '44' : 'rgba(0,0,0,0.20)')),
          offsetY: 1
        })
      if (this.isModLocked(mod)) {
        Text('锁')
          .fontSize(7)
          .fontColor('rgba(255,255,255,0.8)')
          .fontWeight(FontWeight.Bold)
          .position({ x: '75%', y: 3 })
      }
    }
    .height(34)
    .layoutWeight(1)
    .margin({ left: 3, right: 3 })
    .scale({ x: this.isPressed('mod-' + mod) ? 0.96 : 1, y: this.isPressed('mod-' + mod) ? 0.96 : 1 })
    .animation({ duration: 80, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent): void => {
      this.updatePressedKey('mod-' + mod, event);
    })
    .gesture(
      GestureGroup(GestureMode.Exclusive,
        LongPressGesture({ duration: 500 })
          .onAction((): void => {
            hilog.info(DOMAIN, TAG, 'mod long-press → lock: ' + mod);
            this.suppressNextModTap(mod);
            this.onLockModifier(mod);
          }),
        TapGesture({ count: 1 })
          .onAction((): void => {
            if (this.shouldSuppressModTap(mod)) {
              hilog.info(DOMAIN, TAG, 'mod tap suppressed after long-press: ' + mod);
              return;
            }
            hilog.info(DOMAIN, TAG, 'mod tap: ' + mod);
            this.onToggleModifier(mod);
          })
      )
    )
  }

  /** Fn 层切换按钮 */
  @Builder
  FnKey() {
    Text('Fn')
      .fontSize(11)
      .fontColor(this.fnLayer ? '#DFFFE6' : 'rgba(242,244,247,0.82)')
      .fontWeight(this.fnLayer ? FontWeight.Bold : FontWeight.Normal)
      .height(34)
      .width(38)
      .textAlign(TextAlign.Center)
      .borderRadius(10)
      .backgroundColor(this.keyBgFor('fn', this.fnLayer ? this.fnActiveBg() : this.keyBg()))
      .border({
        width: this.fnLayer ? 2 : 0.5,
        color: this.keyBorderFor('fn', this.fnLayer ? this.fnActiveBorder() : this.keyBorder())
      })
      .margin({ left: 3, right: 3 })
      .scale({ x: this.isPressed('fn') ? 0.96 : 1, y: this.isPressed('fn') ? 0.96 : 1 })
      .animation({ duration: 80, curve: Curve.EaseOut })
      .onTouch((event: TouchEvent): void => {
        this.updatePressedKey('fn', event);
      })
      .gesture(TapGesture({ count: 1 })
        .onAction((): void => {
          hilog.info(DOMAIN, TAG, 'fn toggle');
          this.onToggleFnLayer();
        }))
  }

  /** 普通动作键 (Esc/Tab/Del/Enter/F1-F12 等) — keyCode=0 时置灰禁用 */
  @Builder
  ActionKey(label: string, keyCode: number) {
    Text(label)
      .fontSize(12)
      .fontColor(keyCode > 0 ? 'rgba(242,244,247,0.82)' : 'rgba(255,255,255,0.18)')
      .height(34).layoutWeight(1)
      .textAlign(TextAlign.Center)
      .borderRadius(10)
      .backgroundColor(keyCode > 0 ? this.keyBgFor('key-' + label, this.keyBg()) : 'rgba(255,255,255,0.02)')
      .border({ width: 0.5, color: keyCode > 0 ? this.keyBorderFor('key-' + label, this.keyBorder()) : 'rgba(255,255,255,0.04)' })
      .margin({ left: 3, right: 3 })
      .scale({ x: this.isPressed('key-' + label) ? 0.96 : 1, y: this.isPressed('key-' + label) ? 0.96 : 1 })
      .animation({ duration: 80, curve: Curve.EaseOut })
      .enabled(keyCode > 0)
      .onTouch((event: TouchEvent): void => {
        if (keyCode > 0) {
          this.updatePressedKey('key-' + label, event);
        }
      })
      .gesture(TapGesture({ count: 1 })
        .onAction((): void => {
          if (keyCode > 0) {
            hilog.info(DOMAIN, TAG, 'action key tap: ' + label);
            this.onKeyTap(keyCode, label);
          }
        }))
  }

  /** Enter 键 (强调色) */
  @Builder
  EnterKey() {
    Text('Enter')
      .fontSize(12)
      .fontColor('#FFFFFF')
      .fontWeight(FontWeight.Medium)
      .height(34).layoutWeight(1)
      .textAlign(TextAlign.Center)
      .borderRadius(10)
      .backgroundColor(this.keyBgFor('key-Enter', this.accentColor + '99'))
      .border({ width: 1, color: this.keyBorderFor('key-Enter', this.accentColor) })
      .margin({ left: 3, right: 3 })
      .scale({ x: this.isPressed('key-Enter') ? 0.96 : 1, y: this.isPressed('key-Enter') ? 0.96 : 1 })
      .animation({ duration: 80, curve: Curve.EaseOut })
      .onTouch((event: TouchEvent): void => {
        this.updatePressedKey('key-Enter', event);
      })
      .gesture(TapGesture({ count: 1 })
        .onAction((): void => {
          this.onKeyTap(2054, 'Enter');
        }))
  }

  /** 快捷键按钮 (ShortcutSheet 用) — keyCodes 用于 onShortcutTap 回调 */
  @Builder
  ShortcutBtn(label: string, keyCodes: number[]) {
    Text(label)
      .fontSize(11)
      .fontColor('rgba(255,255,255,0.84)')
      .fontWeight(FontWeight.Medium)
      .height(34)
      .width('100%')
      .textAlign(TextAlign.Center)
      .borderRadius(10)
      .backgroundColor(this.keyBgFor('shortcut-' + label, 'rgba(255,255,255,0.06)'))
      .border({ width: 0.5, color: this.keyBorderFor('shortcut-' + label, 'rgba(255,255,255,0.10)') })
      .scale({ x: this.isPressed('shortcut-' + label) ? 0.96 : 1, y: this.isPressed('shortcut-' + label) ? 0.96 : 1 })
      .animation({ duration: 80, curve: Curve.EaseOut })
      .onTouch((event: TouchEvent): void => {
        this.updatePressedKey('shortcut-' + label, event);
      })
      .gesture(TapGesture({ count: 1 })
        .onAction((): void => {
          hilog.info(DOMAIN, TAG, 'shortcut tap: ' + label);
          this.onShortcutTap(keyCodes.slice(0), label);
        }))
  }

  /** Ctrl+Alt+Del 危险动作按钮 */
  @Builder
  DangerShortcut() {
    Text('Ctrl + Alt + Del')
      .fontSize(11)
      .fontColor('#FFFFFF')
      .fontWeight(FontWeight.Bold)
      .height(34)
      .width('100%')
      .textAlign(TextAlign.Center)
      .borderRadius(10)
      .backgroundColor(this.keyBgFor('shortcut-CtrlAltDel', this.dangerBg()))
      .border({ width: 1, color: this.keyBorderFor('shortcut-CtrlAltDel', this.dangerBorder()) })
      .scale({ x: this.isPressed('shortcut-CtrlAltDel') ? 0.96 : 1, y: this.isPressed('shortcut-CtrlAltDel') ? 0.96 : 1 })
      .animation({ duration: 80, curve: Curve.EaseOut })
      .onTouch((event: TouchEvent): void => {
        this.updatePressedKey('shortcut-CtrlAltDel', event);
      })
      .gesture(TapGesture({ count: 1 })
        .onAction((): void => {
          hilog.info(DOMAIN, TAG, 'danger shortcut: Ctrl+Alt+Del');
          // Ctrl+Alt+Del = 2072, 2045, 2071
          this.onShortcutTap([2072, 2045, 2071], 'Ctrl+Alt+Del');
        }))
  }

  @Builder
  PanelDragArea(label: string, shortcut: boolean) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor('#E6E6E6')
        .fontWeight(FontWeight.Medium)
      Blank()
      Text('⋮⋮')
        .fontSize(12)
        .fontColor('rgba(255,255,255,0.32)')
    }
    .height(30)
    .layoutWeight(1)
    .padding({ left: 6, right: 8 })
    .gesture(
      PanGesture({ fingers: 1, distance: 2 })
        .onActionStart((_event: GestureEvent): void => {
          if (shortcut) {
            this.shortcutDragOffsetX = 0;
            this.shortcutDragOffsetY = 0;
          } else {
            this.panelDragOffsetX = 0;
            this.panelDragOffsetY = 0;
          }
        })
        .onActionUpdate((event: GestureEvent): void => {
          if (shortcut) {
            this.shortcutDragOffsetX = event.offsetX;
            this.shortcutDragOffsetY = event.offsetY;
          } else {
            this.panelDragOffsetX = event.offsetX;
            this.panelDragOffsetY = event.offsetY;
          }
        })
        .onActionEnd((_event: GestureEvent): void => {
          if (shortcut) {
            const x: number = this.shortcutEffectiveX();
            const y: number = this.shortcutEffectiveY();
            this.onShortcutPositionChange(x, y);
            this.shortcutDragOffsetX = 0;
            this.shortcutDragOffsetY = 0;
          } else {
            const x: number = this.panelEffectiveX();
            const y: number = this.panelEffectiveY();
            this.onPanelPositionChange(x, y);
            this.panelDragOffsetX = 0;
            this.panelDragOffsetY = 0;
          }
        })
    )
  }

  // ============================================================
  // Fn 层键码 (HarmonyOS keyCode)
  // ============================================================
  private static readonly KEY_F1 = 2090;
  private static readonly KEY_F2 = 2091;
  private static readonly KEY_F3 = 2092;
  private static readonly KEY_F4 = 2093;
  private static readonly KEY_F5 = 2094;
  private static readonly KEY_F6 = 2095;
  private static readonly KEY_F7 = 2096;
  private static readonly KEY_F8 = 2097;
  private static readonly KEY_F9 = 2098;
  private static readonly KEY_F10 = 2099;
  private static readonly KEY_F11 = 2100;
  private static readonly KEY_F12 = 2101;
  private static readonly KEY_HOME = 2081;
  private static readonly KEY_END = 2082;
  private static readonly KEY_PAGE_UP = 2068;
  private static readonly KEY_PAGE_DOWN = 2069;
  private static readonly KEY_ESC = 2070;
  private static readonly KEY_TAB = 2049;
  private static readonly KEY_DEL = 2055;
  private static readonly KEY_ENTER = 2054;
  private static readonly KEY_MENU = 2067;
  private static readonly KEY_SYSRQ = 2079;
  private static readonly KEY_BREAK = 2080;
  private static readonly KEY_INSERT = 2083;

  // ============================================================
  // 构建 — 主面板 (紧凑)
  // ============================================================

  build() {
    Column() {
    // 主面板
    if (this.visible) {
      Column() {
        // 标题栏
        Row() {
          this.PanelDragArea('修饰键', false)
          Text('✕')
            .fontSize(13)
            .fontColor('rgba(255,255,255,0.4)')
            .padding({ left: 10, right: 2, top: 2, bottom: 2 })
            .gesture(TapGesture({ count: 1 })
              .onAction((): void => {
                this.onClose();
              }))
        }
        .width('100%')
        .padding({ right: 6, top: 2, bottom: 8 })

        // 修饰键行: Ctrl Alt Shift Win Fn
        Row() {
          this.ModKey('ctrl')
          this.ModKey('alt')
          this.ModKey('shift')
          this.ModKey('win')
          this.FnKey()
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceEvenly)

        // 间隔
        Row().height(6)

        // 动作键行: Esc Tab Del Enter
        Row() {
          this.ActionKey('Esc', RemoteModifierPanel.KEY_ESC)
          this.ActionKey('Tab', RemoteModifierPanel.KEY_TAB)
          this.ActionKey('Del', RemoteModifierPanel.KEY_DEL)
          this.EnterKey()
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceEvenly)

        // Fn 层
        if (this.fnLayer) {
          Row().height(8)

          // F1-F4
          Row() {
            this.ActionKey('F1', RemoteModifierPanel.KEY_F1)
            this.ActionKey('F2', RemoteModifierPanel.KEY_F2)
            this.ActionKey('F3', RemoteModifierPanel.KEY_F3)
            this.ActionKey('F4', RemoteModifierPanel.KEY_F4)
          }
          .width('100%')

          Row().height(5)

          // F5-F8
          Row() {
            this.ActionKey('F5', RemoteModifierPanel.KEY_F5)
            this.ActionKey('F6', RemoteModifierPanel.KEY_F6)
            this.ActionKey('F7', RemoteModifierPanel.KEY_F7)
            this.ActionKey('F8', RemoteModifierPanel.KEY_F8)
          }
          .width('100%')

          Row().height(5)

          // F9-F12
          Row() {
            this.ActionKey('F9', RemoteModifierPanel.KEY_F9)
            this.ActionKey('F10', RemoteModifierPanel.KEY_F10)
            this.ActionKey('F11', RemoteModifierPanel.KEY_F11)
            this.ActionKey('F12', RemoteModifierPanel.KEY_F12)
          }
          .width('100%')

          Row().height(5)

          // Home End PgUp PgDn
          Row() {
            this.ActionKey('Home', RemoteModifierPanel.KEY_HOME)
            this.ActionKey('End', RemoteModifierPanel.KEY_END)
            this.ActionKey('PgUp', RemoteModifierPanel.KEY_PAGE_UP)
            this.ActionKey('PgDn', RemoteModifierPanel.KEY_PAGE_DOWN)
          }
          .width('100%')

          Row().height(5)

          // Ins PrtSc Pause Menu
          Row() {
            this.ActionKey('Ins', RemoteModifierPanel.KEY_INSERT)
            this.ActionKey('PrtSc', RemoteModifierPanel.KEY_SYSRQ)
            this.ActionKey('Pause', RemoteModifierPanel.KEY_BREAK)
            this.ActionKey('Menu', RemoteModifierPanel.KEY_MENU)
          }
          .width('100%')
        }
      }
      .width(this.panelWidth())
      .padding(10)
      .borderRadius(14)
      .backgroundColor(this.panelBg())
      .border({ width: 1, color: this.panelBorder() })
      .backdropBlur(16)
      .shadow({ radius: 18, color: 'rgba(0,0,0,0.35)', offsetY: 6 })
      .transition(
        TransitionEffect.OPACITY
          .combine(TransitionEffect.translate({
            x: this.attachSide === 'right' ? 50 : -50,
            y: 0
          }))
          .animation({ duration: 180, curve: Curve.EaseOut })
      )
      .position({ x: this.panelEffectiveX(), y: this.panelEffectiveY() })
      .hitTestBehavior(HitTestMode.Default)
    }

    // 快捷键面板 (长按胶囊弹出, 独立于主面板)
    if (this.shortcutVisible) {
      Column() {
        // 标题栏
        Row() {
          this.PanelDragArea('快捷键', true)
          Text('✕')
            .fontSize(13)
            .fontColor('rgba(255,255,255,0.4)')
            .padding({ left: 10, right: 2, top: 2, bottom: 2 })
            .gesture(TapGesture({ count: 1 })
              .onAction((): void => {
                this.onCloseShortcut();
              }))
        }
        .width('100%')
        .padding({ right: 6, top: 2, bottom: 8 })

        // 快捷键 2 列网格
        Grid() {
          GridItem() { this.ShortcutBtn('Ctrl + C', [2072, 2019]) }
          GridItem() { this.ShortcutBtn('Ctrl + V', [2072, 2038]) }
          GridItem() { this.ShortcutBtn('Alt + Tab', [2045, 2049]) }
          GridItem() { this.ShortcutBtn('Alt + F4', [2045, 2093]) }
          GridItem() { this.ShortcutBtn('Win + R', [2076, 2034]) }
          GridItem() { this.ShortcutBtn('Win + D', [2076, 2020]) }
          GridItem() { this.ShortcutBtn('Ctrl + Shift + Esc', [2072, 2047, 2070]) }
          GridItem() { this.ShortcutBtn('Win + E', [2076, 2021]) }
        }
        .columnsTemplate('1fr 1fr')
        .rowsGap(6)
        .columnsGap(6)
        .width('100%')

        Row().height(8)

        // 危险动作
        this.DangerShortcut()
      }
      .width(this.panelWidth())
      .padding(10)
      .borderRadius(14)
      .backgroundColor(this.panelBg())
      .border({ width: 1, color: this.panelBorder() })
      .backdropBlur(16)
      .shadow({ radius: 18, color: 'rgba(0,0,0,0.35)', offsetY: 6 })
      .transition(
        TransitionEffect.OPACITY
          .combine(TransitionEffect.translate({
            x: this.attachSide === 'right' ? 40 : -40,
            y: 0
          }))
          .animation({ duration: 180, curve: Curve.EaseOut })
      )
      .position({ x: this.shortcutEffectiveX(), y: this.shortcutEffectiveY() })
      .hitTestBehavior(HitTestMode.Default)
    }
    }
    .width('100%').height('100%')
    .hitTestBehavior(HitTestMode.None)
  }
}
