import { AppTheme, Palette, buildDark, buildLight } from '../../common/Theme';
import {
  MoonlightLaunchPreflightResult,
  moonlightLaunchPreflight
} from '../../services/MoonlightUiPolicy';
import { MoonlightBrandIcon } from './MoonlightBrandIcon';

@Component
export struct MoonlightLaunchSheet {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @Prop hostName: string = '';
  @Prop appName: string = '';
  @Prop resolutionLabel: string = '跟随主机';
  @Prop fps: number = 60;
  @Prop codecLabel: string = '自动';
  @Prop audioLabel: string = '立体声';
  @Prop inputLabel: string = '直接触控';
  @Prop routeValid: boolean = false;
  @Prop hostAvailable: boolean = false;
  @Prop certificateChanged: boolean = false;
  @Prop identityAvailable: boolean = false;
  @Prop appAvailable: boolean = false;
  @Prop meteredNetwork: boolean = false;
  @Prop meteredAllowed: boolean = false;
  @Prop meteredStateUnknown: boolean = false;
  @Prop meteredApprovalAvailable: boolean = false;
  @Prop hostBusy: boolean = false;
  @Prop activeSession: boolean = false;
  @Prop runtimeAvailable: boolean = false;
  @Prop adjustmentCount: number = 0;
  @Prop launching: boolean = false;
  @Prop launchFeedback: string = '';
  onCancel: () => void = (): void => {};
  onStart: () => void = (): void => {};
  onOpenSettings: () => void = (): void => {};
  onRetry: () => void = (): void => {};
  onAllowMetered: () => void = (): void => {};

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private result(): MoonlightLaunchPreflightResult {
    return moonlightLaunchPreflight({
      routeValid: this.routeValid,
      hostAvailable: this.hostAvailable,
      certificateChanged: this.certificateChanged,
      identityAvailable: this.identityAvailable,
      appAvailable: this.appAvailable,
      meteredNetwork: this.meteredNetwork,
      meteredAllowed: this.meteredAllowed,
      hostBusy: this.hostBusy,
      activeSession: this.activeSession,
      runtimeAvailable: this.runtimeAvailable,
      adjustmentCount: this.adjustmentCount
    });
  }

  @Builder private summaryRow(label: string, value: string, warning: boolean = false) {
    Row() {
      Text(label).fontSize(13).fontColor(this.pal().text3).fontFamily(AppTheme.fontFamily)
      Blank().layoutWeight(1)
      Text(value).fontSize(13).fontWeight(FontWeight.Medium)
        .fontColor(warning ? this.pal().editColor : this.pal().text)
        .fontFamily(AppTheme.fontFamily)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width('100%').height(34)
  }

  build() {
    Column() {
      Row() {
        Stack({ alignContent: Alignment.Center }) {
          MoonlightBrandIcon({ iconSize: 28, tint: this.accentColor })
        }.width(48).height(48).borderRadius(14).backgroundColor(this.pal().surface)
        Column() {
          Text('确认开始串流').fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
          Text((this.appName || '未选择应用') + ' · ' + (this.hostName || '未知主机'))
            .fontSize(12).fontColor(this.pal().text3).fontFamily(AppTheme.fontFamily)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 4 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
        Button() {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(16).fontColor([this.pal().text2])
        }.width(40).height(40).borderRadius(20).backgroundColor(this.pal().surface)
          .onClick((): void => { this.onCancel(); })
          .accessibilityText('取消启动')
      }.width('100%')

      Column() {
        this.summaryRow('画面', this.resolutionLabel + ' · ' + this.fps.toString() + ' FPS')
        this.summaryRow('编码', this.codecLabel)
        this.summaryRow('音频', this.audioLabel)
        this.summaryRow('控制', this.inputLabel)
        if (this.meteredNetwork) {
          this.summaryRow('网络', this.meteredStateUnknown ? '无法确认是否计费' : '当前为计费网络',
            !this.meteredAllowed)
        }
        if (this.adjustmentCount > 0) {
          this.summaryRow('能力调整', this.adjustmentCount.toString() + ' 项', true)
        }
      }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.pal().surface).borderRadius(16).margin({ top: 18 })

      Row() {
        SymbolGlyph(this.result().allowed ? $r('sys.symbol.checkmark_circle_fill') :
          $r('sys.symbol.exclamationmark_triangle_fill'))
          .fontSize(22).fontColor([this.result().allowed ? this.pal().success : this.pal().editColor])
        Column() {
          Text(this.result().title).fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
          Text(this.result().detail).fontSize(11).fontColor(this.pal().text3)
            .fontFamily(AppTheme.fontFamily).lineHeight(17).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 10 })
      }.width('100%').padding(14).margin({ top: 14 })
        .backgroundColor(this.pal().card).borderRadius(14)
        .border({ width: 0.5, color: this.pal().cardBorder })

      if (this.launching || this.launchFeedback !== '') {
        Row() {
          SymbolGlyph(this.launching ? $r('sys.symbol.hourglass') :
            $r('sys.symbol.exclamationmark_circle_fill'))
            .fontSize(18).fontColor([this.launching ? this.accentColor : this.pal().editColor])
          Text(this.launching ? '正在请求 Sunshine 启动应用，请稍候…' : this.launchFeedback)
            .fontSize(11).fontColor(this.pal().text2).fontFamily(AppTheme.fontFamily)
            .lineHeight(17).layoutWeight(1).margin({ left: 10 })
        }.width('100%').padding(12).margin({ top: 10 })
          .backgroundColor(this.pal().surface).borderRadius(12)
      }

      Column({ space: 10 }) {
        Button('串流设置').height(44).width('100%').fontSize(14)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text).borderRadius(12)
          .enabled(!this.launching)
          .onClick((): void => { this.onOpenSettings(); })
        if (this.result().canRetry) {
          Button('重新检查').height(44).width('100%').fontSize(14)
            .backgroundColor(this.pal().surface).fontColor(this.pal().text).borderRadius(12)
            .onClick((): void => { this.onRetry(); })
        }
        if (this.result().blocker === 'metered_denied' && this.meteredApprovalAvailable) {
          Button('允许本次').height(44).width('100%').fontSize(14)
            .backgroundColor(this.pal().surface).fontColor(this.accentColor).borderRadius(12)
            .onClick((): void => { this.onAllowMetered(); })
        }
        Button(this.launching ? '正在启动…' : '开始串流').height(44).width('100%').fontSize(14)
          .backgroundColor(this.result().allowed && !this.launching ?
            this.accentColor : this.pal().surface)
          .fontColor(this.result().allowed && !this.launching ?
            Color.White : this.pal().text3).borderRadius(12)
          .enabled(this.result().allowed && !this.launching)
          .onClick((): void => {
            if (this.result().allowed && !this.launching) { this.onStart(); }
          })
      }.width('100%').margin({ top: 18 })
    }
    .width('100%')
    .padding({ left: 22, right: 22, top: 22, bottom: 18 })
    .backgroundColor(this.pal().sheetBg)
    .borderRadius({ topLeft: 24, topRight: 24, bottomLeft: 0, bottomRight: 0 })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
