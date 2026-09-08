/* Executes the production Share Kit adapter and receiving flow under controlled
 * platform callbacks. This is not App Linking or cross-device acceptance. */
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
async function settle() { for (let n = 0; n < 25; n++) await Promise.resolve(); }
function methodClass(file, names, bindings) {
  const input = fs.readFileSync(path.join(root, file), 'utf8');
  const methods = names.map(name => {
    const start = input.search(new RegExp(`  private (?:async )?${name}\\(`));
    assert.ok(start >= 0, `production method exists: ${name}`);
    let end = input.indexOf('{', start), depth = 1;
    for (end++; depth > 0; end++) {
      if (input[end] === '{') depth++;
      if (input[end] === '}') depth--;
      assert.ok(end < input.length, `balanced production method: ${name}`);
    }
    return input.slice(start, end);
  }).join('\n');
  const source = ts.transpileModule('class Subject {\n' + methods + '\n}\nmodule.exports = Subject;', {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(source, { module, ...bindings }, { filename: file });
  return new module.exports();
}
function fixture() {
  const state = { now: 1000000, base: 'https://connect.example.test/ssh', allowed: true,
    api: 26, capability: true, hostReady: true, nextTimer: 0, timers: new Map(), transitions: [],
    runtimeListeners: [], registrations: [], unregisters: [], nativeGeneration: 9, nativeState: 2,
    profileRaw: '', profileReadable: true,
    scope: { kind: 'huawei_account', ownerScopeId: 'owner-' + 'a'.repeat(64), generation: 1, sessionState: 'ready' } };
  const context = { abilityInfo: { name: 'EntryAbility' } };
  const hosts = new Map();
  const host = { id: 'source-host', userId: state.scope.ownerScopeId, protocol: 'ssh', label: 'Work SSH',
    host: 'ssh.example.test', port: 22, username: 'alice', sshProxyType: 'direct', proxyHost: '',
    password: 'NEVER_SHARE', sshKeyData: 'NEVER_SHARE', sshKeyPassphrase: 'NEVER_SHARE',
    sshHostKeyRawBase64: 'NEVER_SHARE', toJSON() { throw new Error('do not serialize RemoteHost'); } };
  hosts.set(host.id, host);
  const hostService = { isReady: () => state.hostReady, getHost: id => hosts.get(id) };
  const account = { currentScope: () => state.scope, onTransitionActivity(callback) {
    state.transitions.push(callback); callback(false); return () => {};
  } };
  const runtime = { decision: () => ({ executable: state.allowed }), subscribe(callback) {
    state.runtimeListeners.push(callback); callback(); return () => {};
  } };
  const harmonyShare = {
    on(event, registry, callback) { state.registrations.push({ event, registry, callback }); },
    off(event, registry, callback) { state.unregisters.push({ event, registry, callback }); },
    SharableErrorCode: { NO_CONTENT_ERROR: 1 }
  };
  const cache = new Map();
  function load(file) {
    file = path.resolve(root, file);
    if (cache.has(file)) return cache.get(file).exports;
    const module = { exports: {} }; cache.set(file, module);
    const source = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
    }).outputText;
    class Clock extends Date { static now() { return state.now; } }
    vm.runInNewContext(source, { module, exports: module.exports, Date: Clock, canIUse: () => state.capability,
      setTimeout(callback, delay) { const id = ++state.nextTimer; state.timers.set(id, { callback, delay }); return id; },
      clearTimeout: id => state.timers.delete(id), require(id) {
        if (id === '@kit.BasicServicesKit') return { deviceInfo: { get sdkApiVersion() { return state.api; } } };
        if (id === '@kit.CryptoArchitectureKit') return { cryptoFramework: { createRandom: () => ({
          generateRandomSync: n => ({ data: new Uint8Array(crypto.randomBytes(n)) })
        }) } };
        if (id === '@kit.ShareKit') return { harmonyShare, systemShare: { SharedData: class {
          constructor(record) { this.record = record; } getRecords() { return [this.record]; }
        } } };
        if (id === '@kit.ArkData') return { preferences: { getPreferencesSync: () => ({ getSync() {
          if (!state.profileReadable) throw new Error('locked profile'); return state.profileRaw;
        } }) } };
        if (id.endsWith('/AccountSessionCoordinator')) return { AccountSessionCoordinator: { getInstance: () => account } };
        if (id.endsWith('/HostSyncService')) return { HostSyncService: { getInstance: () => hostService } };
        if (id === './ProAppRuntime') return { ProAppRuntime: { getInstance: () => ({ runtime,
          context: () => ({ protocol: 'ssh', capabilities: [] }) }) } };
        if (id === './ProConnectionShareConfiguration') return { proConnectionShareBase: () => state.base };
        if (id.startsWith('.')) return load(path.resolve(path.dirname(file), id + '.ets'));
        throw new Error('unexpected import ' + id);
      }
    }, { filename: file });
    return module.exports;
  }
  const dir = 'entry/src/main/ets/services/pro/';
  const policy = load(dir + 'ProConnectionSharePolicy.ets');
  const adapter = load(dir + 'ProConnectionHostAdapter.ets');
  const sender = load(dir + 'ProConnectionShareSender.ets').ProConnectionShareSender.getInstance();
  const receiver = load(dir + 'ProConnectionShareReceiver.ets').ProConnectionShareReceiver.getInstance();
  const description = () => adapter.describeProSshConnection(host, 'files', '/home/alice/project', context);
  const envelope = (id = 'b'.repeat(32)) => policy.makeProConnectionShareEnvelope(description(), id,
    'rd_' + 'c'.repeat(32), state.now);
  const link = (id) => policy.buildProConnectionShareLink(state.base, envelope(id), state.now);
  const offer = (changes = {}) => ({ windowId: 7, context, description: description(),
    isCurrent: () => true, confirm: async () => true, ...changes });
  function target() {
    const value = { sent: [], rejected: [], infoReads: 0,
      getInfo() { this.infoReads++; if (state.api < 26) throw new Error('API 26 accessed');
        return { coordinate: { screenX: 20, screenY: 30 } }; },
      async share(data) { this.sent.push(data.getRecords()[0]); }, async reject(code) { this.rejected.push(code); } };
    return value;
  }
  async function deliver(targetValue = target(), registration = state.registrations.at(-1)) {
    registration.callback(targetValue); await settle(); return targetValue;
  }
  function accepted() {
    assert.equal(receiver.ingest(link()), true);
    const id = receiver.incomingId(); assert.ok(receiver.accept(id));
    const saved = { ...host, id: 'new-local-host' }; hosts.set(saved.id, saved);
    assert.equal(receiver.bindSaved(id, saved, context), true);
    return { id, saved };
  }
  function terminal(id, saved) {
    const page = methodClass('entry/src/main/ets/pages/SshTerminal.ets',
      ['proContinuationSessionCurrent', 'restoreProConnectionShare'], {
        SSH_STATE_CONNECTED: 2, ProConnectionShareReceiver: { getInstance: () => receiver },
        HostSyncService: { getInstance: () => hostService }, promptAction: { showToast() {} }
      });
    Object.assign(page, { hostId: saved.id, proConnectionShareId: id, proConnectionShareRestoreRunning: false,
      terminalClosing: false, connected: true, sessionId: 15, sshSessionGeneration: 9,
      sshBindingGeneration: 3, pageGeneration: 4, proContinuationPaneEpoch: 0,
      showSftpPanel: false, sftpRootSheetClosing: false, sftpCloseRootAfterPeerPicker: false, sftpPath: '.',
      loader: { getConnectionState: () => state.nativeState,
        getSshTerminalDiagnostics: () => ({ sessionGeneration: state.nativeGeneration }) },
      openSftpPanel() { this.showSftpPanel = true; this.proContinuationPaneEpoch++; },
      normalizeRemoteDir: value => value, async refreshSftp(directory) {
        if (state.directoryWait) await state.directoryWait.promise; this.sftpPath = directory; return true;
      }
    });
    return page;
  }
  return { state, context, hosts, host, policy, sender, receiver, description, envelope, link, offer,
    target, deliver, accepted, terminal, hostService, load, runtime, account };
}

