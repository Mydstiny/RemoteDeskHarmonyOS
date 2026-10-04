/**
 * GuidePage.ets — 应用引导页 (首次安装展示)
 *
 * 内容与设置页「简单使用教程」共享功能介绍，仅收尾页按入口区分。
 */
import { promptAction, router } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { Palette, buildDark, buildLight } from '../common/Theme';
import {
  resolveStartupMode,
  shouldPresentGuideAsBottomSheet,
  shouldPresentGuideAsCenterSheet,
  StartupMode
} from '../services/ReleaseNotesPolicy';
import {
  CURRENT_RELEASE_VERSION, pagesForReleasedVersion, releaseHeadline, ReleaseNotePage
} from '../services/ReleaseNotesRegistry';
import { GuideShowcase, WhatsNewList } from '../components/guide/GuideShowcase';
import { ProShowcase } from '../components/guide/ProShowcase';
import { markProTrialStarted } from '../services/pro/ProTrialNotice';
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
  @State releaseItems: ReleaseNotePage[] = [];
  /** 'main' shows the guide or the 「新功能」 list; 'pro' shows the Pro 功能介绍 sheet that closes either flow. */
  @State stage: string = 'main';
  private tutorialPages: GuideContentPage[] = firstInstallGuidePages();
  private isFinishing: boolean = false;
  /** The sheet is being closed only to reopen at a new breakpoint, not dismissed by the user. */
  private reflowingSheet: boolean = false;
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
      this.releaseItems = releasePages;
      this.replaceActivePages(this.tutorialPages);
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
    this.reflowingSheet = true;
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
    // 引导结束后的 Pro 功能介绍也用同一个 Sheet 弹出，此时页面已经有可见内容。
    return this.mode === StartupMode.RELEASE_NOTES || this.stage === 'pro';
  }

  /** Both flows end with the Pro 功能介绍 sheet; its button or dismissal completes the startup guide. */
  private showProIntro(): void {
    if (this.isFinishing || this.stage === 'pro') { return; }
    this.stage = 'pro';
    this.showGuideSheet = true;
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
    if (this.presentGuideAsBottomSheet() || this.proIntroOnPhone()) { return '86%'; }
    return this.breakpoint === 'xl' ? 680 : 620;
  }

  /** The Pro sheet after the first-install guide follows the window size like the release sheet does. */
  private proIntroOnPhone(): boolean {
    return this.stage === 'pro' && this.mode === StartupMode.FIRST_INSTALL_GUIDE && this.breakpoint === 'sm';
  }

  /**
   * First-install intro fills the page; the post-update 「新功能」 list lives in a sheet. Both continue into the
   * Pro 功能介绍 sheet.
   */
  @Builder guidePanel(isSheet: boolean) {
    if (isSheet && this.stage === 'pro') {
      // 1.2.0: everyone has Pro free. The popup's one way out is 立即试用 (it cannot be swiped or backed away).
      ProShowcase({
        actionLabel: '立即试用',
        onAction: (): void => { this.startProTrial(); }
      })
      .width('100%').height('100%')
      .backgroundColor(this.pal().sheetBg)
    } else if (this.mode === StartupMode.RELEASE_NOTES) {
      WhatsNewList({
        version: CURRENT_RELEASE_VERSION,
        headline: releaseHeadline(CURRENT_RELEASE_VERSION),
        items: this.releaseItems,
        primaryLabel: '继续',
        onPrimary: (): void => { this.showProIntro(); }
      })
      .width('100%').height('100%')
      .backgroundColor(isSheet ? this.pal().sheetBg : this.pal().bg)
    } else {
      GuideShowcase({
        pages: this.activePages,
        skipLabel: '跳过',
        finishLabel: '开始使用',
        onFinish: (): void => { this.showProIntro(); },
        onSkip: (): void => { this.showProIntro(); }
      })
      .width('100%').height('100%')
    }
  }

  @Builder guideSheet() {
    this.guidePanel(true)
  }

  build() {
    Stack() {
      if (this.mode === StartupMode.RELEASE_NOTES) {
        // 更新说明由系统 Sheet 承载，底层只需要提供全屏宿主节点。
        Column().width('100%').height('100%').backgroundColor(this.pal().bg)
      } else {
        // 首次安装引导直接占据页面，保证即使 Sheet 首次挂载失败也有可见内容。
        this.guidePanel(false)
      }
    }
    .width('100%').height('100%')
    .backgroundColor(this.pal().bg)
    // The full-page intro keeps its buttons clear of the status and navigation bars.
    .expandSafeArea(this.mode === StartupMode.RELEASE_NOTES ? [SafeAreaType.SYSTEM] : [],
      this.mode === StartupMode.RELEASE_NOTES ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM] : [])
    .bindSheet($$this.showGuideSheet, this.guideSheet(), {
      height: this.guideSheetHeight(),
      preferType: this.presentGuideAsBottomSheet() || this.proIntroOnPhone() ? SheetType.BOTTOM : SheetType.CENTER,
      // No drag bar on the Pro 功能介绍: it is not dismissed by dragging.
      dragBar: (this.presentGuideAsBottomSheet() || this.proIntroOnPhone()) && this.stage !== 'pro',
      backgroundColor: this.pal().sheetBg,
      blurStyle: BlurStyle.NONE,
      showClose: false,
      maskColor: 'rgba(0,0,0,0.28)',
      // The Pro 功能介绍 closes only through 立即试用; finishing, a reflow at a new breakpoint and going to the
      // background still close it as before, and so does everything about the release notes.
      onWillDismiss: (action: DismissSheetAction): void => {
        if (this.stage === 'pro' && !this.isFinishing && !this.reflowingSheet && !this.appInBackground) { return; }
        action.dismiss();
      },
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
    if (this.stage === 'pro' && !this.appInBackground && !this.reflowingSheet) {
      // Swiping the Pro 功能介绍 away is the same as tapping 开始使用.
      this.finish();
      router.replaceUrl({ url: 'pages/LoginPage' });
      return;
    }
    // 系统弹窗、后台切换或断点变化都可能让 Sheet 先消失；这不代表用户完成了引导。
    this.reflowingSheet = false;
    this.showGuideSheet = false;
    this.scheduleGuideSheetReopen();
  }

  /** 立即试用: the trial is on for everyone; record that the user was told, say so, and carry on. */
  private startProTrial(): void {
    markProTrialStarted(getContext(this));
    try {
      promptAction.showToast({ message: '已开启 Pro 免费试用，全部 Pro 功能可以直接使用', duration: 2600 });
    } catch (_error) { /* no toast */ }
    this.finish();
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
