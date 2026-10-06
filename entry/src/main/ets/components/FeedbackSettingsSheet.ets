/**
 * FeedbackSettingsSheet.ets — 反馈子选项卡：邮箱反馈 / 畅联群聊 / Pro 反馈。
 */
import { promptAction } from '@kit.ArkUI';
import { appUiOnAccentText } from '../common/AppUiColorPolicy';
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
import {
  PRO_FEEDBACK_CHANLIAN_MANIFEST_URL,
  PRO_FEEDBACK_FEATURE,
  PRO_FEEDBACK_QQ_MANIFEST_URL
} from '../services/pro/ProFeedbackPolicy';
import { ProEntries } from '../services/pro/ProEntries';
import { ProBadge } from './ProBadge';

const FEEDBACK_QR_DECODE_EDGE: number = 640;

@Component
export struct FeedbackSettingsSheet {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'md';

  onClose: () => void = (): void => {};
  onOpenMail: () => void = (): void => {};

  @State community: FeedbackCommunityManifest | null = null;
  @State communityQrPixelMap: image.PixelMap | null = null;
  @State communityLoading: boolean = false;
  @State communityError: string = '';
  @State nowMs: number = Date.now();
  @State savingQr: boolean = false;
  @State activeTab: number = 0;
  @State proFeedbackVisible: boolean = false;
  @State proChanlian: FeedbackCommunityManifest | null = null;
  @State proChanlianQrPixelMap: image.PixelMap | null = null;
  @State proChanlianError: string = '';
  @State proQq: FeedbackCommunityManifest | null = null;
  @State proQqQrPixelMap: image.PixelMap | null = null;
  @State proQqError: string = '';
  @State proLoading: boolean = false;

  private readonly tabsController: HdsTabsController = new HdsTabsController();
  private readonly communityService: FeedbackCommunityService = new FeedbackCommunityService();
  private communityLoadEpoch: number = 0;
  private proLoadEpoch: number = 0;
  private proStop: (() => void) | null = null;

  aboutToAppear(): void {
    this.communityLoadEpoch++;
    this.community = null;
    this.clearQrPixelMap();
    this.communityLoading = false;
    this.communityError = '';
    this.nowMs = Date.now();
    this.refreshCommunityQr();
    this.proFeedbackVisible = ProEntries.visible(PRO_FEEDBACK_FEATURE);
    this.proStop?.();
    this.proStop = ProEntries.subscribe((): void => {
      const visible: boolean = ProEntries.visible(PRO_FEEDBACK_FEATURE);
      this.proFeedbackVisible = visible;
      if (!visible) {
        // Entitlement revocation must discard in-memory QR state before a later
        // restore; a restored Pro account should fetch a fresh manifest.
        this.proLoadEpoch++;
        this.proLoading = false;
        this.proChanlian = null;
        this.proQq = null;
        this.proChanlianError = '';
        this.proQqError = '';
        this.clearProQrPixelMaps();
        if (this.activeTab === 2) { this.activeTab = 0; }
      }
      if (visible && this.proChanlian === null && !this.proLoading) {
        void this.refreshProQr();
      }
    });
  }

