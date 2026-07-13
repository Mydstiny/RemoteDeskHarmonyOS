/**
 * HostCard.ets — 主机卡片组件 (纯主题色，无 emoji)
 */
import { RemoteHost } from '../model/RemoteHost';
import { AppTheme, Palette, buildDark, buildLight, AppConfig } from '../common/Theme';

@Component
export struct HostCard {
  @Prop host: RemoteHost = new RemoteHost();
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  cardClick?: () => void;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private protoLabel(): string {
    return this.host.protocol.toUpperCase();
  }

  private protoColor(): string {
    return this.host.protocol === 'rdp' ? AppConfig.getColor() : '#51CF66';
  }

  build() {
    Row() {
      // 协议色块标签 (sm: 42, md+: 46)
      Column() {
        Text(this.protoLabel())
          .fontSize(this.breakpoint === 'sm' ? 11 : 14).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
      }
      .width(this.breakpoint === 'sm' ? 44 : 46)
      .height(this.breakpoint === 'sm' ? 44 : 46)
      .borderRadius(this.breakpoint === 'sm' ? 12 : 14)
      .backgroundColor(this.protoColor())
      .justifyContent(FlexAlign.Center)

      // 主机信息 (sm: old, md+: new)
      Column() {
        Row() {
          Text(this.host.label)
            .fontSize(this.breakpoint === 'sm' ? 16 : 17).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text).maxLines(1).layoutWeight(1)
          if (this.host.locked) {
            SymbolGlyph($r('sys.symbol.ohos_lock'))
              .fontSize(this.breakpoint === 'sm' ? 14 : 18)
              .fontColor([this.pal().danger])
              .margin({ left: this.breakpoint === 'sm' ? 6 : 8 })
          }
        }
        if (!this.host.locked) {
          Text(`${this.host.host}:${this.host.port}  ·  ${this.host.username}`)
            .fontSize(this.breakpoint === 'sm' ? 12 : 14).fontColor(this.pal().text2).maxLines(1)
            .margin({ top: this.breakpoint === 'sm' ? 2 : 4 })
        } else {
          Text('已锁定 · 需要验证')
            .fontSize(this.breakpoint === 'sm' ? 11 : 13).fontColor(this.pal().text3)
            .margin({ top: this.breakpoint === 'sm' ? 2 : 4 })
        }
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)
      .margin({ left: this.breakpoint === 'sm' ? 12 : 14 })
    }
    .width('100%')
    .constraintSize({ minHeight: this.breakpoint === 'sm' ? 66 : 80 })
    .padding(this.breakpoint === 'sm' ? 12 : 14)
    .borderRadius(14)
    .backgroundColor(this.pal().card)
    .backgroundBlurStyle(BlurStyle.Regular)
    .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
    .hoverEffect(HoverEffect.Highlight)
    .onClick(() => { if (this.cardClick) { this.cardClick(); } })
  }
}
