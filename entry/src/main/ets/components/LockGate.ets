/**
 * LockGate.ets — 系统用户身份认证门。
 *
 * UserAuthInstance 是系统级资源，不允许多个业务同时 start，也不能只
 * resolve Promise 而把 result listener 留在实例上。这里把所有调用串成
 * single-flight 队列，并把实例清理绑定到唯一的 finish 路径。
 */
import { Palette, buildDark, buildLight } from '../common/Theme';
import { userAuth } from '@kit.UserAuthenticationKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  LockGateAuthKind,
  lockGateAvailableAuthKinds,
  lockGateRequestedAuthKinds
} from '../services/LockGateAuthPolicy';

export class LockGateResult {
  ok: boolean = false;
  code: number = 0;
  errMsg: string = '';
}

interface LockGateRequest {
  label: string;
  requestedKinds: LockGateAuthKind[];
  resolve: (result: LockGateResult) => void;
}

class LockGateResultCallback {
  onResult: (result: userAuth.UserAuthResult) => void =
    (_result: userAuth.UserAuthResult): void => {};
}

// ArkTS does not support the TypeScript utility type ReturnType in all
// DevEco compiler versions. Keep the small API surface we actually use here
// instead of depending on a compiler-only inferred type.
interface LockGateAuthInstance {
  on(event: string, callback: Object): void;
  off(event: string, callback: Object): void;
  start(): void;
  cancel(): void;
}

const lockGateQueue: LockGateRequest[] = [];
let lockGateRunning: boolean = false;

function authTypeForKind(kind: LockGateAuthKind): userAuth.UserAuthType {
  switch (kind) {
    case 'pin': return userAuth.UserAuthType.PIN;
    case 'fingerprint': return userAuth.UserAuthType.FINGERPRINT;
    case 'face': return userAuth.UserAuthType.FACE;
  }
}

function businessErrorCode(err: Object, fallback: number = -1): number {
  const businessError: BusinessError = err as BusinessError;
  return typeof businessError.code === 'number' ? businessError.code : fallback;
}

function pumpLockGate(): void {
  if (lockGateRunning || lockGateQueue.length === 0) {
    return;
  }
  lockGateRunning = true;
  const request: LockGateRequest | undefined = lockGateQueue.shift();
  if (request === undefined) {
    lockGateRunning = false;
    return;
  }

  let finished: boolean = false;
  const finishRequest = (result: LockGateResult): void => {
    if (finished) { return; }
    finished = true;
    lockGateRunning = false;
    request.resolve(result);
    setTimeout((): void => { pumpLockGate(); }, 0);
  };

  const availableKinds: LockGateAuthKind[] = [];
  let lastUnavailableCode: number = 12500010;
  for (let i = 0; i < request.requestedKinds.length; i++) {
    const kind: LockGateAuthKind = request.requestedKinds[i];
    try {
      userAuth.getAvailableStatus(authTypeForKind(kind), userAuth.AuthTrustLevel.ATL2);
      availableKinds.push(kind);
    } catch (err) {
      lastUnavailableCode = businessErrorCode(err as Object, lastUnavailableCode);
    }
  }

  const admittedKinds: LockGateAuthKind[] = lockGateAvailableAuthKinds(
    request.requestedKinds, availableKinds);
  if (admittedKinds.length === 0) {
    finishRequest({ ok: false, code: lastUnavailableCode, errMsg: '' });
    return;
  }

  let challenge: Uint8Array;
  try {
    challenge = cryptoFramework.createRandom().generateRandomSync(16).data;
  } catch (err) {
    const businessError: BusinessError = err as BusinessError;
    const message: string = typeof businessError.message === 'string' ? businessError.message : '';
    finishRequest({
      ok: false,
      code: businessErrorCode(err as Object),
      errMsg: message !== '' ? message : '无法生成身份认证随机挑战'
    });
    return;
  }

  const authTypes: userAuth.UserAuthType[] = admittedKinds.map(
    (kind: LockGateAuthKind): userAuth.UserAuthType => authTypeForKind(kind));
  const authParam: userAuth.AuthParam = {
    challenge: challenge,
    authType: authTypes,
    authTrustLevel: userAuth.AuthTrustLevel.ATL2
  };
  const widgetParam: userAuth.WidgetParam = {
    title: request.label || '验证系统身份'
  };

  let instance: LockGateAuthInstance | undefined;
  const callback: LockGateResultCallback = new LockGateResultCallback();
  let settledInstance: boolean = false;
  const cleanupInstance = (): void => {
    if (instance === undefined) { return; }
    try { instance.off('result', callback); } catch (_e) { /* completed instance */ }
    try { instance.cancel(); } catch (_e) { /* completed/cancelled instance */ }
    instance = undefined;
  };
  const settleInstance = (result: LockGateResult): void => {
    if (settledInstance || finished) { return; }
    settledInstance = true;
    cleanupInstance();
    finishRequest(result);
  };
  callback.onResult = (result: userAuth.UserAuthResult): void => {
    const code: number = result.result as number;
    settleInstance(code === userAuth.UserAuthResultCode.SUCCESS ?
      { ok: true, code: 0, errMsg: '' } :
      { ok: false, code: code, errMsg: '' });
  };

  try {
    instance = userAuth.getUserAuthInstance(authParam, widgetParam) as LockGateAuthInstance;
    if (!instance || typeof instance.start !== 'function') {
      settleInstance({ ok: false, code: -1, errMsg: 'UserAuthInstance 不可用' });
      return;
    }
    instance.on('result', callback);
    instance.start();
  } catch (err) {
    const businessError: BusinessError = err as BusinessError;
    const message: string = typeof businessError.message === 'string' ? businessError.message : '';
    settleInstance({ ok: false, code: businessErrorCode(err as Object), errMsg: message });
  }
}

export function showLockGate(label: string, lockType: string): Promise<LockGateResult> {
  const requestedKinds: LockGateAuthKind[] = lockGateRequestedAuthKinds(lockType);
  if (requestedKinds.length === 0) {
    const result: LockGateResult = new LockGateResult();
    result.ok = true;
    return Promise.resolve(result);
  }
  return new Promise((resolve: (result: LockGateResult) => void): void => {
    lockGateQueue.push({
      label: label || '验证系统身份',
      requestedKinds: requestedKinds,
      resolve: resolve
    });
    pumpLockGate();
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
  hostLabel: string = '';
  onResult?: (success: boolean) => void;
  onDismiss?: () => void;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private async verifyPin(): Promise<void> {
    const r: LockGateResult = await showLockGate(
      this.hostLabel || '验证系统锁屏密码', 'pin');
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

        Text('将使用设备的系统锁屏密码验证；应用不会读取或保存密码。')
          .fontSize(13).fontColor(this.pal().text2).width('80%')

        Row() {
          Button('取消').layoutWeight(1).height(44)
            .backgroundColor(this.pal().surface).fontColor(this.pal().text2).borderRadius(10)
            .onClick(() => { if (this.onDismiss) { this.onDismiss(); } })
          Blank().width(12)
          Button('使用锁屏密码').layoutWeight(1).height(44)
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
