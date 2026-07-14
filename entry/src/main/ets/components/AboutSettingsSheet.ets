/**
 * AboutSettingsSheet.ets — 关于应用/使用教程/隐私政策/前置操作 (T-200 Step 2)
 *
 * 从 HostListPage.ets 提取。接收 aboutSheetMode 和关闭回调，
 * 通过 @StorageLink/@StorageProp 接入主题系统。
 */
import { common, Want } from '@kit.AbilityKit';
import { AppConfig, AppTheme, Palette, buildLight, buildDark } from '../common/Theme';
import { GuideContentPage, settingsUsageGuidePages } from '../services/GuideContentRegistry';

@Component
export struct AboutSettingsSheet {
  @Prop aboutSheetMode: number = 0;
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @StorageProp('breakpoint') breakpoint: string = 'md';
  onClose: () => void = (): void => {};

  @State usageGuideIndex: number = 0;
  private usageGuideController: SwiperController = new SwiperController();
  private readonly usageGuideItems: GuideContentPage[] = settingsUsageGuidePages();

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private font(): string {
    return AppConfig.fontFamily;
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
    } else if (this.aboutSheetMode === 1) {
      this.aboutAppSheet();
    } else if (this.aboutSheetMode === 2) {
      this.privacyPolicySheet();
    } else {
      this.preRequisiteSheet();
    }
  }

  @Builder usageGuideSheet() {
    Column() {
      Row() {
        Text('简单使用教程').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(this.font())
        Blank()
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
          .width(36).height(36).onClick((): void => { this.onClose(); })
      }.width('100%').padding({ left: 24, right: 20, top: 20 }).margin({ bottom: 4 })

      Swiper(this.usageGuideController) {
        ForEach(this.usageGuideItems, (item: GuideContentPage, index: number) => {
          Column() {
            Column() {
              Image(item.symbol).width(52).height(52).fillColor(this.accentColor)
            }
            .width(108).height(108).borderRadius(30)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(this.pal().surface)
            .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
            .margin({ bottom: 26 })
            .scale({
              x: this.usageGuideIndex === index ? 1 : 0.86,
              y: this.usageGuideIndex === index ? 1 : 0.86
            })
            .animation({ duration: 240, curve: Curve.EaseOut })

            Text(item.title)
              .fontSize(24).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
              .textAlign(TextAlign.Center).fontFamily(this.font()).margin({ bottom: 12 })

            Text(item.desc)
              .fontSize(14).fontColor(this.pal().text2).textAlign(TextAlign.Center)
              .lineHeight(22).width('82%').fontFamily(this.font())
          }
          .width('100%').justifyContent(FlexAlign.Center)
          .padding({ bottom: 40 })
        }, (item: GuideContentPage) => item.id)
      }
      .loop(false).indicator(false).duration(250).curve(Curve.EaseOut)
      .onChange((i: number): void => { this.usageGuideIndex = i; })
      .height(this.breakpoint === 'sm' ? 380 : 420)

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
          ForEach(this.usageGuideItems, (_dot: GuideContentPage, i: number) => {
            Column()
              .width(this.usageGuideIndex === i ? 22 : 7).height(7).borderRadius(4)
              .backgroundColor(this.usageGuideIndex === i ? this.accentColor : this.pal().divider)
              .animation({ duration: 200, curve: Curve.EaseOut })
          }, (_dot: GuideContentPage) => _dot.id)
        }
        Blank()
        Text(this.usageGuideIndex < this.usageGuideItems.length - 1 ? '下一步' : '完成')
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.accentColor)
          .width(72).textAlign(TextAlign.End)
          .onClick((): void => {
            if (this.usageGuideIndex < this.usageGuideItems.length - 1) {
              this.usageGuideController.showNext();
            } else {
              this.onClose();
            }
          })
      }.width('100%').padding({ left: 28, right: 28, bottom: 28, top: 8 })
    }
    .width('100%')
    .constraintSize({ maxWidth: 620 })
    .backgroundColor(this.pal().bg)
    .backgroundBlurStyle(BlurStyle.Regular)
    .borderRadius(this.breakpoint === 'sm' ?
      { topLeft: 22, topRight: 22, bottomLeft: 0, bottomRight: 0 } : 24)
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
            '网络权限用于连接目标主机和云同步；相机只在扫描 2FA 二维码时使用；' +
            '生物识别只在主机锁或 TOTP 隐私保护验证时使用。')
          this.policySection('数据安全',
            '敏感数据使用主密码派生密钥进行 AES-256-GCM 加密。' +
            '主密码丢失后无法恢复已加密数据，请自行妥善保存。')
          this.policySection('第三方共享',
            '本应用不集成广告 SDK，不出售个人信息。华为账号与云同步由华为官方 Kit 提供；' +
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
            this.openUrl('https://mydstiny.github.io/RemoteDeskHarmonyOS/');
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

  /** 前置操作 — FreeRDP / RustDesk 部署教程 */
  @Builder preRequisiteSheet() {
    Column() {
      Row() {
        Text('如何进行前置操作').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(this.font())
        Blank()
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
          .width(36).height(36).onClick((): void => { this.onClose(); })
      }.width('100%').margin({ bottom: 8 })

      Scroll() {
        Column() {
          // FreeRDP 部署教程 (可点击链接)
          Column() {
            Text('FreeRDP 部署教程')
              .fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
              .fontFamily(this.font()).width('100%').margin({ bottom: 4 })
            Text('在服务器上部署 FreeRDP 中转服务，获取更流畅的 RDP 连接体验')
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
            '2. 确保 Windows 版本为专业版或企业版（家庭版不支持远程桌面服务端）。\n' +
            '3. 如果主机在局域网内，记录 IP 地址；如果外网访问需要配置端口转发（默认 3389）或 VPN。\n' +
            '4. 建议使用 Microsoft 账户登录以获得 NLA 网络安全认证。')

          this.preReqSection('RustDesk 前置操作',
            '1. 在目标设备（Windows/macOS/Linux）安装 RustDesk 服务端。\n' +
            '2. 打开 RustDesk 查看远程 ID 和一次性密码（或设置永久密码）。\n' +
            '3. 如果使用自建中继服务器，请在中继页填入 ID/Rendezvous/API 服务器地址和 Key。\n' +
            '4. 首次连接可能需要目标端手动确认。')

          this.preReqSection('SSH 前置操作',
            '1. 确保目标主机已开启 SSH 服务（Linux/macOS 默认支持，Windows 需安装 OpenSSH Server）。\n' +
            '2. 推荐使用密钥认证：生成 Ed25519 或 RSA 密钥对，将公钥添加到目标主机的 ~/.ssh/authorized_keys。\n' +
            '3. 首次连接会显示主机指纹，请核对无误后再信任。')
        }.width('100%').padding({ left: 24, right: 24, bottom: 22 })
      }.height(this.breakpoint === 'sm' ? 420 : 540)

      Button('我知道了').width('100%').height(44).fontSize(14)
        .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(12)
        .margin({ top: 18 })
        .onClick((): void => { this.onClose(); })
    }
    .width('100%')
    .constraintSize({ maxWidth: 680 })
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
