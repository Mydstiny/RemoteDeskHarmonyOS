'use strict';
// 手机通行密钥 end to end: the production ProPasskeyReceiver and ProPasskeyAuthenticator on a phone, the production
// ProPasskeyChannel on every device, joined through a scripted distributed data object network (fields sync to the
// other devices of the session a moment after they are written) and a scripted clock. Dialogs, HUKS keys and the
// paired-device store are scripted. Covers what the unit tests cannot: answers that must still reach the requester,
// and dialogs on other devices that must come down. Not device acceptance.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const crypto = require('node:crypto');
const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const dir = path.resolve(__dirname, '../../entry/src/main/ets/services/pro/passkey') + '/';
const tests = [];
function test(name, body) { tests.push({ name, body }); }
async function settle() { for (let i = 0; i < 40; i++) await Promise.resolve(); }
const sources = new Map();
function transpiled(name) {
  if (!sources.has(name)) {
    sources.set(name, ts.transpileModule(fs.readFileSync(dir + name + '.ets', 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText);
  }
  return sources.get(name);
}
function load(name, mocks, globals) {
  const module = { exports: {} };
  vm.runInNewContext(transpiled(name), { module, exports: module.exports, Uint8Array, JSON, Number, Array, Error, Math,
    String, Map, Set, Promise, ...globals,
    require(id) { if (id in mocks) return mocks[id]; throw new Error('unexpected module ' + id); } }, { filename: name });
  return module.exports;
}
const b64 = bytes => Buffer.from(bytes).toString('base64url');

function world() {
  const w = { now: 1_800_000_000_000, timers: [], sessions: new Map() };
  w.Date = { now: () => w.now };
  w.setTimeout = (callback, delay) => { w.timers.push({ at: w.now + (delay || 0), callback }); return w.timers.length; };
  w.clearTimeout = (id) => { if (w.timers[id - 1]) w.timers[id - 1].cleared = true; };
  w.advance = async (ms) => {
    const until = w.now + ms;
    for (;;) {
      await settle();
      const due = w.timers.filter(timer => !timer.cleared && !timer.done && timer.at <= until).sort((a, b) => a.at - b.at)[0];
      if (due === undefined) break;
      w.now = Math.max(w.now, due.at);
      due.done = true;
      due.callback();
    }
    w.now = until;
    await settle();
  };
  // Distributed data objects: a written field reaches the session's other objects a moment later.
  w.dataObject = () => ({
    create(_context, source) {
      const values = { ...source };
      const object = { handlers: [], sessionId: '',
        on(_type, callback) { this.handlers.push(callback); },
        off(_type, callback) { this.handlers = this.handlers.filter(item => item !== callback); },
        setSessionId(id) {
          const old = w.sessions.get(this.sessionId);
          if (old) old.delete(this);
          this.sessionId = id;
          if (id !== '') {
            const members = w.sessions.get(id) ?? new Set();
            const peer = [...members][0];
            if (peer) Object.assign(values, peer.snapshot());
            members.add(this);
            w.sessions.set(id, members);
          }
          return Promise.resolve();
        },
        snapshot() { return { ...values }; },
        receive(field, value) {
          values[field] = value;
          this.handlers.slice().forEach(callback => callback(this.sessionId, [field]));
        } };
      for (const field of Object.keys(source)) {
        Object.defineProperty(object, field, { enumerable: true, get: () => values[field], set: (value) => {
          values[field] = value;
          const session = object.sessionId;
          Promise.resolve().then(() => {
            for (const other of w.sessions.get(session) ?? []) { if (other !== object) other.receive(field, value); }
          });
        } });
      }
      return object;
    }
  });
  w.channel = () => load('ProPasskeyChannel', {
    '@kit.AbilityKit': { abilityAccessCtrl: { createAtManager: () => ({ requestPermissionsFromUser: async () => ({ authResults: [0] }) }) } },
    '@kit.ArkData': { distributedDataObject: w.dataObject() },
    './ProPasskeyCodec': codec,
    './ProPasskeyKeys': keyHelpers
  }, { canIUse: () => true, Date: w.Date, setTimeout: w.setTimeout, clearTimeout: w.clearTimeout });
  return w;
}
const codec = load('ProPasskeyCodec', {}, {});
const keyHelpers = { sha256: bytes => new Uint8Array(crypto.createHash('sha256').update(bytes).digest()),
  utf8: text => new Uint8Array(Buffer.from(text, 'utf8')), randomBytes: n => new Uint8Array(crypto.randomBytes(n)) };

/** A phone: its own channel, receiver and authenticator; dialogs, HUKS and stores scripted. */
function phone(w, pcDevice) {
  const p = { dialogs: [], keys: new Set(), records: [], unlock: null, signs: 0 };
  class PasskeyDialogParams {
    constructor() { this.title = ''; this.message = ''; this.code = ''; this.cancel = '拒绝'; this.confirm = '允许'; this.deadline = 0; }
  }
  class PasskeyConfirmation {
    constructor(_ui, params) {
      this.params = params; this.closed = false;
      this.answer = new Promise((resolve) => { this.resolve = resolve; });
      p.dialogs.push(this);
    }
    close() { this.closed = true; this.resolve(false); }
  }
  const keys = {
    preferredUnlock: () => 'face',
    async generate(alias) { p.keys.add(alias); },
    async publicKey() {
      const { publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
      return new Uint8Array(publicKey.export({ type: 'spki', format: 'der' }));
    },
    async sign() { p.signs++; if (p.unlock !== null) await p.unlock(); return new Uint8Array(70).fill(1); },
    async remove(alias) { p.keys.delete(alias); },
    async exists(alias) { return p.keys.has(alias); }
  };
  const store = {
    forRp: (_context, owner, rpId) => p.records.filter(record => record.owner === owner && record.rpId === rpId),
    save(_context, record) { p.records = p.records.filter(value => value.id !== record.id).concat([record]); },
    remove() { return null; }
  };
  const keyModule = { ProPasskeyKeys: keys, ...keyHelpers };
  const globals = { Date: w.Date, setTimeout: w.setTimeout, clearTimeout: w.clearTimeout };
  const authenticator = load('ProPasskeyAuthenticator', { './ProPasskeyCodec': codec, './ProPasskeyKeys': keyModule,
    './ProPasskeyStore': { ProPasskeyStore: store } }, globals);
  p.channel = w.channel();
  const peer = { owner: 'owner-a', id: pcDevice, name: 'MateBook', publicKey: b64(new Uint8Array(91)), pairedAt: 1, lastUsedAt: 1 };
  const receiverModule = load('ProPasskeyReceiver', {
    'BuildProfile': { DEBUG: true },
    '../../../components/pro/passkey/ProPasskeyConfirmDialog': { PasskeyConfirmation, PasskeyDialogParams },
    '../../AccountSessionCoordinator': { AccountSessionCoordinator: { getInstance: () => ({
      currentScope: () => ({ ownerScopeId: 'owner-a' }), onChange: () => {} }) } },
    '../ProAppRuntime': { ProAppRuntime: { getInstance: () => ({
      runtime: { decision: () => ({ executable: true }), subscribe: () => {} }, context: () => ({}) }) } },
    './ProPasskeyCodec': codec,
    './ProPasskeyAuthenticator': authenticator,
    './ProPasskeyChannel': p.channel,
    './ProPasskeyDevice': { passkeyPairingCodeOf: () => '123 456', passkeyRequestSignedBy: async () => true },
    './ProPasskeyKeys': keyModule,
    './ProPasskeyPeers': { ProPasskeyPeers: { receiving: () => true, setReceiving: () => true,
      find: (_context, owner, device) => owner === 'owner-a' && device === pcDevice ? peer : null, save() {} } }
  }, globals);
  p.receiver = new receiverModule.ProPasskeyReceiver();
  p.joined = () => p.channel.ProPasskeyChannel.getInstance().joined();
  return p;
}

/** The PC: a channel that sends signed requests and waits for the answer. */
async function pc(w) {
  const device = b64(crypto.randomBytes(16));
  const module = w.channel();
  const channel = module.ProPasskeyChannel.getInstance();
  assert.equal(await channel.join({}, 'owner-a'), true);
  const request = (fields = {}) => ({ v: 2, id: b64(crypto.randomBytes(16)), op: 'register', rpId: 'github.com',
    clientDataHash: b64(crypto.randomBytes(32)), user: { id: b64(crypto.randomBytes(8)), name: 'octocat', displayName: 'Octo' },
    credentialIds: [], from: 'MateBook', sentAt: w.now, ttlMs: 60000, device, devicePub: '', sig: b64(crypto.randomBytes(70)),
    ...fields });
  return { device, channel, request };
}

async function setup(phones = 1) {
  const w = world();
  const device = b64(crypto.randomBytes(16));
  const devices = [];
  for (let i = 0; i < phones; i++) {
    const p = phone(w, device);
    p.receiver.foreground({}, () => ({}));
    devices.push(p);
  }
  await w.advance(0);
  const computer = await pc(w);
  // The phones know the PC under the device ID its requests carry.
  const pcSide = { ...computer, request: (fields = {}) => computer.request({ device, ...fields }) };
  return { w, phones: devices, pc: pcSide };
}

test('an allowed registration still reaches the PC when the unlock moves the phone app to the background', async () => {
  const { w, phones: [p], pc: computer } = await setup();
  let finishUnlock;
  p.unlock = () => new Promise((resolve) => { finishUnlock = resolve; });
  const asked = computer.request();
  const answer = computer.channel.send(asked);
  await w.advance(0);
  assert.equal(p.dialogs.length, 1);
  p.dialogs[0].resolve(true);
  await w.advance(0);
  // The system face/fingerprint sheet puts the app in the background.
  p.receiver.background();
  await w.advance(100);
  assert.equal(p.joined(), true);
  finishUnlock();
  await w.advance(0);
  const response = await answer;
  assert.deepEqual([response.id, response.ok], [asked.id, true]);
  assert.equal(p.records.length, 1);
  await w.advance(600);
  assert.equal(p.joined(), false);
});

test('a registration still waiting for the user is cancelled when the phone app goes to the background', async () => {
  const { w, phones: [p], pc: computer } = await setup();
  const asked = computer.request();
  const answer = computer.channel.send(asked);
  await w.advance(0);
  p.receiver.background();
  await w.advance(0);
  const response = await answer;
  assert.deepEqual([response.id, response.ok, response.error], [asked.id, false, 'PASSKEY_USER_CANCELLED']);
  assert.equal(p.dialogs[0].closed, true);
  assert.equal(p.records.length, 0);
  await w.advance(600);
  assert.equal(p.joined(), false);
});

test('once one phone answers, the dialog on another receiving phone comes down', async () => {
  const { w, phones: [first, second], pc: computer } = await setup(2);
  const asked = computer.request();
  const answer = computer.channel.send(asked);
  await w.advance(0);
  assert.deepEqual([first.dialogs.length, second.dialogs.length], [1, 1]);
  first.dialogs[0].resolve(false);
  await w.advance(0);
  assert.equal((await answer).error, 'PASSKEY_USER_DENIED');
  await w.advance(0);
  assert.equal(second.dialogs[0].closed, true);
  // Too late to allow there: nothing is created.
  second.dialogs[0].resolve(true);
  await w.advance(0);
  assert.equal(second.records.length + second.keys.size, 0);
});

test('a PC request that times out takes the phone dialog down', async () => {
  const { w, phones: [p], pc: computer } = await setup();
  const asked = computer.request({ ttlMs: 20000 });
  const answer = computer.channel.send(asked);
  await w.advance(0);
  assert.equal(p.dialogs.length, 1);
  assert.equal(p.dialogs[0].params.deadline, w.now + 17000);
  await w.advance(20000);
  assert.equal(await answer, null);
  await w.advance(0);
  assert.equal(p.dialogs[0].closed, true);
  p.dialogs[0].resolve(true);
  await w.advance(0);
  assert.equal(p.records.length + p.keys.size, 0);
});

(async () => {
  let failed = 0;
  for (const { name, body } of tests) {
    try { await body(); console.log('PASS', name); }
    catch (error) { failed++; console.error('FAIL', name); console.error(error); }
  }
  if (failed > 0) process.exit(1);
})();
