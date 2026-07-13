/**
 * RemoteModifierHandle.ets — 侧边吸附悬浮胶囊
 *
 * 收起态: 贴边半胶囊工具柄, 显示当前修饰键状态或 ⌨ 图标。
 * 交互: 单击展开面板, 长按快捷键面板, 拖动后松手吸边。
 *
 * 父组件持有 handleX/handleY/handleSide, 此组件仅上报位置变化。
 * 此组件不发送任何协议按键, 仅暴露 UI 事件。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'ModifierHandle';
const DOMAIN = 0x0014;
const HANDLE_WIDTH = 58;
const VISIBLE_TAB_WIDTH = 24;
const HIDDEN_LABEL_WIDTH = HANDLE_WIDTH - VISIBLE_TAB_WIDTH;

@Component
export struct RemoteModifierHandle {
  /** 胶囊 X 坐标 (vp, 父组件管理) */
  @Prop handleX: number = 0;
  /** 胶囊 Y 坐标 (vp, 父组件管理) */
  @Prop handleY: number = 300;
  /** 吸附侧: 'left' | 'right' */
  @Prop handleSide: string = 'right';
  /** 面板是否展开 (用于激活态样式) */
  @Prop panelVisible: boolean = false;
  /** 修饰键锁定状态 (决定胶囊标签) */
  @Prop ctrlLocked: boolean = false;
  @Prop altLocked: boolean = false;
  @Prop shiftLocked: boolean = false;
  @Prop winLocked: boolean = false;
  @Prop fnLayer: boolean = false;
  @StorageProp('accentColor') accentColor: string = '#007DFF';

  /** 单击胶囊 → 展开/收起面板 */
  onTogglePanel: () => void = (): void => {};
  /** 长按胶囊 → 打开快捷键面板 */
  onLongPress: () => void = (): void => {};
  /** 拖动结束, 上报最终坐标 (vp), 父组件负责吸边与动画 */
  onPositionChange: (x: number, y: number) => void = (_x: number, _y: number): void => {};

  /** 拖拽时本地偏移 */
  @State private dragOffsetX: number = 0;
  @State private dragOffsetY: number = 0;
  @State private dragging: boolean = false;
  @State private pressed: boolean = false;

  // ============================================================
  // 胶囊标签
  // ============================================================

  private getLabel(): string {
    if (this.fnLayer) {
      return 'Fn';
    }
    const parts: string[] = [];
    if (this.ctrlLocked) {
      parts.push('Ctrl');
    }
    if (this.altLocked) {
      parts.push('Alt');
    }
    if (this.shiftLocked) {
      parts.push('⇧');
    }
    if (this.winLocked) {
      parts.push('Win');
    }
    if (parts.length > 0) {
      return parts.join(' ');
    }
    return '⌨';
  }

  private hasActiveModifier(): boolean {
    return this.ctrlLocked || this.altLocked || this.shiftLocked || this.winLocked || this.fnLayer;
  }

  private getTabLabel(): string {
    if (this.fnLayer) {
      return 'Fn';
    }
    if (this.hasActiveModifier()) {
      return '●';
    }
    return '⌨';
  }

  private effectiveX(): number {
    return this.handleX + this.dragOffsetX;
  }

  private effectiveY(): number {
    return this.handleY + this.dragOffsetY;
  }

  // ============================================================
  // 样式
  // ============================================================

  private capsuleBg(): string {
    if (this.panelVisible || this.dragging) {
      return 'rgba(20,26,36,0.88)';
    }
    if (this.hasActiveModifier()) {
      return 'rgba(20,28,40,0.82)';
    }
    return 'rgba(14,18,28,0.72)';
  }

  private capsuleBorder(): string {
    if (this.hasActiveModifier()) {
      return this.accentColor + '66';
    }
    if (this.panelVisible) {
      return 'rgba(255,255,255,0.22)';
    }
    return 'rgba(255,255,255,0.14)';
  }

  private labelColor(): string {
    if (this.hasActiveModifier()) {
      return '#FFFFFF';
    }
    return '#E6E6E6';
  }

  // ============================================================
  // 构建
  // ============================================================

  build() {
    Stack() {
      // 胶囊本体 — 半透明深色工具柄
      Row() {
        if (this.handleSide === 'left') {
          Text(this.getLabel())
            .fontSize(10)
            .fontColor(this.labelColor())
            .fontWeight(this.hasActiveModifier() ? FontWeight.Bold : FontWeight.Normal)
            .width(HIDDEN_LABEL_WIDTH)
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.getTabLabel())
            .fontSize(this.fnLayer ? 10 : 13)
            .fontColor(this.labelColor())
            .fontWeight(this.hasActiveModifier() ? FontWeight.Bold : FontWeight.Normal)
            .width(VISIBLE_TAB_WIDTH)
            .textAlign(TextAlign.Center)
        } else {
          Text(this.getTabLabel())
            .fontSize(this.fnLayer ? 10 : 13)
            .fontColor(this.labelColor())
            .fontWeight(this.hasActiveModifier() ? FontWeight.Bold : FontWeight.Normal)
            .width(VISIBLE_TAB_WIDTH)
            .textAlign(TextAlign.Center)
          Text(this.getLabel())
            .fontSize(10)
            .fontColor(this.labelColor())
            .fontWeight(this.hasActiveModifier() ? FontWeight.Bold : FontWeight.Normal)
            .width(HIDDEN_LABEL_WIDTH)
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .height(42)
      .width(HANDLE_WIDTH)
      .borderRadius(14)
      .backgroundColor(this.capsuleBg())
      .border({ width: this.hasActiveModifier() ? 1.5 : 1, color: this.capsuleBorder() })
      .shadow({
        radius: this.hasActiveModifier() ? 14 : 8,
        color: this.hasActiveModifier() ? this.accentColor + '33' : 'rgba(0,0,0,0.30)',
        offsetY: 2
      })
      .alignItems(VerticalAlign.Center)
      .gesture(
        GestureGroup(GestureMode.Exclusive,
          TapGesture({ count: 1 })
            .onAction((): void => {
              hilog.info(DOMAIN, TAG, 'handle tap → toggle panel');
              this.onTogglePanel();
            }),
          LongPressGesture({ duration: 500 })
            .onAction((): void => {
              hilog.info(DOMAIN, TAG, 'handle long-press → shortcut panel');
              this.onLongPress();
            }),
          PanGesture({ fingers: 1, distance: 5 })
            .onActionStart((_event: GestureEvent): void => {
              this.dragging = true;
              this.dragOffsetX = 0;
              this.dragOffsetY = 0;
            })
            .onActionUpdate((event: GestureEvent): void => {
              this.dragOffsetX = event.offsetX;
              this.dragOffsetY = event.offsetY;
            })
            .onActionEnd((_event: GestureEvent): void => {
              const finalX: number = this.effectiveX();
              const finalY: number = this.effectiveY();
              this.dragging = false;
              this.dragOffsetX = 0;
              this.dragOffsetY = 0;
              hilog.info(DOMAIN, TAG, 'handle drag end → x=' + Math.round(finalX).toString() +
                ' y=' + Math.round(finalY).toString());
              this.onPositionChange(finalX, finalY);
            })
        )
      )
    }
    .position({ x: this.effectiveX(), y: this.effectiveY() })
    .hitTestBehavior(HitTestMode.Default)
    // 不铺全屏 — 仅胶囊自身区域响应触摸
  }
}
