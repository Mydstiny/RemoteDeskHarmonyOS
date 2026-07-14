/**
 * FeedbackSettingsSheet.ets — 反馈子选项卡：邮箱反馈 / 畅联群聊。
 */
import { promptAction } from '@kit.ArkUI';
import { common, Want } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { HdsTabs, HdsTabsController } from '@kit.UIDesignKit';
import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';
import {
  SETTINGS_SUPPORT_EMAIL,
  SETTINGS_SUPPORT_SUBJECT
} from '../services/SettingsAccordionPolicy';
import {
  FeedbackCommunityManifest,
  feedbackCommunityImageUrl,
  feedbackCommunityRemainingText
} from '../services/FeedbackCommunityPolicy';
import { FeedbackCommunityService } from '../services/FeedbackCommunityService';

@Component
export struct FeedbackSettingsSheet {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @StorageProp('breakpoint') breakpoint: string = 'md';

  onClose: () => void = (): void => {};
  onOpenMail: () => void = (): void => {};

  @State community: FeedbackCommunityManifest | null = null;
  @State communityQrPixelMap: image.PixelMap | null = null;
  @State communityLoading: boolean = false;
  @State communityError: string = '';
  @State nowMs: number = Date.now();
  @State savingQr: boolean = false;
  @State activeTab: number = 0;

  private readonly tabsController: HdsTabsController = new HdsTabsController();
  private readonly communityService: FeedbackCommunityService = new FeedbackCommunityService();

  aboutToAppear(): void {
    this.refreshCommunityQr();
  }

  aboutToDisappear(): void {
    this.clearQrPixelMap();
  }

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private font(): string {
    return AppConfig.fontFamily;
  }

  private errorMessage(error: Object): string {
    if (error instanceof Error && error.message !== '') {
      return error.message;
    }
    const details: Record<string, Object> = error as Record<string, Object>;
    const message: Object | undefined = details['message'];
    const code: Object | undefined = details['code'];
    if (typeof message === 'string' && (message as string) !== '') {
      if (typeof code === 'number') {
        return '错误码 ' + (code as number).toString() + '：' + (message as string);
      }
      return message as string;
    }
    return '暂时无法读取云端二维码，请稍后重试。';
  }

  private async refreshCommunityQr(): Promise<void> {
    if (this.communityLoading) { return; }
    this.communityLoading = true;
    this.communityError = '';
    try {
      const manifest: FeedbackCommunityManifest = await this.communityService.fetchManifest();
      const bytes: ArrayBuffer = await this.communityService.downloadQrImage(
        feedbackCommunityImageUrl(manifest)
      );
      const source: image.ImageSource = image.createImageSource(bytes);
      let pixelMap: image.PixelMap;
      try {
        pixelMap = await source.createPixelMap({
          desiredPixelFormat: image.PixelMapFormat.RGBA_8888
        });
      } finally {
        source.release();
      }
      const previousPixelMap: image.PixelMap | null = this.communityQrPixelMap;
      this.communityQrPixelMap = pixelMap;
      this.community = manifest;
      this.nowMs = Date.now();
      this.releasePixelMap(previousPixelMap);
    } catch (error) {
      this.community = null;
      this.clearQrPixelMap();
      this.communityError = this.errorMessage(error as Object);
    } finally {
      this.communityLoading = false;
    }
  }

  private releasePixelMap(pixelMap: image.PixelMap | null): void {
    if (pixelMap === null) { return; }
    try {
      pixelMap.release();
    } catch (_error) {
      // 解码对象释放失败不影响页面关闭或重试。
    }
  }

  private clearQrPixelMap(): void {
    const pixelMap: image.PixelMap | null = this.communityQrPixelMap;
    this.communityQrPixelMap = null;
    this.releasePixelMap(pixelMap);
  }

