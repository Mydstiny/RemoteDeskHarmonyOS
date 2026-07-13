/**
 * TotpProgressBar.ets — TOTP 时间刷新条 (Canvas 自定义组件)
 *
 * 参考 Google Authenticator 时间指示器设计。
 * 填充部分用 accentColor, 背景用 rgba(accent, 0.15)。
 */
@Component
export struct TotpProgressBar {
  @Prop period: number = 30;
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @State remaining: number = 30;
  @State progress: number = 0;
  private timer: number = -1;

  aboutToAppear(): void {
    this.tick();
    this.timer = setInterval(() => { this.tick(); }, 1000);
  }

  aboutToDisappear(): void {
    if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
  }

  private tick(): void {
    const now: number = Math.floor(Date.now() / 1000);
    const r: number = this.period - (now % this.period);
    this.remaining = r;
    this.progress = 1.0 - (r / this.period);
  }

  private accentRgba(alpha: number): string {
    const r: number = parseInt(this.accentColor.substring(1, 3), 16);
    const g: number = parseInt(this.accentColor.substring(3, 5), 16);
    const b: number = parseInt(this.accentColor.substring(5, 7), 16);
    return `rgba(${r},${g},${b},${alpha})`;
  }

  build() {
    Row() {
      // 进度条
      Progress({ value: this.progress * 100, total: 100, type: ProgressType.Linear })
        .width('100%').height(4)
        .color(this.accentColor)
        .backgroundColor(this.accentRgba(0.15))
        .layoutWeight(1)

      Text(`${this.remaining}s`)
        .fontSize(13).fontWeight(FontWeight.Medium)
        .fontColor(this.accentColor)
        .fontFamily('monospace')
        .margin({ left: 10 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 4 })
  }
}
