// Execute the production ArkTS verifier using real Node RSA. Only the platform
// API boundary is adapted; device CryptoFramework acceptance remains separate.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { test } = require('node:test');
const keyPair = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const owner = 'owner-' + 'a'.repeat(64);
const now = 1788753534000;
const challenge = crypto.randomBytes(32).toString('base64url');
const config = { applicationId: 'test-app', issuer: 'test-issuer', productId: 'test-pro', environment: 'sandbox',
  keyId: 'test-key', publicKeyDer: new Uint8Array(keyPair.publicKey.export({ type: 'spki', format: 'der' })) };
const payload = { version: 1, issuer: config.issuer, applicationId: config.applicationId, owner,
  environment: config.environment, productId: config.productId, status: 'verified', revision: 1, challenge,
  entitlementIds: ['pro.lifetime'], verifiedAt: now, revalidateAfter: now + 86400000, usableUntil: now + 604800000 };
function signed(changes = {}, header = {}, key = keyPair.privateKey) {
  const parts = [JSON.stringify({ alg: 'RS256', typ: 'JWT', kid: config.keyId, ...header }),
    JSON.stringify({ ...payload, ...changes })].map(part => Buffer.from(part).toString('base64url'));
  const input = parts.join('.');
  return input + '.' + crypto.sign('RSA-SHA256', Buffer.from(input), key).toString('base64url');
}
const { proClientHost } = require('./helpers/pro_client_host.cjs');
const host = proClientHost();
require('node:test').after(() => host.close());
const { ProSignedEntitlementVerifier } = host.load('ProSignedEntitlement');
function verifier(configuration = config) { return new ProSignedEntitlementVerifier(configuration); }

test('actual server signer produces an interoperable RS256 client grant', async () => {
  const { ProGrantSigner } = await import('../../server/pro-entitlement/fulfillment.mjs');
  const signer = new ProGrantSigner({ ...config, environment: 'SANDBOX' },
    keyPair.privateKey.export({ type: 'pkcs8', format: 'pem' }));
  const token = signer.sign({ status: 'verified', revision: 7 }, owner, now, challenge);
  const accepted = await verifier().verify(token, owner, now);
  assert.equal(accepted.result.status, 'verified'); assert.equal(accepted.revision, 7);
  assert.equal(accepted.result.grant.entitlementIds[0], 'pro.lifetime');
  assert.equal(accepted.signedEntitlement, token);
});
test('signed no-entitlement and refund states never carry a usable grant', async () => {
  for (const status of ['revoked', 'noEntitlement']) {
    const value = await verifier().verify(signed({ status, entitlementIds: [], revision: 9 }), owner, now);
    assert.equal(value.result.status, status); assert.equal(value.result.grant, undefined);
    await assert.rejects(() => verifier().verify(signed({ status }), owner, now));
  }
});
test('tampering, unknown key and algorithm substitutions are rejected', async () => {
  const token = signed(); const parts = token.split('.');
  parts[1] = Buffer.from(JSON.stringify({ ...payload, revision: 999 })).toString('base64url');
  await assert.rejects(() => verifier().verify(parts.join('.'), owner, now));
  for (const header of [{ alg: 'none' }, { alg: 'HS256' }, { kid: 'unknown' }, { jku: 'https://untrusted.invalid/key' }]) {
    await assert.rejects(() => verifier().verify(signed({}, header), owner, now));
  }
  const other = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  await assert.rejects(() => verifier().verify(signed({}, {}, other.privateKey), owner, now));
});
test('valid signatures cannot cross owner, application, issuer, product or environment', async () => {
  for (const changes of [{ owner: 'owner-' + 'b'.repeat(64) }, { applicationId: 'other-app' },
    { issuer: 'other-issuer' }, { productId: 'other-pro' }, { environment: 'production' }]) {
    await assert.rejects(() => verifier().verify(signed(changes), owner, now));
  }
});
test('signed schema and capability whitelist are strict', async () => {
  for (const changes of [{ version: 2 }, { version: '1' }, { revision: -1 }, { revision: 1.5 },
    { revision: '1' }, { revision: Number.MAX_SAFE_INTEGER + 1 }, { status: 'unavailable' },
    { entitlementIds: [] }, { entitlementIds: ['pro.lifetime', 'extra'] }, { entitlementIds: 'pro.lifetime' },
    { extra: true }]) {
    await assert.rejects(() => verifier().verify(signed(changes), owner, now));
  }
});
test('expiration, clock rollback and extended offline lifetimes fail closed', async () => {
  for (const changes of [{ verifiedAt: now + 1 }, { revalidateAfter: now - 1 },
    { revalidateAfter: payload.usableUntil }, { usableUntil: now }, { usableUntil: payload.usableUntil + 1 },
    { verifiedAt: 0 }, { usableUntil: Number.MAX_SAFE_INTEGER + 1 }]) {
    await assert.rejects(() => verifier().verify(signed(changes), owner, now));
  }
  await assert.rejects(() => verifier().verify(signed(), owner, now - 1));
  await assert.rejects(() => verifier().verify(signed(), owner, payload.usableUntil));
});
test('canonical bounded input is enforced before expensive crypto', async () => {
  const before = host.state.verifies;
  const parts = signed().split('.');
  for (const token of ['', 'x'.repeat(16385), parts.join('.') + '.',
    parts[0] + '=.' + parts[1] + '.' + parts[2], parts[0] + '.' + parts[1] + '.AA',
    'A.' + parts[1] + '.' + parts[2]]) {
    await assert.rejects(() => verifier().verify(token, owner, now));
  }
  assert.equal(host.state.verifies, before);
});
test('configuration is copied and malformed trust roots are rejected', async () => {
  const mutable = { ...config, publicKeyDer: config.publicKeyDer.slice() }; const instance = verifier(mutable);
  mutable.publicKeyDer.fill(0); mutable.productId = 'attacker';
  assert.equal((await instance.verify(signed(), owner, now)).result.status, 'verified');
  for (const changes of [{ publicKeyDer: new Uint8Array(0) }, { issuer: '' }, { environment: 'invalid' }]) {
    assert.throws(() => verifier({ ...config, ...changes }));
  }
});
