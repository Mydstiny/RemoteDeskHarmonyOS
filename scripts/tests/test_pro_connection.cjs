/* Runs the production envelope, transactions, receipt channel and continuation
 * service with controlled platform callbacks. Not an official device migration test. */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const tests = [];
function test(name, body) { tests.push({ name, body }); }
function deferred() { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; }
async function settle() { for (let i = 0; i < 15; i++) await Promise.resolve(); }
function fixture() {
  const state = { now: 1000000, allowed: true, permission: true, hostReady: true,
    objects: [], timers: new Map(), listeners: [], transitionListeners: [], missions: [], nextTimer: 0,
    profileRaw: '', profileReadable: true, nativeGeneration: 5, nativeState: 2, directoryWait: null,
    joinWait: null, permissionWait: null, createError: false,
    scope: { kind: 'huawei_account', ownerScopeId: 'owner-' + 'a'.repeat(64), generation: 1, sessionState: 'ready' } };
  state.host = { id: 'host-1', userId: state.scope.ownerScopeId, protocol: 'ssh', label: 'Work server',
    host: 'ssh.example.test', port: 22, username: 'alice', sshProxyType: 'direct', proxyHost: '',
    password: 'NEVER_EXPORT', sshKeyData: 'NEVER_EXPORT', sshKeyPassphrase: 'NEVER_EXPORT',
    sshHostKeyRawBase64: 'NEVER_EXPORT', toJSON() { throw new Error('must not serialize host'); } };
  const context = { abilityInfo: { name: 'EntryAbility' }, applicationInfo: { accessTokenId: 42 },
    async setMissionContinueState(value) { state.missions.push(value); } };
  const constants = { ContinueState: { ACTIVE: 0, INACTIVE: 1 }, OnContinueResult: { AGREE: 0, REJECT: 1 } };
  const mocks = {
    '@kit.AbilityKit': { AbilityConstant: constants,
      wantConstant: { Params: { SUPPORT_CONTINUE_PAGE_STACK_KEY: 'pageStack', SUPPORT_CONTINUE_SOURCE_EXIT_KEY: 'sourceExit' } },
      abilityAccessCtrl: { GrantStatus: { PERMISSION_GRANTED: 0 }, createAtManager: () => ({
        checkAccessToken: async () => state.permission ? 0 : -1,
        requestPermissionsFromUser: async () => {
          if (state.permissionWait) await state.permissionWait.promise;
          return { authResults: [state.permission ? 0 : -1] };
        }
      }) } },
    '@kit.CryptoArchitectureKit': { cryptoFramework: { createRandom: () => ({
      generateRandomSync: n => ({ data: new Uint8Array(crypto.randomBytes(n)) })
    }) } },
    '@kit.ArkData': { preferences: { getPreferencesSync: () => ({ getSync() {
      if (!state.profileReadable) throw new Error('unreadable'); return state.profileRaw;
    } }) }, distributedDataObject: { create: (_context, fields) => {
      if (state.createError) throw new Error('platform create failed');
      const object = { ...fields, calls: [], callback: null,
        on(event, callback) { assert.equal(event, 'change'); this.callback = callback; },
        off(event, callback) { assert.equal(callback, this.callback); this.callback = null; },
        async setSessionId(id) {
          this.calls.push(id);
          if (id && state.joinWait) await state.joinWait.promise;
        },
        emit(session) { this.callback?.(session, ['receipt', 'acknowledged']); }
      }; state.objects.push(object); return object;
    } } }
  };
  const runtime = { subscribe(callback) { state.listeners.push(callback); callback(); return () => {}; },
    decision: () => ({ executable: state.allowed, visible: state.allowed }) };
  const cache = new Map();
  function load(file) {
    file = path.resolve(root, file);
    if (cache.has(file)) return cache.get(file).exports;
    const module = { exports: {} }; cache.set(file, module);
    const source = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
    }).outputText;
    const Clock = class extends Date { static now() { return state.now; } };
    vm.runInNewContext(source, { module, exports: module.exports, Date: Clock,
      canIUse: () => true, setTimeout(callback, delay) {
        const id = ++state.nextTimer; state.timers.set(id, { callback, delay }); return id;
      }, clearTimeout: id => state.timers.delete(id),
      require(id) {
        if (mocks[id]) return mocks[id];
        if (id.endsWith('/AccountSessionCoordinator')) return { AccountSessionCoordinator: { getInstance: () => ({
          currentScope: () => state.scope, onTransitionActivity(callback) {
            state.transitionListeners.push(callback); callback(false); return () => {};
          }
        }) } };
        if (id.endsWith('/HostSyncService')) return { HostSyncService: { getInstance: () => ({
          isReady: () => state.hostReady, getHost: id => state.host?.id === id ? state.host : undefined
        }) } };
        if (id === './ProAppRuntime') return { ProAppRuntime: { getInstance: () => ({ runtime,
          context: () => ({ protocol: 'ssh', capabilities: [], grantedPermissions: [], requestablePermissions: [] }) }) } };
        if (id.startsWith('.')) return load(path.resolve(path.dirname(file), id + '.ets'));
        throw new Error('unexpected import ' + id);
      }
    }, { filename: file });
    return module.exports;
  }
  const dir = 'entry/src/main/ets/services/pro/';
  const policy = load(dir + 'ProConnectionEnvelope.ets');
  const adapter = load(dir + 'ProConnectionHostAdapter.ets');
  const { ProConnectionTransaction } = load(dir + 'ProConnectionTransaction.ets');
  const { ProContinuationReceiptChannel } = load(dir + 'ProContinuationReceiptChannel.ets');
  const { ProContinuationService, PRO_CONTINUATION_PARAM } = load(dir + 'ProContinuationService.ets');
  const service = ProContinuationService.getInstance();
  const envelope = () => ({ version: 1, purpose: 'continuation', transferId: 'b'.repeat(32),
    channelId: 'rd_' + 'c'.repeat(32), owner: state.scope.ownerScopeId, createdAt: state.now,
    expiresAt: state.now + 120000, connection: adapter.describeProSshConnection(state.host, 'files', '/home/alice/work', context) });
  const offer = () => ({ windowId: 9, isCurrent: () => true,
    describe: () => adapter.describeProSshConnection(state.host, 'files', '/home/alice/work', context), close() { state.closed = true; } });
  function proxyProfile(type = 'socks5') {
    return { schemaVersion: 1, hostId: state.host.id, route: { schemaVersion: 1, type,
      endpointHost: state.host.host, endpointPort: state.host.port, hops: [], connectTimeoutMs: 10000 },
      ...(type === 'direct' ? {} : { proxyHost: 'proxy.example.test', proxyPort: 1080, proxyAuthRequired: false }) };
  }
  function terminal() {
    const file = path.join(root, 'entry/src/main/ets/pages/SshTerminal.ets');
    const original = fs.readFileSync(file, 'utf8');
    const names = ['proContinuationSessionCurrent', 'prepareProContinuation', 'restoreProContinuation', 'onProContinuationPaneChange'];
    const methods = names.map(name => {
      const start = original.search(new RegExp(`  private (?:async )?${name}\\(`));
      assert.ok(start >= 0, 'actual page method exists: ' + name);
      let cursor = original.indexOf('{', start), depth = 1;
      for (cursor++; depth > 0 && cursor < original.length; cursor++) {
        if (original[cursor] === '{') depth++;
        if (original[cursor] === '}') depth--;
      }
      return original.slice(start, cursor);
    }).join('\n');
    const compiled = ts.transpileModule('class Terminal {\n' + methods + '\n}\nmodule.exports = Terminal;', {
      compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
    }).outputText;
    const module = { exports: {} };
    vm.runInNewContext(compiled, { module, SSH_STATE_CONNECTED: 2,
      ProContinuationService: { getInstance: () => service },
      HostSyncService: { getInstance: () => ({ getHost: id => state.host?.id === id ? state.host : undefined }) },
      describeProSshConnection: adapter.describeProSshConnection, getContext: () => context,
      promptAction: { showToast() {} }, window: { findWindow: () => ({ getWindowProperties: () => ({ id: 9 }) }) }
    }, { filename: file });
    const page = new module.exports();
    Object.assign(page, { hostId: state.host.id, connected: true, isDesktopDevice: false, terminalClosing: false,
      pageGeneration: 3, sshBindingGeneration: 4, sessionId: 17, sshSessionGeneration: state.nativeGeneration,
      showSftpPanel: true, sftpPath: '/home/alice/work', proContinuationPaneEpoch: 0,
      sftpRootSheetClosing: false, sftpCloseRootAfterPeerPicker: false, proContinuationRestoreRunning: false,
      proConnectionTransferId: '', getUIContext: () => ({ getWindowName: () => 'window' }),
      loader: { getConnectionState: () => state.nativeState,
        getSshTerminalDiagnostics: () => ({ sessionGeneration: state.nativeGeneration }) },
      closeSessionAndBack() { state.closed = true; }, stopSftpKnock() {},
      openSftpPanel() { if (!this.showSftpPanel) { this.showSftpPanel = true; this.onProContinuationPaneChange(); } },
      normalizeRemoteDir: value => value,
      async refreshSftp(directory) { if (state.directoryWait) await state.directoryWait.promise; this.sftpPath = directory; return true; }
    });
    return page;
  }
  function entryAbility() {
    const file = path.join(root, 'entry/src/main/ets/entryability/EntryAbility.ets');
    const source = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
    }).outputText;
    const module = { exports: {} };
    const events = [];
    class UIAbility {
      constructor() { this.context = { ...context,
        restoreWindowStage() { events.push('restore'); },
        async terminateSelf() { events.push('terminate'); }
      }; }
    }
    vm.runInNewContext(source, { module, exports: module.exports, LocalStorage: class {},
      require(id) {
        if (id === '@kit.AbilityKit') return { ...mocks[id], UIAbility,
          AbilityConstant: { ...constants, LaunchReason: { CONTINUATION: 3 } } };
        if (id === '../services/pro/ProContinuationService') return {
          ProContinuationService: { getInstance: () => service }, PRO_CONTINUATION_PARAM
        };
        return {}; // These dependencies are not used by the actual Want-receiving method.
      }
    }, { filename: file });
    return { ability: new module.exports.default(), events };
  }
  return { state, context, policy, adapter, service, envelope, offer, ProConnectionTransaction,
    ProContinuationReceiptChannel, entryAbility, proxyProfile, terminal, key: PRO_CONTINUATION_PARAM };
}

