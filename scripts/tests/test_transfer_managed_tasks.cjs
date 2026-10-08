/* Production ETS managed-task/live-task regressions with fake Harmony ports.
 * TRANSFER_TYPESCRIPT_PATH=<DevEco typescript module> node scripts/tests/test_transfer_managed_tasks.cjs
 */
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TRANSFER_TYPESCRIPT_PATH || process.env.SSH_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const tests = [], test = (name, run) => tests.push({ name, run });
async function drain() { for (let i = 0; i < 80; i++) await Promise.resolve(); }
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { resolve, reject, promise }; }
function environment(seed = new Map(), deviceType = '2in1') {
  const cache = new Map(), timers = new Map(), starts = [], stops = [], notifications = [], startContexts = [], stopContexts = [];
  let now = 100000, timer = 0, task = 0, uuid = 0, startGate = null;
  let stopFailures = 0, prefFailure = false, flushFailure = false, publishFailure = false;
  const prefs = { getSync: (key, fallback) => seed.get(key) ?? fallback,
    putSync: (key, value) => seed.set(key, value), flush: async () => { if (flushFailure) throw Error('disk unavailable'); } };
  const context = { abilityInfo: { bundleName: 'fixture', name: 'EntryAbility' } };
  const background = {
    ContinuousTaskRequest: class {}, BackgroundTaskMode: { MODE_DATA_TRANSFER: 1 },
    async startBackgroundRunning(_context, request) {
      assert.equal(arguments.length, 2, 'must use independent API21 request overload');
      assert.deepEqual(Array.from(request.backgroundTaskModes), [1]);
      const id = ++task; starts.push(id); startContexts.push(_context); if (startGate) await startGate.promise;
      return { continuousTaskId: id, notificationId: 1000 + id };
    },
    async stopBackgroundRunning(_context, id) { assert.equal(typeof id, 'number'); stops.push(id); stopContexts.push(_context);
      if (stopFailures > 0) { stopFailures--; throw { code: 9800004 }; } }
  };
  class FakeDate extends Date { static now() { return now; } }
  function load(file) {
    file = path.resolve(root, file); if (cache.has(file)) return cache.get(file).exports;
    const module = { exports: {} }; cache.set(file, module);
    const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
    }).outputText;
    function requireEts(id) {
      if (id === '@kit.ArkTS') return { util: { generateRandomUUID: () => 'task-' + (++uuid) } };
      if (id === '@kit.ArkData') return { preferences: { getPreferencesSync: () => {
        if (prefFailure) throw Error('preferences unavailable'); return prefs;
      } } };
      if (id === '@kit.AbilityKit') return { wantAgent: { getWantAgent: async () => ({}),
        OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 } } };
      if (id === '@kit.BackgroundTasksKit') return { backgroundTaskManager: background };
      if (id === '@kit.BasicServicesKit') return { deviceInfo: { deviceType } };
      if (id === '@kit.PerformanceAnalysisKit') return { hilog: { info() {}, warn() {} } };
      if (id === '@kit.NotificationKit') return { notificationManager: { publish: async request => {
        if (publishFailure) throw { code: 201 }; notifications.push(request);
      }, ContentType: { NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW: 1, NOTIFICATION_CONTENT_BASIC_TEXT: 2 },
      SlotType: { LIVE_VIEW: 1, SERVICE_INFORMATION: 2 } } };
      if (!id.startsWith('.')) throw Error('Unexpected module ' + id);
      return load(path.resolve(path.dirname(file), id + '.ets'));
    }
    vm.runInNewContext(code, { module, exports: module.exports, require: requireEts, Date: FakeDate,
      setTimeout(callback, delay) { timers.set(++timer, { callback, at: now + delay, repeat: false, delay }); return timer; },
      clearTimeout(id) { timers.delete(id); },
      setInterval(callback, delay) { timers.set(++timer, { callback, at: now + delay, repeat: true, delay }); return timer; },
      clearInterval(id) { timers.delete(id); }
    }, { filename: file }); return module.exports;
  }
  const { ManagedTransferTaskService: Service } = load('entry/src/main/ets/services/ManagedTransferTaskService.ets');
  const { ManagedTransferTaskStore: Store } = load('entry/src/main/ets/services/ManagedTransferTaskStore.ets');
  const { FileTransferLiveTaskService: Live } = load('entry/src/main/ets/services/FileTransferLiveTaskService.ets');
  const model = load('entry/src/main/ets/services/FileTransferProgressModel.ets');
  const policy = load('entry/src/main/ets/services/ManagedTransferTaskPolicy.ets');
  return { Service, Store, Live, model, policy, context, starts, stops, startContexts, stopContexts, notifications, seed,
    service() { const service = new Service(); assert.equal(service.init(context), true); return service; },
    advance(ms) { now += ms; for (const [id, value] of Array.from(timers)) if (value.at <= now) {
      if (!value.repeat) timers.delete(id); else value.at = now + value.delay; value.callback();
    } }, gateStarts(gate) { startGate = gate; }, failStops(count) { stopFailures = count; },
    failPreferences(value) { prefFailure = value; }, failFlush(value) { flushFailure = value; },
    failPublish(value) { publishFailure = value; }
  };
}
const options = (extra = {}) => ({ accountScopeId: 'account-a', hostId: 'host-a', protocol: 'rustdesk',
  direction: 'upload', fileName: 'example.bin', totalBytes: 8, isCurrent: () => true, ...extra });
