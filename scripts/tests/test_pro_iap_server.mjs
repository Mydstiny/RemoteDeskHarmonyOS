import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, sign, verify, X509Certificate } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { HuaweiIapJwsVerifier, HUAWEI_IAP_ROOT_SHA256, certificateCrlUrls, iapAuthorization, jwsParts } from '../../server/pro-entitlement/iap-crypto.mjs';
import { HuaweiIapCrlSource } from '../../server/pro-entitlement/iap-crl.mjs';
import { HuaweiAccountVerifier, HuaweiIapClient, orderReferenceFromPurchaseData, ownerForUnionId,
  validateCurrentOrder, vendorPost } from '../../server/pro-entitlement/huawei-api.mjs';

const directory = mkdtempSync(join(tmpdir(), 'pro-iap-test-'));
after(() => rmSync(directory, { recursive: true, force: true }));
function put(name, value) { writeFileSync(join(directory, name), value, { mode: 0o600 }); }
function read(name) { return readFileSync(join(directory, name), 'utf8'); }
function openssl(...args) { return execFileSync('openssl', args, { cwd: directory, stdio: ['ignore', 'pipe', 'pipe'], timeout: 15000 }); }
const caExtensions = 'basicConstraints=critical,CA:true\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n';
function request(name) {
  openssl('req', '-new', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-noenc',
    '-keyout', name + '.key', '-out', name + '.csr', '-subj', '/CN=Pro Test ' + name);
}
function issue(name, parent, extensions) {
  request(name); put(name + '.ext', extensions);
  openssl('x509', '-req', '-in', name + '.csr', '-CA', parent + '.pem', '-CAkey', parent + '.key',
    '-CAcreateserial', '-out', name + '.pem', '-days', '2', '-extfile', name + '.ext');
}
put('root.ext', '[req]\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\n[ext]\n' + caExtensions);
openssl('req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-noenc',
  '-keyout', 'root.key', '-out', 'root.pem', '-days', '2', '-subj', '/CN=Pro Test Root', '-config', 'root.ext');
issue('intermediate', 'root', caExtensions + 'crlDistributionPoints=URI:https://pki.consumer.huawei.com/ca/crl/root.crl\n');
const leafExtensions = 'basicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n' +
  'crlDistributionPoints=URI:http://pki.consumer.huawei.com/ca/crl/intermediate.crl\n';
issue('leaf', 'intermediate', leafExtensions + '1.3.6.1.4.1.2011.2.415.1.1=ASN1:NULL\n');
issue('ordinary', 'intermediate', leafExtensions);
issue('critical', 'intermediate', leafExtensions + '1.3.6.1.4.1.2011.2.415.1.1=critical,ASN1:NULL\n');
issue('unknown', 'intermediate', leafExtensions + '1.3.6.1.4.1.2011.2.415.1.1=ASN1:NULL\n1.2.3.4=critical,ASN1:NULL\n');
issue('noSign', 'intermediate', leafExtensions.replace('digitalSignature', 'keyAgreement') + '1.3.6.1.4.1.2011.2.415.1.1=ASN1:NULL\n');
issue('foreignCrl', 'intermediate', leafExtensions.replace('pki.consumer.huawei.com/ca/crl/intermediate.crl', '127.0.0.1/private.crl') +
  '1.3.6.1.4.1.2011.2.415.1.1=ASN1:NULL\n');
issue('credentialsCrl', 'intermediate', leafExtensions.replace('http://pki.consumer.huawei.com', 'http://user@pki.consumer.huawei.com') +
  '1.3.6.1.4.1.2011.2.415.1.1=ASN1:NULL\n');
