import {
  normalizeRustDeskControlPlaneProfile,
  RustDeskControlPlaneCapabilitySource,
  RustDeskControlPlaneProfile,
  rustDeskControlPlaneProfileForKeyMode,
  rustDeskControlPlaneRequiresAccount,
  rustDeskControlPlaneTokenForConnection
} from './RustDeskControlPlanePolicy';

export type RustDeskConnectionContextCode =
  | 'ready'
  | 'account_required'
  | 'account_missing'
  | 'account_relay_mismatch'
  | 'reauthentication_required'
  | 'capability_unverified';

export interface RustDeskConnectionContextInput {
  direct: boolean
  relayId: string
  profile: RustDeskControlPlaneProfile
  keyMode: string
  accountId: string
  accountRelayId: string
  accountPresent: boolean
  accountLoginStatus: string
  accessToken: string
  thirdPartyCapabilityVerified: boolean
}

export interface RustDeskConnectionContext {
  ready: boolean
  code: RustDeskConnectionContextCode
  profile: RustDeskControlPlaneProfile
  requiresAccount: boolean
  accessToken: string
  capabilitySource: RustDeskControlPlaneCapabilitySource
  message: string
}

function context(
  ready: boolean,
  code: RustDeskConnectionContextCode,
  profile: RustDeskControlPlaneProfile,
  requiresAccount: boolean,
  accessToken: string,
  capabilitySource: RustDeskControlPlaneCapabilitySource,
  message: string
): RustDeskConnectionContext {
  return {
    ready,
    code,
    profile,
    requiresAccount,
    accessToken,
    capabilitySource,
    message
  };
}

/**
 * Resolve the one connection contract used by list preflight and the remote
 * session page. Host sourceType is intentionally absent: profile, account
 * owner binding and local capability evidence decide token projection.
 */
export function resolveRustDeskConnectionContext(
  input: RustDeskConnectionContextInput
): RustDeskConnectionContext {
  if (input.direct) {
    return context(true, 'ready', 'direct_ip', false, '', 'none', '');
  }
  const storedProfile: RustDeskControlPlaneProfile =
    normalizeRustDeskControlPlaneProfile(input.profile);
  const profile: RustDeskControlPlaneProfile =
    rustDeskControlPlaneProfileForKeyMode(storedProfile, input.keyMode);
  const requiresAccount: boolean =
    rustDeskControlPlaneRequiresAccount(profile);
  if (!requiresAccount) {
    return context(true, 'ready', profile, false, '', 'none', '');
  }
  if (input.accountId.trim() === '') {
    return context(false, 'account_required', profile, true, '', 'none',
      '该控制面要求绑定账号，请先登录并同步地址簿。');
  }
  if (!input.accountPresent) {
    return context(false, 'account_missing', profile, true, '', 'none',
      '绑定账号在本机不存在，请重新登录并同步地址簿。');
  }
  if (input.accountRelayId !== input.relayId) {
    return context(false, 'account_relay_mismatch', profile, true, '', 'none',
      '账号与当前中继不匹配，请重新选择账号或同步地址簿。');
  }
  if (input.accountLoginStatus !== 'logged_in' ||
    input.accessToken.trim() === '') {
    return context(false, 'reauthentication_required', profile, true, '', 'none',
      '控制面登录会话已失效，请重新登录后重试。');
  }
  const capabilitySource: RustDeskControlPlaneCapabilitySource =
    profile === 'official_server_pro_token'
      ? 'official_server_pro'
      : (input.thirdPartyCapabilityVerified
        ? 'verified_third_party' : 'none');
  const accessToken: string = rustDeskControlPlaneTokenForConnection(
    profile, false, input.accessToken, capabilitySource);
  if (accessToken === '') {
    return context(false, 'capability_unverified', profile, true, '',
      capabilitySource,
      '第三方控制面尚未完成本机协议能力验证，已禁止发送地址簿令牌。');
  }
  return context(true, 'ready', profile, true, accessToken,
    capabilitySource, '');
}

export function rustDeskConnectionContextDiagnostic(
  value: RustDeskConnectionContext
): string {
  return 'profile=' + value.profile +
    ', code=' + value.code +
    ', account=' + (value.requiresAccount ? 'required' : 'not_required') +
    ', token=' + (value.accessToken === '' ? 'withheld' : 'projected') +
    ', capability=' + value.capabilitySource;
}
