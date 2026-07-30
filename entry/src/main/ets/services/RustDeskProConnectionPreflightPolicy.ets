export enum RustDeskProPreflightState {
  IDLE = 0,
  CONNECTING = 1,
  AUTHENTICATED = 2,
  ERROR = 3
}

export function shouldOpenRustDeskProPreflight(protocol: string, sourceType: string,
  rustdeskProManaged: boolean): boolean {
  // 这个 Sheet 实际承载所有 RustDesk 主机的连接鉴权选择；
  // Server Pro 只是其中一种主机来源，不能决定是否显示设备密码/请求批准。
  return protocol === 'rustdesk';
}

export function shouldRouteAfterRustDeskProPreflight(state: RustDeskProPreflightState): boolean {
  return state === RustDeskProPreflightState.AUTHENTICATED;
}

export function shouldKeepRustDeskProSheetOpen(state: RustDeskProPreflightState): boolean {
  return state === RustDeskProPreflightState.CONNECTING || state === RustDeskProPreflightState.ERROR;
}

export function rustDeskProPeerIdForConnection(stablePeerId: string, legacyPeerId: string): string {
  const stable: string = stablePeerId.trim();
  return stable.length > 0 ? stable : legacyPeerId.trim();
}

export function rustDeskProAccountIdForConnection(stableAccountId: string, legacyAccountId: string): string {
  const stable: string = stableAccountId.trim();
  return stable.length > 0 ? stable : legacyAccountId.trim();
}

export type RustDeskProNativeErrorKind =
  | 'pro_session_expired'
  | 'control_plane_incompatible'
  | 'device_password'
  | 'approval_timeout'
  | 'relay_auth'
  | 'peer_missing'
  | 'network'
  | 'unknown';

export interface RustDeskNativeErrorInfo {
  structured: boolean
  stage: string
  code: string
  attemptId: string
  detail: string
}

/**
 * Rust FFI errors use a small delimiter-safe envelope.  Legacy/native helper
 * messages remain readable, but are never allowed to impersonate a verified
 * Server Pro HTTP session failure.
 */
export function parseRustDeskNativeError(message: string): RustDeskNativeErrorInfo {
  const marker: string = 'RDERR|';
  const markerIndex: number = message.indexOf(marker);
  if (markerIndex < 0) {
    return { structured: false, stage: '', code: '', attemptId: '', detail: message };
  }
  const parts: string[] = message.substring(markerIndex + marker.length).split('|');
  const values: Record<string, string> = {};
  for (let i = 0; i < parts.length; i++) {
    const separator: number = parts[i].indexOf('=');
    if (separator > 0) {
      values[parts[i].substring(0, separator)] = parts[i].substring(separator + 1);
    }
  }
  return {
    structured: true,
    stage: values['stage'] || '',
    code: values['code'] || '',
    attemptId: values['attempt'] || '',
    detail: values['detail'] || message.substring(markerIndex + marker.length)
  };
}

