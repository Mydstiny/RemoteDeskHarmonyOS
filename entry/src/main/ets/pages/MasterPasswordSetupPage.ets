/**
 * MasterPasswordSetupPage.ets — 主密码设置/解锁页面
 *
 * 首次使用: 设置主密码 → PBKDF2 派生 DEK → 加密所有敏感数据
 * 新设备:   输入已有主密码 → 解锁 DEK → 读取加密数据
 *
 * 集成华为密码保险箱 (type=NEW_PASSWORD/PASSWORD + enableAutoFill)
 * 跨设备同步: 密码保险箱通过华为账号自动同步主密码
 */
import { DataCrypto } from '../services/DataCrypto';
import { CloudStore } from '../services/CloudStore';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction, router } from '@kit.ArkUI';
import { Palette, buildDark, buildLight } from '../common/Theme';

const TAG = 'MasterPasswordSetup';
const DOMAIN = 0x0012;

@Entry
@Component
struct MasterPasswordSetupPage {
  @State password: string = '';
  @State confirmPassword: string = '';
  @State isNewSetup: boolean = true;
  @State errorMessage: string = '';
  @State loading: boolean = false;
  @State attemptCount: number = 0;
  @State locked: boolean = false;
  @State lockCountdown: number = 0;
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';

  private crypto: DataCrypto = DataCrypto.getInstance();
  private cloud: CloudStore = CloudStore.getInstance();
  private lockTimer: number = -1;

  aboutToAppear(): void {
    try {
      this.isNewSetup = !this.crypto.isSetupComplete();
    } catch (_e) {
      this.isNewSetup = true;
    }
  }

