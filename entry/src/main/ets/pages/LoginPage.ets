import { ImmersiveBackground } from '../components/ImmersiveBackground';
import { GlassmorphicCard } from '../components/GlassmorphicCard';
import { AuthService } from '../services/AuthService';
import { HostSyncService } from '../services/HostSyncService';
import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

@Entry
@Component
struct LoginPage {
  @State isLoggingIn: boolean = false;
  @State errorMessage: string = '';
  @State userDisplayName: string = '';
  @State userAvatar: string = '';
  @State isLoggedIn: boolean = false;
  @StorageLink('currentTheme') theme: string = 'dark';
  private authService: AuthService = AuthService.getInstance();

  async aboutToAppear(): Promise<void> {
    try {
      const user = await this.authService.silentLogin();
      if (user) {
        this.userDisplayName = user.displayName;
        this.isLoggedIn = true;
      }
    } catch (err) {
      console.info('Silent login skipped, user needs manual login');
    }
  }

  build() {
    ImmersiveBackground({
      contentBuilder: () => {
        this.MainContent()
      }
    })
  }

  @Builder
  MainContent() {
    Column() {
      Column() {
        Column()
          .width(80).height(80)
          .borderRadius(40)
          .backgroundColor('#6677ff')
          .alignItems(HorizontalAlign.Center)
          .justifyContent(FlexAlign.Center)
          .overlay(
            Column()
              .width(80).height(80)
              .borderRadius(40)
              .border({ width: 2, color: 'rgba(255,255,255,0.3)', style: BorderStyle.Solid })
          )

        Text('远程桌面')
          .fontSize(28).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          .margin({ top: 16 })
        Text('双协议 · 华为云同步 · 安全锁')
          .fontSize(14).fontColor('rgba(255,255,255,0.5)')
          .margin({ top: 4 })
      }
      .width('100%')
      .margin({ top: 80 })
      .alignItems(HorizontalAlign.Center)

      GlassmorphicCard({ borderRadius: 24, paddingSize: 24 }) {
        Column() {
          if (!this.isLoggedIn) {
            Text('登录以同步远程主机配置')
              .fontSize(15).fontColor('rgba(255,255,255,0.7)')
              .margin({ bottom: 24 })

            Button() {
              Row() {
                Image($r('app.media.ic_huawei'))
                  .width(20).height(20)
                  .margin({ right: 8 })
                Text('使用华为账号登录')
                  .fontSize(16).fontWeight(FontWeight.Medium)
                  .fontColor('#FFFFFF')
              }
            }
            .width('100%').height(52)
            .borderRadius(16)
            .backgroundColor('#cf1133')
            .onClick(() => {
              this.handleLogin();
            })
            .enabled(!this.isLoggingIn)

            if (this.errorMessage.length > 0) {
              Text(this.errorMessage)
                .fontSize(12).fontColor('#FF6B6B')
                .margin({ top: 12 })
            }

            Text('登录即表示同意服务条款和隐私政策')
              .fontSize(11).fontColor('rgba(255,255,255,0.3)')
              .margin({ top: 16 })

            Button('跳过登录')
              .width('100%').height(44)
              .borderRadius(12)
              .backgroundColor('rgba(255,255,255,0.08)')
              .fontColor('rgba(255,255,255,0.6)')
              .fontSize(14)
              .margin({ top: 8 })
              .onClick(() => {
                this.navigateToHosts();
              })
          } else {
            Column() {
              Text('欢迎回来')
                .fontSize(14).fontColor('rgba(255,255,255,0.6)')
              Text(this.userDisplayName)
                .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
                .margin({ top: 4 })

              Button('进入主机列表')
                .width('100%').height(52)
                .borderRadius(16)
                .backgroundColor('#6677ff')
                .fontColor('#FFFFFF')
                .fontSize(16)
                .margin({ top: 24 })
                .onClick(() => {
                  this.navigateToHosts();
                })

              Button('退出登录')
                .width('100%').height(44)
                .borderRadius(12)
                .backgroundColor('rgba(255,255,255,0.08)')
                .fontColor('rgba(255,255,255,0.5)')
                .fontSize(14)
                .margin({ top: 8 })
                .onClick(() => {
                  this.handleLogout();
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
      .margin({ left: 24, right: 24, top: 48 })
    }
    .width('100%').height('100%')
  }

  private async handleLogin(): Promise<void> {
    this.isLoggingIn = true;
    this.errorMessage = '';
    try {
      const user = await this.authService.login();
      this.userDisplayName = user.displayName;
      this.isLoggedIn = true;
      console.info('Login success: ' + user.displayName);
    } catch (err) {
      this.errorMessage = '登录失败，请重试';
      console.error('Login failed: ' + err);
    } finally {
      this.isLoggingIn = false;
    }
  }

  private async handleLogout(): Promise<void> {
    try {
      await this.authService.logout();
      this.isLoggedIn = false;
      this.userDisplayName = '';
      console.info('Logout success');
    } catch (err) {
      console.error('Logout failed: ' + err);
    }
  }

  private navigateToHosts(): void {
    router.pushUrl({ url: 'pages/HostListPage' });
  }
}
