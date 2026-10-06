/**
 * The 已保存 flash for settings that apply as soon as they change. Bump
 * `savedTick` after each successful save; the badge shows for a moment and
 * fades out (the same look as the AI 个性化 flash).
 */
@Component
export struct SettingsSavedBadge {
  @Prop @Watch('onSaved') savedTick: number = 0;
  @State private shown: boolean = false;
  private timer: number = -1;

  private onSaved(): void {
    if (this.savedTick <= 0) { return; }
    this.shown = true;
    if (this.timer !== -1) { clearTimeout(this.timer); }
    this.timer = setTimeout((): void => { this.shown = false; this.timer = -1; }, 1400);
  }

  aboutToDisappear(): void {
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
  }

  build() {
    Row() {
      if (this.shown) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(14).fontColor(['#34C759'])
          Text('已保存').fontSize(12).fontColor('#34C759')
        }.transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
      }
    }
  }
}
