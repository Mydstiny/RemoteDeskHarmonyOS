/**
 * UserAuthManager.ets — 系统用户身份认证管理器。
 */
import { userAuth } from '@kit.UserAuthenticationKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class UserAuthManager {
  authTypes: userAuth.UserAuthType[] = [
    userAuth.UserAuthType.PIN,
    userAuth.UserAuthType.FINGERPRINT,
    userAuth.UserAuthType.FACE,
  ];
  authTrustLevel: userAuth.AuthTrustLevel = userAuth.AuthTrustLevel.ATL2;

  widgetParam: userAuth.WidgetParam = {
    title: '请验证系统身份',
  };

  onAuthTipCallback?: (tipInfo: userAuth.AuthTipInfo) => void;

  // 查询设备生物识别能力 (排除 PIN)
  isBiometricAvailable(): boolean {
    try { userAuth.getAvailableStatus(userAuth.UserAuthType.FACE, userAuth.AuthTrustLevel.ATL1); return true; } catch { /* */ }
    try { userAuth.getAvailableStatus(userAuth.UserAuthType.FINGERPRINT, userAuth.AuthTrustLevel.ATL1); return true; } catch { /* */ }
    return false;
  }

  // 获取设备支持的认证方式 (供 LockGatePinDialog 等组件使用)
  getAvailableAuthTypes(): userAuth.UserAuthType[] {
    const types: userAuth.UserAuthType[] = [];
    try { userAuth.getAvailableStatus(userAuth.UserAuthType.PIN, this.authTrustLevel); types.push(userAuth.UserAuthType.PIN); } catch { /* */ }
    try { userAuth.getAvailableStatus(userAuth.UserAuthType.FINGERPRINT, this.authTrustLevel); types.push(userAuth.UserAuthType.FINGERPRINT); } catch { /* */ }
    try { userAuth.getAvailableStatus(userAuth.UserAuthType.FACE, this.authTrustLevel); types.push(userAuth.UserAuthType.FACE); } catch { /* */ }
    return types;
  }

  startUserAuth(): Promise<userAuth.UserAuthResult> {
    return this.startUserAuthWithTypes(this.getAvailableAuthTypes());
  }

  startUserAuthWithTypes(authTypes: userAuth.UserAuthType[]): Promise<userAuth.UserAuthResult> {
    return new Promise((resolve, reject) => {
      try {
        if (authTypes.length === 0) {
          reject(new Error('[UserAuth] 系统尚未录入可用的身份认证凭据'));
          return;
        }
        if (typeof userAuth.getUserAuthInstance !== 'function') {
          reject(new Error('[UserAuth] API不可用: getUserAuthInstance 不存在'));
          return;
        }
        const challenge: Uint8Array =
          cryptoFramework.createRandom().generateRandomSync(16).data;
        const inst = userAuth.getUserAuthInstance(
          { challenge: challenge, authType: authTypes, authTrustLevel: this.authTrustLevel },
          { title: this.widgetParam.title }
        );
        if (!inst || typeof inst.start !== 'function') {
          reject(new Error('[UserAuth] UserAuthInstance 无效'));
          return;
        }
        const callback = {
          onResult: (result: userAuth.UserAuthResult): void => {
            try { inst.off('result', callback); } catch (_e) { /* completed instance */ }
            try { inst.cancel(); } catch (_e) { /* completed/cancelled instance */ }
            resolve(result);
          }
        };
        inst.on('result', callback);
        inst.start();
      } catch (err) {
        const be: BusinessError = err as BusinessError;
        const typesStr: string = '[' + authTypes.map((t: userAuth.UserAuthType) => t as number).join(',') + ']';
        reject(new Error('[UserAuth] getUserAuthInstance: code=' + be.code + ' msg=' + be.message +
          ' | types=' + typesStr + ' ATL2'));
      }
    });
  }

  formatAuthErrorCode(code: number): string {
    switch (code) {
      case 12500000: return '认证成功';
      case 12500001: return '认证失败';
      case 12500002: return '通用操作失败';
      case 12500003: return '操作取消';
      case 12500004: return '操作超时';
      case 12500005: return '不支持的认证类型';
      case 12500006: return '不支持的认证等级';
      case 12500007: return '系统繁忙';
      case 12500008: return '参数错误';
      case 12500009: return '认证器已锁定';
      case 12500010: return '用户未录入认证信息';
      case 12500011: return '用户切换到自定义认证';
      case 12500013: return 'PIN码已过期';
      default: return '未知错误 (' + code + ')';
    }
  }
}

export const userAuthManager = new UserAuthManager();