  aboutToDisappear(): void {
    if (this.lockTimer >= 0) {
      clearInterval(this.lockTimer);
      this.lockTimer = -1;
    }
  }

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  build() {
    Column() {
      // 标题区
      Text(this.isNewSetup ? '设置安全密码' : '输入安全密码')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.pal().text)
        .margin({ top: 60, bottom: 8 })

      Text('此密码用于加密云同步中的敏感数据\n(主机密码、SSH 密钥、验证码)')
        .fontSize(14)
        .fontColor(this.pal().text2)
        .textAlign(TextAlign.Center)
        .margin({ bottom: 40 })
        .width('85%')

      // 密码输入区
      if (this.isNewSetup) {
        // 首次设置: NEW_PASSWORD 触发密码保险箱 + 强密码生成
        TextInput({ placeholder: '输入主密码 (12-32位, 大写开头, 含特殊字符)', text: this.password })
          .type(InputType.NEW_PASSWORD)
          .passwordRules('begin:[upper],special:[yes],len:[maxlen:32,minlen:12]')
          .enableAutoFill(true)
          .height(48)
          .width('85%')
          .fontSize(15)
          .fontColor(this.pal().text)
          .placeholderColor(this.pal().text3)
          .backgroundColor(this.pal().surface)
          .borderRadius(8)
          .padding({ left: 12, right: 12 })
          .margin({ bottom: 12 })
          .onChange((value: string) => {
            this.password = value;
            this.errorMessage = '';
          })

        TextInput({ placeholder: '确认主密码', text: this.confirmPassword })
          .type(InputType.NEW_PASSWORD)
          .enableAutoFill(true)
          .height(48)
          .width('85%')
          .fontSize(15)
          .fontColor(this.pal().text)
          .placeholderColor(this.pal().text3)
          .backgroundColor(this.pal().surface)
          .borderRadius(8)
          .padding({ left: 12, right: 12 })
          .margin({ bottom: 24 })
          .onChange((value: string) => {
            this.confirmPassword = value;
            this.errorMessage = '';
          })
      } else {
        // 解锁: PASSWORD 触发密码保险箱自动填充
        TextInput({ placeholder: '输入主密码解锁', text: this.password })
          .type(InputType.Password)
          .enableAutoFill(true)
          .height(48)
          .width('85%')
          .fontSize(15)
          .fontColor(this.pal().text)
          .placeholderColor(this.pal().text3)
          .backgroundColor(this.pal().surface)
          .borderRadius(8)
          .padding({ left: 12, right: 12 })
          .margin({ bottom: 24 })
          .onChange((value: string) => {
            this.password = value;
            this.errorMessage = '';
          })
          .enabled(!this.locked)

        if (this.locked) {
          Text('已锁定, 请等待 ' + this.lockCountdown + ' 秒')
            .fontSize(13)
            .fontColor(this.pal().danger)
            .margin({ bottom: 12 })
        }
      }

      // 错误提示
      if (this.errorMessage) {
        Text(this.errorMessage)
          .fontSize(13)
          .fontColor(this.pal().danger)
          .textAlign(TextAlign.Center)
          .width('85%')
          .margin({ bottom: 12 })
      }

      // 操作按钮
      Button(this.loading ? '处理中...' : (this.isNewSetup ? '完成设置' : '解锁'))
        .width('85%')
        .height(48)
        .fontSize(16)
        .fontColor(Color.White)
        .backgroundColor(this.canSubmit() ? this.accentColor : this.pal().divider)
        .borderRadius(8)
        .enabled(this.canSubmit())
        .margin({ bottom: 24 })
        .onClick(() => {
          this.handleSubmit();
        })

      // 跳过 (仅首次设置)
      if (this.isNewSetup) {
        Text('跳过 (数据将以明文存储, 不推荐)')
          .fontSize(12)
          .fontColor(this.pal().text3)
          .onClick(() => {
            this.showSkipWarning();
          })
      }

      // 安全说明
      Text('密码保险箱将自动同步到您的其他华为设备')
        .fontSize(11)
        .fontColor(this.pal().text3)
        .textAlign(TextAlign.Center)
        .width('85%')
        .margin({ top: 40 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.pal().bg)
  }

  private canSubmit(): boolean {
    if (this.locked || this.loading) {
      return false;
    }
    if (this.isNewSetup) {
      return this.password.length >= 12
        && this.confirmPassword.length >= 12
        && this.password[0] >= 'A' && this.password[0] <= 'Z'
        && this.hasSpecialChar(this.password);
    }
    return this.password.length > 0;
  }

  private hasSpecialChar(s: string): boolean {
    const specials = '!@#$%^&*()-_=+[]{}|;:\'",.<>?/`~';
    for (let i = 0; i < s.length; i++) {
      if (specials.indexOf(s[i]) >= 0) { return true; }
    }
    return false;
  }

  private async handleSubmit(): Promise<void> {
    if (this.isNewSetup) {
      await this.doSetup();
    } else {
      await this.doUnlock();
    }
  }

  private async doSetup(): Promise<void> {
    // 验证密码 (对齐 passwordRules: minlen:12 + begin:[upper] + special:[yes])
    if (this.password !== this.confirmPassword) {
      this.errorMessage = '两次输入的密码不一致';
      return;
    }
    if (this.password.length < 12) {
      this.errorMessage = '密码长度不足 (最少 12 位)';
      return;
    }
    if (this.password[0] < 'A' || this.password[0] > 'Z') {
      this.errorMessage = '密码必须以大写字母开头';
      return;
    }
    if (!this.hasSpecialChar(this.password)) {
      this.errorMessage = '密码必须包含特殊字符 (!@#$%...)';
      return;
    }

    this.loading = true;
    this.errorMessage = '';

    try {
      // 1. 设置主密码 (生成盐值, 派生 DEK, 存储验证器)
      await this.crypto.setMasterPassword(this.password);

      // 2. 自动迁移已有明文数据
      const count = await this.crypto.autoMigrate(this.cloud);

      promptAction.showToast({
        message: count > 0 ? '已加密 ' + count + ' 条数据' : '安全密码已设置',
        duration: 2000
      });

      // 3. 返回上一页 (触发密码保险箱保存)
      router.back();
    } catch (err) {
      this.errorMessage = '设置失败, 请重试';
      hilog.error(DOMAIN, TAG, '设置主密码失败: ' + JSON.stringify(err));
    } finally {
      this.loading = false;
    }
  }

  private async doUnlock(): Promise<void> {
    this.loading = true;
    this.errorMessage = '';

    try {
      const ok = await this.crypto.unlock(this.password);

      if (ok) {
        // 解锁成功 → 自动迁移 (如果有新数据)
        const count = await this.crypto.autoMigrate(this.cloud);
        if (count > 0) {
          promptAction.showToast({ message: '已加密 ' + count + ' 条新数据', duration: 1500 });
        }
        // 清除密码内存
        this.password = '';
        router.back();
      } else {
        // 解锁失败
        this.attemptCount++;
        const remaining = this.crypto.MAX_ATTEMPTS - this.attemptCount;
        if (remaining > 0) {
          this.errorMessage = '密码错误, 还剩 ' + remaining + ' 次尝试';
        } else {
          this.locked = true;
          this.lockCountdown = 30;
          this.errorMessage = '已锁定, 请等待 30 秒';
          this.lockTimer = setInterval(() => {
            this.lockCountdown--;
            if (this.lockCountdown <= 0) {
              clearInterval(this.lockTimer);
              this.lockTimer = -1;
              this.locked = false;
              this.attemptCount = 0;
              this.errorMessage = '';
            }
          }, 1000);
        }
      }
    } catch (err) {
      this.errorMessage = '解锁失败, 请重试';
      hilog.error(DOMAIN, TAG, '解锁失败: ' + JSON.stringify(err));
    } finally {
      this.loading = false;
    }
  }

  private showSkipWarning(): void {
    AlertDialog.show({
      title: '跳过安全设置',
      message: '如果不设置主密码, 您的敏感数据 (主机密码、SSH 密钥、验证码) 将以明文形式存储在云端。\n\n不推荐跳过, 但您可以稍后在设置中配置。',
      primaryButton: {
        value: '仍要跳过',
        action: () => {
          router.back();
        }
      },
      secondaryButton: {
        value: '去设置',
        action: () => { /* stay on page */ }
      }
    });
  }
}
