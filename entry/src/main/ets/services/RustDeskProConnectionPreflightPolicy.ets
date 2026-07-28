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
  | 'device_password'
  | 'approval_timeout'
  | 'relay_auth'
  | 'peer_missing'
  | 'network'
  | 'unknown';

export function classifyRustDeskProNativeError(message: string): RustDeskProNativeErrorKind {
  const value: string = message.toLowerCase();
  if (value.indexOf('you have not logged in') >= 0 ||
    value.indexOf('login session has expired') >= 0 ||
    value.indexOf('session has expired') >= 0 ||
    value.indexOf('not logged in') >= 0) {
    return 'pro_session_expired';
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
  authMode: string): string {
  switch (kind) {
    case 'pro_session_expired':
      return 'RustDesk Server Pro 登录会话已失效，请重新登录后重试。';
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
