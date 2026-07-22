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
  shouldPresentGuideAsDialog,
  StartupMode
} from '../services/ReleaseNotesPolicy';
import { CURRENT_RELEASE_VERSION, pagesForReleasedVersion, ReleaseNotePage } from '../services/ReleaseNotesRegistry';
import { firstInstallGuidePages, GuideContentPage } from '../services/GuideContentRegistry';

const GUIDE_KEY = 'guide_shown_v4';
const LAST_SEEN_RELEASE_KEY = 'last_seen_release_version';
const RELEASE_DIALOG_ENTER_DELAY_MS = 120;
const GUIDE_SHEET_REFLOW_DELAY_MS = 80;

@Entry
@Component
struct GuidePage {
  private swiperController: SwiperController = new SwiperController();
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @StorageLink('currentBreakpoint') @Watch('onBreakpointChange') breakpoint: string = 'sm';
  @State currentIndex: number = 0;
  @State showContent: boolean = false;
  @State showGuideSheet: boolean = false;
  @State mode: StartupMode = StartupMode.FIRST_INSTALL_GUIDE;
  @State activePages: GuideContentPage[] = [];
  private tutorialPages: GuideContentPage[] = firstInstallGuidePages();
  private isFinishing: boolean = false;
  private isReflowingGuideSheet: boolean = false;

  async aboutToAppear(): Promise<void> {
    try {
      const ctx = getContext(this);
      const prefs = preferences.getPreferencesSync(ctx, { name: 'RemoteDesktopAppPrefs' });
      const shown: boolean = prefs.getSync(GUIDE_KEY, false) as boolean;
      const lastSeen: string = prefs.getSync(LAST_SEEN_RELEASE_KEY, '') as string;
      const releasePages: ReleaseNotePage[] = pagesForReleasedVersion(CURRENT_RELEASE_VERSION);
      this.mode = resolveStartupMode(shown, lastSeen, CURRENT_RELEASE_VERSION, releasePages.length > 0);
      if (this.mode === StartupMode.LOGIN) {
        router.replaceUrl({ url: 'pages/LoginPage' });
        return;
      }
      this.activePages = this.mode === StartupMode.RELEASE_NOTES ? releasePages : this.tutorialPages;
    } catch (_e) { /* 出错继续显示 */ }
    if (this.activePages.length === 0) { this.activePages = this.tutorialPages; }
    setTimeout(() => {
      this.showContent = true;
      this.showGuideSheet = true;
    }, RELEASE_DIALOG_ENTER_DELAY_MS);
  }

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private onBreakpointChange(): void {
    if (!this.showContent || this.mode === StartupMode.LOGIN) { return; }
    if (!this.showGuideSheet) { return; }
    // preferType 在 Sheet 已显示时不会可靠地从 BOTTOM 切换为 CENTER，
    // 折叠/展开或跨窗口断点时先完成原生退出，再按新断点重新打开。
    this.isReflowingGuideSheet = true;
    this.showGuideSheet = false;
  }

  private presentGuideAsDialog(): boolean {
    return shouldPresentGuideAsDialog(this.mode, this.breakpoint);
  }

  private presentGuideAsBottomSheet(): boolean {
    return shouldPresentGuideAsBottomSheet(this.mode, this.breakpoint);
  }

  private guideSheetHeight(): string | number {
    // Keep the content below the usable window height on phones and small
    // freeform windows. The pages are intentionally short so the Sheet never
    // needs to grow beyond the viewport just to fit a paragraph.
    if (this.presentGuideAsBottomSheet()) { return '76%'; }
    return this.breakpoint === 'xl' ? 560 : 520;
  }

  @Builder guidePanel() {
    Column() {
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
        })
      }
      .loop(false).indicator(false)
      .duration(250).curve(Curve.EaseOut)
      .onChange((i: number) => { this.currentIndex = i; })
      .layoutWeight(1)

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

        Row({ space: 8 }) {
          ForEach(this.activePages, (_: GuideContentPage, i: number) => {
            Column()
              .width(this.currentIndex === i ? 24 : 8).height(8)
              .borderRadius(4)
              .backgroundColor(this.currentIndex === i ? this.accentColor : this.pal().divider)
              .animation({ duration: 200, curve: Curve.EaseOut })
          }, (page: GuideContentPage) => page.id)
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
      .backgroundColor(this.pal().sheetBg)
      .borderRadius(this.presentGuideAsDialog() ? 24 : 0)
      .border(this.presentGuideAsDialog() ?
        { width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid } :
        { width: 0, color: Color.Transparent, style: BorderStyle.Solid })
      .align(Alignment.Center)
  }

  @Builder guideSheet() {
    this.guidePanel()
  }

  build() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor(this.pal().bg)
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

  private persistCompletion(): void {
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
      if (this.mode === StartupMode.FIRST_INSTALL_GUIDE) { prefs.putSync(GUIDE_KEY, true); }
      prefs.putSync(LAST_SEEN_RELEASE_KEY, CURRENT_RELEASE_VERSION);
      prefs.flushSync();
    } catch (_e) { /* ignore */ }
  }

  private handleGuideSheetDisappear(): void {
    if (this.isReflowingGuideSheet) {
      this.isReflowingGuideSheet = false;
      setTimeout((): void => {
        if (!this.isFinishing && this.mode !== StartupMode.LOGIN) { this.showGuideSheet = true; }
      }, GUIDE_SHEET_REFLOW_DELAY_MS);
      return;
    }
    if (!this.isFinishing) {
      this.isFinishing = true;
      this.persistCompletion();
    }
    router.replaceUrl({ url: 'pages/LoginPage' });
  }

  private finish(): void {
    if (this.isFinishing) { return; }
    this.isFinishing = true;
    this.persistCompletion();
    this.showGuideSheet = false;
  }
}
