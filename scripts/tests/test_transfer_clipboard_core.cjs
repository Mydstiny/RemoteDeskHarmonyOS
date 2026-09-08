/* Executes production ETS clipboard services with a fake Harmony pasteboard.
 * TRANSFER_TYPESCRIPT_PATH=<DevEco typescript module> node scripts/tests/test_transfer_clipboard_core.cjs
 * Host race proofs are separate from Hvigor and real multi-window acceptance.
 */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TRANSFER_TYPESCRIPT_PATH || process.env.SSH_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const tests = [];
function test(name, run) { tests.push({ name, run }); }
async function drain() { for (let i = 0; i < 12; i++) await Promise.resolve(); }
function environment() {
  const cache = new Map(), listeners = new Set(), timers = new Map(), held = [];
  let count = 1, timer = 0, value = 'existing', tag = '', hasText = true, hasData = true;
  let writeFail = false, readFail = false, hold = false;
  const writes = [];
  function data(text, marker = '', textType = true) {
    let property = { tag: marker };
    return { getPrimaryText: () => text, getTag: () => property.tag, hasType: () => textType,
      getProperty: () => ({ ...property }), setProperty: p => { property = { ...p }; } };
  }
  const pb = {
    getChangeCount: () => count, hasDataSync: () => hasData,
    getDataSync() { if (readFail) throw { code: 201 }; return data(value, tag, hasText); },
    getData(callback) {
      const result = data(value, tag, hasText);
      const invoke = () => callback(readFail ? { code: 201 } : null, result);
      if (hold) held.push(invoke); else queueMicrotask(invoke);
    },
    setDataSync(pd) {
      if (writeFail) throw Error('synthetic write refusal');
      value = pd.getPrimaryText(); tag = pd.getTag(); hasData = true; hasText = true; count++;
      writes.push(value); for (const callback of listeners) callback();
    },
    on(_event, callback) { listeners.add(callback); }, off(_event, callback) { listeners.delete(callback); }
  };
  function load(file) {
    file = path.resolve(root, file);
    if (cache.has(file)) return cache.get(file).exports;
    const module = { exports: {} }; cache.set(file, module);
    const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
    }).outputText;
    function requireEts(id) {
      if (id === '@kit.BasicServicesKit') return { pasteboard: { getSystemPasteboard: () => pb,
        createData: (_type, text) => data(text), MIMETYPE_TEXT_PLAIN: 'text/plain' } };
      if (id === '@kit.PerformanceAnalysisKit') return { hilog: { info() {}, warn() {} } };
      if (id === '@kit.AbilityKit') return { abilityAccessCtrl: { createAtManager: () => ({ on() {}, off() {} }) } };
      if (!id.startsWith('.')) throw Error('Unexpected dependency ' + id);
      return load(path.resolve(path.dirname(file), id + '.ets'));
    }
    vm.runInNewContext(code, { module, exports: module.exports, require: requireEts, Date,
      setInterval(callback) { timers.set(++timer, callback); return timer; }, clearInterval(id) { timers.delete(id); }
    }, { filename: file });
    return module.exports;
  }
  const { ClipboardBridgeService } = load('entry/src/main/ets/services/ClipboardBridgeService.ets');
  const policy = load('entry/src/main/ets/services/ClipboardSyncPolicy.ets');
  return { policy, writes, bridge: () => new ClipboardBridgeService(),
    local(text, textType = true) { value = text; tag = ''; hasData = text !== null;
      if (!hasData) value = ''; hasText = textType; count++; for (const callback of listeners) callback(); },
    tick() { for (const callback of timers.values()) callback(); },
    hold(value) { hold = value; }, flush() { held.splice(0).forEach(callback => callback()); },
    resetCount() { count = 0; }, failWrites(v) { writeFail = v; }, failReads(v) { readFail = v; }
  };
}
const snapshot = (sequence, text, kind = 'text', ready = true) => ({ sequence, text, kind, ready });
const lease = (attemptId = 1) => ({ accountScopeId: 'test-account', windowId: 'window-a', hostId: 'host-a',
  protocol: 'rdp', routeIdentity: 'fixture-route', sessionId: 3, attemptId, nativeGeneration: attemptId });

