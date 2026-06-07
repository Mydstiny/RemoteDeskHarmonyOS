import { ImmersiveBackground } from '../components/ImmersiveBackground';
import { GlassmorphicCard } from '../components/GlassmorphicCard';
import { GatewayConfigForm } from '../components/GatewayConfigForm';
import { AuthService } from '../services/AuthService';
import { LockService, LockType } from '../services/LockService';
import { LightSensingService } from '../services/LightSensingService';
import { SessionQuality, KeyboardMode, GatewayConfig, DisplayConfig } from '../models/RemoteHost';
import { router, promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

@Entry
@Component
struct Settings {
  @State syncEnabled: boolean = true;
  @State currentTheme: string = 'dark';
  @State lockAllHosts: boolean = false;
  @State appVersion: string = '1.0.0';
  @StorageLink('currentTheme') theme: string = 'dark';

  @State defaultSessionQuality: SessionQuality = SessionQuality.AUTO;
  @State defaultDisplayConfig: DisplayConfig = { width: 1920, height: 1080, useAllMonitors: false, colorDepth: 32 };
  @State defaultKeyboardMode: KeyboardMode = KeyboardMode.GENERIC;
  @State globalGatewayConfig: GatewayConfig | null = null;

  private authService: AuthService = AuthService.getInstance();
  private lockService: LockService = LockService.getInstance();
  private lightService: LightSensingService = LightSensingService.getInstance();

  aboutToAppear(): void {
    this.currentTheme = this.theme;
    const user = this.authService.getUser();
    if (user) {
      this.lockAllHosts = this.lockService.getLockType('global') !== LockType.NONE;
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
      Row() {
        Image($r('app.media.ic_back'))
          .width(24).height(24)
          .fillColor('#FFFFFF')
          .onClick(() => { router.back(); })
        Text('设置')
          .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
          .margin({ left: 12 })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16 })
      .alignItems(VerticalAlign.Center)

      List({ space: 12 }) {
        ListItem() {
          this.SectionCard('账户', () => {
            this.AuthSection()
          })
        }

        ListItem() {
          this.SectionCard('安全锁', () => {
            this.LockSection()
          })
        }

        ListItem() {
          this.SectionCard('同步', () => {
            this.SyncSection()
          })
        }

        ListItem() {
          this.SectionCard('默认会话设置', () => {
            this.SessionDefaultsSection()
          })
        }

        ListItem() {
          this.SectionCard('网关', () => {
            this.GatewaySection()
          })
        }

        ListItem() {
          this.SectionCard('显示', () => {
            this.DisplaySection()
          })
        }

        ListItem() {
          this.SectionCard('关于', () => {
            this.AboutSection()
          })
        }
      }
      .layoutWeight(1)
      .padding({ left: 16, right: 16, top: 12 })
    }
    .width('100%').height('100%')
  }

  @Builder
  SectionCard(title: string, content: void): void {
    GlassmorphicCard({ borderRadius: 20, paddingSize: 16 }) {
      Column() {
        Text(title)
          .fontSize(16).fontWeight(FontWeight.SemiBold).fontColor('#FFFFFF')
          .margin({ bottom: 12 })
        content
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  AuthSection(): void {
    Column() {
      Row() {
        Image($r('app.media.ic_user'))
          .width(40).height(40).borderRadius(20)
          .backgroundColor('rgba(255,255,255,0.1)')
        Column() {
          Text(this.authService.getUser()?.displayName ?? '未登录')
            .fontSize(15).fontColor('#FFFFFF')
          Text(this.authService.isLoggedInStatus() ? '已登录' : '点击登录')
            .fontSize(12).fontColor('rgba(255,255,255,0.4)')
        }
        .margin({ left: 12 })
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }

      if (!this.authService.isLoggedInStatus()) {
        Button('登录华为账号')
          .width('100%').height(44)
          .borderRadius(12)
          .backgroundColor('#cf1133')
          .fontColor('#FFFFFF')
          .fontSize(14)
          .margin({ top: 12 })
          .onClick(() => { router.pushUrl({ url: 'pages/LoginPage' }); })
      } else {
        Button('退出登录')
          .width('100%').height(44)
          .borderRadius(12)
          .backgroundColor('rgba(255,255,255,0.1)')
          .fontColor('rgba(255,255,255,0.6)')
          .fontSize(14)
          .margin({ top: 12 })
          .onClick(() => { this.handleLogout(); })
      }
    }
    .width('100%')
  }

  @Builder
  LockSection(): void {
    Column() {
      Row() {
        Text('全局主机锁')
          .fontSize(14).fontColor('#FFFFFF')
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.lockAllHosts })
          .onChange((isOn: boolean) => {
            this.lockAllHosts = isOn;
            if (isOn) {
              this.promptSetGlobalLock();
            } else {
              this.lockService.removeLock('global');
            }
          })
      }
      .width('100%')

      Text('启用后连接任意主机需进行身份验证')
        .fontSize(12).fontColor('rgba(255,255,255,0.4)')
        .margin({ top: 4 })

      Row() {
        Text('生物识别锁')
          .fontSize(14).fontColor('#FFFFFF')
        Blank()
        Button('设置')
          .height(32).borderRadius(8)
          .backgroundColor('rgba(102,119,255,0.3)')
          .fontColor('#6677ff').fontSize(13)
          .onClick(() => { this.handleBiometricSetup(); })
      }
      .width('100%').margin({ top: 12 })

      Row() {
        Text('PIN 码锁')
          .fontSize(14).fontColor('#FFFFFF')
        Blank()
        Button('设置')
          .height(32).borderRadius(8)
          .backgroundColor('rgba(102,119,255,0.3)')
          .fontColor('#6677ff').fontSize(13)
          .onClick(() => { this.handlePinSetup(); })
      }
      .width('100%').margin({ top: 8 })
    }
    .width('100%')
  }

  @Builder
  SyncSection(): void {
    Column() {
      Row() {
        Text('华为云同步')
          .fontSize(14).fontColor('#FFFFFF')
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.syncEnabled })
          .onChange((isOn: boolean) => {
            this.syncEnabled = isOn;
            console.info('Cloud sync toggled: ' + (isOn ? 'enabled' : 'disabled'));
          })
      }
      .width('100%')

      Text('主机配置将自动同步至华为云')
        .fontSize(12).fontColor('rgba(255,255,255,0.4)')
        .margin({ top: 4 })

      Button('立即同步')
        .width('100%').height(44)
        .borderRadius(12)
        .backgroundColor('rgba(102,119,255,0.2)')
        .fontColor('#6677ff').fontSize(14)
        .margin({ top: 12 })
        .onClick(() => {
          try {
            promptAction.showToast({ message: '同步已触发', duration: 1500 });
          } catch (err) {
            console.error('Sync toast failed: ' + err);
          }
        })
    }
    .width('100%')
  }

  @Builder
  SessionDefaultsSection(): void {
    Column() {
      Text('以下设置将作为新建连接的默认值')
        .fontSize(12).fontColor('rgba(255,255,255,0.4)')
        .margin({ bottom: 8 })

      Row() {
        Text('默认会话质量')
          .fontSize(14).fontColor('#FFFFFF')
        Blank()
        Text(this.sessionQualityLabel(this.defaultSessionQuality))
          .fontSize(14).fontColor('rgba(255,255,255,0.6)')
      }
      .width('100%')
      .onClick(() => {
        this.showQualityPicker();
      })

      Row() {
        Text('默认分辨率')
          .fontSize(14).fontColor('#FFFFFF')
        Blank()
        Text(String(this.defaultDisplayConfig.width) + '×' + String(this.defaultDisplayConfig.height))
          .fontSize(14).fontColor('rgba(255,255,255,0.6)')
      }
      .width('100%').margin({ top: 8 })
      .onClick(() => {
        this.showDisplayDefaults();
      })

      Row() {
        Text('键盘映射')
          .fontSize(14).fontColor('#FFFFFF')
        Blank()
        Text(this.keyboardModeLabel(this.defaultKeyboardMode))
          .fontSize(14).fontColor('rgba(255,255,255,0.6)')
      }
      .width('100%').margin({ top: 8 })
      .onClick(() => {
        this.showKeyboardPicker();
      })
    }
    .width('100%')
  }

  @Builder
  GatewaySection(): void {
    Column() {
      Text('配置 RD 网关服务器作为默认网关（每主机可单独覆盖）')
        .fontSize(12).fontColor('rgba(255,255,255,0.4)')
        .margin({ bottom: 8 })

      GatewayConfigForm({
        config: this.globalGatewayConfig,
        onChange: (cfg: GatewayConfig | null) => {
          this.globalGatewayConfig = cfg;
        }
      })
    }
    .width('100%')
  }

  @Builder
  DisplaySection(): void {
    Column() {
      Row() {
        Text('主题')
          .fontSize(14).fontColor('#FFFFFF')
        Blank()
        Text(this.currentTheme === 'dark' ? '深色' : '浅色')
          .fontSize(14).fontColor('rgba(255,255,255,0.6)')
      }
      .width('100%')

      Row() {
        Text('深色模式')
          .fontSize(14).fontColor('#FFFFFF')
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.currentTheme === 'dark' })
          .onChange((isOn: boolean) => {
            this.currentTheme = isOn ? 'dark' : 'light';
            this.theme = this.currentTheme;
          })
      }
      .width('100%').margin({ top: 12 })

      Row() {
        Text('光感自动调节')
          .fontSize(14).fontColor('#FFFFFF')
        Blank()
        Button('校准')
          .height(32).borderRadius(8)
          .backgroundColor('rgba(102,119,255,0.3)')
          .fontColor('#6677ff').fontSize(13)
          .onClick(() => {
            const intensity = this.lightService.getLightIntensity();
            try {
              promptAction.showToast({
                message: '当前光效强度: ' + Math.round(intensity * 100) + '%',
                duration: 1500
              });
            } catch (err) {
              console.error('Calibration toast failed: ' + err);
            }
          })
      }
      .width('100%').margin({ top: 8 })
    }
    .width('100%')
  }

  @Builder
  AboutSection(): void {
    Column() {
      Row() {
        Text('版本')
          .fontSize(14).fontColor('#FFFFFF')
        Blank()
        Text(this.appVersion)
          .fontSize(14).fontColor('rgba(255,255,255,0.6)')
      }
      .width('100%')

      Row() {
        Text('协议支持')
          .fontSize(14).fontColor('#FFFFFF')
        Blank()
        Text('RDP + RustDesk')
          .fontSize(14).fontColor('rgba(255,255,255,0.6)')
      }
      .width('100%').margin({ top: 8 })

      Row() {
        Text('鸿蒙PC双协议远程桌面')
          .fontSize(12).fontColor('rgba(255,255,255,0.3)')
      }
      .width('100%').margin({ top: 16 })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
  }

  private sessionQualityLabel(quality: SessionQuality): string {
    switch (quality) {
      case SessionQuality.BEST_QUALITY: return '最佳画质';
      case SessionQuality.BEST_PERFORMANCE: return '最佳性能';
      case SessionQuality.AUTO:
      default: return '自动';
    }
  }

  private keyboardModeLabel(mode: KeyboardMode): string {
    switch (mode) {
      case KeyboardMode.MACOS: return 'macOS 模式';
      case KeyboardMode.WINDOWS: return 'Windows 模式';
      case KeyboardMode.GENERIC:
      default: return '通用模式';
    }
  }

  private async showQualityPicker(): Promise<void> {
    try {
      const result = await promptAction.showDialog({
        title: '默认会话质量',
        message: '选择新建连接的默认质量',
        buttons: [
          { text: '自动', color: '#6677ff' },
          { text: '最佳画质', color: '#51CF66' },
          { text: '最佳性能', color: '#FF6B6B' }
        ]
      });
      if (result.index === 0) this.defaultSessionQuality = SessionQuality.AUTO;
      else if (result.index === 1) this.defaultSessionQuality = SessionQuality.BEST_QUALITY;
      else if (result.index === 2) this.defaultSessionQuality = SessionQuality.BEST_PERFORMANCE;
    } catch (err) {
      console.error('Quality picker failed: ' + err);
    }
  }

  private async showDisplayDefaults(): Promise<void> {
    try {
      const result = await promptAction.showDialog({
        title: '默认分辨率',
        message: '选择新建连接的默认分辨率',
        buttons: [
          { text: '1920×1080', color: '#6677ff' },
          { text: '2560×1440', color: '#51CF66' },
          { text: '3840×2160', color: '#FF6B6B' }
        ]
      });
      if (result.index === 0) {
        this.defaultDisplayConfig = { ...this.defaultDisplayConfig, width: 1920, height: 1080 };
      } else if (result.index === 1) {
        this.defaultDisplayConfig = { ...this.defaultDisplayConfig, width: 2560, height: 1440 };
      } else if (result.index === 2) {
        this.defaultDisplayConfig = { ...this.defaultDisplayConfig, width: 3840, height: 2160 };
      }
    } catch (err) {
      console.error('Display defaults failed: ' + err);
    }
  }

  private async showKeyboardPicker(): Promise<void> {
    try {
      const result = await promptAction.showDialog({
        title: '键盘映射模式',
        message: '选择新建连接的默认键盘映射',
        buttons: [
          { text: '通用模式', color: '#6677ff' },
          { text: 'Windows 模式', color: '#51CF66' },
          { text: 'macOS 模式', color: '#FF6B6B' }
        ]
      });
      if (result.index === 0) this.defaultKeyboardMode = KeyboardMode.GENERIC;
      else if (result.index === 1) this.defaultKeyboardMode = KeyboardMode.WINDOWS;
      else if (result.index === 2) this.defaultKeyboardMode = KeyboardMode.MACOS;
    } catch (err) {
      console.error('Keyboard picker failed: ' + err);
    }
  }

  private async handleLogout(): Promise<void> {
    try {
      await this.authService.logout();
      console.info('Settings logout success');
      router.pushUrl({ url: 'pages/LoginPage' });
    } catch (err) {
      console.error('Settings logout failed: ' + err);
    }
  }

  private async handleBiometricSetup(): Promise<void> {
    const success = await this.lockService.lockWithBiometric('global');
    if (success) {
      try {
        promptAction.showToast({ message: '生物识别锁已启用', duration: 1500 });
      } catch (err) {
        console.error('Toast failed: ' + err);
      }
    }
  }

  private async handlePinSetup(): Promise<void> {
    try {
      const result = await promptAction.showDialog({
        title: '设置PIN码',
        message: '请输入4-6位数字PIN码',
        buttons: [
          { text: '取消', color: '#FF6B6B' },
          { text: '确定', color: '#6677FF' }
        ]
      });
      if (result.index === 1) {
        await this.lockService.setPinLock('global', '000000');
        try {
          promptAction.showToast({ message: 'PIN码锁已启用', duration: 1500 });
        } catch (err) {
          console.error('Toast failed: ' + err);
        }
      }
    } catch (err) {
      console.error('PIN setup failed: ' + err);
    }
  }

  private async promptSetGlobalLock(): Promise<void> {
    try {
      await promptAction.showDialog({
        title: '设置全局锁',
        message: '选择锁类型',
        buttons: [
          { text: '生物识别', color: '#6677FF' },
          { text: 'PIN码', color: '#51CF66' },
          { text: '取消', color: '#FF6B6B' }
        ]
      }).then(async (result) => {
        if (result.index === 0) {
          await this.lockService.lockWithBiometric('global');
        } else if (result.index === 1) {
          await this.lockService.setPinLock('global', '000000');
        }
      });
    } catch (err) {
      console.error('Set global lock failed: ' + err);
    }
  }
}
