@Component
export struct GlassmorphicCard {
  @Prop borderRadius: number = 20;
  @Prop paddingSize: number = 16;

  build() {
    Column() {
      this.contentBuilder()
    }
    .width('100%')
    .padding(this.paddingSize)
    .borderRadius(this.borderRadius)
    .backgroundBlurStyle(BlurStyle.REGULAR)
    .backgroundColor('rgba(255, 255, 255, 0.15)')
    .border({
      width: 1,
      color: 'rgba(255, 255, 255, 0.2)',
      style: BorderStyle.Solid
    })
    .shadow({
      radius: 20,
      color: 'rgba(0, 0, 0, 0.15)',
      offsetY: 4
    })
  }

  @BuilderParam contentBuilder: () => void;
}