test('UTF-8 budget rejects malformed UTF-16, NUL and over-budget data without truncating', () => {
  const { policy: p } = environment();
  assert.equal(p.clipboardUtf8Bytes('A中😀'), 8);
  assert.equal(p.validateClipboardText('😀'.repeat(16384)).ok, true);
  assert.equal(p.validateClipboardText('😀'.repeat(16384) + 'a').ok, false);
  assert.equal(p.validateClipboardText('中'.repeat(21845) + 'a').ok, true);
  for (const text of ['\uD800', '\uDC00', '\uD800A', 'a\0b']) assert.equal(p.validateClipboardText(text).ok, false);
  assert.equal(p.validateClipboardText('').ok, false);
  assert.equal(p.validateClipboardText('', true).ok, true);
});
test('startup baseline is quiet; explicit paste sends current preexisting content', async () => {
  const env = environment(), bridge = env.bridge(), sent = [];
  bridge.startMonitoring(text => { sent.push(text); return true; }); await drain();
  assert.deepEqual(sent, []);
  assert.equal(await bridge.readAndSendCurrentText(), true);
  assert.deepEqual(sent, ['existing']);
});
test('repeated equal local events and clear are sent; file-only data is never interpreted as clear', async () => {
  const env = environment(), bridge = env.bridge(), sent = [];
  bridge.startMonitoring(text => { sent.push(text); return true; }); await drain();
  env.local('A'); await drain(); env.local('A'); await drain(); env.local(null); await drain();
  env.local('', false); await drain();
  assert.deepEqual(sent, ['A', 'A', '']);
  assert.equal(await bridge.readAndSendCurrentText(), false);
});
test('remote identical new sequence, A-B-A and clear each deliver; self writes never echo', async () => {
  const env = environment(), bridge = env.bridge(), sent = []; let remote = snapshot(1, 'A');
  bridge.startMonitoring(text => { sent.push(text); return true; }, undefined, true, true, 0, undefined,
    { readRemoteSnapshot: () => remote }); await drain();
  for (const item of [snapshot(1, 'A'), snapshot(2, 'A'), snapshot(3, 'B'), snapshot(4, 'A'), snapshot(5, '', 'none')]) {
    remote = item; env.tick(); await drain(); env.tick(); await drain();
  }
  assert.deepEqual(env.writes, ['A', 'A', 'B', 'A', '']); assert.deepEqual(sent, []);
});
test('only active owner sends/receives; provenance prevents another bridge forwarding remote content', async () => {
  const env = environment(), a = env.bridge(), b = env.bridge(), sentA = [], sentB = [];
  a.startMonitoring(t => { sentA.push(t); return true; }, undefined, true, true, 0, undefined,
    { readRemoteSnapshot: () => snapshot(1, 'secret-A') }); await drain();
  env.tick(); await drain();
  b.startMonitoring(t => { sentB.push(t); return true; }); await drain();
  a.readLocalClipboard(false); b.readLocalClipboard(false); await drain();
  env.local('local'); await drain();
  assert.deepEqual(sentA, []); assert.deepEqual(sentB, ['local']);
  a.setActive(true); env.local('local2'); await drain();
  assert.deepEqual(sentA, ['local2']); assert.deepEqual(sentB, ['local']);
});
test('late async reads cannot send into restarted bridge or overwrite its in-flight flag', async () => {
  const env = environment(), bridge = env.bridge(), old = [], current = [];
  bridge.startMonitoring(t => { old.push(t); return true; }); await drain();
  env.hold(true); env.local('old');
  bridge.stopMonitoring();
  bridge.startMonitoring(t => { current.push(t); return true; });
  env.flush(); await drain(); env.hold(false); env.local('new'); await drain();
  assert.deepEqual(old, []); assert.deepEqual(current, ['new']);
});
test('focus away and back invalidates delayed explicit paste even on same bridge generation', async () => {
  const env = environment(), a = env.bridge(), b = env.bridge(), sent = [];
  a.startMonitoring(t => { sent.push(t); return true; }); await drain();
  env.hold(true); const pending = a.readAndSendCurrentText();
  b.startMonitoring(() => true); a.setActive(true); env.flush(); await drain();
  assert.equal(await pending, false); assert.deepEqual(sent, []);
});
test('failed remote delivery and local admission retry without advancing success checkpoint', async () => {
  const env = environment(), bridge = env.bridge(), sent = []; let accept = false, remote = null;
  bridge.startMonitoring(t => { sent.push(t); return accept; }, undefined, true, true, 0, undefined,
    { readRemoteSnapshot: () => remote }); await drain();
  env.local('retry'); await drain(); accept = true; env.tick(); await drain(); env.tick(); await drain();
  assert.deepEqual(sent, ['retry', 'retry']);
  remote = snapshot(1, 'remote'); env.failWrites(true); env.tick(); await drain();
  assert.deepEqual(env.writes, []);
  env.failWrites(false); env.tick(); await drain(); env.tick(); await drain();
  assert.deepEqual(env.writes, ['remote']);
});
test('failed local read does not send an empty clear and retries on next tick', async () => {
  const env = environment(), bridge = env.bridge(), sent = [];
  bridge.startMonitoring(t => { sent.push(t); return true; }); await drain();
  env.failReads(true); env.local('retry-read'); await drain(); assert.deepEqual(sent, []);
  env.failReads(false); env.tick(); await drain(); assert.deepEqual(sent, ['retry-read']);
});
test('counter reset or changes during asynchronous reads invalidate stale snapshots', async () => {
  const env = environment(), bridge = env.bridge(), sent = [];
  bridge.startMonitoring(t => { sent.push(t); return true; }); await drain();
  env.hold(true); const pending = bridge.readAndSendCurrentText(); env.resetCount(); env.flush(); await drain();
  assert.equal(await pending, false); assert.deepEqual(sent, []);
});
test('new pending remote/file event synchronously owns paste source and fences earlier local read', async () => {
  const env = environment(), bridge = env.bridge(), sent = []; let remote = null;
  bridge.startMonitoring(t => { sent.push(t); return true; }, undefined, true, true, 0, undefined,
    { readRemoteSnapshot: () => remote }); await drain();
  env.hold(true); env.local('old local'); remote = snapshot(1, '', 'files', false);
  assert.equal(bridge.hasRemoteClipboardSource(), true); env.flush(); await drain();
  assert.deepEqual(sent, []); env.tick(); assert.deepEqual(env.writes, []);
  env.hold(false); env.local('fresh local'); await drain(); assert.equal(bridge.hasRemoteClipboardSource(), false);
});
test('a later local copy supersedes pending remote text so late format data cannot overwrite it', async () => {
  const env = environment(), bridge = env.bridge(), sent = []; let remote = null;
  bridge.startMonitoring(t => { sent.push(t); return true; }, undefined, true, true, 0, undefined,
    { readRemoteSnapshot: () => remote }); await drain();
  remote = snapshot(1, '', 'text', false); env.tick();
  env.local('newer local'); await drain();
  remote = snapshot(1, 'older remote'); env.tick(); await drain();
  assert.deepEqual(sent, ['newer local']); assert.deepEqual(env.writes, []);
});
test('remote event arriving during a local read fences that read even before periodic poll', async () => {
  const env = environment(), bridge = env.bridge(), sent = []; let remote = null;
  bridge.startMonitoring(t => { sent.push(t); return true; }, undefined, true, true, 0, undefined,
    { readRemoteSnapshot: () => remote }); await drain();
  env.hold(true); env.local('older local'); remote = snapshot(1, '', 'files', false);
  env.flush(); await drain(); assert.deepEqual(sent, []);
});
test('local count change immediately supersedes remote source before async update completes', async () => {
  const env = environment(), bridge = env.bridge(); let remote = snapshot(1, 'remote');
  bridge.startMonitoring(() => true, undefined, true, true, 0, undefined,
    { readRemoteSnapshot: () => remote }); await drain(); env.tick(); await drain();
  assert.equal(bridge.hasRemoteClipboardSource(), true);
  env.hold(true); env.local('new local'); assert.equal(bridge.hasRemoteClipboardSource(), false);
  env.flush(); await drain();
});
test('same lease bridge reconstruction retains event checkpoint; new attempt does not', async () => {
  const env = environment(); let bridge = env.bridge();
  const options = { lease: lease(), readRemoteSnapshot: () => snapshot(1, 'A') };
  bridge.startMonitoring(() => true, undefined, true, true, 0, undefined, options); await drain();
  env.tick(); await drain(); env.local('B'); await drain(); bridge.stopMonitoring();
  bridge = env.bridge(); bridge.startMonitoring(() => true, undefined, true, true, 0, undefined, options);
  await drain(); env.tick(); await drain(); assert.deepEqual(env.writes, ['A']);
  assert.equal(bridge.hasRemoteClipboardSource(), false); bridge.stopMonitoring();
  bridge = env.bridge(); bridge.startMonitoring(() => true, undefined, true, true, 0, undefined,
    { lease: lease(2), readRemoteSnapshot: () => snapshot(1, 'A') }); await drain(); env.tick(); await drain();
  assert.deepEqual(env.writes, ['A', 'A']);
});
test('async publication is awaited and never reports success after ownership changes', async () => {
  const env = environment(), a = env.bridge(), b = env.bridge(); let acknowledge;
  a.startMonitoring(() => new Promise(resolve => { acknowledge = resolve; })); await drain();
  let settled = false; const pending = a.readAndSendCurrentText().then(result => { settled = true; return result; });
  await drain(); assert.equal(settled, false);
  b.startMonitoring(() => true); acknowledge(true); await drain(); assert.equal(await pending, false);
});
test('async failed publication is retried without duplicating an in-flight request', async () => {
  const env = environment(), bridge = env.bridge(), pending = [];
  bridge.startMonitoring(() => new Promise(resolve => { pending.push(resolve); })); await drain();
  env.local('publish'); await drain(); env.tick(); await drain(); assert.equal(pending.length, 1);
  pending[0](false); await drain(); env.tick(); await drain(); assert.equal(pending.length, 2);
  pending[1](true); await drain(); env.tick(); await drain(); assert.equal(pending.length, 2);
});
test('full lease current guard revocation blocks pending explicit send and remote writes', async () => {
  const env = environment(), bridge = env.bridge(), sent = []; let current = true;
  bridge.startMonitoring(t => { sent.push(t); return true; }, undefined, true, true, 0, undefined,
    { isCurrent: () => current, readRemoteSnapshot: () => snapshot(1, 'remote') }); await drain();
  env.hold(true); const pending = bridge.readAndSendCurrentText(); current = false; env.flush(); await drain();
  assert.equal(await pending, false); env.tick(); assert.deepEqual(sent, []); assert.deepEqual(env.writes, []);
});
(async () => {
  for (const { name, run } of tests) { await run(); console.log('PASS ' + name); }
  console.log(`PASS ${tests.length} transfer clipboard core regressions`);
})().catch(error => { console.error(error); process.exitCode = 1; });
