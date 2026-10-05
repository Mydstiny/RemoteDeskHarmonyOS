import { common } from '@kit.AbilityKit';
import {
  authenticatorData, base64UrlDecode, base64UrlEncode, bytesToHex, concatBytes, coseEc2PublicKey, p256PointFromSpki,
  PasskeyRequest, PasskeyResponse, PASSKEY_FLAG_AT, PASSKEY_FLAG_UP, PASSKEY_FLAG_UV, PASSKEY_PROTOCOL_VERSION
} from './ProPasskeyCodec';
import { PasskeyUnlock, ProPasskeyKeys, randomBytes, sha256, utf8 } from './ProPasskeyKeys';
import { PasskeyRecord, ProPasskeyStore } from './ProPasskeyStore';

function failure(request: PasskeyRequest, error: string): PasskeyResponse {
  return { v: PASSKEY_PROTOCOL_VERSION, id: request.id, ok: false, error, credentialId: '', authData: '', signature: '',
    userHandle: '', publicKey: '' };
}

function errorCode(error: Object): string {
  const message: string = error instanceof Error ? error.message : '';
  return /^PASSKEY_[A-Z_]{1,40}$/.test(message) ? message : 'PASSKEY_FAILED';
}

/**
 * The phone side of the prototype: a device-bound software authenticator. Each passkey is one HUKS P-256 key;
 * registration and every sign-in are confirmed by the user first and then unlocked by face, fingerprint or PIN.
 * `current` says whether the requester still waits: a passkey is never created or used for a request that ended
 * (expired or withdrawn) while the user was deciding or unlocking.
 */
export class ProPasskeyAuthenticator {
  static async register(context: common.Context, owner: string, request: PasskeyRequest,
    current: () => boolean = (): boolean => true): Promise<PasskeyResponse> {
    const user = request.user;
    if (request.op !== 'register' || user === null) { return failure(request, 'PASSKEY_REQUEST_INVALID'); }
    if (!current()) { return failure(request, 'PASSKEY_EXPIRED'); }
    const existing = ProPasskeyStore.forRp(context, owner, request.rpId);
    if (existing.some((record: PasskeyRecord): boolean => request.credentialIds.indexOf(record.id) >= 0)) {
      return failure(request, 'PASSKEY_CREDENTIAL_EXCLUDED');
    }
    const unlock: PasskeyUnlock | null = ProPasskeyKeys.preferredUnlock();
    if (unlock === null) { return failure(request, 'PASSKEY_NO_LOCK_SCREEN'); }
    const clientDataHash = base64UrlDecode(request.clientDataHash);
    if (clientDataHash === null) { return failure(request, 'PASSKEY_REQUEST_INVALID'); }
    let alias: string = '';
    let created: boolean = false;
    try {
      const credentialId = randomBytes(16);
      alias = 'rd_pk_' + bytesToHex(credentialId);
      await ProPasskeyKeys.generate(alias, unlock);
      created = true;
      const spki = await ProPasskeyKeys.publicKey(alias);
      const point = p256PointFromSpki(spki);
      if (point === null) { throw new Error('PASSKEY_KEY_EXPORT_FAILED'); }
      const authData = authenticatorData(sha256(utf8(request.rpId)), PASSKEY_FLAG_UP | PASSKEY_FLAG_UV | PASSKEY_FLAG_AT,
        0, credentialId, coseEc2PublicKey(point[0], point[1]));
      // Not worth a face or fingerprint prompt when the request ended while the key was being made.
      if (!current()) { throw new Error('PASSKEY_EXPIRED'); }
      // User verification: the new key must be unlocked once, which also proves it works on this device.
      await ProPasskeyKeys.sign(alias, unlock, concatBytes([authData, clientDataHash]),
        '注册「' + request.rpId + '」的通行密钥');
      // The site would never learn of a key created after its request ended; it would only shadow real ones.
      if (!current()) { throw new Error('PASSKEY_EXPIRED'); }
      const now = Date.now();
      ProPasskeyStore.save(context, { owner, id: base64UrlEncode(credentialId), rpId: request.rpId,
        userId: user.id, userName: user.name, displayName: user.displayName, alias, unlock,
        signCount: 0, createdAt: now, lastUsedAt: now });
      return { v: PASSKEY_PROTOCOL_VERSION, id: request.id, ok: true, error: '', credentialId: base64UrlEncode(credentialId),
        authData: base64UrlEncode(authData), signature: '', userHandle: '', publicKey: base64UrlEncode(spki) };
    } catch (error) {
      if (created) { await ProPasskeyKeys.remove(alias); }
      return failure(request, errorCode(error as Object));
    }
  }

  static async signIn(context: common.Context, owner: string, request: PasskeyRequest,
    current: () => boolean = (): boolean => true): Promise<PasskeyResponse> {
    if (request.op !== 'signin') { return failure(request, 'PASSKEY_REQUEST_INVALID'); }
    if (!current()) { return failure(request, 'PASSKEY_EXPIRED'); }
    const candidates = ProPasskeyStore.forRp(context, owner, request.rpId).filter((record: PasskeyRecord): boolean =>
      request.credentialIds.length === 0 || request.credentialIds.indexOf(record.id) >= 0);
    if (candidates.length === 0) { return failure(request, 'PASSKEY_NO_CREDENTIALS'); }
    const record = candidates[0];
    const clientDataHash = base64UrlDecode(request.clientDataHash);
    if (clientDataHash === null) { return failure(request, 'PASSKEY_REQUEST_INVALID'); }
    if (!(await ProPasskeyKeys.exists(record.alias))) {
      try { ProPasskeyStore.remove(context, owner, record.id); } catch (_error) { /* cleaned up next time */ }
      return failure(request, 'PASSKEY_KEY_MISSING');
    }
    try {
      const signCount = Math.min(record.signCount + 1, 0xffffffff);
      const authData = authenticatorData(sha256(utf8(request.rpId)), PASSKEY_FLAG_UP | PASSKEY_FLAG_UV, signCount,
        null, null);
      const signature = await ProPasskeyKeys.sign(record.alias, record.unlock, concatBytes([authData, clientDataHash]),
        '登录「' + request.rpId + '」');
      record.signCount = signCount;
      record.lastUsedAt = Date.now();
      ProPasskeyStore.save(context, record);
      return { v: PASSKEY_PROTOCOL_VERSION, id: request.id, ok: true, error: '', credentialId: record.id,
        authData: base64UrlEncode(authData), signature: base64UrlEncode(signature), userHandle: record.userId,
        publicKey: '' };
    } catch (error) {
      return failure(request, errorCode(error as Object));
    }
  }

  /** Deletes the record first, then its HUKS key; false when the record could not be removed. */
  static async remove(context: common.Context, owner: string, id: string): Promise<boolean> {
    let removed: PasskeyRecord | null = null;
    try { removed = ProPasskeyStore.remove(context, owner, id); } catch (_error) { return false; }
    if (removed !== null) { await ProPasskeyKeys.remove(removed.alias); }
    return true;
  }

  static declined(request: PasskeyRequest): PasskeyResponse { return failure(request, 'PASSKEY_USER_DENIED'); }

  static failed(request: PasskeyRequest, code: string): PasskeyResponse { return failure(request, code); }

  /** A bare success, for requests that return nothing but the outcome (pairing). */
  static done(request: PasskeyRequest): PasskeyResponse {
    return { v: PASSKEY_PROTOCOL_VERSION, id: request.id, ok: true, error: '', credentialId: '', authData: '',
      signature: '', userHandle: '', publicKey: '' };
  }
}
