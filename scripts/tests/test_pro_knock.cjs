/* Executes production ArkTS receivers and file staging against real temp files.
 * Platform Share Kit callbacks are controlled here; this is not device proof. */
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const repo = path.resolve(__dirname, '../..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'pro-knock-test-'));
const tests = [];
function test(name, body) { tests.push({ name, body }); }
async function settle(predicate = () => false) {
  for (let i = 0; i < 200; i++) {
    await new Promise(resolve => setImmediate(resolve));
    if (predicate()) return;
  }
}
function fixture() {
  const root = fs.mkdtempSync(path.join(temporary, 'case-'));
  const state = { root, registrations: [], removed: [], free: 2 ** 40, afterRead: null,
    readSizes: [], writtenSizes: [], timers: new Map(), maxWrite: Infinity };
  const deviceInfo = { sdkApiVersion: 26, deviceType: 'pc' };
  const preferences = new Map();
  function stat(info) { info.mtime = Math.trunc(info.mtimeMs); return info; }
  const fileIo = {
    OpenMode: { READ_ONLY: fs.constants.O_RDONLY, WRITE_ONLY: fs.constants.O_WRONLY,
      CREATE: fs.constants.O_CREAT, NOFOLLOW: fs.constants.O_NOFOLLOW },
    mkdir: async (p, recursive = false) => fs.promises.mkdir(p, { recursive }),
    listFile: async p => fs.promises.readdir(p),
    lstat: async p => stat(await fs.promises.lstat(p)), stat: async p => stat(await fs.promises.stat(p)),
    rmdir: async p => { state.removed.push(p); await fs.promises.rm(p, { recursive: true }); },
    unlink: async p => fs.promises.unlink(p),
    openSync: (p, flags) => ({ fd: fs.openSync(p, flags, 0o600) }),
    closeSync: f => fs.closeSync(typeof f === 'number' ? f : f.fd),
    statSync: fd => stat(typeof fd === 'number' ? fs.fstatSync(fd) : fs.statSync(fd)),
    fsyncSync: fd => fs.fsyncSync(fd),
    read: async (fd, data) => {
      state.readSizes.push(data.byteLength);
      const read = fs.readSync(fd, Buffer.from(data), 0, data.byteLength, null);
      state.afterRead?.(); return read;
    },
    write: async (fd, data) => {
      state.writtenSizes.push(data.byteLength);
      return fs.writeSync(fd, Buffer.from(data), 0, Math.min(state.maxWrite, data.byteLength), null);
    }
  };
  const harmonyShare = {
    ReceivableErrorCode: { NO_RECEIVABLE_ERROR: 1 }, ShareResultCode: { SHARE_SUCCESS: 0 },
    on: (event, registry, callback) => state.registrations.push({ event, registry, callback }),
    off: (event, registry, callback) => {
      const r = state.registrations.find(r => r.registry === registry && r.callback === callback);
      assert.ok(r, 'off must reuse the exact registration and callback'); r.off = true;
    }
  };
  const mocks = {
    '@kit.BasicServicesKit': { deviceInfo }, '@kit.ShareKit': { harmonyShare },
    '@kit.AbilityKit': {}, '@kit.ArkData': { preferences: { getPreferencesSync: () => ({
      getSync: (key, fallback) => preferences.has(key) ? preferences.get(key) : fallback,
      putSync: (key, value) => preferences.set(key, value), flushSync() {}
    }) } },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error() {}, warn() {} } },
    '@kit.CoreFileKit': { fileIo, statfs: { getFreeSize: async () => state.free },
      fileUri: { getUriFromPath: p => 'file://app' + p,
        FileUri: class { constructor(uri) { this.path = decodeURIComponent(new URL(uri).pathname); } } } }
  };
  const cache = new Map();
  function load(relative) {
    const file = path.resolve(repo, relative);
    if (cache.has(file)) return cache.get(file).exports;
    const module = { exports: {} }; cache.set(file, module);
    const source = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
    }).outputText;
    vm.runInNewContext(source, { module, exports: module.exports, Date,
      require: id => {
        if (mocks[id]) return mocks[id];
        if (id.startsWith('.')) return load(path.resolve(path.dirname(file), id + '.ets'));
        throw new Error('unexpected platform import ' + id);
      }, canIUse: () => true,
      setTimeout: (callback, delay) => { const id = state.timers.size + 1; state.timers.set(id, { callback, delay }); return id; },
      clearTimeout: id => state.timers.delete(id)
    }, { filename: file });
    return module.exports;
  }
  const policy = load('entry/src/main/ets/services/pro/ProKnockPolicy.ets');
  const { ProKnockReceiver } = load('entry/src/main/ets/services/pro/ProKnockReceiver.ets');
  const { SshSftpShareStager } = load('entry/src/main/ets/services/ssh/sftp/SshSftpShareStager.ets');
  const receiver = new ProKnockReceiver();
  const target = { rejected: 0, received: 0, callback: null, point: { screenX: 120, screenY: 200 },
    getInfo: () => ({ coordinate: target.point }),
    reject: async () => { target.rejected++; },
    receive: async (uri, callback) => { target.received++; target.uri = uri; target.callback = callback; }
  };
  let active = true; let deliveries = 0;
  const statuses = [];
  const options = { windowId: 17, cacheDir: root, isCurrent: () => active,
    confirm: async () => true, deliver: async () => { deliveries++; return true; },
    status: (message, busy) => statuses.push({ message, busy }) };
  return { ...state, state, load, policy, deviceInfo, receiver, target, options, statuses,
    stage: new SshSftpShareStager(), invalidate: () => { active = false; }, deliveries: () => deliveries,
    fire: (t = target) => state.registrations.at(-1).callback(t) };
}
test('coordinates fail closed outside a window and use explicit fallback for missing/invalid points', () => {
  const { policy } = fixture(); const bounds = { left: 100, top: 100, width: 300, height: 200 };
  assert.equal(policy.matchKnockWindow({ x: 100, y: 100 }, bounds), 'inside');
  assert.equal(policy.matchKnockWindow({ x: 400, y: 100 }, bounds), 'outside');
  for (const point of [null, { x: -1, y: 100 }, { x: NaN, y: 100 }, { x: 120.5, y: 120 }]) {
    assert.equal(policy.matchKnockWindow(point, bounds), 'unknown');
  }
});
test('untrusted source paths and aggregate file sizes are bounded', () => {
  const { policy } = fixture();
  for (const p of ['/sandbox2/f', '/sandbox/../f', '/sandbox/a/../../f', '/sandbox/a//f',
    '/sandbox/./f', '/sandbox/a\\f', '/sandbox/f\u0000']) assert.equal(policy.knockRelativePath('/sandbox', p), null);
  assert.equal(policy.knockRelativePath('/sandbox', '/sandbox/a/f'), 'a/f');
  assert.equal(policy.knockFileSizeAllowed(2 ** 29, 0), true);
  for (const size of [-1, NaN, Infinity, 0.5, 2 ** 29 + 1]) assert.equal(policy.knockFileSizeAllowed(size, 0), false);
  assert.equal(policy.knockFileSizeAllowed(1, 2 ** 29), false);
});
test('completed files are copied in bounded chunks, handle partial writes, preserve empty and duplicate names', async () => {
  const f = fixture(); const source = path.join(f.root, 'source'), dest = path.join(f.root, 'dest');
  fs.mkdirSync(source); fs.mkdirSync(dest); fs.mkdirSync(path.join(source, 'nested'));
  const content = crypto.randomBytes(180003); fs.writeFileSync(path.join(source, 'file.bin'), content);
  fs.writeFileSync(path.join(source, 'nested/file.bin'), 'second'); fs.writeFileSync(path.join(source, 'empty'), '');
  f.state.maxWrite = 13001;
  const result = await f.stage.stage(['file.bin', 'nested/file.bin', 'empty'].map(p => path.join(source, p)), source, dest, () => true);
  assert.equal(result.length, 3); assert.equal(new Set(result.map(r => r.name)).size, 3);
  assert.deepEqual(fs.readFileSync(path.join(dest, result[0].name)), content);
  assert.equal(fs.readFileSync(path.join(dest, result[1].name), 'utf8'), 'second');
  assert.equal(fs.statSync(path.join(dest, result[2].name)).size, 0);
  assert.ok(f.state.readSizes.every(size => size <= 65536));
});
test('source escape and symbolic-link ancestors are rejected before any file content is read', async () => {
  const f = fixture(); const source = path.join(f.root, 'source'), dest = path.join(f.root, 'dest');
  fs.mkdirSync(source); fs.mkdirSync(dest); fs.writeFileSync(path.join(f.root, 'private'), 'private');
  fs.symlinkSync(f.root, path.join(source, 'link'));
  for (const p of [path.join(f.root, 'private'), path.join(source, 'link/private')]) {
    await assert.rejects(() => f.stage.stage([p], source, dest, () => true));
  }
  assert.equal(f.state.readSizes.length, 0); assert.deepEqual(fs.readdirSync(dest), []);
});
test('cancellation while reading prevents subsequent writes and low disk space prevents transfer', async () => {
  const f = fixture(); const source = path.join(f.root, 'source'), dest = path.join(f.root, 'dest');
  fs.mkdirSync(source); fs.mkdirSync(dest); const p = path.join(source, 'f'); fs.writeFileSync(p, crypto.randomBytes(70000));
  f.state.free = 0; await assert.rejects(() => f.stage.stage([p], source, dest, () => true));
  assert.equal(f.state.readSizes.length, 0);
  f.state.free = 2 ** 40; let active = true; f.state.afterRead = () => { active = false; };
  await assert.rejects(() => f.stage.stage([p], source, dest, () => active));
  assert.equal(f.state.writtenSizes.length, 0);
});
test('batch sandbox source stays separate from user folder grants and is removed on discard', async () => {
  const f = fixture(); const { SshLocalFileProvider } = f.load('entry/src/main/ets/services/SshLocalFileProvider.ets');
  const provider = new SshLocalFileProvider(); provider.init({ filesDir: f.root });
  assert.equal(await provider.currentRoot(), '');
  const root = await provider.createTransferStagingRoot(); assert.ok(root.startsWith(f.root + '/ssh-transfer-box/incoming-'));
  fs.writeFileSync(root + '/f', 'source');
  assert.equal(await provider.resolveRelative(root, 'f'), root + '/f');
  assert.equal(await provider.resolveRelative(root, '../private'), null);
  assert.equal(await provider.resolveRelative(root + '/../private', 'f'), null);
  assert.equal(await provider.stat(root + '/../private'), null);
  assert.equal(await provider.resolveRelative(f.root, 'private'), null);
  assert.equal(await provider.currentRoot(), '');
  assert.equal(await provider.remove(root, true), true); assert.equal(fs.existsSync(root), false);
  assert.equal(await provider.resolveRelative(root, 'f'), null);
});
test('API23 and unsupported devices never register native receive capability', () => {
  const f = fixture(); f.deviceInfo.sdkApiVersion = 23;
  assert.equal(f.receiver.arm(f.options), false);
  f.deviceInfo.sdkApiVersion = 26; f.deviceInfo.deviceType = 'phone';
  assert.equal(f.receiver.arm(f.options), false); assert.equal(f.state.registrations.length, 0);
});
test('received names resolve to the actual staged file through the SFTP batch planner and provider', async () => {
  const f = fixture(); const { SshLocalFileProvider } = f.load('entry/src/main/ets/services/SshLocalFileProvider.ets');
  const { planSshSftpBatch } = f.load('entry/src/main/ets/services/SshSftpBatchPolicy.ets');
  const provider = new SshLocalFileProvider(); provider.init({ filesDir: f.root });
  const source = path.join(f.root, 'source'); fs.mkdirSync(source);
  const names = ['report.txt', ' report.txt ', '    '];
  names.forEach((name, index) => fs.writeFileSync(path.join(source, name), 'data-' + index));
  const dest = await provider.createTransferStagingRoot();
  const items = await f.stage.stage(names.map(name => path.join(source, name)), source, dest, () => true);
  const plan = planSshSftpBatch(items); assert.equal(plan.accepted, true);
  for (const [index, item] of items.entries()) {
    const resolved = await provider.resolveRelative(dest, item.relativePath);
    assert.ok(resolved); assert.equal(fs.readFileSync(resolved, 'utf8'), 'data-' + index);
  }
  assert.equal(new Set(items.map(item => item.name)).size, 3);
});
test('cold provider initialization removes only orphaned incoming directories and preserves ordinary files', async () => {
  const f = fixture(); const { SshLocalFileProvider } = f.load('entry/src/main/ets/services/SshLocalFileProvider.ets');
  const previous = new SshLocalFileProvider(); previous.init({ filesDir: f.root });
  const orphan = await previous.createTransferStagingRoot(); fs.writeFileSync(orphan + '/f', 'old');
  const box = path.dirname(orphan); const ordinary = box + '/my-directory'; fs.mkdirSync(ordinary);
  fs.writeFileSync(ordinary + '/important', 'keep');
  const ownedLink = await previous.createTransferStagingRoot(); fs.rmdirSync(ownedLink); fs.symlinkSync(ordinary, ownedLink);
  const lookalike = box + '/incoming-custom-user'; fs.mkdirSync(lookalike); fs.writeFileSync(lookalike + '/keep', 'mine');
  const restored = new SshLocalFileProvider(); restored.init({ filesDir: f.root });
  const current = await restored.createTransferStagingRoot();
  assert.equal(fs.existsSync(orphan), false); assert.equal(fs.existsSync(ownedLink), false);
  assert.equal(fs.readFileSync(ordinary + '/important', 'utf8'), 'keep');
  assert.equal(fs.readFileSync(lookalike + '/keep', 'utf8'), 'mine');
  fs.writeFileSync(current + '/live', 'current');
  restored.init({ filesDir: f.root }); // Another UIAbility context must preserve this process's active source.
  assert.equal(await restored.resolveRelative(current, 'live'), current + '/live');
  assert.equal(fs.readFileSync(current + '/live', 'utf8'), 'current');
  await restored.remove(current, true);
});
test('cancelled and stale confirmation cannot open an incoming directory or start receive', async () => {
  const f = fixture(); let resolve; f.options.confirm = () => new Promise(done => { resolve = done; });
  assert.equal(f.receiver.arm(f.options), true); f.fire(); f.receiver.stop(); resolve(true);
  await settle(() => f.target.rejected > 0);
  assert.equal(f.target.received, 0); assert.deepEqual(fs.readdirSync(f.root), []);
});
test('success result before data plus duplicate data yields exactly one delivery and cleans sandbox', async () => {
  const f = fixture(); f.receiver.arm(f.options); f.fire(); await settle(() => f.target.callback);
  assert.ok(f.target.callback); const root = decodeURIComponent(new URL(f.target.uri).pathname);
  f.target.callback.onResult(0);
  const data = { getRecords: () => [{ uri: root + '/f' }] };
  f.target.callback.onDataReceived(data); f.target.callback.onDataReceived(data);
  await settle(() => !fs.existsSync(root)); assert.equal(f.deliveries(), 1);
  assert.equal(fs.existsSync(root), false); assert.equal(f.statuses.at(-1).busy, false);
});
test('stop during system receive quarantines files until terminal callback and never delivers late files', async () => {
  const f = fixture(); f.receiver.arm(f.options); f.fire(); await settle(() => f.target.callback);
  const root = decodeURIComponent(new URL(f.target.uri).pathname);
  f.receiver.stop(); assert.equal(fs.existsSync(root), true);
  assert.equal(f.receiver.arm(f.options), false, 'native receive must remain single flight');
  f.target.callback.onDataReceived({ getRecords: () => [{ uri: root + '/f' }] });
  await settle(() => !f.receiver.receiving); assert.equal(f.deliveries(), 0);
  assert.equal(f.receiver.arm(f.options), true); f.receiver.stop();
});
test('late failure from a completed transfer cannot invalidate a newly armed window', async () => {
  const f = fixture(); f.receiver.arm(f.options); f.fire(); await settle(() => f.target.callback);
  const old = f.target.callback; old.onDataReceived({ getRecords: () => [{ uri: 'unused' }] });
  await settle(() => !f.receiver.receiving);
  assert.equal(f.receiver.arm(f.options), true); const epoch = f.receiver.epoch;
  old.onResult(1); assert.equal(f.receiver.epoch, epoch);
  const next = { ...f.target, received: 0 }; next.receive = async () => { next.received++; };
  f.fire(next); await settle(() => next.received > 0); assert.equal(next.received, 1); f.receiver.stop();
});
test('insufficient receive space rejects before granting a directory', async () => {
  const f = fixture(); f.state.free = 0; f.receiver.arm(f.options); f.fire();
  await settle(() => f.target.rejected > 0);
  assert.equal(f.target.received, 0); assert.deepEqual(fs.readdirSync(f.root), []);
});
(async () => {
  try {
    for (const test of tests) { await test.body(); process.stdout.write('PASS ' + test.name + '\n'); }
    process.stdout.write('PASS ' + tests.length + ' Pro knock checks\n');
  } finally { fs.rmSync(temporary, { recursive: true, force: true }); }
})().catch(error => { console.error(error); process.exitCode = 1; });