  aboutToDisappear(): void {
    this.communityLoadEpoch++;
    this.proLoadEpoch++;
    this.communityLoading = false;
    this.proLoading = false;
    this.proStop?.();
    this.proStop = null;
    this.clearQrPixelMap();
    this.proChanlian = null;
    this.proQq = null;
    this.proChanlianError = '';
    this.proQqError = '';
    this.clearProQrPixelMaps();
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
    const loadEpoch: number = this.communityLoadEpoch;
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
          desiredSize: this.qrDecodeSize(source),
          desiredPixelFormat: image.PixelMapFormat.RGBA_8888
        });
      } finally {
        source.release();
      }
      if (loadEpoch !== this.communityLoadEpoch) {
        this.releasePixelMap(pixelMap);
        return;
      }
      const previousPixelMap: image.PixelMap | null = this.communityQrPixelMap;
      this.communityQrPixelMap = pixelMap;
      this.community = manifest;
      this.nowMs = Date.now();
      this.releasePixelMap(previousPixelMap);
    } catch (error) {
      if (loadEpoch !== this.communityLoadEpoch) { return; }
      this.community = null;
      this.clearQrPixelMap();
      this.communityError = this.errorMessage(error as Object);
    } finally {
      if (loadEpoch === this.communityLoadEpoch) {
        this.communityLoading = false;
      }
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

  /** Downsample large QR images without changing their aspect ratio. */
  private qrDecodeSize(source: image.ImageSource): image.Size {
    const size: image.Size = source.getImageInfoSync().size;
    const longestEdge: number = Math.max(size.width, size.height);
    if (longestEdge <= FEEDBACK_QR_DECODE_EDGE) {
      return { width: size.width, height: size.height };
    }
    const scale: number = FEEDBACK_QR_DECODE_EDGE / longestEdge;
    return {
      width: Math.max(1, Math.round(size.width * scale)),
      height: Math.max(1, Math.round(size.height * scale))
    };
  }

  private clearQrPixelMap(): void {
    const pixelMap: image.PixelMap | null = this.communityQrPixelMap;
    this.communityQrPixelMap = null;
    this.releasePixelMap(pixelMap);
  }

  private proVisible(): boolean {
    return this.proFeedbackVisible && ProEntries.visible(PRO_FEEDBACK_FEATURE);
  }

  private clearProQrPixelMaps(): void {
    const chanlian: image.PixelMap | null = this.proChanlianQrPixelMap;
    const qq: image.PixelMap | null = this.proQqQrPixelMap;
    this.proChanlianQrPixelMap = null;
    this.proQqQrPixelMap = null;
    this.releasePixelMap(chanlian);
    this.releasePixelMap(qq);
  }

  private async loadProChannel(manifestUrl: string, channel: string, epoch: number): Promise<void> {
    try {
      const manifest: FeedbackCommunityManifest = await this.communityService.fetchManifest(manifestUrl);
      const bytes: ArrayBuffer = await this.communityService.downloadQrImage(
        feedbackCommunityImageUrl(manifest)
      );
      const source: image.ImageSource = image.createImageSource(bytes);
      let pixelMap: image.PixelMap;
      try {
        pixelMap = await source.createPixelMap({
          desiredSize: this.qrDecodeSize(source),
          desiredPixelFormat: image.PixelMapFormat.RGBA_8888
        });
      } finally {
        source.release();
      }
      if (epoch !== this.proLoadEpoch || !this.proVisible()) {
        this.releasePixelMap(pixelMap);
        return;
      }
      if (channel === 'chanlian') {
        const previous: image.PixelMap | null = this.proChanlianQrPixelMap;
        this.proChanlian = manifest;
        this.proChanlianQrPixelMap = pixelMap;
        this.proChanlianError = '';
        this.releasePixelMap(previous);
      } else {
        const previous: image.PixelMap | null = this.proQqQrPixelMap;
        this.proQq = manifest;
        this.proQqQrPixelMap = pixelMap;
        this.proQqError = '';
        this.releasePixelMap(previous);
      }
      this.nowMs = Date.now();
    } catch (error) {
      if (epoch !== this.proLoadEpoch) { return; }
      const message: string = this.errorMessage(error as Object);
      if (channel === 'chanlian') {
        this.proChanlian = null;
        this.releasePixelMap(this.proChanlianQrPixelMap);
        this.proChanlianQrPixelMap = null;
        this.proChanlianError = '畅联二维码：' + message;
      } else {
        this.proQq = null;
        this.releasePixelMap(this.proQqQrPixelMap);
        this.proQqQrPixelMap = null;
        this.proQqError = 'QQ 二维码：' + message;
      }
    }
  }

  private async refreshProQr(): Promise<void> {
    if (this.proLoading || !this.proVisible()) { return; }
    this.proLoading = true;
    const epoch: number = ++this.proLoadEpoch;
    this.proChanlian = null;
    this.proQq = null;
    this.proChanlianError = '';
    this.proQqError = '';
    this.clearProQrPixelMaps();
    try {
      await Promise.all([
        this.loadProChannel(PRO_FEEDBACK_CHANLIAN_MANIFEST_URL, 'chanlian', epoch),
        this.loadProChannel(PRO_FEEDBACK_QQ_MANIFEST_URL, 'qq', epoch)
      ]);
    } finally {
      if (epoch === this.proLoadEpoch) { this.proLoading = false; }
    }
  }

  private proManifestIsCurrent(
    current: FeedbackCommunityManifest,
    latest: FeedbackCommunityManifest
  ): boolean {
    return current.version === latest.version && current.qrImageUrl === latest.qrImageUrl &&
      current.expiresAt === latest.expiresAt;
  }

  private async saveProQrImage(
    result: SaveButtonOnClickResult,
    current: FeedbackCommunityManifest | null,
    manifestUrl: string,
    title: string
  ): Promise<void> {
    if (result !== SaveButtonOnClickResult.SUCCESS) {
      promptAction.showToast({ message: '未获得相册保存授权，请重试', duration: 2200 });
      return;
    }
    if (current === null || !this.proVisible() || this.savingQr) { return; }
    this.savingQr = true;
    try {
      const latest: FeedbackCommunityManifest = await this.communityService.fetchManifest(manifestUrl);
      if (!this.proVisible()) { return; }
      if (!this.proManifestIsCurrent(current, latest) || latest.expiresAt <= Date.now()) {
        await this.refreshProQr();
        throw new Error('二维码已更新或过期，已刷新，请重试保存');
      }
      const bytes: ArrayBuffer = await this.communityService.downloadQrImage(
        feedbackCommunityImageUrl(latest)
      );
      if (!this.proVisible()) { return; }
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const helper = photoAccessHelper.getPhotoAccessHelper(ctx);
      const request: photoAccessHelper.MediaAssetChangeRequest =
        photoAccessHelper.MediaAssetChangeRequest.createAssetRequest(
          ctx, photoAccessHelper.PhotoType.IMAGE, 'jpg', { title: title });
      request.addResource(photoAccessHelper.ResourceType.IMAGE_RESOURCE, bytes);
      await helper.applyChanges(request);
      if (this.proVisible()) {
        promptAction.showToast({ message: '二维码已保存到相册', duration: 1800 });
      }
    } catch (error) {
      promptAction.showToast({ message: '保存失败：' + this.errorMessage(error as Object), duration: 2400 });
    } finally {
      this.savingQr = false;
    }
  }

  private communityManifestIsCurrent(
    current: FeedbackCommunityManifest,
    latest: FeedbackCommunityManifest
  ): boolean {
    return current.version === latest.version &&
      current.qrImageUrl === latest.qrImageUrl &&
      current.expiresAt === latest.expiresAt;
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
      if (manifest.expiresAt <= Date.now()) {
        await this.refreshCommunityQr();
        throw new Error('二维码已过期，已刷新，请重试保存');
      }
      // 保存前重新读取清单，防止用户打开页面后服务器已经轮换二维码。
      const latest: FeedbackCommunityManifest = await this.communityService.fetchManifest();
      if (!this.communityManifestIsCurrent(manifest, latest)) {
        await this.refreshCommunityQr();
        throw new Error('二维码已更新，已刷新，请使用最新二维码重试');
      }
      const bytes: ArrayBuffer = await this.communityService.downloadQrImage(
        feedbackCommunityImageUrl(latest)
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
        if (this.proFeedbackVisible) {
          TabContent() { this.proFeedbackContent() }
            .focusable(false).tabBar(this.proFeedbackTabBar)
        }
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
    // The host sheet sets the height (fitted to the window); the tabs scroll inside it.
    .height('100%')
    .backgroundColor(this.pal().sheetBg)
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

  @Builder proFeedbackTabBar() {
    Column() {
      SymbolGlyph($r('sys.symbol.person_2_fill')).fontSize(18)
        .fontColor([this.activeTab === 2 ? this.accentColor : this.pal().text3])
      Row({ space: 4 }) {
        Text('Pro反馈').fontSize(12)
          .fontColor(this.activeTab === 2 ? this.accentColor : this.pal().text3)
        ProBadge({ large: false })
      }.margin({ top: 3 })
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
          .backgroundColor(this.accentColor).fontColor(appUiOnAccentText(this.accentColor)).borderRadius(14)
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
              .backgroundColor(this.accentColor).fontColor(appUiOnAccentText(this.accentColor)).borderRadius(12)
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
          Button('刷新').height(32).fontSize(12).backgroundColor(Color.Transparent)
            .fontColor(this.accentColor).onClick((): void => { this.refreshCommunityQr(); })
          Row() {
            Row() {
              SaveButton().width('100%').height(42)
                .onClick((_event: ClickEvent, result: SaveButtonOnClickResult): void => {
                  this.saveQrImage(result);
                })
            }.layoutWeight(1)
            if (this.community.joinUrl !== '') {
              Button('直接打开').height(42).layoutWeight(1).fontSize(14)
                .backgroundColor(this.accentColor).fontColor(appUiOnAccentText(this.accentColor)).borderRadius(12)
                .margin({ left: 10 }).onClick((): void => { this.openJoinLink(); })
            }
          }.width('100%').margin({ top: 16, bottom: 24 })
        }
      }.width('100%').alignItems(HorizontalAlign.Center)
    }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
  }

  @Builder proChannelCard(
    title: string,
    scannerHint: string,
    manifest: FeedbackCommunityManifest | null,
    pixelMap: image.PixelMap | null,
    error: string,
    manifestUrl: string,
    saveTitle: string
  ) {
    Column() {
      Text(title).fontSize(18).fontWeight(FontWeight.Medium)
        .fontColor(this.pal().text).fontFamily(this.font()).margin({ top: 14, bottom: 5 })
      if (manifest !== null && pixelMap !== null) {
        Text(manifest.notice + ' ' + scannerHint).fontSize(12).lineHeight(18)
          .textAlign(TextAlign.Center).fontColor(this.pal().text2).fontFamily(this.font())
          .width('100%').padding({ left: 8, right: 8 })
        Column() {
          Image(pixelMap)
            .width(this.breakpoint === 'sm' ? 220 : 248)
            .height(this.breakpoint === 'sm' ? 220 : 248)
            .objectFit(ImageFit.Contain)
        }.padding(10).margin({ top: 12 }).backgroundColor(Color.White).borderRadius(16)
          .shadow({ radius: 10, color: 'rgba(0,0,0,0.12)', offsetY: 3 })
        Text(feedbackCommunityRemainingText(manifest.expiresAt, this.nowMs))
          .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 8 })
        Row() {
          SaveButton().width('100%').height(40)
            .onClick((_event: ClickEvent, result: SaveButtonOnClickResult): void => {
              this.saveProQrImage(result, manifest, manifestUrl, saveTitle);
            })
        }.width('100%').margin({ top: 12, bottom: 16 })
      } else if (error !== '') {
        Text(error).fontSize(13).lineHeight(20).textAlign(TextAlign.Center)
          .fontColor(this.pal().text2).fontFamily(this.font()).width('100%')
          .padding({ left: 12, right: 12, bottom: 18 })
      } else {
        LoadingProgress().width(28).height(28).color(this.accentColor).margin({ top: 24, bottom: 24 })
      }
    }.width('100%').alignItems(HorizontalAlign.Center)
      .backgroundColor(this.pal().surface).borderRadius(18)
  }

  @Builder proFeedbackContent() {
    Scroll() {
      Column({ space: 12 }) {
        Text('Pro 专属反馈').fontSize(20).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(this.font()).margin({ top: 14, bottom: 2 })
        Text('可任选畅联群或 QQ 群加入；二维码会按清单有效期轮换。')
          .fontSize(13).lineHeight(20).textAlign(TextAlign.Center)
          .fontColor(this.pal().text2).fontFamily(this.font()).width('100%')
          .padding({ left: 8, right: 8, bottom: 4 })
        if (!this.proVisible()) {
          Text('Pro 权益已失效，请刷新账号状态后重试。').fontSize(13)
            .fontColor(this.pal().text2).margin({ top: 24, bottom: 24 })
        } else {
          this.proChannelCard('Pro 畅联群', '请使用畅连扫描。', this.proChanlian,
            this.proChanlianQrPixelMap, this.proChanlianError,
            PRO_FEEDBACK_CHANLIAN_MANIFEST_URL, 'Pro 畅联群二维码')
          this.proChannelCard('Pro QQ 群', '请使用 QQ 扫描。', this.proQq,
            this.proQqQrPixelMap, this.proQqError,
            PRO_FEEDBACK_QQ_MANIFEST_URL, 'Pro QQ 群二维码')
          Button('刷新全部二维码').height(38).fontSize(13)
            .backgroundColor(Color.Transparent).fontColor(this.accentColor)
            .onClick((): void => { void this.refreshProQr(); })
        }
      }.width('100%').padding({ left: 24, right: 24, bottom: 24 })
    }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
  }
}
