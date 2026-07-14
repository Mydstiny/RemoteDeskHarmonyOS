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
  shouldPresentReleaseNotesAsDialog,
  StartupMode
} from '../services/ReleaseNotesPolicy';
import { CURRENT_RELEASE_VERSION, pagesForReleasedVersion, ReleaseNotePage } from '../services/ReleaseNotesRegistry';
import { firstInstallGuidePages, GuideContentPage } from '../services/GuideContentRegistry';

const GUIDE_KEY = 'guide_shown_v4';
const LAST_SEEN_RELEASE_KEY = 'last_seen_release_version';

@Entry
@Component
struct GuidePage {
  private swiperController: SwiperController = new SwiperController();
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @State currentIndex: number = 0;
  @State showContent: boolean = false;
  @State mode: StartupMode = StartupMode.FIRST_INSTALL_GUIDE;
  @State activePages: GuideContentPage[] = [];
  private tutorialPages: GuideContentPage[] = firstInstallGuidePages();

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
    setTimeout(() => { this.showContent = true; }, 150);
  }

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private presentReleaseNotesAsDialog(): boolean {
    return shouldPresentReleaseNotesAsDialog(this.mode, this.breakpoint);
  }

  private releaseNotesDialogWidth(): number {
    return this.breakpoint === 'xl' ? 640 : 560;
  }

  private releaseNotesDialogHeight(): string {
    return this.breakpoint === 'xl' ? '60%' : '58%';
  }

  build() {
    Stack() {
      if (this.presentReleaseNotesAsDialog()) {
        Column()
          .width('100%').height('100%')
          .backgroundColor('rgba(0,0,0,0.28)')
      }
      Column() {
      Swiper(this.swiperController) {
        ForEach(this.activePages, (page: GuideContentPage, index: number) => {
          Column() {
            Column() {
              Column() {
                Image(page.symbol).width(56).height(56).fillColor(this.accentColor)
              }
              .width(this.currentIndex === index ? 118 : 104)
              .height(this.currentIndex === index ? 118 : 104)
              .borderRadius(32)
              .backgroundColor(this.pal().card)
              .justifyContent(FlexAlign.Center)
              .margin({ bottom: 30 })
              .shadow({ radius: 24, color: this.pal().fabGlow, offsetY: 8 })
              .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
              .scale({ x: this.currentIndex === index ? 1 : 0.8,
                       y: this.currentIndex === index ? 1 : 0.8 })
              .animation({ duration: 250, curve: Curve.EaseOut })

              Text(page.title)
                .fontSize(28).fontWeight(FontWeight.Bold)
                .fontColor(this.pal().text).textAlign(TextAlign.Center)
                .margin({ bottom: 12 })
                .animation({ duration: 200, curve: Curve.EaseOut })

              Text(page.desc)
                .fontSize(15).fontColor(this.pal().text2).textAlign(TextAlign.Center)
                .lineHeight(23).width('82%')
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
      .width('100%').padding({ left: 28, right: 28, bottom: 48, top: 12 })
      }
      .width(this.presentReleaseNotesAsDialog() ? this.releaseNotesDialogWidth() : '100%')
      .height(this.presentReleaseNotesAsDialog() ? this.releaseNotesDialogHeight() : '100%')
      .backgroundColor(this.pal().bg)
      .borderRadius(this.presentReleaseNotesAsDialog() ? 24 : 0)
      .border(this.presentReleaseNotesAsDialog() ?
        { width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid } :
        { width: 0, color: Color.Transparent, style: BorderStyle.Solid })
      .shadow(this.presentReleaseNotesAsDialog() ?
        { radius: 28, color: 'rgba(0,0,0,0.22)', offsetY: 12 } :
        { radius: 0, color: Color.Transparent, offsetY: 0 })
      .align(Alignment.Center)
    }
    .width('100%').height('100%')
    .backgroundColor(this.pal().bg)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  private finish(): void {
    try {
      const prefs = preferences.getPreferencesSync(getContext(this), { name: 'RemoteDesktopAppPrefs' });
      if (this.mode === StartupMode.FIRST_INSTALL_GUIDE) { prefs.putSync(GUIDE_KEY, true); }
      prefs.putSync(LAST_SEEN_RELEASE_KEY, CURRENT_RELEASE_VERSION);
      prefs.flushSync();
    } catch (_e) { /* ignore */ }
    router.replaceUrl({ url: 'pages/LoginPage' });
  }
}
