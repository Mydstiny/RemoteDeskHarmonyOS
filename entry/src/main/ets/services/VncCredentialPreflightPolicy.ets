export type VncCredentialPreflightState =
  'missing' | 'available' | 'locked' | 'consent_required' | 'invalid';

export function vncCredentialPreflightNeedsPrompt(
  state: VncCredentialPreflightState,
  transientDecisionAvailable: boolean,
  forcePrompt: boolean
): boolean {
  if (forcePrompt) { return true; }
  if (transientDecisionAvailable) { return false; }
  return state !== 'available';
}

export function vncCredentialPreflightMessage(
  state: VncCredentialPreflightState,
  retry: boolean
): string {
  if (retry) {
    return '上次 VNC 密码认证失败。请重新输入密码，或明确选择“无密码连接”。';
  }
  if (state === 'locked') {
    return '已保存的 VNC 密码需要先解锁应用加密，也可以输入本次临时密码。';
  }
  if (state === 'consent_required') {
    return '这台设备尚未确认使用已同步的未加密密码，请确认使用或重新输入。';
  }
  if (state === 'invalid') {
    return '已保存的 VNC 密码记录无效，请重新输入。';
  }
  return '请在进入连接界面前完成 VNC 认证。';
}

/**
 * Selects the native connection password without treating an explicit
 * no-password decision as an absent transient credential.
 */
export function vncCredentialPasswordForConnect(
  transientDecisionProvided: boolean,
  transientPassword: string,
  loadSavedPassword: () => string
): string {
  return transientDecisionProvided ? transientPassword : loadSavedPassword();
}

export function vncAuthFailureShouldReplaceSavedCredential(
  transientDecisionProvided: boolean,
  passwordSentToNative: string
): boolean {
  return !transientDecisionProvided && passwordSentToNative.length > 0;
}
