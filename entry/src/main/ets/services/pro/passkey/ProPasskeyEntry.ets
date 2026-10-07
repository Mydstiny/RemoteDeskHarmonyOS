import { DEBUG } from 'BuildProfile';
import { ProAppRuntime } from '../ProAppRuntime';

export const PHONE_PASSKEY_FEATURE_ID: string = 'pro.security.phonePasskey';

/**
 * 手机通行密钥 is a prototype: its page opens only in Debug builds and with the Pro entitlement. Every entry
 * (设置 → 安全与数据, Pro 功能, the AI 助理's 打开手机通行密钥) asks here, so they appear and disappear together.
 */
export function phonePasskeyEntryAvailable(): boolean {
  if (!DEBUG) { return false; }
  try {
    return ProAppRuntime.getInstance().runtime.decision(PHONE_PASSKEY_FEATURE_ID,
      ProAppRuntime.getInstance().context()).executable;
  } catch (_error) {
    return false;
  }
}
