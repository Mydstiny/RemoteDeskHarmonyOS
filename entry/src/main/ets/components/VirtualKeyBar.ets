/**
 * VirtualKeyBar.ets — 终端虚拟键盘栏 (双行 14 键)
 *
 * 设计参考: ServerBox (flutter_server_box) virt_key.dart + virtual_keyboard.dart
 *
 * Row1: Esc  Tab  Ctrl  Alt  Shift  Home  End
 * Row2: ↑    ↓    ←    →    PgUp   PgDn   Enter
 *
 * 修饰键: 短按切换锁定, 状态由父组件持有.
 * 长按重复: 仅 ↑↓←→ 启用, 137ms 间隔 (与 ServerBox 一致).
 * 触觉反馈: 每次按键调 vibrator.startVibration (preset soft).
 */
import { vibrator } from '@kit.SensorServiceKit';

@Component
export struct VirtualKeyBar {
  /** 修饰键状态 — 由父组件 (SshTerminal) 持有, VirtualKeyBar 仅 UI 翻转 */
  @Link ctrlActive: boolean;
  @Link altActive: boolean;
  @Link shiftActive: boolean;

  /** 发送终端序列 (特殊键 + 字符) */
  onKey: (seq: string) => void = (_s: string): void => {};
  /** 修饰键切换后回调父组件, 用于移动端恢复隐藏输入框焦点 */
  onModifierTap: () => void = (): void => {};
  onModifierLock: (modifier: string) => void = (_modifier: string): void => {};
  onModifierUnlock: (modifier: string) => void = (_modifier: string): void => {};
  @StorageProp('accentColor') accentColor: string = '#007DFF';

  private static readonly KEY_H: number = 36;
  /** 键盘栏总高 (vp) — 两行各 42 + 上下 padding(4+6) = 94; 父级用于布局占位与栅格行数计算 */
  public static readonly TOTAL_H: number = 94;
  @State pressedKey: string = '';

  // ============================================================
  // 内部辅助
  // ============================================================

  private feedback(): void {
    try {
      vibrator.startVibration(
        { type: 'preset', effectId: 'haptic.effect.soft', count: 1, intensity: 60 },
        { usage: 'touch' }
      );
    } catch (_e) { /* 设备不支持/无权限静默 */ }
  }

  private send(seq: string): void {
    this.feedback();
    if (this.onKey) { this.onKey(seq); }
  }

  private pressKey(id: string, seq: string): void {
    this.pressedKey = id;
    this.send(seq);
    setTimeout((): void => {
      if (this.pressedKey === id) { this.pressedKey = ''; }
    }, 120);
  }

  private toggleModifier(modifier: string, active: boolean): void {
    this.feedback();
    if (active) {
      if (this.onModifierUnlock) { this.onModifierUnlock(modifier); }
    } else {
      if (this.onModifierLock) { this.onModifierLock(modifier); }
    }
    this.onModifierTap();
  }

  private keyBg(): string {
    return 'rgba(255,255,255,0.075)';
  }

  private keyPressedBg(): string {
    return this.accentColor + '33';
  }

  private keyActiveBg(): string {
    return this.accentColor + '44';
  }

  private keyBorderColor(active: boolean, pressed: boolean): string {
    if (active) { return this.accentColor; }
    if (pressed) { return 'rgba(255,255,255,0.55)'; }
    return 'rgba(255,255,255,0.10)';
  }

  private isPressed(id: string): boolean {
    return this.pressedKey === id;
  }

  private enterBg(): string {
    return this.accentColor + '99';
  }

  private modifierActive(modifier: string): boolean {
    if (modifier === 'ctrl') { return this.ctrlActive; }
    if (modifier === 'alt') { return this.altActive; }
    return this.shiftActive;
  }

  // ============================================================
  // UI 构建器
  // ============================================================

  /** 普通键 — 点击发送序列 */
  @Builder
  KeyBtn(label: string, seq: string) {
    Text(label).fontSize(12).fontColor('rgba(242,244,247,0.82)')
      .height(VirtualKeyBar.KEY_H).layoutWeight(1)
      .textAlign(TextAlign.Center)
      .borderRadius(10)
      .backgroundColor(this.isPressed(label) ? this.keyPressedBg() : this.keyBg())
      .border({ width: this.isPressed(label) ? 1 : 0.5, color: this.keyBorderColor(false, this.isPressed(label)) })
      .shadow({
        radius: this.isPressed(label) ? 12 : 8,
        color: this.isPressed(label) ? this.accentColor + '33' : 'rgba(0,0,0,0.10)',
        offsetY: 2
      })
      .margin({ left: 3, right: 3 })
      .gesture(TapGesture({ count: 1 }).onAction((): void => { this.pressKey(label, seq); }))
  }

