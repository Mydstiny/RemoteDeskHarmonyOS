'use strict';

// Executes the actual non-Builder page methods with controlled asynchronous
// dependencies. This verifies page logic; it does not emulate ArkUI or a device.
// Run from the repository root. Set AI_TYPESCRIPT_PATH if TypeScript is not on
// Node's module search path. AI_REPO_ROOT optionally overrides the working root.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const ts = require(process.env.AI_TYPESCRIPT_PATH || 'typescript');
const root = process.env.AI_REPO_ROOT || path.resolve(__dirname, '../..');
const sourceHashes = new Map();

function loadPage(name, mocks, structName = name) {
  const file = path.join(root, 'entry/src/main/ets/pages', name + '.ets');
  const original = fs.readFileSync(file, 'utf8');
  const end = original.indexOf('  @Builder');
  assert.ok(end > 0, name + ': lifecycle extraction boundary exists');
  sourceHashes.set(name, crypto.createHash('sha256').update(original).digest('hex'));
  let source = (original.slice(0, end) + '\n}\n')
    .replace(/^import .*;\n/gm, '')
    .replace(/^@(Entry|Component)\s*$/gm, '')
    .replace(/@(?:StorageProp|StorageLink|Watch)\([^\n]*?\)\s*/g, '')
    .replace(/@(?:State|Prop|Link)\s+/g, '')
    .replace('export struct ' + structName, 'class ' + structName);
  source += '\nglobalThis.Page = ' + structName + ';';
  const context = vm.createContext({ Date, JSON, setTimeout, clearTimeout, ...mocks });
  vm.runInContext(ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.None }
  }).outputText, context, { filename: name + '.fixture.js' });
  return new context.Page();
}

async function flush() { for (let index = 0; index < 24; index++) await Promise.resolve(); }
function until(promise, label) {
  let timer;
  return Promise.race([promise, new Promise((_resolve, reject) => {
    timer = setTimeout(() => reject(new Error(label + ' timed out')), 1500);
  })]).finally(() => clearTimeout(timer));
}

function settingsFixture({ deferredInitialize = false } = {}) {
  const state = { owner: 'A', callbacks: [], hostReads: 0, initializations: 0, saves: [], hidden: new Set() };
  state.proVisible = true;
  state.entered = new Promise(resolve => { state.initializeEntered = resolve; });
  const access = {
    capture: () => ({ owner: state.owner, generation: 1, lifecycle: 1 }),
    current: lease => lease !== null && lease.owner === state.owner,
    executable: backend => !state.hidden.has(backend),
    proVisible: () => state.proVisible,
    subscribe: callback => {
      state.callbacks.push(callback); callback();
      return () => { state.callbacks = state.callbacks.filter(value => value !== callback); };
    }
  };
  const defaults = () => ({ showExecution: true, reconnectOnForeground: false, textSize: 15, defaultBackend: 'codex' });
  const store = {
    initialize: async () => {
      state.initializations++;
      if (deferredInitialize && state.initializations === 1) {
        state.initializeEntered();
        await new Promise(resolve => { state.finishInitialize = resolve; });
      }
    },
    settings: async lease => {
      if (!access.current(lease)) throw new Error('AI_ACCOUNT_CHANGED');
      return defaults();
    },
    hosts: async lease => {
      if (!access.current(lease)) throw new Error('AI_ACCOUNT_CHANGED');
      state.hostReads++; return [{ id: state.owner + '-host', owner: state.owner }];
    },
    // Read, change and write in one step (AiLocalStore.updateSettings); what is stored here is always the defaults.
    updateSettings: async (lease, change) => {
      if (!access.current(lease)) throw new Error('AI_ACCOUNT_CHANGED');
      const next = change(defaults()) || defaults();
      state.saves.push(JSON.parse(JSON.stringify(next)));
      return JSON.parse(JSON.stringify(next));
    },
    subscribe: () => () => {}
  };
  state.page = loadPage('AiSettingsPage', {
    AiAccess: { getInstance: () => access },
    AiLocalStore: { getInstance: () => store },
    defaultAiSettings: defaults, aiSettingsMerged: loadModels().aiSettingsMerged, getContext: () => ({}),
    aiErrorText: value => value
  }, 'AiSettingsSurface');
  state.changeAccount = owner => {
    state.owner = owner;
    for (const callback of state.callbacks.slice()) callback();
  };
  state.setProVisible = value => {
    state.proVisible = value;
    for (const callback of state.callbacks.slice()) callback();
  };
  return state;
}

