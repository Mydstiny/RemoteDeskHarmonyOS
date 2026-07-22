/**
 * RustDeskRelayKeyPolicy — relay public-key and shared-access-key rules.
 *
 * RustDesk hbbs/hbbr `-k` is compared with the client protobuf
 * `licence_key` as text.  It is therefore not always an Ed25519 public key:
 * a server administrator may intentionally configure an arbitrary shared
 * access value.  Keep the two meanings explicit so a shared value is never
 * silently transformed into a (different) public key.
 */
import { util } from '@kit.ArkTS';

export type RustDeskRelayKeyMode = 'auto' | 'server_public_key' | 'shared_access_key';

export const RUSTDESK_RELAY_KEY_MODE_AUTO: RustDeskRelayKeyMode = 'auto';
export const RUSTDESK_RELAY_KEY_MODE_PUBLIC: RustDeskRelayKeyMode = 'server_public_key';
export const RUSTDESK_RELAY_KEY_MODE_SHARED: RustDeskRelayKeyMode = 'shared_access_key';

// `licence_key` is a protobuf string.  This is deliberately generous for an
// administrator supplied value while keeping a malformed paste from becoming
// an unbounded IPC/network payload.
export const RUSTDESK_SHARED_ACCESS_KEY_MAX_UTF8_BYTES: number = 4096;

const SHARED_STORAGE_PREFIX: string = 'rdsk-shared-v1:';

export interface RustDeskRelayKeyResolution {
  ok: boolean;
  mode: RustDeskRelayKeyMode;
  value: string;
  error: string;
  requiresInsecureConnectionWarning: boolean;
}

export interface RustDeskRelayStoredKey {
  key: string;
  mode: RustDeskRelayKeyMode;
}

function utf8Length(value: string): number {
  return new util.TextEncoder('utf-8').encodeInto(value).length;
}

function publicKeyInput(value: string): string {
  let candidate: string = value.replace(/^\uFEFF/, '').replace(/[\s\u200B-\u200D]/g, '');
  if ((candidate.startsWith('"') && candidate.endsWith('"')) ||
    (candidate.startsWith("'") && candidate.endsWith("'"))) {
    candidate = candidate.substring(1, candidate.length - 1);
  }
  if (candidate.toLowerCase().startsWith('key=')) {
    candidate = candidate.substring(4);
  }
  return candidate;
}

/** Normalize only an explicit Ed25519 public key. */
export function normalizeRustDeskServerPublicKey(value: string): string | null {
  const compact: string = publicKeyInput(value);
  if (compact.length === 0) { return ''; }
  if (!/^[A-Za-z0-9+/_-]+={0,2}$/.test(compact)) { return null; }
  const firstPadding: number = compact.indexOf('=');
  if (firstPadding >= 0 && firstPadding < compact.length - (compact.endsWith('==') ? 2 : 1)) {
    return null;
  }
  if (compact.length % 4 === 1 || (firstPadding >= 0 && compact.length % 4 !== 0)) {
    return null;
  }
  const base64: string = compact.replace(/-/g, '+').replace(/_/g, '/');
  const padded: string = base64 + '='.repeat((4 - base64.length % 4) % 4);
  try {
    const bytes: Uint8Array = new util.Base64Helper().decodeSync(padded);
    if (bytes.length !== 32) { return null; }
    return new util.Base64Helper().encodeToStringSync(bytes);
  } catch (_err) {
    return null;
  }
}

function sharedAccessKeyError(value: string, required: boolean): string {
  if (value.length === 0) {
    return required ? '自定义共享准入 Key 不能为空' : '';
  }
  if (value.indexOf('\0') >= 0) {
    return '自定义共享准入 Key 不能包含 NUL 字符';
  }
  if (utf8Length(value) > RUSTDESK_SHARED_ACCESS_KEY_MAX_UTF8_BYTES) {
    return '自定义共享准入 Key 超过 4 KB 协议限制';
  }
  return '';
}

/**
 * Resolve the value used by the RustDesk protocol.  Shared mode deliberately
 * does not trim, decode, pad, or otherwise rewrite the input.
 */
