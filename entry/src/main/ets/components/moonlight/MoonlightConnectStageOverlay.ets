import { MoonlightSessionErrorCode, MoonlightSessionPhase } from '../../services/MoonlightSessionState';
import {
  MoonlightConnectStagePresentation,
  moonlightConnectStagePresentation
} from '../../services/MoonlightUiPolicy';
import { MoonlightBrandIcon } from './MoonlightBrandIcon';

@Component
export struct MoonlightConnectStageOverlay {
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @Prop sheetBackgroundColor: string = 'rgba(14,18,28,0.90)';
  @Prop phase: MoonlightSessionPhase = 'negotiating';
  @Prop elapsedMs: number = 0;
  @Prop firstFrameSeen: boolean = false;
  @Prop errorCode: MoonlightSessionErrorCode = 'none';
  @Prop degradationReasons: string[] = [];
  @Prop inSheet: boolean = false;
  @State private detailsExpanded: boolean = false;
  onCancel: () => void = (): void => {};
  onRetry: () => void = (): void => {};
  onDowngradeRetry: () => void = (): void => {};
  onOpenDiagnostics: () => void = (): void => {};
  onBackToCatalog: () => void = (): void => {};

  private presentation(): MoonlightConnectStagePresentation {
    return moonlightConnectStagePresentation(
      this.phase, this.elapsedMs, this.firstFrameSeen, this.errorCode);
  }

  build() {
    // This Sheet is only a connection/authentication gate. Terminal failures
    // are handled by the stream route and return directly to the catalog, so
    // the old failure dialog cannot flash during an intentional disconnect.
    if (this.presentation().visible && !this.presentation().terminal) {
      Column() {
        Row() {
          MoonlightBrandIcon({ iconSize: 30, tint: this.accentColor })
          Column() {
            Text(this.presentation().title).fontSize(17).fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
            Text(this.presentation().detail).fontSize(12).fontColor('rgba(255,255,255,0.70)')
              .lineHeight(18).margin({ top: 4 })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })
          LoadingProgress().width(26).height(26).color(this.accentColor)
        }.width('100%')

        if (this.presentation().showElapsed) {
          Row() {
            Text('已等待 ' + Math.ceil(this.elapsedMs / 1000).toString() + ' 秒')
              .fontSize(11).fontColor('rgba(255,255,255,0.62)')
            Blank().layoutWeight(1)
            if (this.degradationReasons.length > 0) {
              Text(this.degradationReasons.length.toString() + ' 项能力降级')
                .fontSize(11).fontColor('#FFCF70')
            }
          }.width('100%').margin({ top: 14 })
        }

        if (this.detailsExpanded) {
          Column() {
            Text('阶段：' + this.phase).fontSize(11).fontColor('#FFFFFF').fontFamily('monospace')
            Text('错误：' + this.errorCode).fontSize(11).fontColor('rgba(255,255,255,0.72)')
              .fontFamily('monospace').margin({ top: 4 })
            Text('技术信息已脱敏，不包含地址、PIN、证书或会话密钥。')
              .fontSize(10).fontColor('rgba(255,255,255,0.55)').margin({ top: 8 })
          }.alignItems(HorizontalAlign.Start).width('100%').padding(12).margin({ top: 12 })
            .backgroundColor('rgba(255,255,255,0.08)').borderRadius(12)
        }

        Row() {
          Button('取消').height(40).layoutWeight(1).borderRadius(10)
            .backgroundColor('rgba(255,255,255,0.12)').fontColor('#FFFFFF')
            .onClick((): void => { this.onCancel(); })
          if (this.presentation().showDiagnostics) {
            Button('网络诊断').height(40).layoutWeight(1).borderRadius(10)
              .backgroundColor('rgba(255,255,255,0.12)').fontColor('#FFFFFF').margin({ left: 10 })
              .onClick((): void => { this.onOpenDiagnostics(); })
          }
          Button(this.detailsExpanded ? '收起详情' : '技术详情').height(40).layoutWeight(1)
            .borderRadius(10).backgroundColor('rgba(255,255,255,0.12)').fontColor('#FFFFFF')
            .margin({ left: 10 }).onClick((): void => { this.detailsExpanded = !this.detailsExpanded; })
        }.width('100%').margin({ top: 16 })
      }
      .width(this.inSheet ? '100%' : '88%').constraintSize({ maxWidth: 560 })
      .padding(20).backgroundColor(this.sheetBackgroundColor).borderRadius(20)
      .border({ width: 1, color: 'rgba(255,255,255,0.14)' })
      .shadow({ radius: 24, color: 'rgba(0,0,0,0.40)', offsetY: 8 })
      .accessibilityGroup(true)
    }
  }
}
