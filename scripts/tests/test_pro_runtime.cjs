/* Host execution of pure ArkTS policy/runtime tests; the DevEco gate still checks ArkTS itself.
 * Usage: PRO_TYPESCRIPT_PATH=<DevEco typescript module> node scripts/tests/test_pro_runtime.cjs
 */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const tests = [];
function environment(debug, clock = { now: 1000 }, mocks = {}) {
  const cache = new Map(); const timers = new Map(); let timerId = 0;
  const hypium = {
    describe: (_name, body) => body(), it: (name, _level, body) => tests.push({ name, body }),
    expect: (value) => ({ assertEqual: (expected) => assert.equal(value, expected),
      assertTrue: () => assert.equal(value, true), assertFalse: () => assert.equal(value, false) })
  };
  function load(file) {
    file = path.resolve(root, file);
    if (mocks[file]) return mocks[file];
    if (cache.has(file)) return cache.get(file).exports;
    const module = { exports: {} }; cache.set(file, module);
    const source = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
    }).outputText;
    const requireEts = (id) => {
      if (id === 'BuildProfile') return { DEBUG: debug, VERSION_CODE: 100 };
      if (mocks[id]) return mocks[id];
      if (file.endsWith('/AccountSessionCoordinator.ets')) {
        if (id === './AccountScopePolicy') return { deviceLocalScopeToken: () => ({ kind: 'device_local', ownerScopeId: 'local', generation: 0, sessionState: 'offline' }) };
        if (id === './AppCloneContext') return { AppCloneContext: { getInstance: () => ({ accountKitAllowed: () => true }) } };
        return {}; // Unused platform collaborators; actual public transition/notification code still executes.
      }
      if (id === '@ohos/hypium') return hypium;
      if (!id.startsWith('.')) throw new Error('Unexpected platform import: ' + id);
      return load(path.resolve(path.dirname(file), id + '.ets'));
    };
    const context = { module, exports: module.exports, require: requireEts,
      Date: { now: () => clock.now }, setTimeout: (callback, delay) => {
        const id = ++timerId; timers.set(id, { callback, at: clock.now + delay }); return id;
      }, clearTimeout: (id) => timers.delete(id) };
    vm.runInNewContext(source, context, { filename: file });
    return module.exports;
  }
  return { load, clock, timers, advance: (now) => {
    clock.now = now;
    for (const [id, timer] of [...timers]) {
      if (timer.at <= now) { timers.delete(id); timer.callback(); }
    }
  } };
}
function fixture(debug = true) {
  const env = environment(debug);
  const base = 'entry/src/main/ets/services/pro/';
  const { ProEntitlementService } = env.load(base + 'ProEntitlementService.ets');
  const catalog = env.load(base + 'ProFeatureCatalog.ets');
  const originalCatalog = catalog.proFeatures;
  catalog.proFeatures = () => [...originalCatalog(), { ...originalCatalog()[1],
    id: 'test.shipped', availability: 'available' }];
  const { ProRuntime } = env.load(base + 'ProRuntime.ets');
  const verifier = { result: { status: 'unavailable', owner: 'a', environment: 'production' },
    verify: async () => verifier.result };
  const service = new ProEntitlementService(verifier);
  service.bindAccount('a', 'production');
  const runtime = new ProRuntime(service);
  const context = { appVersionCode: 100, apiVersion: 26, device: 'pc', protocol: 'rdp',
    capabilities: [], grantedPermissions: [], requestablePermissions: [] };
  const grant = { owner: 'a', environment: 'production', productId: 'test',
    verifiedAt: 500, revalidateAfter: 1500, usableUntil: 2000, entitlementIds: ['pro.lifetime'] };
  return { ...env, service, runtime, verifier, context, grant };
}
const policyEnv = environment(true);
policyEnv.load('entry/src/test/ProAccessPolicy.test.ets').default();
function test(name, body) { tests.push({ name, body }); }
test('debug synchronizes subscribers without changing real entitlement or planned gates', () => {
  const f = fixture(); let a = 0, b = 0;
  const stopA = f.runtime.subscribe(() => a++); const stopB = f.runtime.subscribe(() => b++);
  assert.equal(a, 1); assert.equal(b, 1);
  const before = JSON.stringify(f.service.snapshot());
  f.runtime.setDebugMode('pro');
  assert.equal(f.runtime.decision('test.shipped', f.context).executable, true);
  assert.equal(f.runtime.snapshot().label, '模拟 Pro'); assert.equal(a, 2); assert.equal(b, 2);
  assert.equal(JSON.stringify(f.service.snapshot()), before);
  assert.equal(f.runtime.decision('pro.personalization.appIcon', f.context).visible, true);
  assert.equal(f.runtime.decision('pro.personalization.appIcon', { ...f.context, apiVersion: 23 }).visible, false);
  let calls = 0; f.runtime.run('pro.workspaces', f.context, () => calls++); assert.equal(calls, 0);
  f.runtime.run('core.connection', f.context, () => calls++); assert.equal(calls, 1);
  stopB(); f.runtime.setDebugMode('free'); assert.equal(b, 2); assert.equal(a, 3);
  f.runtime.setDebugMode('invalid'); assert.equal(f.runtime.snapshot().mode, 'free');
  f.runtime.setDebugMode('real'); assert.equal(f.runtime.snapshot().realState, 'free');
  stopA(); f.runtime.dispose(); assert.equal(f.timers.size, 0);
  const restarted = fixture(); assert.equal(restarted.runtime.snapshot().mode, 'real'); restarted.runtime.dispose();
});
test('release runtime denies forced simulation at both setter and decision', () => {
  const f = fixture(false); f.runtime.setDebugMode('pro');
  // Fault injection proves the read side is guarded too, independent of setter visibility.
  f.runtime.debugMode = 'pro';
  assert.equal(f.runtime.snapshot().mode, 'real');
  assert.equal(f.runtime.snapshot().effectiveState, 'free');
  assert.equal(f.runtime.decision('test.shipped', f.context).executable, false);
  let calls = 0; f.runtime.run('test.shipped', f.context, () => calls++); assert.equal(calls, 0);
  f.runtime.dispose();
});
test('cache boundaries notify and return revalidation, not repurchase', async () => {
  const f = fixture(); let notifications = 0; f.runtime.subscribe(() => notifications++);
  f.verifier.result = { status: 'verified', owner: 'a', environment: 'production', grant: f.grant };
  await f.service.reconcile([]); const activated = notifications;
  f.advance(1500); assert.ok(notifications > activated); assert.equal(f.runtime.snapshot().needsRevalidation, true);
  assert.equal(f.runtime.snapshot().effectiveState, 'active');
  f.advance(2000); assert.equal(f.runtime.snapshot().effectiveState, 'verificationRequired');
  assert.equal(f.timers.size, 1); f.runtime.dispose(); assert.equal(f.timers.size, 0);
});
test('late account and out-of-order verification cannot resurrect grants', async () => {
  const f = fixture(); const replies = [];
  f.verifier.verify = () => new Promise(resolve => replies.push(resolve));
  const stale = f.service.reconcile([]); f.service.bindAccount('b', 'production', 2);
  replies.shift()({ status: 'verified', owner: 'a', environment: 'production', grant: f.grant });
  assert.equal(await stale, false); assert.equal(f.service.snapshot().state, 'free');
  f.service.bindAccount('a', 'production', 3);
  const first = f.service.reconcile([]); const second = f.service.reconcile([]);
  replies[1]({ status: 'revoked', owner: 'a', environment: 'production' }); await second;
  replies[0]({ status: 'verified', owner: 'a', environment: 'production', grant: f.grant }); await first;
  assert.equal(f.service.snapshot().state, 'revoked'); f.runtime.dispose();
});
test('verifier throws or malformed result preserves only a still-usable trusted grant', async () => {
  const f = fixture(); f.verifier.result = { status: 'verified', owner: 'a', environment: 'production', grant: f.grant };
  await f.service.reconcile([]); f.verifier.verify = async () => { throw new Error('offline'); };
  await f.service.reconcile([]); assert.equal(f.service.snapshot().state, 'active');
  f.advance(2000); assert.equal(f.service.snapshot().state, 'verificationRequired'); f.runtime.dispose();
});
test('real account transitions isolate Pro before their first await and through overlapping failures', async () => {
  const env = environment(false, { now: 1000 }, {
    '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: 26, deviceType: '2in1' },
      systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: () => 0 } },
    '@kit.ArkTS': { util: {} }, '@kit.ArkData': { relationalStore: {} },
    '@kit.CryptoArchitectureKit': { cryptoFramework: {} }, '@kit.NetworkKit': { http: {} },
    [path.resolve(root, 'entry/src/main/ets/services/AccountKitService.ets')]: { AccountKitService: {} }
  });
  const { AccountSessionCoordinator } = env.load('entry/src/main/ets/services/AccountSessionCoordinator.ets');
  const account = AccountSessionCoordinator.getInstance();
  account.current = { kind: 'huawei_account', ownerScopeId: 'a', generation: 1, sessionState: 'ready' };
  const ready = [];
  account.whenReady = () => new Promise(resolve => ready.push(resolve));
  const { ProAppRuntime } = env.load('entry/src/main/ets/services/pro/ProAppRuntime.ets');
  const app = ProAppRuntime.getInstance();
  const grant = { owner: 'a', environment: 'production', productId: 'test', entitlementIds: ['pro.lifetime'],
    verifiedAt: 500, revalidateAfter: 1500, usableUntil: 2000 };
  app.entitlement.verifier = { verify: async () => ({ status: 'verified', owner: 'a', environment: 'production', grant }) };
  await app.entitlement.reconcile([]); assert.equal(app.runtime.snapshot().realState, 'active');
  let notifications = 0; app.runtime.subscribe(() => notifications++);
  const before = notifications;
  const login = account.transitionToAccount({});
  assert.equal(app.runtime.snapshot().realState, 'free'); assert.ok(notifications > before);
  const logout = account.transitionToOffline();
  assert.equal(app.transitionActive, true);
  ready[0](false); await login;
  assert.equal(app.transitionActive, true); assert.equal(app.entitlement.owner, '');
  ready[1](false); await logout;
  assert.equal(app.transitionActive, false); assert.equal(app.entitlement.owner, 'a');
  assert.equal(app.runtime.snapshot().realState, 'free'); // A failed transition cannot resurrect the old grant.
  assert.equal(app.context().device, 'pc');
  app.runtime.dispose();
});
function iconFixture(debug = true) {
  const f = fixture(debug); let selected = ''; let queries = 0; const applied = [];
  const { ProAppIconController } = f.load('entry/src/main/ets/services/pro/ProAppIconController.ets');
  const icons = () => ['rd_white', 'rd_transparent'].map(name => ({ name, enabled: selected === name }));
  const provider = { supported: () => true, query: async () => { queries++; return icons(); },
    apply: async name => { applied.push(name); selected = name; } };
  const controller = new ProAppIconController(provider, f.runtime, () => f.context);
  return { ...f, controller, provider, applied, icons, queries: () => queries,
    dispose: () => { controller.dispose(); f.runtime.dispose(); } };
}
test('real icon feature hides for free users and rejects direct calls; default restore stays free', async () => {
  const f = iconFixture();
  assert.equal(f.runtime.decision('pro.personalization.appIcon', f.context).visible, false);
  assert.equal(await f.controller.select('rd_white', () => true), false);
  assert.equal(f.queries(), 0); assert.equal(f.applied.length, 0);
  assert.equal(await f.controller.select('', () => true), true);
  assert.deepEqual(f.applied, ['']);
  f.runtime.setDebugMode('pro');
  assert.equal(await f.controller.select('rd_white', () => true), true);
  assert.equal(f.controller.snapshot().currentName, 'rd_white');
  f.runtime.setDebugMode('free');
  assert.equal(f.controller.snapshot().currentName, 'rd_white'); // mode changes never mutate the real system icon
  assert.equal(await f.controller.select('rd_transparent', () => true), false);
  assert.equal(await f.controller.select('', () => true), true);
  assert.equal(f.controller.snapshot().currentName, ''); f.dispose();
});
test('release icon action needs a real grant and cannot be enabled by simulated state', async () => {
  const f = iconFixture(false); f.runtime.setDebugMode('pro'); f.runtime.debugMode = 'pro';
  assert.equal(await f.controller.select('rd_white', () => true), false);
  f.verifier.result = { status: 'verified', owner: 'a', environment: 'production', grant: f.grant };
  await f.service.reconcile([]);
  assert.equal(await f.controller.select('rd_transparent', () => true), true);
  f.verifier.result = { status: 'revoked', owner: 'a', environment: 'production' }; await f.service.reconcile([]);
  assert.equal(await f.controller.select('rd_white', () => true), false);
  assert.equal(await f.controller.select('', () => true), true); f.dispose();
});
test('icon preflight rejects stale account, changed simulation, closed UI and duplicate window actions', async () => {
  for (const change of ['account', 'mode', 'close']) {
    const f = iconFixture(); f.runtime.setDebugMode('pro'); let live = true; let resolve;
    f.provider.query = () => new Promise(done => { resolve = done; });
    const first = f.controller.select('rd_white', () => live);
    assert.equal(await f.controller.select('rd_transparent', () => true), false);
    if (change === 'account') f.service.bindAccount('b', 'production', 2);
    if (change === 'mode') f.runtime.setDebugMode('free');
    if (change === 'close') live = false;
    resolve(f.icons()); assert.equal(await first, false);
    assert.equal(f.applied.length, 0); assert.equal(f.controller.snapshot().busy, false); f.dispose();
  }
});
test('expired icon entitlement is rechecked after asynchronous system query', async () => {
  const f = iconFixture(false); let resolve;
  f.verifier.result = { status: 'verified', owner: 'a', environment: 'production', grant: f.grant };
  await f.service.reconcile([]);
  f.provider.query = () => new Promise(done => { resolve = done; });
  const action = f.controller.select('rd_white', () => true);
  f.clock.now = 2000; // no timer callback: decision must re-evaluate the clock itself
  resolve(f.icons()); assert.equal(await action, false); assert.equal(f.applied.length, 0); f.dispose();
});
test('icon dismiss epoch rejects the old action while the child still lives, including rapid reopen', async () => {
  const f = iconFixture(); f.runtime.setDebugMode('pro'); let resolve;
  const { ProPurchaseLifecycle } = f.load('entry/src/main/ets/services/pro/ProPurchaseLifecycle.ets');
  const epoch = ProPurchaseLifecycle.capture();
  f.provider.query = () => new Promise(done => { resolve = done; });
  const action = f.controller.select('rd_white', () => ProPurchaseLifecycle.current(epoch));
  ProPurchaseLifecycle.dismiss(); // the child has not reached aboutToDisappear yet
  resolve(f.icons()); assert.equal(await action, false); assert.equal(f.applied.length, 0);
  const reopened = ProPurchaseLifecycle.capture();
  f.provider.query = async () => f.icons();
  assert.equal(await f.controller.select('rd_transparent', () => ProPurchaseLifecycle.current(reopened)), true);
  f.dispose();
});
test('icon controller rejects unsupported systems, unknown and absent preset names without a mutation', async () => {
  const f = iconFixture(); f.runtime.setDebugMode('pro');
  f.provider.supported = () => false;
  await f.controller.refresh(); assert.equal(await f.controller.select('', () => true), false);
  assert.equal(f.queries(), 0);
  f.provider.supported = () => true;
  assert.equal(await f.controller.select('../../custom.png', () => true), false);
  f.provider.query = async () => [];
  assert.equal(await f.controller.select('rd_white', () => true), false);
  assert.equal(f.applied.length, 0); f.dispose();
});
test('icon read failure and unconfirmed mutation never report a default or successful selection', async () => {
  const f = iconFixture(); f.runtime.setDebugMode('pro');
  f.provider.query = async () => { throw new Error('read unavailable'); };
  await f.controller.refresh(); assert.equal(f.controller.snapshot().loaded, false);
  assert.equal(await f.controller.select('rd_white', () => true), false);
  assert.equal(f.applied.length, 0);
  f.provider.query = async () => f.icons(); f.provider.apply = async () => {};
  assert.equal(await f.controller.select('rd_white', () => true), false);
  assert.equal(f.controller.snapshot().currentName, '');
  assert.equal(f.controller.snapshot().loaded, false); // the UI must expose its reread action
  assert.match(f.controller.snapshot().message, /尚未确认/);
  let reads = 0;
  f.provider.query = async () => { if (++reads > 1) throw new Error('after mutation'); return f.icons(); };
  assert.equal(await f.controller.select('rd_white', () => true), false);
  assert.equal(f.controller.snapshot().loaded, false);
  assert.match(f.controller.snapshot().message, /无法确认/); f.dispose();
});
test('stale icon refresh cannot overwrite a newer confirmed mutation and subscribers stay synchronized', async () => {
  const f = iconFixture(); f.runtime.setDebugMode('pro'); let resolve;
  let a = '', b = ''; const stopA = f.controller.subscribe(() => a = f.controller.snapshot().currentName);
  const stopB = f.controller.subscribe(() => b = f.controller.snapshot().currentName);
  f.provider.query = () => new Promise(done => resolve = done);
  const stale = f.controller.refresh();
  f.provider.query = async () => f.icons();
  assert.equal(await f.controller.select('rd_white', () => true), true);
  resolve([{ name: 'rd_transparent', enabled: true }]); await stale;
  assert.equal(a, 'rd_white'); assert.equal(b, 'rd_white'); stopB();
  await f.controller.select('', () => true); assert.equal(a, ''); assert.equal(b, 'rd_white');
  stopA(); f.dispose();
});
test('actual API23 icon adapter cold import and calls never access API26 members', async () => {
  let accesses = 0;
  const bundleManager = {};
  for (const name of ['getAlternateIcons', 'setAlternateIcon']) Object.defineProperty(bundleManager, name,
    { get() { accesses++; throw new Error('API26 member unavailable'); } });
  const env = environment(false, { now: 1000 }, {
    '@kit.AbilityKit': { bundleManager }, '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: 23 } }
  });
  const { AppIconAdapter } = env.load('entry/src/main/ets/common/AppIconAdapter.ets');
  const adapter = new AppIconAdapter(); assert.equal(adapter.supported(), false);
  assert.equal((await adapter.query()).length, 0);
  await assert.rejects(() => adapter.apply('rd_white'), /iconUnsupported/);
  assert.equal(accesses, 0);
});
test('experimental SFTP receiver is limited to Debug Pro on supported PC and protocol', () => {
  const f = fixture(); const id = 'pro.file.knockTransfer';
  const context = { ...f.context, protocol: 'ssh', capabilities: ['SystemCapability.Collaboration.HarmonyShare'] };
  assert.equal(f.runtime.decision(id, context).executable, false);
  f.runtime.setDebugMode('pro'); assert.equal(f.runtime.decision(id, context).executable, true);
  for (const patch of [{ device: 'phone' }, { apiVersion: 23 }, { protocol: 'rdp' }, { capabilities: [] }]) {
    assert.equal(f.runtime.decision(id, { ...context, ...patch }).executable, false);
  }
  f.runtime.setDebugMode('free'); assert.equal(f.runtime.decision(id, context).visible, false);
  const release = fixture(false); release.runtime.setDebugMode('pro');
  assert.equal(release.runtime.decision(id, context).visible, false);
  f.runtime.dispose(); release.runtime.dispose();
});
(async () => {
  for (const test of tests) { await test.body(); process.stdout.write('PASS ' + test.name + '\n'); }
  process.stdout.write('PASS ' + tests.length + ' Pro policy/runtime checks\n');
})().catch(error => { console.error(error); process.exitCode = 1; });
