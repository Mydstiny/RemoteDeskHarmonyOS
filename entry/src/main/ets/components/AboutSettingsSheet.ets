/**
 * AboutSettingsSheet.ets — 关于应用/使用教程/实操教程/隐私政策/前置操作 (T-200 Step 2)
 *
 * 从 HostListPage.ets 提取。接收 aboutSheetMode 和关闭回调，
 * 通过 @StorageLink/@StorageProp 接入主题系统。
 */
import { common, Want } from '@kit.AbilityKit';
import { AppConfig, AppTheme, Palette, buildLight, buildDark } from '../common/Theme';
import { GUIDE_ALWAYS_VISIBLE_STORAGE_KEY } from '../services/GuideVisibilityPolicy';
import { GuideVisibilityService } from '../services/GuideVisibilityService';
import {
  guideDeviceFor,
  guideDeviceLabel,
  guideDeviceSummary,
  GuideDevice,
  GuideContentPage,
  GuideLesson,
  guideLessonsFor,
  GuideProtocol,
  GuideProtocolOption,
  guideProtocolOptions,
  settingsUsageGuidePages
} from '../services/GuideContentRegistry';
import {
  CURRENT_RELEASE_VERSION,
  pagesForReleasedVersion,
  ReleaseNotePage
} from '../services/ReleaseNotesRegistry';

@Component
export struct AboutSettingsSheet {
  @Prop aboutSheetMode: number = 0;
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @StorageProp('isPadDevice') isPadDevice: boolean = false;
  @StorageLink(GUIDE_ALWAYS_VISIBLE_STORAGE_KEY) guideAlwaysVisible: boolean = false;
  onClose: () => void = (): void => {};

  @State usageGuideIndex: number = 0;
  private usageGuideController: SwiperController = new SwiperController();
  @State guideDevice: GuideDevice = 'phone';
  @State guideProtocol: GuideProtocol = 'all';
  @State expandedGuideLessonId: string = 'common-first-host';
  @State releaseNotesIndex: number = 0;
  private releaseNotesController: SwiperController = new SwiperController();
  private readonly releaseNotesItems: ReleaseNotePage[] =
    pagesForReleasedVersion(CURRENT_RELEASE_VERSION);

  aboutToAppear(): void {
    this.guideDevice = guideDeviceFor(
      this.isDesktopDevice, this.isPadDevice, this.breakpoint);
  }

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private font(): string {
    return AppConfig.fontFamily;
  }

  private usageGuideHeight(): number {
    // The settings Sheet is FIT_CONTENT. Keep the Swiper bounded so a short
    // phone or a small freeform window never grows the popup beyond the
    // usable viewport.
    return this.breakpoint === 'sm' ? 300 : 340;
  }

  private usageGuideItems(): GuideContentPage[] {
    return settingsUsageGuidePages(this.guideDevice);
  }

  private resetExpandedGuideLesson(): void {
    const lessons: GuideLesson[] = guideLessonsFor(this.guideDevice, this.guideProtocol);
    this.expandedGuideLessonId = lessons.length > 0 ? lessons[0].id : '';
  }

  private toggleGuideAlwaysVisible(): void {
    const next: boolean = !this.guideAlwaysVisible;
    const saved: boolean = GuideVisibilityService.getInstance().setAlwaysVisible(
      getContext(this) as common.Context, next);
    if (saved) {
      this.guideAlwaysVisible = next;
      return;
    }
    try {
      this.getUIContext().getPromptAction().showToast({
        message: '引导显示设置保存失败，请稍后重试', duration: 2000
      });
    } catch (_error) {}
  }