test('wire serialization reads only whitelist fields and detaches mutable view', () => {
  const f = fixture(); const envelope = f.envelope(); const encoded = JSON.stringify(envelope);
  assert.equal(encoded.includes('NEVER_EXPORT'), false);
  const parsed = f.policy.parseProConnectionEnvelope(encoded); assert.ok(parsed);
  parsed.connection.view.sshDirectory = '/changed'; assert.equal(envelope.connection.view.sshDirectory, '/home/alice/work');
  assert.ok(Buffer.byteLength(encoded) < 100000);
});
test('malformed, oversized, sensitive and prototype fields fail closed', () => {
  const f = fixture();
  for (const body of ['', '{', '[]', 'null', '0', ' '.repeat(8193)]) assert.equal(f.policy.parseProConnectionEnvelope(body), null);
  for (const edit of [e => { e.password = 'secret'; }, e => { e.connection.password = 'secret'; },
    e => { e.connection.view.command = 'run'; }, e => { e.connection.host = 'user@host'; },
    e => { e.connection.host = 'https://host/path'; }, e => { e.connection.label = '\u202ehidden'; },
    e => { e.connection.view.scale = 100; }, e => { e.connection.port = 22.5; },
    e => { e.connection.view.sshDirectory = '../../local'; }, e => { e.version = 2; }]) {
    const envelope = f.envelope(); edit(envelope); assert.equal(f.policy.parseProConnectionEnvelope(JSON.stringify(envelope)), null);
  }
  const encoded = JSON.stringify(f.envelope()).replace('"version":1', '"__proto__":{},"version":1');
  assert.equal(f.policy.parseProConnectionEnvelope(encoded), null);
});
test('expired, future and overlong validity never become fresh invitations', () => {
  const f = fixture();
  for (const edit of [e => { e.expiresAt = f.state.now; }, e => { e.createdAt += 10000; },
    e => { e.expiresAt += 1; }, e => { e.createdAt = -1; }]) {
    const envelope = f.envelope(); edit(envelope); assert.equal(f.policy.parseProConnectionEnvelope(JSON.stringify(envelope)), null);
  }
});
test('sharing cannot carry account ownership or a local host reference', () => {
  const f = fixture(); const e = f.envelope(); e.purpose = 'share';
  assert.equal(f.policy.parseProConnectionEnvelope(JSON.stringify(e)), null);
  e.owner = ''; e.connection.hostReference = '';
  assert.ok(f.policy.parseProConnectionEnvelope(JSON.stringify(e)));
});
test('proxy source cannot silently export as a direct connection', () => {
  const f = fixture(); f.state.host.sshProxyType = 'ssh_jump';
  assert.equal(f.adapter.describeProSshConnection(f.state.host, 'terminal', '', f.context), null);
  f.state.host.sshProxyType = 'direct'; f.state.profileRaw = JSON.stringify([f.proxyProfile()]);
  assert.equal(f.adapter.describeProSshConnection(f.state.host, 'terminal', '', f.context), null);
});
test('destination needs confirmation, own entitlement and account before native readiness', () => {
  const f = fixture(); const tx = new f.ProConnectionTransaction(f.envelope());
  assert.equal(tx.ready(f.state.scope.ownerScopeId, true), null);
  assert.equal(tx.begin('wrong-owner', true, true), false);
  assert.equal(tx.begin(f.state.scope.ownerScopeId, false, true), false);
  assert.equal(tx.begin(f.state.scope.ownerScopeId, true, false), false);
  assert.equal(tx.begin(f.state.scope.ownerScopeId, true, true), true);
  assert.equal(tx.begin(f.state.scope.ownerScopeId, true, true), false);
  assert.equal(tx.mayOfferSourceClose(), false);
  assert.ok(tx.ready(f.state.scope.ownerScopeId, true));
});
test('wrong, duplicate and expired receipts cannot close the source', () => {
  const f = fixture(); const tx = new f.ProConnectionTransaction(f.envelope());
  tx.begin(f.state.scope.ownerScopeId, true, true);
  const receipt = { version: 1, transferId: 'b'.repeat(32), owner: f.state.scope.ownerScopeId, result: 'ready' };
  assert.equal(tx.acceptReceipt(JSON.stringify({ ...receipt, transferId: 'd'.repeat(32) }), f.state.scope.ownerScopeId, true), false);
  assert.equal(tx.acceptReceipt(JSON.stringify(receipt), f.state.scope.ownerScopeId, false), false);
  assert.equal(tx.acceptReceipt(JSON.stringify(receipt), f.state.scope.ownerScopeId, true), true);
  assert.equal(tx.acceptReceipt(JSON.stringify(receipt), f.state.scope.ownerScopeId, true), false);
  f.state.now += 120000; assert.equal(tx.mayOfferSourceClose(), false);
});
test('cancellation and timeout remain terminal and preserve the source', () => {
  const f = fixture(); const tx = new f.ProConnectionTransaction(f.envelope()); tx.cancel();
  assert.equal(tx.begin(f.state.scope.ownerScopeId, true, true), false);
  const other = new f.ProConnectionTransaction(f.envelope()); f.state.now += 120000;
  assert.equal(other.state(), 'expired'); assert.equal(other.mayOfferSourceClose(), false);
});
test('receipt channel closes a late join and does not touch a newer object', async () => {
  const f = fixture(); const old = deferred(); f.state.joinWait = old;
  const channel = new f.ProContinuationReceiptChannel();
  const waiting = channel.join(f.context, f.envelope().channelId, f.envelope().expiresAt, () => false, () => {});
  await settle(); const oldObject = f.state.objects[0]; channel.close(); f.state.joinWait = null;
  assert.equal(await channel.join(f.context, 'rd_' + 'd'.repeat(32), f.envelope().expiresAt, () => false, () => {}), true);
  old.resolve(); assert.equal(await waiting, false);
  assert.equal(oldObject.calls.at(-1), ''); assert.notEqual(f.state.objects[1].calls.at(-1), '');
});
test('platform object failure and invalid oversized receipt are contained', async () => {
  const f = fixture(); const channel = new f.ProContinuationReceiptChannel(); f.state.createError = true;
  assert.equal(await channel.join(f.context, f.envelope().channelId, f.envelope().expiresAt, () => false, () => {}), false);
  f.state.createError = false; let received = 0;
  assert.equal(await channel.join(f.context, f.envelope().channelId, f.envelope().expiresAt, () => { received++; return true; }, () => {}), true);
  f.state.objects[0].receipt = 'x'.repeat(513); f.state.objects[0].emit(f.envelope().channelId); assert.equal(received, 0);
  f.state.now += 120000; assert.equal(channel.send('{}'), false);
});
test('official continuation disables page-stack/native-handle copy and automatic source exit', async () => {
  const f = fixture(); assert.equal(await f.service.prepare(f.context, f.offer()), true);
  const parameters = {}; assert.equal(await f.service.onContinue(9, parameters), 0);
  assert.equal(parameters.pageStack, false); assert.equal(parameters.sourceExit, false);
  assert.ok(f.policy.parseProConnectionEnvelope(parameters[f.key]));
  assert.equal(await f.service.onContinue(9, {}), 1); assert.equal(f.state.closed, undefined);
});
test('only a matching ready receipt enables an explicit source close', async () => {
  const f = fixture(); await f.service.prepare(f.context, f.offer()); const params = {}; await f.service.onContinue(9, params);
  const e = JSON.parse(params[f.key]); const object = f.state.objects[0];
  assert.equal(f.service.closeConfirmedSource(9), false);
  object.receipt = JSON.stringify({ version: 1, transferId: e.transferId, owner: e.owner, result: 'ready' });
  object.emit(e.channelId); assert.equal(f.state.closed, undefined);
  assert.equal(f.service.snapshot().sourceCloseAllowed, true);
  assert.equal(f.service.closeConfirmedSource(8), false); assert.equal(f.service.closeConfirmedSource(9), true);
  assert.equal(f.state.closed, true);
});
test('permission resolution after account switch cannot arm the previous account', async () => {
  const f = fixture(); const wait = deferred(); f.state.permission = false; f.state.permissionWait = wait;
  const prepare = f.service.prepare(f.context, f.offer()); await settle();
  f.state.scope = { ...f.state.scope, generation: 2, ownerScopeId: 'owner-' + 'd'.repeat(64) };
  f.state.permission = true; wait.resolve(); assert.equal(await prepare, false); assert.equal(f.state.missions.length, 0);
});
test('wrong window, revoked feature and desktop ability cannot initiate continuation', async () => {
  const f = fixture(); assert.equal(await f.service.prepare({ ...f.context, abilityInfo: { name: 'RemoteSessionAbility' } }, f.offer()), false);
  await f.service.prepare(f.context, f.offer()); assert.equal(await f.service.onContinue(10, {}), 1);
  f.state.allowed = false; f.state.listeners.forEach(fn => fn());
  assert.equal(await f.service.onContinue(9, {}), 1); assert.equal(f.state.closed, undefined);
});
test('source preparation expires even before a suspended timer is dispatched', async () => {
  const f = fixture(); await f.service.prepare(f.context, f.offer()); f.state.now += 120000;
  assert.equal(await f.service.onContinue(9, {}), 1); assert.equal(f.state.closed, undefined);
});
test('source business service refuses a host from another application account', async () => {
  const f = fixture(); f.state.host.userId = 'owner-' + 'd'.repeat(64);
  assert.equal(await f.service.prepare(f.context, f.offer()), false); assert.equal(f.state.objects.length, 0);
});
test('a fresh mission stays inactive until explicitly prepared', async () => {
  const f = fixture(); f.service.initializeMission(f.context); await settle();
  assert.equal(f.state.missions.at(-1), 1); await f.service.prepare(f.context, f.offer());
  assert.equal(f.state.missions.at(-1), 0);
});
test('real Ability receiver ignores public Wants and synchronously restores valid cold continuation', () => {
  const f = fixture(); const { ability, events } = f.entryAbility();
  const want = { parameters: { [f.key]: JSON.stringify(f.envelope()), pageStack: false, sourceExit: false } };
  assert.equal(ability.acceptProContinuationWant(want, { launchReason: 0 }), true);
  assert.equal(f.service.snapshot().incoming, false); assert.equal(events.length, 0);
  assert.equal(ability.acceptProContinuationWant(want, { launchReason: 3 }), true);
  assert.deepEqual(events, ['restore']); assert.equal(f.service.snapshot().incoming, true);
});
test('real Ability receiver rejects a foreign Router stack and preserves an existing warm window', () => {
  for (const warm of [false, true]) {
    const f = fixture(); const { ability, events } = f.entryAbility();
    if (warm) ability.windowStage = {};
    const want = { parameters: { [f.key]: JSON.stringify(f.envelope()), pageStack: true, sourceExit: false } };
    assert.equal(ability.acceptProContinuationWant(want, { launchReason: 3 }), false);
    assert.deepEqual(events, warm ? [] : ['terminate']); assert.equal(f.service.snapshot().incoming, false);
  }
});
test('valid warm continuation is announced without replacing an existing Router stack', () => {
  const f = fixture(); const { ability, events } = f.entryAbility();
  ability.windowStage = { getMainWindowSync: () => ({ getUIContext: () => ({
    getPromptAction: () => ({ showToast() { events.push('toast'); } })
  }) }) };
  const want = { parameters: { [f.key]: JSON.stringify(f.envelope()), pageStack: false, sourceExit: false } };
  assert.equal(ability.acceptProContinuationWant(want, { launchReason: 3 }), true);
  assert.deepEqual(events, ['toast']);
});
test('repeated incoming envelopes are not queued or replayed after cancellation', () => {
  const f = fixture(); const serialized = JSON.stringify(f.envelope());
  assert.equal(f.service.ingest(serialized), true); assert.equal(f.service.ingest(serialized), false);
  f.service.cancelIncoming(); assert.equal(f.service.ingest(serialized), false);
});
test('target reconnect uses only matching existing same-account host and restores by transaction id', async () => {
  const f = fixture(); const e = f.envelope(); f.service.ingest(JSON.stringify(e));
  assert.equal(await f.service.accept(f.context), f.state.host);
  assert.equal(f.service.restoreView('wrong', f.state.host), null);
  assert.equal(f.service.restoreView(e.transferId, f.state.host).sshDirectory, '/home/alice/work');
  assert.equal(f.state.objects[0].receipt, ''); // Opening preflight is not native readiness.
  assert.equal(f.service.complete(e.transferId, f.state.host), true);
  assert.equal(JSON.parse(f.state.objects[0].receipt).result, 'ready');
});
test('target host mutation or account change during channel join prevents connecting', async () => {
  for (const mutation of [f => { f.state.host.host = 'different.example.test'; },
    f => { f.state.scope = { ...f.state.scope, generation: 2 }; }]) {
    const f = fixture(); const wait = deferred(); f.state.joinWait = wait; f.service.ingest(JSON.stringify(f.envelope()));
    const accepting = f.service.accept(f.context); await settle(); mutation(f); wait.resolve();
    assert.equal(await accepting, null);
  }
});
test('ready target receipts are closed on account change and after source acknowledgement', async () => {
  for (const action of ['account', 'acknowledged']) {
    const f = fixture(); const e = f.envelope(); f.service.ingest(JSON.stringify(e));
    await f.service.accept(f.context); assert.equal(f.service.complete(e.transferId, f.state.host), true);
    const object = f.state.objects[0];
    if (action === 'account') {
      f.state.scope = { ...f.state.scope, generation: 2 }; f.state.listeners.forEach(fn => fn());
    } else { object.acknowledged = e.channelId; object.emit(e.channelId); }
    assert.equal(f.service.snapshot().incoming, false); assert.equal(object.calls.at(-1), '');
    assert.equal(f.state.closed, undefined);
  }
});
test('bounded old join expiry cannot close a newly prepared source channel', async () => {
  const f = fixture(); const wait = deferred(); f.state.joinWait = wait;
  await f.service.prepare(f.context, f.offer()); const old = f.service.onContinue(9, {}); await settle();
  const oldTimeout = [...f.state.timers.values()].find(x => x.delay === 2500).callback;
  f.service.cancelSource(); f.state.joinWait = null; await f.service.prepare(f.context, f.offer());
  assert.equal(await f.service.onContinue(9, {}), 0); oldTimeout(); assert.equal(await old, 1);
  assert.notEqual(f.state.objects[1].calls.at(-1), ''); wait.resolve(); await settle();
});

