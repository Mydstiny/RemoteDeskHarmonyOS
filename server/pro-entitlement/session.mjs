import { createHmac, timingSafeEqual } from 'node:crypto';
import { boundedString, fail, jwsParts } from './iap-crypto.mjs';

const LIFETIME_SECONDS = 600;
function challengeValue(value) {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{43}$/.test(value) &&
    Buffer.from(value, 'base64url').toString('base64url') === value;
}
function encode(value) { return Buffer.from(JSON.stringify(value)).toString('base64url'); }

// This credential authenticates requests; it is never an entitlement. A separate
// random deployment key, token type, audience and environment prevent grant or
// production/sandbox substitution. Only the verified vendor identity supplies sub.
export class ProSessionService {
  #configuration;
  #authorization;
  #key;
  #now;
  constructor(configuration, authorization, key, now = Date.now) {
    if (!Buffer.isBuffer(key) || key.length !== 32 || !['NORMAL', 'SANDBOX'].includes(configuration.environment)) {
      fail('invalid_session_configuration');
    }
    this.#configuration = Object.freeze({ applicationId: boundedString(configuration.applicationId),
      issuer: boundedString(configuration.issuer), environment: configuration.environment });
    this.#authorization = authorization; this.#key = Buffer.from(key); this.#now = now;
  }
  async issue(code, challenge, signal) {
    boundedString(code, 8192);
    if (!challengeValue(challenge) || signal?.aborted) fail('account_verification_failed');
    const owner = await this.#authorization.exchange(code, signal);
    const now = this.#now();
    if (!/^owner-[a-f0-9]{64}$/.test(owner) || !Number.isSafeInteger(now) || now <= 0 ||
      !Number.isSafeInteger(now + LIFETIME_SECONDS * 1000) || signal?.aborted) fail('account_verification_failed');
    const issuedAt = Math.floor(now / 1000); const expiresAt = issuedAt + LIFETIME_SECONDS;
    const payload = { v: 1, iss: this.#configuration.issuer, aud: this.#configuration.applicationId,
      env: this.#configuration.environment, sub: owner, iat: issuedAt, exp: expiresAt, jti: challenge };
    const input = encode({ alg: 'HS256', typ: 'pro-session+jwt' }) + '.' + encode(payload);
    const sessionToken = input + '.' + createHmac('sha256', this.#key).update(input).digest('base64url');
    return { sessionToken, owner, expiresAt: expiresAt * 1000, challenge };
  }
  async owner(token) {
    try {
      boundedString(token, 4096);
      const { header, payload, signature, input } = jwsParts(token);
      if (Object.keys(header).length !== 2 || header.alg !== 'HS256' || header.typ !== 'pro-session+jwt' || signature.length !== 32 ||
        !timingSafeEqual(signature, createHmac('sha256', this.#key).update(input).digest())) fail('invalid_session');
      const now = this.#now();
      if (!Number.isSafeInteger(now) || now <= 0 || Object.keys(payload).length !== 8 || payload.v !== 1 ||
        payload.iss !== this.#configuration.issuer || payload.aud !== this.#configuration.applicationId ||
        payload.env !== this.#configuration.environment || !/^owner-[a-f0-9]{64}$/.test(payload.sub) ||
        !Number.isSafeInteger(payload.iat) || !Number.isSafeInteger(payload.exp) || payload.iat <= 0 ||
        payload.exp - payload.iat !== LIFETIME_SECONDS || payload.iat > Math.floor(now / 1000) + 60 ||
        payload.exp <= Math.floor(now / 1000) || !challengeValue(payload.jti)) fail('invalid_session');
      return payload.sub;
    } catch { fail('account_verification_failed'); }
  }
}
