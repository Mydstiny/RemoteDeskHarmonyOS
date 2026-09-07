import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { ProEnvironment, ProVerifiedGrant } from './ProAccessPolicy';
import { ProVerificationStatus, ProVerificationResult } from './ProEntitlementService';

export interface ProTrustConfiguration {
  applicationId: string;
  issuer: string;
  productId: string;
  environment: ProEnvironment;
  keyId: string;
  publicKeyDer: Uint8Array;
}
interface ProJwsHeader { alg: string; typ: string; kid: string; }
interface ProSignedPayload {
  version: number;
  issuer: string;
  applicationId: string;
  owner: string;
  environment: ProEnvironment;
  productId: string;
  status: ProVerificationStatus;
  revision: number;
  challenge: string;
  entitlementIds: string[];
  verifiedAt: number;
  revalidateAfter: number;
  usableUntil: number;
}
export interface ProTrustedSnapshot {
  signedEntitlement: string;
  challenge: string;
  revision: number;
  verifiedAt: number;
  usableUntil: number;
  signedStatus: ProVerificationStatus;
  result: ProVerificationResult;
}

const MAX_SIGNED_BYTES: number = 16384;
const MAX_CACHE_LIFETIME: number = 7 * 86400000;
function invalid(): never { throw new Error('Invalid signed Pro entitlement'); }
function bounded(value: string): boolean {
  return typeof value === 'string' && value.length > 0 && value.length <= 256 && !/[\u0000-\u001f\u007f]/.test(value);
}
function decodeSegment(value: string): Uint8Array {
  if (value.length === 0 || !/^[A-Za-z0-9_-]+$/.test(value) || value.length % 4 === 1) { invalid(); }
  const base64 = new util.Base64Helper();
  let standard = value.replace(/-/g, '+').replace(/_/g, '/');
  while (standard.length % 4 !== 0) { standard += '='; }
  const bytes = base64.decodeSync(standard);
  const canonical = base64.encodeToStringSync(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  if (canonical !== value) { invalid(); }
  return bytes;
}
function decodeJson(value: Uint8Array): string {
  return util.TextDecoder.create('utf-8', { fatal: true, ignoreBOM: true }).decodeToString(value);
}

// Only this server-signed format enters the entitlement service. Store callback
// payloads and Huawei order JSON are never interpreted here as local grants.
export class ProSignedEntitlementVerifier {
  private configuration: ProTrustConfiguration;
  constructor(configuration: ProTrustConfiguration) {
    if (![configuration.applicationId, configuration.issuer, configuration.productId, configuration.keyId]
      .every((value: string): boolean => bounded(value)) ||
      (configuration.environment !== 'production' && configuration.environment !== 'sandbox') ||
      !(configuration.publicKeyDer instanceof Uint8Array) || configuration.publicKeyDer.length < 256 ||
      configuration.publicKeyDer.length > 1024) { invalid(); }
    this.configuration = { applicationId: configuration.applicationId, issuer: configuration.issuer,
      productId: configuration.productId, environment: configuration.environment, keyId: configuration.keyId,
      publicKeyDer: configuration.publicKeyDer.slice() };
  }
  async verify(signedEntitlement: string, owner: string, now: number): Promise<ProTrustedSnapshot> {
    return this.verifyInternal(signedEntitlement, owner, now, false);
  }
  // A historical signature can protect a revision floor or refund tombstone.
  // An expired positive record is returned as unavailable, without a grant.
  async inspectCached(signedEntitlement: string, owner: string, now: number): Promise<ProTrustedSnapshot> {
    return this.verifyInternal(signedEntitlement, owner, now, true);
  }
  private async verifyInternal(signedEntitlement: string, owner: string, now: number,
    historical: boolean): Promise<ProTrustedSnapshot> {
    if (typeof signedEntitlement !== 'string' || signedEntitlement.length > MAX_SIGNED_BYTES ||
      !/^owner-[a-f0-9]{64}$/.test(owner) || !Number.isSafeInteger(now) || now <= 0) { invalid(); }
    const segments = signedEntitlement.split('.');
    if (segments.length !== 3) { invalid(); }
    const header = JSON.parse(decodeJson(decodeSegment(segments[0]))) as ProJwsHeader;
    const config = this.configuration;
    if (!header || typeof header !== 'object' || Array.isArray(header) || Object.keys(header).length !== 3 ||
      header.alg !== 'RS256' || header.typ !== 'JWT' || header.kid !== config.keyId) { invalid(); }
    const signature = decodeSegment(segments[2]);
    if (signature.length !== 256) { invalid(); }
    const generator = cryptoFramework.createAsyKeyGenerator('RSA2048');
    const key = await generator.convertKey({ data: config.publicKeyDer }, null);
    const verifier = cryptoFramework.createVerify('RSA2048|PKCS1|SHA256');
    await verifier.init(key.pubKey);
    const input = new util.TextEncoder().encodeInto(segments[0] + '.' + segments[1]);
    if (!await verifier.verify({ data: input }, { data: signature })) { invalid(); }

    const payload = JSON.parse(decodeJson(decodeSegment(segments[1]))) as ProSignedPayload;
    if (!payload || typeof payload !== 'object' || Array.isArray(payload) || Object.keys(payload).length !== 13 ||
      payload.version !== 1 || payload.issuer !== config.issuer || payload.applicationId !== config.applicationId ||
      payload.owner !== owner || payload.environment !== config.environment || payload.productId !== config.productId ||
      (payload.status !== 'verified' && payload.status !== 'revoked' && payload.status !== 'noEntitlement') ||
      !Number.isSafeInteger(payload.revision) || payload.revision < 0 ||
      typeof payload.challenge !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(payload.challenge) ||
      decodeSegment(payload.challenge).length !== 32 ||
      !Number.isSafeInteger(payload.verifiedAt) || !Number.isSafeInteger(payload.revalidateAfter) ||
      !Number.isSafeInteger(payload.usableUntil) || payload.verifiedAt <= 0 || payload.verifiedAt > now ||
      payload.revalidateAfter < payload.verifiedAt || payload.revalidateAfter >= payload.usableUntil ||
      payload.usableUntil - payload.verifiedAt > MAX_CACHE_LIFETIME || (!historical && payload.usableUntil <= now) ||
      !Array.isArray(payload.entitlementIds) ||
      (payload.status === 'verified' ? payload.entitlementIds.length !== 1 || payload.entitlementIds[0] !== 'pro.lifetime' :
        payload.entitlementIds.length !== 0)) { invalid(); }
    const result: ProVerificationResult = { status: payload.status, owner, environment: payload.environment };
    if (payload.status === 'verified' && payload.usableUntil <= now) {
      result.status = 'unavailable';
    } else if (payload.status === 'verified') {
      const grant: ProVerifiedGrant = { owner, environment: payload.environment, productId: payload.productId,
        verifiedAt: payload.verifiedAt, revalidateAfter: payload.revalidateAfter, usableUntil: payload.usableUntil,
        entitlementIds: payload.entitlementIds.slice() };
      result.grant = grant;
    }
    return { signedEntitlement, challenge: payload.challenge, revision: payload.revision, verifiedAt: payload.verifiedAt,
      usableUntil: payload.usableUntil, signedStatus: payload.status, result };
  }
}
