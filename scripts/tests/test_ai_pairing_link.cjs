'use strict';
// Pairing contract with the RemoteDesk host plugins (Codex, DSH, Claude Code): their control panels show the raw
// invite JSON as a QR code and offer `remotedesk://pair?data=<base64url JSON>` as the link fallback. The QR carries the
// compact invite (CA SHA-256 instead of the CA) so it stays scannable; the full invite still pastes as before.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require(process.env.AI_TYPESCRIPT_PATH || 'typescript');
const base = path.resolve(__dirname, '../../entry/src/main/ets/services/ai') + '/';
const util = {
  Base64Helper: class { decodeSync(text) { return new Uint8Array(Buffer.from(text, 'base64')); } },
  TextDecoder: class { decodeToString(bytes) { return Buffer.from(bytes).toString('utf8'); } }
};
function load(name, mocks) {
  const module = { exports: {} };
  const source = ts.transpileModule(fs.readFileSync(base + name + '.ets', 'utf8'),
    { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInNewContext(source, { module, exports: module.exports, require: key => mocks[key] }, { filename: name });
  return module.exports;
}
const models = load('AiModels', { '../EndpointAddressPolicy': { parseEndpointHost: () => ({ ok: true }), parseEndpointServerIdentity: () => ({ ok: true }) } });
const { parseAiInvite } = load('AiWirePolicy', { './AiModels': models, '@kit.ArkTS': { util } });

const now = 1_800_000_000_000;
const invite = { code: 'Q2xhdWRlLWNvZGUtaW52aXRlLXRva2VuLTAxMjM0NTY3', expires: now + 120000,
  ca: '-----BEGIN CERTIFICATE-----\nMIIBfixture\n-----END CERTIFICATE-----\n', serverInstance: 'aW5zdGFuY2UtMDEyMzQ1Njc4OQ' };
const link = payload => 'remotedesk://pair?data=' + Buffer.from(JSON.stringify(payload), 'utf8').toString('base64url');
const accepted = {
  'raw invite JSON (QR)': JSON.stringify(invite),
  'pretty invite JSON': JSON.stringify(invite, null, 2),
  'Codex link with url': link({ type: 'remotedesk-pair', version: 1, engine: 'codex', url: 'https://192.168.31.142:9443', invite }),
  'DSH link without url': link({ type: 'remotedesk-pair', version: 1, engine: 'dsh', invite }),
  'Pi link with IPv6 url': link({ type: 'remotedesk-pair', version: 1, engine: 'pi', url: 'https://[fe80::1]:9445', invite }),
  'link with surrounding whitespace': '  ' + link({ type: 'remotedesk-pair', version: 1, engine: 'codex', invite }) + '\n'
};
for (const [name, text] of Object.entries(accepted)) {
  const parsed = parseAiInvite(text, now);
  assert.deepEqual({ ...parsed }, { ...invite, caSha256: '' }, name);
}
const compact = { caSha256: 'n4bQgYhMfWWaL-qgxVrQFaO_TxsrC4Is0V1sFbDwCgg', code: invite.code, expires: invite.expires,
  serverInstance: invite.serverInstance };
for (const [name, text] of Object.entries({ 'compact QR': JSON.stringify(compact),
  'compact link': link({ type: 'remotedesk-pair', version: 1, engine: 'dsh', invite: compact }) })) {
  assert.deepEqual({ ...parseAiInvite(text, now) }, { ...compact, ca: '' }, name);
}
assert.ok(JSON.stringify(compact).length < 200, 'the compact QR payload stays small');
const rejected = {
  'extra invite field': JSON.stringify({ ...invite, role: 'operator' }),
  'missing invite field': JSON.stringify({ code: invite.code, expires: invite.expires, ca: invite.ca }),
  expired: JSON.stringify({ ...invite, expires: now }),
  'missing certificate': JSON.stringify({ ...invite, ca: 'not a certificate' }),
  'invalid code': JSON.stringify({ ...invite, code: 'has spaces' }),
  'wrong link type': link({ type: 'other', version: 1, invite }),
  'future link version': link({ type: 'remotedesk-pair', version: 2, invite }),
  'link without invite': link({ type: 'remotedesk-pair', version: 1 }),
  'padded base64 link': 'remotedesk://pair?data=' + Buffer.from(JSON.stringify({ type: 'remotedesk-pair', version: 1, invite })).toString('base64'),
  'non-base64 link': 'remotedesk://pair?data=@@@',
  'other scheme': link({ type: 'remotedesk-pair', version: 1, invite }).replace('remotedesk://', 'https://'),
  'oversized text': 'x'.repeat(120001),
  'compact with CA too': JSON.stringify({ ...compact, ca: invite.ca }),
  'compact short fingerprint': JSON.stringify({ ...compact, caSha256: 'abc' }),
  'compact padded fingerprint': JSON.stringify({ ...compact, caSha256: compact.caSha256.slice(0, 42) + '=' }),
  'compact expired': JSON.stringify({ ...compact, expires: now })
};
for (const [name, text] of Object.entries(rejected)) {
  assert.throws(() => parseAiInvite(text, now), /AI_INVITE_/, name);
}
console.log('PASS ' + Object.keys(accepted).length + ' plugin pairing forms accepted, ' + Object.keys(rejected).length + ' malformed or stale invites rejected');
