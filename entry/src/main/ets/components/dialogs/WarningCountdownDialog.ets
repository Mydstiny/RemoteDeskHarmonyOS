/**
 * WarningCountdownDialog.ets — 倒计时警告弹窗
 *
 * 华为官方风格的高危操作确认弹窗:
 *   - ⚠️ 红色警告图标
 *   - 标题 + 多行警告说明
 *   - 倒计时按钮 (默认5秒), 归零后变为实色可点击
 *   - 取消按钮
 *
 * 用法:
 *   const dlg = new CustomDialogController({
 *     builder: WarningCountdownDialog({
 *       title: '⚠️ 重置加密',
 *       message: '此操作将永久删除云端所有加密数据...',
 *       confirmLabel: '我已知晓，确认重置',
 *       countdownSeconds: 5,
 *       onConfirm: () => { ... }
 *     })
 *   });
 *   dlg.open();
 */
import { Palette, buildDark, buildLight } from '../../common/Theme';

const DEFAULT_COUNTDOWN: number = 5;

@CustomDialog
export struct WarningCountdownDialog {
  controller: CustomDialogController;
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  title: string = '';
  message: string = '';
  confirmLabel: string = '确认';
  countdownSeconds: number = DEFAULT_COUNTDOWN;
  onConfirm?: () => void;

  @State countdown: number = DEFAULT_COUNTDOWN;
  @State cdtActive: boolean = false;
  private timer: number = -1;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  aboutToAppear(): void {
    this.countdown = this.countdownSeconds > 0 ? this.countdownSeconds : DEFAULT_COUNTDOWN;
    this.cdtActive = true;
    this.timer = setInterval(() => {
      this.countdown--;
      if (this.countdown <= 0) {
        this.countdown = 0;
        this.cdtActive = false;
        if (this.timer !== -1) {
          clearInterval(this.timer);
          this.timer = -1;
        }
      }
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private getConfirmText(): string {
    if (this.cdtActive && this.countdown > 0) {
      return this.confirmLabel + " (" + this.countdown.toString() + "s)";
    }
    return this.confirmLabel;
  }

  build() {
    Column() {
      // 警告图标
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
        .fontSize(36)
        .fontColor([this.pal().danger])
        .margin({ bottom: 12 })

      // 标题
      Text(this.title)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.pal().danger)
        .textAlign(TextAlign.Center)
        .margin({ bottom: 12 })
        .width('100%')

      // 消息
      Text(this.message)
        .fontSize(14)
        .fontColor(this.pal().text2)
        .textAlign(TextAlign.Start)
        .width('100%')
        .margin({ bottom: 24 })
        .lineHeight(20)

      // 按钮区
      Row() {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor(this.pal().text2)
          .backgroundColor(this.pal().surface)
          .borderRadius(10)
          .onClick(() => { this.controller.close(); })

        Blank().width(12)

        Button(this.getConfirmText())
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor(this.cdtActive ? this.pal().text3 : '#FFFFFF')
          .backgroundColor(this.cdtActive ? this.pal().surface : this.pal().danger)
          .borderRadius(10)
          .enabled(!this.cdtActive)
          .onClick(() => {
            this.controller.close();
            if (this.onConfirm) {
              this.onConfirm();
            }
          })
      }
      .width('100%')
    }
    .padding({ left: 24, right: 24, top: 28, bottom: 24 })
    .width('100%')
    .borderRadius(20)
    .backgroundColor(this.pal().bg)
    .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
    .shadow({ radius: 32, color: 'rgba(0,0,0,0.15)', offsetY: 8 })
  }
}
