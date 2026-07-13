/**
 * GlassmorphicCard.ets — 通用玻璃拟态卡片
 */
import { AppTheme, buildDark, buildLight } from '../common/Theme';

/**
 * 获取当前主题的玻璃卡片背景色 (base=dark, 因为应用默认深色)
 */
function glassBg(): string {
  const theme: string = AppStorage.get<string>('currentTheme') ?? 'dark';
  const accent: string = AppStorage.get<string>('accentColor') ?? '#007DFF';
  const p = theme === 'light' ? buildLight(accent) : buildDark(accent);
  return p.card;
}
function glassBorder(): string {
  const theme: string = AppStorage.get<string>('currentTheme') ?? 'dark';
  const accent: string = AppStorage.get<string>('accentColor') ?? '#007DFF';
  const p = theme === 'light' ? buildLight(accent) : buildDark(accent);
  return p.cardBorder;
}

@Component
export struct GlassmorphicCard {
  cardRadius: number = AppTheme.radius.xl;
  cardPadding: number = AppTheme.spacing.md;
  cardBgColor: string = glassBg();
  cardBorderColor: string = glassBorder();
  cardShadowRadius: number = 16;
  cardShadowColor: string = 'rgba(0,0,0,0.06)';
  cardShadowOffsetY: number = 4;
  @BuilderParam contentBuilder: () => void;

  build() {
    Column() {
      if (this.contentBuilder) {
        this.contentBuilder();
      }
    }
    .width('100%')
    .padding(this.cardPadding)
    .borderRadius(this.cardRadius)
    .backgroundBlurStyle(BlurStyle.Regular)
    .backgroundColor(this.cardBgColor)
    .border({ width: 1, color: this.cardBorderColor, style: BorderStyle.Solid })
    .shadow({ radius: this.cardShadowRadius, color: this.cardShadowColor, offsetY: this.cardShadowOffsetY })
  }
}
