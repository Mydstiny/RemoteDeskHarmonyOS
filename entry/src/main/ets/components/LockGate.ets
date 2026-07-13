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

      // 检测设备支持的认证类型
      const types: userAuth.UserAuthType[] = [];
      let hasBio: boolean = false;
      let pinOk: boolean = false;

      try {
        userAuth.getAvailableStatus(userAuth.UserAuthType.FACE, userAuth.AuthTrustLevel.ATL1);
        types.push(userAuth.UserAuthType.FACE);
        hasBio = true;
      } catch { /* FACE不可用 */ }
      try {
        userAuth.getAvailableStatus(userAuth.UserAuthType.FINGERPRINT, userAuth.AuthTrustLevel.ATL1);
        types.push(userAuth.UserAuthType.FINGERPRINT);
        hasBio = true;
      } catch { /* FINGERPRINT不可用 */ }
      try {
        userAuth.getAvailableStatus(userAuth.UserAuthType.PIN, userAuth.AuthTrustLevel.ATL1);
        types.push(userAuth.UserAuthType.PIN);
        pinOk = true;
      } catch { /* PIN不可用 */ }

      // 三个都没有 → 未录入
      if (types.length === 0) {
        resolve({ ok: false, code: 12500010, errMsg: '[showLockGate] 未录入认证信息' });
        return;
      }

      // 一次性传入所有可用类型, 系统Widget原生处理级联
      const typesStr: string = '[' + types.map((t: userAuth.UserAuthType) => t as number).join(',') + ']';
      const ap: userAuth.AuthParam = {
        challenge: challenge,
        authType: types,
        authTrustLevel: userAuth.AuthTrustLevel.ATL1
      };
      const wp: userAuth.WidgetParam = { title: title };

      try {
        const inst = userAuth.getUserAuthInstance(ap, wp);
        if (!inst || typeof inst.start !== 'function') {
          resolve({ ok: false, code: -1, errMsg: '[showLockGate] getInstance null types=' + typesStr });
          return;
        }
        inst.on('result', {
          onResult: (result: userAuth.UserAuthResult) => {
            if (result.result === userAuth.UserAuthResultCode.SUCCESS) {
              resolve({ ok: true, code: 0, errMsg: '' });
            } else {
              resolve({ ok: false, code: result.result as number,
                errMsg: '[showLockGate] code=' + (result.result as number) + ' types=' + typesStr });
            }
          }
        });
        inst.start();
      } catch (err) {
        const be: BusinessError = err as BusinessError;
        resolve({ ok: false, code: -1,
          errMsg: '[showLockGate] getInstance: code=' + be.code + ' msg=' + be.message + ' types=' + typesStr });
      }
    } else {
      resolve({ ok: true, code: 0, errMsg: '' });
    }
  });
}

/** 根据认证失败的错误码返回用户友好的提示消息 */
export function lockGateErrorMessage(r: LockGateResult): string {
  if (r.errMsg !== '') { return r.errMsg; }
  const code: number = r.code;
  switch (code) {
    case -1: return r.errMsg !== '' ? r.errMsg : '认证服务启动失败';
    case 12500003: return ''; // 用户取消
    case 12500004: return '认证超时';
    case 12500005: return '设备不支持该认证方式';
    case 12500006: return '设备不支持该认证等级';
    case 12500007: return '认证服务繁忙';
    case 12500009: return '认证器已锁定，请稍后重试';
    case 12500010: return '未录入认证信息，请先在设置中录入';
    case 12500013: return 'PIN码已过期';
    default: return '认证失败 (code: ' + code + ')';
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
