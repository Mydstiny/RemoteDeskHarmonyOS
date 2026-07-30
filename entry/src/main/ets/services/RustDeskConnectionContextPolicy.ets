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
  rustDeskControlPlaneCapabilitySourceForProof,
  rustDeskControlPlaneCapabilityProofMatches,
  RustDeskControlPlaneCapabilityBinding
} from './RustDeskControlPlaneCapabilityPolicy';

export type RustDeskConnectionContextCode =
  | 'ready'
  | 'account_required'
  | 'account_missing'
  | 'account_relay_mismatch'
  | 'reauthentication_required'
  | 'capability_unverified'
  | 'api_only_fallback';

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
  const profileRequiresAccount: boolean =
    rustDeskControlPlaneRequiresAccount(profile);
  if (!profileRequiresAccount) {
    return context(true, 'ready', profile, false, '', 'none', '');
  }
  const capabilitySource: RustDeskControlPlaneCapabilitySource =
    rustDeskControlPlaneCapabilitySourceForProof(
      input.capabilityProof);
  const sourceFitsProfile: boolean =
    (profile === 'official_server_pro_token' &&
      capabilitySource === 'official_server_pro') ||
    (profile === 'third_party_control_plane' &&
      capabilitySource === 'verified_third_party');
  if (!sourceFitsProfile) {
    return context(true, 'api_only_fallback',
      'third_party_api_only', false, '', 'none',
      '地址簿登录保持有效；当前没有可信控制面能力证明，本次连接按 API-only/OSS Key 模式且不发送地址簿令牌。');
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
  const binding: RustDeskControlPlaneCapabilityBinding = {
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
  const bindingVerified: boolean =
    rustDeskControlPlaneCapabilityProofMatches(
      input.capabilityProof, binding);
  const accessToken: string = rustDeskControlPlaneTokenForConnection(
    profile, false, input.accessToken,
    bindingVerified ? capabilitySource : 'none');
  if (!bindingVerified || accessToken === '') {
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