const actualLeafCdp = 'http://h5hosting-drcn.dbankcdn.cn/cch5/crl/haicag3/HuaweiCBGHAIG3crl.crl';
const actualRootCdp = 'http://cpki-caweb.huawei.com/cpki/servlet/crlFileDown.crl?certype=10&/root_g2_crl.crl';
issue('cdnLeaf', 'intermediate', leafExtensions.replace('http://pki.consumer.huawei.com/ca/crl/intermediate.crl', actualLeafCdp) +
  '1.3.6.1.4.1.2011.2.415.1.1=ASN1:NULL\n');
issue('rootCdpLeaf', 'intermediate', leafExtensions.replace('http://pki.consumer.huawei.com/ca/crl/intermediate.crl', actualRootCdp) +
  '1.3.6.1.4.1.2011.2.415.1.1=ASN1:NULL\n');
issue('legacyRootCdpLeaf', 'intermediate', leafExtensions.replace('http://pki.consumer.huawei.com/ca/crl/intermediate.crl',
  'http://pki.consumer.huawei.com/ca/crl/root_g2_crl.crl') + '1.3.6.1.4.1.2011.2.415.1.1=ASN1:NULL\n');
for (const [name, url] of [['cdnOtherPath', actualLeafCdp.replace('HuaweiCBGHAIG3crl.crl','other.crl')],
  ['cdnQuery', actualLeafCdp+'?redirect=1'], ['cdnPort', actualLeafCdp.replace('.cn/', '.cn:80/')],
  ['rootQuery', actualRootCdp.replace('certype=10','certype=11')]]) {
  issue(name, 'intermediate', leafExtensions.replace('http://pki.consumer.huawei.com/ca/crl/intermediate.crl',url)+
    '1.3.6.1.4.1.2011.2.415.1.1=ASN1:NULL\n');
}
for (const ca of ['root', 'intermediate']) {
  put(ca + '.db', ''); put(ca + '.serial', '1000\n'); put(ca + '.crlnumber', '1000\n');
  put(ca + '.cnf', `[ca]\ndefault_ca=authority\n[authority]\ndatabase=${ca}.db\nserial=${ca}.serial\ncrlnumber=${ca}.crlnumber\ncertificate=${ca}.pem\nprivate_key=${ca}.key\ndefault_md=sha256\ndefault_crl_days=1\n`);
  openssl('ca', '-gencrl', '-config', ca + '.cnf', '-out', ca + '.crl');
}
const root = new X509Certificate(read('root.pem'));
const rootFingerprint = createHash('sha256').update(root.raw).digest('hex');
const crls = read('root.crl') + read('intermediate.crl');
const crlDer = new Map(['root', 'intermediate'].map(name => [name, openssl('crl', '-in', name + '.crl', '-outform', 'DER')]));
const now = Date.now();
const reference = { purchaseOrderId: 'test-order', purchaseToken: 'test-purchase-token' };
const merchant = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const configuration = { applicationId: 'test-application', packageName: 'test.example.remotedesk', productId: 'test.pro.lifetime', environment: 'NORMAL',
  issuerId: 'test-issuer', keyId: 'test-key', privateKey: merchant.privateKey.export({ type: 'pkcs8', format: 'pem' }) };
const order = { ...reference, applicationId: configuration.applicationId, productId: configuration.productId,
  productType: '1', environment: 'NORMAL', purchaseTime: now - 1000, signedTime: now,
  finishStatus: '2', needFinish: true, developerPayload: 'server-created-intent' };
function jwt(payload = order, name = 'leaf', override = {}) {
  const header = { alg: 'ES256', typ: 'JWT', x5c: [name, 'intermediate', 'root'].map(n =>
    new X509Certificate(read(n + '.pem')).raw.toString('base64')), ...override };
  const input = Buffer.from(JSON.stringify(header)).toString('base64url') + '.' + Buffer.from(JSON.stringify(payload)).toString('base64url');
  return input + '.' + sign('sha256', Buffer.from(input), { key: read(name + '.key'), dsaEncoding: 'ieee-p1363' }).toString('base64url');
}
function verifier(options = {}) {
  return new HuaweiIapJwsVerifier({ rootCertificate: read('root.pem'), crls, rootFingerprint, now: () => now, ...options });
}
function response(body, options = {}) { return new Response(JSON.stringify(body), { status: 200, ...options }); }

