import { RustDeskProAccountState } from '../model/RustDeskProModels';

export enum RustDeskProPreflightState {
  IDLE = 0,
  CONNECTING = 1,
  AUTHENTICATED = 2,
  ERROR = 3
}

/**
 * Why a rendezvous handshake does or does not carry a Pro session token.
 *
 * `requires_login` is the state that matters for diagnostics: an account row
 * exists for this relay but holds no usable token. That is the normal outcome
 * after a reinstall, because the access token is local-only by design and
 * cloud sync restores only the account metadata.
 */
export type RustDeskProSessionState = 'not_configured' | 'ready' | 'requires_login';

export interface RustDeskProSessionResolution {
  token: string;
  state: RustDeskProSessionState;
}

/**
 * Select the Server Pro session token to send with the rendezvous handshake.
 *
 * hbbs with account access control enabled refuses an unauthenticated
 * PunchHoleRequest with "You have not logged in or your login session has
 * expired", so a logged-in account's token has to reach the FFI layer.
 *
 * Resolution order:
 *   1. Direct connections never touch a rendezvous server — send no token.
 *   2. The account the host is explicitly bound to (Pro-imported hosts).
 *   3. Any logged-in account on the same relay, newest login first. This is
 *      what lets a manually added host on a Pro relay authenticate without
 *      being re-imported from the address book.
 *
 * A tokenless or expired row is never sent as a credential; it is reported as
 * `requires_login` so the caller can say what to do instead of surfacing the
 * server's opaque rejection.
 */
export function resolveRustDeskProSession(accounts: RustDeskProAccountState[],
  proAccountId: string, legacyAccountId: string, relayId: string,
  directEnabled: boolean): RustDeskProSessionResolution {
  if (directEnabled) { return { token: '', state: 'not_configured' }; }

  const usable = (account: RustDeskProAccountState): boolean =>
    account.accessToken.length > 0 && account.loginStatus !== 'expired';

  const relay: string = relayId.trim();
  const boundIds: string[] = [proAccountId.trim(), legacyAccountId.trim()];

  const isBoundRow = (account: RustDeskProAccountState): boolean =>
    boundIds.indexOf(account.id) >= 0 || (relay.length > 0 && account.relayId === relay);

  for (const boundId of boundIds) {
    if (boundId.length === 0) { continue; }
    const bound = accounts.find((account: RustDeskProAccountState): boolean =>
      account.id === boundId && usable(account));
    if (bound !== undefined) { return { token: bound.accessToken, state: 'ready' }; }
  }

  if (relay.length > 0) {
    let best: RustDeskProAccountState | undefined = undefined;
    for (const account of accounts) {
      if (account.relayId !== relay || !usable(account)) { continue; }
      if (best === undefined || account.lastLoginAt > best.lastLoginAt) { best = account; }
    }
    if (best !== undefined) { return { token: best.accessToken, state: 'ready' }; }
  }

  // No usable token. Distinguish "this relay has an account that needs a fresh
  // login" from "no Pro account was ever configured" (a plain OSS relay).
  const stale = accounts.some(isBoundRow);
  return { token: '', state: stale ? 'requires_login' : 'not_configured' };
}

/** Substrings hbbs/hbbr use when refusing an unauthenticated connection. */
const RUSTDESK_LOGIN_REQUIRED_MARKERS: string[] = [
  'you have not logged in',
  'login session has expired',
  'connection is not allowed'
];

/**
 * Turn the server's account-control rejection into something actionable.
 *
 * Returns '' for every other failure so unrelated errors keep their own
 * message. This deliberately runs only after a real rejection rather than
 * blocking the attempt up front: a relay may carry stale account metadata and
 * still allow anonymous connections when access control is switched off.
 */
export function rustDeskProLoginHint(ffiError: string, state: RustDeskProSessionState): string {
  const lowered: string = ffiError.toLowerCase();
  const rejected: boolean = RUSTDESK_LOGIN_REQUIRED_MARKERS.some(
    (marker: string): boolean => lowered.indexOf(marker) >= 0);
  if (!rejected) { return ''; }

  if (state === 'ready') {
    return 'Server Pro 登录令牌已被服务器拒绝，请重新登录：设置 → RustDesk 中继 → 登录 Server Pro';
  }
  if (state === 'requires_login') {
    return '该中继的 Server Pro 账号需要重新登录（登录令牌只保存在本机，云同步不会同步它）。' +
      '请前往：设置 → RustDesk 中继 → 登录 Server Pro';
  }
  return '该中继启用了账号访问控制，但本机没有已登录的 Server Pro 账号。' +
    '请前往：设置 → RustDesk 中继 → 登录 Server Pro';
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
