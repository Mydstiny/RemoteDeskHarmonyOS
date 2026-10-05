import { base64UrlDecode, base64UrlEncode, PasskeyRequest, PasskeyResponse, PASSKEY_MAX_TTL_MS,
  PASSKEY_PROTOCOL_VERSION, validRpId } from './ProPasskeyCodec';

/**
 * The CTAP2 side of 手机通行密钥 in a remote session: a remote Windows MakeCredential/GetAssertion (CTAP command
 * byte + CBOR, as MS-RDPEWA carries it) becomes a passkey request for the paired phone, and the phone's answer
 * becomes the CTAP response (attestation "none"). Only the CBOR CTAP2 needs is supported: canonical, definite.
 */

export const CTAP_MAKE_CREDENTIAL: number = 0x01;
export const CTAP_GET_ASSERTION: number = 0x02;
export const CTAP2_OK: number = 0x00;
export const CTAP1_ERR_INVALID_PARAMETER: number = 0x02;
export const CTAP2_ERR_CBOR_UNEXPECTED_TYPE: number = 0x11;
export const CTAP2_ERR_INVALID_CBOR: number = 0x12;
export const CTAP2_ERR_MISSING_PARAMETER: number = 0x14;
export const CTAP2_ERR_CREDENTIAL_EXCLUDED: number = 0x19;
export const CTAP2_ERR_UNSUPPORTED_ALGORITHM: number = 0x26;
export const CTAP2_ERR_OPERATION_DENIED: number = 0x27;
export const CTAP2_ERR_NO_CREDENTIALS: number = 0x2e;
export const CTAP2_ERR_USER_ACTION_TIMEOUT: number = 0x2f;
export const CTAP1_ERR_OTHER: number = 0x7f;

const COSE_ES256: number = -7;
const MAX_DEPTH: number = 8;
const MAX_ITEMS: number = 1024;
const PHONE_CREDENTIAL_ID_BYTES: number = 16;
const MAX_LISTED_CREDENTIALS: number = 16;

/** One decoded CBOR data item. */
export class CborItem {
  /** 'uint' | 'neg' | 'bytes' | 'text' | 'array' | 'map' | 'bool' | 'null' */
  kind: string;
  /** uint: the value; neg: the value itself (negative) */
  num: number = 0;
  bytes: Uint8Array = new Uint8Array(0);
  text: string = '';
  items: CborItem[] = [];
  keys: CborItem[] = [];
  values: CborItem[] = [];
  bool: boolean = false;

  constructor(kind: string) { this.kind = kind; }

  /** The value under an integer or text key of a map, or null. */
  get(key: number | string): CborItem | null {
    for (let i = 0; i < this.keys.length; i++) {
      const candidate = this.keys[i];
      if (typeof key === 'number' && (candidate.kind === 'uint' || candidate.kind === 'neg') && candidate.num === key) {
        return this.values[i];
      }
      if (typeof key === 'string' && candidate.kind === 'text' && candidate.text === key) { return this.values[i]; }
    }
    return null;
  }
}

class CborReader {
  private data: Uint8Array;
  private offset: number = 0;
  private count: number = 0;

  constructor(data: Uint8Array) { this.data = data; }

  done(): boolean { return this.offset === this.data.length; }

  private byte(): number {
    if (this.offset >= this.data.length) { throw new Error('CBOR_TRUNCATED'); }
    return this.data[this.offset++];
  }

  private argument(info: number): number {
    if (info < 24) { return info; }
    let size = 0;
    if (info === 24) { size = 1; } else if (info === 25) { size = 2; } else if (info === 26) { size = 4; }
    else if (info === 27) { size = 8; } else { throw new Error('CBOR_UNSUPPORTED'); }
    let value = 0;
    for (let i = 0; i < size; i++) { value = value * 256 + this.byte(); }
    if (!Number.isSafeInteger(value)) { throw new Error('CBOR_UNSUPPORTED'); }
    return value;
  }

  private take(length: number): Uint8Array {
    if (length > this.data.length - this.offset) { throw new Error('CBOR_TRUNCATED'); }
    const slice = this.data.slice(this.offset, this.offset + length);
    this.offset += length;
    return slice;
  }

