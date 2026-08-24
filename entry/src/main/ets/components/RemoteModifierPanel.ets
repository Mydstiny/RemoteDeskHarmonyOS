/**
 * RemoteModifierPanel.ets — 统一组合键、修饰键与功能键面板
 *
 * 面板只能由会话贴边栏/工具栏唤起。仅面板实体区域拦截命中，面板外
 * 的远端画布保持可操作；标题栏承担拖动手柄，位置由会话页约束并持久化。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  RemoteCustomShortcut,
  RemoteCustomShortcutKeyGroup,
  RemoteCustomShortcutKeyOption,
  remoteCustomShortcutKeyGroupForKeyCode,
  remoteCustomShortcutKeyOptions,
  remoteCustomShortcutLabel,
  remoteCustomShortcutLabelForPlatform
} from '../services/RemoteCustomShortcutPolicy';
import {
  normalizeRemoteShortcutPlatform,
  RemoteShortcutCategory,
  RemoteShortcutPlatform,
  RemoteShortcutPreset,
  remoteShortcutCategories,
  remoteShortcutCategoryLabel,
  remoteShortcutPresets,
  REMOTE_KEYBOARD_CLOSE_AFTER_SHORTCUT_KEY,
  REMOTE_KEYBOARD_FUNCTION_KEYS_VISIBLE_KEY,
  REMOTE_KEYBOARD_SHORTCUT_PLATFORM_KEY
} from '../services/RemoteKeyboardSettingsPolicy';
import { RemoteKeyboardSettingsService } from '../services/RemoteKeyboardSettingsService';

const TAG = 'ModifierPanel';
const DOMAIN = 0x0014;
const DRAG_COMMIT_THRESHOLD = 3;

@Component
export struct RemoteModifierPanel {
  @Prop visible: boolean = false;
  /** VNC can mount the panel invisibly for one layout pass before revealing it. */
  @Prop prepareOnly: boolean = false;
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
  /** Parent-derived safe height after toolbars, avoid areas and IME. */
  @Prop maxPanelHeight: number = 480;
  @Prop customizationEnabled: boolean = false;
  @Prop customShortcuts: Array<RemoteCustomShortcut> = [];
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @StorageLink(REMOTE_KEYBOARD_SHORTCUT_PLATFORM_KEY) shortcutPlatformMode: string = 'windows';
  @StorageLink(REMOTE_KEYBOARD_FUNCTION_KEYS_VISIBLE_KEY) functionKeysVisible: boolean = true;
  @StorageLink(REMOTE_KEYBOARD_CLOSE_AFTER_SHORTCUT_KEY) closeAfterShortcut: boolean = false;

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
  /** 上报主面板真实布局尺寸，避免父组件按 Fn 状态猜测高度。 */
  onPanelSizeChange: (width: number, height: number) => void =
    (_width: number, _height: number): void => {};
  /** 上报快捷键面板真实布局尺寸。 */
  onShortcutSizeChange: (width: number, height: number) => void =
    (_width: number, _height: number): void => {};
  onSaveCustomShortcut: (id: string, keyCodes: Array<number>) => boolean =
    (_id: string, _keyCodes: Array<number>): boolean => false;
  onDeleteCustomShortcut: (id: string) => void = (_id: string): void => {};

  @State private panelDragOffsetX: number = 0;
  @State private panelDragOffsetY: number = 0;
  @State private shortcutDragOffsetX: number = 0;
  @State private shortcutDragOffsetY: number = 0;
  @State private panelDragMoved: boolean = false;
  @State private shortcutDragMoved: boolean = false;
  @State private pressedKeyId: string = '';
  @State private customEditorVisible: boolean = false;
  @State private customEditingId: string = '';
  @State private customModifierCodes: Array<number> = [];
  @State private customKeyGroup: RemoteCustomShortcutKeyGroup = 'letters';
  @State private customActionKeyCode: number = 2017;
  @State private panelSection: string = 'shortcuts';
  @State private shortcutCategory: RemoteShortcutCategory = 'editing';
  @State private viewportHeight: number = 640;
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
      return this.shortcutPlatform() === 'macos' ? 'Control' : 'Ctrl';
    }
    if (mod === 'alt') {
      return this.shortcutPlatform() === 'macos' ? 'Option' : 'Alt';
    }
    if (mod === 'shift') {
      return '⇧';
    }
    return this.shortcutPlatform() === 'macos' ? 'Cmd' : 'Win';
  }

  private shortcutPlatform(): RemoteShortcutPlatform {
    return normalizeRemoteShortcutPlatform(this.shortcutPlatformMode);
  }

  private shortcutPlatformLabel(): string {
    return this.shortcutPlatform() === 'macos' ? 'macOS' : 'Windows';
  }

  private selectShortcutPlatform(platform: RemoteShortcutPlatform): void {
    this.shortcutPlatformMode = platform;
    // 首先回到通用编辑键，避免 macOS 桌面分类中合法的
    // Control 组合被误解为平台没有切换。
    this.shortcutCategory = 'editing';
    RemoteKeyboardSettingsService.getInstance().saveShortcutPlatform(platform, getContext(this));
  }

  private visibleShortcutPresets(): Array<RemoteShortcutPreset> {
    return remoteShortcutPresets(this.shortcutPlatform(), this.shortcutCategory);
  }

  private closeUnifiedPanel(): void {
    this.closeCustomShortcutEditor();
    if (this.visible || this.prepareOnly) { this.onClose(); }
    if (this.shortcutVisible) { this.onCloseShortcut(); }
  }

  private finishShortcutAction(): void {
    if (this.closeAfterShortcut) { this.closeUnifiedPanel(); }
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

  private updateDragMoved(shortcut: boolean, offsetX: number, offsetY: number): void {
    if (Math.sqrt(offsetX * offsetX + offsetY * offsetY) < DRAG_COMMIT_THRESHOLD) {
      return;
    }
    if (shortcut) {
      this.shortcutDragMoved = true;
    } else {
      this.panelDragMoved = true;
    }
  }

  private finishPanelDrag(shortcut: boolean): void {
    if (shortcut) {
      const x: number = this.shortcutEffectiveX();
      const y: number = this.shortcutEffectiveY();
      const moved: boolean = this.shortcutDragMoved;
      this.shortcutDragMoved = false;
      this.shortcutDragOffsetX = 0;
      this.shortcutDragOffsetY = 0;
      if (moved) {
        this.onShortcutPositionChange(x, y);
      }
      return;
    }
    const x: number = this.panelEffectiveX();
    const y: number = this.panelEffectiveY();
    const moved: boolean = this.panelDragMoved;
    this.panelDragMoved = false;
    this.panelDragOffsetX = 0;
    this.panelDragOffsetY = 0;
    if (moved) {
      this.onPanelPositionChange(x, y);
    }
  }

  private cancelPanelDrag(shortcut: boolean): void {
    if (shortcut) {
      this.shortcutDragMoved = false;
      this.shortcutDragOffsetX = 0;
      this.shortcutDragOffsetY = 0;
      return;
    }
    this.panelDragMoved = false;
    this.panelDragOffsetX = 0;
    this.panelDragOffsetY = 0;
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

  private customModifierActive(keyCode: number): boolean {
    return this.customModifierCodes.indexOf(keyCode) >= 0;
  }

  private toggleCustomModifier(keyCode: number): void {
    const next: Array<number> = this.customModifierCodes.slice(0);
    const index: number = next.indexOf(keyCode);
    if (index >= 0) {
      next.splice(index, 1);
    } else {
      next.push(keyCode);
    }
    this.customModifierCodes = next;
  }

  private customDraftKeyCodes(): Array<number> {
    const result: Array<number> = this.customModifierCodes.slice(0);
    result.push(this.customActionKeyCode);
    return result;
  }

  private beginCustomShortcutEditor(shortcut: RemoteCustomShortcut | null = null): void {
    this.customEditorVisible = true;
    this.customEditingId = shortcut === null ? '' : shortcut.id;
    this.customModifierCodes = shortcut === null ? [] :
      shortcut.keyCodes.slice(0, Math.max(0, shortcut.keyCodes.length - 1));
    this.customActionKeyCode = shortcut === null || shortcut.keyCodes.length === 0 ?
      2017 : shortcut.keyCodes[shortcut.keyCodes.length - 1];
    this.customKeyGroup = remoteCustomShortcutKeyGroupForKeyCode(this.customActionKeyCode);
  }

  private closeCustomShortcutEditor(): void {
    this.customEditorVisible = false;
    this.customEditingId = '';
    this.customModifierCodes = [];
    this.customKeyGroup = 'letters';
    this.customActionKeyCode = 2017;
  }

  private saveCustomShortcutEditor(): void {
    const keyCodes: Array<number> = this.customDraftKeyCodes();
    if (remoteCustomShortcutLabel(keyCodes).length === 0) { return; }
    if (this.onSaveCustomShortcut(this.customEditingId, keyCodes)) {
      this.closeCustomShortcutEditor();
    }
  }

  private customKeyOptions(): Array<RemoteCustomShortcutKeyOption> {
    return remoteCustomShortcutKeyOptions(this.customKeyGroup, this.shortcutPlatform());
  }

  private customGroupLabel(group: RemoteCustomShortcutKeyGroup): string {
    if (group === 'letters') { return '字母'; }
    if (group === 'digits') { return '数字'; }
    if (group === 'symbols') { return '符号'; }
    if (group === 'functions') { return 'F 键'; }
    return '导航';
  }

  // ============================================================
  // 样式：深色半透明材质，保持远端画面可辨识。
  // ============================================================

  private panelBg(): string {
    return 'rgba(12,17,26,0.76)';
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

  private panelHeight(): number {
    const availableHeight: number = Number.isFinite(this.maxPanelHeight) ?
      Math.max(1, this.maxPanelHeight) : 480;
    return Math.max(1, Math.min(480, this.viewportHeight - 16, availableHeight));
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
          this.finishShortcutAction();
        }))
  }

  @Builder
  PresetShortcutBtn(item: RemoteShortcutPreset) {
    Button() {
      Column({ space: 2 }) {
        Text(item.label)
          .fontSize(11).fontWeight(FontWeight.Medium)
          .fontColor(item.dangerous ? '#FFD4D0' : 'rgba(255,255,255,0.90)')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.chord)
          .fontSize(9)
          .fontColor(item.dangerous ? 'rgba(255,180,172,0.82)' : 'rgba(255,255,255,0.54)')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%').justifyContent(FlexAlign.Center)
    }
    .height(46).width('100%').padding({ left: 4, right: 4 })
    .borderRadius(10)
    .backgroundColor(item.dangerous ? this.dangerBg() : this.keyBg())
    .border({ width: item.dangerous ? 1 : 0.5,
      color: item.dangerous ? this.dangerBorder() : this.keyBorder() })
    .accessibilityText(item.label + '，' + item.chord)
    .onClick((): void => {
      this.onShortcutTap(item.keyCodes.slice(0), item.chord);
      this.finishShortcutAction();
    })
  }

  @Builder
  PlatformChoice(platform: RemoteShortcutPlatform, label: string) {
    Button(label)
      .height(34).layoutWeight(1).fontSize(11)
      .fontColor(this.shortcutPlatform() === platform ? '#FFFFFF' : 'rgba(255,255,255,0.62)')
      .backgroundColor(this.shortcutPlatform() === platform ?
        this.accentColor : 'rgba(255,255,255,0.04)')
      .borderRadius(9)
      .onClick((): void => { this.selectShortcutPlatform(platform); })
      .accessibilityText('切换到 ' + label + ' 快捷键')
  }

  @Builder
  SectionChoice(section: string, label: string) {
    Text(label)
      .height(32).layoutWeight(1).fontSize(10).textAlign(TextAlign.Center)
      .fontColor(this.panelSection === section ? '#FFFFFF' : 'rgba(255,255,255,0.56)')
      .fontWeight(this.panelSection === section ? FontWeight.Bold : FontWeight.Normal)
      .borderRadius(9)
      .backgroundColor(this.panelSection === section ?
        this.accentColor + '88' : 'rgba(255,255,255,0.03)')
      .onClick((): void => {
        if (section !== 'functions' || this.functionKeysVisible) {
          this.panelSection = section;
          if (section !== 'custom') { this.closeCustomShortcutEditor(); }
        }
      })
      .opacity(section === 'functions' && !this.functionKeysVisible ? 0.38 : 1)
      .accessibilityText(section === 'functions' && !this.functionKeysVisible ?
        '功能键页已在设置中隐藏' : label)
  }

  @Builder
  ShortcutCategoryChoice(category: RemoteShortcutCategory) {
    Text(remoteShortcutCategoryLabel(category))
      .fontSize(9).fontColor(this.shortcutCategory === category ? '#FFFFFF' : 'rgba(255,255,255,0.50)')
      .height(28).padding({ left: 10, right: 10 }).textAlign(TextAlign.Center)
      .borderRadius(8)
      .backgroundColor(this.shortcutCategory === category ?
        this.accentColor + '66' : 'rgba(255,255,255,0.03)')
      .onClick((): void => { this.shortcutCategory = category; })
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
          this.finishShortcutAction();
        }))
  }

  @Builder
  CustomModifierChoice(label: string, keyCode: number) {
    Text(label)
      .fontSize(11)
      .fontColor(this.customModifierActive(keyCode) ? '#FFFFFF' : 'rgba(255,255,255,0.68)')
      .fontWeight(this.customModifierActive(keyCode) ? FontWeight.Bold : FontWeight.Normal)
      .height(32).layoutWeight(1)
      .textAlign(TextAlign.Center)
      .borderRadius(9)
      .backgroundColor(this.customModifierActive(keyCode) ? this.accentColor + '88' : this.keyBg())
      .border({ width: 1, color: this.customModifierActive(keyCode) ?
        this.accentColor : this.keyBorder() })
      .margin({ left: 2, right: 2 })
      .onClick((): void => { this.toggleCustomModifier(keyCode); })
  }

  @Builder
  CustomGroupChoice(group: RemoteCustomShortcutKeyGroup) {
    Text(this.customGroupLabel(group))
      .fontSize(10)
      .fontColor(this.customKeyGroup === group ? '#FFFFFF' : 'rgba(255,255,255,0.55)')
      .height(28).layoutWeight(1)
      .textAlign(TextAlign.Center)
      .borderRadius(8)
      .backgroundColor(this.customKeyGroup === group ? this.accentColor + '66' : 'rgba(255,255,255,0.03)')
      .margin({ left: 2, right: 2 })
      .onClick((): void => {
        this.customKeyGroup = group;
        const options: Array<RemoteCustomShortcutKeyOption> =
          remoteCustomShortcutKeyOptions(group, this.shortcutPlatform());
        if (options.length > 0) { this.customActionKeyCode = options[0].keyCode; }
      })
  }

  @Builder
  CustomActionChoice(option: RemoteCustomShortcutKeyOption) {
    Text(option.label)
      .fontSize(10)
      .fontColor(this.customActionKeyCode === option.keyCode ? '#FFFFFF' : 'rgba(255,255,255,0.72)')
      .height(28).width('100%')
      .textAlign(TextAlign.Center)
      .borderRadius(8)
      .backgroundColor(this.customActionKeyCode === option.keyCode ?
        this.accentColor + '88' : this.keyBg())
      .border({ width: 0.5, color: this.customActionKeyCode === option.keyCode ?
        this.accentColor : this.keyBorder() })
      .onClick((): void => { this.customActionKeyCode = option.keyCode; })
  }

  @Builder
  CustomShortcutStrip() {
    Column() {
      Row() {
        Text('自定义组合键')
          .fontSize(10).fontColor('rgba(255,255,255,0.58)')
        Blank()
        Text('＋ 新建')
          .fontSize(10).fontColor(this.accentColor)
          .padding({ left: 8, right: 4, top: 4, bottom: 4 })
          .onClick((): void => { this.beginCustomShortcutEditor(); })
      }.width('100%').margin({ top: 8, bottom: 4 })
      if (this.customShortcuts.length === 0) {
        Text('可保存最多 32 个组合键，所有图形远程协议共用')
          .fontSize(9).fontColor('rgba(255,255,255,0.35)')
          .height(34).width('100%').textAlign(TextAlign.Center)
          .backgroundColor('rgba(255,255,255,0.025)').borderRadius(8)
      } else {
        Scroll() {
          Row({ space: 6 }) {
            ForEach(this.customShortcuts, (shortcut: RemoteCustomShortcut): void => {
              Row() {
                Text(remoteCustomShortcutLabelForPlatform(
                  shortcut.keyCodes, this.shortcutPlatform()))
                  .fontSize(10).fontColor('rgba(255,255,255,0.86)')
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                  .onClick((): void => {
                    this.onShortcutTap(shortcut.keyCodes.slice(0), shortcut.label);
                    this.finishShortcutAction();
                  })
                Text('✎')
                  .fontSize(10).fontColor(this.accentColor)
                  .padding({ left: 6, right: 5, top: 7, bottom: 7 })
                  .onClick((): void => { this.beginCustomShortcutEditor(shortcut); })
                Text('×')
                  .fontSize(12).fontColor('rgba(255,138,128,0.86)')
                  .padding({ left: 4, right: 6, top: 6, bottom: 6 })
                  .onClick((): void => { this.onDeleteCustomShortcut(shortcut.id); })
              }
              .width(150).height(36)
              .padding({ left: 8 })
              .borderRadius(9)
              .backgroundColor('rgba(255,255,255,0.05)')
              .border({ width: 0.5, color: this.keyBorder() })
            }, (shortcut: RemoteCustomShortcut): string => shortcut.id)
          }
        }
        .width('100%').height(40)
        .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
      }
    }.width('100%')
  }

  @Builder
  CustomShortcutEditor() {
    Column() {
      Row() {
        Text(this.customEditingId.length > 0 ? '编辑组合键' : '新建组合键')
          .fontSize(11).fontWeight(FontWeight.Medium).fontColor('#FFFFFF')
        Blank()
        Text('取消').fontSize(10).fontColor('rgba(255,255,255,0.55)')
          .padding({ left: 8, right: 4, top: 4, bottom: 4 })
          .onClick((): void => { this.closeCustomShortcutEditor(); })
      }.width('100%').margin({ bottom: 7 })
      Text('1. 选择一个或多个修饰键')
        .fontSize(9).fontColor('rgba(255,255,255,0.42)').width('100%')
      Row() {
        if (this.shortcutPlatform() === 'macos') {
          this.CustomModifierChoice('Cmd', 2076)
          this.CustomModifierChoice('Option', 2045)
          this.CustomModifierChoice('Shift', 2047)
          this.CustomModifierChoice('Control', 2072)
        } else {
          this.CustomModifierChoice('Ctrl', 2072)
          this.CustomModifierChoice('Alt', 2045)
          this.CustomModifierChoice('Shift', 2047)
          this.CustomModifierChoice('Win', 2076)
        }
      }.width('100%').margin({ top: 4, bottom: 7 })
      Text('2. 选择一个主键')
        .fontSize(9).fontColor('rgba(255,255,255,0.42)').width('100%')
      Row() {
        this.CustomGroupChoice('letters')
        this.CustomGroupChoice('digits')
        this.CustomGroupChoice('symbols')
        this.CustomGroupChoice('functions')
        this.CustomGroupChoice('navigation')
      }.width('100%').margin({ top: 4, bottom: 5 })
      Grid() {
        ForEach(this.customKeyOptions(), (option: RemoteCustomShortcutKeyOption): void => {
          GridItem() { this.CustomActionChoice(option) }
        }, (option: RemoteCustomShortcutKeyOption): string => option.keyCode.toString())
      }
      .columnsTemplate('1fr 1fr 1fr 1fr 1fr')
      .rowsGap(4).columnsGap(4).width('100%').height(108)
      Row() {
        Text(remoteCustomShortcutLabelForPlatform(
          this.customDraftKeyCodes(), this.shortcutPlatform()) || '请至少选择一个修饰键')
          .fontSize(10)
          .fontColor(remoteCustomShortcutLabel(this.customDraftKeyCodes()).length > 0 ?
            '#FFFFFF' : 'rgba(255,138,128,0.72)')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('保存')
          .fontSize(11).fontWeight(FontWeight.Bold)
          .fontColor(remoteCustomShortcutLabel(this.customDraftKeyCodes()).length > 0 ?
            '#FFFFFF' : 'rgba(255,255,255,0.28)')
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .borderRadius(9)
          .backgroundColor(remoteCustomShortcutLabel(this.customDraftKeyCodes()).length > 0 ?
            this.accentColor : 'rgba(255,255,255,0.05)')
          .enabled(remoteCustomShortcutLabel(this.customDraftKeyCodes()).length > 0)
          .onClick((): void => { this.saveCustomShortcutEditor(); })
      }.width('100%').margin({ top: 7 })
    }.width('100%')
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
    .height(44)
    .layoutWeight(1)
    .padding({ left: 6, right: 8 })
    .accessibilityText(label + '，按住并拖动可移动面板')
    .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
    .priorityGesture(
      PanGesture({ direction: PanDirection.All, fingers: 1, distance: 3 })
        .onActionStart((_event: GestureEvent): void => {
          if (shortcut) {
            this.shortcutDragMoved = false;
            this.shortcutDragOffsetX = 0;
            this.shortcutDragOffsetY = 0;
          } else {
            this.panelDragMoved = false;
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
          this.updateDragMoved(shortcut, event.offsetX, event.offsetY);
        })
        .onActionEnd((_event: GestureEvent): void => { this.finishPanelDrag(shortcut); })
        .onActionCancel((): void => { this.cancelPanelDrag(shortcut); })
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
  private static readonly KEY_F13 = 2816;
  private static readonly KEY_F14 = 2817;
  private static readonly KEY_F15 = 2818;
  private static readonly KEY_F16 = 2819;
  private static readonly KEY_F17 = 2820;
  private static readonly KEY_F18 = 2821;
  private static readonly KEY_F19 = 2822;
  private static readonly KEY_F20 = 2823;
  private static readonly KEY_F21 = 2824;
  private static readonly KEY_F22 = 2825;
  private static readonly KEY_F23 = 2826;
  private static readonly KEY_F24 = 2827;
  private static readonly KEY_HOME = 2081;
  private static readonly KEY_END = 2082;
  private static readonly KEY_PAGE_UP = 2068;
  private static readonly KEY_PAGE_DOWN = 2069;
  private static readonly KEY_ESC = 2070;
  private static readonly KEY_TAB = 2049;
  private static readonly KEY_BACKSPACE = 2055;
  private static readonly KEY_FORWARD_DELETE = 2071;
  private static readonly KEY_ENTER = 2054;
  private static readonly KEY_SPACE = 2050;
  private static readonly KEY_UP = 2012;
  private static readonly KEY_DOWN = 2013;
  private static readonly KEY_LEFT = 2014;
  private static readonly KEY_RIGHT = 2015;
  private static readonly KEY_MENU = 2067;
  private static readonly KEY_CAPS_LOCK = 2074;
  private static readonly KEY_SCROLL_LOCK = 2075;
  private static readonly KEY_SYSRQ = 2079;
  private static readonly KEY_BREAK = 2080;
  private static readonly KEY_INSERT = 2083;

  @Builder
  ShortcutLibrary() {
    Column() {
      Row({ space: 6 }) {
        this.PlatformChoice('windows', 'Windows · Ctrl')
        this.PlatformChoice('macos', 'macOS · Cmd')
      }.width('100%').margin({ bottom: 7 })
      Scroll() {
        Row({ space: 5 }) {
          ForEach(remoteShortcutCategories(), (category: RemoteShortcutCategory): void => {
            this.ShortcutCategoryChoice(category)
          }, (category: RemoteShortcutCategory): string => category)
        }
      }
      .width('100%').height(30).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
      .margin({ bottom: 7 })
      Grid() {
        ForEach(this.visibleShortcutPresets(), (item: RemoteShortcutPreset): void => {
          GridItem() { this.PresetShortcutBtn(item) }
        }, (item: RemoteShortcutPreset): string => item.id)
      }
      .columnsTemplate('1fr 1fr').rowsGap(6).columnsGap(6)
      .width('100%').height(204).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
    }.width('100%')
  }

  @Builder
  FunctionKeyLibrary() {
    Scroll() {
      Column({ space: 5 }) {
        Row() {
          this.ActionKey('F1', RemoteModifierPanel.KEY_F1)
          this.ActionKey('F2', RemoteModifierPanel.KEY_F2)
          this.ActionKey('F3', RemoteModifierPanel.KEY_F3)
          this.ActionKey('F4', RemoteModifierPanel.KEY_F4)
        }.width('100%')
        Row() {
          this.ActionKey('F5', RemoteModifierPanel.KEY_F5)
          this.ActionKey('F6', RemoteModifierPanel.KEY_F6)
          this.ActionKey('F7', RemoteModifierPanel.KEY_F7)
          this.ActionKey('F8', RemoteModifierPanel.KEY_F8)
        }.width('100%')
        Row() {
          this.ActionKey('F9', RemoteModifierPanel.KEY_F9)
          this.ActionKey('F10', RemoteModifierPanel.KEY_F10)
          this.ActionKey('F11', RemoteModifierPanel.KEY_F11)
          this.ActionKey('F12', RemoteModifierPanel.KEY_F12)
        }.width('100%')
        Row() {
          this.ActionKey('F13', RemoteModifierPanel.KEY_F13)
          this.ActionKey('F14', RemoteModifierPanel.KEY_F14)
          this.ActionKey('F15', RemoteModifierPanel.KEY_F15)
          this.ActionKey('F16', RemoteModifierPanel.KEY_F16)
        }.width('100%')
        Row() {
          this.ActionKey('F17', RemoteModifierPanel.KEY_F17)
          this.ActionKey('F18', RemoteModifierPanel.KEY_F18)
          this.ActionKey('F19', RemoteModifierPanel.KEY_F19)
          this.ActionKey('F20', RemoteModifierPanel.KEY_F20)
        }.width('100%')
        if (this.shortcutPlatform() === 'windows') {
          Row() {
            this.ActionKey('F21', RemoteModifierPanel.KEY_F21)
            this.ActionKey('F22', RemoteModifierPanel.KEY_F22)
            this.ActionKey('F23', RemoteModifierPanel.KEY_F23)
            this.ActionKey('F24', RemoteModifierPanel.KEY_F24)
          }.width('100%')
        }
        Row() {
          this.ActionKey('Home', RemoteModifierPanel.KEY_HOME)
          this.ActionKey('End', RemoteModifierPanel.KEY_END)
          this.ActionKey('PgUp', RemoteModifierPanel.KEY_PAGE_UP)
          this.ActionKey('PgDn', RemoteModifierPanel.KEY_PAGE_DOWN)
        }.width('100%')
        Row() {
          this.ActionKey('Ins', RemoteModifierPanel.KEY_INSERT)
          this.ActionKey('Del', RemoteModifierPanel.KEY_FORWARD_DELETE)
          this.ActionKey('PrtSc', RemoteModifierPanel.KEY_SYSRQ)
          this.ActionKey('Pause', RemoteModifierPanel.KEY_BREAK)
        }.width('100%')
        Row() {
          this.ActionKey('←', RemoteModifierPanel.KEY_LEFT)
          this.ActionKey('↑', RemoteModifierPanel.KEY_UP)
          this.ActionKey('↓', RemoteModifierPanel.KEY_DOWN)
          this.ActionKey('→', RemoteModifierPanel.KEY_RIGHT)
        }.width('100%')
        Row() {
          this.ActionKey('⌫ 退格', RemoteModifierPanel.KEY_BACKSPACE)
          this.ActionKey('Space', RemoteModifierPanel.KEY_SPACE)
          this.ActionKey('Caps', RemoteModifierPanel.KEY_CAPS_LOCK)
          this.ActionKey('Scroll', RemoteModifierPanel.KEY_SCROLL_LOCK)
        }.width('100%')
        Row() {
          this.ActionKey('Menu', RemoteModifierPanel.KEY_MENU)
          this.ActionKey('', 0)
          this.ActionKey('', 0)
          this.ActionKey('', 0)
        }.width('100%')
      }.width('100%')
    }.width('100%').height(204).scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  CustomShortcutLibrary() {
    if (!this.customizationEnabled) {
      Text('当前协议暂不支持保存自定义组合键')
        .width('100%').height(120).textAlign(TextAlign.Center)
        .fontSize(11).fontColor('rgba(255,255,255,0.48)')
    } else if (this.customEditorVisible) {
      this.CustomShortcutEditor()
    } else {
      this.CustomShortcutStrip()
      Text('自定义组合键按当前 ' + this.shortcutPlatformLabel() + ' 模式显示；Cmd 与 Win 使用同一远端 Meta 键。')
        .fontSize(9).fontColor('rgba(255,255,255,0.40)').width('100%')
        .margin({ top: 10 })
    }
  }

  build() {
    Column() {
      if (this.visible || this.prepareOnly || this.shortcutVisible) {
        Column() {
          Row() {
            this.PanelDragArea('组合键与功能键', this.shortcutVisible && !this.visible)
            Button() {
              SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor(['#FFFFFF'])
            }
            .width(44).height(44).padding(0).borderRadius(12)
            .backgroundColor('rgba(255,255,255,0.08)')
            .onClick((): void => { this.closeUnifiedPanel(); })
            .accessibilityText('关闭组合键与功能键面板')
          }.width('100%').margin({ bottom: 4 })

          Scroll() {
            Column() {
              Row() {
                if (this.shortcutPlatform() === 'macos') {
                  this.ModKey('win')
                  this.ModKey('alt')
                  this.ModKey('shift')
                  this.ModKey('ctrl')
                } else {
                  this.ModKey('ctrl')
                  this.ModKey('alt')
                  this.ModKey('shift')
                  this.ModKey('win')
                }
                this.FnKey()
              }.width('100%').justifyContent(FlexAlign.SpaceEvenly)

              Row() {
                this.ActionKey('Esc', RemoteModifierPanel.KEY_ESC)
                this.ActionKey('Tab', RemoteModifierPanel.KEY_TAB)
                this.ActionKey('⌫ 退格', RemoteModifierPanel.KEY_BACKSPACE)
                this.EnterKey()
              }.width('100%').justifyContent(FlexAlign.SpaceEvenly).margin({ top: 6 })

              Row({ space: 5 }) {
                this.SectionChoice('shortcuts', '快捷键')
                this.SectionChoice('functions', 'F1–F12 / 导航')
                this.SectionChoice('custom', '自定义')
              }.width('100%').margin({ top: 9, bottom: 8 })

              if (this.panelSection === 'functions' && this.functionKeysVisible) {
                this.FunctionKeyLibrary()
              } else if (this.panelSection === 'custom') {
                this.CustomShortcutLibrary()
              } else {
                this.ShortcutLibrary()
              }
            }.width('100%')
          }
          .width('100%').layoutWeight(1).scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
        }
        .width(this.panelWidth()).height(this.panelHeight()).padding(10).borderRadius(16)
        .backgroundColor(this.panelBg()).border({ width: 1, color: this.panelBorder() })
        .backdropBlur(22)
        .shadow({ radius: 22, color: 'rgba(0,0,0,0.42)', offsetY: 7 })
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({
          x: this.attachSide === 'right' ? 48 : -48, y: 0
        })).animation({ duration: 180, curve: Curve.EaseOut }))
        .position({
          x: this.shortcutVisible && !this.visible ? this.shortcutEffectiveX() : this.panelEffectiveX(),
          y: this.shortcutVisible && !this.visible ? this.shortcutEffectiveY() : this.panelEffectiveY()
        })
        .opacity(this.prepareOnly ? 0 : 1)
        .hitTestBehavior(this.prepareOnly ? HitTestMode.None : HitTestMode.BLOCK_HIERARCHY)
        .onAreaChange((_old: Area, next: Area): void => {
          const width: number = next.width as number;
          const height: number = next.height as number;
          if (Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0) {
            if (this.shortcutVisible && !this.visible) {
              this.onShortcutSizeChange(width, height);
            } else {
              this.onPanelSizeChange(width, height);
            }
          }
        })
      }
    }
    .width('100%').height('100%')
    .backgroundColor(Color.Transparent)
    // 根容器只负责定位，不占用面板外的命中区域；面板自身仍使用
    // BLOCK_HIERARCHY，保证其下方连接画面不会收到触控。
    .hitTestBehavior((this.visible || this.shortcutVisible) && !this.prepareOnly ?
      HitTestMode.Transparent : HitTestMode.None)
    .onAreaChange((_old: Area, next: Area): void => {
      const height: number = next.height as number;
      if (Number.isFinite(height) && height > 0 &&
        Math.abs(height - this.viewportHeight) >= 1) {
        this.viewportHeight = height;
      }
    })
  }
}
