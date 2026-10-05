/* Executes the production ArkTS side of RDP security-key redirection (ProRdpSecurityKey.ets) against a scripted
 * session broker and USB key: prompts, dismissals, PIN rules, key claims and page handoff. Not device acceptance. */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const tests = [];
function test(name, body) { tests.push({ name, body }); }
async function settle() { for (let i = 0; i < 20; i++) await Promise.resolve(); }

function fixture() {
  const state = { available: true, executable: true, watchId: 0, owner: 0, queue: [], responses: [], cancels: 0,
    released: 0, unwatches: [], wake: null, respondResult: true, subscribers: [], authorizations: [],
    keyReleases: [], authorize: null, transfers: [] };
  const napi = {
    rdpSecurityKeyAvailable: () => state.available,
    rdpSecurityKeyWatch(sessionId, wake) {
      if (state.watchId === 0) return 0;
      state.owner = state.watchId; state.wake = wake; return state.watchId;
    },
    rdpSecurityKeyUnwatch(sessionId, watchId) {
      state.unwatches.push(watchId);
      if (watchId !== state.owner) return false;
      state.owner = 0; return true;
    },
    rdpSecurityKeyPoll: () => state.queue.length > 0 ? state.queue.shift() : null,
    rdpSecurityKeyRespond(sessionId, id, ok, report, text) {
      state.responses.push({ id, ok, report, text }); return state.respondResult;
    },
    rdpSecurityKeyCancel() { state.cancels++; },
    rdpSecurityKeyReleased() { state.released++; }
  };
  const runtime = {
    decision: () => ({ executable: state.executable }),
    subscribe(callback) { state.subscribers.push(callback); return () => {
      state.subscribers = state.subscribers.filter((item) => item !== callback); }; }
  };
  class ProUsbFidoKeySession {
    constructor(label) { this.label = label; this.open = true; }
    transfer(write, data, timeoutMs) {
      state.transfers.push({ write, timeoutMs, first: data[0] });
      const reply = new Uint8Array(64); reply[0] = 0x42; return Promise.resolve(write ? data : reply);
    }
    release() { this.open = false; state.keyReleases.push(this.label); }
  }
  class ProUsbFidoKeys {
    list() { return [{ key: 'k1', label: 'YubiKey 5' }]; }
    authorize(key, isCurrent) {
      state.authorizations.push({ key, released: state.keyReleases.length });
      return new Promise((resolve, reject) => { state.authorize = { resolve, reject, isCurrent }; });
    }
  }
  const mocks = {
    'BuildProfile': { DEBUG: true },
    'librdpnapi.so': { default: napi },
    './ProAppRuntime': { ProAppRuntime: { getInstance: () => ({ runtime, context: () => ({ capabilities: [] }) }) } },
    './ProUsbFidoKey': { ProUsbFidoKeys, ProUsbFidoKeySession }
  };
  const file = path.resolve(root, 'entry/src/main/ets/services/pro/ProRdpSecurityKey.ets');
  const module = { exports: {} };
  const source = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  vm.runInNewContext(source, { module, exports: module.exports, canIUse: () => true,
    require(id) { if (mocks[id]) return mocks[id]; throw new Error('unexpected module ' + id); } }, { filename: file });
  const prompts = [];
  const service = new module.exports.ProRdpSecurityKey((prompt) => { prompts.push(prompt); });
  const request = (fields) => Object.assign({ id: 0, kind: 0, text: '', operation: 0, retries: -1, timeoutMs: 0,
    report: new Uint8Array(64) }, fields);
  const deliver = (...items) => { state.queue.push(...items); state.wake(); };
  return { state, service, prompts, request, deliver, exports: module.exports, Session: ProUsbFidoKeySession,
    last: () => prompts[prompts.length - 1] };
}

test('start fails without a broker and succeeds with a watch it owns', () => {
  const f = fixture();
  assert.equal(f.service.start(7), false);
  f.state.watchId = 3;
  assert.equal(f.service.start(7), true);
  assert.equal(f.state.owner, 3);
  f.state.available = false;
  assert.equal(f.exports.ProRdpSecurityKey.available(), false);
});

