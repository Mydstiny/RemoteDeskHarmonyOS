/** Shared fullscreen affordance for session pages without native PC chrome. */
@Component
export struct RemoteSessionFullscreenButton {
  @Prop fullscreen: boolean = false;
  @Prop compact: boolean = false;
  onToggle: () => void = (): void => {};

  build() {
    Button() {
      Row({ space: this.compact ? 0 : 6 }) {
        Text(this.fullscreen ? '↙' : '⛶')
          .fontSize(this.compact ? 18 : 16)
          .fontColor('#F7F8FA')
        if (!this.compact) {
          Text(this.fullscreen ? '退出全屏' : '全屏')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#F7F8FA')
        }
      }
      .justifyContent(FlexAlign.Center)
    }
    .height(36)
    .constraintSize({ minWidth: this.compact ? 36 : 76 })
    .padding({ left: this.compact ? 8 : 12, right: this.compact ? 8 : 12 })
    .borderRadius(18)
    .backgroundColor('rgba(16,20,27,0.78)')
    .border({ width: 0.5, color: 'rgba(255,255,255,0.24)' })
    .shadow({ radius: 10, color: 'rgba(0,0,0,0.28)', offsetY: 3 })
    .accessibilityText(this.fullscreen ? '退出全屏' : '进入全屏')
    .onClick((): void => { this.onToggle(); })
  }
}
