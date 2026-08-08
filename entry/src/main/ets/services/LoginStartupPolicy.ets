/** Login startup fallback rules kept independent from ArkUI lifecycle code. */

export const SILENT_LOGIN_TIMEOUT_MS: number = 8000;

export function shouldShowLoginAfterSilentAttempt(restored: boolean): boolean {
  return !restored;
}

/** Silent provider failure is recoverable and must never imply user logout. */
export function shouldPreserveAccountAfterSilentFailure(restored: boolean): boolean {
  return !restored;
}

export function silentLoginFallbackMessage(code: number, timedOut: boolean): string {
  if (timedOut) { return '登录状态检查超时，请重试登录'; }
  if (code === 0 || code === 1001502002) { return ''; }
  return '账号需要重新授权，请重试登录';
}
