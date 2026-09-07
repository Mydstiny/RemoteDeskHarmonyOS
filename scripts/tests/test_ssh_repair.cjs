/* Runs SSH store/layout policies and preflight ownership regressions on the host.
 * Native/Harmony ports are fakes; Hvigor and device acceptance remain separate gates.
 * SSH_TYPESCRIPT_PATH=<DevEco typescript module> node scripts/tests/test_ssh_repair.cjs
 */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.SSH_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const tests = [];
const add = (name, body) => tests.push({ name, body });
function environment() {
  const cache = new Map(), timers = new Map(), sessions = new Map();
  let seq = 0, tid = 0, active = true, prompt = null;
  let scope = { ownerScopeId: 'device-local', generation: 1, storeIdentity: 'local' };
  const host = { id: 'host-one', protocol: 'ssh', userId: 'device-local', host: 'example.test', port: 22,
    username: 'tester', password: 'test-fixture', sshUseKey: false, sshKeyId: '', sshKeyData: '',
    sshKeyPassphrase: '', customHostname: '', sshJumpHostKeyRawBase64: '', sshJumpHostKeyFingerprintSha256: '' };
  const plan = { valid: true, source: 'profile', message: '', route: {
    type: 'direct', endpointHost: host.host, endpointPort: 22, hops: [], schemaVersion: 1 },
    hopKeyIds: [], proxyAuthRequired: false, proxyHost: '', proxyPort: 0, proxyUsername: '' };
  const disconnected = [], calls = [], prompts = [], secrets = [];
  const loader = {
    inspectSshPrivateKey: () => ({ ok: true, encrypted: false }),
    waitForPendingTeardown: async () => true,
    connectSshAsync(config, foreground) {
      let settle; const promise = new Promise(resolve => { settle = resolve; });
      promise.sessionId = ++seq; promise.generation = seq + 100;
      sessions.set(seq, { state: 1, generation: promise.generation, detached: false });
      calls.push({ config: JSON.parse(JSON.stringify(config)), foreground, promise, settle });
      return promise;
    },
    peekDetachedSshSession: () => {
      for (const [id, value] of sessions) if (value.detached && value.state === 2) return id;
      return -1;
    },
    getSshAuthPrompt: () => prompt,
    cancelSshAuthPrompt: () => true,
    respondSshAuthPrompt: () => { prompt = null; return true; },
    disconnectSshSession(id) { disconnected.push(id); if (sessions.has(id)) sessions.get(id).state = 0; },
    getConnectionState: id => sessions.get(id)?.state || 0,
    getSshTerminalDiagnostics: id => ({ sessionGeneration: sessions.get(id)?.generation || 0 }),
    detachSshSession(id) { if (!sessions.has(id)) return false; sessions.get(id).detached = true; return true; },
    adoptDetachedSshSession(_host, id, generation) {
      const s = sessions.get(id);
      if (!s || !s.detached || s.state !== 2 || s.generation !== generation) return -1;
      s.detached = false; return id;
    }
  };
  const interaction = {
    active: () => active,
    secret: async (_title, label) => { secrets.push(label); return 'test-input'; },
    prompt: value => prompts.push(value), cancelled: () => {}
  };
  const mocks = {
    AccountSessionCoordinator: { AccountSessionCoordinator: { getInstance: () => ({ currentScope: () => ({ ...scope }) }) } },
    ExtensionLoader: { ExtensionLoader: { getInstance: () => loader } },
    HostSyncService: { HostSyncService: { getInstance: () => ({ getHost: id => id === host.id ? host : undefined }) } },
    KeyVaultService: { KeyVaultService: { getInstance: () => ({ getSshKey: () => ({ privateKey: 'fixture-key' }) }) } },
    SshProxyProfileStore: { SshProxyProfileStore: class { init() { return true; } load() { return {}; } } },
    SshProxyRuntimePolicy: { resolveSshProxyRuntimePlan: () => plan },
    SshHostKeyTrustPolicy: { sshHostKeyRouteBinding: () => ({ ok: true, identity: plan.route.endpointHost }),
      sshHostKeyPinsForRoute: () => ({ rawBase64: 'fixture-pin', fingerprintSha256: 'SHA256:fixture' }) },
    SshHostKeyTrustWriter: { persistSshHostKeyTrust: () => true },
    SshSettingsService: { SshSettingsService: class { init() {} getSshSessionLocale() { return 'en_US.UTF-8'; } } },
    SshOperationRouteSecretService: { SshOperationRouteSecretService: { getInstance: () => ({ stage: () => true }) } },
    DataCrypto: { DataCrypto: { getInstance: () => { throw Error('Unexpected real crypto access'); } } }
  };
  const hypium = {
    describe: (_name, body) => body(), it: (name, _level, body) => add(name, body),
    expect: value => ({ assertEqual: expected => assert.equal(value, expected), assertTrue: () => assert.equal(value, true),
      assertFalse: () => assert.equal(value, false), assertNull: () => assert.equal(value, null) })
  };
  function load(file) {
    file = path.resolve(root, file);
    if (cache.has(file)) return cache.get(file).exports;
    const module = { exports: {} }; cache.set(file, module);
    const source = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
    }).outputText;
    function requireEts(id) {
      if (id === '@ohos/hypium') return hypium;
      if (id === '@kit.ArkTS') return { util: { generateRandomUUID: () => 'receipt-' + (++tid) } };
      if (id.startsWith('@kit.')) return {};
      if (mocks[path.basename(id)]) return mocks[path.basename(id)];
      if (!id.startsWith('.')) throw Error('Unexpected dependency: ' + id);
      return load(path.resolve(path.dirname(file), id + '.ets'));
    }
    vm.runInNewContext(source, { module, exports: module.exports, require: requireEts, Date,
      setTimeout: callback => { timers.set(++tid, { callback, interval: false }); return tid; },
      clearTimeout: id => timers.delete(id),
      setInterval: callback => { timers.set(++tid, { callback, interval: true }); return tid; },
      clearInterval: id => timers.delete(id)
    }, { filename: file });
    return module.exports;
  }
  return { load, host, plan, calls, sessions, disconnected, prompts, secrets, interaction,
    changeScope: () => { scope.generation++; }, stop: () => { active = false; },
    setPrompt: p => { prompt = p; },
    tick: () => { for (const t of [...timers.values()]) if (t.interval) t.callback(); },
    expire: () => { for (const t of [...timers.values()]) if (!t.interval) t.callback(); },
    success: (index = 0) => { const call = calls[index]; sessions.get(call.promise.sessionId).state = 2; call.settle(call.promise.sessionId); }
  };
}
const env = environment();
for (const file of ['SshProductivityPolicy', 'SshTabChromePolicy']) {
  env.load('entry/src/test/' + file + '.test.ets').default();
}
const preflightPath = 'entry/src/main/ets/services/ssh/auth/SshConnectionPreflight.ets';
const handoffPath = 'entry/src/main/ets/services/ssh/auth/SshAuthenticatedHandoff.ets';
async function begin(e) {
  const controller = new (e.load(preflightPath).SshConnectionPreflight)(e.interaction);
  const result = controller.connect(e.host.id, {});
  for (let i = 0; i < 12; i++) await Promise.resolve();
  assert.equal(e.calls.length, 1);
  return { controller, result };
}
add('preflight_waits_for_native_authentication_and_transfers_exact_session_once', async () => {
  const e = environment(); const { result } = await begin(e);
  let done = false; result.then(() => { done = true; });
  assert.equal(done, false); assert.equal(e.calls[0].foreground, false);
  assert.equal(e.calls[0].config.sshHostKeyPromptEnabled, true);
  e.success(); const token = await result;
  const handoff = e.load(handoffPath).SshAuthenticatedHandoff.getInstance();
  assert.equal(handoff.consume(token, e.host, e.plan), 1);
  assert.equal(handoff.consume(token, e.host, e.plan), -1);
  assert.equal(e.disconnected.length, 0);
});
add('preflight_cancellation_closes_a_late_success_without_routing', async () => {
  const e = environment(); const { controller, result } = await begin(e);
  controller.cancel(); e.success();
  await assert.rejects(result); assert.ok(e.disconnected.includes(1));
});
add('preflight_handles_multiple_mfa_rounds_on_the_same_pending_identity', async () => {
  const e = environment(); const { controller, result } = await begin(e);
  const p = { schemaVersion: 1, sessionId: 1, generation: 101, requestId: 1,
    kind: 'kbd_interactive', prompts: [{ text: 'OTP', echo: false }] };
  e.setPrompt(p); e.tick(); assert.equal(e.prompts.at(-1).requestId, 1);
  assert.equal(controller.submit(p, ['fixture-response']), true);
  const second = { ...p, requestId: 2 };
  e.setPrompt(second); e.tick(); assert.equal(e.prompts.at(-1).requestId, 2);
  assert.equal(controller.submit(second, ['fixture-response']), true);
  e.success(); assert.ok(await result);
});
for (const mode of ['account', 'route', 'username', 'background']) {
  add('preflight_rejects_' + mode + '_changes_during_authentication', async () => {
    const e = environment(); const { result } = await begin(e);
    if (mode === 'account') e.changeScope();
    else if (mode === 'route') e.plan.route.endpointHost = 'different.test';
    else if (mode === 'username') e.host.username = 'different-user';
    else e.stop();
    e.tick(); e.success(); await assert.rejects(result); assert.ok(e.disconnected.includes(1));
  });
}
for (const mode of ['account', 'route', 'username', 'generation', 'expiry']) {
  add('handoff_rejects_' + mode + '_changes_without_reauthentication', async () => {
    const e = environment(); const { result } = await begin(e); e.success(); const token = await result;
    if (mode === 'account') e.changeScope();
    if (mode === 'route') e.plan.route.endpointHost = 'different.test';
    if (mode === 'username') e.host.username = 'different-user';
    if (mode === 'generation') e.sessions.get(1).generation++;
    if (mode === 'expiry') e.expire();
    const handoff = e.load(handoffPath).SshAuthenticatedHandoff.getInstance();
    assert.equal(handoff.consume(token, e.host, e.plan), -1);
    if (mode === 'generation') assert.equal(e.disconnected.length, 0);
    else assert.ok(e.disconnected.includes(1));
  });
}
add('preflight_keeps_canonical_proxy_and_three_ordered_jump_authentication_inputs', async () => {
  const e = environment();
  e.plan.route.type = 'ssh_jump';
  e.plan.route.hops = [
    { host: 'hop-a.test', username: 'a', port: 22, authMethod: 'password' },
    { host: 'hop-b.test', username: 'b', port: 22, authMethod: 'publickey' },
    { host: 'hop-c.test', username: 'c', port: 22, authMethod: 'kbd-interactive' }
  ];
  e.plan.hopKeyIds = ['', 'fixture-key-id', ''];
  const { result } = await begin(e);
  const cfg = e.calls[0].config;
  assert.equal(cfg.sshProxyType, 'ssh_jump');
  assert.equal(cfg.sshProxyAuthMethod, 'password');
  assert.equal(cfg.sshJumpHopHandoffs.length, 3);
  assert.equal(cfg.sshJumpHopHandoffs[0].password, 'test-input');
  assert.equal(cfg.sshJumpHopHandoffs[1].privateKeyPem, 'fixture-key');
  assert.equal(cfg.sshJumpHopHandoffs[2].keyboardInteractiveResponses.length, 0);
  assert.equal(cfg.sshRoute.hops[2].host, 'hop-c.test');
  e.success(); assert.ok(await result);
});
add('preflight_collects_http_proxy_secret_without_falling_back_to_direct', async () => {
  const e = environment();
  e.plan.route.type = 'http_connect'; e.plan.proxyAuthRequired = true;
  e.plan.proxyHost = 'proxy.test'; e.plan.proxyPort = 8080; e.plan.proxyUsername = 'proxy-user';
  const { result } = await begin(e);
  const cfg = e.calls[0].config;
  assert.equal(cfg.sshProxyType, 'http_connect');
  assert.equal(cfg.sshProxyPassword, 'test-input');
  assert.equal(cfg.sshProxyHost, 'proxy.test');
  e.success(); assert.ok(await result);
});
add('retained_authenticated_session_is_restored_without_a_second_login', async () => {
  const e = environment(); const { result } = await begin(e); e.success(); const first = await result;
  const handoff = e.load(handoffPath).SshAuthenticatedHandoff.getInstance();
  assert.equal(handoff.consume(first, e.host, e.plan), 1);
  handoff.remember(e.host, e.plan, 1, 101);
  e.sessions.get(1).detached = true;
  const controller = new (e.load(preflightPath).SshConnectionPreflight)(e.interaction);
  const restored = await controller.connect(e.host.id, {});
  assert.equal(e.calls.length, 1);
  handoff.discard(restored);
  assert.equal(e.sessions.get(1).state, 2);
  assert.equal(e.disconnected.length, 0);
});
add('retained_session_with_changed_route_is_preserved_without_an_orphan_replacement', async () => {
  const e = environment(); const { result } = await begin(e); e.success(); const first = await result;
  const handoff = e.load(handoffPath).SshAuthenticatedHandoff.getInstance();
  handoff.consume(first, e.host, e.plan); handoff.remember(e.host, e.plan, 1, 101);
  e.sessions.get(1).detached = true; e.plan.route.endpointHost = 'changed.test';
  const controller = new (e.load(preflightPath).SshConnectionPreflight)(e.interaction);
  await assert.rejects(controller.connect(e.host.id, {}));
  assert.equal(e.calls.length, 1); assert.equal(e.sessions.get(1).state, 2);
});
add('host_list_success_dismissal_routes_once_while_user_cancellation_discards', () => {
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/HostListPage.ets'), 'utf8');
  const cancel = source.slice(source.indexOf('  private doSshPreflightCancel('),
    source.indexOf('  private sshPreflightSheetHeight('));
  const disappear = source.slice(source.indexOf('  private handleSshPreflightSheetDisappear('),
    source.indexOf('  /** 获取当前 preflight host'));
  const compiled = ts.transpileModule('class Harness {\n' + cancel + disappear +
    '\n} module.exports = Harness;', { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText;
  const discarded = [], routed = []; const module = { exports: {} };
  vm.runInNewContext(compiled, { module, nextRemoteHostSheetGeneration: n => n + 1,
    REMOTE_HOST_SHEET_SSH_PREFLIGHT: 1,
    SshAuthenticatedHandoff: { getInstance: () => ({ discard: token => discarded.push(token) }) },
    setTimeout: callback => callback() });
  function instance(success) {
    return Object.assign(new module.exports(), { sshPreflightClosing: success,
      sshPreflightPendingRouteParams: { hostId: 'fixture', sshAuthenticatedHandoff: 'receipt' },
      sshPreflightPendingHostId: '', sshPreflightHostId: 'fixture', sshPreflightGeneration: 1,
      pageActive: true, appInBackground: false, cancelSshPreflightOperation() {},
      beginRemoteHostSheetClose() {}, noteSheetDismissed() {},
      openSessionDestination: (_page, params) => routed.push(params.sshAuthenticatedHandoff) });
  }
  const success = instance(true); success.doSshPreflightCancel(false);
  success.handleSshPreflightSheetDisappear();
  assert.deepEqual(routed, ['receipt']); assert.equal(discarded.length, 0);
  const cancelled = instance(false); cancelled.doSshPreflightCancel(false);
  cancelled.handleSshPreflightSheetDisappear();
  assert.deepEqual(routed, ['receipt']); assert.deepEqual(discarded, ['receipt']);
});
(async () => {
  for (const test of tests) {
    try { await test.body(); } catch (error) { console.error('FAIL ' + test.name); throw error; }
  }
  console.log('PASS ' + tests.length + ' SSH store, layout, authentication and ownership checks');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
