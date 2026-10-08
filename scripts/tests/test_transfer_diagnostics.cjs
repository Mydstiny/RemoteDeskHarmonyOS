/* Production diagnostic policy and the service's actual throttled publish path.
 * Host-only tests; no OS notification or device performance acceptance implied.
 */
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TRANSFER_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const tests = [], test = (name, run) => tests.push({ name, run });

function environment() {
  const cache = new Map(), logs = [], updates = [], observed = [];
  let now = 1000, failLog = false;
  class FakeDate extends Date { static now() { return now; } }
  class Store { list() { observed.push('list'); return []; } setActivePredicate() {} }
  const live = { update(value) { updates.push(value); return Promise.resolve(); } };
  function load(relative) {
    const file = path.resolve(root, relative);
    if (cache.has(file)) return cache.get(file).exports;
    const module = { exports: {} }; cache.set(file, module);
    const output = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
    }).outputText;
    function requireEts(id) {
      if (id === '@kit.BasicServicesKit') return { deviceInfo: { deviceType: 'phone' } };
      if (id === '@kit.ArkTS') return { util: { generateRandomUUID: () => 'fixture-task' } };
      if (id === '@kit.PerformanceAnalysisKit') {
        const log = level => (...args) => {
          if (failLog) throw Error('diagnostic backend failed');
          assert.equal(args[2], '%{public}s');
          logs.push({ level, line: args[3] });
        };
        return { hilog: { info: log('info'), debug: log('debug') } };
      }
      if (id === './ManagedTransferTaskStore') return { ManagedTransferTaskStore: Store };
      if (id === './FileTransferLiveTaskService') return { FileTransferLiveTaskService: { getInstance: () => live } };
      if (!id.startsWith('.')) throw Error('Unexpected dependency: ' + id);
      return load(path.resolve(path.dirname(file), id + '.ets'));
    }
    vm.runInNewContext(output, { module, exports: module.exports, require: requireEts, Date: FakeDate,
      setInterval() { throw Error('publish must not create another timer'); }, clearInterval() {} }, { filename: file });
    return module.exports;
  }
  const policy = load('entry/src/main/ets/services/TransferDiagnosticPolicy.ets');
  const { ManagedTransferTaskService } = load('entry/src/main/ets/services/ManagedTransferTaskService.ets');
  return { policy, Service: ManagedTransferTaskService, logs, updates, observed,
    time(value) { now = value; }, fail(value) { failLog = value; } };
}

function record(overrides = {}) {
  return { taskId: 'private-task-789', attemptId: 3, accountScopeId: 'private-account-456', hostId: 'private-host-123',
    protocol: 'rustdesk', direction: 'upload', sourceKind: 'authorized-file', leaseId: '7.3.9',
    stage: 'transferring', readBytes: 131072, sentBytes: 65536, writtenBytes: 0, verifiedBytes: 0,
    totalBytes: 2 * 1024 * 1024 * 1024, evidence: 'none', diagnosticCode: '',
    fileName: 'private-name.txt', sourceUri: 'file:///private/name.txt', clipboard: 'private clipboard text',
    token: 'private-token-012', ...overrides };
}

test('normal projection emits only fixed diagnostic scalars and keeps actual byte evidence', () => {
  const { policy } = environment(); const value = JSON.parse(policy.transferDiagnosticLine(record()));
  assert.deepEqual(Object.keys(value), ['task','attempt','hostScope','protocol','direction','sourceKind','leaseGeneration',
    'stage','readBytes','sentBytes','writtenBytes','verifiedBytes','totalBytes','code','evidence']);
  assert.match(value.task, /^task-[0-9a-f]{8}$/); assert.match(value.hostScope, /^host-[0-9a-f]{8}$/);
  assert.equal(value.attempt, 3); assert.equal(value.protocol, 'rustdesk'); assert.equal(value.direction, 'upload');
  assert.equal(value.leaseGeneration, '7:3:9'); assert.equal(value.readBytes, 131072); assert.equal(value.sentBytes, 65536);
  assert.equal(value.totalBytes, 2147483648); assert.equal(value.code, 'none'); assert.equal(value.evidence, 'none');
});

test('sensitive source data, safe-looking injected strings and custom toJSON never enter logs', () => {
  const { policy } = environment(); const input = record({ sourceKind: 'sensitive_source_label',
    diagnosticCode: 'sensitive_bearer_token', stage: 'private_stage_value', evidence: 'private_evidence_value' });
  Object.defineProperty(input, 'toJSON', { value() { throw Error('Original record serialized'); } });
  Object.defineProperty(input, 'path', { get() { throw Error('Unlisted field read'); } });
  const line = policy.transferDiagnosticLine(input), value = JSON.parse(line);
  for (const secret of [input.taskId, input.accountScopeId, input.hostId, input.fileName, input.sourceUri,
    input.clipboard, input.token, input.sourceKind, input.diagnosticCode, input.stage, input.evidence]) {
    assert.equal(line.includes(secret), false, secret);
  }
  assert.equal(value.sourceKind, 'other'); assert.equal(value.code, 'other');
  assert.equal(value.stage, 'unknown'); assert.equal(value.evidence, 'unknown'); assert.ok(line.length < 800);
});

