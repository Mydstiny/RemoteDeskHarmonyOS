'use strict';
// 手机通行密钥 transport: the production ProPasskeyChannel over a scripted distributed data object (one shared
// object per account with request / response / cancel fields). Covers joining, which requests reach the listener,
// withdrawals, answers, timeouts that tell the other side, and leaving only once nothing is waiting.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const crypto = require('node:crypto');
const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const dir = path.resolve(__dirname, '../../entry/src/main/ets/services/pro/passkey') + '/';
const tests = [];
function test(name, body) { tests.push({ name, body }); }
async function settle() { for (let i = 0; i < 20; i++) await Promise.resolve(); }

function load(name, mocks, globals) {
  const module = { exports: {} };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(dir + name + '.ets', 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText, { module, exports: module.exports, Uint8Array, JSON, Number, Array, Error, Math, String, Map, Date,
    ...globals, require(id) { if (id in mocks) return mocks[id]; throw new Error('unexpected module ' + id); } },
  { filename: name });
  return module.exports;
}
const codec = load('ProPasskeyCodec', {});
const b64 = bytes => Buffer.from(bytes).toString('base64url');

function fixture() {
  const state = { objects: [], timers: [] };
  const distributedDataObject = {
    create(_context, source) {
      const object = { ...source, handlers: [], sessions: [], sessionId: '',
        on(_type, callback) { this.handlers.push(callback); },
        off(_type, callback) { this.handlers = this.handlers.filter(item => item !== callback); },
        setSessionId(id) {
          this.sessions.push(id); this.sessionId = id;
          // Joining brings in what the account's other devices hold.
          if (id !== '' && state.synced) Object.assign(this, state.synced);
          // Leaving may take a while on a device.
          if (id === '' && state.leaveGate) return state.leaveGate;
          return Promise.resolve();
        } };
      state.objects.push(object);
      return object;
    }
  };
  const timers = {
    setTimeout: (callback, delay) => { state.timers.push({ callback, delay }); return state.timers.length; },
    clearTimeout: (id) => { if (state.timers[id - 1]) state.timers[id - 1].cleared = true; }
  };
  state.run = (delay) => {
    state.timers.filter(timer => !timer.cleared && !timer.done && (delay === undefined || timer.delay === delay))
      .forEach(timer => { timer.done = true; timer.callback(); });
  };
  const module = load('ProPasskeyChannel', {
    '@kit.AbilityKit': { abilityAccessCtrl: { createAtManager: () => ({
      requestPermissionsFromUser: async () => ({ authResults: [0] }) }) } },
    '@kit.ArkData': { distributedDataObject },
    './ProPasskeyCodec': codec,
    './ProPasskeyKeys': { sha256: bytes => new Uint8Array(crypto.createHash('sha256').update(bytes).digest()),
      utf8: text => new Uint8Array(Buffer.from(text, 'utf8')) }
  }, { canIUse: () => true, ...timers });
  const channel = new module.ProPasskeyChannel();
  const object = () => state.objects[state.objects.length - 1];
  // Another device of the account writes fields of the shared object.
  const remote = (values) => {
    const target = object();
    Object.assign(target, values);
    target.handlers.slice().forEach(callback => callback(target.sessionId, Object.keys(values)));
  };
  const request = (fields = {}) => ({ v: 2, id: b64(crypto.randomBytes(16)), op: 'signin', rpId: 'github.com',
    clientDataHash: b64(crypto.randomBytes(32)), user: null, credentialIds: [], from: 'MateBook', sentAt: Date.now(),
    ttlMs: 60000, device: b64(crypto.randomBytes(16)), devicePub: '', sig: b64(crypto.randomBytes(70)), ...fields });
  const answer = (id, fields = {}) => ({ v: 2, id, ok: false, error: 'PASSKEY_USER_DENIED', credentialId: '', authData: '',
    signature: '', userHandle: '', publicKey: '', ...fields });
  return { state, module, channel, object, remote, request, answer };
}

test('joining uses the account session and never answers a request that was already there', async () => {
  const f = fixture();
  const old = f.request();
  f.state.synced = { request: JSON.stringify(old) };
  assert.equal(await f.channel.join({}, 'owner-a'), true);
  assert.deepEqual(f.object().sessions, [f.module.passkeySessionId('owner-a')]);
  const heard = [];
  f.channel.listen(request => heard.push(request.id));
  f.remote({ request: JSON.stringify(old) });
  assert.equal(heard.length, 0);
  const fresh = f.request();
  f.remote({ request: JSON.stringify(fresh) });
  assert.deepEqual(heard, [fresh.id]);
});

test('a listener hears each new request once, never its own, and hears withdrawals', async () => {
  const f = fixture();
  await f.channel.join({}, 'owner-a');
  const heard = [], withdrawn = [];
  f.channel.listen(request => heard.push(request.id), id => withdrawn.push(id));
  const first = f.request();
  f.remote({ request: JSON.stringify(first) });
  f.remote({ request: JSON.stringify(first) });
  assert.deepEqual(heard, [first.id]);
  // Stale or malformed requests are not heard.
  f.remote({ request: JSON.stringify(f.request({ sentAt: Date.now() - 600000 })) });
  f.remote({ request: '{not json' });
  assert.equal(heard.length, 1);
  // What this device sent itself is not handed to its own listener.
  const mine = f.request();
  void f.channel.send(mine);
  f.remote({ request: JSON.stringify(mine) });
  assert.equal(heard.length, 1);
  f.remote({ cancel: first.id });
  assert.deepEqual(withdrawn, [first.id]);
  // Without a listener, withdrawals go nowhere.
  f.channel.listen(null, id => withdrawn.push(id));
  f.remote({ cancel: 'x' });
  assert.equal(withdrawn.length, 1);
});