test('canonical direct profiles override legacy fields; corrupt or unreadable profiles never imply direct', () => {
  const f = fixture(); f.state.host.sshProxyType = 'socks5'; f.state.host.proxyHost = 'old-proxy';
  f.state.profileRaw = JSON.stringify([f.proxyProfile('direct')]);
  assert.ok(f.adapter.describeProSshConnection(f.state.host, 'terminal', '', f.context));
  f.state.profileReadable = false;
  assert.equal(f.adapter.describeProSshConnection(f.state.host, 'terminal', '', f.context), null);
  f.state.profileReadable = true; f.state.profileRaw = '{';
  assert.equal(f.adapter.describeProSshConnection(f.state.host, 'terminal', '', f.context), null);
});
test('source and target re-read canonical routes after permission and channel awaits', async () => {
  for (const side of ['source', 'target']) {
    for (const phase of ['permission', 'join']) {
      const f = fixture(); const envelope = f.envelope(); const description = envelope.connection;
      const offer = { ...f.offer(), describe: () => description };
      const wait = deferred();
      if (phase === 'permission') { f.state.permission = false; f.state.permissionWait = wait; }
      else { f.state.joinWait = wait; }
      let action;
      if (side === 'target') { f.service.ingest(JSON.stringify(envelope)); action = f.service.accept(f.context); }
      else if (phase === 'permission') { action = f.service.prepare(f.context, offer); }
      else { await f.service.prepare(f.context, offer); action = f.service.onContinue(9, {}); }
      await settle(); f.state.profileRaw = JSON.stringify([f.proxyProfile()]); f.state.permission = true; wait.resolve();
      assert.equal(await action, side === 'target' ? null : phase === 'permission' ? false : 1);
      assert.equal(f.state.closed, undefined);
    }
  }
});
test('target completion re-reads current hosts and profiles instead of trusting a captured object', async () => {
  for (const mutation of [f => { f.state.profileRaw = JSON.stringify([f.proxyProfile()]); },
    f => { f.state.host = { ...f.state.host, host: 'changed.example.test' }; },
    f => { f.state.hostReady = false; }, f => { f.state.profileReadable = false; }]) {
    const f = fixture(); const e = f.envelope(); f.service.ingest(JSON.stringify(e));
    const captured = await f.service.accept(f.context); assert.ok(captured); mutation(f);
    assert.equal(f.service.restoreView(e.transferId, captured), null);
    assert.equal(f.service.complete(e.transferId, captured), false); assert.equal(f.state.objects[0].receipt, '');
  }
});
test('actual source page binds native generation and CONNECTED before accepting an old close receipt', async () => {
  for (const mutation of [f => { f.state.nativeGeneration++; }, f => { f.state.nativeState = 1; }]) {
    const f = fixture(); const page = f.terminal(); await page.prepareProContinuation();
    const params = {}; assert.equal(await f.service.onContinue(9, params), 0);
    const e = JSON.parse(params[f.key]); const object = f.state.objects[0];
    object.receipt = JSON.stringify({ version: 1, transferId: e.transferId, owner: e.owner, result: 'ready' });
    object.emit(e.channelId); assert.equal(f.service.snapshot().sourceCloseAllowed, true);
    mutation(f);
    assert.equal(f.service.snapshot().sourceCloseAllowed, false);
    assert.equal(f.service.closeConfirmedSource(9), false); assert.equal(f.state.closed, undefined);
  }
});
test('actual target page requires declared pane, directory and native generation after slow SFTP restore', async () => {
  for (const change of ['none', 'close', 'close-reopen', 'closing', 'generation', 'host', 'route']) {
    const f = fixture(); const e = f.envelope(); f.service.ingest(JSON.stringify(e)); await f.service.accept(f.context);
    const page = f.terminal(); page.proConnectionTransferId = e.transferId;
    const wait = deferred(); f.state.directoryWait = wait; const restoring = page.restoreProContinuation(); await settle();
    if (change === 'close' || change === 'close-reopen') { page.showSftpPanel = false; page.onProContinuationPaneChange(); }
    if (change === 'close-reopen') { page.openSftpPanel(); }
    if (change === 'closing') { page.sftpRootSheetClosing = true; }
    if (change === 'generation') { f.state.nativeGeneration++; page.sshSessionGeneration = f.state.nativeGeneration; }
    if (change === 'host') { f.state.host = { ...f.state.host, host: 'changed.example.test' }; }
    if (change === 'route') { f.state.profileRaw = JSON.stringify([f.proxyProfile()]); }
    wait.resolve(); await restoring;
    assert.equal(f.state.objects[0].receipt !== '', change === 'none', change);
  }
});
test('transition start fences simulation before scope generation changes and failed transition never revives source', async () => {
  const f = fixture(); await f.service.prepare(f.context, f.offer()); const scope = f.state.scope;
  f.state.transitionListeners.forEach(fn => fn(true)); assert.equal(f.state.allowed, true);
  assert.equal(f.state.scope, scope); assert.equal(await f.service.onContinue(9, {}), 1);
  assert.equal(await f.service.prepare(f.context, f.offer()), false);
  f.state.transitionListeners.forEach(fn => fn(false));
  assert.equal(await f.service.onContinue(9, {}), 1); assert.equal(f.service.closeConfirmedSource(9), false);
});
test('transition cancels pending target acceptance and ready channels before account mutation', async () => {
  for (const phase of ['offered', 'permission', 'ready']) {
    const f = fixture(); const e = f.envelope(); f.service.ingest(JSON.stringify(e));
    let accepting; let wait;
    if (phase === 'permission') {
      wait = deferred(); f.state.permission = false; f.state.permissionWait = wait;
      accepting = f.service.accept(f.context); await settle();
    }
    if (phase === 'ready') { await f.service.accept(f.context); f.service.complete(e.transferId, f.state.host); }
    f.state.transitionListeners.forEach(fn => fn(true));
    assert.equal(f.service.snapshot().incoming, false); assert.equal(f.service.complete(e.transferId, f.state.host), false);
    if (phase === 'permission') { f.state.permission = true; wait.resolve(); assert.equal(await accepting, null); }
    f.state.transitionListeners.forEach(fn => fn(false)); assert.equal(await f.service.accept(f.context), null);
  }
});
test('unconfirmed cold Want survives account bootstrap only as data and cannot execute during transition', async () => {
  const f = fixture(); const e = f.envelope(); const bound = f.state.scope;
  f.state.scope = { ...bound, kind: 'device_local', ownerScopeId: '', generation: 0 };
  assert.equal(f.service.ingest(JSON.stringify(e)), true);
  f.state.transitionListeners.forEach(fn => fn(true));
  assert.equal(f.service.snapshot().incoming, true); assert.equal(await f.service.accept(f.context), null);
  assert.equal(f.state.objects.length, 0);
  f.state.scope = bound; f.state.transitionListeners.forEach(fn => fn(false));
  assert.equal(await f.service.accept(f.context), f.state.host);
});

(async () => {
  for (const { name, body } of tests) { await body(); process.stdout.write('PASS ' + name + '\n'); }
  process.stdout.write(`${tests.length} production connection checks passed\n`);
})().catch(error => { process.stderr.write(error.stack + '\n'); process.exitCode = 1; });
