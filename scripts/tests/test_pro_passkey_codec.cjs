'use strict';
// Phone passkey prototype: pure WebAuthn helpers (services/pro/passkey/ProPasskeyCodec.ets).
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const crypto = require('node:crypto');
const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const file = path.resolve(__dirname, '../../entry/src/main/ets/services/pro/passkey/ProPasskeyCodec.ets');
const loaded = { exports: {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, { module: loaded, exports: loaded.exports, Uint8Array, JSON, Number, Array, Error, Math }, { filename: file });
const c = loaded.exports;
// Objects built inside the vm realm have another Object prototype; compare their JSON content.
const plain = value => JSON.parse(JSON.stringify(value));

// base64url round trips and strictness
for (let n = 0; n < 70; n++) {
  const bytes = new Uint8Array(crypto.randomBytes(n));
  const text = c.base64UrlEncode(bytes);
  assert.equal(text, Buffer.from(bytes).toString('base64url'));
  assert.deepEqual(Array.from(c.base64UrlDecode(text)), Array.from(bytes));
}
assert.equal(c.base64UrlDecode('abc='), null);
assert.equal(c.base64UrlDecode('a+b/'), null);
assert.equal(c.base64UrlDecode('abcde'), null);

// COSE key and SPKI extraction against node's own P-256 export
const { publicKey, privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
const spki = new Uint8Array(publicKey.export({ type: 'spki', format: 'der' }));
const point = c.p256PointFromSpki(spki);
const jwk = publicKey.export({ format: 'jwk' });
assert.deepEqual(Buffer.from(point[0]).toString('base64url'), jwk.x);
assert.deepEqual(Buffer.from(point[1]).toString('base64url'), jwk.y);
assert.equal(c.p256PointFromSpki(spki.slice(1)), null);
const tampered = spki.slice(); tampered[10] ^= 1;
assert.equal(c.p256PointFromSpki(tampered), null);
const cose = c.coseEc2PublicKey(point[0], point[1]);
assert.equal(cose.length, 77);
assert.equal(Buffer.from(cose.slice(0, 10)).toString('hex'), 'a5010203262001215820');
assert.throws(() => c.coseEc2PublicKey(new Uint8Array(31), point[1]), /PASSKEY_KEY_INVALID/);

// authenticator data layout and a signature a WebAuthn relying party would verify
const rpIdHash = new Uint8Array(crypto.createHash('sha256').update('example.com').digest());
const credentialId = new Uint8Array(crypto.randomBytes(16));
const attested = c.authenticatorData(rpIdHash, c.PASSKEY_FLAG_UP | c.PASSKEY_FLAG_UV | c.PASSKEY_FLAG_AT, 0,
  credentialId, cose);
assert.equal(attested.length, 37 + 16 + 2 + 16 + 77);
assert.equal(attested[32], 0x45);
assert.deepEqual(Array.from(attested.slice(53, 55)), [0, 16]);
const [parsedId, parsedKey] = c.attestedCredential(attested);
assert.deepEqual(Array.from(parsedId), Array.from(credentialId));
assert.deepEqual(Array.from(parsedKey), Array.from(cose));
assert.equal(c.attestedCredential(attested.slice(0, 37)), null);
const assertion = c.authenticatorData(rpIdHash, c.PASSKEY_FLAG_UP | c.PASSKEY_FLAG_UV, 0x01020304, null, null);
assert.equal(assertion.length, 37);
assert.deepEqual(Array.from(assertion.slice(32)), [5, 1, 2, 3, 4]);
const clientDataHash = new Uint8Array(crypto.randomBytes(32));
const signature = crypto.sign('sha256', Buffer.from(c.concatBytes([assertion, clientDataHash])), privateKey);
assert.ok(crypto.verify('sha256', Buffer.concat([Buffer.from(assertion), Buffer.from(clientDataHash)]), publicKey, signature));
assert.throws(() => c.authenticatorData(new Uint8Array(31), 0, 0, null, null), /PASSKEY_AUTHDATA_INVALID/);
assert.throws(() => c.authenticatorData(rpIdHash, 0, -1, null, null), /PASSKEY_AUTHDATA_INVALID/);

// requests
const b64 = n => Buffer.from(crypto.randomBytes(n)).toString('base64url');
const register = { v: 1, id: b64(16), op: 'register', rpId: 'github.com', clientDataHash: b64(32),
  user: { id: b64(32), name: 'octocat', displayName: 'The Octocat' }, credentialIds: [b64(16)], from: 'MatePad', sentAt: 1800000000000, ttlMs: 60000 };
assert.deepEqual(plain(c.parsePasskeyRequest(JSON.stringify(register))), register);
const signin = { v: 1, id: b64(16), op: 'signin', rpId: 'login.example.co.uk', clientDataHash: b64(32), user: null,
  credentialIds: [], from: 'MateBook', sentAt: 1800000000000, ttlMs: 120000 };
assert.deepEqual(plain(c.parsePasskeyRequest(JSON.stringify(signin))), signin);
const bad = [
  { ...register, v: 2 }, { ...register, id: b64(15) }, { ...register, op: 'delete' }, { ...register, rpId: 'GitHub.com' },
  { ...register, rpId: 'a..b' }, { ...register, rpId: 'evil.com\u0000.good.com' }, { ...register, rpId: 'x'.repeat(254) },
  { ...register, clientDataHash: b64(31) }, { ...register, ttlMs: 999 }, { ...register, ttlMs: 120001 },
  { ...register, ttlMs: 1.5 }, { ...register, from: 'x'.repeat(41) }, { ...register, user: null },
  { ...register, user: { ...register.user, name: 'a\nb' } }, { ...register, user: { ...register.user, id: b64(65) } },
  { ...register, credentialIds: new Array(17).fill(b64(16)) }, { ...register, credentialIds: ['***'] },
  { ...signin, user: register.user }, { ...register, sentAt: 0 }, { ...register, sentAt: 1.5 }, { ...register, sentAt: '1' }
];
for (const item of bad) assert.equal(c.parsePasskeyRequest(JSON.stringify(item)), null, JSON.stringify(item).slice(0, 80));
assert.equal(c.parsePasskeyRequest('[]'), null);
assert.equal(c.parsePasskeyRequest('not json'), null);
assert.equal(c.parsePasskeyRequest('x'.repeat(8193)), null);
assert.ok(c.passkeyRequestCurrent(register, register.sentAt + 119000));
assert.ok(c.passkeyRequestCurrent(register, register.sentAt - 60000));
assert.ok(!c.passkeyRequestCurrent(register, register.sentAt + 121000));
assert.ok(c.validRpId('localhost'));
assert.ok(!c.validRpId('-bad.com'));

// responses
const response = { v: 1, id: register.id, ok: true, error: '', credentialId: b64(16), authData: Buffer.from(attested).toString('base64url'),
  signature: '', userHandle: '', publicKey: Buffer.from(spki).toString('base64url') };
assert.deepEqual(plain(c.parsePasskeyResponse(JSON.stringify(response), register.id)), response);
assert.equal(c.parsePasskeyResponse(JSON.stringify(response), signin.id), null);
assert.deepEqual(plain(c.parsePasskeyResponse(JSON.stringify({ v: 1, id: register.id, ok: false, error: 'USER_DENIED' }), register.id)),
  { v: 1, id: register.id, ok: false, error: 'USER_DENIED', credentialId: '', authData: '', signature: '', userHandle: '', publicKey: '' });
assert.equal(c.parsePasskeyResponse(JSON.stringify({ ...response, authData: b64(36) }), register.id), null);
assert.equal(c.parsePasskeyResponse(JSON.stringify({ ...response, signature: b64(73) }), register.id), null);
assert.equal(c.parsePasskeyResponse(JSON.stringify({ ...response, publicKey: b64(90) }), register.id), null);

console.log('PASS phone passkey codec: base64url, COSE/SPKI, authenticator data and signatures, request/response validation');
