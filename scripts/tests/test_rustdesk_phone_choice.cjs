// Production model, local persistence and actual target-click regressions.
// This proves source admission; UI/RDB device acceptance remains separate.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.RDP_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const cache = new Map();
function evaluate(source, bindings = {}) {
  const module = { exports: {} };
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021
  } }).outputText, { module, exports: module.exports, ...bindings });
  return module.exports;
}
function load(file) {
  file = path.resolve(root, file);
  if (cache.has(file)) return cache.get(file);
  const exposePrivateBackupValidator = file.endsWith('/LocalBackupPolicy.ets') ? '\nexport { validateLocalExtensions };' : '';
  const result = evaluate(fs.readFileSync(file, 'utf8') + exposePrivateBackupValidator, { require(id) {
    if (id === '@kit.CryptoArchitectureKit') return { cryptoFramework: { createMd() {
      const hash = require('node:crypto').createHash('sha256');
      return { updateSync(blob) { hash.update(blob.data); }, digestSync() { return {data: hash.digest()}; } };
    } } };
    if (id === '@kit.ArkTS') return { util: { TextEncoder, TextDecoder } };
    if (id === '@kit.PerformanceAnalysisKit') return { hilog: {error() {}, warn() {}, info() {}} };
    if (id.startsWith('.')) return load(path.resolve(path.dirname(file), id) + '.ets');
    throw new Error(id);
  } });
  cache.set(file, result); return result;
}
const { RemoteHost } = load('entry/src/main/ets/model/RemoteHost.ets');
const policy = load('entry/src/main/ets/services/RustDeskExplicitPhonePolicy.ets');
const local = load('entry/src/main/ets/services/HostLocalPersonalizationPolicy.ets');
const handoff = load('entry/src/main/ets/services/RustDeskHostAddHandoff.ets');
let count = 0;
function test(name, run) { run(); count++; console.log('PASS ' + name); }
function host(chosen = false) {
  const h = new RemoteHost(); h.id = 'phone'; h.userId = 'owner'; h.protocol = 'rustdesk';
  h.createdAt = 1; h.rustdeskTargetDevice = 'phone'; h.rustdeskPhoneChoiceVersion = chosen ? 1 : 0; return h;
}
function bodyAt(source, start) {
  let cursor = source.indexOf('{', start), depth = 1, end = cursor + 1;
  for (; depth; end++) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
    assert(end < source.length);
  }
  return source.slice(cursor, end);
}
function methodClass(file, names, bindings) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  const methods = names.map(name => {
    const start = source.search(new RegExp('  (?:private )?' + name + '\\('));
    assert(start >= 0, name);
    const open = source.indexOf('{', start);
    return source.slice(start, open) + bodyAt(source, start);
  }).join('\n');
  return evaluate('class Subject {\n' + methods + '\n}\nmodule.exports=Subject;', bindings);
}
test('production fromJSON never infers a choice from missing, empty or manual source', () => {
  for (const source of [undefined, '', 'manual', 'rustdesk_pro']) {
    const raw = host().toJSON(); raw.sourceType = source;
    raw.rustdeskPhoneChoiceVersion = 1; // Generic import cannot forge the local evidence field.
    const loaded = RemoteHost.fromJSON(raw);
    assert.equal(loaded.rustdeskPhoneChoiceVersion, 0);
    assert.equal(policy.hasExplicitRustDeskPhoneChoice(loaded), false);
  }
});
test('only explicit local marker restores after process-style JSON and extension reload', () => {
  const before = host(true);
  const portable = JSON.parse(JSON.stringify(before.toJSON()));
  assert(!Object.hasOwn(portable, 'rustdeskPhoneChoiceVersion'));
  const loaded = RemoteHost.fromJSON(portable);
  assert(!policy.hasExplicitRustDeskPhoneChoice(loaded));
  const disk = JSON.parse(JSON.stringify(local.remoteHostLocalPersonalizationValues(before)));
  local.applyRemoteHostLocalPersonalization(loaded, disk);
  assert(policy.hasExplicitRustDeskPhoneChoice(loaded));
  assert(policy.hasExplicitRustDeskPhoneChoice(loaded.runtimeClone()));
  assert.equal(local.remoteHostCloudBaseSnapshot(before), local.remoteHostCloudBaseSnapshot(host(false)));
});
test('saving an unknown old phone record does not manufacture evidence', () => {
  const before = host(false), values = local.remoteHostLocalPersonalizationValues(before);
  assert(!Object.hasOwn(values, 'localrustdeskphonechoice'));
  for (const marker of [undefined, '', '0', 'true', '2', 1, true]) {
    local.applyRemoteHostLocalPersonalization(before, {...values, localrustdeskphonechoice: marker});
    assert(!policy.hasExplicitRustDeskPhoneChoice(before));
  }
  for (const version of ['', '2', undefined]) {
    local.applyRemoteHostLocalPersonalization(before, {
      localpersonalizationversion: version, localrustdeskphonechoice: '1'});
    assert(!policy.hasExplicitRustDeskPhoneChoice(before));
  }
});
test('selecting computer clears persisted evidence and a later phone string cannot resurrect it', () => {
  const before = host(true); before.rustdeskTargetDevice = 'computer';
  const values = local.remoteHostLocalPersonalizationValues(before);
  assert(!Object.hasOwn(values, 'localrustdeskphonechoice'));
  before.rustdeskTargetDevice = 'phone';
  local.applyRemoteHostLocalPersonalization(before, values);
  assert(!policy.hasExplicitRustDeskPhoneChoice(before));
});
test('other protocols, inferred Pro platform, managed routes and import sources remain excluded', () => {
  const variants = [
    ...['rdp','ssh','vnc','moonlight',''].map(protocol => ({protocol})),
    {rustdeskTargetDevice:'computer'}, {sourceType:'rustdesk_pro'}, {sourceType:'import'},
    {rustdeskProManaged:true}, {rustdeskProPlatform:'Android'},
    {rustdeskProAccountId:'account'}, {rustdeskProPeerId:'peer'}];
  for (const variant of variants) {
    const selected = Object.assign(host(true), variant);
    assert(!policy.hasExplicitRustDeskPhoneChoice(selected));
    assert(!Object.hasOwn(local.remoteHostLocalPersonalizationValues(selected), 'localrustdeskphonechoice'));
    policy.restoreLocalRustDeskPhoneChoice(selected, '1');
    assert(!policy.hasExplicitRustDeskPhoneChoice(selected));
  }
});
test('actual classic click grants evidence; computer click revokes it', () => {
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/HostListPage.ets'), 'utf8');
  const box = {sheetRustdeskTargetDevice:'phone', sheetRustdeskPhoneChoiceVersion:0, sheetRustdeskAdaptiveOrientation:true};
  for (const label of ['控制手机','控制电脑']) {
    const start = source.indexOf('.onClick(', source.indexOf("Button('" + label + "')"));
    const callback = evaluate('module.exports=function()' + bodyAt(source, start));
    callback.call(box);
    assert.equal(box.sheetRustdeskPhoneChoiceVersion, label === '控制手机' ? 1 : 0);
  }
});
test('modern click and relay/TOTP draft handoff preserve only an actual phone choice', () => {
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/components/hostadd/RustDeskAddFlow.ets'), 'utf8');
  const start = source.indexOf('.onClick(', source.indexOf('@Builder private targetButton('));
  const click = evaluate('module.exports=function(target)' + bodyAt(source, start));
  const box = {targetDevice:'computer', phoneChoiceVersion:0}; click.call(box, 'phone');
  const draft = Object.assign(new handoff.RustDeskHostAddDraft(), box);
  const moved = handoff.cloneRustDeskHostAddDraft(draft);
  assert.equal(moved.phoneChoiceVersion, 1);
  click.call(box, 'computer'); assert.equal(box.phoneChoiceVersion, 0);
  draft.phoneChoiceVersion = undefined;
  assert.equal(handoff.cloneRustDeskHostAddDraft(draft).phoneChoiceVersion, 0);
});
test('dynamic local payload persists the choice outside portable JSON', () => {
  const Store = methodClass('entry/src/main/ets/services/CloudStore.ets',
    ['dynamicLanHostJSON', 'deviceLocalHostValues'], {
      ...policy, DataCrypto: {getInstance: () => ({})}, DYNAMIC_LAN_HOST_AAD_TABLE: 'local',
      remoteHostPersistentPasswordAllowed: () => true
    });
  const store = new Store(); store.currentOwnerScopeId = () => 'owner'; store.encryptIfReady = (_c,_t,_i,_f,v) => v;
  const selected = host(true), values = store.deviceLocalHostValues(selected);
  assert.equal(values.localrustdeskphonechoice, '1');
  const loaded = RemoteHost.fromJSON(JSON.parse(values.hostjson));
  assert(!policy.hasExplicitRustDeskPhoneChoice(loaded));
  policy.restoreLocalRustDeskPhoneChoice(loaded, values.localrustdeskphonechoice);
  assert(policy.hasExplicitRustDeskPhoneChoice(loaded));
  assert(!Object.hasOwn(store.deviceLocalHostValues(host()), 'localrustdeskphonechoice'));
});
test('full and redacted backups export without local choice, while local rollback preserves it', () => {
  const backup = load('entry/src/main/ets/services/LocalBackupPolicy.ets');
  const {CLOUD_SYNC_TABLES} = load('entry/src/main/ets/services/CloudSyncPolicy.ets');
  const tables = Object.fromEntries(CLOUD_SYNC_TABLES.map(name => [name, []]));
  tables.remotehosts.push({id: 'phone', userid: 'owner', protocol: 'rustdesk', host: '123456789'});
  const extensions = [{id: 'remotehosts:phone', tablename: 'remotehosts', recordid: 'phone',
    payload: JSON.stringify(local.remoteHostLocalPersonalizationValues(host(true))), updatedat: '1'}];
  const before = JSON.stringify(extensions);
  assert(backup.validateLocalBackupSnapshot(tables, extensions));
  assert(backup.validateCloudDownloadRollbackSnapshot(tables, extensions));
  assert(!backup.validateLocalExtensions(extensions, tables), 'portable validator must reject local evidence');
  for (const mode of ['full', 'redacted']) {
    const doc = backup.createLocalBackupDocument(tables, 100, 'test', extensions, {}, 'owner', 3, false, mode);
    assert(backup.validateLocalBackupDocument(JSON.stringify(doc)), mode + ' backup must remain usable');
    assert(!Object.hasOwn(JSON.parse(doc.extensions[0].payload), 'localrustdeskphonechoice'));
    const loaded = RemoteHost.fromJSON(host().toJSON());
    local.applyRemoteHostLocalPersonalization(loaded, JSON.parse(doc.extensions[0].payload));
    assert(!policy.hasExplicitRustDeskPhoneChoice(loaded));
    const payload = JSON.parse(doc.extensions[0].payload); payload.localrustdeskphonechoice = '1';
    doc.extensions[0].payload = JSON.stringify(payload);
    doc.sha256 = backup.localBackupSha256(backup.localBackupCanonicalPayload(
      doc.createdAt, doc.appVersion, doc.tables, doc.extensions, doc.version, doc.localTables, doc.manifest));
    assert.equal(backup.validateLocalBackupDocument(JSON.stringify(doc)), null);
  }
  assert.equal(JSON.stringify(extensions), before, 'export must not clear local intent');
  for (const value of ['', '0', '2', 1]) {
    const invalid = [{...extensions[0], payload: JSON.stringify({localrustdeskphonechoice: value})}];
    assert(!backup.validateLocalBackupSnapshot(tables, invalid));
    assert(!backup.validateCloudDownloadRollbackSnapshot(tables, invalid));
  }
});
console.log(count + ' phone choice checks passed');