test('an answer for the request settles it and clears the request field', async () => {
  const f = fixture();
  await f.channel.join({}, 'owner-a');
  const sent = f.request();
  const pending = f.channel.send(sent);
  assert.equal(JSON.parse(f.object().request).id, sent.id);
  f.remote({ response: JSON.stringify(f.answer('someone-else')) });
  await settle();
  f.remote({ response: JSON.stringify(f.answer(sent.id)) });
  const response = await pending;
  assert.deepEqual([response.id, response.error], [sent.id, 'PASSKEY_USER_DENIED']);
  assert.equal(f.object().request, '');
  // Settled by one device's answer: the others are told, so their dialogs come down.
  assert.equal(f.object().cancel, sent.id);
});

test('a timeout and a withdrawal both settle with null and tell the other devices', async () => {
  const f = fixture();
  await f.channel.join({}, 'owner-a');
  const timed = f.request({ ttlMs: 5000 });
  const waiting = f.channel.send(timed);
  f.state.run(5000);
  assert.equal(await waiting, null);
  assert.equal(f.object().cancel, timed.id);
  assert.equal(f.object().request, '');
  const withdrawn = f.request();
  const second = f.channel.send(withdrawn);
  f.channel.withdraw(withdrawn.id);
  assert.equal(await second, null);
  assert.equal(f.object().cancel, withdrawn.id);
  // A late answer for a settled request changes nothing.
  f.remote({ response: JSON.stringify(f.answer(withdrawn.id)) });
  f.channel.withdraw('unknown');
  assert.equal(f.object().cancel, withdrawn.id);
});

test('releasing waits until nothing is out and the last withdrawal had time to sync; a receiver keeps it', async () => {
  const f = fixture();
  await f.channel.join({}, 'owner-a');
  const sent = f.request();
  const pending = f.channel.send(sent);
  f.channel.release();
  assert.equal(f.channel.joined(), true);
  f.channel.withdraw(sent.id);
  await pending;
  assert.equal(f.channel.joined(), true);
  f.state.run(500);
  assert.equal(f.channel.joined(), false);
  assert.deepEqual(f.object().sessions.slice(-1), ['']);
  // Joining again cancels a pending leave; a listening receiver is never released.
  await f.channel.join({}, 'owner-a');
  f.channel.listen(() => {});
  f.channel.release();
  assert.equal(f.channel.joined(), true);
  f.channel.listen(null);
  f.channel.release();
  assert.equal(f.channel.joined(), false);
});

test('leaving or switching accounts settles what was waiting', async () => {
  const f = fixture();
  await f.channel.join({}, 'owner-a');
  const out = f.request();
  const waiting = f.channel.send(out);
  const first = f.object();
  await f.channel.join({}, 'owner-b');
  assert.equal(await waiting, null);
  // The old account's devices are told, and the old object leaves only after the cancel had time to sync.
  assert.equal(first.cancel, out.id);
  assert.deepEqual(first.sessions, [f.module.passkeySessionId('owner-a')]);
  // Switching straight back waits for the old object to be out before joining that session again.
  const back = f.channel.join({}, 'owner-a');
  await settle();
  assert.equal(f.state.objects.length, 2);
  f.state.run(500);
  assert.deepEqual(first.sessions.slice(-1), ['']);
  assert.equal(await back, true);
  assert.equal(f.state.objects.length, 3);
  assert.deepEqual(f.object().sessions, [f.module.passkeySessionId('owner-a')]);
});

test('a receiver and a sender joining one session at once share the join; it waits until the old object is out', async () => {
  const f = fixture();
  await f.channel.join({}, 'owner-a');
  void f.channel.send(f.request());
  await f.channel.join({}, 'owner-b');
  let left;
  f.state.leaveGate = new Promise((resolve) => { left = resolve; });
  const receiver = f.channel.join({}, 'owner-a');
  const sender = f.channel.join({}, 'owner-a');
  f.state.run(500);
  await settle();
  // The old object asked to leave but is not out yet: nobody joins.
  assert.equal(f.state.objects.length, 2);
  left();
  assert.deepEqual([await receiver, await sender], [true, true]);
  assert.equal(f.state.objects.length, 3);
  assert.equal(f.channel.joined(), true);
  assert.deepEqual(f.state.objects.map(item => item.sessions[0]),
    [f.module.passkeySessionId('owner-a'), f.module.passkeySessionId('owner-b'), f.module.passkeySessionId('owner-a')]);
});

(async () => {
  let failed = 0;
  for (const { name, body } of tests) {
    try { await body(); console.log('PASS', name); }
    catch (error) { failed++; console.error('FAIL', name); console.error(error); }
  }
  if (failed > 0) process.exit(1);
})();
