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
  const state = { owner: 'A', callbacks: [], hostReads: 0, initializations: 0 };
  state.entered = new Promise(resolve => { state.initializeEntered = resolve; });
  const access = {
    capture: () => ({ owner: state.owner, generation: 1, lifecycle: 1 }),
    current: lease => lease !== null && lease.owner === state.owner,
    executable: () => true,
    subscribe: callback => {
      state.callbacks.push(callback); callback();
      return () => { state.callbacks = state.callbacks.filter(value => value !== callback); };
    }
  };
  const defaults = () => ({ showExecution: true, reconnectOnForeground: false, textSize: 15 });
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
    }
  };
  state.page = loadPage('AiSettingsPage', {
    AiAccess: { getInstance: () => access },
    AiLocalStore: { getInstance: () => store },
    defaultAiSettings: defaults, getContext: () => ({}), aiErrorText: value => value
  }, 'AiSettingsSurface');
  state.changeAccount = owner => {
    state.owner = owner;
    for (const callback of state.callbacks.slice()) callback();
  };
  return state;
}

function workspaceFixture(reconnect, {
  background = false, deferredConnect = false, deferredRefresh = false,
  deferredRelease = false, manualTimers = false
} = {}) {
  const state = { background, connects: 0, reads: 0, registered: 0, removed: 0,
    closes: 0, releases: 0, navigations: 0, timers: new Map(), timerSequence: 0 };
  const account = { owner: 'fixture', generation: 1, lifecycle: 1 };
  state.entered = new Promise(resolve => { state.connectEntered = resolve; });
  state.refresh = deferredRefresh ? new Promise(resolve => { state.finishRefresh = resolve; }) : Promise.resolve();
  const application = {
    on: (_type, callback) => { state.listener = callback; state.registered++; },
    off: () => { state.removed++; }
  };
  const access = { capture: () => account, current: lease => lease === account,
    subscribe: callback => { callback(); return () => {}; }, executable: () => true,
    assertCurrent: lease => assert.equal(lease, account) };
  class Controller {
    constructor() {
      this.sessionId = ''; this.projectId = ''; this.projects = []; this.sessions = []; this.client = null;
    }
    close() { state.closes++; this.client = null; }
    async connect() {
      state.connects++; state.connectEntered();
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
    aiErrorText: value => value, aiStatusLabel: value => value, ...timers
  });
  state.page.sync = () => {};
  return state;
}

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