test('a confirm prompt is answered once and a dismissed prompt comes down', () => {
  const f = fixture(); f.state.watchId = 1; f.service.start(7);
  f.deliver(f.request({ id: 11, kind: 1, text: 'webauthn.io', operation: 1 }));
  assert.deepEqual([f.last().kind, f.last().rpId, f.last().register], ['confirm', 'webauthn.io', true]);
  f.service.answerConfirm(99, true);
  assert.equal(f.state.responses.length, 0);
  f.service.answerConfirm(11, true);
  assert.deepEqual(f.state.responses.pop(), { id: 11, ok: true, report: null, text: null });
  assert.equal(f.last(), null);
  // A dismissal names the prompt it closes; another request's dismissal changes nothing.
  f.deliver(f.request({ id: 12, kind: 1, text: 'github.com', operation: 2 }));
  f.deliver(f.request({ id: 11, kind: 8 }));
  assert.equal(f.last().requestId, 12);
  f.deliver(f.request({ id: 12, kind: 8 }));
  assert.equal(f.last(), null);
  f.service.answerConfirm(12, true);
  assert.equal(f.state.responses.length, 0);
  // The touch prompt only follows the touch notifications.
  f.deliver(f.request({ kind: 4, operation: 1 }));
  assert.equal(f.last().kind, 'touch');
  f.deliver(f.request({ id: 12, kind: 8 }));
  assert.equal(f.last().kind, 'touch');
  f.deliver(f.request({ kind: 4, operation: 0 }));
  assert.equal(f.last(), null);
});

test('PIN rules are checked locally and a blocked PIN is shown as locked', () => {
  const f = fixture(); f.state.watchId = 1; f.service.start(7);
  const problem = f.exports.rdpSecurityKeyPinProblem;
  assert.equal(problem('1234'), '');
  assert.equal(problem('密钥口令'), '');
  assert.equal(problem('123'), 'PIN 至少 4 位');
  assert.equal(problem('密钥口'), 'PIN 至少 4 位');
  assert.equal(problem('12\u000034'), 'PIN 不能包含空字符');
  assert.equal(problem('a'.repeat(63)), '');
  assert.equal(problem('a'.repeat(64)), 'PIN 太长');
  assert.equal(problem('密'.repeat(21)), '');
  assert.equal(problem('密'.repeat(22)), 'PIN 太长');
  assert.equal(problem('😀😀😀😀'), '');
  f.deliver(f.request({ id: 21, kind: 3, retries: 2 }));
  assert.deepEqual([f.last().kind, f.last().retries], ['pin', 2]);
  f.service.answerPin(21, '123');
  assert.deepEqual(f.state.responses.pop(), { id: 21, ok: false, report: null, text: null });
  f.deliver(f.request({ id: 22, kind: 3, retries: 0 }));
  assert.equal(f.last().retries, 0);
  f.service.cancel();
  assert.deepEqual(f.state.responses.pop(), { id: 22, ok: false, report: null, text: null });
  f.deliver(f.request({ id: 23, kind: 3, retries: -1 }));
  f.service.answerPin(23, '123456');
  assert.deepEqual(f.state.responses.pop(), { id: 23, ok: true, report: null, text: '123456' });
});