test('real OpenSSL certificate path + IAP OID + P1363 signature accept a generated valid chain', async () => {
  assert.deepEqual(await verifier().verify(jwt()), order);
});
test('the production root pin cannot be replaced by an otherwise valid private CA', () => {
  assert.notEqual(rootFingerprint, HUAWEI_IAP_ROOT_SHA256);
  assert.throws(() => new HuaweiIapJwsVerifier({ rootCertificate: read('root.pem'), crls }), /untrusted_iap_root/);
  assert.throws(() => verifier({ crls: '' }), /iap_crls_required/);
});
test('ordinary and critical-OID certificates are rejected even with a valid CA signature', async () => {
  await assert.rejects(() => verifier().verify(jwt(order, 'ordinary')));
  await assert.rejects(() => verifier().verify(jwt(order, 'critical')));
  await assert.rejects(() => verifier().verify(jwt(order, 'unknown')));
});
test('IAP leaf must explicitly permit digitalSignature even when PKIX purpose is any', async () => {
  await assert.rejects(() => verifier().verify(jwt(order, 'noSign')));
});
test('algorithm confusion, missing chain, unsupported critical header and forged signature cannot grant', async () => {
  for (const header of [{ alg: 'HS256' }, { typ: 'JWS' }, { x5c: [] }, { crit: ['foo'] }, { b64: false }]) {
    await assert.rejects(() => verifier().verify(jwt(order, 'leaf', header)));
  }
  const parts = jwt().split('.'); parts[2] = Buffer.alloc(64).toString('base64url');
  await assert.rejects(() => verifier().verify(parts.join('.')));
  const mismatched = jwt().split('.'); mismatched[1] = Buffer.from(JSON.stringify({ ...order, productId: 'changed' })).toString('base64url');
  await assert.rejects(() => verifier().verify(mismatched.join('.')));
});
test('expired path and revoked leaf fail with real CRL verification', async () => {
  await assert.rejects(() => verifier({ now: () => now + 3 * 86400000 }).verify(jwt()));
  openssl('ca', '-config', 'intermediate.cnf', '-revoke', 'leaf.pem');
  openssl('ca', '-gencrl', '-config', 'intermediate.cnf', '-out', 'revoked.crl');
  await assert.rejects(() => verifier({ crls: read('root.crl') + read('revoked.crl'), now: Date.now }).verify(jwt()));
});
function liveCrlFixture(fetcher, clock = () => now) {
  const calls = [];
  const source = new HuaweiIapCrlSource(async (url, request) => {
    calls.push({ url, request });
    if (fetcher) return fetcher(url, request);
    return new Response(crlDer.get(url.includes('intermediate.crl') ? 'intermediate' : 'root'));
  }, clock);
  return { calls, source, verifier: verifier({ crls: undefined, crlSource: source, now: clock }) };
}
test('dynamic CRLs are fetched from signed distribution points and cached only after full revocation verification', async () => {
  const f = liveCrlFixture();
  assert.deepEqual(certificateCrlUrls(new X509Certificate(read('leaf.pem')).raw),
    ['http://pki.consumer.huawei.com/ca/crl/intermediate.crl']);
  assert.deepEqual(await f.verifier.verify(jwt()), order); assert.equal(f.calls.length, 2);
  assert.deepEqual(await f.verifier.verify(jwt()), order); assert.equal(f.calls.length, 2);
  for (const call of f.calls) {
    assert.equal(call.request.method, 'GET'); assert.equal(call.request.redirect, 'error');
    assert.deepEqual(Object.keys(call.request.headers), ['Accept']);
    assert.ok(call.request.signal instanceof AbortSignal);
  }
});
test('untrusted certificate paths and forged JWS never trigger a CRL download', async () => {
  const f = liveCrlFixture(); const forged = jwt().split('.'); forged[2] = Buffer.alloc(64).toString('base64url');
  for (const value of [forged.join('.'), jwt(order, 'unknown'), jwt(order, 'ordinary')]) {
    await assert.rejects(() => f.verifier.verify(value));
  }
  const expired = liveCrlFixture(undefined, () => now + 3 * 86400000);
  await assert.rejects(() => expired.verifier.verify(jwt()));
  assert.equal(f.calls.length, 0); assert.equal(expired.calls.length, 0);
});
test('valid signatures cannot use foreign or credential-bearing CRL destinations', async () => {
  const f = liveCrlFixture();
  for (const name of ['foreignCrl', 'credentialsCrl']) await assert.rejects(() => f.verifier.verify(jwt(order, name)));
  assert.equal(f.calls.length, 0);
  assert.throws(() => certificateCrlUrls(Buffer.from([48, 128, 0, 0])));
});
test('dynamic revoked or malformed CRLs fail and cannot poison a later valid download', async () => {
  let bad = true;
  const f = liveCrlFixture(async url => new Response(bad ? Buffer.from('not a CRL') :
    crlDer.get(url.includes('intermediate.crl') ? 'intermediate' : 'root')));
  await assert.rejects(() => f.verifier.verify(jwt())); bad = false;
  assert.deepEqual(await f.verifier.verify(jwt()), order); assert.equal(f.calls.length, 4);
  const revoked = liveCrlFixture(async url => new Response(url.includes('intermediate.crl') ?
    openssl('crl', '-in', 'revoked.crl', '-outform', 'DER') : crlDer.get('root')));
  await assert.rejects(() => revoked.verifier.verify(jwt()));
});
test('CRL cache refresh is bounded to five minutes and expired cached CRLs are never accepted', async () => {
  let instant = now; const f = liveCrlFixture(undefined, () => instant);
  await f.verifier.verify(jwt()); instant += 299999; await f.verifier.verify(jwt()); assert.equal(f.calls.length, 2);
  instant++; await f.verifier.verify(jwt()); assert.equal(f.calls.length, 4);
  instant = now + 86400000 + 1000;
  await assert.rejects(() => f.verifier.verify(jwt())); assert.equal(f.calls.length, 6);
  await assert.rejects(() => f.verifier.verify(jwt())); assert.equal(f.calls.length, 8);
});
test('CRL transport rejects redirects, oversized streams and empty responses without caching them', async () => {
  for (const fetcher of [async () => new Response(null, { status: 302, headers: { location: 'https://example.test' } }),
    async () => new Response('x', { headers: { 'content-length': String(2 * 1024 * 1024 + 1) } }),
    async () => new Response(Buffer.alloc(2 * 1024 * 1024 + 1)), async () => new Response('')]) {
    const f = liveCrlFixture(fetcher); await assert.rejects(() => f.verifier.verify(jwt()));
    await assert.rejects(() => f.verifier.verify(jwt())); assert.equal(f.calls.length, 4);
  }
});
test('merchant authorization signs exact request bytes, correct audience and bounded lifetime', () => {
  const body = JSON.stringify(reference); const parts = jwsParts(iapAuthorization(body, configuration, now));
  assert.equal(parts.header.alg, 'ES256'); assert.equal(parts.header.kid, 'test-key');
  assert.equal(parts.payload.aud, 'iap-v1'); assert.equal(parts.payload.aid, 'test-application');
  assert.equal(parts.payload.digest, createHash('sha256').update(body).digest('hex'));
  assert.equal(parts.payload.exp - parts.payload.iat, 300);
  assert.equal(verify('sha256', parts.input, { key: merchant.publicKey, dsaEncoding: 'ieee-p1363' }, parts.signature), true);
  assert.notEqual(parts.payload.digest, createHash('sha256').update(body + ' ').digest('hex'));
});
test('Account Kit verifies user token, OAuth client and expiry before deriving app owner', async () => {
  const calls = [];
  const client = new HuaweiAccountVerifier('expected-client', async (url, request) => {
    calls.push({ url, request }); return response({ type: 0, expire_in: 3600, client_id: 'expected-client', union_id: 'test-union', open_id: 'test-open' });
  });
  assert.equal(await client.owner('opaque&test=token'), ownerForUnionId('test-union'));
  assert.equal(calls[0].url, 'https://oauth-api.cloud.huawei.com/rest.php?nsp_fmt=JSON&nsp_svc=huawei.oauth2.user.getTokenInfo');
  assert.equal(calls[0].request.redirect, 'error'); assert.equal(new URLSearchParams(calls[0].request.body).get('access_token'), 'opaque&test=token');
  for (const mutation of [{ type: 1 }, { client_id: 'other-client' }, { expire_in: 0 }, { union_id: '' }, { error: 'invalid' }]) {
    const invalid = new HuaweiAccountVerifier('expected-client', async () => response({ type: 0, expire_in: 3600,
      client_id: 'expected-client', union_id: 'test-union', open_id: 'test-open', ...mutation }));
    await assert.rejects(() => invalid.owner('opaque-token'));
  }
});
test('HTTP 200 vendor error headers and oversized streaming responses are failures', async () => {
  await assert.rejects(() => vendorPost('unused', '', {}, async () => response({}, { headers: { NSP_STATUS: '102' } })));
  await assert.rejects(() => vendorPost('unused', '', {}, async () => response({ value: 'x'.repeat(128 * 1024) })));
});
test('unverified client receipt only provides a bounded lookup reference, never owner or entitlement', () => {
  assert.deepEqual(orderReferenceFromPurchaseData(JSON.stringify({ jwsPurchaseOrder: jwt({ ...reference, owner: 'attacker', productType: '0' }) })), reference);
  assert.throws(() => orderReferenceFromPurchaseData(JSON.stringify({ jwsPurchaseOrder: jwt({ ...reference, purchaseToken: 'x'.repeat(257) }) })));
  assert.throws(() => orderReferenceFromPurchaseData('not-json'));
});
test('latest order binds app, product, type, environment, token, time and completed payment', () => {
  assert.equal(validateCurrentOrder(order, reference, configuration, now).needsFinish, true);
  for (const mutation of [{ applicationId: 'other' }, { productId: 'other' }, { productType: 1 }, { environment: 'SANDBOX' },
    { purchaseToken: 'other' }, { signedTime: now - 300001 }, { signedTime: now + 60001 },
    { purchaseTime: undefined }, { finishStatus: 'unknown' }, { needFinish: 'true' }]) {
    assert.throws(() => validateCurrentOrder({ ...order, ...mutation }, reference, configuration, now));
  }
  assert.equal(validateCurrentOrder({ ...order, finishStatus: '1' }, reference, configuration, now).needsFinish, false);
  assert.equal(validateCurrentOrder({ ...order, revocationTime: now }, reference, configuration, now).revoked, true);
  assert.equal(validateCurrentOrder({ ...order, purchaseOrderRevocationReasonCode: '1' }, reference, configuration, now).needsFinish, false);
});
test('IAP query validates signed current state and never acknowledges delivery on its own', async () => {
  const calls = [];
  const client = new HuaweiIapClient(configuration, verifier(), async (url, request) => {
    calls.push({ url, request }); return response({ responseCode: '0', jwsPurchaseOrder: jwt() });
  }, () => now);
  const result = await client.query(reference);
  assert.equal(result.needsFinish, true); assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://iap.cloud.huawei.com/order/harmony/v1/application/order/status/query');
  const auth = jwsParts(calls[0].request.headers.Authorization.substring(7));
  assert.equal(auth.payload.digest, createHash('sha256').update(calls[0].request.body).digest('hex'));
  await client.confirm(reference);
  assert.equal(calls[1].url, 'https://iap.cloud.huawei.com/order/harmony/v1/application/purchase/shipped/confirm');
});
test('signed notifications bind the environment and return a query reference instead of a grant', async () => {
  const client = new HuaweiIapClient(configuration, verifier(), undefined, () => now);
  const notification = { notificationRequestId: 'test-notification', notificationVersion: 'v3', notificationType: 'REVOKE', signedTime: now,
    notificationMetaData: { ...reference, applicationId: configuration.applicationId, packageName: configuration.packageName, environment: 'NORMAL', type: 1 } };
  assert.deepEqual(await client.notification(jwt(notification)), { id: 'test-notification', reference });
  await assert.rejects(() => client.notification(jwt({ ...notification, notificationMetaData: { ...notification.notificationMetaData, environment: 'SANDBOX' } })));
  await assert.rejects(() => client.notification(jwt({ ...notification, notificationVersion: 'v2' })));
  await assert.rejects(() => client.notification(jwt({ ...notification, notificationMetaData: { ...notification.notificationMetaData, packageName: 'other.app' } })));
  assert.deepEqual(await client.notification(jwt({ ...notification, notificationType: 'TEST', notificationMetaData: {
    applicationId: configuration.applicationId, packageName: configuration.packageName, environment: 'NORMAL' } })),
  { id: 'test-notification', reference: null });
});

