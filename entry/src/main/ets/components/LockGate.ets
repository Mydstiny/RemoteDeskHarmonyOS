/**
 * LockGate.ets — 生物识别锁认证门 (v10)
 *
 * 官方原生逻辑: 将设备支持的所有认证类型一次性传入,
 * 系统Widget自动处理级联: 人脸→指纹→密码 (无需应用层编排)
 * - 三样都不支持 → 12500010 (未录入认证信息)
 * - lockType 非 'biometric'/'' → 直接通过
 */
import { Palette, buildDark, buildLight } from '../common/Theme';
import { userAuth } from '@kit.UserAuthenticationKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class LockGateResult {
  ok: boolean = false;
  code: number = 0;
  errMsg: string = '';
}

export function showLockGate(label: string, lockType: string): Promise<LockGateResult> {
  return new Promise((resolve) => {
    if (lockType === 'biometric' || lockType === '') {
      const title: string = label || '验证身份';
      const challenge: Uint8Array = new Uint8Array(16);
      for (let i = 0; i < 16; i++) { challenge[i] = (i + 1) as number; }
      const wp: userAuth.WidgetParam = { title: title };

      // Do not build one mixed FACE/FINGERPRINT/PIN request. On API 23
      // getAvailableStatus can be asynchronous or return a non-success
      // status without throwing; the old code consequently passed unsupported
      // types into getUserAuthInstance and surfaced the raw showLockGate
      // exception. Try one concrete type at a time and fall back to PIN.
      const candidates: userAuth.UserAuthType[] = [
        userAuth.UserAuthType.FACE,
        userAuth.UserAuthType.FINGERPRINT,
        userAuth.UserAuthType.PIN
      ];
      const tryNext = (index: number, lastCode: number, lastMessage: string): void => {
        if (index >= candidates.length) {
          resolve({ ok: false, code: lastCode, errMsg: lastMessage });
          return;
        }
        const authType: userAuth.UserAuthType = candidates[index];
        const ap: userAuth.AuthParam = {
          challenge: challenge,
          authType: [authType],
          authTrustLevel: userAuth.AuthTrustLevel.ATL1
        };
        try {
          const inst = userAuth.getUserAuthInstance(ap, wp);
          if (!inst || typeof inst.start !== 'function') {
            tryNext(index + 1, -1, '');
            return;
          }
          let settled: boolean = false;
          inst.on('result', {
            onResult: (result: userAuth.UserAuthResult) => {
              if (settled) { return; }
              settled = true;
              const code: number = result.result as number;
              if (code === userAuth.UserAuthResultCode.SUCCESS) {
                resolve({ ok: true, code: 0, errMsg: '' });
                return;
              }
              // Unsupported type/level is a probe failure, not a user
              // cancellation; continue to the next system authenticator.
              if (code === 12500005 || code === 12500006 || code === 12500010) {
                tryNext(index + 1, code, '');
                return;
              }
              resolve({ ok: false, code: code, errMsg: '' });
            }
          });
          inst.start();
        } catch (err) {
          const be: BusinessError = err as BusinessError;
          const code: number = typeof be.code === 'number' ? be.code : -1;
          tryNext(index + 1, code, '');
        }
      };
      tryNext(0, 12500010, '');
    } else {
      resolve({ ok: true, code: 0, errMsg: '' });
    }
  });
}

/** 根据认证失败的错误码返回用户友好的提示消息 */
export function lockGateErrorMessage(r: LockGateResult): string {
  const code: number = r.code;
  switch (code) {
    case -1: return '系统身份认证启动失败，请检查设备 PIN/生物识别设置后重试';
    case 12500003: return ''; // 用户取消
    case 12500004: return '认证超时';
    case 12500005: return '设备不支持该认证方式';
    case 12500006: return '设备不支持该认证等级';
    case 12500007: return '认证服务繁忙';
    case 12500009: return '认证器已锁定，请稍后重试';
    case 12500010: return '未录入认证信息，请先在设置中录入';
    case 12500013: return 'PIN码已过期';
    default: return r.errMsg !== '' ? r.errMsg : '认证失败 (code: ' + code + ')';
  }
}



@Component
export struct LockGatePinDialog {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @State pinInput: string = '';
  @State pinError: string = '';
  hostLabel: string = '';
  onResult?: (success: boolean) => void;
  onDismiss?: () => void;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private async verifyPin(): Promise<void> {
    const r: LockGateResult = await showLockGate(this.hostLabel || '验证身份', 'biometric');
    if (this.onResult) {
      this.onResult(r.ok);
    }
  }

  build() {
    Column() {
      Column() {
        Text('安全验证').fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).margin({ bottom: 4 })
        Text(this.hostLabel).fontSize(13).fontColor(this.pal().text2)
          .margin({ bottom: 20 })

        TextInput({ placeholder: '输入 PIN 码', text: this.pinInput })
          .type(InputType.Password).width('80%').height(44)
          .backgroundColor(this.pal().surface).borderRadius(10)
          .fontColor(this.pal().text).maxLength(6)
          .onChange((v: string) => { this.pinInput = v; this.pinError = ''; })

        if (this.pinError !== '') {
          Text(this.pinError).fontSize(12).fontColor(this.pal().danger).margin({ top: 8 })
        }

        Row() {
          Button('取消').layoutWeight(1).height(44)
            .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(10)
            .onClick(() => { if (this.onDismiss) { this.onDismiss(); } })
          Blank().width(12)
          Button('确认').layoutWeight(1).height(44)
            .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10)
            .onClick(() => { this.verifyPin(); })
        }.width('80%').margin({ top: 20 })
      }
      .width('86%').padding(28).borderRadius(20)
      .backgroundColor(this.pal().bg).backgroundBlurStyle(BlurStyle.Regular)
      .shadow({ radius: 32, color: 'rgba(0,0,0,0.2)', offsetY: 8 })
      .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
    }
    .width('100%').height('100%')
    .backgroundColor(this.pal().lockOverlay)
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
  }
}