test('choosing a key releases the old claim first and lets go when the request already ended', async () => {
  const f = fixture(); f.state.watchId = 1; f.service.start(7);
  f.deliver(f.request({ id: 41, kind: 2 }));
  f.service.chooseKey(41, 'k1');
  assert.equal(f.last().busy, true);
  f.state.authorize.resolve(new f.Session('first'));
  await settle();
  assert.deepEqual(f.state.responses.pop(), { id: 41, ok: true, report: null, text: 'first' });
  assert.equal(f.last(), null);
  // Reads and writes go to the claimed key.
  f.deliver(f.request({ id: 42, kind: 6, timeoutMs: 400 }));
  await settle();
  const read = f.state.responses.pop();
  assert.equal(read.id, 42); assert.equal(read.ok, true); assert.equal(read.report[0], 0x42);
  assert.deepEqual(f.state.transfers.pop(), { write: false, timeoutMs: 400, first: 0 });
  // A second selection (the key was replugged) releases the old claim before asking the system again.
  const releasedBefore = f.state.released;
  f.deliver(f.request({ id: 43, kind: 2 }));
  f.service.chooseKey(43, 'k1');
  assert.deepEqual(f.state.keyReleases, ['first']);
  assert.equal(f.state.released, releasedBefore + 1);
  assert.equal(f.state.authorizations.pop().released, 1);
  // The select timed out while the system dialog was open: the broker refuses the answer and the claim is let go.
  f.state.respondResult = false;
  f.state.authorize.resolve(new f.Session('second'));
  await settle();
  assert.deepEqual(f.state.keyReleases, ['first', 'second']);
  assert.equal(f.last(), null);
  f.deliver(f.request({ id: 44, kind: 5 }));
  assert.deepEqual(f.state.responses.pop(), { id: 44, ok: false, report: null, text: null });
  // A dismissal while the dialog is open: the new claim is released and nothing is answered.
  f.state.respondResult = true;
  f.deliver(f.request({ id: 45, kind: 2 }));
  f.service.chooseKey(45, 'k1');
  f.deliver(f.request({ id: 45, kind: 8 }));
  assert.equal(f.last(), null);
  const answered = f.state.responses.length;
  f.state.authorize.resolve(new f.Session('third'));
  await settle();
  assert.equal(f.state.responses.length, answered);
  assert.deepEqual(f.state.keyReleases, ['first', 'second', 'third']);
});

test('a broker release lets go without telling the broker back; revocation cancels and releases', async () => {
  const f = fixture(); f.state.watchId = 1; f.service.start(7);
  f.deliver(f.request({ id: 51, kind: 2 }));
  f.service.chooseKey(51, 'k1');
  f.state.authorize.resolve(new f.Session('held'));
  await settle();
  const released = f.state.released;
  f.deliver(f.request({ kind: 7 }));
  assert.deepEqual(f.state.keyReleases, ['held']);
  assert.equal(f.state.released, released);
  f.deliver(f.request({ id: 52, kind: 1, text: 'webauthn.io', operation: 2 }));
  f.state.executable = false;
  f.state.subscribers.forEach((callback) => callback());
  assert.deepEqual(f.state.responses.pop(), { id: 52, ok: false, report: null, text: null });
  assert.equal(f.state.cancels, 1);
  assert.equal(f.last(), null);
});

test('a page that lost the watch to a newer page stops without cancelling or unauthorizing its session', () => {
  const f = fixture(); f.state.watchId = 5; f.service.start(7);
  f.deliver(f.request({ id: 61, kind: 1, text: 'webauthn.io', operation: 1 }));
  // The independent window watched the same session (watch 6) before this source page stopped.
  f.state.owner = 6;
  f.service.stop();
  assert.deepEqual(f.state.unwatches, [5]);
  assert.equal(f.state.cancels, 0);
  assert.equal(f.state.released, 0);
  assert.equal(f.last(), null);
  // The owner of the watch cancels the session's request and tells the broker its key is gone.
  const g = fixture(); g.state.watchId = 8; g.service.start(9);
  g.service.stop();
  assert.equal(g.state.cancels, 1);
  assert.equal(g.state.released, 1);
  // After stop nothing is answered any more.
  g.service.answerConfirm(1, true);
  g.service.cancel();
  assert.equal(g.state.responses.length, 0);
});

(async () => {
  let failed = 0;
  for (const { name, body } of tests) {
    try { await body(); console.log('PASS', name); }
    catch (error) { failed++; console.error('FAIL', name); console.error(error); }
  }
  if (failed > 0) process.exit(1);
})();
