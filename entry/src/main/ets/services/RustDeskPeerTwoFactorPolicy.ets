import { TotpAlgorithm, TotpCode, TotpEntry } from '../model/TotpEntry';

// RustDesk's official TOTP generator currently uses SHA-1, 30 seconds, and
// six digits. Manual input also permits an explicit eight-digit custom Peer.
export const RUSTDESK_OFFICIAL_TOTP_PERIOD_SECONDS: number = 30;
export const RUSTDESK_OFFICIAL_TOTP_DIGITS: number = 6;
export const RUSTDESK_PEER_2FA_MIN_REMAINING_SECONDS: number = 5;

export function isRustDeskPeerTwoFactorManualCode(code: string): boolean {
  if (code.length !== 6 && code.length !== 8) { return false; }
  for (let i = 0; i < code.length; i++) {
    const value: number = code.charCodeAt(i);
    if (value < 48 || value > 57) { return false; }
  }
  return true;
}

export function isRustDeskPeerTwoFactorAutoSubmitCompatible(entry: TotpEntry): boolean {
  return entry.algorithm === TotpAlgorithm.SHA1 &&
    entry.digits === RUSTDESK_OFFICIAL_TOTP_DIGITS &&
    entry.period === RUSTDESK_OFFICIAL_TOTP_PERIOD_SECONDS;
}

/** Returns a user-safe reason when an automatic submission must fall back to manual input. */
export function rustDeskPeerTwoFactorAutoSubmitError(entry: TotpEntry, code: TotpCode): string {
  if (!isRustDeskPeerTwoFactorAutoSubmitCompatible(entry)) {
    return '自动填写仅支持 RustDesk 官方默认的 SHA1、30 秒、6 位 TOTP，请手动输入验证码。';
  }
  if (code.code.length !== RUSTDESK_OFFICIAL_TOTP_DIGITS ||
    !isRustDeskPeerTwoFactorManualCode(code.code)) {
    return '已绑定的 2FA 条目未生成有效验证码，请手动输入验证码。';
  }
  if (code.remaining < RUSTDESK_PEER_2FA_MIN_REMAINING_SECONDS) {
    return '验证码即将更新。为避免提交过期验证码，请手动输入下一组验证码。';
  }
  return '';
}
