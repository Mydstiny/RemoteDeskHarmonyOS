import { userAuth } from '@kit.UserAuthenticationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';

export enum LockType {
  NONE = 'none',
  BIOMETRIC = 'biometric',
  PIN = 'pin',
  PASSWORD = 'password'
}

@Component
export struct LockGate {
  @State isUnlocked: boolean = false;
  @State showPINInput: boolean = false;
  @State pinValue: string = '';
  @State errorMessage: string = '';
  @Prop lockType: LockType = LockType.BIOMETRIC;
  @Prop hostLabel: string = '';
  onUnlocked?: () => void;
  onCancel?: () => void;

  build() {
    Column() {
      if (!this.isUnlocked) {
        Column() {
          Text(this.hostLabel)
            .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
            .margin({ bottom: 8 })
          Text('请输入验证以解锁连接')
            .fontSize(14).fontColor('rgba(255,255,255,0.6)')
            .margin({ bottom: 32 })

          if (this.lockType === LockType.BIOMETRIC) {
            Button() {
              Image($r('app.media.ic_fingerprint'))
                .width(48).height(48).fillColor('#FFFFFF')
            }
            .width(80).height(80)
            .borderRadius(40)
            .backgroundColor('#6677ff')
            .onClick(() => {
              this.authenticateBiometric();
            })

            Text('点击指纹图标进行验证')
              .fontSize(13).fontColor('rgba(255,255,255,0.5)')
              .margin({ top: 16 })
          }

          if (this.lockType === LockType.PIN || this.lockType === LockType.PASSWORD) {
            TextInput({ placeholder: '请输入' + (this.lockType === LockType.PIN ? 'PIN码' : '密码'), text: this.pinValue })
              .width('80%').height(48)
              .backgroundColor('rgba(255,255,255,0.1)')
              .borderRadius(12)
              .fontColor('#FFFFFF')
              .placeholderColor('rgba(255,255,255,0.4)')
              .type(this.lockType === LockType.PASSWORD ? InputType.Password : InputType.Number)
              .onChange((value: string) => {
                this.pinValue = value;
                this.errorMessage = '';
              })

            if (this.errorMessage.length > 0) {
              Text(this.errorMessage)
                .fontSize(12).fontColor('#FF6B6B').margin({ top: 8 })
            }

            Button('验证')
              .width('80%').height(48)
              .borderRadius(12)
              .backgroundColor('#6677ff')
              .fontColor('#FFFFFF')
              .margin({ top: 16 })
              .onClick(() => {
                this.verifyPIN(this.pinValue);
              })
          }

          Button('取消')
            .width('80%').height(44)
            .borderRadius(12)
            .backgroundColor('rgba(255,255,255,0.1)')
            .fontColor('rgba(255,255,255,0.7)')
            .margin({ top: 12 })
            .onClick(() => {
              this.onCancel?.();
            })
        }
        .width('100%')
        .padding(24)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%').height('100%')
  }

  private async authenticateBiometric(): Promise<void> {
    try {
      const authInstance = userAuth.getAuthInstance({
        challenge: new Uint8Array(32),
        authType: [userAuth.UserAuthType.FINGERPRINT, userAuth.UserAuthType.FACE]
      });
      authInstance.on('result', {
        callback: (result: userAuth.UserAuthResult) => {
          if (result.result === userAuth.UserAuthResultCode.SUCCESS) {
            this.isUnlocked = true;
            this.onUnlocked?.();
          } else {
            this.errorMessage = '生物识别验证失败，请重试';
          }
        }
      });
      authInstance.start();
    } catch (err) {
      this.errorMessage = '生物识别不可用，错误: ' + err;
      console.error('Biometric auth failed: ' + err);
    }
  }

  private verifyPIN(input: string): void {
    if (input.length < 4) {
      this.errorMessage = this.lockType === LockType.PIN ? 'PIN码至少4位' : '密码至少6位';
      return;
    }
    this.isUnlocked = true;
    this.onUnlocked?.();
  }
}
