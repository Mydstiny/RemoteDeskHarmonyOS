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

// The pure passkey modules run as they are; the phone channel, device key and receiver are scripted.
function loadPure(name, mocks) {
  const file = path.resolve(root, 'entry/src/main/ets/services/pro/passkey/' + name + '.ets');
  const module = { exports: {} };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText, { module, exports: module.exports, require: id => mocks[id], Uint8Array, JSON, Number, Array, Error, Math, String },
  { filename: file });
  return module.exports;
}
const passkeyCodec = loadPure('ProPasskeyCodec', {});
const passkeyCtap = loadPure('ProPasskeyCtap', { './ProPasskeyCodec': passkeyCodec });

function fixture() {
  const state = { available: true, executable: true, watchId: 0, owner: 0, queue: [], responses: [], cancels: 0,
    released: 0, unwatches: [], wake: null, respondResult: true, subscribers: [], authorizations: [],
    keyReleases: [], authorize: null, transfers: [], exResponses: [], phoneAvailable: true, channelOk: true,
    phoneRequests: [], phoneReply: null, phoneSend: null, withdrawn: [], channelGate: null, signGate: null };
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
    rdpSecurityKeyReleased() { state.released++; },
    rdpSecurityKeyRespondEx(sessionId, id, ok, payload, authenticator) {
      state.exResponses.push({ id, ok, payload: payload === null ? null : Array.from(payload), authenticator });
      return state.respondResult;
    }
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
    './ProUsbFidoKey': { ProUsbFidoKeys, ProUsbFidoKeySession },
    './passkey/ProPasskeyCtap': passkeyCtap,
    './passkey/ProPasskeyChannel': { ProPasskeyChannel: { getInstance: () => ({
      send(request) {
        state.phoneRequests.push(request);
        return new Promise((resolve) => { state.phoneSend = resolve; });
      },
      // Like the channel: a withdrawn request settles with null at once.
      withdraw(id) {
        state.withdrawn.push(id);
        const pending = state.phoneSend; state.phoneSend = null;
        if (pending !== null) pending(null);
      } }) } },
    './passkey/ProPasskeyDevice': { passkeyDeviceLabel: () => 'MateBook',
      ProPasskeyDevice: { signRequest: async (request) => {
        if (state.signGate !== null) await state.signGate.promise;
        return { ...request, device: 'D'.repeat(22), sig: 'S'.repeat(94) };
      } } },
    './passkey/ProPasskeyKeys': { randomBytes: n => new Uint8Array(n).fill(9) },
    './passkey/ProPasskeyReceiver': { ProPasskeyReceiver: { available: () => state.phoneAvailable,
      getInstance: () => ({ ensureChannel: async () => {
        if (state.channelGate !== null) await state.channelGate.promise;
        return state.channelOk;
      } }) } }
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
  // Native gives a passkey request the time left in the remote request (at most 120 s).
  const request = (fields) => Object.assign({ id: 0, kind: 0, text: '', operation: 0, retries: -1,
    timeoutMs: fields.kind === 9 ? 60000 : 0, report: new Uint8Array(64), payload: new Uint8Array(0) }, fields);
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

// CTAP command bytes for the phone path, built with the module's own encoder.
const enc = passkeyCtap;
function ctapGetAssertion(allow) {
  const entries = [[enc.cborUint(1), enc.cborText('github.com')], [enc.cborUint(2), enc.cborBytes(new Uint8Array(32).fill(1))]];
  if (allow) entries.push([enc.cborUint(3), [0x81].concat(enc.cborMap([[enc.cborText('id'), enc.cborBytes(allow)],
    [enc.cborText('type'), enc.cborText('public-key')]]))]);
  return new Uint8Array([2].concat(enc.cborMap(entries)));
}

test('the select prompt offers the paired phone, and choosing it answers with the phone authenticator', async () => {
  const f = fixture(); f.state.watchId = 1; f.service.start(7);
  f.deliver(f.request({ id: 70, kind: 2 }));
  assert.equal(f.last().phone, true);
  f.service.choosePhone(70);
  assert.deepEqual(f.state.exResponses.pop(), { id: 70, ok: true, payload: null, authenticator: 2 });
  assert.equal(f.last(), null);
  const g = fixture(); g.state.watchId = 1; g.state.phoneAvailable = false; g.service.start(7);
  g.deliver(g.request({ id: 71, kind: 2 }));
  assert.equal(g.last().phone, false);
  g.service.choosePhone(71);
  assert.equal(g.state.exResponses.length, 0);
});

test('a remote sign-in is signed, sent to the phone and its answer goes back as a CTAP response', async () => {
  const f = fixture(); f.state.watchId = 1; f.service.attachContext({}); f.service.start(7);
  const credential = new Uint8Array(16).fill(4);
  f.deliver(f.request({ id: 80, kind: 9, text: 'github.com', timeoutMs: 45000, payload: ctapGetAssertion(credential) }));
  await settle();
  assert.deepEqual([f.last().kind, f.last().rpId, f.last().register], ['phone', 'github.com', false]);
  const sent = f.state.phoneRequests.pop();
  assert.deepEqual([sent.op, sent.rpId, sent.from, sent.device.length], ['signin', 'github.com', 'MateBook', 22]);
  assert.ok(sent.ttlMs > 44000 && sent.ttlMs <= 45000, 'the phone gets the time left: ' + sent.ttlMs);
  assert.deepEqual(Array.from(sent.credentialIds), [Buffer.from(credential).toString('base64url')]);
  const b64 = bytes => Buffer.from(bytes).toString('base64url');
  const authData = new Uint8Array(37); authData[32] = 0x05;
  f.state.phoneSend({ v: 2, id: sent.id, ok: true, error: '', credentialId: b64(credential), authData: b64(authData),
    signature: b64(new Uint8Array(70).fill(3)), userHandle: '', publicKey: '' });
  await settle();
  const answer = f.state.exResponses.pop();
  assert.deepEqual([answer.id, answer.ok, answer.authenticator, answer.payload[0]], [80, true, 1, 0]);
  assert.equal(f.last(), null);
});

test('the phone path refuses at once when nothing can answer, and a timeout or cancel never answers late', async () => {
  const f = fixture(); f.state.watchId = 1; f.service.attachContext({}); f.service.start(7);
  const ask = (id, extra = {}) => f.request({ id, kind: 9, text: 'github.com', timeoutMs: 45000, payload: ctapGetAssertion(null),
    ...extra });
  // The server allows only another authenticator's credential: no round trip to the phone.
  f.deliver(ask(81, { payload: ctapGetAssertion(new Uint8Array(48)) }));
  await settle();
  assert.deepEqual(f.state.exResponses.pop().payload, [0x2e]);
  assert.equal(f.state.phoneRequests.length, 0);
  // Malformed command bytes are refused with their CTAP status.
  f.deliver(ask(82, { payload: new Uint8Array([2, 0xff]) }));
  await settle();
  assert.deepEqual(f.state.exResponses.pop().payload, [0x12]);
  // The command names another relying party than the one confirmed here: refused, nothing sent.
  f.deliver(ask(87, { text: 'webauthn.io' }));
  await settle();
  assert.deepEqual(f.state.exResponses.pop().payload, [0x02]);
  assert.equal(f.state.phoneRequests.length, 0);
  // The user cancels while waiting: the broker hears a refusal, the phone's request is withdrawn, nothing late.
  f.deliver(ask(86));
  await settle();
  const sent = f.state.phoneRequests.pop();
  f.service.cancel();
  assert.deepEqual(f.state.responses.pop(), { id: 86, ok: false, report: null, text: null });
  assert.deepEqual(f.state.withdrawn, [sent.id]);
  await settle();
  assert.equal(f.state.exResponses.length, 0);
  assert.equal(f.state.released, 0);
});

test('a phone that cannot answer is set aside and the key selection returns with the reason', async () => {
  const f = fixture(); f.state.watchId = 1; f.service.attachContext({}); f.service.start(7);
  const ask = (id) => f.request({ id, kind: 9, text: 'github.com', operation: 1, timeoutMs: 45000,
    payload: ctapGetAssertion(null) });
  const setAside = (id) => {
    assert.deepEqual(f.state.exResponses.pop(), { id, ok: false, payload: null, authenticator: 1 });
    assert.equal(f.state.released, ++released);
  };
  let released = 0;
  // No phone feature: set aside without a prompt.
  f.state.phoneAvailable = false;
  f.deliver(ask(90));
  await settle();
  setAside(90);
  f.state.phoneAvailable = true;
  // The channel cannot be joined.
  f.state.channelOk = false;
  f.deliver(ask(91));
  await settle();
  setAside(91);
  assert.equal(f.last(), null);
  f.state.channelOk = true;
  // No answer within the phone's time.
  f.deliver(ask(92));
  await settle();
  f.state.phoneSend(null);
  await settle();
  setAside(92);
  // The phone does not know this device; the next selection says why.
  f.deliver(ask(93));
  await settle();
  const sent = f.state.phoneRequests.pop();
  f.state.phoneSend({ v: 2, id: sent.id, ok: false, error: 'PASSKEY_DEVICE_NOT_PAIRED', credentialId: '', authData: '',
    signature: '', userHandle: '', publicKey: '' });
  await settle();
  setAside(93);
  f.deliver(f.request({ id: 94, kind: 2 }));
  assert.equal(f.last().kind, 'select');
  assert.match(f.last().error, /配对/);
  f.deliver(f.request({ id: 95, kind: 2 }));
  assert.equal(f.last().error, '');
  // A refusal on the phone is the user's answer: the phone stays chosen.
  f.deliver(ask(96));
  await settle();
  const declined = f.state.phoneRequests.pop();
  f.state.phoneSend({ v: 2, id: declined.id, ok: false, error: 'PASSKEY_USER_DENIED', credentialId: '', authData: '',
    signature: '', userHandle: '', publicKey: '' });
  await settle();
  assert.deepEqual(f.state.exResponses.pop(), { id: 96, ok: true, payload: [0x27], authenticator: 1 });
  assert.equal(f.state.released, released);
});

test('choosing a USB key while the phone is asked withdraws the phone request and returns to selection', async () => {
  const f = fixture(); f.state.watchId = 1; f.service.attachContext({}); f.service.start(7);
  f.deliver(f.request({ id: 100, kind: 9, text: 'github.com', operation: 1, payload: ctapGetAssertion(null) }));
  await settle();
  assert.equal(f.last().phone, true);
  const sent = f.state.phoneRequests.pop();
  f.service.useSecurityKey(99);
  assert.equal(f.state.withdrawn.length, 0);
  f.service.useSecurityKey(100);
  assert.deepEqual(f.state.withdrawn, [sent.id]);
  assert.deepEqual(f.state.exResponses.pop(), { id: 100, ok: false, payload: null, authenticator: 1 });
  assert.equal(f.state.released, 1);
  assert.equal(f.last(), null);
  await settle();
  assert.equal(f.state.exResponses.length, 0);
});

test('when the request cannot go back to selection, there is no switch and no reason is kept', async () => {
  const f = fixture(); f.state.watchId = 1; f.service.attachContext({}); f.service.start(7);
  f.deliver(f.request({ id: 140, kind: 9, text: 'github.com', operation: 0, payload: ctapGetAssertion(null) }));
  await settle();
  assert.equal(f.last().phone, false);
  f.service.useSecurityKey(140);
  assert.equal(f.state.withdrawn.length, 0);
  assert.equal(f.state.exResponses.length, 0);
  // The phone does not answer: the request ends, the phone is set aside, the next selection says nothing stale.
  f.state.phoneSend(null);
  await settle();
  assert.deepEqual(f.state.exResponses.pop(), { id: 140, ok: false, payload: null, authenticator: 1 });
  assert.equal(f.state.released, 1);
  f.deliver(f.request({ id: 141, kind: 2 }));
  assert.equal(f.last().error, '');
});

test('too little time left: the CTAP timeout at once, nothing sent to the phone', async () => {
  const f = fixture(); f.state.watchId = 1; f.service.attachContext({}); f.service.start(7);
  f.deliver(f.request({ id: 150, kind: 9, text: 'github.com', operation: 1, timeoutMs: 5000, payload: ctapGetAssertion(null) }));
  await settle();
  assert.equal(f.state.phoneRequests.length, 0);
  assert.deepEqual(f.state.exResponses.pop(), { id: 150, ok: true, payload: [0x2f], authenticator: 1 });
  assert.equal(f.last(), null);
});

test('when no selection follows, the reason stays on screen and closing it cancels nothing', async () => {
  const f = fixture(); f.state.watchId = 1; f.service.attachContext({}); f.service.start(7);
  f.deliver(f.request({ id: 160, kind: 9, text: 'github.com', operation: 0, payload: ctapGetAssertion(null) }));
  await settle();
  const sent = f.state.phoneRequests.pop();
  f.state.phoneSend({ v: 2, id: sent.id, ok: false, error: 'PASSKEY_BUSY', credentialId: '', authData: '', signature: '',
    userHandle: '', publicKey: '' });
  await settle();
  assert.deepEqual(f.state.exResponses.pop(), { id: 160, ok: false, payload: null, authenticator: 1 });
  assert.deepEqual([f.last().kind, f.last().phone], ['phone', false]);
  assert.match(f.last().error, /另一个请求/);
  const cancels = f.state.cancels;
  f.service.cancel();
  assert.equal(f.last(), null);
  assert.equal(f.state.cancels, cancels);
  assert.equal(f.state.responses.length, 0);
});

test('a request that ends while the channel is joined or the request is signed never reaches the phone', async () => {
  for (const [stage, end] of [['join', 'cancel'], ['join', 'dismiss'], ['join', 'stop'], ['sign', 'cancel'],
    ['sign', 'dismiss'], ['sign', 'stop']]) {
    const f = fixture(); f.state.watchId = 1; f.service.attachContext({}); f.service.start(7);
    const blocker = gate();
    if (stage === 'join') f.state.channelGate = blocker; else f.state.signGate = blocker;
    f.deliver(f.request({ id: 110, kind: 9, text: 'github.com', payload: ctapGetAssertion(null) }));
    await settle();
    assert.equal(f.last().kind, 'phone');
    if (end === 'cancel') f.service.cancel();
    else if (end === 'dismiss') f.deliver(f.request({ id: 110, kind: 8 }));
    else f.service.stop();
    blocker.open();
    await settle();
    assert.equal(f.state.phoneRequests.length, 0, stage + '/' + end);
    assert.equal(f.state.exResponses.length, 0, stage + '/' + end);
  }
});

test('a dismissal or a stop while the phone is asked withdraws the request', async () => {
  for (const end of ['dismiss', 'stop']) {
    const f = fixture(); f.state.watchId = 1; f.service.attachContext({}); f.service.start(7);
    f.deliver(f.request({ id: 120, kind: 9, text: 'github.com', payload: ctapGetAssertion(null) }));
    await settle();
    const sent = f.state.phoneRequests.pop();
    if (end === 'dismiss') f.deliver(f.request({ id: 120, kind: 8 })); else f.service.stop();
    assert.deepEqual(f.state.withdrawn, [sent.id], end);
    await settle();
    assert.equal(f.state.exResponses.length, 0, end);
  }
});

test('choosing the phone lets go of a USB key held from before', async () => {
  const f = fixture(); f.state.watchId = 1; f.service.start(7);
  f.deliver(f.request({ id: 130, kind: 2 }));
  const choosing = f.service.chooseKey(130, 'k1');
  f.state.authorize.resolve(new f.Session('YubiKey 5'));
  await choosing;
  assert.equal(f.state.released, 1);
  f.deliver(f.request({ id: 131, kind: 2 }));
  f.service.choosePhone(131);
  assert.deepEqual(f.state.keyReleases, ['YubiKey 5']);
  assert.equal(f.state.released, 2);
  assert.deepEqual(f.state.exResponses.pop(), { id: 131, ok: true, payload: null, authenticator: 2 });
});

function gate() {
  let open;
  const promise = new Promise((resolve) => { open = resolve; });
  return { promise, open };
}

(async () => {
  let failed = 0;
  for (const { name, body } of tests) {
    try { await body(); console.log('PASS', name); }
    catch (error) { failed++; console.error('FAIL', name); console.error(error); }
  }
  if (failed > 0) process.exit(1);
})();
