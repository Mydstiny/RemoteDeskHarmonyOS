/* Host-side tests for data management safety: portable local backups
 * (export/self-check symmetry, redacted-field fidelity, restore plans), cloud
 * sync protection wording, master password rules and app-clone clipboard
 * isolation. The listed ArkTS hypium suites run here unchanged; the cases
 * below cover cross-module contracts that need several services at once.
 * DATA_SAFETY_TYPESCRIPT_PATH selects the installed compiler; Hvigor
 * validates ArkTS separately. */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const nodeCrypto = require('node:crypto');
const assert = require('node:assert/strict');
const ts = require(process.env.DATA_SAFETY_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const cache = new Map();
const tests = [];
const hypium = { describe: (_name, body) => body(), it: (name, _level, body) => tests.push({ name, body }),
  expect: (value) => ({ assertEqual: expected => assert.equal(value, expected),
    assertTrue: () => assert.equal(value, true), assertFalse: () => assert.equal(value, false),
    assertDeepEquals: expected => assert.deepEqual(value, expected) }) };
const hilog = { info: () => {}, warn: () => {}, error: () => {}, debug: () => {} };
const cryptoFramework = {
  createMd: () => {
    const hash = nodeCrypto.createHash('sha256');
    return { updateSync: blob => { hash.update(Buffer.from(blob.data)); },
      digestSync: () => ({ data: new Uint8Array(hash.digest()) }) };
  }
};
function load(file) {
  file = path.resolve(root, file);
  if (cache.has(file)) return cache.get(file).exports;
  const module = { exports: {} }; cache.set(file, module);
  const source = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const requireEts = id => {
    if (id === '@ohos/hypium') return hypium;
    if (id === '@kit.ArkTS') return { util: { TextEncoder, TextDecoder } };
    if (id === '@kit.PerformanceAnalysisKit') return { hilog };
    if (id === '@kit.CryptoArchitectureKit') return { cryptoFramework };
    if (id === '@kit.ArkData') return { relationalStore: {}, preferences: {} };
    if (id === '@kit.BasicServicesKit') return { deviceInfo: { deviceType: 'phone' } };
    if (id === '@kit.CoreFileKit' || id === '@kit.AbilityKit' || id === '@kit.ArkUI') return {};
    if (!id.startsWith('.')) throw new Error('Unexpected import ' + id + ' from ' + file);
    const resolved = path.resolve(path.dirname(file), id + '.ets');
    if (!fs.existsSync(resolved) && fs.existsSync(path.resolve(path.dirname(file), id + '.d.ts'))) return {};
    return load(resolved);
  };
  const sandbox = { module, exports: module.exports, require: requireEts, Date, Uint8Array,
    ArrayBuffer, TextEncoder, TextDecoder, setTimeout, clearTimeout, console,
    AppStorage: { get: () => undefined, setOrCreate: () => {}, set: () => {} } };
  vm.runInNewContext(source, sandbox, { filename: file });
  return module.exports;
}

load('entry/src/test/LocalBackupPolicy.test.ets').default();
load('entry/src/test/CloudSyncSheetPolicy.test.ets').default();
load('entry/src/test/MasterPasswordPolicy.test.ets').default();
load('entry/src/test/AppCloneContext.test.ets').default();
load('entry/src/test/BackupCryptoContractPolicy.test.ets').default();
load('entry/src/test/RemoteHostDeviceTrustRestorePolicy.test.ets').default();

const svc = 'entry/src/main/ets/services/';
const backup = load(svc + 'LocalBackupPolicy.ets');
const adapter = load(svc + 'CloudTableAdapter.ets');
const { vncPayloadHashSha256 } = load(svc + 'VncRecordPolicy.ets');
function test(name, body) { tests.push({ name, body }); }

const owner = 'device-local:owner-a';
function tables(extra) {
  return Object.assign({ usersettings: [], remotehosts: [], rdpcredentials: [], rustdeskrelays: [],
    sshkeys: [], totpentries: [], cryptoparams: [], vncrecordv2: [] }, extra || {});
}
function hostRow(id, extra) {
  return Object.assign({ id, userid: owner, label: 'h', protocol: 'ssh', host: '203.0.113.' + id.length,
    port: '22', username: 'u', password: '', passward: '', customhostname: '', displayconfig: '{}',
    locked: '0', locktype: '0', isfavorite: '0', sortorder: '0', createdat: '1', updatedat: '1' }, extra || {});
}
function vncRow(id, recordType, deletedAt) {
  const payload = recordType === 'host' ? '{"host":"203.0.113.9","label":"v","port":5900}' : '{}';
  return { id, userid: owner, recordtype: recordType, ownerid: owner, ownertype: 'account', secretkind: '',
    payload, ciphertext: '', envelopeversion: '0', cryptoversion: '0', keyversion: '0', aadversion: '0',
    payloadhashsha256: vncPayloadHashSha256(payload), syncversion: '1', schemaversion: '1',
    resetepoch: '1', createdat: '1', updatedat: '2', deletedat: String(deletedAt) };
}
function roundTrip(document) {
  return backup.validateLocalBackupDocument(JSON.stringify(document));
}

test('full backup excludes VNC tombstones and passes its own validation', () => {
  const source = tables({ vncrecordv2: [vncRow('vnc-live', 'host', 0), vncRow('vnc-deleted', 'host', 9),
    vncRow('vnc-secret-deleted', 'secret', 9)] });
  const local = { vnclocalrecords: [Object.assign(vncRow('vnc-local-deleted', 'host', 9), { localonly: '1' })] };
  const document = backup.createLocalBackupDocument(source, 100, '1.2.0', [], local, owner, 3, false, 'full');
  assert.deepEqual(Array.from(document.tables.vncrecordv2, row => row.id), ['vnc-live']);
  assert.equal(document.localTables.vnclocalrecords.length, 0);
  assert.notEqual(roundTrip(document), null);
});

test('self-check reports the failing stage instead of a generic error', () => {
  const document = backup.createLocalBackupDocument(tables(), 100, '1.2.0', [], {}, owner, 3, false, 'full');
  const valid = backup.validateLocalBackupDocumentDetailed(JSON.stringify(document));
  assert.notEqual(valid.document, null);
  assert.equal(valid.stage, '');
  document.sha256 = '0'.repeat(64);
  assert.equal(backup.validateLocalBackupDocumentDetailed(JSON.stringify(document)).stage, 'hash');
  assert.equal(backup.validateLocalBackupDocumentDetailed('not json').stage, 'json');
  const newer = JSON.parse(JSON.stringify(document));
  newer.version = 4;
  assert.equal(backup.validateLocalBackupDocumentDetailed(JSON.stringify(newer)).stage, 'unsupported_version');
  assert.equal(backup.validateLocalBackupDocument(JSON.stringify(newer)), null);
});

test('redacted backup keeps every non-secret cloud extension value', () => {
  const extension = {};
  for (const key of adapter.remoteHostCloudExtensionColumns()) { extension[key] = 'value-' + key; }
  extension.lanaddressmode = 'static';
  extension.lanlastresolvedat = '1700000000000';
  extension.rustdeskdirectport = '21118';
  // The only Restricted Admin source is the NTLM hash; the default is not carried.
  extension.rdprestrictedadminsecretsource = 'ntlm_hash';
  const projected = adapter.projectRemoteHostCloudExtension(extension);
  const row = hostRow('h1', { protocol: 'rdp',
    displayconfig: adapter.encodeRemoteHostDisplayPayload('{"width":1920}', projected) });
  const document = backup.createLocalBackupDocument(tables({ remotehosts: [row] }), 100, '1.2.0', [], {}, owner, 3,
    false, 'redacted');
  const kept = adapter.decodeRemoteHostDisplayPayload(document.tables.remotehosts[0].displayconfig).extension;
  for (const key of Object.keys(projected)) {
    if (key === 'rdprestrictedadminsecretsource') { continue; }
    assert.equal(kept[key], projected[key], 'redacted backup dropped ' + key);
  }
  assert.equal(kept.rdprestrictedadminsecretsource, undefined);
  assert.notEqual(roundTrip(document), null);
});

test('redacted backup omits default LAN values so older apps can still import it', () => {
  const projected = adapter.projectRemoteHostCloudExtension({ sshkeyid: 'k1', lanaddressmode: 'manual',
    landiscoveryidentity: '', lanlastresolvedat: '0', rdprestrictedadminsecretsource: 'ntlm_hash' });
  const row = hostRow('h1', { displayconfig: adapter.encodeRemoteHostDisplayPayload('{}', projected) });
  const document = backup.createLocalBackupDocument(tables({ remotehosts: [row] }), 100, '1.2.0', [], {}, owner, 3,
    false, 'redacted');
  const kept = adapter.decodeRemoteHostDisplayPayload(document.tables.remotehosts[0].displayconfig).extension;
  assert.deepEqual(Object.keys(kept), ['sshkeyid']);
  assert.notEqual(roundTrip(document), null);
});

test('redacted backup ignores inherited object names in the cloud extension', () => {
  const row = hostRow('h1', { displayconfig: JSON.stringify({ width: 1280,
    _remoteDeskExtensionV1: { sshkeyid: 'k1', constructor: 'x', toString: 'y' } }) });
  const document = backup.createLocalBackupDocument(tables({ remotehosts: [row] }), 100, '1.2.0', [], {}, owner, 3,
    false, 'redacted');
  const display = JSON.parse(document.tables.remotehosts[0].displayconfig);
  assert.equal(display.width, 1280);
  assert.equal(display._remoteDeskExtensionV1.sshkeyid, 'k1');
  assert.notEqual(roundTrip(document), null);
});

test('only encrypted VNC secret envelopes count as ciphertext', () => {
  const manifest = load(svc + 'BackupManifestV3.ets');
  const plainSecret = Object.assign(vncRow('vnc-plain', 'secret', 0), {
    payload: '{"storageMode":"plain_explicit_v1"}', ciphertext: 'plain:v1:aGVsbG8=' });
  const encryptedSecret = Object.assign(vncRow('vnc-encrypted', 'secret', 0), {
    payload: '{"storageMode":"encrypted_v3"}', ciphertext: '3:n:c:t' });
  const empty = { tables: {}, extensions: [], localTables: {} };
  assert.equal(manifest.portableDataCarriesCiphertext(Object.assign({}, empty, { tables: { vncrecordv2: [plainSecret] } })), false);
  assert.equal(manifest.portableDataCarriesCiphertext(Object.assign({}, empty, { tables: { vncrecordv2: [encryptedSecret] } })), true);
  assert.equal(manifest.portableDataCarriesCiphertext(Object.assign({}, empty, { localTables: { vnclocalrecords: [encryptedSecret] } })), true);
  const relay = { id: 'r1', userid: owner, accountsjson: '[{"username":"a","password":"3:n:c:t"}]' };
  assert.equal(manifest.portableDataCarriesCiphertext(Object.assign({}, empty, { tables: { rustdeskrelays: [relay] } })), true);
  const extension = { id: 'remotehosts:h1', tablename: 'remotehosts', recordid: 'h1', payload: '{"sshkeypassphrase":"1:iv:data"}' };
  assert.equal(manifest.portableDataCarriesCiphertext(Object.assign({}, empty, { extensions: [extension] })), true);
});

test('redacted plans pass the crypto planner unchanged', () => {
  const contract = load(svc + 'BackupCryptoContractPolicy.ets');
  const document = backup.createLocalBackupDocument(tables({ remotehosts: [hostRow('h1')] }), 100, '1.2.0', [], {}, owner,
    3, false, 'redacted');
  const plan = backup.adaptLocalBackupDocumentForRestore(document, owner, false);
  const resolved = backup.planForTargetCryptoContract(plan, contract.backupCryptoContract('salt', 'verifier'));
  assert.equal(resolved.plan, plan);
  assert.equal(resolved.decision, 'keep_target');
});

let failed = 0;
for (const entry of tests) {
  try {
    entry.body();
    console.log('PASS ' + entry.name);
  } catch (error) {
    failed++;
    console.log('FAIL ' + entry.name + '\n  ' + (error && error.stack ? error.stack.split('\n').slice(0, 4).join('\n  ') : error));
  }
}
console.log((tests.length - failed) + '/' + tests.length + ' passed');
process.exit(failed === 0 ? 0 : 1);
