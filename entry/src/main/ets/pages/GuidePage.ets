/**
 * GuidePage.ets — 应用引导页 (首次安装展示)
 *
 * 内容与设置页「简单使用教程」共享功能介绍，仅收尾页按入口区分。
 */
import { router } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { Palette, buildDark, buildLight } from '../common/Theme';
import {
  resolveStartupMode,
  shouldPresentGuideAsBottomSheet,
  shouldPresentGuideAsCenterSheet,
  StartupMode
} from '../services/ReleaseNotesPolicy';
import { CURRENT_RELEASE_VERSION, pagesForReleasedVersion, ReleaseNotePage } from '../services/ReleaseNotesRegistry';
import {
  clampGuidePageIndex,
  ensureGuidePages,
  firstInstallGuidePages,
  guideDeviceFor,
  GuideContentPage,
  GuideDevice
} from '../services/GuideContentRegistry';

const GUIDE_KEY = 'guide_shown_v4';
const LAST_SEEN_RELEASE_KEY = 'last_seen_release_version';
const GUIDE_SHEET_ENTER_DELAY_MS = 120;
const GUIDE_SHEET_REFLOW_DELAY_MS = 80;
// Set true only during explicit release acceptance to show the update Swiper
// on every launch regardless of the persisted read marker.
const FORCE_RELEASE_NOTES_REVIEW: boolean = false;

@Entry
@Component
struct GuidePage {
  private swiperController: SwiperController = new SwiperController();
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @StorageLink('currentBreakpoint') @Watch('onBreakpointChange') breakpoint: string = 'sm';
  @StorageProp('isDesktopDevice') @Watch('onGuideDeviceChange')
  isDesktopDevice: boolean = false;
  @StorageProp('isPadDevice') @Watch('onGuideDeviceChange')
  isPadDevice: boolean = false;
  @StorageLink('remoteDesktopBgFlag') @Watch('onBackgroundFlagChange') appInBackground: boolean = false;
  @State currentIndex: number = 0;
  @State showContent: boolean = false;
  @State showGuideSheet: boolean = false;
  @State mode: StartupMode = StartupMode.FIRST_INSTALL_GUIDE;
  @State activePages: GuideContentPage[] = firstInstallGuidePages();
  private tutorialPages: GuideContentPage[] = firstInstallGuidePages();
  private isFinishing: boolean = false;
  private guideSheetEnterTimer: number = -1;
  private guideSheetReopenTimer: number = -1;

  async aboutToAppear(): Promise<void> {
    this.refreshTutorialPages();
    try {
      const ctx = getContext(this);
      const prefs = preferences.getPreferencesSync(ctx, { name: 'RemoteDesktopAppPrefs' });
      const shown: boolean = prefs.getSync(GUIDE_KEY, false) as boolean;
      const lastSeen: string = prefs.getSync(LAST_SEEN_RELEASE_KEY, '') as string;
      const releasePages: ReleaseNotePage[] = pagesForReleasedVersion(CURRENT_RELEASE_VERSION);
      this.mode = resolveStartupMode(shown, lastSeen, CURRENT_RELEASE_VERSION,
        releasePages.length > 0, FORCE_RELEASE_NOTES_REVIEW);
      if (this.mode === StartupMode.LOGIN) {
        router.replaceUrl({ url: 'pages/LoginPage' });
        return;
      }
      this.replaceActivePages(
        this.mode === StartupMode.RELEASE_NOTES ? releasePages : this.tutorialPages);
    } catch (_e) { /* 出错继续显示 */ }
    this.replaceActivePages(this.activePages);
    this.cancelGuideSheetEnter();
    this.guideSheetEnterTimer = setTimeout((): void => {
      this.guideSheetEnterTimer = -1;
      this.showContent = true;
      if (!this.appInBackground && this.usesGuideSheet() && !this.isFinishing) {
        this.showGuideSheet = true;
      }
    }, GUIDE_SHEET_ENTER_DELAY_MS);
  }

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private refreshTutorialPages(): void {
    const device: GuideDevice = guideDeviceFor(
      this.isDesktopDevice, this.isPadDevice, this.breakpoint);
    this.tutorialPages = ensureGuidePages(firstInstallGuidePages(device), device);
    if (this.mode === StartupMode.FIRST_INSTALL_GUIDE) {
      this.replaceActivePages(this.tutorialPages);
    }
  }

  private replaceActivePages(pages: GuideContentPage[]): void {
    const fallback: GuideContentPage[] = pages.length > 0 ? pages : this.tutorialPages;
    const nextPages: GuideContentPage[] = ensureGuidePages(fallback);
    this.currentIndex = clampGuidePageIndex(this.currentIndex, nextPages.length);
    this.activePages = nextPages;
  }

  private onBreakpointChange(): void {
    this.refreshTutorialPages();
    if (!this.showContent || this.mode === StartupMode.LOGIN) { return; }
    if (!this.usesGuideSheet() || !this.showGuideSheet) { return; }
    // preferType 在 Sheet 已显示时不会可靠地从 BOTTOM 切换为 CENTER，
    // 折叠/展开或跨窗口断点时先完成原生退出，再按新断点重新打开。
    this.showGuideSheet = false;
  }