test('host scope is stable and separates account host and ambiguous component boundaries', () => {
  const { policy } = environment(); const project = input => policy.projectTransferDiagnostic(input);
  const first = project(record()); assert.equal(first.hostScope, project(record()).hostScope);
  assert.notEqual(first.hostScope, project(record({ hostId: 'different-host' })).hostScope);
  assert.notEqual(first.hostScope, project(record({ accountScopeId: 'different-account' })).hostScope);
  assert.notEqual(project(record({ accountScopeId: 'ab', hostId: 'c' })).hostScope,
    project(record({ accountScopeId: 'a', hostId: 'bc' })).hostScope);
  assert.equal(first.hostScope, project(record({ taskId: 'different-task' })).hostScope);
  assert.notEqual(first.task, project(record({ taskId: 'different-task' })).task);
  assert.equal(project(record({ hostId: 'x'.repeat(1025) })).hostScope, 'unknown');
  // Hosts synced from RustDesk Pro have long URL-encoded ids; they are hashed like any other.
  assert.match(project(record({ hostId: 'rdpro_' + encodeURIComponent('relay:acct:123 456') })).hostScope, /^host-[0-9a-f]{8}$/);
});

test('lease accepts only bounded safe numeric generations and never echoes host or window identity', () => {
  const { policy } = environment();
  for (const leaseId of ['', 'host-private:7', 'window-9:7', '7/path', '7\n9', '7:8:9:10:11',
    '9007199254740992', '1e9', '1.5e2', '-1', '1'.repeat(68), { toString() { throw Error('coercion'); } }]) {
    assert.equal(policy.projectTransferDiagnostic(record({ leaseId })).leaseGeneration, 'unknown');
  }
  assert.equal(policy.projectTransferDiagnostic(record({ leaseId: '0007:03_9-2' })).leaseGeneration, '7:3:9:2');
  assert.equal(policy.projectTransferDiagnostic(record({ leaseId: '9007199254740991' })).leaseGeneration, '9007199254740991');
});

test('numeric and enum validation rejects malformed values without coercion or field injection', () => {
  const { policy } = environment();
  for (const invalid of [-1, 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, '123', null]) {
    const value = policy.projectTransferDiagnostic(record({ attemptId: invalid, readBytes: invalid,
      sentBytes: invalid, writtenBytes: invalid, verifiedBytes: invalid, totalBytes: invalid }));
    for (const key of ['attempt','readBytes','sentBytes','writtenBytes','verifiedBytes','totalBytes']) assert.equal(value[key], 0);
  }
  const value = policy.projectTransferDiagnostic(record({ protocol: 'rdp\n"token":"secret"', direction: 'download/private',
    diagnosticCode: 'receive_failed', sourceKind: 'deferred-drop', evidence: 'metadataVerified' }));
  assert.equal(value.protocol, 'unknown'); assert.equal(value.direction, 'unknown'); assert.equal(value.code, 'receive_failed');
  assert.equal(value.sourceKind, 'deferred-drop'); assert.equal(value.evidence, 'metadataVerified');
  assert.equal(policy.projectTransferDiagnostic(record({ sourceKind: 'file-picker' })).sourceKind, 'file-picker');
});

test('actual service publish logs at the existing 250ms gate and sends immediate terminal INFO', () => {
  const env = environment(), service = new env.Service(), runtime = { record: record(), lastPublishedAt: 0 };
  service.publish(runtime, false); assert.equal(env.logs.length, 1); assert.equal(env.logs[0].level, 'debug');
  for (let time = 1001; time < 1250; time++) { env.time(time); runtime.record.sentBytes++; service.publish(runtime, false); }
  assert.equal(env.logs.length, 1); assert.equal(env.updates.length, 1);
  env.time(1250); service.publish(runtime, false); assert.equal(env.logs.length, 2);
  env.time(1251); runtime.record.stage = 'completed'; runtime.record.evidence = 'metadataVerified';
  service.publish(runtime, true); assert.equal(env.logs.length, 3); assert.equal(env.logs[2].level, 'info');
  assert.equal(JSON.parse(env.logs[2].line).stage, 'completed'); assert.equal(env.updates.length, 2);
});

test('logger and projection exceptions leave service observers and notification updates usable', () => {
  const env = environment(), service = new env.Service(), runtime = { record: record(), lastPublishedAt: 0 };
  let observed = 0; service.listeners.push({ accountScopeId: runtime.record.accountScopeId, listener() { observed++; } });
  env.fail(true); assert.doesNotThrow(() => service.publish(runtime, false));
  assert.equal(observed, 1); assert.equal(env.updates.length, 1);
  env.time(1250); env.fail(false);
  Object.defineProperty(runtime.record, 'leaseId', { get() { throw Error('projection failed'); } });
  assert.doesNotThrow(() => service.publish(runtime, false)); assert.equal(observed, 2); assert.equal(env.updates.length, 2);
  assert.equal(env.logs.length, 0);
});

(async () => { for (const item of tests) { await item.run(); console.log('PASS ' + item.name); }
  console.log(`PASS ${tests.length} transfer diagnostic regressions`);
})().catch(error => { console.error(error); process.exitCode = 1; });
