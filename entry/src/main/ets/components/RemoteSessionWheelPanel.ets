import { LengthMetrics } from '@kit.ArkUI';
import { AppSheetHeader } from './AppSheetHeader';
import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';
import { appUiOnAccentText } from '../common/AppUiColorPolicy';
import {
  normalizeRemoteWheelSpeed,
  remoteWheelSessionSpeedChoices,
  remoteWheelSpeedLabel
} from '../services/RemoteWheelPreferencePolicy';

/**
 * A session's 滚轮 controls (the VNC rail's 滚轮 button): direction and speed, the same settings as 设置 › 远程滚轮 for
 * this protocol, applied at once. Also says how to scroll by touch.
 */
@Component
export struct RemoteSessionWheelPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @Prop protocol: string = 'vnc';
  @Prop protocolLabel: string = 'VNC';
  @Prop reverse: boolean = false;
  @Prop speed: number = 100;
  onReverse: (on: boolean) => void = (_on: boolean): void => {};
  onSpeed: (speed: number) => void = (_speed: number): void => {};
  onClose: () => void = (): void => {};

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }

  private current(): number { return normalizeRemoteWheelSpeed(this.speed, this.protocol); }

  build() {
    Column() {
      AppSheetHeader({ title: '滚轮', subtitle: this.protocolLabel + ' · 与设置里的远程滚轮同步', whiteOnAccent: true,
        onClose: (): void => { this.onClose(); } })
      Column({ space: 14 }) {
        Row() {
          Column() {
            Text('反转滚轮方向').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
              .fontFamily(AppConfig.fontFamily)
            Text('鼠标滚轮、触控板和三指滑动一起反转').fontSize(12).fontColor(this.pal().text2)
              .fontFamily(AppConfig.fontFamily).margin({ top: 3 })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.reverse }).selectedColor(this.accent)
            .accessibilityText('反转 ' + this.protocolLabel + ' 滚轮方向')
            .onChange((on: boolean): void => { this.onReverse(on); })
        }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 15, right: 12, top: 10, bottom: 10 })
        .backgroundColor(this.pal().card).borderRadius(14)

        Column({ space: 10 }) {
          Row() {
            Text('滚轮速度').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
              .fontFamily(AppConfig.fontFamily).layoutWeight(1)
            Text(remoteWheelSpeedLabel(this.current())).fontSize(15).fontWeight(FontWeight.Medium)
              .fontColor(this.accent).fontFamily(AppConfig.fontFamily)
          }.width('100%')
          Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
            ForEach(remoteWheelSessionSpeedChoices(this.protocol), (speed: number): void => {
              Text(speed.toString() + '%').fontSize(13).height(36).padding({ left: 14, right: 14 })
                .textAlign(TextAlign.Center).borderRadius(18)
                .fontColor(this.current() === speed ? appUiOnAccentText(this.accent) : this.pal().text)
                .backgroundColor(this.current() === speed ? this.accent : this.pal().surface)
                .accessibilityText('滚轮速度 ' + speed.toString() + '%' + (this.current() === speed ? '，已选中' : ''))
                .onClick((): void => { this.onSpeed(speed); })
            }, (speed: number): string => speed.toString() + (this.current() === speed ? '-on' : '-off'))
          }.width('100%')
          Text('触屏上三指上下滑动滚动；开启双指缩放时，双指只用来缩放和移动画面。')
            .fontSize(12).lineHeight(18).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily).width('100%')
        }.width('100%').padding({ left: 15, right: 15, top: 14, bottom: 14 })
        .backgroundColor(this.pal().card).borderRadius(14)
      }.width('100%').padding({ left: 20, right: 20, top: 4, bottom: 24 })
    }.width('100%').backgroundColor(this.pal().sheetBg)
  }
}