  read(depth: number): CborItem {
    if (depth > MAX_DEPTH || ++this.count > MAX_ITEMS) { throw new Error('CBOR_TOO_DEEP'); }
    const head = this.byte();
    const major = head >> 5;
    const info = head & 0x1f;
    if (major === 7) {
      if (info === 20 || info === 21) { const item = new CborItem('bool'); item.bool = info === 21; return item; }
      if (info === 22) { return new CborItem('null'); }
      throw new Error('CBOR_UNSUPPORTED');
    }
    const argument = this.argument(info);
    if (major === 0) { const item = new CborItem('uint'); item.num = argument; return item; }
    if (major === 1) { const item = new CborItem('neg'); item.num = -1 - argument; return item; }
    if (major === 2) { const item = new CborItem('bytes'); item.bytes = this.take(argument); return item; }
    if (major === 3) { const item = new CborItem('text'); item.text = utf8Text(this.take(argument)); return item; }
    if (major === 4) {
      const item = new CborItem('array');
      for (let i = 0; i < argument; i++) { item.items.push(this.read(depth + 1)); }
      return item;
    }
    if (major === 5) {
      const item = new CborItem('map');
      for (let i = 0; i < argument; i++) {
        item.keys.push(this.read(depth + 1));
        item.values.push(this.read(depth + 1));
      }
      return item;
    }
    throw new Error('CBOR_UNSUPPORTED');
  }
}

function utf8Text(bytes: Uint8Array): string {
  let text = '';
  let i = 0;
  while (i < bytes.length) {
    const lead = bytes[i];
    let code = 0;
    let length = 0;
    if (lead < 0x80) { code = lead; length = 1; }
    else if (lead >= 0xc2 && lead <= 0xdf) { code = lead & 0x1f; length = 2; }
    else if (lead >= 0xe0 && lead <= 0xef) { code = lead & 0x0f; length = 3; }
    else if (lead >= 0xf0 && lead <= 0xf4) { code = lead & 0x07; length = 4; }
    else { throw new Error('CBOR_TEXT_INVALID'); }
    if (i + length > bytes.length) { throw new Error('CBOR_TEXT_INVALID'); }
    for (let k = 1; k < length; k++) {
      if ((bytes[i + k] & 0xc0) !== 0x80) { throw new Error('CBOR_TEXT_INVALID'); }
      code = (code << 6) | (bytes[i + k] & 0x3f);
    }
    text += String.fromCodePoint(code);
    i += length;
  }
  return text;
}

/** Decodes exactly one CBOR item spanning all of `data`. */
export function cborDecode(data: Uint8Array): CborItem {
  const reader = new CborReader(data);
  const item = reader.read(0);
  if (!reader.done()) { throw new Error('CBOR_TRAILING'); }
  return item;
}

// ---- encoding (canonical: shortest heads, map keys sorted by length then bytes) ----

function head(major: number, value: number): number[] {
  if (value < 24) { return [(major << 5) | value]; }
  if (value < 0x100) { return [(major << 5) | 24, value]; }
  if (value < 0x10000) { return [(major << 5) | 25, value >> 8, value & 0xff]; }
  return [(major << 5) | 26, (value >>> 24) & 0xff, (value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff];
}

function concat(parts: number[][]): number[] {
  let out: number[] = [];
  parts.forEach((part: number[]): void => { out = out.concat(part); });
  return out;
}

export function cborUint(value: number): number[] { return head(0, value); }
export function cborBytes(bytes: Uint8Array): number[] { return head(2, bytes.length).concat(Array.from(bytes)); }
export function cborText(text: string): number[] {
  const bytes: number[] = [];
  for (const character of text) {
    const code: number = character.codePointAt(0) ?? 0;
    if (code < 0x80) { bytes.push(code); }
    else if (code < 0x800) { bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f)); }
    else if (code < 0x10000) { bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f)); }
    else {
      bytes.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    }
  }
  return head(3, bytes.length).concat(bytes);
}

function compareKeys(a: number[], b: number[]): number {
  if (a.length !== b.length) { return a.length - b.length; }
  for (let i = 0; i < a.length; i++) { if (a[i] !== b[i]) { return a[i] - b[i]; } }
  return 0;
}

/** A map from already-encoded keys and values, in canonical key order. */
export function cborMap(entries: number[][][]): number[] {
  const sorted = entries.slice().sort((x: number[][], y: number[][]): number => compareKeys(x[0], y[0]));
  return head(5, sorted.length).concat(concat(sorted.map((entry: number[][]): number[] => entry[0].concat(entry[1]))));
}

// ---- CTAP2 commands ----

export interface CtapUser { id: Uint8Array; name: string; displayName: string; }