  private onGuideDeviceChange(): void {
    // EntryAbility publishes physical-device flags after the first breakpoint.
    // Re-evaluate so PC/Pad do not keep that short-lived fallback selection.
    this.refreshTutorialPages();
  }

  private usesGuideSheet(): boolean {
    // 首次安装引导必须先作为页面首屏渲染。冷启动时系统 bindSheet 可能
    // 尚未完成宿主挂载，若把首屏完全交给 Sheet，挂载竞态会再次呈现白屏。
    // 版本更新说明继续使用既有 Sheet，不改变更新弹窗的显示路径。
    return this.mode === StartupMode.RELEASE_NOTES;
  }

  private onBackgroundFlagChange(): void {
    if (this.appInBackground) {
      this.cancelGuideSheetReopen();
      return;
    }
    if (this.usesGuideSheet() && !this.isFinishing && !this.showGuideSheet) {
      this.scheduleGuideSheetReopen();
    }
  }

  private cancelGuideSheetReopen(): void {
    if (this.guideSheetReopenTimer !== -1) {
      clearTimeout(this.guideSheetReopenTimer);
      this.guideSheetReopenTimer = -1;
    }
  }

  private cancelGuideSheetEnter(): void {
    if (this.guideSheetEnterTimer !== -1) {
      clearTimeout(this.guideSheetEnterTimer);
      this.guideSheetEnterTimer = -1;
    }
  }

  private scheduleGuideSheetReopen(): void {
    if (this.guideSheetReopenTimer !== -1 || this.appInBackground ||
      !this.usesGuideSheet() || this.isFinishing) {
      return;
    }
    this.guideSheetReopenTimer = setTimeout((): void => {
      this.guideSheetReopenTimer = -1;
      if (!this.appInBackground && this.usesGuideSheet() && !this.isFinishing) {
        this.showGuideSheet = true;
      }
    }, GUIDE_SHEET_REFLOW_DELAY_MS);
  }

  private presentGuideAsCenterSheet(): boolean {
    return shouldPresentGuideAsCenterSheet(this.mode, this.breakpoint);
  }

  private presentGuideAsBottomSheet(): boolean {
    return shouldPresentGuideAsBottomSheet(this.mode, this.breakpoint);
  }

  private guideSheetHeight(): string | number {
    // Keep the content below the usable window height on phones and small
    // freeform windows. The pages are intentionally short so the Sheet never
    // needs to grow beyond the viewport just to fit a paragraph.
    if (this.presentGuideAsBottomSheet()) { return '82%'; }
    return this.breakpoint === 'xl' ? 620 : 580;
  }