const outcome = (stage = 'completed', evidence = 'senderCompleted') => ({ stage, evidence });

test('finish during asynchronous begin waits for exact task ID and finalizes once', async () => {
  const env = environment(), live = new env.Live(), gate = deferred(); env.gateStarts(gate);
  const first = env.model.createTransferSnapshot('one', 'rdp', 'file', 0, 8, 'preparing');
  const final = env.model.createTransferSnapshot('one', 'rdp', 'file', 8, 8, 'completed');
  const begin = live.begin(env.context, first); await drain();
  const end = live.complete(env.context, final), duplicate = live.fail(env.context, final);
  await drain(); assert.deepEqual(env.stops, []); gate.resolve(); await Promise.all([begin, end, duplicate]);
  assert.deepEqual(env.starts, [1]); assert.deepEqual(env.stops, [1]);
  assert.equal(env.notifications.length, 1); assert.equal(live.activeTasks.size, 0);
});
test('duplicate begin shares startup while attempts and accounts remain isolated', async () => {
  const env = environment(), live = new env.Live(), first = env.model.createTransferSnapshot('same', 'rdp', 'file', 0, 8, 'preparing');
  first.attemptId = 1; first.accountScopeId = 'a';
  const second = { ...first, attemptId: 2 }, other = { ...first, accountScopeId: 'b' };
  await Promise.all([live.begin(env.context, first), live.begin(env.context, first),
    live.begin(env.context, second), live.begin(env.context, other)]);
  assert.equal(env.starts.length, 3);
  await live.complete(env.context, first); assert.equal(live.activeTasks.size, 2);
  await live.complete(env.context, second); await live.complete(env.context, other); assert.equal(env.stops.length, 3);
});
test('failed scoped background stop remains owned and retries without stopping unrelated tasks', async () => {
  const env = environment(), live = new env.Live(), snapshot = env.model.createTransferSnapshot('stop', 'rdp', 'file', 0, 1, 'preparing');
  await live.begin(env.context, snapshot); env.failStops(1); await live.complete(env.context, { ...snapshot, state: 'cancelled' });
  assert.equal(live.activeTasks.size, 1); env.advance(1000); await drain();
  assert.equal(live.activeTasks.size, 0); assert.deepEqual(env.stops, [1, 1]);
});
test('task progress uses actual bytes; sender-complete remains explicitly unverified', async () => {
  const env = environment(), service = env.service(); let control; const gate = deferred();
  const handle = service.enqueue(options(), async c => { control = c; return gate.promise; }); await drain();
  assert.equal(control.update({ stage: 'transferring', readBytes: 8, sentBytes: 3 }), true);
  assert.equal(control.update({ sentBytes: 2 }), false); assert.equal(control.update({ sentBytes: 9 }), false);
  assert.equal(control.update({ stage: 'preparing' }), false);
  assert.equal(service.list('account-a')[0].sentBytes, 3);
  control.update({ sentBytes: 8 }); gate.resolve(outcome()); assert.equal((await handle.result).evidence, 'senderCompleted'); await drain();
  assert.equal(service.list('account-a')[0].stage, 'completed'); assert.equal(env.stops.length, 1);
  const final = env.notifications.at(-1); assert.match(final.content.systemLiveView.text, /尚未验证/);
});
test('cancel callback is invoked once and source cleanup waits for runner drain', async () => {
  const env = environment(), service = env.service(), gate = deferred(); let cancels = 0, finalized = 0, control;
  const handle = service.enqueue(options({ onFinalize: () => { finalized++; } }), async c => {
    control = c; c.onCancel(() => { cancels++; }); return gate.promise;
  }); await drain();
  assert.equal(service.cancel('account-b', handle.taskId, 1), false);
  service.cancel('account-a', handle.taskId, 1); service.cancel('account-a', handle.taskId, 1);
  assert.equal(cancels, 1); assert.equal(finalized, 0); assert.equal(control.update({ sentBytes: 1 }), false);
  gate.resolve(outcome('cancelled', 'none')); assert.equal((await handle.result).stage, 'cancelled'); await drain();
  assert.equal(finalized, 1); assert.equal(service.active.size, 0);
});
test('no page-style 30 second deadline; idle expiry has owned drain state and late success refines it', async () => {
  const env = environment(), service = env.service(), gate = deferred(); let control, finalized = 0;
  const handle = service.enqueue(options({ onFinalize: () => { finalized++; } }), async c => { control = c; return gate.promise; });
  await drain(); env.advance(31000); await drain(); assert.equal(control.isCurrent(), true);
  control.update({ stage: 'transferring', sentBytes: 8 });
  env.advance(300000); await drain(); assert.equal(control.isCancellationRequested(), true);
  env.advance(5000); await drain(); assert.equal((await handle.result).stage, 'commitUnknown');
  assert.equal(finalized, 0); assert.equal(service.active.size, 1);
  gate.resolve(outcome()); await drain();
  assert.equal(service.list('account-a')[0].stage, 'completed'); assert.equal(finalized, 1); assert.equal(service.active.size, 0);
});
test('commit success wins cancellation; crash during cancelling after enterCommit recovers unknown', async () => {
  const env = environment(), service = env.service(), gate = deferred(); let control;
  const handle = service.enqueue(options(), async c => { control = c; return gate.promise; }); await drain();
  control.update({ stage: 'transferring', sentBytes: 8 }); assert.equal(await control.enterCommit(), true);
  service.cancel('account-a', handle.taskId, 1); await service.store.flush();
  const restored = new env.Store(); restored.init(env.context);
  assert.equal(restored.list('account-a')[0].stage, 'commitUnknown');
  gate.resolve(outcome('completed', 'contentVerified')); assert.equal((await handle.result).stage, 'completed'); await drain();
});
test('account manifests are isolated, minimally projected, immutable to subscribers and never auto-resumed', async () => {
  const env = environment(), service = env.service(), gate = deferred(); let callbacks = 0;
  service.subscribe('account-b', records => { callbacks++; assert.equal(records.length, 0); });
  service.enqueue(options({ sourceKind: 'picker', leaseId: 'lease-hash', batchId: 'artifact-batch',
    ignoredSecret: 'must-not-persist', onFinalize: () => {} }), () => gate.promise); await drain();
  const listed = service.list('account-a'); listed[0].fileName = 'mutated'; assert.equal(service.list('account-a')[0].fileName, 'example.bin');
  await service.store.flush(); const serialized = env.seed.get('account:account-a');
  assert.equal(serialized.includes('must-not-persist'), false); assert.equal(serialized.includes('isCurrent'), false);
  const restored = new env.Store(); restored.init(env.context); assert.equal(restored.list('account-a')[0].stage, 'interrupted');
  assert.equal(restored.list('account-b').length, 0); assert.equal(callbacks, 1); assert.equal(env.starts.length, 1);
  gate.resolve(outcome('cancelled', 'none')); await drain();
});
test('storage failure refuses execution and preserves unreadable manifests', async () => {
  const env = environment(), service = env.service(); let runs = 0;
  env.seed.set('account:account-a', '{broken-json');
  const rejected = service.enqueue(options(), async () => { runs++; return outcome(); });
  assert.equal((await rejected.result).stage, 'failed'); assert.equal(runs, 0);
  assert.equal(env.seed.get('account:account-a'), '{broken-json');
  env.failPreferences(true); const unavailable = new env.Service(); assert.equal(unavailable.init(env.context), false);
});
test('failed initial manifest flush prevents runner and finalizes resources once', async () => {
  const env = environment(), service = env.service(); let runs = 0, finalized = 0;
  env.failFlush(true); const handle = service.enqueue(options({ onFinalize: () => { finalized++; } }), async () => { runs++; return outcome(); });
  assert.equal((await handle.result).stage, 'failed'); await drain(); assert.equal(runs, 0); assert.equal(finalized, 1);
});
test('bounded queue cancels waiting task without starting it and fences old attempt callbacks', async () => {
  const env = environment(), service = env.service(), first = deferred(); service.setConcurrency(1);
  let oldControl, secondRuns = 0, finalizes = 0;
  const a = service.enqueue(options({ taskId: 'stable' }), async c => { oldControl = c; return first.promise; });
  const b = service.enqueue(options({ taskId: 'queued', onFinalize: () => { finalizes++; } }), async () => { secondRuns++; return outcome(); });
  await drain(); service.cancel('account-a', 'queued', 1); assert.equal((await b.result).stage, 'cancelled'); await drain();
  assert.equal(secondRuns, 0); assert.equal(finalizes, 1);
  first.resolve(outcome('failed', 'none')); await a.result; await drain();
  const next = deferred(); const retry = service.enqueue(options({ taskId: 'stable', attemptId: 2 }), () => next.promise); await drain();
  assert.equal(oldControl.update({ sentBytes: 7 }), false); assert.equal(service.list('account-a').find(x => x.attemptId === 2).sentBytes, 0);
  next.resolve(outcome('cancelled', 'none')); await retry.result; await drain();
});
test('completion Promise waits for asynchronous finalize and callbacks cannot finalize twice', async () => {
  const env = environment(), service = env.service(), cleanup = deferred(); let settled = false, calls = 0;
  const handle = service.enqueue(options({ onFinalize: async () => { calls++; await cleanup.promise; } }),
    async c => { c.update({ stage: 'transferring', sentBytes: 8 }); return outcome(); });
  handle.result.then(() => { settled = true; }); await drain(); assert.equal(settled, false); assert.equal(calls, 1);
  cleanup.resolve(); await handle.result; await drain(); assert.equal(settled, true); assert.equal(calls, 1);
});
test('each task stops background work with its original window context', async () => {
  const env = environment(), service = env.service(), first = deferred(), second = deferred();
  const a = service.enqueue(options(), () => first.promise); await drain();
  const otherContext = { abilityInfo: { bundleName: 'fixture', name: 'SecondWindow' } };
  service.init(otherContext); const b = service.enqueue(options({ taskId: 'window-b' }), () => second.promise); await drain();
  first.resolve(outcome('cancelled', 'none')); await a.result;
  second.resolve(outcome('cancelled', 'none')); await b.result;
  assert.equal(env.startContexts[0], env.context); assert.equal(env.stopContexts[0], env.context);
  assert.equal(env.startContexts[1], otherContext); assert.equal(env.stopContexts[1], otherContext);
});
test('offer admission alone cannot be completed and commit manifest must flush before approval', async () => {
  const env = environment(), service = env.service();
  const offer = service.enqueue(options(), async () => outcome('completed', 'offered'));
  assert.equal((await offer.result).diagnosticCode, 'invalid_completion_evidence');
  const gate = deferred(); let control;
  const handle = service.enqueue(options({ taskId: 'commit-test' }), async c => { control = c; return gate.promise; }); await drain();
  env.failFlush(true); assert.equal(await control.enterCommit(), false);
  env.failFlush(false); gate.resolve(outcome('failed', 'none')); await handle.result;
});
test('revoked lease before runner start is rejected and corrupted account records are preserved', async () => {
  const env = environment(), service = env.service(); let runs = 0;
  const rejected = service.enqueue(options({ isCurrent: () => false }), async () => { runs++; return outcome(); });
  assert.equal(rejected.accepted, false); await rejected.result; assert.equal(runs, 0);
  const corrupted = new Map([['account:account-a', '123']]); const other = environment(corrupted), otherService = other.service();
  const invalid = otherService.enqueue(options(), async () => { runs++; return outcome(); });
  assert.equal(invalid.accepted, false); assert.equal(corrupted.get('account:account-a'), '123');
});
test('notification rejection cannot fail successful data transfer', async () => {
  const env = environment(), service = env.service(); env.failPublish(true);
  const handle = service.enqueue(options(), async c => { c.update({ stage: 'transferring', sentBytes: 8 }); return outcome(); });
  assert.equal((await handle.result).stage, 'completed'); await drain(); assert.equal(env.stops.length, 1);
});
test('phone defaults to one active data task while PC admits two', async () => {
  for (const [deviceType, expected] of [['phone', 1], ['2in1', 2]]) {
    const env = environment(new Map(), deviceType), service = env.service(), gate = deferred(); let active = 0;
    const handles = [1,2,3].map(i => service.enqueue(options({taskId:'budget-'+i}), async () => { active++; return gate.promise; }));
    await drain(); assert.equal(active, expected); gate.resolve(outcome());
    await Promise.all(handles.map(h=>h.result)); await drain(); assert.equal(env.stops.length,3);
  }
});
test('100 queued attempts converge exactly once with isolated progress and notifications', async () => {
  const env = environment(), service = env.service(); let finalized=0;
  const handles = Array.from({length:100},(_,i)=>service.enqueue(options({taskId:'replay-'+i,onFinalize:()=>{finalized++;}}),async c=>{
    c.update({stage:'transferring',sentBytes:4}); await Promise.resolve();
    c.update({sentBytes:8}); return outcome();
  }));
  const results=await Promise.all(handles.map(h=>h.result)); await drain();
  assert.equal(results.filter(r=>r.stage==='completed').length,100);assert.equal(finalized,100);
  assert.equal(new Set(env.starts).size,100);assert.equal(new Set(env.stops).size,100);
  assert.equal(service.active.size,0);assert.equal(service.queue.length,0);
});
test('different sessions run side by side; one session queues; local saves have their own lane', async () => {
  const env = environment(new Map(), 'tablet'), service = env.service(), gate = deferred(); let started = [];
  const run = name => async () => { started.push(name); return gate.promise; };
  const a1 = service.enqueue(options({ taskId: 'a1', queueKey: 'session-a' }), run('a1'));
  const a2 = service.enqueue(options({ taskId: 'a2', queueKey: 'session-a' }), run('a2'));
  const b1 = service.enqueue(options({ taskId: 'b1', queueKey: 'session-b' }), run('b1'));
  const save = service.enqueue(options({ taskId: 's1', local: true, direction: 'download' }), run('s1'));
  await drain(); assert.deepEqual(started.sort(), ['a1', 'b1', 's1']);
  assert.equal(service.isQueued('account-a', 'a2', 1), true); assert.equal(service.isQueued('account-a', 'a1', 1), false);
  gate.resolve(outcome()); await Promise.all([a1, a2, b1, save].map(h => h.result)); await drain();
  assert.equal(started.length, 4); assert.equal(service.isQueued('account-a', 'a2', 1), false);
});
test('saving received data ignores cancel and disconnect; the next file of the task may follow', async () => {
  const env = environment(), service = env.service(), gate = deferred(); let control, current = true;
  const handle = service.enqueue(options({ direction: 'download', isCurrent: () => current }), async c => { control = c; return gate.promise; });
  await drain(); assert.equal(control.update({ stage: 'transferring', writtenBytes: 4 }), true);
  assert.equal(control.update({ stage: 'verifying' }), true); assert.equal(await control.enterCommit(), true);
  assert.equal(service.cancel('account-a', handle.taskId, 1), false);
  current = false; env.advance(10000); await drain();
  assert.equal(control.isCurrent(), true); assert.equal(control.isCancellationRequested(), false);
  // The first file is saved; the next one transfers, and from then on the session counts again.
  assert.equal(control.update({ stage: 'transferring', writtenBytes: 6 }), true);
  env.advance(1000); await drain(); assert.equal(control.isCancellationRequested(), true);
  gate.resolve(outcome('cancelled', 'none')); assert.equal((await handle.result).stage, 'cancelled'); await drain();
});
test('new network bytes after a saved file end the save phase even without a stage update', async () => {
  const env = environment(), service = env.service(), gate = deferred(); let control, current = true;
  const handle = service.enqueue(options({ direction: 'download', isCurrent: () => current }), async c => { control = c; return gate.promise; });
  await drain(); control.update({ stage: 'transferring', writtenBytes: 2 }); assert.equal(await control.enterCommit(), true);
  assert.equal(service.isCancellable('account-a', handle.taskId, 1), false);
  assert.equal(control.update({ writtenBytes: 5 }), true);
  assert.equal(service.list('account-a')[0].stage, 'transferring');
  assert.equal(service.isCancellable('account-a', handle.taskId, 1), true);
  current = false; env.advance(1000); await drain(); assert.equal(control.isCancellationRequested(), true);
  gate.resolve(outcome('cancelled', 'none')); await handle.result; await drain();
});
test('a local save stays cancellable while it writes and does not depend on the session', async () => {
  const env = environment(), service = env.service(), gate = deferred(); let control;
  const handle = service.enqueue(options({ local: true, direction: 'download' }), async c => { control = c; return gate.promise; });
  await drain(); assert.equal(await control.enterCommit(), true);
  assert.equal(service.cancel('account-a', handle.taskId, 1), true); assert.equal(control.isCurrent(), false);
  gate.resolve(outcome('cancelled', 'none')); await handle.result; await drain();
});
test('the idle clock stops while the app is in the background', async () => {
  const env = environment(), service = env.service(), gate = deferred(); let control;
  const handle = service.enqueue(options(), async c => { control = c; return gate.promise; }); await drain();
  service.setAppInBackground(true); env.advance(600000); await drain(); assert.equal(control.isCancellationRequested(), false);
  service.setAppInBackground(false); env.advance(301000); await drain(); assert.equal(control.isCancellationRequested(), true);
  gate.resolve(outcome('cancelled', 'none')); await handle.result; await drain();
});
test('records found at start are settled: offers handed off, saves unknown, the rest interrupted', async () => {
  const env = environment(), policy = env.policy;
  const make = (taskId, stage, extra = {}) => Object.assign(new policy.ManagedTransferRecord(), { schemaVersion: 1,
    taskId, accountScopeId: 'account-a', hostId: 'host-a', fileName: 'a.bin', stage, createdAt: 99000, updatedAt: 99000 }, extra);
  env.seed.set('account:account-a', JSON.stringify([
    make('offer', 'paused', { evidence: 'offered', diagnosticCode: 'target_write_unconfirmed' }),
    make('saving', 'committing', { commitStarted: true }), make('running', 'transferring'),
    make('waiting', 'paused', { diagnosticCode: 'offer_ack_unconfirmed' }), { broken: true }]));
  const store = new env.Store(); store.init(env.context);
  const byId = new Map(store.list('account-a').map(r => [r.taskId, r]));
  assert.equal(byId.size, 4);
  assert.equal(byId.get('offer').stage, 'handedOff'); assert.equal(byId.get('saving').stage, 'commitUnknown');
  assert.equal(byId.get('running').stage, 'interrupted'); assert.equal(byId.get('running').diagnosticCode, 'interrupted');
  assert.equal(byId.get('waiting').stage, 'interrupted'); assert.equal(byId.get('waiting').diagnosticCode, 'offer_ack_unconfirmed');
  for (const stage of ['handedOff', 'interrupted', 'commitUnknown', 'paused', 'completed']) assert.equal(policy.managedTransferSettled(stage), true);
  assert.equal(policy.managedTransferSettled('transferring'), false);
});
test('the oldest settled records make room; running tasks and old records are handled', async () => {
  const env = environment(), service = env.service(), policy = env.policy, gate = deferred();
  const make = (i, stage, updatedAt) => Object.assign(new policy.ManagedTransferRecord(), { taskId: 'old-' + i,
    accountScopeId: 'account-a', hostId: i % 2 === 0 ? 'host-a' : 'host-b', fileName: 'a.bin', stage, createdAt: updatedAt, updatedAt });
  const seeded = []; for (let i = 0; i < 512; i++) seeded.push(make(i, 'completed', 99000 + i));
  seeded.push(make(999, 'completed', 99000 - 15 * 24 * 60 * 60 * 1000));
  env.seed.set('account:account-a', JSON.stringify(seeded));
  assert.equal(service.list('account-a').length, 512);
  const handle = service.enqueue(options({ taskId: 'fresh' }), () => gate.promise); assert.equal(handle.accepted, true); await drain();
  const ids = service.list('account-a').map(r => r.taskId);
  assert.equal(ids.length, 512); assert.equal(ids.includes('old-0'), false); assert.equal(ids.includes('fresh'), true);
  const removed = service.clearFinished('account-a', 'host-a');
  assert.ok(removed > 0); assert.equal(service.list('account-a').some(r => r.hostId === 'host-a' && r.taskId !== 'fresh'), false);
  assert.equal(service.list('account-a').some(r => r.taskId === 'fresh'), true);
  gate.resolve(outcome('cancelled', 'none')); await handle.result; await drain();
});
test('progress ticks persist at most every five seconds; stage changes persist at once', async () => {
  const env = environment(), service = env.service(), gate = deferred(); let control;
  const handle = service.enqueue(options({ totalBytes: 100 }), async c => { control = c; return gate.promise; }); await drain();
  control.update({ stage: 'transferring', sentBytes: 1 }); env.advance(300); await drain();
  const persisted = () => JSON.parse(env.seed.get('account:account-a'))[0];
  assert.equal(persisted().stage, 'transferring');
  control.update({ sentBytes: 2 }); env.advance(300); await drain(); assert.equal(persisted().sentBytes, 1);
  env.advance(5000); control.update({ sentBytes: 3 }); env.advance(300); await drain(); assert.equal(persisted().sentBytes, 3);
  gate.resolve(outcome('cancelled', 'none')); await handle.result; await drain();
});
(async () => {
  for (const { name, run } of tests) { await run(); console.log('PASS ' + name); }
  console.log(`PASS ${tests.length} managed transfer regressions`);
})().catch(error => { console.error(error); process.exitCode = 1; });