test('exact observed Huawei CDPs use fixed HTTPS targets with unchanged full CRL verification', async () => {
  for (const [name, target] of [['cdnLeaf', actualLeafCdp.replace('http:', 'https:')],
    ['rootCdpLeaf','https://h5hosting.dbankcdn.com/cch5/crl/pki_CRL_root_g2_crl/root_g2_crl.crl'],
    ['legacyRootCdpLeaf','https://h5hosting.dbankcdn.com/cch5/crl/pki_CRL_root_g2_crl/root_g2_crl.crl']]) {
    const calls=[];
    const source=new HuaweiIapCrlSource(async (url, options) => {
      calls.push(url); assert.equal(options.redirect,'error');
      return new Response(crlDer.get(url===target ? 'intermediate' : 'root'));
    });
    assert.deepEqual(await verifier({crls:undefined,crlSource:source}).verify(jwt(order,name)),order);
    assert.ok(calls.includes(target)); assert.equal(calls.length,2);
    await verifier({crls:undefined,crlSource:source}).verify(jwt(order,name)); assert.equal(calls.length,2);
  }
  const f=liveCrlFixture();
  for(const name of ['cdnOtherPath','cdnQuery','cdnPort','rootQuery']) {
    await assert.rejects(()=>f.verifier.verify(jwt(order,name)), error=>
      error.message==='iap_verification_failed' && error.cause.reason==='iap_crl_distribution_unsupported');
  }
  assert.equal(f.calls.length,0);
});

test('CRL transport failures expose only bounded download index and failure kind', async () => {
  for(const [fetcher,expected] of [
    [async()=>{throw new DOMException('private endpoint','TimeoutError');},{index:0,kind:'timeout'}],
    [async()=>new Response(null,{status:403}),{index:0,kind:'http',status:403}],
    [async()=>{throw new TypeError('private receipt',{cause:{code:'ENOTFOUND',token:'secret'}});},{index:0,kind:'dns'}]
  ]) {
    const f=liveCrlFixture(fetcher);
    await assert.rejects(()=>f.verifier.verify(jwt()),error=>{
      assert.equal(error.message,'iap_verification_failed');
      assert.deepEqual(error.cause.downloadFailure,{...expected,url:'http://pki.consumer.huawei.com/ca/crl/intermediate.crl'});
      assert.equal(JSON.stringify(error.cause).includes('private'),false);return true;
    });
  }
});
