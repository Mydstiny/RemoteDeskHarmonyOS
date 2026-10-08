'use strict';
// 手机通行密钥 in a remote session: CTAP2 MakeCredential/GetAssertion from MS-RDPEWA become phone passkey requests,
// and phone answers become CTAP responses (services/pro/passkey/ProPasskeyCtap.ets). The test has its own CBOR encoder
// and decoder so the module is checked against an independent implementation.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const crypto = require('node:crypto');
const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const dir = path.resolve(__dirname, '../../entry/src/main/ets/services/pro/passkey') + '/';
function load(name, mocks) {
  const module = { exports: {} };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(dir + name + '.ets', 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText, { module, exports: module.exports, require: id => mocks[id], Uint8Array, JSON, Number, Array, Error, Math, String },
  { filename: name });
  return module.exports;
}
const codec = load('ProPasskeyCodec', {});
const ctap = load('ProPasskeyCtap', { './ProPasskeyCodec': codec });
const plain = value => JSON.parse(JSON.stringify(value));
const b64 = bytes => Buffer.from(bytes).toString('base64url');

// --- independent CBOR (canonical) ---
function head(major, n) {
  if (n < 24) return [(major << 5) | n];
  if (n < 256) return [(major << 5) | 24, n];
  if (n < 65536) return [(major << 5) | 25, n >> 8, n & 255];
  return [(major << 5) | 26, (n >>> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255];
}
function enc(value) {
  if (typeof value === 'number') return value >= 0 ? head(0, value) : head(1, -1 - value);
  if (typeof value === 'boolean') return [value ? 0xf5 : 0xf4];
  if (typeof value === 'string') { const b = [...Buffer.from(value, 'utf8')]; return head(3, b.length).concat(b); }
  if (value instanceof Uint8Array || Buffer.isBuffer(value)) return head(2, value.length).concat([...value]);
  if (Array.isArray(value)) return head(4, value.length).concat(...value.map(enc));
  if (value instanceof Map) {
    const entries = [...value.entries()].map(([k, v]) => [enc(k), enc(v)]);
    entries.sort((a, b) => a[0].length - b[0].length || Buffer.compare(Buffer.from(a[0]), Buffer.from(b[0])));
    return head(5, entries.length).concat(...entries.map(([k, v]) => k.concat(v)));
  }
  throw new Error('unsupported');
}
function dec(bytes) {
  let i = 0;
  const arg = info => {
    if (info < 24) return info;
    const size = { 24: 1, 25: 2, 26: 4 }[info]; let n = 0;
    for (let k = 0; k < size; k++) n = n * 256 + bytes[i++];
    return n;
  };
  const read = () => {
    const h = bytes[i++], major = h >> 5, info = h & 31;
    if (major === 7) return info === 21 ? true : info === 20 ? false : null;
    const n = arg(info);
    if (major === 0) return n;
    if (major === 1) return -1 - n;
    if (major === 2) { const v = Buffer.from(bytes.slice(i, i + n)); i += n; return v; }
    if (major === 3) { const v = Buffer.from(bytes.slice(i, i + n)).toString('utf8'); i += n; return v; }
    if (major === 4) { const a = []; for (let k = 0; k < n; k++) a.push(read()); return a; }
    const m = new Map(); for (let k = 0; k < n; k++) { const key = read(); m.set(key, read()); } return m;
  };
  const value = read();
  assert.equal(i, bytes.length, 'trailing bytes');
  return value;
}
const command = (code, map) => new Uint8Array([code].concat(enc(map)));

// --- MakeCredential ---
const hash = crypto.randomBytes(32), userId = crypto.randomBytes(16), mine = crypto.randomBytes(16);
const makeCredential = new Map([
  [1, hash], [2, new Map([['id', 'github.com'], ['name', 'GitHub']])],
  [3, new Map([['id', userId], ['name', 'octocat\n'], ['displayName', 'The Octocat']])],
  [4, [new Map([['alg', -257], ['type', 'public-key']]), new Map([['alg', -7], ['type', 'public-key']])]],
  [5, [new Map([['id', mine], ['type', 'public-key']]), new Map([['id', crypto.randomBytes(64)], ['type', 'public-key']])]],
  [7, new Map([['rk', true]])]]);
let parsed = ctap.parseCtapCommand(command(1, makeCredential));
assert.equal(parsed.status, 0);
assert.equal(parsed.op, 'register');
assert.equal(parsed.rpId, 'github.com');
assert.equal(b64(parsed.clientDataHash), b64(hash));
assert.deepEqual([b64(parsed.user.id), parsed.user.name, parsed.user.displayName], [b64(userId), 'octocat', 'The Octocat']);
assert.deepEqual(Array.from(parsed.credentialIds, b64), [b64(mine)]);
const request = plain(ctap.passkeyRequestFromCtap(parsed, new Uint8Array(16).fill(7), 'MateBook', 1800000000000, 500000));
assert.equal(request.ttlMs, 120000);
assert.deepEqual({ ...request, device: 'x'.repeat(22), sig: 'y'.repeat(94) }, {
  v: 2, id: b64(new Uint8Array(16).fill(7)), op: 'register', rpId: 'github.com', clientDataHash: b64(hash),
  user: { id: b64(userId), name: 'octocat', displayName: 'The Octocat' }, credentialIds: [b64(mine)], from: 'MateBook',
  sentAt: 1800000000000, ttlMs: 120000, device: 'x'.repeat(22), devicePub: '', sig: 'y'.repeat(94) });
// Once signed (device + signature filled in), the phone-side parser accepts exactly this request.
assert.ok(codec.parsePasskeyRequest(JSON.stringify({ ...request, device: b64(crypto.randomBytes(16)), sig: b64(crypto.randomBytes(70)) })));
assert.equal(plain(ctap.passkeyRequestFromCtap(parsed, new Uint8Array(16), 'x', 1, 10)).ttlMs, 1000);
// ES256 is required; RS256-only servers are refused with the CTAP status for it.
const rsOnly = new Map(makeCredential); rsOnly.set(4, [new Map([['alg', -257], ['type', 'public-key']])]);
assert.equal(ctap.parseCtapCommand(command(1, rsOnly)).status, ctap.CTAP2_ERR_UNSUPPORTED_ALGORITHM);
for (const [key, status] of [[1, 0x14], [2, 0x14], [3, 0x14], [4, 0x14]]) {
  const missing = new Map(makeCredential); missing.delete(key);
  assert.equal(ctap.parseCtapCommand(command(1, missing)).status, status, 'missing ' + key);
}
const badHash = new Map(makeCredential); badHash.set(1, crypto.randomBytes(31));
assert.equal(ctap.parseCtapCommand(command(1, badHash)).status, ctap.CTAP1_ERR_INVALID_PARAMETER);
const badRp = new Map(makeCredential); badRp.set(2, new Map([['id', 'evil..com']]));
assert.equal(ctap.parseCtapCommand(command(1, badRp)).status, ctap.CTAP1_ERR_INVALID_PARAMETER);
const longUser = new Map(makeCredential); longUser.set(3, new Map([['id', crypto.randomBytes(65)]]));
assert.equal(ctap.parseCtapCommand(command(1, longUser)).status, ctap.CTAP1_ERR_INVALID_PARAMETER);
// The relying party is taken exactly as sent: upper case, or a character that lower-cases into ASCII, is refused.
for (const id of ['GitHub.com', '\u212Aey.com', 'xn--80ak6aa92e.com.']) {
  const other = new Map(makeCredential); other.set(2, new Map([['id', id]]));
  assert.equal(ctap.parseCtapCommand(command(1, other)).status, ctap.CTAP1_ERR_INVALID_PARAMETER, id);
}
// Names shown on the phone lose invisible and reordering characters.
const spoof = new Map(makeCredential);
spoof.set(3, new Map([['id', userId], ['name', 'a\u202Egnp.exe\u2028配对码 000 000'], ['displayName', 'x\u200By']]));
parsed = ctap.parseCtapCommand(command(1, spoof));
assert.deepEqual([parsed.user.name, parsed.user.displayName], ['agnp.exe配对码 000 000', 'xy']);
// Up to 64 of the phone's credential IDs fit in a list; a longer exclude list is refused rather than cut short.
const many = n => Array.from({ length: n }, () => new Map([['id', crypto.randomBytes(16)], ['type', 'public-key']]));
const sixtyFour = new Map(makeCredential); sixtyFour.set(5, many(64));
assert.equal(ctap.parseCtapCommand(command(1, sixtyFour)).credentialIds.length, 64);
const tooMany = new Map(makeCredential); tooMany.set(5, many(65));
assert.equal(ctap.parseCtapCommand(command(1, tooMany)).status, ctap.CTAP2_ERR_LIMIT_EXCEEDED);
console.log('PASS MakeCredential becomes a phone registration request; unsupported or malformed ones are refused');

// --- GetAssertion ---
const getAssertion = new Map([[1, 'login.example.co.uk'], [2, hash], [3, [new Map([['id', mine], ['type', 'public-key']])]],
  [5, new Map([['up', true]])]]);
parsed = ctap.parseCtapCommand(command(2, getAssertion));
assert.deepEqual([parsed.status, parsed.op, parsed.rpId, parsed.foreignAllowList], [0, 'signin', 'login.example.co.uk', false]);
assert.deepEqual(Array.from(parsed.credentialIds, b64), [b64(mine)]);
const foreign = new Map(getAssertion); foreign.set(3, [new Map([['id', crypto.randomBytes(48)], ['type', 'public-key']])]);
assert.equal(ctap.parseCtapCommand(command(2, foreign)).foreignAllowList, true);
const discoverable = new Map(getAssertion); discoverable.delete(3);
parsed = ctap.parseCtapCommand(command(2, discoverable));
assert.deepEqual([parsed.status, parsed.credentialIds.length, parsed.foreignAllowList], [0, 0, false]);
const longAllow = new Map(getAssertion); longAllow.set(3, many(65));
assert.equal(ctap.parseCtapCommand(command(2, longAllow)).status, ctap.CTAP2_ERR_LIMIT_EXCEEDED);
console.log('PASS GetAssertion keeps only credentials the phone could have issued');

// --- malformed input never throws ---
for (const bytes of [[], [1], [3, 0xa0], [1, 0xff], [1, 0x5f], [2, 0xa1, 0x01], [1, 0xa0, 0x00], [1, 0x80],
  [1, 0xbb, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff], [2, 0xa1, 0x01, 0x63, 0xff, 0xfe, 0xfd]]) {
  const status = ctap.parseCtapCommand(new Uint8Array(bytes)).status;
  assert.ok(status !== 0, 'refused ' + JSON.stringify(bytes));
}
let nested = [0];
for (let k = 0; k < 20; k++) nested = [0x81].concat(nested);
assert.equal(ctap.parseCtapCommand(new Uint8Array([1].concat(nested))).status, ctap.CTAP2_ERR_INVALID_CBOR);
// Only what a canonical encoder writes: anything that two readers could read differently is refused.
const getBytes = enc(getAssertion);
const invalid = bytes => ctap.parseCtapCommand(new Uint8Array([2].concat(bytes))).status;
// A repeated key (first-wins here, last-wins in libcbor): {1: "github.com", 1: "webauthn.io", 2: hash}.
assert.equal(invalid([0xa3].concat(enc(1), enc('github.com'), enc(1), enc('webauthn.io'), enc(2), enc(hash))),
  ctap.CTAP2_ERR_INVALID_CBOR);
// A repeated key inside a nested map (the rp map of MakeCredential).
const dupRp = enc(makeCredential);
const rpWithDup = [0xa2].concat(enc('id'), enc('github.com'), enc('id'), enc('webauthn.io'));
assert.equal(ctap.parseCtapCommand(new Uint8Array([1].concat([0xa6], enc(1), enc(hash), enc(2), rpWithDup,
  enc(3), enc(makeCredential.get(3)), enc(4), enc(makeCredential.get(4)), enc(5), enc(makeCredential.get(5)),
  enc(7), enc(makeCredential.get(7))))).status, ctap.CTAP2_ERR_INVALID_CBOR);
assert.ok(dupRp.length > 0);
// Overlong UTF-8 ("id" with its i in three bytes), a surrogate, a code point past U+10FFFF.
const overlongKey = [0x64, 0xe0, 0x81, 0xa9, 0x64];
assert.equal(ctap.parseCtapCommand(new Uint8Array([1, 0xa1, 0x02, 0xa1].concat(overlongKey, enc('github.com')))).status,
  ctap.CTAP2_ERR_INVALID_CBOR);
assert.equal(invalid([0xa2, 0x01, 0x63, 0xed, 0xa0, 0x80, 0x02].concat(enc(hash))), ctap.CTAP2_ERR_INVALID_CBOR);
assert.equal(invalid([0xa2, 0x01, 0x64, 0xf4, 0x90, 0x80, 0x80, 0x02].concat(enc(hash))), ctap.CTAP2_ERR_INVALID_CBOR);
// Long-form numbers and lengths: 5 as 0x18 0x05, a text length as two bytes.
assert.equal(invalid([0xa2, 0x18, 0x01].concat(enc('github.com'), enc(2), enc(hash))), ctap.CTAP2_ERR_INVALID_CBOR);
assert.equal(invalid([0xa2, 0x01, 0x79, 0x00, 0x0a].concat([...Buffer.from('github.com')], enc(2), enc(hash))),
  ctap.CTAP2_ERR_INVALID_CBOR);
// Lengths beyond what can be addressed, item counts past the limit, bytes after the item.
assert.equal(invalid([0xa1, 0x01, 0x7b, 0x00, 0x20, 0, 0, 0, 0, 0, 0]), ctap.CTAP2_ERR_INVALID_CBOR);
assert.equal(invalid([0x9a, 0x00, 0x00, 0x04, 0x4c].concat(new Array(1100).fill(0))), ctap.CTAP2_ERR_INVALID_CBOR);
assert.equal(invalid(getBytes.concat([0x00])), ctap.CTAP2_ERR_INVALID_CBOR);
assert.equal(invalid(getBytes), 0);
console.log('PASS malformed CBOR and commands are refused without throwing');

// --- responses ---
const authData = Buffer.concat([crypto.randomBytes(32), Buffer.from([0x05]), crypto.randomBytes(4)]);
const signature = crypto.randomBytes(71), credentialId = crypto.randomBytes(16);
const ok = { v: 2, id: 'x', ok: true, error: '', credentialId: b64(credentialId), authData: b64(authData),
  signature: b64(signature), userHandle: b64(userId), publicKey: '' };
let response = ctap.ctapResponseFromPasskey('signin', ok);
assert.equal(response[0], 0);
let body = dec(response.slice(1));
assert.deepEqual([...body.keys()], [1, 2, 3, 4]);
assert.deepEqual([...body.get(1).keys()], ['id', 'type']);
assert.equal(b64(body.get(1).get('id')), b64(credentialId));
assert.equal(body.get(1).get('type'), 'public-key');
assert.equal(b64(body.get(2)), b64(authData));
assert.equal(b64(body.get(3)), b64(signature));
assert.equal(b64(body.get(4).get('id')), b64(userId));
// Canonical bytes: identical to the independent encoder's output for the same map.
assert.deepEqual([...response.slice(1)], enc(new Map([[1, new Map([['id', credentialId], ['type', 'public-key']])],
  [2, authData], [3, signature], [4, new Map([['id', userId]])]])));
body = dec(ctap.ctapResponseFromPasskey('signin', { ...ok, userHandle: '' }).slice(1));
assert.deepEqual([...body.keys()], [1, 2, 3]);
// Registration: authenticator data with the attested credential (flags UP|UV|AT, zero AAGUID, the new ID, its key).
const attestedFor = id => Buffer.concat([crypto.randomBytes(32), Buffer.from([0x45, 0, 0, 0, 0]), Buffer.alloc(16),
  Buffer.from([0, id.length]), id, crypto.randomBytes(77)]);
const attested = attestedFor(credentialId);
response = ctap.ctapResponseFromPasskey('register', { ...ok, authData: b64(attested), signature: '' });
assert.deepEqual([...response], [0].concat(enc(new Map([[1, 'none'], [2, attested], [3, new Map()]]))));
// A success that does not attest the credential it names (or names none) is not passed on.
assert.deepEqual([...ctap.ctapResponseFromPasskey('register', { ...ok, authData: b64(attestedFor(crypto.randomBytes(16))),
  signature: '' })], [0x7f]);
assert.deepEqual([...ctap.ctapResponseFromPasskey('register', { ...ok, authData: b64(authData), signature: '' })], [0x7f]);
assert.deepEqual([...ctap.ctapResponseFromPasskey('register', { ...ok, credentialId: '', authData: '', signature: '',
  userHandle: '' })], [0x7f]);
// A sign-in's authenticator data carries no attested credential.
assert.deepEqual([...ctap.ctapResponseFromPasskey('signin', { ...ok, authData: b64(attested) })], [0x7f]);
assert.deepEqual([...ctap.ctapResponseFromPasskey('signin', null)], [ctap.CTAP2_ERR_USER_ACTION_TIMEOUT]);
for (const [error, status] of [['PASSKEY_USER_DENIED', 0x27], ['PASSKEY_DEVICE_NOT_PAIRED', 0x27], ['PASSKEY_NO_CREDENTIALS', 0x2e],
  ['PASSKEY_CREDENTIAL_EXCLUDED', 0x19], ['PASSKEY_KEY_MISSING', 0x2e], ['SOMETHING_ELSE', 0x7f]]) {
  assert.deepEqual([...ctap.ctapResponseFromPasskey('register', { ...ok, ok: false, error })], [status], error);
}
assert.deepEqual([...ctap.ctapResponseFromPasskey('signin', { ...ok, signature: '' })], [0x7f]);
assert.deepEqual([...ctap.ctapResponseFromPasskey('signin', { ...ok, authData: '***' })], [0x7f]);
console.log('PASS phone answers become canonical CTAP responses (attestation none) or CTAP status codes');