test('wire data strips host identity, account identity and credential fields', () => {
  const f = fixture(); const description = f.description(); description.password = 'NEVER_SHARE';
  const envelope = f.policy.makeProConnectionShareEnvelope(description, 'b'.repeat(32), 'rd_' + 'c'.repeat(32));
  assert.equal(envelope.owner, ''); assert.equal(envelope.connection.hostReference, '');
  assert.equal(JSON.stringify(envelope).includes('NEVER_SHARE'), false);
  envelope.connection.view.sshDirectory = '/changed';
  assert.equal(description.view.sshDirectory, '/home/alice/project');
});
test('only a pinned canonical HTTPS link is accepted; suffix, credentials and query fail', () => {
  const f = fixture(); const link = f.link(); assert.ok(f.policy.parseProConnectionShareLink(f.state.base, link));
  assert.equal(new URL(link).search, ''); assert.ok(new URL(link).hash.startsWith('#rd='));
  for (const base of ['', 'http://connect.example.test/ssh', 'https://u:p@connect.example.test/ssh',
    'https://connect.example.test:443/ssh', 'https://connect.example.test/ssh?next=x', 'https://localhost/ssh']) {
    assert.equal(f.policy.buildProConnectionShareLink(base, f.envelope()), '');
  }
  for (const value of [link + '&next=remote', link.replace('/ssh#', '/ssh/more#'), link.replace('#rd=', '?rd='),
    link.replace('connect.example.test', 'connect.example.test.evil.test'), link.replace('%7B', '%7b'),
    f.state.base + '#rd=%XX', f.state.base + '#rd=' + 'a'.repeat(32768)]) {
    assert.equal(f.policy.parseProConnectionShareLink(f.state.base, value), null);
  }
});
test('expired or continuation-purpose data cannot be imported as a connection share', () => {
  const f = fixture(); const link = f.link(); f.state.now += 120000;
  assert.equal(f.receiver.ingest(link), false);
  const e = f.envelope(); e.purpose = 'continuation'; e.owner = 'owner-' + 'a'.repeat(64); e.connection.hostReference = 'host';
  assert.equal(f.policy.buildProConnectionShareLink(f.state.base, e), '');
});
test('unconfigured production domain disables both sender and receiver', () => {
  const f = fixture(); const link = f.link(); f.state.base = '';
  assert.equal(f.sender.arm(f.offer()), false); assert.equal(f.receiver.ingest(link), false);
  assert.equal(f.state.registrations.length, 0);
});
test('sender registers one send-only window and unregisters exactly its own callback', async () => {
  const f = fixture(); assert.equal(f.sender.arm(f.offer()), true);
  const registration = f.state.registrations[0]; assert.equal(registration.event, 'knockShare');
  assert.equal(registration.registry.windowId, 7); assert.equal(registration.registry.sendOnly, true);
  const target = await f.deliver(); assert.equal(target.sent.length, 1);
  assert.equal(target.sent[0].utd, 'general.hyperlink');
  assert.ok(f.policy.parseProConnectionShareLink(f.state.base, target.sent[0].content));
  assert.equal(JSON.stringify(target.sent).includes('NEVER_SHARE'), false);
  assert.equal(f.state.unregisters.length, 1);
  assert.equal(f.state.unregisters[0].registry, registration.registry);
  assert.equal(f.state.unregisters[0].callback, registration.callback);
  assert.match(f.sender.snapshot().message, /本端会话继续保留/);
});
test('API 23 never reads API 26 coordinate member', async () => {
  const f = fixture(); f.state.api = 23; let point = 'unset';
  assert.equal(f.sender.arm(f.offer({ confirm: async value => { point = value; return true; } })), true);
  const target = await f.deliver(); assert.equal(point, null); assert.equal(target.infoReads, 0);
});
test('duplicate Share Kit callbacks cannot send twice', async () => {
  const f = fixture(); const wait = deferred(); assert.equal(f.sender.arm(f.offer({ confirm: () => wait.promise })), true);
  const registration = f.state.registrations.at(-1); const first = f.target(), second = f.target();
  registration.callback(first); registration.callback(second); await settle();
  assert.equal(second.rejected.length, 1); wait.resolve(true); await settle();
  assert.equal(first.sent.length, 1); assert.equal(second.sent.length, 0);
});
test('explicit cancel rejects the target and ends the waiting status', async () => {
  const f = fixture(); f.sender.arm(f.offer({ confirm: async () => false }));
  const target = await f.deliver(); assert.equal(target.sent.length, 0); assert.equal(target.rejected.length, 1);
  assert.equal(f.sender.snapshot().active, false); assert.match(f.sender.snapshot().message, /已取消/);
});
test('a late duplicate callback cannot reuse a consumed source after share resolves', async () => {
  const f = fixture(); f.sender.arm(f.offer()); const registration = f.state.registrations.at(-1);
  const first = await f.deliver(); const second = await f.deliver(f.target(), registration);
  assert.equal(first.sent.length, 1); assert.equal(second.sent.length, 0); assert.equal(second.rejected.length, 1);
});
test('page invalidation while confirmation is pending fences the old target', async () => {
  const f = fixture(); const wait = deferred(); let current = true;
  f.sender.arm(f.offer({ isCurrent: () => current, confirm: () => wait.promise }));
  const target = f.target(); f.state.registrations.at(-1).callback(target); current = false;
  wait.resolve(true); await settle(); assert.equal(target.sent.length, 0); assert.equal(target.rejected.length, 1);
});
test('account transition, runtime revocation and expiry fence pending confirmations', async () => {
  for (const invalidate of [f => f.state.transitions.forEach(cb => cb(true)),
    f => f.state.runtimeListeners.forEach(cb => cb()), f => { f.state.now += 120001; }]) {
    const f = fixture(); const wait = deferred(); f.sender.arm(f.offer({ confirm: () => wait.promise }));
    const target = f.target(); f.state.registrations.at(-1).callback(target); invalidate(f);
    wait.resolve(true); await settle(); assert.equal(target.sent.length, 0); assert.equal(target.rejected.length, 1);
  }
});
test('sender re-reads stored endpoint and direct route immediately before send', async () => {
  for (const change of [f => { f.host.host = 'changed.example.test'; },
    f => { f.host.sshProxyType = 'ssh_jump'; }, f => { f.state.profileReadable = false; }]) {
    const f = fixture(); const wait = deferred(); f.sender.arm(f.offer({ confirm: () => wait.promise }));
    const target = f.target(); f.state.registrations.at(-1).callback(target); change(f);
    wait.resolve(true); await settle(); assert.equal(target.sent.length, 0);
  }
});
test('another window cannot stop the current explicit source', () => {
  const f = fixture(); f.sender.arm(f.offer()); f.sender.stop(8);
  assert.equal(f.sender.snapshot().windowId, 7); f.sender.stop(7); assert.equal(f.sender.snapshot().windowId, 0);
});
test('ordinary receiver imports with Pro disabled and a device-local account', () => {
  const f = fixture(); f.state.allowed = false; f.state.scope.kind = 'device_local'; f.state.scope.ownerScopeId = 'device-local';
  assert.equal(f.receiver.ingest(f.link()), true);
  const draft = f.receiver.accept(f.receiver.incomingId()); assert.ok(draft);
  assert.deepEqual(Object.keys(draft).sort(), ['address', 'label', 'port', 'username']);
  assert.equal(draft.address, f.host.host);
});
test('receiver requires explicit acceptance and the fresh saved host before restoring a view', () => {
  const f = fixture(); const link = f.link(); f.receiver.ingest(link); const id = f.receiver.incomingId();
  assert.equal(f.receiver.restoreView(id, f.host), null); assert.equal(f.receiver.bindSaved(id, f.host, f.context), false);
  f.receiver.accept(id); const saved = { ...f.host, id: 'new-host' };
  assert.equal(f.receiver.bindSaved(id, saved, f.context), false);
});
test('edited endpoint or a proxy route preserves no automatic shared view', () => {
  for (const change of [h => { h.host = 'edited.example.test'; }, h => { h.username = 'bob'; },
    h => { h.sshProxyType = 'ssh_jump'; }]) {
    const f = fixture(); f.receiver.ingest(f.link()); const id = f.receiver.incomingId(); f.receiver.accept(id);
    const saved = { ...f.host, id: 'new-host' }; change(saved); f.hosts.set(saved.id, saved);
    assert.equal(f.receiver.bindSaved(id, saved, f.context), false); assert.equal(f.receiver.incomingId(), '');
  }
});
test('received offer survives cold account bootstrap but an accepted draft never crosses a transition', () => {
  const f = fixture(); f.receiver.ingest(f.link()); const id = f.receiver.incomingId();
  f.state.transitions.forEach(cb => cb(true)); assert.equal(f.receiver.incomingId(), id);
  assert.equal(f.receiver.accept(id), null); f.state.transitions.forEach(cb => cb(false)); assert.ok(f.receiver.accept(id));
  f.state.transitions.forEach(cb => cb(true)); assert.equal(f.receiver.incomingId(), '');
});
test('generation, host identity and stored endpoint are rechecked before applying directory', () => {
  for (const change of [f => { f.state.scope.generation++; }, f => { f.hosts.get('new-local-host').port = 2222; },
    f => { f.state.hostReady = false; }, f => { f.state.now += 120000; }]) {
    const f = fixture(); const { id, saved } = f.accepted(); assert.ok(f.receiver.restoreView(id, saved)); change(f);
    assert.equal(f.receiver.restoreView(id, saved), null); assert.equal(f.receiver.complete(id, saved), false);
  }
});
test('view is detached, one-use and cannot be replayed after completion', () => {
  const f = fixture(); const link = f.link(); const { id, saved } = f.accepted();
  f.receiver.restoreView(id, saved).sshDirectory = '/mutated';
  assert.equal(f.receiver.restoreView(id, saved).sshDirectory, '/home/alice/project');
  assert.equal(f.receiver.complete(id, saved), true); assert.equal(f.receiver.restoreView(id, saved), null);
  assert.equal(f.receiver.ingest(link), false);
});
test('stale cancellation cannot remove a later incoming offer', () => {
  const f = fixture(); f.receiver.ingest(f.link()); const old = f.receiver.incomingId(); f.receiver.cancel(old);
  assert.equal(f.receiver.ingest(f.link('d'.repeat(32))), true); f.receiver.cancel(old);
  assert.equal(f.receiver.incomingId(), 'd'.repeat(32));
});
test('actual terminal waits for SFTP restoration before consuming the share token', async () => {
  const f = fixture(); const { id, saved } = f.accepted(); const page = f.terminal(id, saved);
  f.state.directoryWait = deferred(); const operation = page.restoreProConnectionShare(); await settle();
  assert.equal(f.receiver.incomingId(), id); f.state.directoryWait.resolve(); await operation;
  assert.equal(page.sftpPath, '/home/alice/project'); assert.equal(page.proConnectionShareId, '');
  assert.equal(f.receiver.incomingId(), '');
});
test('actual terminal never completes a view after native generation or pane changes during SFTP', async () => {
  for (const change of [(f, page) => { f.state.nativeGeneration++; }, (f, page) => { page.proContinuationPaneEpoch++; }]) {
    const f = fixture(); const { id, saved } = f.accepted(); const page = f.terminal(id, saved);
    let completed = 0; const complete = f.receiver.complete.bind(f.receiver);
    f.receiver.complete = (...args) => { completed++; return complete(...args); };
    f.state.directoryWait = deferred(); const operation = page.restoreProConnectionShare(); await settle();
    change(f, page); f.state.directoryWait.resolve(); await operation;
    assert.equal(completed, 0); assert.equal(f.receiver.incomingId(), '');
  }
});
test('actual incoming Want handler accepts only viewData links and preserves the warm page', () => {
  const f = fixture(); let toasts = 0;
  const entry = methodClass('entry/src/main/ets/entryability/EntryAbility.ets', ['acceptProConnectionShareWant'], {
    AbilityConstant: { LaunchReason: { CONTINUATION: 3 } }, ProConnectionShareReceiver: { getInstance: () => f.receiver }
  });
  entry.windowStage = { getMainWindowSync: () => ({ getUIContext: () => ({ getPromptAction: () => ({
    showToast() { toasts++; }
  }) }) }) };
  const link = f.link(); entry.acceptProConnectionShareWant({ action: 'other', uri: link }, { launchReason: 0 });
  entry.acceptProConnectionShareWant({ action: 'ohos.want.action.viewData', uri: link }, { launchReason: 3 });
  assert.equal(f.receiver.incomingId(), ''); assert.equal(toasts, 0);
  entry.acceptProConnectionShareWant({ action: 'ohos.want.action.viewData', uri: link }, { launchReason: 0 });
  assert.equal(f.receiver.incomingId(), 'b'.repeat(32)); assert.equal(toasts, 1);
});
test('actual add form save refuses an expired draft before any host or profile write', () => {
  const f = fixture(); f.receiver.ingest(f.link()); const id = f.receiver.incomingId(); f.receiver.accept(id);
  let writes = 0;
  const page = methodClass('entry/src/main/ets/pages/HostListPage.ets', ['saveSshHostFromAddFlow'], {
    ProConnectionShareReceiver: { getInstance: () => f.receiver }, promptAction: { showToast() {} },
    shouldAcceptHostAddSave: () => true, pendingHostIdForHostAddSave: (_connect, hostId) => hostId,
    getContext: () => f.context
  });
  Object.assign(page, { proConnectionShareDraftId: id, addSheetClosing: false, pendingAddSheetConnectHostId: '',
    sshProxyProfiles: { upsert() { writes++; return true; } }, srv: { addHost() { writes++; return true; } } });
  f.state.now += 120000; page.saveSshHostFromAddFlow({ ...f.host, id: 'saved' }, true, { hostId: 'saved' });
  assert.equal(writes, 0);
});
test('actual add form persists user authentication and binds only the newly saved host ID', () => {
  const f = fixture(); f.receiver.ingest(f.link()); const id = f.receiver.incomingId(); f.receiver.accept(id);
  let closed = false;
  const page = methodClass('entry/src/main/ets/pages/HostListPage.ets', ['saveSshHostFromAddFlow'], {
    ProConnectionShareReceiver: { getInstance: () => f.receiver }, promptAction: { showToast() {} },
    shouldAcceptHostAddSave: () => true, pendingHostIdForHostAddSave: (connect, hostId) => connect ? hostId : '',
    getContext: () => f.context
  });
  const saved = { ...f.host, id: 'saved-host', password: 'USER_ENTERED_LOCAL_PASSWORD' };
  Object.assign(page, { proConnectionShareDraftId: id, addSheetClosing: false, pendingAddSheetConnectHostId: '',
    sshProxyProfiles: { upsert: () => true }, srv: { addHost(host) { f.hosts.set(host.id, host); return true; } },
    refreshHostSnapshotAfterMutation() {}, requestAddSheetClose() { closed = true; } });
  page.saveSshHostFromAddFlow(saved, true, { hostId: saved.id });
  assert.equal(f.hosts.get(saved.id).password, 'USER_ENTERED_LOCAL_PASSWORD'); assert.equal(closed, true);
  assert.equal(page.pendingAddSheetConnectHostId, saved.id); assert.equal(page.pendingAddSheetShareId, id);
  assert.equal(page.proConnectionShareDraftId, ''); assert.ok(f.receiver.restoreView(id, saved));
  assert.equal(f.receiver.restoreView(id, f.host), null);
});
test('actual page routing carries the share token only to its bound authenticated host path', () => {
  const f = fixture(); const { id, saved } = f.accepted(); const routes = [];
  const page = methodClass('entry/src/main/ets/pages/HostListPage.ets', ['openSessionDestination'], {
    ProConnectionShareReceiver: { getInstance: () => f.receiver }, router: { pushUrl(value) { routes.push(value); return Promise.resolve(); } }
  });
  Object.assign(page, { proContinuationAttemptId: '', proConnectionShareAttemptId: id,
    isDesktopDevice: false, srv: f.hostService });
  page.openSessionDestination('pages/SshTerminal', { hostId: f.host.id }, 'ssh_preflight');
  assert.equal(routes[0].params.proConnectionShareId, undefined);
  page.proConnectionShareAttemptId = id;
  page.openSessionDestination('pages/SshTerminal', { hostId: saved.id }, 'ssh_preflight');
  assert.equal(routes[1].params.proConnectionShareId, id); assert.equal(page.proConnectionShareAttemptId, '');
  assert.equal(routes[1].params.authenticated, undefined);
});
test('actual PC handoff preserves the one-use view token without completing it on window launch', async () => {
  const f = fixture(); const { id, saved } = f.accepted(); let captured, backs = 0;
  const registry = { bindScope() {}, setActive: () => true };
  const page = methodClass('entry/src/main/ets/pages/SshTerminal.ets', ['handoffAuthenticatedSshToIndependentWindow'], {
    ProConnectionShareReceiver: { getInstance: () => f.receiver },
    AccountSessionCoordinator: { getInstance: () => ({ ...f.account, init: async () => true }) },
    ActiveRemoteSessionRegistry: { getInstance: () => registry }, RemoteProtocol: { ssh: 2 },
    RemoteSessionWindowAuthorizationService: { getInstance: () => ({ issue: () => 'local-auth-token' }) },
    RemoteSessionWindowLauncher: { async open(_context, request) { captured = request; return true; } },
    RemoteSessionWindowNativeHandoff: class {}, nextRemoteSessionHandoffGeneration: value => value + 1,
    getContext: () => f.context, hilog: { info() {}, warn() {} }
  });
  Object.assign(page, { pcWindowAfterAuthentication: true, pcWindowHandoffStarted: false, sessionWindowId: '',
    pcWindowHandoffGeneration: 0, pageGeneration: 3, sshBindingGeneration: 4, proConnectionShareId: id,
    srv: f.hostService, getUIContext: () => ({ getRouter: () => ({ back() { backs++; } }), getHostContext: () => f.context }),
    loader: { captureExplicitDisconnectIdentity: () => ({ facadeGeneration: 1 }), detachSshSession: () => true,
      adoptDetachedSshSession: () => 15 }, sshTranscriptStore: { snapshot: () => '' }, detachSftpSessionOwner() {},
    releaseForwardingSession() {}, sshTabStore: { close: () => ({ nextActiveHostId: '' }) }, cleanupClosedSshTab() {},
    stopLatencyProbe() {}, stopSshAuthPromptPolling() {}
  });
  assert.equal(await page.handoffAuthenticatedSshToIndependentWindow(15, saved.id, 9), true);
  assert.equal(captured.routeParams.proConnectionShareId, id); assert.equal(captured.hostId, saved.id);
  assert.equal(captured.authorizationToken, 'local-auth-token'); assert.equal(page.proConnectionShareId, '');
  assert.equal(backs, 1); assert.equal(f.receiver.incomingId(), id);
});

(async () => {
  for (const item of tests) { await item.body(); console.log('PASS ' + item.name); }
  console.log(`PASS ${tests.length} connection-share checks`);
})().catch(error => { console.error(error); process.exitCode = 1; });
