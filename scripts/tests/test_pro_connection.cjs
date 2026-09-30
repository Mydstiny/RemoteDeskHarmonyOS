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
    async setMissionContinueState(value) { state.missions.push(value);
      if(value===0 && state.missionWait) await state.missionWait.promise; } };
  const constants = { ContinueState: { ACTIVE: 0, INACTIVE: 1 }, OnContinueResult: { AGREE: 0, REJECT: 1 } };
  const mocks = {
    '@kit.AbilityKit': { AbilityConstant: constants,
      wantConstant: { Params: { SUPPORT_CONTINUE_PAGE_STACK_KEY: 'pageStack', SUPPORT_CONTINUE_SOURCE_EXIT_KEY: 'sourceExit' } },
      abilityAccessCtrl: { GrantStatus: { PERMISSION_GRANTED: 0 }, createAtManager: () => ({
        checkAccessToken: async () => state.permission ? 0 : -1,
        requestPermissionsFromUser: async () => {
          state.permissionRequests = (state.permissionRequests ?? 0) + 1;
          if (state.permissionWait) await state.permissionWait.promise;
          return { authResults: [state.permission ? 0 : -1] };
        }
      }) } },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {} } },
    '@kit.BasicServicesKit': {},
    '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(text) { return new Uint8Array(Buffer.from(text)); } } } },
    '@kit.CryptoArchitectureKit': { cryptoFramework: { createMd: () => { const hash = crypto.createHash('sha256');
      return { updateSync: input => hash.update(Buffer.from(input.data)), digestSync: () => ({ data: new Uint8Array(hash.digest()) }) }; },
      createRandom: () => ({
      generateRandomSync: n => ({ data: new Uint8Array(crypto.randomBytes(n)) })
    }) } },
    '@kit.ArkData': { preferences: { getPreferencesSync: () => ({ getSync() {
      if (!state.profileReadable) throw new Error('unreadable'); return state.profileRaw;
    } }) }, distributedDataObject: { create: (_context, fields) => {
      if (state.createError) throw new Error('platform create failed');
      // A target-side credential object sees what the source offered (the platform would sync it).
      if ('secret' in fields && fields.secret === '' && state.remoteSecret) fields = { ...fields, secret: state.remoteSecret };
      const object = { ...fields, calls: [], callback: null,
        on(event, callback) { assert.ok(event === 'change' || event === 'status'); this.callback = callback; },
        off(event, callback) { assert.equal(callback, this.callback); this.callback = null; },
        async save(device) { this.savedTo = device; }, async revokeSave() { this.revoked = true; },
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
      AppStorage: { get: () => state.rdpIdentityMode ?? 1 },
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
          isReady: () => state.hostReady, getHost: id => state.host?.id === id ? state.host : undefined,
          getRdpCredential: () => state.credential
        }) } };
        if (id.endsWith('/VncHostService')) return { VncHostService: { getInstance: () => ({
          isReady: () => state.vncHostReady ?? state.hostReady,
          find: id => state.vncHost?.id === id ? state.vncHost : null
        }) } };
        if (id.endsWith('/VncGatewayService')) return { VncGatewayService: { getInstance: () => ({
          find: id => state.vncGateway?.id === id ? state.vncGateway : null
        }) } };
        if (id.endsWith('/VncHostListProjectionPolicy')) return {
          vncHostRecordIdFromUiId: id => typeof id === 'string' && id.startsWith('vnc:') ? id.substring(4) : '',
          projectVncHost: view => ({ id: 'vnc:' + view.id, userId: view.userId, label: view.label,
            protocol: 'vnc', host: view.host, port: view.port, username: view.username ?? '', sourceType: 'vnc' })
        };
        if (id === './ProAppRuntime') return { ProAppRuntime: { getInstance: () => ({ runtime,
          context: protocol => ({ protocol, capabilities: [], grantedPermissions: [], requestablePermissions: [] }) }) } };
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
  const { ProContinuationService, PRO_CONTINUATION_PARAM, PRO_CONTINUATION_LIBRARY_PARAM } =
    load(dir + 'ProContinuationService.ets');
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
    const names = ['proContinuationSessionCurrent', 'prepareProContinuation', 'proContinuationDescribe',
      'armProContinuation', 'restoreProContinuation', 'onProContinuationPaneChange'];
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
      ProContinuationPreferences: { getInstance: () => ({ settings: () => ({ auto: state.autoContinuation ?? false, credentialMode: 'manual' }) }) },
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
          ProContinuationService: { getInstance: () => service }, PRO_CONTINUATION_PARAM,
          PRO_CONTINUATION_LIBRARY_PARAM
        };
        return {}; // These dependencies are not used by the actual Want-receiving method.
      }
    }, { filename: file });
    return { ability: new module.exports.default(), events };
  }
  function sessionAbility() {
    const file = path.join(root, 'entry/src/main/ets/entryability/RemoteSessionAbility.ets');
    const events = [];
    class Storage {
      constructor(values = {}) { this.values = { ...values }; }
      get(key) { return this.values[key]; }
      set(key, value) { this.values[key] = value; return true; }
    }
    class UIAbility {
      constructor() {
        this.context = { ...context,
          abilityInfo: { name: 'RemoteSessionAbility', bundleName: 'test.remotedesk' },
          restoreWindowStage() {
            events.push(['restore']); if (state.restoreError) throw new Error('restore failed');
          },
          async terminateSelf() { events.push(['terminate']); },
          async startAbility(want) {
            events.push(['start', want]);
            if (state.libraryWait) await state.libraryWait.promise;
            if (state.libraryError) throw new Error('start failed');
          }
        };
      }
    }
    const coordinator = {
      activate(id) { events.push(['activate', id]); return state.windowRecord ?? null; },
      resolve() { return state.windowRecord ?? null; },
      registerTargetCloser() {}, release(id) { events.push(['release', id]); },
      promoteTargetWindow: async () => true,
      failBeforeReady(id, reason) { events.push(['failed', id, reason]); }
    };
    const module = { exports: {} };
    vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
    }).outputText, { module, exports: module.exports, LocalStorage: Storage,
      require(id) {
        if (id === '@kit.AbilityKit') return { ...mocks[id], UIAbility,
          AbilityConstant: { ...constants, LaunchReason: { CONTINUATION: 3 } },
          bundleManager: { SupportWindowMode: { FULL_SCREEN: 1, SPLIT: 2, FLOATING: 3 } } };
        if (id === '@kit.PerformanceAnalysisKit') return { hilog: { info() {}, warn() {}, error() {} } };
        if (id === '../services/RemoteSessionWindowCoordinator') return {
          RemoteSessionWindowCoordinator: { getInstance: () => coordinator }
        };
        if (id === '../services/pro/ProContinuationService') return {
          ProContinuationService: { getInstance: () => service }, PRO_CONTINUATION_PARAM
        };
        // A continuation cold start loads Pro display choices before any gate renders.
        if (id === '../services/pro/ProFeatureVisibility') return {
          ProFeatureVisibility: { getInstance: () => ({ load() { state.proVisibilityLoads = (state.proVisibilityLoads ?? 0) + 1; } }) }
        };
        return {};
      }
    }, { filename: file });
    const ability = new module.exports.default();
    const stage = {
      storage: null,
      async loadContent(page, storage) {
        events.push(['load', page]); this.storage = storage;
        if (state.loadWait) await state.loadWait.promise;
        if (state.loadError) throw new Error('load failed');
      },
      getMainWindowSync() { return { getWindowProperties: () => ({ id: 9 }) }; }
    };
    function bootstrap() {
      const file = path.join(root, 'entry/src/main/ets/pages/RemoteSessionWindowBootstrap.ets');
      const original = fs.readFileSync(file, 'utf8');
      const methods = ['aboutToAppear', 'aboutToDisappear', 'openContinuationLibrary', 'closeWindow'].map(name => {
        const start = original.search(new RegExp(`^  (?:private )?(?:async )?${name}\\(`, 'm'));
        assert(start >= 0, name);
        const open = original.indexOf('{', start);
        const scanner = ts.createScanner(ts.ScriptTarget.Latest, true, ts.LanguageVariant.Standard, original.slice(open));
        let depth = 0, token;
        do {
          token = scanner.scan();
          if (token === ts.SyntaxKind.OpenBraceToken) depth++;
          if (token === ts.SyntaxKind.CloseBraceToken) depth--;
        } while (depth > 0 && token !== ts.SyntaxKind.EndOfFileToken);
        assert.equal(depth, 0);
        return original.slice(start, open + scanner.getTextPos());
      });
      const module = { exports: {} };
      vm.runInNewContext(ts.transpileModule('class Bootstrap {\n' + methods.join('\n') +
        '\n}\nmodule.exports = Bootstrap;', {
        compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
      }).outputText, { module,
        ProContinuationService: { getInstance: () => service }, PRO_CONTINUATION_LIBRARY_PARAM,
        RemoteSessionWindowCoordinator: { getInstance: () => coordinator },
        promptAction: { showToast() {} }
      }, { filename: file });
      const page = new module.exports();
      Object.assign(page, { routing: false, live: false, errorMessage: '', openingContinuation: false,
        getUIContext: () => ({ getSharedLocalStorage: () => stage.storage, getHostContext: () => ability.context }) });
      return page;
    }
    return { ability, events, stage, bootstrap };
  }
  return { state, context, policy, adapter, service, envelope, offer, ProConnectionTransaction, load,
    ProContinuationReceiptChannel, entryAbility, sessionAbility, proxyProfile, terminal,
    rdpPolicy: load(dir + 'ProRdpConnectionIdentity.ets'),
    key: PRO_CONTINUATION_PARAM, libraryKey: PRO_CONTINUATION_LIBRARY_PARAM };
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
test('wrong window, revoked feature and unrelated ability cannot initiate continuation', async () => {
  const f = fixture(); assert.equal(await f.service.prepare({ ...f.context, abilityInfo: { name: 'UnrelatedAbility' } }, f.offer()), false);
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
  // A new transfer after a failed or still pending one replaces it instead of reporting busy.
  const first = f.envelope(); first.transferId = '1'.repeat(32); first.channelId = 'rd_' + '2'.repeat(32);
  const second = f.envelope(); second.transferId = '3'.repeat(32); second.channelId = 'rd_' + '4'.repeat(32);
  assert.equal(f.service.ingest(JSON.stringify(first)), true); assert.equal(f.service.ingest(JSON.stringify(second)), true);
  assert.equal(f.service.incomingId(), second.transferId);
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
  assert.notEqual(f.state.objects.filter(o => 'receipt' in o)[1].calls.at(-1), ''); wait.resolve(); await settle();
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
test('always-on Pro continuation never prompts, stays armed and carries the directory current at continue time', async () => {
  const f = fixture(); const page = f.terminal(); f.state.permission = false;
  assert.equal(await page.armProContinuation(true, false), false);
  assert.equal(f.service.lastPrepareFailure(), 'permission'); assert.equal(f.state.permissionRequests ?? 0, 0);
  f.state.permission = true;
  assert.equal(await page.armProContinuation(true, false), true); assert.equal(f.service.armed(9), true);
  assert.match(f.service.snapshot().sourceMessage, /已开启/);
  page.sftpPath = '/home/alice/other';
  const params = {}; assert.equal(await f.service.onContinue(9, params), 0);
  assert.equal(JSON.parse(params[f.key]).connection.view.sshDirectory, '/home/alice/other');
  page.showSftpPanel = false; page.onProContinuationPaneChange();
  assert.equal(page.proContinuationDescribe().view.sshPane, 'terminal');
  assert.equal(f.state.permissionRequests ?? 0, 0);
});
test('opt-in credential transfer rides a separate continuation parameter, never the envelope, and is used once', async () => {
  const f = fixture(); const dir = 'entry/src/main/ets/services/pro/';
  const prefs = f.load(dir + 'ProContinuationPreferences.ets').ProContinuationPreferences.getInstance();
  const secretKey = f.load(dir + 'ProContinuationService.ets').PRO_CONTINUATION_SECRET_PARAM;
  const secret = { kind: 'key', password: '', privateKeyPem: '-----BEGIN OPENSSH PRIVATE KEY-----\nabc', passphrase: 'pp' };
  const offer = f.offer(); offer.secret = () => secret;
  await f.service.prepare(f.context, offer); let params = {};
  assert.equal(await f.service.onContinue(9, params), 0);
  assert.equal(secretKey in params, false, 'manual mode attaches nothing');
  f.service.cancelSource(); prefs.value.credentialMode = 'transfer';
  try {
    await f.service.prepare(f.context, offer); params = {};
    assert.equal(await f.service.onContinue(9, params), 0);
    assert.equal(params[f.key].includes('PRIVATE KEY'), false, 'the envelope never carries it');
    assert.equal(params[secretKey], JSON.stringify(secret));
    // Target: validated at ingest, moved to the one-shot host-bound handoff only after accept.
    const t = fixture(); const te = t.envelope();
    const handoff = t.load(dir + 'ProContinuationCredentials.ets').ProContinuationCredentialHandoff.getInstance();
    assert.equal(t.service.ingest(JSON.stringify(te), params[secretKey]), true);
    assert.equal(handoff.take(te.connection.hostReference, te.owner), null, 'nothing before accept');
    assert.ok(await t.service.accept(t.context));
    assert.equal(handoff.take('other-host', te.owner), null);
    assert.equal(JSON.stringify(handoff.take(te.connection.hostReference, te.owner)), JSON.stringify({ ...secret, username: '' }));
    assert.equal(handoff.take(te.connection.hostReference, te.owner), null, 'one use');
    // A cancelled or malformed secret never reaches the handoff.
    const c = fixture(); const ce = c.envelope();
    c.service.ingest(JSON.stringify(ce), params[secretKey]); c.service.cancelIncoming();
    const ce2 = c.envelope(); ce2.transferId = '5'.repeat(32); ce2.channelId = 'rd_' + '6'.repeat(32);
    c.service.ingest(JSON.stringify(ce2), JSON.stringify({ ...secret, extra: 1 })); assert.ok(await c.service.accept(c.context));
    assert.equal(c.load(dir + 'ProContinuationCredentials.ets').ProContinuationCredentialHandoff.getInstance()
      .take(ce2.connection.hostReference, ce2.owner), null);
  } finally { prefs.value.credentialMode = 'manual'; }
});
test('a transferred RDP password keeps its Windows account; unknown or oversized fields fail closed', () => {
  const f = fixture();
  const { validProContinuationSecret } = f.load('entry/src/main/ets/services/pro/ProContinuationCredentials.ets');
  const rdp = { kind: 'password', password: 'pw', privateKeyPem: '', passphrase: '', username: 'WORK\\alice' };
  assert.equal(JSON.stringify(validProContinuationSecret(rdp)), JSON.stringify(rdp));
  assert.equal(validProContinuationSecret({ ...rdp, domain: 'x' }), null);
  assert.equal(validProContinuationSecret({ ...rdp, username: 'a'.repeat(257) }), null);
  assert.equal(validProContinuationSecret({ ...rdp, username: 7 }), null);
  const vnc = { kind: 'password', password: 'pw', privateKeyPem: '', passphrase: '' };
  assert.equal(validProContinuationSecret(vnc).username, '');
});
test('a protocol switched off in settings neither continues from nor is accepted on this device', async () => {
  const f = fixture(); const dir = 'entry/src/main/ets/services/pro/';
  const prefsModule = f.load(dir + 'ProContinuationPreferences.ets');
  const prefs = prefsModule.ProContinuationPreferences.getInstance();
  assert.deepEqual([...prefs.settings().protocols], ['ssh', 'rdp', 'rustdesk', 'vnc'], 'all protocols on by default');
  prefs.value.protocols = ['rdp', 'rustdesk', 'vnc'];
  try {
    assert.equal(await f.service.prepare(f.context, f.offer()), false);
    assert.equal(f.service.lastPrepareFailure(), 'disabled');
    const t = fixture(); const te = t.envelope();
    t.load(dir + 'ProContinuationPreferences.ets').ProContinuationPreferences.getInstance().value.protocols = ['rdp'];
    assert.equal(t.service.ingest(JSON.stringify(te)), true);
    assert.equal(await t.service.accept(t.context), null);
    assert.match(t.service.snapshot().incomingMessage, /关闭 SSH 接续/);
    t.load(dir + 'ProContinuationPreferences.ets').ProContinuationPreferences.getInstance().value.protocols =
      ['ssh', 'rdp', 'rustdesk', 'vnc'];
    // Switched off after arming: the platform's continue callback is refused.
    prefs.value.protocols = ['ssh', 'rdp', 'rustdesk', 'vnc'];
    assert.equal(await f.service.prepare(f.context, f.offer()), true);
    prefs.value.protocols = [];
    assert.equal(await f.service.onContinue(9, {}), 1);
  } finally { prefs.value.protocols = ['ssh', 'rdp', 'rustdesk', 'vnc']; }
});
test('RustDesk and VNC continue as V3 reconnect-only transfers of the same synced host', async () => {
  for (const kind of ['rustdesk', 'vnc']) {
    const f = fixture();
    const remote = kind === 'rustdesk'
      ? { id: 'rd-host', userId: f.state.scope.ownerScopeId, protocol: 'rustdesk', label: 'Office PC', host: '123456789',
        port: 0, username: '', password: 'NEVER_EXPORT', rustdeskDirectEnabled: false, rustdeskDirectHost: '', rustdeskDirectPort: 21118,
        rustdeskRelayId: 'relay-1', rustdeskAccountId: 'acct-1', rustdeskTargetDevice: 'computer',
        rustdeskProAccountId: '', rustdeskProPeerId: '', rustdeskProManaged: false, customHostname: '',
        rustdeskAuthMode: 'password', rustdeskPasswordMode: 0 }
      : { id: 'vnc-host', userId: f.state.scope.ownerScopeId, protocol: 'vnc', label: 'Lab Mac', host: '192.0.2.10',
        port: 5901, username: 'alice', password: 'NEVER_EXPORT', transport: 'direct_tcp', repeaterMode: 'mode12',
        gatewayId: '', tls: true, securityPolicy: 'secure_only', viewOnly: false, displayOverrideEnabled: false,
        scalingMode: 'fit', rustdeskDirectEnabled: false, rustdeskDirectHost: '', rustdeskDirectPort: 0 };
    f.state.host = remote;
    const source = kind === 'vnc' ? { ...remote, id: 'vnc:' + remote.id, sourceType: 'vnc' } : remote;
    if (kind === 'vnc') { f.state.vncHost = remote; f.state.vncHostReady = true; }
    const described = f.adapter.describeProRemoteConnection(source);
    assert.equal(described.port, kind === 'rustdesk' ? 21116 : 5901, 'missing ports are normalized');
    assert.equal(f.adapter.describeProRemoteConnection({ ...source, protocol: 'ssh' }), null);
    const offer = { windowId: 9, isCurrent: () => true, describe: () => f.adapter.describeProRemoteConnection(source),
      close() { f.state.closed = true; } };
    assert.equal(await f.service.prepare(f.context, offer, true, false), true);
    const params = {}; assert.equal(await f.service.onContinue(9, params), 0);
    const wire = params[f.key]; const e = JSON.parse(wire);
    assert.equal(e.version, 3); assert.equal(e.connection.protocol, kind); assert.equal(wire.includes('NEVER_EXPORT'), false);
    // Only V3 continuation with the canonical empty view is accepted.
    for (const edit of [x => { x.version = 1; }, x => { x.version = 2; }, x => { x.purpose = 'share'; x.owner = ''; x.connection.hostReference = ''; },
      x => { x.connection.view.scale = 2; }, x => { x.connection.view.sshDirectory = '/tmp'; }]) {
      const copy = JSON.parse(wire); edit(copy); assert.equal(f.policy.parseProConnectionEnvelope(JSON.stringify(copy)), null);
    }
    // Target: the same synced host record is accepted; a changed endpoint is not.
    const t = fixture();
    if (kind === 'vnc') { t.state.vncHost = { ...remote, viewOnly: true, displayOverrideEnabled: true, scalingMode: 'integer' }; t.state.vncHostReady = true; }
    else { t.state.host = { ...remote }; }
    assert.equal(t.service.ingest(wire), true);
    assert.equal((await t.service.accept(t.context)).id, kind === 'vnc' ? 'vnc:' + remote.id : remote.id);
    const u = fixture();
    if (kind === 'vnc') { u.state.vncHost = { ...remote, host: '192.0.2.99' }; u.state.vncHostReady = true; }
    else { u.state.host = { ...remote, host: '987654321' }; }
    assert.equal(u.service.ingest(wire), true); assert.equal(await u.service.accept(u.context), null);
    // The endpoint alone is insufficient: a same-endpoint route mutation and
    // a different account owner must both fail closed.
    const route = fixture();
    if (kind === 'vnc') {
      route.state.vncHost = { ...remote, repeaterMode: 'none' }; route.state.vncHostReady = true;
    } else {
      route.state.host = { ...remote, rustdeskTargetDevice: 'phone' };
    }
    assert.equal(route.service.ingest(wire), true); assert.equal(await route.service.accept(route.context), null);
    const routeWire = JSON.parse(wire); routeWire.connection.routeKey += 'x';
    const routeWireTarget = fixture();
    if (kind === 'vnc') { routeWireTarget.state.vncHost = { ...remote }; routeWireTarget.state.vncHostReady = true; }
    else { routeWireTarget.state.host = { ...remote }; }
    assert.equal(routeWireTarget.service.ingest(JSON.stringify(routeWire)), true);
    assert.equal(await routeWireTarget.service.accept(routeWireTarget.context), null);
    const owner = fixture();
    const foreignOwner = 'owner-' + 'd'.repeat(64);
    if (kind === 'vnc') { owner.state.vncHost = { ...remote, userId: foreignOwner }; owner.state.vncHostReady = true; }
    else { owner.state.host = { ...remote, userId: foreignOwner }; }
    assert.equal(owner.service.ingest(wire), true); assert.equal(await owner.service.accept(owner.context), null);
  }
  const f = fixture();
  const direct = { id: 'rd-direct', protocol: 'rustdesk', label: '', host: '123', port: 0, username: 'x',
    rustdeskDirectEnabled: true, rustdeskDirectHost: '198.51.100.7', rustdeskDirectPort: 21118,
    rustdeskRelayId: '', rustdeskAccountId: '', rustdeskTargetDevice: 'computer', rustdeskProAccountId: '',
    rustdeskProPeerId: '', rustdeskProManaged: false, customHostname: '', rustdeskAuthMode: 'password', rustdeskPasswordMode: 0 };
  const d = f.adapter.describeProRemoteConnection(direct);
  assert.equal(d.host, '198.51.100.7'); assert.equal(d.port, 21118); assert.equal(d.username, ''); assert.equal(d.label, '198.51.100.7');
  const gateway = fixture();
  const vnc = { id: 'vnc-gateway-host', userId: gateway.state.scope.ownerScopeId, protocol: 'vnc', label: 'Gateway VNC',
    host: '192.0.2.20', port: 5900, username: 'bob', password: 'NEVER_EXPORT', transport: 'gateway_https',
    repeaterMode: 'mode12', gatewayId: 'gw-1', tls: true, securityPolicy: 'secure_only', viewOnly: false,
    displayOverrideEnabled: false, scalingMode: 'fit', rustdeskDirectEnabled: false, rustdeskDirectHost: '', rustdeskDirectPort: 0 };
  gateway.state.vncHost = vnc; gateway.state.vncHostReady = true;
  gateway.state.vncGateway = { id: 'gw-1', userId: vnc.userId, transport: 'https', host: 'gw.example.test', port: 443,
    path: '/vnc', repeaterMode: 'mode12', targetId: 'peer-1', tls: true, enabled: true };
  const gatewaySource = { ...vnc, id: 'vnc:' + vnc.id, sourceType: 'vnc' };
  const gatewayDescription = gateway.adapter.describeProRemoteConnection(gatewaySource);
  assert.ok(gatewayDescription.routeKey.includes('gw.example.test'));
  const gatewayWireOffer = { windowId: 9, isCurrent: () => true, describe: () => gatewayDescription, close() {} };
  assert.equal(await gateway.service.prepare(gateway.context, gatewayWireOffer, true, false), true);
  const gatewayParams = {}; assert.equal(await gateway.service.onContinue(9, gatewayParams), 0);
  const gatewayWire = gatewayParams[gateway.key];
  const gatewayTarget = fixture(); gatewayTarget.state.vncHost = { ...vnc, viewOnly: true, scalingMode: 'integer' };
  gatewayTarget.state.vncHostReady = true; gatewayTarget.state.vncGateway = { ...gateway.state.vncGateway };
  assert.equal(gatewayTarget.service.ingest(gatewayWire), true);
  assert.ok(await gatewayTarget.service.accept(gatewayTarget.context));
  const changedGateway = fixture(); changedGateway.state.vncHost = { ...vnc }; changedGateway.state.vncHostReady = true;
  changedGateway.state.vncGateway = { ...gateway.state.vncGateway, host: 'other-gw.example.test' };
  assert.equal(changedGateway.service.ingest(gatewayWire), true);
  assert.equal(await changedGateway.service.accept(changedGateway.context), null);
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
test('old target page failure cannot cancel a replacement incoming transaction', async () => {
  const f = fixture(); const e = f.envelope(); f.service.ingest(JSON.stringify(e)); await f.service.accept(f.context);
  const page = f.terminal(); page.proConnectionTransferId = e.transferId;
  const wait = deferred(); f.state.directoryWait = wait; const restoring = page.restoreProContinuation(); await settle();
  page.pageGeneration++; f.service.cancelIncoming(e.transferId);
  const replacement = f.envelope(); replacement.transferId = 'd'.repeat(32); replacement.channelId = 'rd_' + 'e'.repeat(32);
  assert.equal(f.service.ingest(JSON.stringify(replacement)), true); assert.ok(await f.service.accept(f.context));
  wait.resolve(); await restoring;
  assert.equal(f.service.incomingId(), replacement.transferId); assert.notEqual(f.state.objects.filter(o => 'receipt' in o)[1].calls.at(-1), '');
  f.service.cancelIncoming(e.transferId); assert.equal(f.service.incomingId(), replacement.transferId);
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

test('actual PC SSH preparation uses its independent mission and still requires a target receipt', async () => {
  const f = fixture(); f.context.abilityInfo.name = 'RemoteSessionAbility';
  const terminal = f.terminal(); terminal.isDesktopDevice = true;
  await terminal.prepareProContinuation();
  assert.equal(f.service.snapshot().sourceWindow, 9);
  const remote = f.sessionAbility(); remote.ability.windowStage = remote.stage;
  const parameters = {};
  assert.equal(await remote.ability.onContinue(parameters), 0);
  const wire = JSON.parse(parameters[f.key]);
  assert.equal(wire.connection.protocol, 'ssh');
  assert.equal(wire.connection.view.sshDirectory, '/home/alice/work');
  assert.equal(parameters.pageStack, false); assert.equal(parameters.sourceExit, false);
  assert.equal(f.service.closeConfirmedSource(9), false); assert.equal(f.state.closed, undefined);
  f.state.nativeGeneration++; assert.equal(await remote.ability.onContinue({}), 1);
});
test('normal independent-window Wants cannot ingest continuation data or activate a foreign record', () => {
  const f = fixture(); const remote = f.sessionAbility();
  remote.ability.onCreate({ parameters: { [f.key]: JSON.stringify(f.envelope()),
    pageStack: false, sourceExit: false, sessionWindowId: 'foreign-record' } }, { launchReason: 0 });
  assert.equal(f.service.snapshot().incoming, false);
  assert.deepEqual(remote.events, [['activate', 'foreign-record'], ['terminate']]);
  assert.equal(f.state.proVisibilityLoads, 1);
});
test('multiton continuation synchronously restores only a validated offer and bypasses local record activation', async () => {
  const f = fixture(); const remote = f.sessionAbility(), envelope = f.envelope();
  remote.ability.onCreate({ parameters: { [f.key]: JSON.stringify(envelope),
    pageStack: false, sourceExit: false, sessionWindowId: 'NEVER_ACTIVATE' } }, { launchReason: 3 });
  assert.deepEqual(remote.events, [['restore']]);
  assert.equal(f.service.incomingId(), envelope.transferId);
  await remote.ability.onWindowStageRestore(remote.stage);
  assert.equal(remote.stage.storage.get('proContinuationBootstrapId'), envelope.transferId);
  assert.equal(remote.stage.storage.get('sessionWindowId'), undefined);
  assert.equal(f.state.objects.length, 0); assert.equal(f.state.closed, undefined);
});
test('multiton malformed flags, replay and synchronous restore failure reject only the arriving offer', async () => {
  for (const patch of [{ pageStack: true }, { sourceExit: true }, { pageStack: undefined }, { sourceExit: undefined }]) {
    const f = fixture(), remote = f.sessionAbility();
    remote.ability.onCreate({ parameters: { [f.key]: JSON.stringify(f.envelope()),
      pageStack: false, sourceExit: false, ...patch } }, { launchReason: 3 });
    assert.deepEqual(remote.events, [['terminate']]); assert.equal(f.service.snapshot().incoming, false);
  }
  const f = fixture(), envelope = f.envelope();
  f.service.ingest(JSON.stringify(envelope));
  const duplicate = f.sessionAbility();
  duplicate.ability.onCreate({ parameters: { [f.key]: JSON.stringify(envelope), pageStack: false, sourceExit: false } },
    { launchReason: 3 });
  assert.deepEqual(duplicate.events, [['terminate']]); assert.equal(f.service.incomingId(), envelope.transferId);
  f.service.cancelIncoming(); f.state.restoreError = true;
  const next = { ...envelope, transferId: 'e'.repeat(32) }, remote = f.sessionAbility();
  remote.ability.onCreate({ parameters: { [f.key]: JSON.stringify(next), pageStack: false, sourceExit: false } },
    { launchReason: 3 });
  assert.deepEqual(remote.events, [['restore'], ['terminate']]); assert.equal(f.service.snapshot().incoming, false);
});
test('cold PC receiver opens EntryAbility for initialization without any connection or readiness receipt', async () => {
  const f = fixture(), remote = f.sessionAbility(), envelope = f.envelope();
  remote.ability.onCreate({ parameters: { [f.key]: JSON.stringify(envelope), pageStack: false, sourceExit: false } },
    { launchReason: 3 });
  await remote.ability.onWindowStageRestore(remote.stage);
  const page = remote.bootstrap(); page.aboutToAppear(); await settle();
  const start = remote.events.find(event => event[0] === 'start');
  assert.equal(start[1].abilityName, 'EntryAbility'); assert.equal(start[1].bundleName, 'test.remotedesk');
  assert.deepEqual(Object.keys(start[1].parameters), [f.libraryKey]);
  assert.equal(start[1].parameters[f.libraryKey], envelope.transferId);
  assert.equal(remote.stage.storage.get('proContinuationForwarded'), true);
  assert.equal(remote.events.at(-1)[0], 'terminate'); assert.equal(f.state.objects.length, 0);
  remote.ability.onWindowStageDestroy(); remote.ability.onDestroy();
  assert.equal(f.service.incomingId(), envelope.transferId);
  assert.equal(f.service.snapshot().incomingCanAccept, true); assert.equal(f.state.closed, undefined);
});
test('failed PC library launch keeps the offer unconfirmed and closing its window cancels only that offer', async () => {
  const f = fixture(), remote = f.sessionAbility(), envelope = f.envelope(); f.state.libraryError = true;
  remote.ability.onCreate({ parameters: { [f.key]: JSON.stringify(envelope), pageStack: false, sourceExit: false } },
    { launchReason: 3 });
  await remote.ability.onWindowStageRestore(remote.stage);
  const page = remote.bootstrap(); page.aboutToAppear(); await settle();
  assert.ok(page.errorMessage.includes('无法打开主机列表'));
  assert.equal(remote.stage.storage.get('proContinuationForwarded'), false);
  assert.equal(f.service.snapshot().incomingCanAccept, true); assert.equal(f.state.objects.length, 0);
  remote.ability.onWindowStageDestroy(); assert.equal(f.service.snapshot().incoming, false);
});
test('expired, replaced and destroyed PC handoffs cannot mark a newer offer forwarded', async () => {
  for (const change of ['expired', 'replaced', 'destroyed']) {
    const f = fixture(), remote = f.sessionAbility(), envelope = f.envelope();
    f.state.libraryWait = deferred();
    remote.ability.onCreate({ parameters: { [f.key]: JSON.stringify(envelope), pageStack: false, sourceExit: false } },
      { launchReason: 3 });
    await remote.ability.onWindowStageRestore(remote.stage);
    const storage = remote.stage.storage, page = remote.bootstrap(); page.aboutToAppear(); await settle();
    assert.equal(storage.get('proContinuationForwarded'), false);
    const next = { ...envelope, transferId: 'e'.repeat(32) };
    if (change === 'expired') f.state.now += 120000;
    if (change === 'replaced') { f.service.cancelIncoming(); f.service.ingest(JSON.stringify(next)); }
    if (change === 'destroyed') { page.aboutToDisappear(); remote.ability.onWindowStageDestroy(); }
    f.state.libraryWait.resolve(); await settle();
    assert.equal(storage.get('proContinuationForwarded'), false);
    assert.equal(f.state.objects.length, 0); assert.equal(f.state.closed, undefined);
    remote.ability.onDestroy();
    if (change === 'replaced') assert.equal(f.service.incomingId(), next.transferId);
  }
});
test('late PC bootstrap-load failure cannot cancel a later request', async () => {
  const f = fixture(), remote = f.sessionAbility(), envelope = f.envelope();
  f.state.loadWait = deferred(); f.state.loadError = true;
  remote.ability.onCreate({ parameters: { [f.key]: JSON.stringify(envelope), pageStack: false, sourceExit: false } },
    { launchReason: 3 });
  const loading = remote.ability.onWindowStageRestore(remote.stage); await settle();
  const next = { ...envelope, transferId: 'e'.repeat(32) };
  f.service.cancelIncoming(); f.service.ingest(JSON.stringify(next));
  f.state.loadWait.resolve(); await loading; remote.ability.onWindowStageDestroy();
  assert.equal(f.service.incomingId(), next.transferId);
});
test('destroying an independent window disarms its own preparation without closing a remote session', async () => {
  const f = fixture(); f.context.abilityInfo.name = 'RemoteSessionAbility';
  await f.service.prepare(f.context, f.offer());
  const unrelated = f.sessionAbility(); unrelated.ability.nativeWindowId = 8; unrelated.ability.onDestroy();
  assert.equal(f.service.snapshot().sourceWindow, 9);
  const owner = f.sessionAbility(); owner.ability.nativeWindowId = 9; owner.ability.onDestroy(); await settle();
  assert.equal(f.service.snapshot().sourceWindow, 0); assert.equal(f.state.missions.at(-1), 1);
  assert.equal(f.state.closed, undefined);
});
test('warm main-window handoff is only a notice for an already ingested matching offer', () => {
  const f = fixture(), envelope = f.envelope(), main = f.entryAbility();
  const notices = []; main.ability.windowStage = { getMainWindowSync: () => ({
    getUIContext: () => ({ getPromptAction: () => ({ showToast: value => notices.push(value.message) }) })
  }) };
  main.ability.onNewWant({ parameters: { [f.libraryKey]: envelope.transferId } }, { launchReason: 0 });
  assert.equal(notices.length, 0); assert.equal(f.service.snapshot().incoming, false);
  f.service.ingest(JSON.stringify(envelope));
  main.ability.onNewWant({ parameters: { [f.libraryKey]: 'd'.repeat(32) } }, { launchReason: 0 });
  assert.equal(notices.length, 0);
  main.ability.onNewWant({ parameters: { [f.libraryKey]: envelope.transferId } }, { launchReason: 0 });
  assert.equal(notices.length, 1); assert.equal(f.state.objects.length, 0);
  assert.equal(f.service.snapshot().incomingCanAccept, true);
});
test('a receiver-card continuation queued after acceptance cannot cancel a newer offer', async () => {
  const file = path.join(root, 'entry/src/main/ets/components/ProContinuationControls.ets');
  const source = fs.readFileSync(file, 'utf8'), start = source.indexOf('  private async accept()');
  assert(start >= 0);
  const open = source.indexOf('{', start);
  const scanner = ts.createScanner(ts.ScriptTarget.Latest, true, ts.LanguageVariant.Standard, source.slice(open));
  let depth = 0, token;
  do {
    token = scanner.scan();
    if (token === ts.SyntaxKind.OpenBraceToken) depth++;
    if (token === ts.SyntaxKind.CloseBraceToken) depth--;
  } while (depth > 0 && token !== ts.SyntaxKind.EndOfFileToken);
  assert.equal(depth, 0);
  const method = source.slice(start, open + scanner.getTextPos());
  for (const change of ['replaced', 'closed']) {
    const f = fixture(), original = f.envelope(); f.service.ingest(JSON.stringify(original));
    // The service has returned an authenticated host, but the UI's await
    // continuation has not run yet. The actual card must recheck its captured id.
    f.service.accept = async () => f.state.host;
    const module = { exports: {} };
    vm.runInNewContext(ts.transpileModule('class Card {\n' + method + '\n}\nmodule.exports = Card;', {
      compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
    }).outputText, { module, ProContinuationService: { getInstance: () => f.service }, getContext: () => f.context });
    let connected = 0;
    const card = new module.exports(); Object.assign(card, { busy: false, live: true, onConnect() { connected++; } });
    const accepting = card.accept();
    const next = { ...original, transferId: 'e'.repeat(32) };
    if (change === 'replaced') { f.service.cancelIncoming(); f.service.ingest(JSON.stringify(next)); }
    else card.live = false;
    await accepting; assert.equal(connected, 0);
    assert.equal(f.service.incomingId(), change === 'replaced' ? next.transferId : '');
  }
});

function rdpFixture() {
  const f=fixture();
  f.state.host={...f.state.host,protocol:'rdp',host:'desktop.example.test',port:3389,username:'WORK\\alice',
    customHostname:'',gatewayHost:'',gatewayPort:443,rdpGatewayServerName:'',rdpGatewayTransport:'auto',
    rdpEndpointMode:'direct_rdp',rdpAuthMode:'password',rdpCredentialId:'',rdpCredentialStorageMode:'saved'};
  f.identity=f.rdpPolicy.describeProRdpConnectionIdentity(f.state.host,{username:'alice',domain:'WORK'});
  f.rdpView={sshPane:'terminal',sshDirectory:'',monitor:0,scale:2,panX:50,panY:-10,inputMode:'keyboardMouse',strictBounds:false};
  f.envelope=()=>({version:2,purpose:'continuation',transferId:'b'.repeat(32),channelId:'rd_'+'c'.repeat(32),
    owner:f.state.scope.ownerScopeId,createdAt:f.state.now,expiresAt:f.state.now+120000,
    connection:f.adapter.describeProRdpConnection(f.state.host,f.identity,f.rdpView)});
  f.offer=()=>({windowId:9,isCurrent:()=>true,describe:()=>f.envelope().connection,close(){f.state.closed=true;}});
  return f;
}
test('RDP source uses V2 identity and separate ready receipt with explicit manual source exit',async()=>{
  const f=rdpFixture();assert.equal(await f.service.prepare(f.context,f.offer()),true);
  const params={};assert.equal(await f.service.onContinue(9,params),0);
  const envelope=JSON.parse(params[f.key]);assert.equal(envelope.version,2);
  assert.equal(envelope.connection.rdpIdentity.domain,'WORK');assert.equal(params.pageStack,false);assert.equal(params.sourceExit,false);
  assert.equal(f.state.closed,undefined);const object=f.state.objects[0];
  object.receipt=JSON.stringify({version:1,transferId:envelope.transferId,owner:envelope.owner,result:'ready'});
  object.emit(envelope.channelId);assert.equal(f.service.snapshot().sourceCloseAllowed,true);
  assert.equal(f.state.closed,undefined);assert.equal(f.service.closeConfirmedSource(9),true);assert.equal(f.state.closed,true);
});
test('RDP target never confirms a missing or different actual native identity',async()=>{
  for(const change of [null,{username:'bob'},{domain:'OTHER'},{authMode:'blank_password'},{route:'rdp-route-v2|other'}]){
    const f=rdpFixture(),e=f.envelope();assert.equal(f.service.ingest(JSON.stringify(e)),true);
    const host=await f.service.accept(f.context);assert.ok(host);
    assert.equal(f.service.complete(e.transferId,host,change===null?null:{...f.identity,...change}),false);
    assert.equal(f.state.objects[0].receipt,'');assert.equal(f.state.closed,undefined);
    assert.equal(f.service.complete(e.transferId,host,f.identity),true);
    assert.equal(JSON.parse(f.state.objects[0].receipt).transferId,e.transferId);
  }
});
test('RDP connection-time identity is reobtained locally while saved credentials are re-read without secrets',async()=>{
  for(const mode of ['connect_time','saved']){
    const f=rdpFixture(),e=f.envelope();f.state.host.rdpCredentialStorageMode=mode;
    if(mode==='connect_time')f.state.host.username='';
    else {
      f.state.host.rdpCredentialId='credential-1';
      f.state.credential={username:'WORK\\alice'};
      Object.defineProperty(f.state.credential,'password',{get(){throw new Error('must not read password');}});
    }
    assert.equal(f.service.ingest(JSON.stringify(e)),true);const host=await f.service.accept(f.context);assert.ok(host);
    if(mode==='saved'){
      f.state.credential.username='WORK\\bob';assert.equal(f.service.restoreView(e.transferId,host),null);
      assert.equal(f.service.complete(e.transferId,host,f.identity),false);f.state.credential.username='WORK\\alice';
    }else assert.equal(f.service.complete(e.transferId,host,{...f.identity,username:'bob'}),false);
    assert.equal(f.service.complete(e.transferId,host,f.identity),true);
  }
});
test('RDP source and target reject fresh gateway, username, auth mode and account changes',async()=>{
  const changes=[f=>{f.state.host.customHostname='other-name.example.test';},f=>{f.state.host.username='OTHER\\alice';},
    f=>{f.state.host.rdpAuthMode='restricted_admin';},f=>{f.state.host.rdpEndpointMode='microsoft_rd_gateway';f.state.host.gatewayHost='gw.example.test';},
    f=>{f.state.scope={...f.state.scope,generation:2};},f=>{f.state.allowed=false;}];
  for(const mutate of changes)for(const side of ['source','target']){
    const f=rdpFixture(),e=f.envelope();
    if(side==='source'){
      const description=e.connection;await f.service.prepare(f.context,{...f.offer(),describe:()=>description});
      mutate(f);assert.equal(await f.service.onContinue(9,{}),1);
    }else{
      f.service.ingest(JSON.stringify(e));const host=await f.service.accept(f.context);assert.ok(host);
      mutate(f);assert.equal(f.service.complete(e.transferId,host,f.identity),false);assert.equal(f.state.objects[0].receipt,'');
    }
    assert.equal(f.state.closed,undefined);
  }
});
test('RDP inactive mission is restored if a native/page fence fails while ACTIVE is pending',async()=>{
  const f=rdpFixture(),wait=deferred();f.state.missionWait=wait;let current=true;
  const pending=f.service.prepare(f.context,{...f.offer(),isCurrent:()=>current});await settle();
  assert.ok(f.state.missions.includes(0));current=false;wait.resolve();assert.equal(await pending,false);await settle();
  assert.equal(f.service.snapshot().sourceWindow,0);assert.equal(f.state.missions.at(-1),1);
});

(async () => {
  for (const { name, body } of tests) { await body(); process.stdout.write('PASS ' + name + '\n'); }
  process.stdout.write(`${tests.length} production connection checks passed\n`);
})().catch(error => { process.stderr.write(error.stack + '\n'); process.exitCode = 1; });