/** A parsed MakeCredential / GetAssertion, or the CTAP status that refuses it (status !== 0). */
export class CtapCommand {
  status: number = CTAP2_OK;
  op: string = '';
  rpId: string = '';
  clientDataHash: Uint8Array = new Uint8Array(0);
  user: CtapUser | null = null;
  /** register: exclude list; sign-in: allow list — only IDs the phone could have issued */
  credentialIds: Uint8Array[] = [];
  /** sign-in: the server listed credentials, none of them the phone's */
  foreignAllowList: boolean = false;
}

function refused(status: number): CtapCommand {
  const command = new CtapCommand();
  command.status = status;
  return command;
}

function cleanName(value: CborItem | null): string {
  if (value === null || value.kind !== 'text') { return ''; }
  return value.text.replace(/[\u0000-\u001f\u007f]/g, '').slice(0, 64);
}

function credentialIds(list: CborItem | null): Uint8Array[] | null {
  if (list === null) { return []; }
  if (list.kind !== 'array') { return null; }
  const ids: Uint8Array[] = [];
  for (const descriptor of list.items) {
    if (descriptor.kind !== 'map') { return null; }
    const id = descriptor.get('id');
    if (id === null || id.kind !== 'bytes') { return null; }
    ids.push(id.bytes);
  }
  return ids;
}

/** Parses the CTAP command (command byte + CBOR map) a remote session sent. */
export function parseCtapCommand(command: Uint8Array): CtapCommand {
  if (command.length < 2) { return refused(CTAP1_ERR_INVALID_PARAMETER); }
  const code = command[0];
  if (code !== CTAP_MAKE_CREDENTIAL && code !== CTAP_GET_ASSERTION) { return refused(CTAP1_ERR_INVALID_PARAMETER); }
  let map: CborItem;
  try { map = cborDecode(command.slice(1)); } catch (_error) { return refused(CTAP2_ERR_INVALID_CBOR); }
  if (map.kind !== 'map') { return refused(CTAP2_ERR_CBOR_UNEXPECTED_TYPE); }
  const result = new CtapCommand();
  if (code === CTAP_MAKE_CREDENTIAL) {
    result.op = 'register';
    const hash = map.get(1);
    const rp = map.get(2);
    const user = map.get(3);
    const params = map.get(4);
    if (hash === null || rp === null || user === null || params === null) { return refused(CTAP2_ERR_MISSING_PARAMETER); }
    if (hash.kind !== 'bytes' || rp.kind !== 'map' || user.kind !== 'map' || params.kind !== 'array') {
      return refused(CTAP2_ERR_CBOR_UNEXPECTED_TYPE);
    }
    const rpId = rp.get('id');
    const userId = user.get('id');
    if (rpId === null || rpId.kind !== 'text' || userId === null || userId.kind !== 'bytes') {
      return refused(CTAP2_ERR_MISSING_PARAMETER);
    }
    result.rpId = rpId.text.toLowerCase();
    result.clientDataHash = hash.bytes;
    if (userId.bytes.length < 1 || userId.bytes.length > 64) { return refused(CTAP1_ERR_INVALID_PARAMETER); }
    result.user = { id: userId.bytes, name: cleanName(user.get('name')), displayName: cleanName(user.get('displayName')) };
    // The phone's keys are ES256 only.
    const es256 = params.items.some((param: CborItem): boolean => {
      if (param.kind !== 'map') { return false; }
      const alg = param.get('alg');
      const type = param.get('type');
      return alg !== null && alg.kind === 'neg' && alg.num === COSE_ES256 && type !== null && type.kind === 'text' &&
        type.text === 'public-key';
    });
    if (!es256) { return refused(CTAP2_ERR_UNSUPPORTED_ALGORITHM); }
    const excluded = credentialIds(map.get(5));
    if (excluded === null) { return refused(CTAP2_ERR_CBOR_UNEXPECTED_TYPE); }
    result.credentialIds = excluded.filter((id: Uint8Array): boolean => id.length === PHONE_CREDENTIAL_ID_BYTES)
      .slice(0, MAX_LISTED_CREDENTIALS);
  } else {
    result.op = 'signin';
    const rpId = map.get(1);
    const hash = map.get(2);
    if (rpId === null || hash === null) { return refused(CTAP2_ERR_MISSING_PARAMETER); }
    if (rpId.kind !== 'text' || hash.kind !== 'bytes') { return refused(CTAP2_ERR_CBOR_UNEXPECTED_TYPE); }
    result.rpId = rpId.text.toLowerCase();
    result.clientDataHash = hash.bytes;
    const allowed = credentialIds(map.get(3));
    if (allowed === null) { return refused(CTAP2_ERR_CBOR_UNEXPECTED_TYPE); }
    const mine = allowed.filter((id: Uint8Array): boolean => id.length === PHONE_CREDENTIAL_ID_BYTES);
    result.foreignAllowList = allowed.length > 0 && mine.length === 0;
    result.credentialIds = mine.slice(0, MAX_LISTED_CREDENTIALS);
  }
  if (result.clientDataHash.length !== 32 || !validRpId(result.rpId)) { return refused(CTAP1_ERR_INVALID_PARAMETER); }
  return result;
}