  private async openJoinLink(): Promise<void> {
    const manifest: FeedbackCommunityManifest | null = this.community;
    if (manifest === null || manifest.joinUrl === '') {
      promptAction.showToast({ message: '当前未配置直接跳转链接，请保存二维码扫描', duration: 2200 });
      return;
    }
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: manifest.joinUrl
      };
      await ctx.startAbility(want);
    } catch (error) {
      promptAction.showToast({ message: '当前设备无法直接打开，请保存二维码后扫描', duration: 2400 });
    }
  }

  private async saveQrImage(result: SaveButtonOnClickResult): Promise<void> {
    if (result !== SaveButtonOnClickResult.SUCCESS) {
      promptAction.showToast({ message: '未获得相册保存授权，请重试', duration: 2200 });
      return;
    }
    const manifest: FeedbackCommunityManifest | null = this.community;
    if (manifest === null || this.savingQr) { return; }
    this.savingQr = true;
    try {
      const bytes: ArrayBuffer = await this.communityService.downloadQrImage(
        feedbackCommunityImageUrl(manifest)
      );
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const helper = photoAccessHelper.getPhotoAccessHelper(ctx);
      const assetChangeRequest: photoAccessHelper.MediaAssetChangeRequest =
        photoAccessHelper.MediaAssetChangeRequest.createAssetRequest(
          ctx,
          photoAccessHelper.PhotoType.IMAGE,
          'jpg',
          { title: '畅联群聊二维码' }
        );
      assetChangeRequest.addResource(photoAccessHelper.ResourceType.IMAGE_RESOURCE, bytes);
      await helper.applyChanges(assetChangeRequest);
      promptAction.showToast({ message: '二维码已保存到相册', duration: 1800 });
    } catch (error) {
      promptAction.showToast({ message: '保存失败：' + this.errorMessage(error as Object), duration: 2400 });
    } finally {
      this.savingQr = false;
    }
  }

  build() {
    Column() {
      Row() {
        Text('反馈').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(this.font())
        Blank()
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
          .width(36).height(36).onClick((): void => { this.onClose(); })
      }.width('100%').padding({ left: 24, right: 20, top: 20 }).margin({ bottom: 4 })

      Text('选择一种方式联系作者或加入用户群').fontSize(13).fontColor(this.pal().text3)
        .fontFamily(this.font()).width('100%').padding({ left: 24, right: 24 }).margin({ bottom: 8 })

      HdsTabs({ controller: this.tabsController }) {
        TabContent() { this.emailContent() }
          .focusable(false).tabBar(this.emailTabBar)
        TabContent() { this.communityContent() }
          .focusable(false).tabBar(this.communityTabBar)
      }
      .barOverlap(false)
      .barPosition(BarPosition.Start)
      .barHeight(52)
      .vertical(false)
      .onChange((index: number): void => { this.activeTab = index; })
      .width('100%').layoutWeight(1)
    }
    .padding({ left: 24, right: 24, bottom: 24 })
    .width('100%')
    .constraintSize({ maxWidth: 620 })
    .height(this.breakpoint === 'sm' ? 560 : 600)
    .backgroundColor(this.pal().bg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .borderRadius(this.breakpoint === 'sm' ?
      { topLeft: 22, topRight: 22, bottomLeft: 0, bottomRight: 0 } : 24)
  }

  @Builder emailTabBar() {
    Column() {
      SymbolGlyph($r('sys.symbol.envelope_fill')).fontSize(18)
        .fontColor([this.activeTab === 0 ? this.accentColor : this.pal().text3])
      Text('邮箱反馈').fontSize(12)
        .fontColor(this.activeTab === 0 ? this.accentColor : this.pal().text3)
        .margin({ top: 3 })
    }.alignItems(HorizontalAlign.Center)
  }

  @Builder communityTabBar() {
    Column() {
      SymbolGlyph($r('sys.symbol.person_2_fill')).fontSize(18)
        .fontColor([this.activeTab === 1 ? this.accentColor : this.pal().text3])
      Text('加入畅联群聊').fontSize(12)
        .fontColor(this.activeTab === 1 ? this.accentColor : this.pal().text3)
        .margin({ top: 3 })
    }.alignItems(HorizontalAlign.Center)
  }

  @Builder emailContent() {
    Scroll() {
      Column() {
        Column() {
          SymbolGlyph($r('sys.symbol.envelope_fill')).fontSize(42)
            .fontColor([this.accentColor])
          Text('通过邮箱反馈').fontSize(21).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text).fontFamily(this.font()).margin({ top: 16 })
          Text('适合提交问题、功能建议和截图。点击后会打开系统邮件编辑器，并自动填写收件人、主题和设备信息。')
            .fontSize(14).lineHeight(22).textAlign(TextAlign.Center)
            .fontColor(this.pal().text2).fontFamily(this.font()).margin({ top: 10 })
        }.width('100%').alignItems(HorizontalAlign.Center)
          .padding({ left: 18, right: 18, top: 34, bottom: 26 })

        Column() {
          Text(SETTINGS_SUPPORT_EMAIL).fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text).fontFamily(this.font())
          Text('主题：' + SETTINGS_SUPPORT_SUBJECT).fontSize(12)
            .fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 6 })
        }.width('100%').alignItems(HorizontalAlign.Start)
          .padding(16).borderRadius(16).backgroundColor(this.pal().surface)

        Button('打开邮件编辑器').width('100%').height(46).fontSize(15)
          .backgroundColor(this.accentColor).fontColor(Color.White).borderRadius(14)
          .margin({ top: 18, bottom: 24 }).onClick((): void => { this.onOpenMail(); })
      }.width('100%')
    }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
  }

  @Builder communityContent() {
    Scroll() {
      Column() {
        if (this.communityLoading) {
          Column() {
            LoadingProgress().width(36).height(36).color(this.accentColor)
            Text('正在获取最新二维码…').fontSize(14).fontColor(this.pal().text2)
              .fontFamily(this.font()).margin({ top: 14 })
          }.width('100%').height(360).justifyContent(FlexAlign.Center)
        } else if (this.communityError !== '') {
          Column() {
            SymbolGlyph($r('sys.symbol.exclamationmark_triangle')).fontSize(42)
              .fontColor([this.pal().text3])
            Text('二维码暂时不可用').fontSize(17).fontWeight(FontWeight.Medium)
              .fontColor(this.pal().text).fontFamily(this.font()).margin({ top: 14 })
            Text(this.communityError).fontSize(13).lineHeight(20).textAlign(TextAlign.Center)
              .fontColor(this.pal().text2).fontFamily(this.font()).margin({ top: 8 })
            Button('重新获取').width(150).height(42).fontSize(14)
              .backgroundColor(this.accentColor).fontColor(Color.White).borderRadius(12)
              .margin({ top: 18 }).onClick((): void => { this.refreshCommunityQr(); })
          }.width('100%').height(360).justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
        } else if (this.community !== null && this.communityQrPixelMap !== null) {
          Text(this.community.title).fontSize(20).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text).fontFamily(this.font()).margin({ top: 18, bottom: 6 })
          Text(this.community.notice).fontSize(13).lineHeight(20).textAlign(TextAlign.Center)
            .fontColor(this.pal().text2).fontFamily(this.font()).width('100%')
          Column() {
            Image(this.communityQrPixelMap)
              .width(this.breakpoint === 'sm' ? 250 : 286)
              .height(this.breakpoint === 'sm' ? 250 : 286)
              .objectFit(ImageFit.Contain)
          }.padding(12).margin({ top: 16 }).backgroundColor(Color.White)
            .borderRadius(18).shadow({ radius: 12, color: 'rgba(0,0,0,0.12)', offsetY: 4 })
          Text(feedbackCommunityRemainingText(this.community.expiresAt, this.nowMs))
            .fontSize(12).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 10 })
          Row() {
            Row() {
              SaveButton().width('100%').height(42)
                .onClick((_event: ClickEvent, result: SaveButtonOnClickResult): void => {
                  this.saveQrImage(result);
                })
            }.layoutWeight(1)
            if (this.community.joinUrl !== '') {
              Button('直接打开').height(42).layoutWeight(1).fontSize(14)
                .backgroundColor(this.accentColor).fontColor(Color.White).borderRadius(12)
                .margin({ left: 10 }).onClick((): void => { this.openJoinLink(); })
            }
          }.width('100%').margin({ top: 16, bottom: 24 })
        }
      }.width('100%').alignItems(HorizontalAlign.Center)
    }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
  }
}
