// Pure WebAuthn/passkey helpers for the RemoteDesk phone passkey prototype. No platform imports, so the node tests
// can load this file directly. Formats follow W3C WebAuthn Level 3 (authenticator data, COSE EC2 keys).

export const PASSKEY_FLAG_UP: number = 0x01;
export const PASSKEY_FLAG_UV: number = 0x04;
export const PASSKEY_FLAG_AT: number = 0x40;
export const PASSKEY_PROTOCOL_VERSION: number = 1;
export const PASSKEY_MAX_TTL_MS: number = 120000;
/** Device-bound software authenticator without attestation: the all-zero AAGUID. */
export const PASSKEY_AAGUID: Uint8Array = new Uint8Array(16);

const B64: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

export function base64UrlEncode(bytes: Uint8Array): string {
  let out: string = '';
  for (let i: number = 0; i < bytes.length; i += 3) {
    const a: number = bytes[i];
    const b: number = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const c: number = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out += B64.charAt(a >> 2) + B64.charAt(((a & 3) << 4) | (b >> 4));
    if (i + 1 < bytes.length) { out += B64.charAt(((b & 15) << 2) | (c >> 6)); }
    if (i + 2 < bytes.length) { out += B64.charAt(c & 63); }
  }
  return out;
}

/** Strict unpadded base64url; null on any other character or an impossible length. */
export function base64UrlDecode(text: string): Uint8Array | null {
  if (text.length % 4 === 1) { return null; }
  const values: number[] = [];
  for (let i: number = 0; i < text.length; i++) {
    const index: number = B64.indexOf(text.charAt(i));
    if (index < 0) { return null; }
    values.push(index);
  }
  const out: number[] = [];
  for (let i: number = 0; i < values.length; i += 4) {
    const a: number = values[i];
    const b: number = i + 1 < values.length ? values[i + 1] : 0;
    out.push((a << 2) | (b >> 4));
    if (i + 2 < values.length) { out.push(((b & 15) << 4) | (values[i + 2] >> 2)); }
    if (i + 3 < values.length) { out.push(((values[i + 2] & 3) << 6) | values[i + 3]); }
  }
  return new Uint8Array(out.map((value: number): number => value & 0xff));
}

export function bytesToHex(bytes: Uint8Array): string {
  let out: string = '';
  bytes.forEach((value: number): void => { out += (value < 16 ? '0' : '') + value.toString(16); });
  return out;
}

export function concatBytes(parts: Uint8Array[]): Uint8Array {
  let length: number = 0;
  parts.forEach((part: Uint8Array): void => { length += part.length; });
  const out: Uint8Array = new Uint8Array(length);
  let offset: number = 0;
  parts.forEach((part: Uint8Array): void => { out.set(part, offset); offset += part.length; });
  return out;
}

export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) { return false; }
  for (let i: number = 0; i < a.length; i++) { if (a[i] !== b[i]) { return false; } }
  return true;
}

/** COSE_Key for an ES256 (P-256) public key: {1: 2, 3: -7, -1: 1, -2: x, -3: y} in canonical CBOR. */
export function coseEc2PublicKey(x: Uint8Array, y: Uint8Array): Uint8Array {
  if (x.length !== 32 || y.length !== 32) { throw new Error('PASSKEY_KEY_INVALID'); }
  return concatBytes([new Uint8Array([0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20]), x,
    new Uint8Array([0x22, 0x58, 0x20]), y]);
}

/** The x/y coordinates of an uncompressed P-256 point inside an X.509 SubjectPublicKeyInfo (HUKS export format). */
export function p256PointFromSpki(spki: Uint8Array): Uint8Array[] | null {
  // SEQUENCE { SEQUENCE { id-ecPublicKey, prime256v1 }, BIT STRING 0x00 0x04 x y }
  const prefix: number[] = [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08,
    0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04];
  if (spki.length !== prefix.length + 64) { return null; }
  for (let i: number = 0; i < prefix.length; i++) { if (spki[i] !== prefix[i]) { return null; } }
  return [spki.slice(prefix.length, prefix.length + 32), spki.slice(prefix.length + 32)];
}