export function classifyRustDeskProNativeError(message: string): RustDeskProNativeErrorKind {
  const parsed: RustDeskNativeErrorInfo = parseRustDeskNativeError(message);
  const value: string = parsed.detail.toLowerCase();
  if (parsed.structured && parsed.stage === 'control_plane' &&
    parsed.code === 'pro_session_expired') {
    return 'pro_session_expired';
  }
  if (parsed.structured && parsed.code === 'control_plane_login_required') {
    return 'control_plane_incompatible';
  }
  if (parsed.structured && parsed.code === 'peer_password_rejected') {
    return 'device_password';
  }
  if (parsed.structured && parsed.code === 'approval_unavailable') {
    return 'approval_timeout';
  }
  if (parsed.structured && parsed.code === 'peer_unavailable') {
    return 'peer_missing';
  }
  if (parsed.structured && parsed.code === 'relay_credential_rejected') {
    return 'relay_auth';
  }
  // This phrase is also returned by incompatible third-party relay/control
  // planes. It is diagnostic only and must never clear a local account token.
  if (value.indexOf('you have not logged in') >= 0 ||
    value.indexOf('login session has expired') >= 0 ||
    value.indexOf('session has expired') >= 0 ||
    value.indexOf('not logged in') >= 0) {
    return 'control_plane_incompatible';
  }
  if (parsed.structured && (parsed.stage === 'relay' || parsed.stage === 'rendezvous')) {
    return 'relay_auth';
  }
  if (value.indexOf('no password access') >= 0 ||
    value.indexOf('remote approval timed out') >= 0 ||
    value.indexOf('approval timed out') >= 0) {
    return 'approval_timeout';
  }
  if (value.indexOf('wrong password') >= 0 ||
    value.indexOf('invalid password') >= 0 ||
    value.indexOf('password is wrong') >= 0) {
    return 'device_password';
  }
  if (value.indexOf('id does not exist') >= 0 ||
    value.indexOf('peer not found') >= 0 ||
    value.indexOf('remote desktop is offline') >= 0 ||
    value.indexOf('peer is offline') >= 0) {
    return 'peer_missing';
  }
  if (value.indexOf('license mismatch') >= 0 ||
    value.indexOf('license overuse') >= 0 ||
    value.indexOf('key mismatch') >= 0 ||
    value.indexOf('connection refused') >= 0 ||
    value.indexOf('relay refused') >= 0) {
    return 'relay_auth';
  }
  if (value.indexOf('timed out') >= 0 ||
    value.indexOf('timeout') >= 0 ||
    value.indexOf('resolve') >= 0 ||
    value.indexOf('connection reset') >= 0 ||
    value.indexOf('network is unreachable') >= 0 ||
    value.indexOf('no route') >= 0) {
    return 'network';
  }
  return 'unknown';
}

export function rustDeskProNativeErrorMessage(kind: RustDeskProNativeErrorKind,
  authMode: string, profile: string = 'oss_key_only'): string {
  switch (kind) {
    case 'pro_session_expired':
      return 'RustDesk Server Pro 登录会话已失效，请重新登录后重试。';
    case 'control_plane_incompatible':
      if (profile === 'official_server_pro_token') {
        return '中继控制面拒绝了本次官方 Server Pro 建链令牌。应用不会仅凭这条连接错误清除当前登录账号，请核对 API 与 hbbs/hbbr 是否属于同一套 Server Pro 服务。';
      }
      if (profile === 'third_party_control_plane') {
        return '第三方控制面的 token 契约与当前连接不兼容。应用已保留登录账号，并禁止在未重新验证能力前继续投影 token。';
      }
      return '地址簿登录成功并不代表 hbbs/hbbr 接受同一 token；当前连接没有发送地址簿 token。请将中继按 OSS 公钥/共享 -k 配置，或让服务商提供明确的控制面兼容证明。';
    case 'device_password':
      return '远程 RustDesk 设备密码错误，请重新输入。';
    case 'approval_timeout':
      return authMode === 'request_approval' ? '远端未批准本次连接，请重新发起请求。' : '远端设备未提供可用密码。';
    case 'relay_auth':
      return 'RustDesk 中继鉴权失败，请检查服务器 Key 和账号绑定。';
    case 'peer_missing':
      return '地址簿中的远程设备不存在或当前离线。';
    case 'network':
      return 'RustDesk 中继服务器不可达，请检查网络和服务器配置。';
    default:
      return 'RustDesk 连接失败，请检查设备鉴权和中继配置。';
  }
}

/** Only an explicit, verified official control-plane error may invalidate a token. */
export function canInvalidateRustDeskProSession(message: string,
  profile: string): boolean {
  const parsed: RustDeskNativeErrorInfo = parseRustDeskNativeError(message);
  return profile === 'official_server_pro_token' && parsed.structured &&
    parsed.stage === 'control_plane' && parsed.code === 'pro_session_expired';
}

export function rustDeskNativeErrorDetail(message: string): string {
  return parseRustDeskNativeError(message).detail;
}
