'use strict';
// 手机通行密钥, phone side: the production ProPasskeyReceiver and ProPasskeyAuthenticator against a scripted channel,
// paired-device store, HUKS keys and confirmation dialog. Covers who may ask, one request at a time, pairing, and
// that nothing is created or answered for a request that expired or was withdrawn. Not device acceptance.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const crypto = require('node:crypto');
const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const dir = path.resolve(__dirname, '../../entry/src/main/ets/services/pro/passkey') + '/';
const tests = [];
function test(name, body) { tests.push({ name, body }); }
async function settle() { for (let i = 0; i < 30; i++) await Promise.resolve(); }

function load(name, mocks, globals) {
  const module = { exports: {} };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(dir + name + '.ets', 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText, { module, exports: module.exports, Uint8Array, JSON, Number, Array, Error, Math, String, ...globals,
    require(id) { if (id in mocks) return mocks[id]; throw new Error('unexpected module ' + id); } }, { filename: name });
  return module.exports;
}
const codec = load('ProPasskeyCodec', {});
const b64 = bytes => Buffer.from(bytes).toString('base64url');

function fixture() {
  const state = { now: 1_000_000, owner: 'owner-a', receiving: true, peers: new Map(), signatureValid: true,
    dialogs: [], responses: [], listener: null, withdraw: null, joined: false, released: 0, records: [],
    keys: new Set(), removedKeys: [], unlock: null, savedPeers: [], timers: [], generated: null, signs: 0,
    saving: null, joinGate: null };
  const clock = { now: () => state.now };
  const timers = { setTimeout: (callback) => { state.timers.push(callback); return state.timers.length; },
    clearTimeout: () => {} };
  state.runTimers = () => { const pending = state.timers.splice(0); pending.forEach(callback => callback()); };
  class PasskeyDialogParams {
    constructor() { this.title = ''; this.message = ''; this.code = ''; this.cancel = '拒绝'; this.confirm = '允许'; this.deadline = 0; }
  }
  class PasskeyConfirmation {
    constructor(_ui, params) {
      this.params = params; this.closed = false;
      this.answer = new Promise((resolve) => { this.resolve = resolve; });
      state.dialogs.push(this);
    }
    close() { this.closed = true; this.resolve(false); }
  }
  const channel = {
    supported: () => true,
    getInstance: () => channelInstance
  };
  const channelInstance = {
    requestPermission: async () => true,
    joined: () => state.joined,
    async join() { if (state.joinGate !== null) await state.joinGate; state.joined = true; return true; },
    listen(onRequest, onWithdraw) { state.listener = onRequest; state.withdraw = onRequest === null ? null : onWithdraw; },
    respond(response) { state.responses.push(response); return true; },
    release() { state.released++; },
    leave() { state.joined = false; }
  };
  const peers = {
    receiving: () => state.receiving,
    setReceiving(_context, _owner, on) { state.receiving = on; return true; },
    find: (_context, owner, device) => state.peers.get(owner + '/' + device) ?? null,
    save(_context, peer) { state.savedPeers.push({ ...peer }); state.peers.set(peer.owner + '/' + peer.id, peer); }
  };
  // HUKS stand-in: keys exist after generate; sign() is where face, fingerprint or PIN would be asked.
  const keys = {
    preferredUnlock: () => 'face',
    async generate(alias) { state.keys.add(alias); if (state.generated !== null) await state.generated(); },
    async publicKey() {
      const { publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
      return new Uint8Array(publicKey.export({ type: 'spki', format: 'der' }));
    },
    async sign() { state.signs++; if (state.unlock !== null) await state.unlock(); return new Uint8Array(70).fill(1); },
    async remove(alias) { state.keys.delete(alias); state.removedKeys.push(alias); },
    async exists(alias) { return state.keys.has(alias); }
  };
  const keyModule = { ProPasskeyKeys: keys, randomBytes: n => new Uint8Array(crypto.randomBytes(n)),
    sha256: bytes => new Uint8Array(crypto.createHash('sha256').update(bytes).digest()),
    utf8: text => new Uint8Array(Buffer.from(text, 'utf8')) };
  const store = {
    forRp: (_context, owner, rpId) => state.records.filter(record => record.owner === owner && record.rpId === rpId),
    save(_context, record) {
      state.records = state.records.filter(value => value.id !== record.id).concat([record]);
      if (state.saving !== null) state.saving();
    },
    remove(_context, owner, id) {
      const record = state.records.find(value => value.owner === owner && value.id === id);
      if (record === undefined) return null;
      state.records = state.records.filter(value => value !== record);
      return record;
    }
  };
  const authenticator = load('ProPasskeyAuthenticator', { './ProPasskeyCodec': codec, './ProPasskeyKeys': keyModule,
    './ProPasskeyStore': { ProPasskeyStore: store } }, { Date: clock });
  const receiverModule = load('ProPasskeyReceiver', {
    'BuildProfile': { DEBUG: true },
    '../../../components/pro/passkey/ProPasskeyConfirmDialog': { PasskeyConfirmation, PasskeyDialogParams },
    '../../AccountSessionCoordinator': { AccountSessionCoordinator: { getInstance: () => ({
      currentScope: () => ({ ownerScopeId: state.owner }), onChange: () => {} }) } },
    '../ProAppRuntime': { ProAppRuntime: { getInstance: () => ({
      runtime: { decision: () => ({ executable: true }), subscribe: () => {} }, context: () => ({}) }) } },
    './ProPasskeyCodec': codec,
    './ProPasskeyAuthenticator': authenticator,
    './ProPasskeyChannel': { ProPasskeyChannel: channel },
    './ProPasskeyDevice': { passkeyPairingCodeOf: () => '123 456',
      passkeyRequestSignedBy: async () => state.signatureValid },
    './ProPasskeyKeys': keyModule,
    './ProPasskeyPeers': { ProPasskeyPeers: peers }
  }, { Date: clock, ...timers });
  const receiver = new receiverModule.ProPasskeyReceiver();
  const device = b64(crypto.randomBytes(16));
  state.peers.set('owner-a/' + device, { owner: 'owner-a', id: device, name: 'MateBook‮exe', publicKey: b64(new Uint8Array(91)),
    pairedAt: 1, lastUsedAt: 1 });
  let sequence = 0;
  const request = (fields = {}) => ({ v: 2, id: b64(crypto.randomBytes(16)), op: 'signin', rpId: 'github.com',
    clientDataHash: b64(crypto.randomBytes(32)), user: null, credentialIds: [], from: 'MateBook', sentAt: state.now,
    ttlMs: 60000, device, devicePub: '', sig: b64(crypto.randomBytes(70)), seq: ++sequence, ...fields });
  const register = (fields = {}) => request({ op: 'register', user: { id: b64(crypto.randomBytes(8)), name: 'octocat',
    displayName: 'Octo' }, ...fields });
  return { state, receiver, request, register, device };
}

async function started() {
  const f = fixture();
  f.receiver.foreground({}, () => ({}));
  await settle();
  assert.equal(typeof f.state.listener, 'function', 'listening');
  return f;
}

test('only paired devices with a valid signature reach a dialog', async () => {
  const f = await started();
  f.state.listener(f.request({ device: b64(crypto.randomBytes(16)), from: 'Stranger' }));
  await settle();
  assert.equal(f.state.responses.pop().error, 'PASSKEY_DEVICE_NOT_PAIRED');
  f.state.signatureValid = false;
  f.state.listener(f.request());
  await settle();
  assert.equal(f.state.responses.pop().error, 'PASSKEY_SIGNATURE_INVALID');
  assert.equal(f.state.dialogs.length, 0);
});

test('one request at a time; the dialog shows cleaned names and ends before the requester stops waiting', async () => {
  const f = await started();
  const first = f.request({ ttlMs: 30000 });
  f.state.listener(first);
  await settle();
  const dialog = f.state.dialogs[0];
  assert.equal(dialog.params.deadline, f.state.now + 27000);
  assert.ok(dialog.params.message.includes('「MateBookexe」') && !dialog.params.message.includes('‮'));
  f.state.listener(f.request());
  await settle();
  assert.equal(f.state.responses.pop().error, 'PASSKEY_BUSY');
  dialog.resolve(false);
  await settle();
  assert.equal(f.state.responses.pop().error, 'PASSKEY_USER_DENIED');
  // Free again: the next request gets its own dialog.
  f.state.listener(f.request());
  await settle();
  assert.equal(f.state.dialogs.length, 2);
});

test('a withdrawn request takes its dialog down and is never answered', async () => {
  const f = await started();
  const asked = f.request();
  f.state.listener(asked);
  await settle();
  f.state.withdraw('someone-else');
  assert.equal(f.state.dialogs[0].closed, false);
  f.state.withdraw(asked.id);
  await settle();
  assert.equal(f.state.dialogs[0].closed, true);
  assert.equal(f.state.responses.length, 0);
});

test('an approval after the request expired neither creates a passkey nor answers', async () => {
  const f = await started();
  f.state.listener(f.register({ ttlMs: 10000 }));
  await settle();
  f.state.now += 600000;
  f.state.dialogs[0].resolve(true);
  await settle();
  assert.equal(f.state.keys.size, 0);
  assert.equal(f.state.records.length, 0);
  assert.equal(f.state.responses.length, 0);
});

test('a request that ends while its key is made asks for no unlock and leaves no key behind', async () => {
  const f = await started();
  const asked = f.register();
  f.state.generated = async () => { f.state.withdraw(asked.id); };
  f.state.listener(asked);
  await settle();
  f.state.dialogs[0].resolve(true);
  await settle();
  assert.equal(f.state.signs, 0);
  assert.equal(f.state.keys.size, 0);
  assert.equal(f.state.records.length, 0);
  assert.equal(f.state.responses.length, 0);
});

test('a request that ends while the passkey is being unlocked leaves no passkey behind', async () => {
  const f = await started();
  const asked = f.register();
  f.state.unlock = async () => { f.state.withdraw(asked.id); };
  f.state.listener(asked);
  await settle();
  f.state.dialogs[0].resolve(true);
  await settle();
  assert.equal(f.state.keys.size, 0);
  assert.equal(f.state.removedKeys.length, 1);
  assert.equal(f.state.records.length, 0);
  assert.equal(f.state.responses.length, 0);
});

test('an approved registration and sign-in answer the requester', async () => {
  const f = await started();
  const registered = f.register();
  f.state.listener(registered);
  await settle();
  f.state.dialogs[0].resolve(true);
  await settle();
  const created = f.state.responses.pop();
  assert.deepEqual([created.id, created.ok], [registered.id, true]);
  assert.equal(f.state.records.length, 1);
  const signIn = f.request();
  f.state.listener(signIn);
  await settle();
  f.state.dialogs[1].resolve(true);
  await settle();
  const signed = f.state.responses.pop();
  assert.deepEqual([signed.id, signed.ok, signed.credentialId], [signIn.id, true, f.state.records[0].id]);
});

test('pairing shows the code in the dialog and stores the device under a cleaned name', async () => {
  const f = await started();
  const devicePub = b64(new Uint8Array(91).fill(4));
  const pair = f.request({ op: 'pair', rpId: '', clientDataHash: '', from: 'Pad⁦ Pro', device: b64(crypto.randomBytes(16)),
    devicePub });
  f.state.listener(pair);
  await settle();
  assert.equal(f.state.dialogs[0].params.code, '123 456');
  f.state.dialogs[0].resolve(true);
  await settle();
  assert.deepEqual([f.state.responses[0].id, f.state.responses[0].ok], [pair.id, true]);
  assert.equal(f.state.savedPeers.pop().name, 'Pad Pro');
  // A declined pairing stores nothing.
  const other = f.request({ op: 'pair', rpId: '', clientDataHash: '', device: b64(crypto.randomBytes(16)), devicePub });
  f.state.listener(other);
  await settle();
  f.state.dialogs[1].resolve(false);
  await settle();
  assert.equal(f.state.responses.pop().error, 'PASSKEY_PAIRING_DECLINED');
  assert.equal(f.state.savedPeers.length, 0);
});

test('turning receiving off takes an open dialog down without an answer', async () => {
  const f = await started();
  f.state.listener(f.request());
  await settle();
  await f.receiver.setEnabled(false, {});
  await settle();
  assert.equal(f.state.dialogs[0].closed, true);
  assert.equal(f.state.responses.length, 0);
  assert.ok(f.state.released > 0);
});

test('going to the background cancels an unanswered request, but not one being unlocked', async () => {
  const f = await started();
  const waiting = f.request();
  f.state.listener(waiting);
  await settle();
  const late = f.state.listener;
  f.receiver.background();
  await settle();
  assert.equal(f.state.dialogs[0].closed, true);
  assert.deepEqual([f.state.responses[0].id, f.state.responses[0].error], [waiting.id, 'PASSKEY_USER_CANCELLED']);
  // The answer gets a moment to sync before the channel is let go.
  const released = f.state.released;
  f.state.runTimers();
  await settle();
  assert.ok(f.state.released > released);
  // A request delivered late, while away, is not shown.
  late(f.request());
  await settle();
  assert.equal(f.state.dialogs.length, 1);
  // Back in front: a request being unlocked when the app leaves again carries on, and the channel stays until the
  // answer went out (the face or fingerprint check itself may move the app to the background).
  f.receiver.foreground({}, () => ({}));
  await settle();
  const unlocking = f.register();
  let finishUnlock;
  f.state.unlock = () => new Promise((resolve) => { finishUnlock = resolve; });
  f.state.listener(unlocking);
  await settle();
  f.state.dialogs[1].resolve(true);
  await settle();
  const before = f.state.released;
  f.receiver.background();
  await settle();
  assert.equal(f.state.released, before);
  assert.equal(typeof f.state.listener, 'function');
  finishUnlock();
  await settle();
  const answer = f.state.responses.pop();
  assert.deepEqual([answer.id, answer.ok], [unlocking.id, true]);
  assert.equal(f.state.records.length, 1);
  f.state.runTimers();
  await settle();
  assert.ok(f.state.released > before);
  assert.equal(f.state.listener, null);
});

test('a registration saved as its deadline passes is still answered; one withdrawn meanwhile is rolled back', async () => {
  const f = await started();
  const late = f.register({ ttlMs: 10000 });
  f.state.saving = () => { f.state.now += 8000; };
  f.state.listener(late);
  await settle();
  f.state.dialogs[0].resolve(true);
  await settle();
  const answer = f.state.responses.pop();
  assert.deepEqual([answer.id, answer.ok], [late.id, true]);
  assert.equal(f.state.records.length, 1);
  const withdrawn = f.register();
  f.state.saving = () => { f.state.withdraw(withdrawn.id); };
  f.state.listener(withdrawn);
  await settle();
  f.state.dialogs[1].resolve(true);
  await settle();
  assert.equal(f.state.responses.length, 0);
  assert.equal(f.state.records.length, 1);
  assert.equal(f.state.keys.size, 1);
});

test('going to the background while still joining lets the channel go', async () => {
  const f = fixture();
  let open;
  f.state.joinGate = new Promise((resolve) => { open = resolve; });
  f.receiver.foreground({}, () => ({}));
  await settle();
  f.receiver.background();
  await settle();
  open();
  await settle();
  assert.equal(f.state.listener, null);
  assert.ok(f.state.released > 0);
});

test('a request with too little time left is refused without a dialog', async () => {
  const f = await started();
  f.state.listener(f.request({ ttlMs: 5000 }));
  await settle();
  assert.equal(f.state.dialogs.length, 0);
  assert.equal(f.state.responses.pop().error, 'PASSKEY_EXPIRED');
});

test('each request is answered once, and the echo of its own answer changes nothing', async () => {
  const f = await started();
  const asked = f.request();
  f.state.listener(asked);
  await settle();
  f.state.dialogs[0].resolve(false);
  await settle();
  assert.equal(f.state.responses.length, 1);
  // The requester settles and tells every device; the answering device ignores it.
  f.state.withdraw(asked.id);
  await settle();
  assert.equal(f.state.responses.length, 1);
});

(async () => {
  let failed = 0;
  for (const { name, body } of tests) {
    try { await body(); console.log('PASS', name); }
    catch (error) { failed++; console.error('FAIL', name); console.error(error); }
  }
  if (failed > 0) process.exit(1);
})();
