import { protocolIconDescriptor } from '../../services/ProtocolIconPolicy';

@Component
export struct MoonlightBrandIcon {
  @Prop iconSize: number = 24;
  @Prop tint: string = '#007DFF';
  @Prop accessibilityLabel: string = 'Moonlight';
  @State private brandFailed: boolean = false;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (!this.brandFailed) {
        Image(protocolIconDescriptor('moonlight').resource)
          .width(this.iconSize)
          .height(this.iconSize)
          .fillColor(this.tint)
          .objectFit(ImageFit.Contain)
          .accessibilityText(this.accessibilityLabel)
          .onError((): void => { this.brandFailed = true; })
      } else {
        SymbolGlyph(protocolIconDescriptor('moonlight').fallback)
          .fontSize(this.iconSize)
          .fontColor([this.tint])
          .accessibilityText(this.accessibilityLabel)
      }
    }
    .width(this.iconSize)
    .height(this.iconSize)
  }
}