  private openUrl(url: string): void {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url
      };
      ctx.startAbility(want);
    } catch (_e) {
      // 静默 — 打开浏览器失败不影响
    }
  }

  build() {
    if (this.aboutSheetMode === 0) {
      this.usageGuideSheet();
    } else if (this.aboutSheetMode === 5) {
      this.handsOnGuideSheet();
    } else if (this.aboutSheetMode === 1) {
      this.aboutAppSheet();
    } else if (this.aboutSheetMode === 2) {
      this.privacyPolicySheet();
    } else if (this.aboutSheetMode === 3) {
      this.preRequisiteSheet();
    } else {
      this.releaseNotesSheet();
    }
  }

  @Builder releaseNotesSheet() {
    Column() {
      Row() {
        Text(CURRENT_RELEASE_VERSION + ' 本版本更新日志').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(this.font())
        Blank()
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
          .width(36).height(36).onClick((): void => { this.onClose(); })
      }.width('100%').padding({ left: 24, right: 20, top: 20 }).margin({ bottom: 4 })

      Swiper(this.releaseNotesController) {
        ForEach(this.releaseNotesItems, (item: ReleaseNotePage, index: number) => {
          Column() {
            Column() {
              Image(item.symbol).width(48).height(48).fillColor(this.accentColor)
            }
            .width(96).height(96).borderRadius(26)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(this.pal().surface)
            .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
            .margin({ bottom: 18 })
            .scale({
              x: this.releaseNotesIndex === index ? 1 : 0.86,
              y: this.releaseNotesIndex === index ? 1 : 0.86
            })
            .animation({ duration: 240, curve: Curve.EaseOut })

            Text(item.title)
              .fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
              .textAlign(TextAlign.Center).fontFamily(this.font()).margin({ bottom: 10 })

            Text(item.desc)
              .fontSize(14).fontColor(this.pal().text2).textAlign(TextAlign.Center)
              .lineHeight(21).width('88%').fontFamily(this.font())
          }
          .width('100%').justifyContent(FlexAlign.Center)
          .padding({ bottom: 40 })
        }, (item: ReleaseNotePage) => item.id)
      }
      .loop(false).indicator(false).duration(250).curve(Curve.EaseOut)
      .onChange((i: number): void => { this.releaseNotesIndex = i; })
      .height(this.usageGuideHeight())

      Row() {
        Text(this.releaseNotesIndex > 0 ? '上一步' : '关闭')
          .fontSize(14).fontColor(this.pal().text2).width(72).textAlign(TextAlign.Start)
          .onClick((): void => {
            if (this.releaseNotesIndex > 0) {
              this.releaseNotesController.showPrevious();
            } else {
              this.onClose();
            }
          })
        Blank()
        Text((this.releaseNotesIndex + 1).toString() + ' / ' +
          this.releaseNotesItems.length.toString())
          .fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text3)
        Blank()
        Text(this.releaseNotesIndex < this.releaseNotesItems.length - 1 ? '下一步' : '完成')
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.accentColor)
          .width(72).textAlign(TextAlign.End)
          .onClick((): void => {
            if (this.releaseNotesIndex < this.releaseNotesItems.length - 1) {
              this.releaseNotesController.showNext();
            } else {
              this.onClose();
            }
          })
      }.width('100%').padding({ left: 28, right: 28, bottom: 28, top: 8 })
    }
    .width('100%')
    .constraintSize({ maxWidth: 620, maxHeight: this.breakpoint === 'sm' ? 500 : 560 })
    .clip(true)
    .backgroundColor(this.pal().bg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .borderRadius(this.breakpoint === 'sm' ?
      { topLeft: 22, topRight: 22, bottomLeft: 0, bottomRight: 0 } : 24)
  }

  @Builder usageGuideSheet() {
    Column() {
      Row() {
        Text('快速认识应用').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(this.font())
        Blank()
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
          .width(36).height(36).onClick((): void => { this.onClose(); })
      }.width('100%').padding({ left: 24, right: 20, top: 20 }).margin({ bottom: 4 })

      Swiper(this.usageGuideController) {
        ForEach(this.usageGuideItems(), (item: GuideContentPage, index: number) => {
          Column() {
            Column() {
              Image(item.symbol).width(48).height(48).fillColor(this.accentColor)
            }
            .width(96).height(96).borderRadius(26)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(this.pal().surface)
            .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
            .margin({ bottom: 18 })
            .scale({
              x: this.usageGuideIndex === index ? 1 : 0.86,
              y: this.usageGuideIndex === index ? 1 : 0.86
            })
            .animation({ duration: 240, curve: Curve.EaseOut })

            Text(item.title)
              .fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
              .textAlign(TextAlign.Center).fontFamily(this.font()).margin({ bottom: 10 })

            Scroll() {
              Text(item.desc)
                .fontSize(14).fontColor(this.pal().text2).textAlign(TextAlign.Center)
                .lineHeight(21).width('100%').fontFamily(this.font())
            }
            .width('88%').layoutWeight(1).scrollBar(BarState.Off)
          }
          .width('100%').justifyContent(FlexAlign.Center)
          .padding({ bottom: 40 })
        }, (item: GuideContentPage) => item.id)
      }
      .loop(false).indicator(false).duration(250).curve(Curve.EaseOut)
      .onChange((i: number): void => { this.usageGuideIndex = i; })
      .height(this.usageGuideHeight())

      Row() {
        Text(this.usageGuideIndex > 0 ? '上一步' : '关闭')
          .fontSize(14).fontColor(this.pal().text2).width(72).textAlign(TextAlign.Start)
          .onClick((): void => {
            if (this.usageGuideIndex > 0) {
              this.usageGuideController.showPrevious();
            } else {
              this.onClose();
            }
          })
        Blank()
        Row({ space: 7 }) {
          ForEach(this.usageGuideItems(), (_dot: GuideContentPage, i: number) => {
            Column()
              .width(this.usageGuideIndex === i ? 22 : 7).height(7).borderRadius(4)
              .backgroundColor(this.usageGuideIndex === i ? this.accentColor : this.pal().divider)
              .animation({ duration: 200, curve: Curve.EaseOut })
          }, (_dot: GuideContentPage) => _dot.id)
        }
        Blank()
        Text(this.usageGuideIndex < this.usageGuideItems().length - 1 ? '下一步' : '完成')
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.accentColor)
          .width(72).textAlign(TextAlign.End)
          .onClick((): void => {
            if (this.usageGuideIndex < this.usageGuideItems().length - 1) {
              this.usageGuideController.showNext();
            } else {
              this.onClose();
            }
          })
      }.width('100%').padding({ left: 28, right: 28, bottom: 28, top: 8 })
    }
    .width('100%')
    .constraintSize({ maxWidth: 620, maxHeight: this.breakpoint === 'sm' ? 500 : 560 })
    .clip(true)
    .backgroundColor(this.pal().bg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .borderRadius(this.breakpoint === 'sm' ?
      { topLeft: 22, topRight: 22, bottomLeft: 0, bottomRight: 0 } : 24)
  }

  @Builder handsOnGuideSheet() {
    Column() {
      Row() {
        Column() {
          Text('操作引导中心').fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text).fontFamily(this.font())
          Text('按设备与协议定位，不必从头读完')
            .fontSize(12).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Blank()
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
          .width(36).height(36).onClick((): void => { this.onClose(); })
      }.width('100%').padding({ left: 24, right: 20, top: 20 }).margin({ bottom: 12 })

      Column() {
        Row() {
          Column() {
            Text('当前按 ' + guideDeviceLabel(this.guideDevice) + ' 展示')
              .fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
              .fontFamily(this.font())
            Text(guideDeviceSummary(this.guideDevice))
              .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font()).margin({ top: 3 })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
            .fontSize(22).fontColor([this.accentColor])
        }.width('100%')

        Row({ space: 8 }) {
          this.guideDeviceChip('phone')
          this.guideDeviceChip('tablet')
          this.guideDeviceChip('desktop')
        }.width('100%').margin({ top: 12 })
      }
      .width('100%').padding(14).borderRadius(16)
      .backgroundColor(this.pal().surface)
      .margin({ left: 20, right: 20, bottom: 12 })

      Row() {
        Column() {
          Text('自动引导显示方式')
            .fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
            .fontFamily(this.font()).width('100%')
          Text(this.guideAlwaysVisible ?
            '每次进入适用会话时显示一次；同一会话不会反复弹出' :
            '默认每类自动引导只显示一次，教程中心仍可随时打开')
            .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
            .lineHeight(16).width('100%').margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button(this.guideAlwaysVisible ? '始终显示：开' : '始终显示')
          .height(34).fontSize(11).borderRadius(10).margin({ left: 12 })
          .backgroundColor(this.guideAlwaysVisible ? this.accentColor : this.pal().card)
          .fontColor(this.guideAlwaysVisible ? Color.White : this.accentColor)
          .onClick((): void => { this.toggleGuideAlwaysVisible(); })
          .accessibilityText(this.guideAlwaysVisible ? '关闭始终显示引导' : '开启始终显示引导')
      }
      .width('100%').padding(13).borderRadius(16)
      .backgroundColor(this.pal().surface)
      .margin({ left: 20, right: 20, bottom: 12 })

      Scroll() {
        Row({ space: 8 }) {
          ForEach(guideProtocolOptions(), (option: GuideProtocolOption): void => {
            this.guideProtocolChip(option)
          }, (option: GuideProtocolOption): string => option.id)
        }.padding({ left: 20, right: 20 })
      }
      .width('100%').height(72).scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)

      Scroll() {
        Column() {
          ForEach(guideLessonsFor(this.guideDevice, this.guideProtocol),
            (lesson: GuideLesson): void => {
              this.guideLessonCard(lesson)
            }, (lesson: GuideLesson): string => lesson.id)
        }.width('100%').padding({ left: 20, right: 20, top: 4, bottom: 22 })
      }
      .width('100%').layoutWeight(1).scrollBar(BarState.Auto)
    }
    .width('100%').height('100%')
    .constraintSize({ minHeight: 360, maxWidth: 760,
      maxHeight: this.breakpoint === 'sm' ? 660 : 820 })
    .clip(true)
    .backgroundColor(this.pal().bg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .borderRadius(this.breakpoint === 'sm' ?
      { topLeft: 22, topRight: 22, bottomLeft: 0, bottomRight: 0 } : 24)
  }

  @Builder guideDeviceChip(device: GuideDevice) {
    Text(device === 'phone' ? '手机' : (device === 'tablet' ? 'Pad' : 'PC'))
      .fontSize(12).fontWeight(this.guideDevice === device ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.guideDevice === device ? Color.White : this.pal().text2)
      .textAlign(TextAlign.Center).layoutWeight(1)
      .padding({ top: 8, bottom: 8 })
      .backgroundColor(this.guideDevice === device ? this.accentColor : this.pal().card)
      .borderRadius(10)
      .onClick((): void => {
        this.guideDevice = device;
        this.resetExpandedGuideLesson();
      })
  }

  @Builder guideProtocolChip(option: GuideProtocolOption) {
    Column() {
      Text(option.label)
        .fontSize(13).fontWeight(FontWeight.Medium)
        .fontColor(this.guideProtocol === option.id ? Color.White : this.pal().text)
        .fontFamily(this.font())
      Text(option.summary)
        .fontSize(10).fontColor(this.guideProtocol === option.id ? '#EAF3FF' : this.pal().text3)
        .fontFamily(this.font()).margin({ top: 2 })
    }
    .constraintSize({ minWidth: option.id === 'ssh' || option.id === 'moonlight' ? 112 : 92 })
    .height(58).justifyContent(FlexAlign.Center)
    .padding({ left: 12, right: 12 }).borderRadius(14)
    .backgroundColor(this.guideProtocol === option.id ? this.accentColor : this.pal().surface)
    .border({ width: 0.5,
      color: this.guideProtocol === option.id ? this.accentColor : this.pal().cardBorder,
      style: BorderStyle.Solid })
    .onClick((): void => {
      this.guideProtocol = option.id;
      this.resetExpandedGuideLesson();
    })
  }

  @Builder guideLessonCard(lesson: GuideLesson) {
    Column() {
      Row() {
        Column() {
          Text(lesson.title).fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text).fontFamily(this.font()).width('100%')
          Text(lesson.summary).fontSize(11).fontColor(this.pal().text3)
            .fontFamily(this.font()).width('100%').margin({ top: 4 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        SymbolGlyph(this.expandedGuideLessonId === lesson.id ?
          $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(16).fontColor([this.pal().text3]).margin({ left: 10 })
      }
      .width('100%').padding({ left: 16, right: 16, top: 15, bottom: 15 })
      .onClick((): void => {
        this.expandedGuideLessonId = this.expandedGuideLessonId === lesson.id ? '' : lesson.id;
      })

      if (this.expandedGuideLessonId === lesson.id) {
        Divider().strokeWidth(0.5).color(this.pal().divider)
          .margin({ left: 16, right: 16 })
        Column() {
          ForEach(lesson.steps, (step: string, index: number): void => {
            Row() {
              Text((index + 1).toString())
                .fontSize(11).fontWeight(FontWeight.Bold).fontColor(Color.White)
                .width(22).height(22).textAlign(TextAlign.Center)
                .backgroundColor(this.accentColor).borderRadius(11)
              Text(step).fontSize(13).fontColor(this.pal().text2).lineHeight(20)
                .fontFamily(this.font()).layoutWeight(1).margin({ left: 10 })
            }.width('100%').alignItems(VerticalAlign.Top).margin({ bottom: 11 })
          }, (step: string, index: number): string => lesson.id + '-' + index.toString())
          if (lesson.note.length > 0) {
            Row() {
              SymbolGlyph($r('sys.symbol.info_circle')).fontSize(15)
                .fontColor([this.accentColor]).margin({ top: 2 })
              Text(lesson.note).fontSize(12).fontColor(this.pal().text2).lineHeight(18)
                .fontFamily(this.font()).layoutWeight(1).margin({ left: 8 })
            }
            .width('100%').padding(11).borderRadius(12)
            .backgroundColor(this.pal().surface)
          }
        }.width('100%').padding({ left: 16, right: 16, top: 14, bottom: 16 })
      }
    }
    .width('100%').borderRadius(16).backgroundColor(this.pal().card)
    .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
    .margin({ bottom: 10 })
  }

  @Builder aboutAppSheet() {
    Column() {
      Row() {
        Text('关于应用').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(this.font())
        Blank()
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
          .width(36).height(36).onClick((): void => { this.onClose(); })
      }.width('100%').margin({ bottom: 14 })

      Scroll() {
        Column() {
          // 开源协议
          Column() {
            Text('AGPL-3.0-or-later 开源协议')
              .fontSize(14).fontColor(this.pal().text).fontWeight(FontWeight.Medium)
              .fontFamily(this.font()).width('100%').margin({ bottom: 6 })
            Text('完整对应源码与第三方许可声明见 GitHub 仓库')
              .fontSize(13).fontColor(this.pal().text2).lineHeight(20)
              .fontFamily(this.font()).width('100%')
          }
          .alignItems(HorizontalAlign.Start).width('100%')
          .padding({ left: 14, right: 14, top: 14, bottom: 14 })
          .borderRadius(16).backgroundColor(this.pal().surface)
          .margin({ bottom: 12 })

          // GitHub 链接
          Row() {
            Text('GitHub 仓库')
              .fontSize(14).fontColor(this.pal().text).fontWeight(FontWeight.Medium)
              .fontFamily(this.font())
            Blank()
            Text('在浏览器中打开 >')
              .fontSize(12).fontColor(this.accentColor).fontFamily(this.font())
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 14, bottom: 14 })
          .borderRadius(16).backgroundColor(this.pal().surface)
          .margin({ bottom: 12 })
          .onClick((): void => {
            this.openUrl('https://github.com/Mydstiny/RemoteDeskHarmonyOS');
          })

          // 更新与联系
          Column() {
            Text('更新与联系')
              .fontSize(14).fontColor(this.pal().text).fontWeight(FontWeight.Medium)
              .fontFamily(this.font()).width('100%').margin({ bottom: 6 })
            Text('作者正在准备考研，回复和更新可能不及时，尽量半月更新一版。\n' +
              '如有建议，可从设置中的“反馈”发送邮件或获取最新畅联群聊二维码。')
              .fontSize(13).fontColor(this.pal().text2).lineHeight(22)
              .fontFamily(this.font()).width('100%')
          }
          .alignItems(HorizontalAlign.Start).width('100%')
          .padding({ left: 14, right: 14, top: 14, bottom: 14 })
          .borderRadius(16).backgroundColor(this.pal().surface)
        }.width('100%')
      }.height(this.breakpoint === 'sm' ? 220 : 280)

      Button('我知道了').width('100%').height(44).fontSize(14)
        .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(12)
        .margin({ top: 18 })
        .onClick((): void => { this.onClose(); })
    }
    .padding({ left: 24, right: 24, top: 22, bottom: 30 })
    .width('100%')
    .constraintSize({ maxWidth: 620 })
    .backgroundColor(this.pal().bg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .borderRadius(this.breakpoint === 'sm' ?
      { topLeft: 22, topRight: 22, bottomLeft: 0, bottomRight: 0 } : 24)
  }

  @Builder privacyPolicySheet() {
    Column() {
      Row() {
        Text('隐私政策').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(this.font())
        Blank()
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
          .width(36).height(36).onClick((): void => { this.onClose(); })
      }.width('100%').padding({ left: 24, right: 20, top: 20 }).margin({ bottom: 8 })

      Scroll() {
        Column() {
          this.policySection('我们处理的信息',
            '账号信息、主机配置、远程连接凭据、SSH 私钥、TOTP 密钥、RustDesk 中继配置和应用偏好。' +
            '远程桌面画面、SSH 会话内容不会持久化保存。')
          this.policySection('权限用途',
            '网络权限用于连接目标主机；ohos.permission.DISTRIBUTED_DATASYNC（分布式数据管理权限）' +
            '只在你登录华为账号并使用云同步时，用于通过华为云空间服务同步跨设备数据；' +
            '拒绝或撤回该权限后云同步不可用，但不影响本地基础功能；' +
            '相机只在扫描 2FA 二维码时使用；' +
            '系统锁屏密码、指纹或人脸只在主机锁或 TOTP 隐私保护验证时使用。')
          this.policySection('数据安全',
            '启用并解锁应用加密后，受保护的敏感字段使用主密码派生密钥进行 AES-256-GCM 加密；' +
            '未启用应用加密时，你选择保存和同步的部分凭据可能以未加密形式保存或同步，' +
            '相关设置会要求确认风险。主密码丢失后无法恢复已加密数据，请自行妥善保存。')
          this.policySection('第三方共享',
            '本应用不集成广告 SDK，不出售个人信息。华为账号与云空间服务由华为官方 Kit 提供；' +
            'RustDesk 中继服务器由你自行选择。')
          this.policySection('联系我们',
            '如有隐私或数据处理问题，请发送邮件至 lijiong1219@petalmail.com。')

          Row() {
            Text('完整隐私政策').fontSize(AppTheme.fontSize.body).fontWeight(FontWeight.Medium)
              .fontColor(this.pal().text).fontFamily(this.font())
            Blank()
            Text('在浏览器中打开 >')
              .fontSize(12).fontColor(this.accentColor).fontFamily(this.font())
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 14, bottom: 14 })
          .borderRadius(16).backgroundColor(this.pal().surface)
          .margin({ bottom: 12 })
          .onClick((): void => {
            this.openUrl('https://mydstiny.github.io/RemoteDeskHarmonyOS/privacy/');
          })
        }.width('100%').padding({ left: 24, right: 24, bottom: 22 })
      }.height(this.breakpoint === 'sm' ? 440 : 520)
    }
    .width('100%')
    .constraintSize({ maxWidth: 680 })
    .backgroundColor(this.pal().bg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .borderRadius(this.breakpoint === 'sm' ?
      { topLeft: 22, topRight: 22, bottomLeft: 0, bottomRight: 0 } : 24)
  }

  /** 连接前准备 — 五协议服务端与网络检查 */
  @Builder preRequisiteSheet() {
    Column() {
      Row() {
        Text('连接前准备').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(this.font())
        Blank()
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
          .width(36).height(36).onClick((): void => { this.onClose(); })
      }.width('100%').margin({ bottom: 8 })

      Scroll() {
        Column() {
          // Windows RDP 设置指南（可点击链接）
          Column() {
            Text('Windows RDP 设置指南')
              .fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
              .fontFamily(this.font()).width('100%').margin({ bottom: 4 })
            Text('配置 Windows 远程桌面、用户、网络与安全策略')
              .fontSize(12).fontColor(this.pal().text3).lineHeight(18)
              .fontFamily(this.font()).width('100%')
          }
          .alignItems(HorizontalAlign.Start).width('100%')
          .padding({ left: 14, right: 14, top: 14, bottom: 14 })
          .borderRadius(16).backgroundColor(this.pal().surface)
          .margin({ bottom: 12 })
          .onClick((): void => {
            this.openUrl('https://lijiong.online/2026/06/22/RDP%E8%AE%BE%E7%BD%AE%E6%8C%87%E5%8D%97/');
          })

          // RustDesk 部署教程 (可点击链接)
          Column() {
            Text('RustDesk 部署教程')
              .fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
              .fontFamily(this.font()).width('100%').margin({ bottom: 4 })
            Text('自建 RustDesk 中继服务器，告别公共服务器延迟与限制')
              .fontSize(12).fontColor(this.pal().text3).lineHeight(18)
              .fontFamily(this.font()).width('100%')
          }
          .alignItems(HorizontalAlign.Start).width('100%')
          .padding({ left: 14, right: 14, top: 14, bottom: 14 })
          .borderRadius(16).backgroundColor(this.pal().surface)
          .margin({ bottom: 12 })
          .onClick((): void => {
            this.openUrl('https://lijiong.online/2026/06/22/RustDesk%E8%87%AA%E5%BB%BA%E6%9C%8D%E5%8A%A1%E5%99%A8%E6%95%99%E7%A8%8B/');
          })

          this.preReqSection('Windows RDP 前置操作',
            '1. 右键"此电脑" → "属性" → "远程桌面"，开启"启用远程桌面"。\n' +
            '2. 确保 Windows 是支持远程桌面主机的版本，并为允许登录的账户设置强密码。\n' +
            '3. 局域网连接记录主机地址；外网访问优先使用 VPN，不建议直接暴露 3389 端口。\n' +
            '4. 保持网络级别身份验证（NLA）开启，并在首次连接时核对证书。')

          this.preReqSection('RustDesk 前置操作',
            '1. 在目标设备（Windows/macOS/Linux）安装并启动 RustDesk 被控端。\n' +
            '2. 打开 RustDesk 查看远程 ID 和一次性密码（或设置永久密码）。\n' +
            '3. 如果使用自建中继服务器，请在中继页填入 ID/Rendezvous/API 服务器地址和 Key。\n' +
            '4. 首次连接可能需要目标端手动确认。')

          this.preReqSection('SSH 前置操作',
            '1. 确保目标主机已开启 SSH 服务（Linux/macOS 默认支持，Windows 需安装 OpenSSH Server）。\n' +
            '2. 推荐使用密钥认证：生成 Ed25519 或 RSA 密钥对，将公钥添加到目标主机的 ~/.ssh/authorized_keys。\n' +
            '3. 首次连接会显示主机指纹，请核对无误后再信任。')

          this.preReqSection('VNC 前置操作',
            '1. 在目标设备启动 VNC Server，确认认证方式、显示编号和监听端口（常见为 5900）。\n' +
            '2. 同网或 VPN 内优先 TCP 直连；公网连接应启用 TLS、VPN 或可信中继。\n' +
            '3. 使用 UltraVNC Repeater 时，先在中继服务器页添加 Gateway；当前 Viewer 使用 mode12。\n' +
            '4. 首次 TLS 连接分别核对 Gateway 与目标端证书。')

          this.preReqSection('Moonlight / Sunshine 前置操作',
            '1. 在目标电脑安装 Sunshine，完成 Web 管理端初始化并添加要串流的应用。\n' +
            '2. 确保当前设备能访问 Sunshine 主机；局域网发现不可用时可手动输入地址。\n' +
            '3. 添加主机时先校验身份，再把应用显示的 PIN 输入 Sunshine 完成配对。\n' +
            '4. 手柄、HDR、高分辨率和后台音频需同时满足当前设备、系统与 Sunshine 能力。')
        }.width('100%').padding({ left: 24, right: 24, bottom: 22 })
      }.layoutWeight(1).scrollBar(BarState.Auto)

      Button('我知道了').width('100%').height(44).fontSize(14)
        .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(12)
        .margin({ top: 18 })
        .onClick((): void => { this.onClose(); })
    }
    .width('100%').height('100%')
    .constraintSize({ minHeight: 360, maxWidth: 680, maxHeight: 820 })
    .padding({ left: 24, right: 24, top: 22, bottom: 30 })
    .backgroundColor(this.pal().bg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .borderRadius(this.breakpoint === 'sm' ?
      { topLeft: 22, topRight: 22, bottomLeft: 0, bottomRight: 0 } : 24)
  }

  @Builder policySection(title: string, body: string) {
    Column() {
      Text(title).fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        .fontFamily(this.font()).width('100%').margin({ bottom: 8 })
      Text(body).fontSize(13).fontColor(this.pal().text2).lineHeight(21)
        .fontFamily(this.font()).width('100%')
    }
    .alignItems(HorizontalAlign.Start).width('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .borderRadius(16).backgroundColor(this.pal().surface)
    .margin({ bottom: 12 })
  }

  @Builder preReqSection(title: string, body: string) {
    Column() {
      Text(title).fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
        .fontFamily(this.font()).width('100%').margin({ bottom: 8 })
      Text(body).fontSize(13).fontColor(this.pal().text2).lineHeight(21)
        .fontFamily(this.font()).width('100%')
    }
    .alignItems(HorizontalAlign.Start).width('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .borderRadius(16).backgroundColor(this.pal().surface)
    .margin({ bottom: 12 })
  }
}