  @Builder guidePanel(isSheet: boolean) {
    Column() {
      if (this.activePages.length > 0) {
        Swiper(this.swiperController) {
          ForEach(this.activePages, (page: GuideContentPage, index: number) => {
            Column() {
              Column() {
                Column() {
                  Image(page.symbol).width(50).height(50).fillColor(this.accentColor)
                }
                .width(this.currentIndex === index ? 104 : 92)
                .height(this.currentIndex === index ? 104 : 92)
                .borderRadius(28)
                .backgroundColor(this.pal().card)
                .justifyContent(FlexAlign.Center)
                .margin({ bottom: 20 })
                .shadow({ radius: 24, color: this.pal().fabGlow, offsetY: 8 })
                .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
                .scale({ x: this.currentIndex === index ? 1 : 0.8,
                         y: this.currentIndex === index ? 1 : 0.8 })
                .animation({ duration: 250, curve: Curve.EaseOut })

                Text(page.title)
                  .fontSize(24).fontWeight(FontWeight.Bold)
                  .fontColor(this.pal().text).textAlign(TextAlign.Center)
                  .margin({ bottom: 12 })
                  .animation({ duration: 200, curve: Curve.EaseOut })

                Text(page.desc)
                  .fontSize(15).fontColor(this.pal().text2).textAlign(TextAlign.Center)
                  .lineHeight(22).width('88%')
                  .animation({ duration: 200, curve: Curve.EaseOut })
              }
              .width('100%')
            }
            .width('100%').height('100%')
            .justifyContent(FlexAlign.Center)
          }, (page: GuideContentPage) => page.id)
        }
        .loop(false).indicator(false)
        .duration(250).curve(Curve.EaseOut)
        .onChange((i: number) => {
          this.currentIndex = clampGuidePageIndex(i, this.activePages.length);
        })
        .layoutWeight(1)
      } else {
        // 理论上 ensureGuidePages 已阻止空数组；这里保留最终可见兜底，
        // 即使未来注册表或框架状态异常，新用户也不会只看到白屏。
        Column() {
          Image($rawfile('icons/computer-desktop.svg'))
            .width(50).height(50).fillColor(this.accentColor).margin({ bottom: 20 })
          Text('欢迎使用 RemoteDesktop')
            .fontSize(24).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
            .textAlign(TextAlign.Center).margin({ bottom: 12 })
          Text('引导内容暂时无法载入，你仍可立即进入工作台，并从“设置 → 教程”重新打开。')
            .fontSize(15).fontColor(this.pal().text2).textAlign(TextAlign.Center)
            .lineHeight(22).width('88%')
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      }

      Row() {
        Text(this.currentIndex > 0 ? '上一步' :
          (this.mode === StartupMode.FIRST_INSTALL_GUIDE ? '跳过' : ''))
          .fontSize(15).fontColor(this.pal().text3)
          .width(64).textAlign(TextAlign.Start)
          .onClick(() => {
            if (this.currentIndex > 0) { this.swiperController.showPrevious(); }
            else if (this.mode === StartupMode.FIRST_INSTALL_GUIDE) { this.finish(); }
          })

        Blank()

        if (this.activePages.length <= 10) {
          Row({ space: 8 }) {
            ForEach(this.activePages, (_: GuideContentPage, i: number) => {
              Column()
                .width(this.currentIndex === i ? 24 : 8).height(8)
                .borderRadius(4)
                .backgroundColor(this.currentIndex === i ? this.accentColor : this.pal().divider)
                .animation({ duration: 200, curve: Curve.EaseOut })
            }, (page: GuideContentPage) => page.id)
          }
        } else {
          Text((this.currentIndex + 1).toString() + ' / ' + this.activePages.length.toString())
            .fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text3)
        }

        Blank()

        Row() {
          Text(this.currentIndex < this.activePages.length - 1 ? '下一步' :
            (this.mode === StartupMode.RELEASE_NOTES ? '继续' : '立即体验'))
            .fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.accentColor)
          Text(' >').fontSize(14).fontColor(this.accentColor).margin({ left: 2 })
        }
        .width(64).justifyContent(FlexAlign.End)
        .onClick(() => {
          if (this.currentIndex < this.activePages.length - 1) {
            this.swiperController.showNext();
          } else { this.finish(); }
        })
        .opacity(this.showContent ? 1 : 0)
        .animation({ duration: 200, curve: Curve.EaseOut })
      }
      .width('100%').padding({ left: 24, right: 24, bottom: 24, top: 8 })
      }
      // CENTER Sheet 的外框宽度由系统按窗口尺寸决定；这里只设置上限，
      // 不让内部内容在 Pad/PC 小窗口中反向撑大 Sheet。
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: 640, maxHeight: 720 })
      .clip(true)
      .backgroundColor(isSheet ? this.pal().sheetBg : this.pal().bg)
      .borderRadius(this.presentGuideAsCenterSheet() ? 24 : 0)
      .border(this.presentGuideAsCenterSheet() ?
        { width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid } :
        { width: 0, color: Color.Transparent, style: BorderStyle.Solid })
      .align(Alignment.Center)
  }

  @Builder guideSheet() {
    this.guidePanel(true)
  }

  build() {
    Stack() {
      if (this.usesGuideSheet()) {
        // 更新说明由系统 Sheet 承载，底层只需要提供全屏宿主节点。
        Column().width('100%').height('100%').backgroundColor(this.pal().bg)
      } else {
        // 首次安装引导直接占据页面，保证即使 Sheet 首次挂载失败也有可见内容。
        this.guidePanel(false)
      }
    }
    .width('100%').height('100%')
    .backgroundColor(this.pal().bg)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet($$this.showGuideSheet, this.guideSheet(), {
      height: this.guideSheetHeight(),
      preferType: this.presentGuideAsBottomSheet() ? SheetType.BOTTOM : SheetType.CENTER,
      dragBar: this.presentGuideAsBottomSheet(),
      backgroundColor: this.pal().sheetBg,
      blurStyle: BlurStyle.NONE,
      showClose: false,
      maskColor: 'rgba(0,0,0,0.28)',
      onDisappear: (): void => { this.handleGuideSheetDisappear(); }
    })
  }

  aboutToDisappear(): void {
    this.cancelGuideSheetEnter();
    this.cancelGuideSheetReopen();
  }

  private persistCompletion(): void {
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
      if (this.mode === StartupMode.FIRST_INSTALL_GUIDE) { prefs.putSync(GUIDE_KEY, true); }
      prefs.putSync(LAST_SEEN_RELEASE_KEY, CURRENT_RELEASE_VERSION);
      prefs.flushSync();
    } catch (_e) { /* ignore */ }
  }

  private handleGuideSheetDisappear(): void {
    if (this.isFinishing) {
      router.replaceUrl({ url: 'pages/LoginPage' });
      return;
    }
    // 系统弹窗、后台切换或断点变化都可能让 Sheet 先消失；这不代表用户完成了引导。
    this.showGuideSheet = false;
    this.scheduleGuideSheetReopen();
  }

  private finish(): void {
    if (this.isFinishing) { return; }
    this.isFinishing = true;
    this.cancelGuideSheetEnter();
    this.cancelGuideSheetReopen();
    this.persistCompletion();
    if (!this.usesGuideSheet()) {
      // 首次引导不是 Sheet，没有 onDisappear 回调负责路由；完成后直接进入登录页。
      router.replaceUrl({ url: 'pages/LoginPage' });
      return;
    }
    this.showGuideSheet = false;
  }
}
