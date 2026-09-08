/* Exercises the production API23/API26 progress reader with deterministic platform
 * promises and clocks. No system clipboard, network, payload copies or app build. */
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TRANSFER_TYPESCRIPT_PATH || process.env.SSH_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const tests = [], test = (name, run) => tests.push({ name, run });
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
async function flush() { for (let i = 0; i < 40; i++) await Promise.resolve(); }
function observe(promise) { const result = { done: false, value: undefined, error: undefined };
  promise.then(value => { result.done = true; result.value = value; }, error => { result.done = true; result.error = error; }); return result; }
const uriRecord = uri => ({ mimeType: 'text/uri', uri });
function data(records) { return { getRecordCount: () => records.length, getRecord: index => records[index] }; }
function environment() {
  const timers = new Map(), signals = [], stats = [], calls = [], reads = deferred();
  let now = 1000, timer = 0, count = 7, owner = true, params, statGate, statKind = 'file';
  let platformFailure, syncThrow = false, cancelThrow = false, countThrow = false;
  const kinds = new Map();
  class FakeDate extends Date { static now() { return now; } }
  const schedule = (fn, ms, interval) => { const id = ++timer; timers.set(id, { fn, at: now + ms, interval }); return id; };
  const board = {
    getChangeCount() { if (countThrow) throw Error('private counter error'); return count; },
    getDataWithProgress(options) { calls.push('getDataWithProgress'); params = options;
      if (syncThrow) throw platformFailure; return reads.promise; },
    getData() { throw Error('forbidden silent fallback'); }, getUnifiedData() { throw Error('forbidden silent fallback'); }
  };
  class ProgressSignal { constructor() { this.cancelled = 0; signals.push(this); }
    cancel() { this.cancelled++; if (cancelThrow) throw Error('cancel failed'); } }
  const fileIo = { async lstat(name) { stats.push(name); if (statGate) await statGate.promise;
    assert.ok(name.startsWith('file://'), 'metadata must preserve the URI grant');
    const kind = kinds.get(decodeURIComponent(new URL(name).pathname)) ?? statKind; if (kind === 'error') throw Error('private filesystem error');
    return { isDirectory: () => kind === 'directory', isSymbolicLink: () => kind === 'symlink', isFile: () => kind === 'file' }; }
  };
  const source = path.join(root, 'entry/src/main/ets/services/SystemClipboardFileProvider.ets');
  const compiled = ts.transpileModule(fs.readFileSync(source, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  });
  const module = { exports: {} };
  vm.runInNewContext(compiled.outputText, { module, exports: module.exports, Date: FakeDate,
    setTimeout: (fn, ms) => schedule(fn, ms, 0), clearTimeout: id => timers.delete(id),
    setInterval: (fn, ms) => schedule(fn, ms, ms), clearInterval: id => timers.delete(id),
    require(id) {
      if (id === '@kit.BasicServicesKit') return { pasteboard: { getSystemPasteboard: () => board, ProgressSignal,
        ProgressIndicator: { NONE: 0 }, MIMETYPE_TEXT_URI: 'text/uri' } };
      if (id === '@kit.CoreFileKit') return { fileIo, fileUri: { FileUri: class { constructor(uri) {
        const value = new URL(uri); this.path = decodeURIComponent(value.pathname);
      } } } };
      throw Error('Unexpected dependency ' + id);
    }
  }, { filename: source });
  const service = new module.exports.SystemClipboardFileProvider();
  return { service, board, signals, stats, calls, reads, timers,
    guard: () => owner, setOwner: value => owner = value, setCount: value => count = value,
    setCountThrow: value => countThrow = value, setCancelThrow: value => cancelThrow = value,
    setStatKind: value => statKind = value, kind: (name, value) => kinds.set(name, value),
    setStatGate(value) { statGate = value; },
    throwOnStart(error) { platformFailure = error; syncThrow = true; },
    get params() { return params; }, progress(value) { params.progressListener({ progress: value }); },
    async advance(ms) {
      const until = now + ms;
      for (;;) {
        const ready = [...timers].filter(([_id, t]) => t.at <= until).sort((a, b) => a[1].at - b[1].at || a[0] - b[0]);
        if (!ready.length) break;
        const [id, t] = ready[0]; now = t.at;
        if (t.interval) t.at += t.interval; else timers.delete(id);
        t.fn(); await flush();
      }
      now = until; await flush();
    },
    jumpClock(ms) { now += ms; }
  };
}
function failed(result, suffix) { assert.equal(result.done, true); assert.equal(result.error?.message, 'system_clipboard_files_' + suffix); }
function clean(env, cancelled = 0) { assert.equal(env.timers.size, 0); assert.equal(env.signals[0]?.cancelled ?? 0, cancelled); }

