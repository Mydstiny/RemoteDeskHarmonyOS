import { huks } from '@kit.UniversalKeystoreKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import {
  base64UrlDecode, base64UrlEncode, passkeyCleanText, PasskeyRequest, passkeyPairingCode, passkeyPairingCodeInput,
  passkeyRequestSigningBytes
} from './ProPasskeyCodec';
import { sha256, verifyEs256 } from './ProPasskeyKeys';

const DEVICE_KEY_ALIAS: string = 'rd_pkdev_v1';

function properties(): huks.HuksParam[] {
  return [
    { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_ECC },
    { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_ECC_KEY_SIZE_256 },
    { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_SIGN },
    { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_SHA256 }
  ];
}

/** How this device names itself in requests (the phone shows the name confirmed at pairing instead). */
export function passkeyDeviceLabel(): string {
  return passkeyCleanText(deviceInfo.marketName || deviceInfo.productModel || 'HarmonyOS 设备', 40);
}

/** ID of a device key: its public key's SHA-256, first 16 bytes, base64url. */
export function passkeyDeviceId(spki: Uint8Array): string {
  return base64UrlEncode(sha256(spki).slice(0, 16));
}

/** The six-digit code both devices show while pairing. */
export function passkeyPairingCodeOf(request: PasskeyRequest): string {
  return passkeyPairingCode(sha256(passkeyPairingCodeInput(request)));
}

/**
 * This device's passkey identity: one HUKS P-256 key that signs the requests it sends. It needs no face or
 * fingerprint (it only says which device asks); the phone answers only devices the user paired with it.
 */
export class ProPasskeyDevice {
  private static spki: Uint8Array | null = null;

  static async publicKey(): Promise<Uint8Array> {
    const cached = ProPasskeyDevice.spki;
    if (cached !== null) { return cached; }
    let exists: boolean = false;
    try { exists = await huks.isKeyItemExist(DEVICE_KEY_ALIAS, { properties: [] }); } catch (_error) { exists = false; }
    if (!exists) {
      const generation: huks.HuksParam[] = [
        { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_ECC },
        { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_ECC_KEY_SIZE_256 },
        { tag: huks.HuksTag.HUKS_TAG_PURPOSE,
          value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_SIGN | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_VERIFY },
        { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_SHA256 }
      ];
      try { await huks.generateKeyItem(DEVICE_KEY_ALIAS, { properties: generation }); }
      catch (_error) { throw new Error('PASSKEY_DEVICE_KEY_FAILED'); }
    }
    let result: huks.HuksReturnResult;
    try { result = await huks.exportKeyItem(DEVICE_KEY_ALIAS, { properties: [] }); }
    catch (_error) { throw new Error('PASSKEY_DEVICE_KEY_FAILED'); }
    if (result.outData === undefined || result.outData.length !== 91) { throw new Error('PASSKEY_DEVICE_KEY_FAILED'); }
    ProPasskeyDevice.spki = result.outData;
    return result.outData;
  }

  static async id(): Promise<string> { return passkeyDeviceId(await ProPasskeyDevice.publicKey()); }

  private static async sign(data: Uint8Array): Promise<Uint8Array> {
    let session: huks.HuksSessionHandle;
    try { session = await huks.initSession(DEVICE_KEY_ALIAS, { properties: properties() }); }
    catch (_error) { throw new Error('PASSKEY_DEVICE_KEY_FAILED'); }
    try {
      const result = await huks.finishSession(session.handle, { properties: properties(), inData: data });
      if (result.outData === undefined || result.outData.length < 8) { throw new Error('PASSKEY_DEVICE_KEY_FAILED'); }
      return result.outData;
    } catch (_error) {
      try { await huks.abortSession(session.handle, { properties: properties() }); } catch (_abortError) {}
      throw new Error('PASSKEY_DEVICE_KEY_FAILED');
    }
  }

  /** Fills in this device's ID (and public key for 'pair') and signs the request. */
  static async signRequest(request: PasskeyRequest): Promise<PasskeyRequest> {
    const spki = await ProPasskeyDevice.publicKey();
    request.device = passkeyDeviceId(spki);
    request.devicePub = request.op === 'pair' ? base64UrlEncode(spki) : '';
    request.sig = '';
    request.sig = base64UrlEncode(await ProPasskeyDevice.sign(passkeyRequestSigningBytes(request)));
    return request;
  }
}

/** Whether `request` was signed by the key in `spki` and names that key as its device. */
export async function passkeyRequestSignedBy(request: PasskeyRequest, spki: Uint8Array): Promise<boolean> {
  const signature = base64UrlDecode(request.sig);
  if (signature === null || passkeyDeviceId(spki) !== request.device) { return false; }
  return verifyEs256(spki, passkeyRequestSigningBytes(request), signature);
}