export function resolveRustDeskRelayKey(value: string, requestedMode: RustDeskRelayKeyMode =
  RUSTDESK_RELAY_KEY_MODE_AUTO, required: boolean = false): RustDeskRelayKeyResolution {
  const raw: string = value;
  if (requestedMode === RUSTDESK_RELAY_KEY_MODE_SHARED) {
    const error: string = sharedAccessKeyError(raw, true);
    return {
      ok: error === '', mode: RUSTDESK_RELAY_KEY_MODE_SHARED, value: raw, error,
      requiresInsecureConnectionWarning: error === ''
    };
  }

  const normalized: string | null = normalizeRustDeskServerPublicKey(raw);
  if (requestedMode === RUSTDESK_RELAY_KEY_MODE_PUBLIC) {
    if (normalized === null) {
      return {
        ok: false, mode: RUSTDESK_RELAY_KEY_MODE_PUBLIC, value: '',
        error: 'RustDesk 中继服务器公钥格式无效，应为 Base64 编码的 32 字节 Ed25519 公钥',
        requiresInsecureConnectionWarning: false
      };
    }
    if (normalized.length === 0 && required) {
      return {
        ok: false, mode: RUSTDESK_RELAY_KEY_MODE_PUBLIC, value: '', error: 'Server Pro 中继缺少服务器密钥',
        requiresInsecureConnectionWarning: false
      };
    }
    return {
      ok: true, mode: RUSTDESK_RELAY_KEY_MODE_PUBLIC, value: normalized, error: '',
      requiresInsecureConnectionWarning: false
    };
  }

  // Legacy/auto entries preserve old OSS behaviour for an empty value, use a
  // canonical public key where unambiguous, and otherwise act as a shared
  // access key. An imported raw `1:` value is not storage ciphertext: only
  // the encrypted storage reader has that context. New UI flows make this
  // selection explicit before saving.
  if (normalized !== null) {
    if (normalized.length === 0 && required) {
      return {
        ok: false, mode: RUSTDESK_RELAY_KEY_MODE_PUBLIC, value: '', error: 'Server Pro 中继缺少服务器密钥',
        requiresInsecureConnectionWarning: false
      };
    }
    return {
      ok: true, mode: RUSTDESK_RELAY_KEY_MODE_PUBLIC, value: normalized, error: '',
      requiresInsecureConnectionWarning: false
    };
  }
  const sharedError: string = sharedAccessKeyError(raw, required);
  return {
    ok: sharedError === '', mode: RUSTDESK_RELAY_KEY_MODE_SHARED, value: raw, error: sharedError,
    requiresInsecureConnectionWarning: sharedError === ''
  };
}

/** C ABI values consumed by rustdesk_ffi (0=legacy/auto, 1=public, 2=shared). */
export function rustDeskRelayKeyModeForFfi(value: string, mode: RustDeskRelayKeyMode): number {
  // Do not promote a legacy auto record that still looks like DataCrypto to
  // shared mode. New shared `1:` values are enveloped and carry explicit mode.
  if (mode === RUSTDESK_RELAY_KEY_MODE_AUTO && value.trimStart().startsWith('1:')) { return 1; }
  const resolved: RustDeskRelayKeyResolution = resolveRustDeskRelayKey(value, mode, false);
  return resolved.mode === RUSTDESK_RELAY_KEY_MODE_SHARED ? 2 : 1;
}

/**
 * Store shared text in an unambiguous envelope before DataCrypto encrypts the
 * relay column.  In particular, a genuine shared key beginning with `1:`
 * must never be mistaken for locked ciphertext after it is decrypted.
 */
export function rustDeskRelayKeyForStorage(value: string, mode: RustDeskRelayKeyMode): string {
  if (mode !== RUSTDESK_RELAY_KEY_MODE_SHARED) { return value; }
  const base64: string = new util.Base64Helper().encodeToStringSync(
    new util.TextEncoder('utf-8').encodeInto(value));
  return SHARED_STORAGE_PREFIX + base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

export function rustDeskRelayKeyFromStorage(value: string, fallbackMode: RustDeskRelayKeyMode =
  RUSTDESK_RELAY_KEY_MODE_AUTO): RustDeskRelayStoredKey {
  if (!value.startsWith(SHARED_STORAGE_PREFIX)) {
    return { key: value, mode: fallbackMode };
  }
  const payload: string = value.substring(SHARED_STORAGE_PREFIX.length);
  if (payload.length === 0 || !/^[A-Za-z0-9_-]+$/.test(payload)) {
    // Keep the stored value visible for recovery rather than silently turning
    // a damaged record into an empty credential.
    return { key: value, mode: fallbackMode };
  }
  const padded: string = payload.replace(/-/g, '+').replace(/_/g, '/') +
    '='.repeat((4 - payload.length % 4) % 4);
  try {
    const key: string = new util.TextDecoder('utf-8').decodeToString(
      new util.Base64Helper().decodeSync(padded));
    return { key, mode: RUSTDESK_RELAY_KEY_MODE_SHARED };
  } catch (_err) {
    return { key: value, mode: fallbackMode };
  }
}