/**
 * Authenticator data: rpIdHash(32) | flags(1) | signCount(4, big endian) | [AAGUID(16) | credIdLen(2) | credId |
 * COSE public key] when attested credential data is present.
 */
export function authenticatorData(rpIdHash: Uint8Array, flags: number, signCount: number,
  credentialId: Uint8Array | null, cosePublicKey: Uint8Array | null): Uint8Array {
  if (rpIdHash.length !== 32 || !Number.isInteger(signCount) || signCount < 0 || signCount > 0xffffffff) {
    throw new Error('PASSKEY_AUTHDATA_INVALID');
  }
  const head: Uint8Array = new Uint8Array(37);
  head.set(rpIdHash, 0);
  head[32] = flags & 0xff;
  head[33] = (signCount >>> 24) & 0xff;
  head[34] = (signCount >>> 16) & 0xff;
  head[35] = (signCount >>> 8) & 0xff;
  head[36] = signCount & 0xff;
  if (credentialId === null || cosePublicKey === null) { return head; }
  if (credentialId.length < 16 || credentialId.length > 1023) { throw new Error('PASSKEY_AUTHDATA_INVALID'); }
  const length: Uint8Array = new Uint8Array([(credentialId.length >> 8) & 0xff, credentialId.length & 0xff]);
  return concatBytes([head, PASSKEY_AAGUID, length, credentialId, cosePublicKey]);
}

export interface PasskeyUser { id: string; name: string; displayName: string; }

/** What the requesting device asks the phone to do. All binary fields are base64url. */
export interface PasskeyRequest {
  v: number;
  id: string;
  op: string;            // 'register' | 'signin'
  rpId: string;
  clientDataHash: string;
  user: PasskeyUser | null;
  credentialIds: string[];  // register: exclude list; signin: allow list (empty = any for this rpId)
  from: string;
  /** Requester clock (ms). A late joiner of the shared object can tell a stale request from a new one. */
  sentAt: number;
  ttlMs: number;
}

export interface PasskeyResponse {
  v: number;
  id: string;
  ok: boolean;
  error: string;
  credentialId: string;
  authData: string;
  signature: string;
  userHandle: string;
  publicKey: string;     // SPKI DER of the credential key (register)
}

function isText(value: Object | undefined | null, max: number): boolean {
  return typeof value === 'string' && (value as string).length <= max && !/[\u0000-\u001f\u007f]/.test(value as string);
}

function isB64(value: Object | undefined | null, minBytes: number, maxBytes: number): boolean {
  if (typeof value !== 'string') { return false; }
  const decoded: Uint8Array | null = base64UrlDecode(value as string);
  return decoded !== null && decoded.length >= minBytes && decoded.length <= maxBytes;
}