/** The passkey request for the phone (unsigned; ProPasskeyDevice.signRequest fills in device and signature). */
export function passkeyRequestFromCtap(command: CtapCommand, id: Uint8Array, from: string, now: number,
  ttlMs: number): PasskeyRequest {
  const user = command.user;
  return {
    v: PASSKEY_PROTOCOL_VERSION, id: base64UrlEncode(id), op: command.op, rpId: command.rpId,
    clientDataHash: base64UrlEncode(command.clientDataHash),
    user: user === null ? null : { id: base64UrlEncode(user.id), name: user.name, displayName: user.displayName },
    credentialIds: command.credentialIds.map((value: Uint8Array): string => base64UrlEncode(value)),
    from, sentAt: now, ttlMs: Math.max(1000, Math.min(Math.floor(ttlMs), PASSKEY_MAX_TTL_MS)),
    device: '', devicePub: '', sig: ''
  };
}

/** CTAP status for a phone answer that is not a success. */
export function ctapStatusForPasskeyError(error: string): number {
  switch (error) {
    case 'PASSKEY_USER_DENIED':
    case 'PASSKEY_USER_CANCELLED':
    case 'PASSKEY_USER_AUTH_FAILED':
    case 'PASSKEY_DEVICE_NOT_PAIRED':
    case 'PASSKEY_SIGNATURE_INVALID':
    case 'PASSKEY_BUSY':
      return CTAP2_ERR_OPERATION_DENIED;
    case 'PASSKEY_NO_CREDENTIALS':
    case 'PASSKEY_KEY_MISSING':
      return CTAP2_ERR_NO_CREDENTIALS;
    case 'PASSKEY_CREDENTIAL_EXCLUDED':
      return CTAP2_ERR_CREDENTIAL_EXCLUDED;
    default:
      return CTAP1_ERR_OTHER;
  }
}

export function ctapStatus(status: number): Uint8Array { return new Uint8Array([status]); }

/**
 * The CTAP response for the phone's answer (status byte + CBOR). A success that lacks what the command needs is
 * reported as an error rather than passed on half-formed.
 */
export function ctapResponseFromPasskey(op: string, response: PasskeyResponse | null): Uint8Array {
  if (response === null) { return ctapStatus(CTAP2_ERR_USER_ACTION_TIMEOUT); }
  if (!response.ok) { return ctapStatus(ctapStatusForPasskeyError(response.error)); }
  const authData = base64UrlDecode(response.authData);
  const credentialId = base64UrlDecode(response.credentialId);
  if (authData === null || credentialId === null) { return ctapStatus(CTAP1_ERR_OTHER); }
  if (op === 'register') {
    // fmt "none" with an empty attestation statement: the RP sees an unattested platform-style key.
    const body = cborMap([[cborUint(1), cborText('none')], [cborUint(2), cborBytes(authData)], [cborUint(3), cborMap([])]]);
    return new Uint8Array([CTAP2_OK].concat(body));
  }
  const signature = base64UrlDecode(response.signature);
  if (signature === null || signature.length === 0) { return ctapStatus(CTAP1_ERR_OTHER); }
  const entries: number[][][] = [
    [cborUint(1), cborMap([[cborText('id'), cborBytes(credentialId)], [cborText('type'), cborText('public-key')]])],
    [cborUint(2), cborBytes(authData)],
    [cborUint(3), cborBytes(signature)]
  ];
  const userHandle = response.userHandle === '' ? null : base64UrlDecode(response.userHandle);
  if (userHandle !== null && userHandle.length > 0) {
    entries.push([cborUint(4), cborMap([[cborText('id'), cborBytes(userHandle)]])]);
  }
  return new Uint8Array([CTAP2_OK].concat(cborMap(entries)));
}