test('reads only URI records, preserves authority/escaping and separates bounded read progress', async () => {
  const env = environment(), progress = [];
  const result = observe(env.service.read(env.guard, p => progress.push(p)));
  assert.deepEqual(env.calls, ['getDataWithProgress']);
  assert.equal(env.params.progressIndicator, 0); assert.equal(env.params.progressSignal, env.signals[0]);
  assert.equal(Object.hasOwn(env.params, 'destUri'), false); assert.equal(Object.hasOwn(env.params, 'fileConflictOptions'), false);
  env.progress(35.9); env.progress(2); env.progress(NaN); env.progress(100);
  env.reads.resolve(data([uriRecord('file://docs/storage/hello%2520world.txt'), { mimeType: 'text/plain', plainText: 'ignored' }, uriRecord('file:///storage/zero')]));
  await flush();
  assert.deepEqual(Array.from(result.value), ['file://docs/storage/hello%2520world.txt', 'file:///storage/zero']);
  assert.deepEqual(env.stats, ['file://docs/storage/hello%2520world.txt', 'file:///storage/zero']);
  assert.deepEqual(progress, [0,35,99,100]); clean(env);
});
test('already cancelled or throwing owner is rejected before platform admission', async () => {
  for (const guard of [() => false, () => { throw Error('owner failed'); }]) {
    const env = environment(), result = observe(env.service.read(guard)); await flush();
    failed(result, 'cancelled'); assert.equal(env.calls.length, 0); assert.equal(env.signals.length, 0); clean(env);
  }
});
test('100ms cancellation cancels platform once and does not await its unresolved promise', async () => {
  const env = environment(), progress = [], result = observe(env.service.read(env.guard, p => progress.push(p)));
  env.setOwner(false); await env.advance(99); assert.equal(result.done, false);
  await env.advance(1); failed(result, 'cancelled'); clean(env, 1);
  env.progress(90); env.reads.resolve(data([uriRecord('file:///storage/late')])); await flush();
  assert.deepEqual(progress, [0]); assert.equal(env.stats.length, 0); failed(result, 'cancelled'); clean(env, 1);
});
test('absolute 30s timeout is never extended by progress and late rejection is consumed', async () => {
  const env = environment(), result = observe(env.service.read(env.guard));
  await env.advance(15000); env.progress(50); await env.advance(14999); assert.equal(result.done, false);
  await env.advance(1); failed(result, 'timeout'); clean(env, 1);
  env.reads.reject(Error('late platform error')); await flush(); failed(result, 'timeout'); clean(env, 1);
});
test('change counter increment and reset abort the captured source', async () => {
  for (const value of [8, 0]) {
    const env = environment(), result = observe(env.service.read(env.guard)); env.setCount(value); await env.advance(100);
    failed(result, value === 0 ? 'source_unavailable' : 'source_changed'); clean(env, 1);
  }
});
test('source change immediately before platform fulfillment is checked without waiting for polling', async () => {
  const env = environment(), result = observe(env.service.read(env.guard));
  env.setCount(9); env.reads.resolve(data([uriRecord('file:///storage/file')])); await flush();
  failed(result, 'source_changed'); assert.equal(env.stats.length, 0); clean(env, 1);
});
test('metadata awaits share cancellation/timeout and late completion starts no further metadata work', async () => {
  for (const reason of ['cancelled', 'timeout', 'source_changed']) {
    const env = environment(), gate = deferred(); env.setStatGate(gate);
    const result = observe(env.service.read(env.guard)); env.reads.resolve(data([uriRecord('file:///storage/a'), uriRecord('file:///storage/b')]));
    await flush(); assert.equal(env.stats.length, 1);
    if (reason === 'cancelled') env.setOwner(false); if (reason === 'source_changed') env.setCount(8);
    await env.advance(reason === 'timeout' ? 30000 : 100); failed(result, reason); clean(env, 1);
    gate.resolve(); await flush(); assert.equal(env.stats.length, 1); failed(result, reason);
  }
});
test('source is rechecked after metadata returns and after the final progress observer', async () => {
  const env = environment(), gate = deferred(); env.setStatGate(gate);
  const result = observe(env.service.read(env.guard)); env.reads.resolve(data([uriRecord('file:///storage/a')])); await flush();
  env.setCount(8); gate.resolve(); await flush(); failed(result, 'source_changed'); clean(env, 1);
  const other = environment(), second = observe(other.service.read(other.guard, p => { if (p === 100) other.setOwner(false); }));
  other.reads.resolve(data([uriRecord('file:///storage/a')])); await flush(); failed(second, 'cancelled'); clean(other, 1);
});
test('directories, symlinks, nonregular files and metadata errors reject the whole selection', async () => {
  for (const [kind, code] of [['directory','directory_unsupported'], ['symlink','unsupported_type'], ['socket','unsupported_type'], ['error','read_failed']]) {
    const env = environment(); env.kind('/storage/b', kind);
    const result = observe(env.service.read(env.guard)); env.reads.resolve(data([uriRecord('file:///storage/a'), uriRecord('file:///storage/b')])); await flush();
    failed(result, code); assert.equal(result.value, undefined); clean(env, 1);
  }
});
test('errors and unavailable APIs never fall back to uncancellable readers or expose raw messages', async () => {
  for (const mode of ['reject', 'null', 'sync', 'missing']) {
    const env = environment(); if (mode === 'sync') env.throwOnStart(Error('secret platform path'));
    if (mode === 'missing') env.board.getDataWithProgress = undefined;
    const result = observe(env.service.read(env.guard));
    if (mode === 'reject') env.reads.reject(Error('secret platform path')); if (mode === 'null') env.reads.reject(null);
    await flush(); failed(result, 'read_failed'); clean(env, 1);
    assert.deepEqual(env.calls, mode === 'missing' ? [] : ['getDataWithProgress']);
  }
});
test('invalid or unavailable change counter cannot establish a file source', async () => {
  for (const count of [0, -1, NaN, Number.MAX_SAFE_INTEGER + 1]) {
    const env = environment(); env.setCount(count); const result = observe(env.service.read(env.guard)); await flush();
    failed(result, 'source_unavailable'); assert.equal(env.calls.length, 0); clean(env);
  }
  const env = environment(), result = observe(env.service.read(env.guard)); env.setCountThrow(true); await env.advance(100);
  failed(result, 'source_unavailable'); clean(env, 1);
});
test('empty/nonfile data and unsafe URI records never become file paths', async () => {
  for (const [records, code] of [[[], 'no_files'], [[{ mimeType:'text/plain', plainText:'file:///storage/a' }], 'no_files'],
    [[uriRecord('https://example.test/a')], 'unsupported_uri'], [[uriRecord('file:///storage/a?query=1')], 'unsupported_uri'],
    [[uriRecord('file:///storage/a#fragment')], 'unsupported_uri'], [[uriRecord('file:///storage/a%00b')], 'unsupported_uri'],
    [[uriRecord('file:///storage/a%5cb')], 'unsupported_uri']]) {
    const env = environment(), result = observe(env.service.read(env.guard)); env.reads.resolve(data(records)); await flush();
    failed(result, code); assert.equal(env.stats.length, 0); clean(env, 1);
  }
});
test('256 ordinary files are supported and larger or malformed record counts are rejected before metadata', async () => {
  const env = environment(), result = observe(env.service.read(env.guard));
  env.reads.resolve(data(Array.from({ length:256 }, (_, i) => uriRecord('file:///storage/f' + i))));
  for (let i = 0; i < 30; i++) await flush(); assert.equal(result.value.length, 256); clean(env);
  for (const count of [257, -1, NaN, 1.5]) {
    const other = environment(), rejected = observe(other.service.read(other.guard)); other.reads.resolve({ getRecordCount: () => count });
    await flush(); failed(rejected, 'item_limit'); assert.equal(other.stats.length, 0); clean(other, 1);
  }
});
test('throwing progress observers or platform cancellation do not strand the promise or timers', async () => {
  const env = environment(), result = observe(env.service.read(env.guard, () => { throw Error('observer'); }));
  env.reads.resolve(data([uriRecord('file:///storage/a')])); await flush(); assert.equal(result.error, undefined); clean(env);
  const other = environment(); other.setCancelThrow(true); const rejected = observe(other.service.read(other.guard));
  other.setOwner(false); await other.advance(100); failed(rejected, 'cancelled'); clean(other, 1);
});
test('a delayed event loop checks the absolute deadline before accepting already fulfilled data', async () => {
  const env = environment(), result = observe(env.service.read(env.guard)); env.jumpClock(30001);
  env.reads.resolve(data([uriRecord('file:///storage/a')])); await flush(); failed(result, 'timeout'); assert.equal(env.stats.length, 0); clean(env, 1);
});
(async () => { for (const { name, run } of tests) { await run(); console.log('PASS ' + name); }
  await new Promise(resolve => setImmediate(resolve)); console.log(`${tests.length}/${tests.length} system clipboard file provider tests passed`);
})().catch(error => { console.error(error); process.exitCode = 1; });
