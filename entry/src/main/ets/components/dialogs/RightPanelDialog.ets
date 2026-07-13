/**
 * RightPanelDialog.ets — PC/平板右侧独立弹出对话框
 *
 * 设计参考: moonlight-harmony PcListDialogs.ets
 * 在 PC/平板端从底部右侧弹出, 手机端从底部居中弹出
 */
import { Palette, buildDark, buildLight } from '../../common/Theme';

/**
 * 对话框中承载的内容 Builder 签名
 * 每个使用 RightPanelDialog 的页面都会通过 @Builder 构建内容
 */
interface DialogContent {
  build(): void;
}

@CustomDialog
export struct RightPanelDialog {
  controller: CustomDialogController;
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop breakpoint: string = 'sm';
  // 弹窗固定宽度 (仅 md/lg 生效)
  @Prop panelWidth: number = 420;
  // 标题 (可选，为空则不显示标题栏)
  @Prop title: string = '';
  // 内部使用 @Builder 构建内容 (通过闭包方式传入)
  @State _innerTitle: string = '';

  @Builder
  defaultContent() {
    // 默认空内容
  }

  @BuilderParam content: () => void = this.defaultContent;

  aboutToAppear(): void {
    this._innerTitle = this.title;
  }

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private isWidePanel(): boolean {
    return this.breakpoint === 'lg' || this.breakpoint === 'md';
  }

  build() {
    Column() {
      // 标题栏
      if (this._innerTitle !== '') {
        Row() {
          Text(this._innerTitle)
            .fontSize(19).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text)
            .textAlign(TextAlign.Start).layoutWeight(1)
          Text('✕')
            .fontSize(14)
            .fontColor(this.pal().text3)
            .padding({ left: 12, right: 8, top: 8, bottom: 8 })
            .onClick(() => { this.controller.close(); })
        }
        .width('100%')
        .padding({ left: 24, right: 20, top: 24, bottom: 10 })
      }

      // 滚动内容区
      Scroll() {
        Column() {
          this.content()
        }
        .width('100%')
      }
      .layoutWeight(1).scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width(this.isWidePanel()
      ? this.panelWidth + 'vp'
      : '100%')
    .constraintSize({ maxHeight: '80vh', minHeight: 200 })
    .borderRadius(this.isWidePanel()
      ? 24
      : { topLeft: 24, topRight: 24, bottomLeft: 0, bottomRight: 0 })
    .backgroundColor(this.pal().bg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
    .shadow(this.isWidePanel()
      ? { radius: 32, color: 'rgba(0,0,0,0.15)', offsetY: 8 }
      : { radius: 20, color: 'rgba(0,0,0,0.12)', offsetY: -4 })
    .margin(this.isWidePanel()
      ? { right: 16, bottom: 12 }
      : { bottom: 0 })
    .transition(
      TransitionEffect.OPACITY
        .animation({ duration: 280, curve: Curve.EaseOut })
        .combine(
          TransitionEffect.translate({ x: this.isWidePanel() ? 40 : 0, y: this.isWidePanel() ? 0 : 40 })
            .animation({ duration: 320, curve: Curve.FastOutSlowIn })
        )
        .combine(
          TransitionEffect.scale({ x: this.isWidePanel() ? 0.97 : 1, y: 0.97 })
            .animation({ duration: 300, curve: Curve.EaseOut })
        )
    )
  }
}
