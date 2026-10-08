import { AppSheetHeader } from '../../AppSheetHeader';
import { AppConfig, Palette, buildDark, buildLight } from '../../../common/Theme';
import { appUiOnAccentText } from '../../../common/AppUiColorPolicy';
import { ProPhonePasskeyPanel } from './ProPhonePasskeyPanel';
import { SlidingSegment } from '../../SlidingSegment';

/** The three steps of using it, short enough to read at a glance. */
const PASSKEY_STEPS: string[] = [
  '手机：打开「接收登录请求」',
  '另一台设备：点「与手机配对」，核对两边的配对码后在手机上确认',
  '配对后：测试注册和登录；鸿蒙 PC 的远程桌面里，网站要安全密钥时也可以用手机'
];

/**
 * 设置 → 安全与数据 → 手机通行密钥. What it is in one sentence and how to use it in three steps, then the page split
 * by role: 作为密钥 (this phone holds the keys and confirms requests) and 使用手机密钥 (this device pairs with the
 * phone and asks it). A phone opens on 作为密钥, a tablet or PC on 使用手机密钥.
 */
@Component
export struct PhonePasskeySettingsSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @StorageProp('isPadDevice') isPadDevice: boolean = false;
  @Prop viewportHeight: number = 0;
  onClose: () => void = (): void => {};
  @State role: number = 0;
  private slide: number = 0;

  aboutToAppear(): void {
    this.role = this.isDesktopDevice || this.isPadDevice ? 1 : 0;
  }

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }

  @Builder private intro() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.key_fill')).fontSize(22).fontColor([this.accent])
      }.width(44).height(44).borderRadius(14).backgroundColor(this.pal().surface)
      Text('用同一华为账号的手机当通行密钥。私钥只存在手机的系统密钥库里，每次使用都要在手机上确认，并验证人脸、指纹或锁屏密码。')
        .fontSize(13).lineHeight(19).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily).layoutWeight(1)
    }.width('100%').alignItems(VerticalAlign.Top)
  }

  @Builder private steps() {
    Column({ space: 10 }) {
      ForEach(PASSKEY_STEPS, (step: string, index: number): void => {
        Row({ space: 10 }) {
          Text((index + 1).toString()).fontSize(12).fontWeight(FontWeight.Medium)
            .fontColor(appUiOnAccentText(this.accent)).textAlign(TextAlign.Center)
            .width(20).height(20).borderRadius(10).backgroundColor(this.accent)
          Text(step).fontSize(13).lineHeight(19).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily)
            .layoutWeight(1)
        }.width('100%').alignItems(VerticalAlign.Top)
      }, (step: string): string => step)
    }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(16)
  }

  /** The new role's page comes in from the side of the tab chosen. */
  private roleEffect(): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: this.slide * 32 }))
        .animation({ duration: 280, curve: Curve.FastOutSlowIn }),
      TransitionEffect.IDENTITY);
  }

  build() {
    Column() {
      AppSheetHeader({ title: '手机通行密钥', subtitle: '原型 · 目前只在调试版开放', showProBadge: true, whiteOnAccent: true,
        onClose: (): void => { this.onClose(); } })
      Scroll() {
        Column({ space: 14 }) {
          this.intro()
          this.steps()
          SlidingSegment({ labels: ['作为密钥', '使用手机密钥'], selected: this.role, itemHeight: 36, radius: 18,
            onSelect: (index: number): void => {
              this.slide = index > this.role ? 1 : -1;
              this.getUIContext().animateTo({ duration: 280, curve: Curve.FastOutSlowIn }, (): void => { this.role = index; });
            } })
          if (this.role === 0) {
            Column({ space: 12 }) {
              Text('这台设备保存通行密钥，在这里确认别的设备发来的请求。')
                .fontSize(12).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily).width('100%')
              ProPhonePasskeyPanel({ role: 0 })
            }.width('100%').transition(this.roleEffect())
          } else {
            Column({ space: 12 }) {
              Text('这台设备向配对的手机请求通行密钥。')
                .fontSize(12).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily).width('100%')
              ProPhonePasskeyPanel({ role: 1 })
            }.width('100%').transition(this.roleEffect())
          }
        }.width('100%').padding({ left: 20, right: 20, top: 4, bottom: 28 })
      }.width('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: false })
      .align(Alignment.Top)
      // Fits its content, never past the window (the sheet itself is FIT_CONTENT).
      .constraintSize({ maxHeight: Math.max(320, (this.viewportHeight > 0 ? this.viewportHeight : 800) - 140) })
    }.width('100%').backgroundColor(this.pal().sheetBg)
  }
}
