import { huks } from '@kit.UniversalKeystoreKit';
import { userAuth } from '@kit.UserAuthenticationKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

/** How a passkey's private key is unlocked; fixed when the key is created. */
export type PasskeyUnlock = 'biometric' | 'pin';

const AUTH_TRUST_LEVEL: userAuth.AuthTrustLevel = userAuth.AuthTrustLevel.ATL2;

function available(type: userAuth.UserAuthType): boolean {
  try { userAuth.getAvailableStatus(type, AUTH_TRUST_LEVEL); return true; } catch (_error) { return false; }
}

function biometricTypes(): userAuth.UserAuthType[] {
  const types: userAuth.UserAuthType[] = [];
  if (available(userAuth.UserAuthType.FACE)) { types.push(userAuth.UserAuthType.FACE); }
  if (available(userAuth.UserAuthType.FINGERPRINT)) { types.push(userAuth.UserAuthType.FINGERPRINT); }
  return types;
}

function huksAuthType(types: userAuth.UserAuthType[]): number {
  let value: number = 0;
  types.forEach((type: userAuth.UserAuthType): void => {
    if (type === userAuth.UserAuthType.FACE) { value |= huks.HuksUserAuthType.HUKS_USER_AUTH_TYPE_FACE; }
    if (type === userAuth.UserAuthType.FINGERPRINT) { value |= huks.HuksUserAuthType.HUKS_USER_AUTH_TYPE_FINGERPRINT; }
    if (type === userAuth.UserAuthType.PIN) { value |= huks.HuksUserAuthType.HUKS_USER_AUTH_TYPE_PIN; }
  });
  return value;
}

function unlockTypes(unlock: PasskeyUnlock): userAuth.UserAuthType[] {
  return unlock === 'biometric' ? biometricTypes() : [userAuth.UserAuthType.PIN];
}

function signProperties(): huks.HuksParam[] {
  return [
    { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_ECC },
    { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_ECC_KEY_SIZE_256 },
    { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_SIGN },
    { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_SHA256 }
  ];
}

/** Runs the system user-authentication sheet bound to a HUKS challenge and resolves with its auth token. */
function authenticate(challenge: Uint8Array, types: userAuth.UserAuthType[], title: string): Promise<Uint8Array> {
  return new Promise<Uint8Array>((resolve: (token: Uint8Array) => void, reject: (reason: Error) => void): void => {
    try {
      const instance: userAuth.UserAuthInstance = userAuth.getUserAuthInstance(
        { challenge, authType: types, authTrustLevel: AUTH_TRUST_LEVEL }, { title: title.slice(0, 60) });
      instance.on('result', {
        onResult: (result: userAuth.UserAuthResult): void => {
          try { instance.off('result'); } catch (_error) {}
          if (result.result === userAuth.UserAuthResultCode.SUCCESS && result.token !== undefined) {
            resolve(result.token);
          } else {
            reject(new Error(result.result === userAuth.UserAuthResultCode.CANCELED ? 'PASSKEY_USER_CANCELLED' :
              'PASSKEY_USER_AUTH_FAILED'));
          }
        }
      });
      instance.start();
    } catch (_error) {
      reject(new Error('PASSKEY_USER_AUTH_UNAVAILABLE'));
    }
  });
}

/**
 * P-256 passkey keys in HUKS. The private key never leaves HUKS; every signature needs a fresh face, fingerprint or
 * lock-screen PIN check bound to that signing session (HUKS challenge + auth token).
 */
export class ProPasskeyKeys {
  /** HUKS key access control and system user authentication are both present on this device. */
  static supported(): boolean {
    try {
      return canIUse('SystemCapability.Security.Huks.Extension') && canIUse('SystemCapability.UserIAM.UserAuth.Core');
    } catch (_error) {
      return false;
    }
  }

  /** The unlock method a new key would use on this device, or null when it cannot hold passkeys. */
  static preferredUnlock(): PasskeyUnlock | null {
    if (!ProPasskeyKeys.supported()) { return null; }
    if (biometricTypes().length > 0) { return 'biometric'; }
    return available(userAuth.UserAuthType.PIN) ? 'pin' : null;
  }