function loadModels() {
  const module = { exports: {} };
  const source = ts.transpileModule(fs.readFileSync(path.join(root, 'entry/src/main/ets/services/ai/AiModels.ets'), 'utf8'),
    { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInNewContext(source, { module, exports: module.exports, require: () => ({ parseEndpointHost: () => ({ ok: true }),
    parseEndpointServerIdentity: () => ({ ok: true }) }) }, { filename: 'AiModels' });
  return module.exports;
}

function loadTimeline() {
  const load = (name, mocks) => {
    const module = { exports: {} };
    const source = ts.transpileModule(fs.readFileSync(path.join(root, 'entry/src/main/ets/services/ai', name + '.ets'), 'utf8'),
      { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
    vm.runInNewContext(source, { module, exports: module.exports, require: key => mocks[key] }, { filename: name });
    return module.exports;
  };
  const models = load('AiModels', { '../EndpointAddressPolicy': { parseEndpointHost: () => ({ ok: true }),
    parseEndpointServerIdentity: () => ({ ok: true }) } });
  return load('AiTimeline', { './AiModels': models });
}
const timeline = loadTimeline();

function workspaceFixture(reconnect, {
  background = false, deferredConnect = false, deferredRefresh = false,
  deferredRelease = false, manualTimers = false, firstOpen = false
} = {}) {
  const state = { background, connects: 0, reads: 0, registered: 0, removed: 0,
    closes: 0, releases: 0, navigations: 0, timers: new Map(), timerSequence: 0, itemDiffs: 0, signatures: 0 };
  const account = { owner: 'fixture', generation: 1, lifecycle: 1 };
  state.entered = new Promise(resolve => { state.connectEntered = resolve; });
  state.refresh = deferredRefresh ? new Promise(resolve => { state.finishRefresh = resolve; }) : Promise.resolve();
  const application = {
    on: (_type, callback) => { state.listener = callback; state.registered++; },
    off: () => { state.removed++; }
  };
  const access = { capture: () => account, current: lease => lease === account,
    subscribe: callback => { callback(); return () => {}; }, executable: () => true, proVisible: () => true,
    assertCurrent: lease => assert.equal(lease, account) };
  class Controller {
    constructor() {
      this.sessionId = ''; this.projectId = ''; this.projects = []; this.sessions = []; this.client = null;
    }
    close() { state.closes++; this.client = null; }
    async connect() {
      state.connects++; this.allowed = true; state.connectEntered();
      if (deferredConnect && state.connects === 1) await new Promise(resolve => { state.finishConnect = resolve; });
    }
    async release() {
      state.releases++;
      if (deferredRelease) await new Promise(resolve => { state.finishRelease = resolve; });
    }
  }
  const timers = manualTimers ? {
    setTimeout: (callback, delay) => {
      const id = ++state.timerSequence;
      state.timers.set(id, { callback, delay }); return id;
    },
    clearTimeout: id => state.timers.delete(id)
  } : {};
  state.page = loadPage('RemoteAiWorkspace', {
    AiWorkspaceController: Controller,
    AiAccess: { getInstance: () => access },
    AiLocalStore: { getInstance: () => ({ settings: async () => {
      state.reads++; return { reconnectOnForeground: reconnect, showExecution: true, textSize: 15 };
    } }) },
    AiHostService: { getInstance: () => ({ refresh: () => state.refresh,
      find: () => ({ id: 'host-fixture', owner: account.owner, backend: 'codex' }) }) },
    getContext: () => ({ getApplicationContext: () => application }),
    AppStorage: { get: () => state.background },
    router: { getParams: () => ({ hostId: 'host-fixture' }), back: () => { state.navigations++; } },
    aiErrorText: value => value, aiStatusLabel: value => value, aiConversationItem: timeline.aiConversationItem,
    aiItemDiff: (item) => { state.itemDiffs++; return timeline.aiItemDiff(item); }, aiDiffFiles: timeline.aiDiffFiles,
    aiDiffStats: timeline.aiDiffStats, aiDiffSignature: (files) => { state.signatures++; return timeline.aiDiffSignature(files); },
    ...timers
  });
  state.page.sync = () => {};
  if (!firstOpen) { state.page.allowed = true; }
  return state;
}

const item = (id, role, kind, extra = {}) => ({ id, role, title: role, text: id, state: 'completed', turnId: 't', kind,
  detail: '', output: '', ...extra });

const cases = [
  ['settings busy account change reloads the new owner', async () => {
    const state = settingsFixture();
    await until(state.page.aboutToAppear(), 'settings appearance');
    let finish;
    const pending = state.page.run(() => new Promise(resolve => { finish = resolve; }));
    state.changeAccount('B'); finish(); await until(pending, 'busy settings operation'); await flush();
    assert.equal(state.page.account.owner, 'B');
    assert.equal(state.page.hosts.length, 1); assert.equal(state.page.hosts[0].owner, 'B');
    state.page.aboutToDisappear();
  }],
  ['settings initial load account change reloads the new owner', async () => {
    const state = settingsFixture({ deferredInitialize: true });
    const appearing = state.page.aboutToAppear();
    await until(state.entered, 'initial store initialization');
    state.changeAccount('B'); state.finishInitialize();
    await until(appearing, 'initial settings account handoff'); await flush();
    assert.equal(state.page.account?.owner, 'B');
    assert.equal(state.page.hosts.length, 1); assert.equal(state.page.hosts[0].owner, 'B');
    state.page.aboutToDisappear();
  }],
  ['settings feature visibility restores the same page after being re-enabled', async () => {
    const state = settingsFixture();
    await until(state.page.aboutToAppear(), 'settings visibility appearance');
    assert.equal(state.page.allowed, true);
    assert.equal(state.page.hosts.length, 1);
    state.setProVisible(false); await flush();
    assert.equal(state.page.allowed, false);
    assert.equal(state.page.account, null);
    state.setProVisible(true); await flush();
    assert.equal(state.page.allowed, true);
    assert.equal(state.page.account?.owner, 'A');
    assert.equal(state.page.hosts.length, 1);
    state.page.aboutToDisappear();
  }],
  ['a hidden unchanged default backend does not block other settings, but a hidden new default is rolled back', async () => {
    const state = settingsFixture();
    await until(state.page.aboutToAppear(), 'settings backend visibility appearance');
    state.hidden.add('codex');
    state.page.settings.showExecution = false; state.page.save(); await flush();
    assert.equal(state.page.error, ''); assert.equal(state.saves.length, 1);
    assert.equal(state.saves[0].showExecution, false); assert.equal(state.saves[0].defaultBackend, 'codex');
    state.hidden.add('dsh');
    state.page.settings.defaultBackend = 'dsh'; state.page.save(); await flush();
    assert.equal(state.saves.length, 1);
    assert.equal(state.page.error, '所选默认 AI 后端已隐藏或暂不可用');
    assert.equal(state.page.settings.defaultBackend, 'codex'); assert.equal(state.page.settings.showExecution, false);
    state.page.aboutToDisappear();
  }],
  ['stored auto-reconnect false is honored during pending first connection', async () => {
    const state = workspaceFixture(false, { deferredConnect: true });
    const appearing = state.page.aboutToAppear(); await until(state.entered, 'first connection');
    state.background = true; state.listener.onApplicationBackground();
    state.background = false; state.listener.onApplicationForeground();
    state.finishConnect(); await until(appearing, 'first appearance'); await flush();
    assert.equal(state.reads, 1); assert.equal(state.page.reconnectForeground, false);
    assert.equal(state.connects, 1); state.page.aboutToDisappear();
  }],
  ['initial background does not connect and permitted foreground resumes once', async () => {
    const state = workspaceFixture(true, { background: true });
    await until(state.page.aboutToAppear(), 'background appearance'); assert.equal(state.connects, 0);
    state.background = false; state.listener.onApplicationForeground();
    await until(state.entered, 'foreground resume'); await flush();
    assert.equal(state.connects, 1); state.page.aboutToDisappear();
  }],
  ['route exit during refresh leaves no late observer or connection', async () => {
    const state = workspaceFixture(true, { deferredRefresh: true });
    const appearing = state.page.aboutToAppear(); state.page.aboutToDisappear(); state.finishRefresh();
    await until(appearing, 'abandoned appearance');
    assert.equal(state.registered, 1); assert.equal(state.removed, 1); assert.equal(state.connects, 0);
  }],
  ['back navigation is bounded when remote release never resolves', async () => {
    const state = workspaceFixture(true, { deferredRelease: true, manualTimers: true });
    state.page.alive = true;
    const leaving = state.page.leave(); await flush();
    assert.equal(state.releases, 1); assert.equal(state.navigations, 0);
    assert.equal(state.timers.size, 1);
    const deadline = Array.from(state.timers.values())[0]; assert.equal(deadline.delay, 800);
    deadline.callback(); await until(leaving, 'release deadline');
    assert.equal(state.closes, 1); assert.equal(state.navigations, 1); assert.equal(state.timers.size, 0);
    state.finishRelease(); await flush(); assert.equal(state.navigations, 1);
  }],
  ['first open connects before any connection has reported access', async () => {
    const state = workspaceFixture(false, { firstOpen: true });
    assert.equal(state.page.allowed, false);
    await until(state.page.aboutToAppear(), 'first open');
    assert.equal(state.connects, 1);
    assert.equal(state.page.canReconnect, true);
    state.page.aboutToDisappear();
  }],
  ['background tasks keep the send button; a running or just accepted turn shows stop', async () => {
    const state = workspaceFixture(false);
    state.page.role = 'operator';
    for (const [status, mode] of [['background', 'send'], ['idle', 'send'], ['running', 'stop'], ['inProgress', 'stop'],
      ['请求已接受，等待执行结果', 'stop']]) {
      state.page.rawStatus = status;
      assert.equal(state.page.composerMode(), mode, status);
    }
    state.page.rawStatus = 'background';
    assert.equal(state.page.backgroundTasks(), true);
    // A viewer device never gets the stop button (it cannot act on the turn).
    state.page.role = 'viewer'; state.page.rawStatus = 'running';
    assert.equal(state.page.composerMode(), 'send');
  }],
  ['hiding tool steps keeps notices and conversation', async () => {
    const state = workspaceFixture(false);
    state.page.items = [item('u', 'user', 'user'), item('tool', 'execution', 'tool'), item('think', 'execution', 'thinking'),
      item('notice', 'execution', 'notice'), item('a', 'assistant', 'assistant'), item('legacy', 'execution', undefined)];
    state.page.showExecution = false;
    assert.deepEqual(state.page.visibleItems().map(value => value.id), ['u', 'notice', 'a']);
    state.page.showExecution = true;
    assert.equal(state.page.visibleItems().length, 6);
  }],
  ['the follow check counts the rows each style and tab actually shows', async () => {
    const state = workspaceFixture(false);
    const rows = [];
    for (let turn = 0; turn < 5; turn++) {
      rows.push(item('u' + turn, 'user', 'user'));
      for (let step = 0; step < 4; step++) {
        rows.push(item('c' + turn + step, 'execution', 'tool', { title: 'Bash', detail: '{"command":"ls"}' }));
      }
      rows.push(item('a' + turn, 'assistant', 'assistant'));
    }
    state.page.items = rows; state.page.historyCursor = ''; state.page.rawStatus = 'idle';
    state.page.uiStyle = 'claude';
    assert.equal(state.page.listLength(), 30);
    state.page.uiStyle = 'codex'; state.page.codexTab = 0;
    assert.equal(state.page.shownItems().length, 10); assert.equal(state.page.listLength(), 10);
    state.page.codexTab = 1;
    assert.equal(state.page.shownItems().length, 20); assert.equal(state.page.listLength(), 20);
    state.page.codexTab = 2;
    assert.equal(state.page.shownItems().length, 0); assert.equal(state.page.listLength(), 1);
    state.page.codexTab = 0; state.page.rawStatus = 'running'; state.page.historyCursor = 'older';
    assert.equal(state.page.listLength(), 12);
  }],
  ['Claude file edits can be allowed; Codex ones need the complete native item', async () => {
    const state = workspaceFixture(false);
    const approval = request => ({ id: 'a', request, expires: Date.now() + 60000 });
    assert.equal(state.page.approvalAcceptable(approval({ kind: 'fileChange', engine: 'claudecode', tool: 'Edit' })), true);
    assert.equal(state.page.approvalAcceptable(approval({ kind: 'fileChange', engine: 'codex' })), false);
    assert.equal(state.page.approvalAcceptable(approval({ kind: 'fileChange', engine: 'codex', nativeItemComplete: true })), true);
    assert.equal(state.page.approvalAcceptable(approval({ kind: 'command' })), true);
  }],
  ['streamed answer text does not parse or sign the diffs again; a changed step does', async () => {
    const state = workspaceFixture(false);
    const edit = item('e1', 'execution', 'tool', { title: 'Edit',
      detail: JSON.stringify({ file_path: '/r/a.ts', old_string: 'a', new_string: 'b' }) });
    state.page.items = [item('u', 'user', 'user'), edit, item('s', 'assistant', 'assistant', { text: '正在' })];
    state.page.diff = '';
    const first = state.page.sessionDiffKey();
    const parses = state.itemDiffs, signs = state.signatures;
    for (let chunk = 0; chunk < 20; chunk++) {
      state.page.items = [item('u', 'user', 'user'), edit, item('s', 'assistant', 'assistant', { text: '正在' + 'x'.repeat(chunk) })];
      assert.equal(state.page.sessionDiffKey(), first);
    }
    assert.equal(state.itemDiffs, parses);
    assert.equal(state.signatures, signs);
    // A step rewritten in place with the same length still changes the diff.
    const rewritten = item('e1', 'execution', 'tool', { title: 'Edit',
      detail: JSON.stringify({ file_path: '/r/a.ts', old_string: 'a', new_string: 'c' }) });
    state.page.items = [item('u', 'user', 'user'), rewritten, item('s', 'assistant', 'assistant', { text: '完成' })];
    assert.notEqual(state.page.sessionDiffKey(), first);
    const second = state.page.sessionDiffKey();
    state.page.items = state.page.items.concat([item('e2', 'execution', 'tool', { title: 'Write',
      detail: JSON.stringify({ file_path: '/r/b.ts', content: 'new' }) })]);
    assert.notEqual(state.page.sessionDiffKey(), second);
    // The engine's own diff takes over and is signed once per text.
    state.page.diff = 'diff --git a/c b/c\n@@ -1 +1 @@\n-1\n+2';
    const native = state.page.sessionDiffKey();
    const nativeSigns = state.signatures;
    assert.equal(state.page.sessionDiffKey(), native);
    assert.equal(state.page.nativeDiffKey(), native);
    assert.equal(state.signatures, nativeSigns);
  }],
  ['a collapsed log output is bounded in lines and characters', async () => {
    const state = workspaceFixture(false);
    assert.equal(state.page.outputPreview('a\nb'), 'a\nb');
    assert.equal(state.page.outputPreview('1\n2\n3\n4\n5\n6\n7'), '1\n2\n3\n4\n5\n6\n…');
    const single = state.page.outputPreview('x'.repeat(1000000));
    assert.ok(single.length <= 802 && single.endsWith('…'));
  }]
];

(async () => {
  let passed = 0;
  for (const [name, run] of cases) {
    try { await run(); passed++; console.log('PASS ' + name); }
    catch (error) { process.exitCode = 1; console.error('FAIL ' + name + ': ' + error.message); }
  }
  for (const [name, hash] of sourceHashes) console.log(name + '-source-sha256=' + hash);
  console.log(passed + '/' + cases.length + ' page lifecycle cases passed');
})().catch(error => { console.error(error.stack); process.exitCode = 1; });
