import { AppConfig } from '../common/Theme';

/** Product marker only; never grants access or represents a payment status. */
@Component
export struct ProBadge {
  build() {
    Text('Pro').fontSize(10).fontWeight(FontWeight.Bold).fontFamily(AppConfig.fontFamily)
      .fontColor('#29223F').maxLines(1)
      .padding({ left: 8, right: 8, top: 3, bottom: 3 }).borderRadius(7)
      .linearGradient({ angle: 115, colors: [['#B9F3EA', 0], ['#CDC9FF', 0.35],
        ['#F4C8E5', 0.7], ['#F9E3B8', 1]] })
      .border({ width: 0.5, color: '#90FFFFFF' })
      .accessibilityText('Pro 功能标识')
  }
}
