/**
 * GuidePage.ets — 应用引导页 (首次安装展示)
 *
 * 内容与设置页「简单使用教程」同步, 额外新增最后一页提示可在设置中重新查看.
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

const GUIDE_KEY = 'guide_shown_v4';
const LAST_SEEN_RELEASE_KEY = 'last_seen_release_version';

interface GuidePageData {
  symbol: ResourceStr;
  title: string;
  desc: string;
}

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
  @State activePages: GuidePageData[] = [];

  /** 与 HostListPage.usageGuideItems 同步, 末尾新增 "可重新查看" 提示页 */
  private tutorialPages: GuidePageData[] = [
    {
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: '添加连接',
      desc: '在主机页点击添加，按目标设备选择 RDP、RustDesk 或 SSH。Windows 推荐 RDP，跨平台远控推荐 RustDesk，服务器维护推荐 SSH。'
    },
    {
      symbol: $rawfile('icons/cloud.svg'),
      title: '同步与离线',
      desc: '登录华为账号后可跨设备同步主机、密钥和验证器。选择离线模式时，数据只保存在当前设备。'
    },
    {
      symbol: $rawfile('icons/key.svg'),
      title: '保护密钥',
      desc: '首次使用敏感数据前建议启用端到端加密。主密码丢失无法恢复，请自行妥善保管。'
    },
    {
      symbol: $rawfile('icons/command-line.svg'),
      title: '使用 SSH',
      desc: 'SSH 支持密码、私钥和跳板机。移动端可用虚拟键栏，PC 端可直接使用物理键盘。'
    },
    {
      symbol: $rawfile('icons/folder-open.svg'),
      title: 'SFTP 文件传输',
      desc: '连接 SSH 后点击顶部栏文件图标即可浏览远端目录。支持上传本地文件（最大 512MB）、下载远端文件、新建目录、重命名和删除。选中文件或目录后可用底部操作按钮完成对应操作。'
    },
    {
      symbol: $rawfile('icons/shield-check.svg'),
      title: '连接前检查',
      desc: '确认目标主机已开启对应服务，网络可达，RustDesk 中继配置正确。个人 Microsoft 账户推荐填写邮箱和密码，账号格式使用“MSA域”；企业/学校账号可使用 AzureAD 格式。本地或域账户仍可按 whoami 输出填写。'
    },
    {
      symbol: $rawfile('icons/computer-desktop.svg'),
      title: 'RDP / RustDesk 虚拟触控板',
      desc: '连接 RDP 或 RustDesk 远程桌面后，屏幕即为虚拟触控板。单指轻点为左键，双指轻点为右键，单指停留并移动为左键拖拽。拖拽时光标变为红色提醒，右键时光标变为橙色。三指同时触摸屏幕可唤起控制面板，支持文件传输和拉出虚拟键盘。'
    },
    {
      symbol: $rawfile('icons/cog-6-tooth.svg'),
      title: '随时重新查看',
      desc: '本教程可在 设置 → 关于 → 简单使用教程 中随时重新查看。'
    }
  ];

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
        ForEach(this.activePages, (page: GuidePageData, index: number) => {
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
          ForEach(this.activePages, (_: GuidePageData, i: number) => {
            Column()
              .width(this.currentIndex === i ? 24 : 8).height(8)
              .borderRadius(4)
              .backgroundColor(this.currentIndex === i ? this.accentColor : this.pal().divider)
              .animation({ duration: 200, curve: Curve.EaseOut })
          })
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