  /** 修饰键 — 短按切换锁定状态 */
  @Builder
  ModBtn(label: string, modifier: string) {
    Text(label).fontSize(12)
      .fontColor(this.modifierActive(modifier) ? '#FFFFFF' : 'rgba(242,244,247,0.82)')
      .fontWeight(this.modifierActive(modifier) ? FontWeight.Bold : FontWeight.Normal)
      .height(VirtualKeyBar.KEY_H).layoutWeight(1)
      .textAlign(TextAlign.Center)
      .borderRadius(10)
      .backgroundColor(this.modifierActive(modifier) ? this.keyActiveBg() : this.keyBg())
      .border({
        width: this.modifierActive(modifier) ? 2 : 0.5,
        color: this.keyBorderColor(this.modifierActive(modifier), false)
      })
      .shadow({
        radius: this.modifierActive(modifier) ? 18 : 8,
        color: this.modifierActive(modifier) ? this.accentColor + '66' : 'rgba(0,0,0,0.10)',
        offsetY: 2
      })
      .margin({ left: 3, right: 3 })
      .gesture(TapGesture({ count: 1 })
        .onAction((): void => { this.toggleModifier(modifier, this.modifierActive(modifier)); }))
  }

  /** 方向键 — 长按重复 137ms (LongPressGesture repeat=true) */
  @Builder
  ArrowBtn(label: string, seq: string) {
    Text(label).fontSize(14).fontColor('rgba(242,244,247,0.86)')
      .height(VirtualKeyBar.KEY_H).layoutWeight(1)
      .textAlign(TextAlign.Center)
      .borderRadius(10)
      .backgroundColor(this.isPressed(label) ? this.keyPressedBg() : this.keyBg())
      .border({ width: this.isPressed(label) ? 1 : 0.5, color: this.keyBorderColor(false, this.isPressed(label)) })
      .shadow({
        radius: this.isPressed(label) ? 12 : 8,
        color: this.isPressed(label) ? this.accentColor + '33' : 'rgba(0,0,0,0.10)',
        offsetY: 2
      })
      .margin({ left: 3, right: 3 })
      .gesture(
        GestureGroup(GestureMode.Exclusive,
          LongPressGesture({ repeat: true, duration: 137 })
            .onAction((_event: GestureEvent) => {
              // 长按首发 + repeat 各发一次
              this.pressKey(label, seq);
            }),
          TapGesture({ count: 1 })
            .onAction((): void => { this.pressKey(label, seq); })
        )
      )
  }

  /** Enter 键 — 强调显示 (终端核心键) */
  @Builder
  EnterBtn() {
    Text('↵').fontSize(16).fontColor('#FFFFFF').fontWeight(FontWeight.Medium)
      .height(VirtualKeyBar.KEY_H).layoutWeight(1)
      .textAlign(TextAlign.Center)
      .borderRadius(10).backgroundColor(this.isPressed('Enter') ? this.accentColor : this.enterBg())
      .border({ width: 1, color: this.isPressed('Enter') ? '#FFFFFF' : this.accentColor })
      .shadow({ radius: this.isPressed('Enter') ? 16 : 12, color: this.accentColor + '44', offsetY: 2 })
      .margin({ left: 3, right: 3 })
      .gesture(TapGesture({ count: 1 }).onAction((): void => { this.pressKey('Enter', '\r'); }))
  }

  build() {
    Column() {
      Column() {
        // Row 1: 控制 / 跳转
        Row() {
          this.KeyBtn('Esc', '\x1b')
          this.KeyBtn('Tab', '\t')
          this.ModBtn('Ctrl', 'ctrl')
          this.ModBtn('Alt', 'alt')
          this.ModBtn('⇧', 'shift')
          this.KeyBtn('Home', '\x1b[H')
          this.KeyBtn('End', '\x1b[F')
        }
        .width('100%').height(42).alignItems(VerticalAlign.Center)

        // Row 2: 方向 + 翻页 + Enter
        Row() {
          this.ArrowBtn('↑', '\x1b[A')
          this.ArrowBtn('↓', '\x1b[B')
          this.ArrowBtn('←', '\x1b[D')
          this.ArrowBtn('→', '\x1b[C')
          this.KeyBtn('PgUp', '\x1b[5~')
          this.KeyBtn('PgDn', '\x1b[6~')
          this.EnterBtn()
        }
        .width('100%').height(42).alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .constraintSize({ maxWidth: 720 })
      .padding({ left: 8, right: 8, top: 4, bottom: 6 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    // SSH 终端始终深色模式 — 背景和文字硬编码, 不跟随系统主题
    .backgroundColor('#11151C')
    .backgroundBlurStyle(BlurStyle.NONE)
    .linearGradient({
      direction: GradientDirection.Bottom,
      colors: [['rgba(255,255,255,0.04)', 0], ['rgba(255,255,255,0.00)', 1]]
    })
  }
}
