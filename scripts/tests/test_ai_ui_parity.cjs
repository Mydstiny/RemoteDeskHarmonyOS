'use strict';
// Actual non-Builder methods and callback expressions; no ArkUI renderer/device.
// Run at repo root, AI_TYPESCRIPT_PATH=... node this-file.cjs.
// Optional AI_REVIEW_REF selects immutable Git source; AI_REPO_ROOT sets root.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict'), crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const ts = require(process.env.AI_TYPESCRIPT_PATH || 'typescript');
const root = process.env.AI_REPO_ROOT || process.cwd(), ref = process.env.AI_REVIEW_REF || '';
const cache = new Map(), hashes = new Map();
function read(file) {
  if (!cache.has(file)) {
    const text = ref ? execFileSync('git', ['show', ref + ':' + file], { cwd: root, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 }) : fs.readFileSync(path.join(root, file), 'utf8');
    cache.set(file, text); hashes.set(file, crypto.createHash('sha256').update(text).digest('hex'));
  }
  return cache.get(file);
}
function compile(source, context) {
  vm.runInContext(ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText, context);
}
const modules = new Map();
function loadModule(file) {
  if (modules.has(file)) return modules.get(file);
  const module = { exports: {} };
  const context = vm.createContext({ module, exports: module.exports, Date, JSON, Math,
    require: name => { assert.ok(name.startsWith('.'), 'Only pure relative modules may load'); return loadModule(path.posix.normalize(path.posix.join(path.posix.dirname(file), name)) + '.ets'); } });
  compile(read(file), context); modules.set(file, module.exports); return module.exports;
}
const models = loadModule('entry/src/main/ets/services/ai/AiModels.ets');
function loadClass(file, name, mocks) {
  const original = read(file);
  const cuts = [original.indexOf('  @Builder'), original.indexOf('  build() {')].filter(value => value >= 0);
  assert.ok(cuts.length); const end = Math.min(...cuts);
  const source = (original.slice(0, end) + '\n}\n')
    .replace(/^import .*;\n/gm, '').replace(/^@(Entry|Component)\s*$/gm, '')
    .replace(/@(?:StorageProp|StorageLink|Watch)\([^\n]*?\)\s*/g, '')
    .replace(/@(?:State|Prop|Link)\s+/g, '').replace('export struct ' + name, 'class ' + name);
  const context = vm.createContext({ Date, JSON, Math, setTimeout, clearTimeout, ...mocks });
  compile(source + '\nglobalThis.Target = ' + name + ';', context); return new context.Target();
}
// Extract an existing balanced call argument rather than reimplement its callback.
function argument(source, needle, last = false) {
  const at = last ? source.lastIndexOf(needle) : source.indexOf(needle);
  assert.ok(at >= 0, 'Missing production expression: ' + needle);
  const start = at + needle.length;
  const scanner = ts.createScanner(ts.ScriptTarget.ESNext, true, ts.LanguageVariant.Standard, source);
  scanner.setTextPos(start); let depth = 1, token;
  while ((token = scanner.scan()) !== ts.SyntaxKind.EndOfFileToken) {
    if (token === ts.SyntaxKind.OpenParenToken) depth++;
    if (token === ts.SyntaxKind.CloseParenToken && --depth === 0) return source.slice(start, scanner.getTokenPos());
  }
  throw new Error('Unbalanced production expression');
}
function evaluate(expression, owner, globals = {}) {
  const context = vm.createContext({ Math, ...globals });
  compile('globalThis.make = function () { return (' + expression + '); };', context);
  return context.make.call(owner);
}
function callback(file, needle, owner) { return evaluate(argument(read(file), needle, false), owner); }
function deferred() { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; }
async function bounded(promise) {
  let timer; try { return await Promise.race([promise, new Promise((_done, reject) => { timer = setTimeout(() => reject(Error('fixture timed out')), 2000); })]); }
  finally { clearTimeout(timer); }
}
function authority() {
  const state = { owner: 'owner-' + 'a'.repeat(64), granted: true, callbacks: [] };
  const access = { capture: () => ({ owner: state.owner, generation: 1, lifecycle: 1 }),
    current: lease => lease !== null && lease.owner === state.owner,
    assertCurrent: lease => { if (!access.current(lease)) throw Error('AI_ACCOUNT_CHANGED'); },
    executable: () => state.granted,
    proVisible: () => state.granted,
    subscribe: cb => { state.callbacks.push(cb); cb(); return () => { state.callbacks = state.callbacks.filter(value => value !== cb); }; } };
  state.access = access; state.publish = () => { for (const cb of state.callbacks.slice()) cb(); }; return state;
}
const editorFile = 'entry/src/main/ets/components/ai/AiHostEditor.ets';
const workspaceFile = 'entry/src/main/ets/pages/RemoteAiWorkspace.ets';
async function editor({ blocked = false, defaultsBlocked = false, defaultBackend = 'codex', granted = true } = {}) {
  const state = authority(), gate = deferred(); state.granted = granted; let initializes = 0;
  Object.assign(state, { pairs: [], saves: [], completions: [], backs: 0, closes: 0 });
  state.page = loadClass(editorFile, 'AiHostEditor', {
    ...models, aiRandomId: () => 'fixture-host', AiAccess: { getInstance: () => state.access },
    AiLocalStore: { getInstance: () => ({ initialize: () => (++initializes === 1 ? defaultsBlocked : blocked) ? gate.promise : Promise.resolve(),
      settings: async () => ({ ...models.defaultAiSettings(), defaultBackend }),
      saveHost: async (_lease, host) => { state.saves.push(JSON.parse(JSON.stringify(host))); },
      connection: async () => ({ identity: null }) }) },
    HostSyncService: { getInstance: () => ({ getAllRelays: () => [] }) },
    AiLanDiscoveryService: class {
      stopScan() {}
      startScan() { return Promise.resolve([]); }
    },
    AiBridgeClient: { pair: async (host, invitation) => {
      assert.ok(state.granted, 'Pair called without current access'); state.pairs.push({ host: JSON.parse(JSON.stringify(host)), invitation });
    } }, getContext: () => ({}), aiErrorText: value => value
  });
  state.release = gate.resolve; state.page.aboutToAppear();
  for (let i = 0; i < 5; i++) await Promise.resolve();
  state.page.label = 'Fixture'; state.page.address = '192.0.2.1';
  state.page.onSaved = (id, connect) => state.completions.push({ id, connect });
  state.page.onBackToProtocols = () => { state.backs++; }; state.page.onClose = () => { state.closes++; };
  return state;
}
function workspace() {
  const state = authority(); Object.assign(state, { background: false, closes: 0, appCallbacks: new Set() });
  const app = { on: (_name, cb) => { state.appCallbacks.add(cb); state.application = cb; }, off: (_name, cb) => state.appCallbacks.delete(cb) };
  class Controller {
    constructor() { this.onChange = () => {}; this.stop = () => {}; this.reset(); }
    reset() { Object.assign(this, { title: '', status: '', error: '', projects: [], sessions: [], transcript: { items: [] }, approvals: [], operations: [], terminals: [], models: [], allowed: false, archived: false, sessionId: '', projectId: '', historyCursor: '', lease: '', leaseExpires: 0, diff: '', client: null }); }
    close() { state.closes++; this.stop(); this.stop = () => {}; this.reset(); }
    async connect(host) {
      this.close(); const account = state.access.capture(); this.client = { account, host };
      this.title = 'Fixture session'; this.sessionId = 'fixture-session'; this.projectId = 'fixture-project'; this.allowed = state.granted;
      this.stop = state.access.subscribe(() => { if (!state.access.current(account)) this.close(); else this.allowed = state.granted; this.onChange(); });
    }
  }
  state.page = loadClass(workspaceFile, 'RemoteAiWorkspace', {
    AiWorkspaceController: Controller, AiAccess: { getInstance: () => state.access },
    AiLocalStore: { getInstance: () => ({ settings: async () => ({ showExecution: true, reconnectOnForeground: false, textSize: 15 }) }) },
    AiHostService: { getInstance: () => ({ refresh: async () => {}, find: () => ({ id: 'fixture-host', owner: state.owner, label: 'Fixture A host', backend: 'codex' }) }) },
    getContext: () => ({ getApplicationContext: () => app }), AppStorage: { get: () => state.background },
    router: { getParams: () => ({ hostId: 'fixture-host' }) }, aiErrorText: value => value, aiStatusLabel: value => value
  }); return state;
}
function fillDrafts(page) {
  for (const key of ['draft', 'newTitle', 'model', 'provider', 'effort', 'permission', 'collaboration']) page[key] = 'fixture draft';
  page.attachments = ['fixture']; page.efforts = ['high']; page.approval = { id: 'fixture' }; page.questions = [{ id: 'fixture' }];
  page.showDetails = true; page.showApproval = true; page.showApprovalDetails = true; page.showSessionPicker = true;
}
function cleanDrafts(page) {
  for (const key of ['draft', 'newTitle', 'model', 'provider', 'effort', 'permission', 'collaboration']) assert.equal(page[key], '', key);
  for (const key of ['attachments', 'efforts', 'questions']) assert.equal(page[key].length, 0, key);
  for (const key of ['showDetails', 'showApproval', 'showApprovalDetails', 'showSessionPicker']) assert.equal(page[key], false, key);
  assert.equal(page.approval, null);
}
const cases = [
  ['settings write failure restores displayed settings without changing another account', async () => {
    for (const changeAccount of [false, true]) {
      const state = authority(); let attempted;
      const page = loadClass('entry/src/main/ets/pages/AiSettingsPage.ets', 'AiSettingsSurface', {
        ...models, AiAccess: { getInstance: () => state.access }, aiErrorText: value => value,
        AiLocalStore: { getInstance: () => ({ saveSettings: async (_account, next) => {
          attempted = next;
          if (changeAccount) { state.owner = 'owner-' + 'b'.repeat(64); page.settings = { ...models.defaultAiSettings(), textSize: 21 }; }
          throw Error('storage unavailable');
        } }) }
      });
      page.alive = true; page.allowed = true; page.account = state.access.capture(); page.savedSettingsAccount = page.account;
      page.settingsReady = true; page.savedSettings = models.defaultAiSettings();
      page.settings = { ...models.defaultAiSettings(), textSize: 19, defaultBackend: 'dsh' }; page.save();
      for (let i = 0; i < 8; i++) await Promise.resolve();
      assert.equal(attempted.defaultBackend, 'dsh'); assert.equal(attempted.textSize, 19);
      assert.equal(page.settings.textSize, changeAccount ? 21 : 15);
      assert.equal(page.busy, false); assert.equal(page.error, 'storage unavailable');
    }
  }],
  ['failed new-account load blocks saving and cannot reuse previous account rollback data', async () => {
    const state = authority(); let failRead = false; const writes = [];
    const store = { initialize: async () => {}, settings: async () => {
      if (failRead) throw Error('read failure');
      return { ...models.defaultAiSettings(), defaultBackend: 'dsh', textSize: 21 };
    }, hosts: async () => [], saveSettings: async (lease, next) => { writes.push({ lease, next }); } };
    const page = loadClass('entry/src/main/ets/pages/AiSettingsPage.ets', 'AiSettingsSurface', {
      ...models, AiAccess: { getInstance: () => state.access }, AiLocalStore: { getInstance: () => store },
      getContext: () => ({}), aiErrorText: value => value
    });
    await page.aboutToAppear(); assert.equal(page.settingsReady, true);
    failRead = true; state.owner = 'owner-' + 'b'.repeat(64); state.publish();
    for (let i = 0; i < 12; i++) await Promise.resolve();
    assert.equal(page.settingsReady, false); assert.equal(page.savedSettings, null); assert.equal(page.savedSettingsAccount, null);
    page.settings.textSize = 17; page.save(); for (let i = 0; i < 5; i++) await Promise.resolve();
    assert.equal(writes.length, 0); page.aboutToDisappear();
  }],
  ['free users still receive their saved default AI for local configuration', async () => {
    const state = await editor({ defaultBackend: 'dsh', granted: false });
    assert.equal(state.page.backend, 'dsh'); assert.equal(state.page.port, '9444');
    assert.equal(state.page.allowed, false); state.page.aboutToDisappear();
  }],
  ['new host uses saved default backend and matching port', async () => {
    const state = await editor({ defaultBackend: 'dsh' });
    assert.equal(state.page.backend, 'dsh'); assert.equal(state.page.port, '9444');
    assert.equal(state.page.defaultsPending, false); state.page.aboutToDisappear();
  }],
  ['pending defaults freeze user edits and stale account cannot populate form', async () => {
    const state = await editor({ defaultsBlocked: true, defaultBackend: 'dsh' }), page = state.page;
    page.selectBackend('dsh'); page.nextStep(); await page.save(true);
    assert.equal(page.backend, 'codex'); assert.equal(page.step, 1); assert.equal(state.saves.length, 0);
    state.owner = 'owner-' + 'b'.repeat(64); state.publish(); state.release();
    for (let i = 0; i < 5; i++) await Promise.resolve();
    assert.equal(page.backend, 'codex'); assert.equal(page.draft, null); assert.equal(page.defaultsPending, false);
    page.aboutToDisappear();
  }],
  ['edit retains complete form even when new-host preference is modern', async () => {
    const state = await editor(), page = state.page; page.modern = true;
    assert.equal(page.wizard(), true); page.host = models.emptyAiHost(state.owner, 'existing', 'dsh');
    assert.equal(page.wizard(), false); page.aboutToDisappear();
  }],
  ['modern validation, two-step return and FAB protocol return', async () => {
    const state = await editor(), page = state.page; page.modern = true; page.canReturnToProtocols = true;
    page.address = ''; page.nextStep(); assert.equal(page.step, 1);
    page.address = '192.0.2.1'; page.nextStep(); assert.equal(page.step, 2);
    page.previousStep(); assert.equal(page.step, 1); assert.equal(state.backs, 0);
    page.invite = 'fixture'; page.previousStep(); assert.equal(state.backs, 1); assert.equal(page.invite, '');
    page.canReturnToProtocols = false; page.previousStep(); assert.equal(state.backs, 1);
    assert.equal(state.saves.length + state.pairs.length, 0); page.aboutToDisappear();
  }],
  ['classic full form and modern step visibility declarations', async () => {
    const source = read(editorFile);
    const host = source.match(/if \(([^\n]+)\) \{ this\.hostFields\(\) \}/)[1];
    const pair = source.match(/if \(([^\n]+)\) \{ this\.pairingFields\(\) \}/)[1];
    assert.equal(evaluate(host, { modern: false, step: 1, wizard() { return this.modern; } }), true); assert.equal(evaluate(pair, { modern: false, step: 1, wizard() { return this.modern; } }), true);
    assert.equal(evaluate(host, { modern: true, step: 1, wizard() { return this.modern; } }), true); assert.equal(evaluate(pair, { modern: true, step: 1, wizard() { return this.modern; } }), false);
    assert.equal(evaluate(host, { modern: true, step: 2, wizard() { return this.modern; } }), false); assert.equal(evaluate(pair, { modern: true, step: 2, wizard() { return this.modern; } }), true);
  }],
  ['same backend keeps custom port and busy methods cannot switch', async () => {
    const state = await editor(), page = state.page; page.port = '12345'; page.invite = 'fixture'; page.selectBackend('codex');
    assert.equal(page.port, '12345'); assert.equal(page.invite, 'fixture');
    page.busy = true; page.selectBackend('dsh'); page.nextStep(); page.previousStep(); await page.save(true);
    assert.equal(page.backend, 'codex'); assert.equal(page.step, 1); assert.equal(state.pairs.length + state.saves.length, 0);
    page.busy = false; page.selectBackend('dsh'); assert.equal(page.port, '9444'); assert.equal(page.invite, ''); page.aboutToDisappear();
  }],
  ['relay route requires a configured RustDesk binding and persists the selected route', async () => {
    const state = await editor(), page = state.page;
    page.selectTransport('rustdesk'); page.nextStep();
    assert.equal(page.step, 1); assert.equal(page.error, '请选择已配置的 RustDesk 中继');
    page.relays = [{ id: 'relay-1', displayName: () => 'relay.example.com', relayServer: 'relay.example.com', relayPort: 21117 }];
    page.selectRelay('relay-1'); page.nextStep();
    assert.equal(page.step, 2); page.onSaved = (id, connect) => state.completions.push({ id, connect });
    await page.save(true); for (let i = 0; i < 8; i++) await Promise.resolve();
    assert.equal(state.saves.at(-1).transport, 'rustdesk'); assert.equal(state.saves.at(-1).relayHostId, 'relay-1');
    assert.equal(state.completions.at(-1).connect, false); page.aboutToDisappear();
  }],
  ['unpaired LAN save never requests a connection', async () => {
    const state = await editor(), page = state.page;
    page.nextStep(); assert.equal(page.step, 2);
    await page.save(true); for (let i = 0; i < 8; i++) await Promise.resolve();
    assert.equal(state.saves.length, 1); assert.equal(state.pairs.length, 0);
    assert.equal(state.completions.at(-1).connect, false); page.aboutToDisappear();
  }],
  ['save freezes both host and invitation before initialization', async () => {
    const state = await editor({ blocked: true }), page = state.page; page.invite = 'original invitation';
    const saving = page.save(true); page.invite = 'replacement invitation'; page.label = 'replacement label'; state.release(); await bounded(saving);
    assert.equal(state.pairs.length, 1); assert.equal(state.pairs[0].invitation, 'original invitation');
    assert.equal(state.pairs[0].host.label, 'Fixture'); assert.equal(state.saves.length, 0); assert.equal(state.completions.length, 1); page.aboutToDisappear();
  }],
  ...['background', 'exit', 'revoke_restore', 'account'].map(reason => [reason + ' during initialization cannot downgrade or dispatch the old save', async () => {
    const state = await editor({ blocked: true }), page = state.page; page.invite = 'fixture invitation'; const saving = page.save(true);
    if (reason === 'background') { page.inBackground = true; page.onBackgroundChanged(); page.inBackground = false; }
    if (reason === 'exit') page.aboutToDisappear();
    if (reason === 'revoke_restore') { state.granted = false; state.publish(); state.granted = true; state.publish(); }
    if (reason === 'account') { state.owner = 'owner-' + 'b'.repeat(64); state.publish(); }
    state.release(); await bounded(saving); assert.equal(state.pairs.length, 0); assert.equal(state.saves.length, 0); assert.equal(state.completions.length, 0); assert.equal(page.invite, '');
    if (reason !== 'exit') page.aboutToDisappear();
  }]),
  ['late invitation IME callbacks honor alive, background, busy and access', async () => {
    const state = await editor(), page = state.page, change = callback(editorFile, '.onChange(', page);
    for (const [key, value] of [['alive', false], ['inBackground', true], ['busy', true], ['allowed', false]]) {
      Object.assign(page, { alive: true, inBackground: false, busy: false, allowed: true, invite: '' }); page[key] = value;
      change('late fixture invitation'); assert.equal(page.invite, '', key);
    }
    Object.assign(page, { alive: true, inBackground: false, busy: false, allowed: true }); change('accepted fixture'); assert.equal(page.invite, 'accepted fixture'); page.aboutToDisappear();
  }],
  ['shared field/action callbacks respect disabled controls', async () => {
    const field = { isEnabled: false, calls: 0, onChange() { this.calls++; } };
    const action = { isEnabled: false, calls: 0, onAction() { this.calls++; } };
    const change = callback('entry/src/main/ets/components/ai/AiFormField.ets', '.onChange(', field);
    const click = callback('entry/src/main/ets/components/ai/AiActionButton.ets', '.onClick(', action);
    change('fixture'); click(); assert.equal(field.calls, 0); assert.equal(action.calls, 0);
    field.isEnabled = true; action.isEnabled = true; change('fixture'); click(); assert.equal(field.calls, 1); assert.equal(action.calls, 1);
  }],
  ['workspace account invalidation clears own drafts, sheets and old host fallback', async () => {
    const state = workspace(); await bounded(state.page.aboutToAppear()); fillDrafts(state.page);
    state.owner = 'owner-' + 'b'.repeat(64); state.publish(); cleanDrafts(state.page);
    assert.equal(state.page.host, null); assert.equal(state.page.title, '远程 AI'); state.page.aboutToDisappear(); assert.equal(state.callbacks.length, 0);
  }],
  ['workspace revoke and restore cannot bring cleared drafts back', async () => {
    const state = workspace(); await bounded(state.page.aboutToAppear()); fillDrafts(state.page);
    state.granted = false; state.publish(); cleanDrafts(state.page); state.granted = true; state.publish(); cleanDrafts(state.page); state.page.aboutToDisappear();
  }],
  ['independent page access listener survives background close and clears later account data', async () => {
    const state = workspace(); await bounded(state.page.aboutToAppear()); fillDrafts(state.page);
    state.background = true; state.application.onApplicationBackground(); cleanDrafts(state.page); assert.equal(state.callbacks.length, 1);
    state.owner = 'owner-' + 'b'.repeat(64); state.publish(); cleanDrafts(state.page); assert.equal(state.page.host, null);
    assert.equal(state.page.resumeAccount, null); assert.equal(state.page.resumeSession, ''); assert.equal(state.page.title, '远程 AI');
    state.page.aboutToDisappear(); assert.equal(state.callbacks.length, 0); assert.equal(state.appCallbacks.size, 0);
  }],
  ['small-height declarations keep one scrollable natural-height tree and a bounded list', async () => {
    const source = read(workspaceFile), body = source.slice(source.indexOf('  @Builder private workspace()'), source.indexOf('  build() {'));
    assert.ok(source.includes('.scrollable(ScrollDirection.Vertical)')); assert.ok(!source.includes('ScrollDirection.None'));
    assert.equal((source.match(/Scroll\(\) \{ this\.workspace\(\) \}/g) || []).length, 1);
    const suffix = body.slice(body.lastIndexOf("}.width('100%')")); assert.ok(suffix.includes('minHeight:')); assert.ok(!suffix.includes('.height('));
    const height = argument(body, '}.height('); // The transcript List's production expression.
    for (const pageHeight of [160, 320, 399, 400, 480, 800]) for (const topInset of [0, 32, 80]) for (const sessionId of ['', 'fixture']) {
      const value = evaluate(height, { pageHeight, topInset, sessionId }); assert.ok(Number.isFinite(value) && value >= 180);
    }
  }],
  ['settings editor honors saved style and the shared sheet keyboard policy', async () => {
    const source = read('entry/src/main/ets/pages/AiSettingsPage.ets');
    const style = loadModule('entry/src/main/ets/services/FabAddStylePolicy.ets');
    const modern = source.match(/AiHostEditor\(\{ host: this\.editing, modern: ([^\n]+),/)[1];
    for (const isDesktopDevice of [false, true]) {
      assert.equal(evaluate(modern, { fabAddStyle: 'classic', isDesktopDevice }, style), false);
      assert.equal(evaluate(modern, { fabAddStyle: 'modern', isDesktopDevice }, style), true);
    }
    assert.ok(source.includes("@StorageProp('hostAddMode')")); assert.ok(source.includes('height: SheetSize.FIT_CONTENT'));
    assert.ok(source.includes('keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL'));
  }],
  ['Pro markers stay semantic, visible and revoked approval inputs stay disabled', async () => {
    const badge = read('entry/src/main/ets/components/ProBadge.ets');
    assert.ok(badge.includes("accessibilityText('Pro 功能标识')"));
    const header = read('entry/src/main/ets/components/AppSheetHeader.ets');
    assert.ok(header.includes('@Prop showProBadge: boolean = false;'));
    const workspace = read(workspaceFile);
    const headers = workspace.split('\n').filter(line => line.includes('AppSheetHeader({'));
    assert.equal(headers.length, 4);
    assert.equal(headers.filter(line => line.includes('showProBadge: true')).length, 4);
    assert.ok(workspace.includes("enabled(!this.busy && this.allowed).accessibilityText(question.title)"));
    const settings = read('entry/src/main/ets/pages/AiSettingsPage.ets');
    assert.ok(settings.includes("this.accessText === '' ? 'Pro 远程 AI' : this.accessText"));
    const hosts = read('entry/src/main/ets/pages/HostListPage.ets');
    for (const marker of ['@Builder hostGroupedHostCard(host: RemoteHost)', '@Builder flatRemoteHostListItem(host: RemoteHost)']) {
      const start = hosts.indexOf(marker), end = hosts.indexOf('\n  @Builder', start + marker.length);
      assert.ok(start >= 0 && end > start, 'Missing host card builder: ' + marker);
      const body = hosts.slice(start, end), columns = [...body.matchAll(/Column\(\) \{/g)].map(match => match.index);
      const badge = body.indexOf('ProBadge()');
      assert.ok(columns.length >= 3 && badge > columns[1] && badge < columns[2], 'ProBadge must stay in the host title column');
    }
  }],
  ['Pro AI picker order and settings leaf routes stay aligned with shared sheets', async () => {
    const picker = read('entry/src/main/ets/components/hostadd/HostProtocolPicker.ets');
    assert.ok(picker.indexOf("protocolOption('moonlight'") < picker.indexOf("protocolOption('ai'"));
    assert.ok(picker.includes('ProBadge().margin({ right: 8 }).alignSelf(ItemAlign.Center)'));
    const hosts = read('entry/src/main/ets/pages/HostListPage.ets');
    assert.ok(hosts.indexOf('this.sidebarMoonlightTab()') < hosts.indexOf("this.sidebarTab('远程 AI · Pro'"));
    assert.ok(hosts.includes("if (card.type === 'ai') { ProBadge().margin({ right: 8 }).alignSelf(ItemAlign.Center) }"));
    assert.ok(hosts.indexOf('this.moonlightGroupedPhoneGroup()') < hosts.indexOf("this.hostGroupedPhoneGroup('ai')"));
    assert.ok(hosts.includes("else {\n            Blank()\n              .width(this.breakpoint === 'sm' ? 38 : 40)"));
    const aiSettingsStart = hosts.indexOf("this.settingsAccordionHeader(SETTINGS_SECTION_AI");
    const aiSettingsEnd = hosts.indexOf("this.settingsAccordionHeader(SETTINGS_SECTION_MOONLIGHT", aiSettingsStart);
    const aiSettings = hosts.slice(aiSettingsStart, aiSettingsEnd);
    for (const mode of ['SETTINGS_SHEET_AI_HOSTS', 'SETTINGS_SHEET_AI_DISPLAY', 'SETTINGS_SHEET_AI_DATA', 'SETTINGS_SHEET_AI_INSTALL']) {
      assert.ok(aiSettings.includes('openSettingsLeafSheet(' + mode + ')'), 'Missing shared leaf route: ' + mode);
    }
    assert.ok(!aiSettings.includes("router.pushUrl({ url: 'pages/AiSettingsPage'"));
    assert.ok(hosts.includes('AiSettingsSurface({') && hosts.includes('embedded: true'));
    assert.ok(hosts.includes('return SheetSize.FIT_CONTENT;'));
    const routePolicy = read('entry/src/main/ets/services/SettingsSheetRoutePolicy.ets');
    assert.ok(routePolicy.includes('SETTINGS_SHEET_AI_HOSTS')); assert.ok(routePolicy.includes('aiSettingsLeafSheetHeight'));
    const settingsPage = read('entry/src/main/ets/pages/AiSettingsPage.ets');
    assert.ok(settingsPage.includes('@Prop @Watch(\'onRequestedSectionChange\') requestedSection: string ='));
    assert.ok(settingsPage.includes('@Prop embedded: boolean = false;'));
    assert.ok(settingsPage.includes('@Prop viewportHeight: number = 720;'));
    assert.ok(settingsPage.includes('embeddedSheetMaxHeight()'));
    assert.ok(settingsPage.includes("height(this.embedded ? 'auto' : '100%')"));
    assert.ok(settingsPage.includes('layoutWeight(this.embedded ? 0 : 1)'));
    assert.ok(settingsPage.includes('if (this.embedded) { this.onClose(); } else { router.back(); }'));
    assert.ok(settingsPage.includes('@State routeSection: string ='));
    assert.ok(settingsPage.includes('aboutToAppear(): void {\n    this.routeSection = this.readRouteSection();'));
    assert.ok(settingsPage.includes('onPageShow(): void {\n    this.routeSection = this.readRouteSection();'));
    assert.ok(settingsPage.includes('AiSettingsSurface({ requestedSection: this.routeSection })'));
    const editor = read('entry/src/main/ets/components/ai/AiHostEditor.ets');
    assert.ok(editor.includes('ProBadge().alignSelf(ItemAlign.Center).margin({ right: 8 })'));
    assert.ok(editor.includes('@StorageProp(\'currentBreakpoint\') breakpoint: string = \'sm\';'));
    assert.ok(editor.includes('Scroll() {') && editor.includes('constraintSize({ maxHeight: this.breakpoint === \'sm\' ? 520 : 560 })'));
    const backendCard = read('entry/src/main/ets/components/ai/AiBackendChoiceCard.ets');
    assert.ok(backendCard.includes('.height(68)') && backendCard.includes('.borderRadius(16)'));
    const routeCard = read('entry/src/main/ets/components/ai/AiConnectionPathCard.ets');
    assert.ok(routeCard.includes('.height(68)') && routeCard.includes('.borderRadius(16)'));
    assert.ok(editor.includes('AiBackendChoiceCard({ backend: \'codex\''));
    assert.ok(editor.includes('AiConnectionPathCard({ path: \'lan\''));
    assert.ok(editor.includes('AiConnectionPathCard({ path: \'rustdesk\''));
    assert.ok(editor.includes('选择 RustDesk 中继'));
    assert.ok(editor.includes('局域网搜索') && editor.includes('搜索局域网 Agent'));
    assert.ok(editor.includes('selectLanAgent') && editor.includes('startLanScan'));
    assert.ok(editor.includes('从剪贴板粘贴邀请') && editor.includes('pasteInvite'));
    assert.ok(editor.includes('bin/remotedesk-codex.mjs invite') && editor.includes('bin/remotedesk-dsh.mjs invite'));
    const lanDiscovery = read('entry/src/main/ets/services/ai/AiLanDiscoveryService.ets');
    assert.ok(lanDiscovery.includes('aiLanCandidateAddresses') && lanDiscovery.includes('MAX_CONCURRENCY'));
    assert.ok(lanDiscovery.includes('getDefaultNet') && lanDiscovery.includes('CONNECT_TIMEOUT_MS: number = 320'));
    assert.ok(settingsPage.includes('AiBackendChoiceCard({ backend: \'codex\''));
    assert.ok(read('entry/src/main/ets/components/ai/AiHostInstallPanel.ets').includes('AiBackendChoiceCard({ backend: \'codex\''));
    assert.ok(settingsPage.includes("padding({ top: this.embedded ? 0 : (this.topInset > 0 ? px2vp(this.topInset) : 0) })"));
    const actionRow = read('entry/src/main/ets/components/AppSettingsActionRow.ets');
    assert.ok(!actionRow.includes('Button({ type: ButtonType.Normal })'), 'Settings action rows must not use native rectangular Button clipping');
    assert.ok(actionRow.includes('.borderRadius(20)') && actionRow.includes('.focusable(this.isEnabled)'), 'Settings action rows must retain rounded accessible hit targets');
  }]
];
(async () => {
  let passed = 0;
  for (const [name, run] of cases) {
    try { await bounded(run()); passed++; console.log('PASS ' + name); }
    catch (error) { process.exitCode = 1; console.error('FAIL ' + name + ': ' + error.message); }
  }
  console.log(passed + '/' + cases.length + ' UI polish cases passed; declaration checks are not rendered-device acceptance');
  for (const [file, hash] of hashes) if (/components\/ai|pages\/(AiSettingsPage|RemoteAiWorkspace)/.test(file)) console.log(file + ' sha256=' + hash);
})().catch(error => { console.error(error.stack); process.exitCode = 1; });
