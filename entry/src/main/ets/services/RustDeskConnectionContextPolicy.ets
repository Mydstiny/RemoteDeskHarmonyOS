import {
  normalizeRustDeskControlPlaneProfile,
  RustDeskControlPlaneCapabilitySource,
  RustDeskControlPlaneProfile,
  rustDeskControlPlaneProfileForKeyMode,
  rustDeskControlPlaneRequiresAccount,
  rustDeskControlPlaneTokenForConnection
} from './RustDeskControlPlanePolicy';
import {
  RustDeskControlPlaneCapabilityProof
} from '../model/RustDeskControlPlaneCapabilityModels';
import {
  rustDeskControlPlaneCapabilityProofMatches,
  RustDeskControlPlaneCapabilityBinding
} from './RustDeskControlPlaneCapabilityPolicy';

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
  accessTokenFingerprint: string
  tokenGeneration: number
  ownerScopeId: string
  accountApiServer: string
  configuredApiServer: string
  idServer: string
  idServerPort: number
  relayServer: string
  relayPort: number
  serverKeyMode: string
  serverKey: string
  capabilityProof?: RustDeskControlPlaneCapabilityProof
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
  const expectedSource: RustDeskControlPlaneCapabilitySource =
    profile === 'official_server_pro_token'
      ? 'official_server_pro'
      : (profile === 'third_party_control_plane'
        ? 'verified_third_party' : 'none');
  const binding: RustDeskControlPlaneCapabilityBinding = {
    source: expectedSource,
    ownerScopeId: input.ownerScopeId,
    accountId: input.accountId,
    relayId: input.relayId,
    tokenGeneration: input.tokenGeneration,
    accessTokenFingerprint: input.accessTokenFingerprint,
    accountApiServer: input.accountApiServer,
    configuredApiServer: input.configuredApiServer,
    idServer: input.idServer,
    idServerPort: input.idServerPort,
    relayServer: input.relayServer,
    relayPort: input.relayPort,
    serverKeyMode: input.serverKeyMode,
    serverKey: input.serverKey
  };
  const capabilitySource: RustDeskControlPlaneCapabilitySource =
    expectedSource !== 'none' &&
    rustDeskControlPlaneCapabilityProofMatches(
      input.capabilityProof, binding)
      ? expectedSource : 'none';
  const accessToken: string = rustDeskControlPlaneTokenForConnection(
    profile, false, input.accessToken, capabilitySource);
  if (accessToken === '') {
    return context(false, 'capability_unverified', profile, true, '',
      capabilitySource,
      '控制面能力证明与当前账号、API、端点或服务器身份不一致，已禁止发送地址簿令牌；请重新登录并同步验证。');
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