/** Relying party IDs are lowercase DNS names (or localhost); nothing else reaches the phone prompt. */
export function validRpId(rpId: string): boolean {
  return rpId.length > 0 && rpId.length <= 253 &&
    /^(localhost|([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)$/.test(rpId);
}

export function parsePasskeyRequest(text: string): PasskeyRequest | null {
  if (text.length === 0 || text.length > 8192) { return null; }
  let raw: Record<string, Object>;
  try {
    const parsed: Object = JSON.parse(text) as Object;
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) { return null; }
    raw = parsed as Record<string, Object>;
  } catch (_error) {
    return null;
  }
  const op: Object | null | undefined = raw['op'];
  if (raw['v'] !== PASSKEY_PROTOCOL_VERSION || !isB64(raw['id'], 16, 16) || (op !== 'register' && op !== 'signin') ||
      !isText(raw['rpId'], 253) || !validRpId(raw['rpId'] as string) || !isB64(raw['clientDataHash'], 32, 32) ||
      !isText(raw['from'], 40) || typeof raw['sentAt'] !== 'number' || !Number.isInteger(raw['sentAt'] as number) ||
      (raw['sentAt'] as number) <= 0 || typeof raw['ttlMs'] !== 'number' || !Number.isInteger(raw['ttlMs'] as number) ||
      (raw['ttlMs'] as number) < 1000 || (raw['ttlMs'] as number) > PASSKEY_MAX_TTL_MS) { return null; }
  const ids: Object | null | undefined = raw['credentialIds'];
  if (ids === null || ids === undefined || !Array.isArray(ids) || (ids as Object[]).length > 16 ||
      (ids as Object[]).some((item: Object): boolean => !isB64(item, 16, 1023))) { return null; }
  let user: PasskeyUser | null = null;
  if (op === 'register') {
    const value: Object | null | undefined = raw['user'];
    if (value === null || value === undefined || typeof value !== 'object' || Array.isArray(value)) { return null; }
    const entry: Record<string, Object> = value as Record<string, Object>;
    if (!isB64(entry['id'], 1, 64) || !isText(entry['name'], 64) || !isText(entry['displayName'], 64)) { return null; }
    user = { id: entry['id'] as string, name: entry['name'] as string, displayName: entry['displayName'] as string };
  } else if (raw['user'] !== null && raw['user'] !== undefined) {
    return null;
  }
  return { v: PASSKEY_PROTOCOL_VERSION, id: raw['id'] as string, op: op as string, rpId: raw['rpId'] as string,
    clientDataHash: raw['clientDataHash'] as string, user, credentialIds: (ids as Object[]).map((item: Object): string =>
      item as string), from: raw['from'] as string, sentAt: raw['sentAt'] as number, ttlMs: raw['ttlMs'] as number };
}

export function parsePasskeyResponse(text: string, requestId: string): PasskeyResponse | null {
  if (text.length === 0 || text.length > 16384) { return null; }
  let raw: Record<string, Object>;
  try {
    const parsed: Object = JSON.parse(text) as Object;
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) { return null; }
    raw = parsed as Record<string, Object>;
  } catch (_error) {
    return null;
  }
  if (raw['v'] !== PASSKEY_PROTOCOL_VERSION || raw['id'] !== requestId || typeof raw['ok'] !== 'boolean' ||
      !isText(raw['error'], 64)) { return null; }
  const response: PasskeyResponse = { v: PASSKEY_PROTOCOL_VERSION, id: requestId, ok: raw['ok'] as boolean,
    error: raw['error'] as string, credentialId: '', authData: '', signature: '', userHandle: '', publicKey: '' };
  if (!response.ok) { return response; }
  if (!isB64(raw['credentialId'], 16, 1023) || !isB64(raw['authData'], 37, 2048) ||
      !(raw['signature'] === '' || isB64(raw['signature'], 8, 72)) ||
      !(raw['userHandle'] === '' || isB64(raw['userHandle'], 1, 64)) ||
      !(raw['publicKey'] === '' || isB64(raw['publicKey'], 91, 91))) { return null; }
  response.credentialId = raw['credentialId'] as string;
  response.authData = raw['authData'] as string;
  response.signature = raw['signature'] as string;
  response.userHandle = raw['userHandle'] as string;
  response.publicKey = raw['publicKey'] as string;
  return response;
}

/** Whether a request is still current on this device: its age, allowing a minute of clock difference, is within its TTL. */
export function passkeyRequestCurrent(request: PasskeyRequest, now: number): boolean {
  return Math.abs(now - request.sentAt) <= request.ttlMs + 60000;
}

/** Credential ID and COSE key from the attested credential data of a registration's authenticator data. */
export function attestedCredential(authData: Uint8Array): Uint8Array[] | null {
  if (authData.length < 55 || (authData[32] & PASSKEY_FLAG_AT) === 0) { return null; }
  const length: number = (authData[53] << 8) | authData[54];
  if (length < 16 || 55 + length >= authData.length) { return null; }
  return [authData.slice(55, 55 + length), authData.slice(55 + length)];
}