  static async generate(alias: string, unlock: PasskeyUnlock): Promise<void> {
    const types = unlockTypes(unlock);
    if (types.length === 0) { throw new Error('PASSKEY_USER_AUTH_UNAVAILABLE'); }
    const properties: huks.HuksParam[] = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_ECC },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_ECC_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE,
        value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_SIGN | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_VERIFY },
      { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_SHA256 },
      { tag: huks.HuksTag.HUKS_TAG_USER_AUTH_TYPE, value: huksAuthType(types) },
      // A new fingerprint must not silently strand every passkey; the per-use check still applies.
      { tag: huks.HuksTag.HUKS_TAG_KEY_AUTH_ACCESS_TYPE, value: huks.HuksAuthAccessType.HUKS_AUTH_ACCESS_ALWAYS_VALID },
      { tag: huks.HuksTag.HUKS_TAG_CHALLENGE_TYPE, value: huks.HuksChallengeType.HUKS_CHALLENGE_TYPE_NORMAL },
      { tag: huks.HuksTag.HUKS_TAG_KEY_AUTH_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_SIGN }
    ];
    try { await huks.generateKeyItem(alias, { properties }); }
    catch (_error) { throw new Error('PASSKEY_KEY_CREATE_FAILED'); }
  }

  /** X.509 SubjectPublicKeyInfo of the public key. */
  static async publicKey(alias: string): Promise<Uint8Array> {
    let result: huks.HuksReturnResult;
    try { result = await huks.exportKeyItem(alias, { properties: [] }); }
    catch (_error) { throw new Error('PASSKEY_KEY_EXPORT_FAILED'); }
    if (result.outData === undefined) { throw new Error('PASSKEY_KEY_EXPORT_FAILED'); }
    return result.outData;
  }

  /** ECDSA P-256 / SHA-256 signature (DER) over data, after the user unlocks the key. */
  static async sign(alias: string, unlock: PasskeyUnlock, data: Uint8Array, title: string): Promise<Uint8Array> {
    const types = unlockTypes(unlock);
    if (types.length === 0) { throw new Error('PASSKEY_USER_AUTH_UNAVAILABLE'); }
    let session: huks.HuksSessionHandle;
    try { session = await huks.initSession(alias, { properties: signProperties() }); }
    catch (_error) { throw new Error('PASSKEY_KEY_UNAVAILABLE'); }
    let finished: boolean = false;
    try {
      if (session.challenge === undefined) { throw new Error('PASSKEY_KEY_CHALLENGE_MISSING'); }
      const token: Uint8Array = await authenticate(session.challenge, types, title);
      let result: huks.HuksReturnResult;
      try {
        result = await huks.finishSession(session.handle, { properties: signProperties(), inData: data }, token);
      } catch (_error) {
        throw new Error('PASSKEY_SIGN_FAILED');
      }
      finished = true;
      if (result.outData === undefined || result.outData.length < 8) { throw new Error('PASSKEY_SIGN_FAILED'); }
      return result.outData;
    } finally {
      if (!finished) {
        try { await huks.abortSession(session.handle, { properties: signProperties() }); } catch (_error) {}
      }
    }
  }

  static async remove(alias: string): Promise<void> {
    try { await huks.deleteKeyItem(alias, { properties: [] }); } catch (_error) { /* already gone */ }
  }

  static async exists(alias: string): Promise<boolean> {
    try { return await huks.isKeyItemExist(alias, { properties: [] }); } catch (_error) { return false; }
  }
}

export function sha256(data: Uint8Array): Uint8Array {
  try {
    const md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data });
    return md.digestSync().data;
  } catch (_error) {
    throw new Error('PASSKEY_CRYPTO_UNAVAILABLE');
  }
}

export function utf8(text: string): Uint8Array {
  try { return new util.TextEncoder().encodeInto(text); }
  catch (_error) { throw new Error('PASSKEY_CRYPTO_UNAVAILABLE'); }
}

export function randomBytes(length: number): Uint8Array {
  try { return cryptoFramework.createRandom().generateRandomSync(length).data; }
  catch (_error) { throw new Error('PASSKEY_CRYPTO_UNAVAILABLE'); }
}

/** Verifies an ES256 signature with an SPKI public key, as a relying party would. */
export async function verifyEs256(spki: Uint8Array, data: Uint8Array, signature: Uint8Array): Promise<boolean> {
  try {
    const keyPair: cryptoFramework.KeyPair =
      await cryptoFramework.createAsyKeyGenerator('ECC256').convertKey({ data: spki }, null);
    const verifier: cryptoFramework.Verify = cryptoFramework.createVerify('ECC256|SHA256');
    await verifier.init(keyPair.pubKey);
    return await verifier.verify({ data }, { data: signature });
  } catch (_error) {
    return false;
  }
}
