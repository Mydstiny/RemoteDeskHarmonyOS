import { util } from '@kit.ArkTS';

/** The application-wide crypto state as it applies to the VNC owner only. */
export type VncCryptoState = 'disabled' | 'locked' | 'unlocked';
export type VncSecretStorageMode =
  'encrypted_v3' | 'encrypted_v2' | 'plain_explicit_v1';

export const VNC_PLAIN_SECRET_ENVELOPE_PREFIX: string = 'plain-v1:';
export const VNC_PLAIN_SECRET_MAX_LENGTH: number = 512;
export const VNC_PLAIN_SECRET_ENCODED_MAX_LENGTH: number = 2048;

export interface VncSecretStorageDecision {
  allowed: boolean;
  mode: VncSecretStorageMode | '';
  code: 'none' | 'remember_disabled' | 'unlock_required' | 'plain_confirmation_required';
  message: string;
}

export function vncCryptoState(configured: boolean, ready: boolean): VncCryptoState {
  if (!configured) { return 'disabled'; }
  return ready ? 'unlocked' : 'locked';
}

export function decideVncSecretStorage(remember: boolean, configured: boolean, ready: boolean,
  plainConfirmed: boolean): VncSecretStorageDecision {
  if (!remember) {
    return { allowed: true, mode: '', code: 'remember_disabled', message: '' };
  }
  const state: VncCryptoState = vncCryptoState(configured, ready);
  if (state === 'unlocked') {
    return { allowed: true, mode: 'encrypted_v3', code: 'none', message: '' };
  }
  if (state === 'locked') {
    return {
      allowed: false, mode: '', code: 'unlock_required',
      message: '应用加密已锁定；请先解锁，或关闭“记住密码”进行本次连接'
    };
  }
  if (!plainConfirmed) {
    return {
      allowed: false, mode: '', code: 'plain_confirmation_required',
      message: '应用加密未启用，记住的 VNC 密码将以未加密形式保存；需要明确确认风险'
    };
  }
  return { allowed: true, mode: 'plain_explicit_v1', code: 'none', message: '' };
}

export function encodePlainVncSecret(plaintext: string): string {
  if (plaintext.length === 0 || plaintext.length > VNC_PLAIN_SECRET_MAX_LENGTH) {
    return '';
  }
  try {
    const bytes: Uint8Array = new util.TextEncoder().encode(plaintext);
    const encoded: string = new util.Base64Helper().encodeToStringSync(bytes);
    if (encoded.length === 0 || encoded.length > VNC_PLAIN_SECRET_ENCODED_MAX_LENGTH) { return ''; }
    return VNC_PLAIN_SECRET_ENVELOPE_PREFIX + encoded;
  } catch (_e) {
    return '';
  }
}

export function decodePlainVncSecret(envelope: string): string | null {
  if (!isPlainVncSecretEnvelope(envelope)) { return null; }
  try {
    const encoded: string = envelope.substring(VNC_PLAIN_SECRET_ENVELOPE_PREFIX.length);
    const bytes: Uint8Array = new util.Base64Helper().decodeSync(encoded);
    if (bytes.length === 0) { return null; }
    const plaintext: string = new util.TextDecoder('utf-8').decodeToString(bytes);
    if (plaintext.length === 0 || plaintext.length > VNC_PLAIN_SECRET_MAX_LENGTH) { return null; }
    return plaintext;
  } catch (_e) {
    return null;
  }
}

export function isPlainVncSecretEnvelope(envelope: string): boolean {
  if (!envelope.startsWith(VNC_PLAIN_SECRET_ENVELOPE_PREFIX)) { return false; }
  const encoded: string = envelope.substring(VNC_PLAIN_SECRET_ENVELOPE_PREFIX.length);
  return encoded.length > 0 && encoded.length <= VNC_PLAIN_SECRET_ENCODED_MAX_LENGTH &&
    encoded.length % 4 === 0 && /^[A-Za-z0-9+/]+={0,2}$/.test(encoded) &&
    decodePlainVncSecretUnchecked(encoded);
}

function decodePlainVncSecretUnchecked(encoded: string): boolean {
  try {
    const bytes: Uint8Array = new util.Base64Helper().decodeSync(encoded);
    if (bytes.length === 0 || bytes.length > VNC_PLAIN_SECRET_MAX_LENGTH * 4) { return false; }
    const plaintext: string = new util.TextDecoder('utf-8').decodeToString(bytes);
    return plaintext.length > 0 && plaintext.length <= VNC_PLAIN_SECRET_MAX_LENGTH;
  } catch (_e) {
    return false;
  }
}

/**
 * Old encrypted VNC rows omitted storageMode; they remain encrypted_v2 and
 * are accepted only so the atomic crypto migration can authenticate and
 * rewrite them as account/reset-bound encrypted_v3.
 */
export function vncSecretStorageModeFromPayload(payload: string): VncSecretStorageMode | '' {
  try {
    const parsed: Object = JSON.parse(payload) as Object;
    if (!parsed || Array.isArray(parsed) || typeof parsed !== 'object') { return ''; }
    const values: Record<string, Object> = parsed as Record<string, Object>;
    const value: Object | undefined = values['storageMode'];
    if (typeof value === 'undefined') { return 'encrypted_v2'; }
    if (value === 'encrypted_v3' || value === 'encrypted_v2' ||
      value === 'plain_explicit_v1') {
      return value as VncSecretStorageMode;
    }
  } catch (_e) {}
  return '';
}
