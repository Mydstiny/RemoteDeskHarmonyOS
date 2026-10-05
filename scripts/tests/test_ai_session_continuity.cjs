'use strict';

/*
 * The AI in a remote session and what the AI knows about the newest features:
 * - the session's orb works for the signed-in account (its AI 配置), survives a dropped connection, and the host list
 *   carries it on when the user leaves the host (source contracts: these are ArkUI components);
 * - 远程 AI 设置 (界面风格, 显示工具执行过程, 回到前台后恢复查看) are in the AI's settings catalog, read and saved per
 *   account through AiHostService;
 * - 手机通行密钥 and 安全密钥重定向 are app actions; the knowledge base describes 远程 AI, Claude Agent and both keys
 *   with ids that exist.
 */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.AI_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const ETS = path.join(root, 'entry/src/main/ets');
const storage = new Map();
const AppStorage = { get: (key) => storage.get(key), setOrCreate: (key, value) => { storage.set(key, value); } };
const anyModule = new Proxy(function () {}, {
  get: (_t, key) => (key === '__esModule' ? false : anyModule),
  apply: () => anyModule,
  construct: () => anyModule
});
const kits = {
  '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {} } },
  '@kit.AbilityKit': { common: {} }
};

/** Loads `file` (relative to ets/) with `mocks` for some of its imports (keyed by the import text). */
function load(file, mocks = {}, cache = new Map()) {
  if (cache.has(file)) return cache.get(file).exports;
  const full = path.join(ETS, file + '.ets');
  if (!fs.existsSync(full)) return anyModule;
  const context = vm.createContext({ Math, Number, String, Object, Array, Map, Set, Error, JSON, Date, Promise, AppStorage,
    isNaN, console });
  const output = ts.transpileModule(fs.readFileSync(full, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const fresh = { exports: {} };
  cache.set(file, fresh);
  const req = (name) => {
    if (name in mocks) return mocks[name];
    if (kits[name]) return kits[name];
    if (name.startsWith('@')) return anyModule;
    const child = path.posix.normalize(path.posix.join(path.posix.dirname(file), name));
    return load(child, mocks, cache);
  };
  vm.runInContext('(function(require,module,exports){' + output + '\n})', context)(req, fresh, fresh.exports);
  return fresh.exports;
}
const read = (file) => fs.readFileSync(path.join(ETS, file), 'utf8');
const tests = [];
function test(name, body) { tests.push({ name, body }); }
async function settle() { for (let i = 0; i < 20; i++) await Promise.resolve(); }

const D = 'services/diagnosticAi/';

// ---------------------------------------------------------------- 远程 AI 设置 as values
test('远程 AI settings read and change as catalog values, on a copy, and refuse anything else', () => {
  const models = load('services/ai/AiModels');
  const base = models.defaultAiSettings();
  delete base.uiStyle;
  assert.equal(models.aiRemoteSettingValue(base, 'remoteAi.uiStyle'), 'claude', 'settings saved before the style read as Claude');
  assert.equal(models.aiRemoteSettingValue(base, 'remoteAi.showExecution'), 'true');
  assert.equal(models.aiRemoteSettingValue(base, 'remoteAi.reconnectOnForeground'), 'true');
  assert.equal(models.aiRemoteSettingValue(base, 'remoteAi.textSize'), null);
  const codex = models.aiRemoteSettingChanged(base, 'remoteAi.uiStyle', 'codex');
  assert.equal(codex.uiStyle, 'codex');
  assert.equal(base.uiStyle, undefined, 'the settings passed in stay as they were');
  assert.equal(models.aiRemoteSettingChanged(base, 'remoteAi.showExecution', 'false').showExecution, false);
  assert.equal(models.aiRemoteSettingChanged(base, 'remoteAi.reconnectOnForeground', 'false').reconnectOnForeground, false);
  for (const [id, value] of [['remoteAi.uiStyle', 'siri'], ['remoteAi.showExecution', '开启'], ['remoteAi.textSize', '20'],
    ['remoteAi.defaultBackend', 'dsh'], ['ai.style', 'xiaoyi']]) {
    assert.equal(models.aiRemoteSettingChanged(base, id, value), null, id + '=' + value);
  }
  assert.deepEqual(Array.from(models.AI_REMOTE_SETTING_IDS),
    ['remoteAi.uiStyle', 'remoteAi.showExecution', 'remoteAi.reconnectOnForeground']);
});

test('a 远程 AI settings save writes only what that writer changed, over what is stored', () => {
  const models = load('services/ai/AiModels');
  const before = models.defaultAiSettings();
  const after = Object.assign(models.defaultAiSettings(), { textSize: 18 });
  // Meanwhile the AI 助理 changed the style.
  const stored = Object.assign(models.defaultAiSettings(), { uiStyle: 'codex' });
  const merged = models.aiSettingsMerged(stored, before, after);
  assert.equal(merged.textSize, 18, 'this writer\'s change');
  assert.equal(merged.uiStyle, 'codex', 'the other writer\'s change stays');
  assert.equal(stored.textSize, 15, 'nothing passed in is changed');
  const legacy = models.defaultAiSettings(); delete legacy.uiStyle;
  assert.equal(models.aiSettingsMerged(stored, legacy, models.defaultAiSettings()).uiStyle, 'codex',
    'an absent style reads as Claude: no change');
  for (const field of ['showExecution', 'reconnectOnForeground']) {
    const flip = Object.assign(models.defaultAiSettings(), { [field]: false });
    assert.equal(models.aiSettingsMerged(stored, before, flip)[field], false, field);
  }
  assert.equal(models.aiSettingsMerged(stored, before, Object.assign(models.defaultAiSettings(), { defaultBackend: 'dsh' }))
    .defaultBackend, 'dsh');
});

test('the AI settings catalog has the 远程 AI settings, and plain words pick them without stealing AI 风格', () => {
  const settings = load(D + 'DiagnosticAiSettingsActionPolicy');
  const models = load('services/ai/AiModels');
  for (const id of models.AI_REMOTE_SETTING_IDS) { assert.ok(settings.diagnosticAiSettingSpec(id), id + ' in the catalog'); }
  assert.deepEqual(Array.from(settings.diagnosticAiSettingSpec('remoteAi.uiStyle').choices, (c) => c.value), ['claude', 'codex']);
  const pick = (question) => Array.from(settings.diagnosticAiSettingIntents(question), (p) => p.settingId + '=' + p.proposedValue);
  assert.deepEqual(pick('把远程 AI 换成 Codex 风格'), ['remoteAi.uiStyle=codex']);
  assert.deepEqual(pick('远程AI界面改回Claude风格'), ['remoteAi.uiStyle=claude']);
  assert.deepEqual(pick('关闭工具执行过程'), ['remoteAi.showExecution=false']);
  assert.deepEqual(pick('关闭联网搜索工具调用'), [], 'the AI 助理\'s own tools are not 远程 AI\'s');
  // 从 A 换成 B means B.
  assert.deepEqual(pick('把远程 AI 从 Claude 风格换成 Codex 风格'), ['remoteAi.uiStyle=codex']);
  assert.deepEqual(pick('从 Siri 风格换成小艺风格'), ['ai.style=xiaoyi']);
  assert.deepEqual(pick('把 RustDesk 编码改成 H265，画质优先'), ['rustdesk.codec=5', 'rustdesk.imageQuality=2']);
  // 不要打开 / 不显示 turn off; 显示 turns on.
  assert.deepEqual(pick('不要打开 RDP 音频'), ['rdp.audioEnabled=false']);
  assert.deepEqual(pick('不显示远程 AI 执行过程'), ['remoteAi.showExecution=false']);
  assert.deepEqual(pick('显示 RDP 诊断信息'), ['rdp.showDiagnostics=true']);
  // A clause that names a setting is about it alone: another setting's value label in it does not count.
  assert.deepEqual(pick('悬浮球用小艺光环球'), ['ai.motion.orb=xiaoyiRing']);
  assert.deepEqual(pick('完成动画不显示'), ['ai.motion.done=none']);
  assert.deepEqual(pick('H264'), ['rustdesk.codec=4'], 'a value alone still finds its setting');
  assert.deepEqual(pick('打开回到前台后恢复查看'), ['remoteAi.reconnectOnForeground=true']);
  assert.deepEqual(pick('切到小艺风格'), ['ai.style=xiaoyi'], 'AI 风格 stays its own setting');
  // The host page reports the account's values; the catalog shows them.
  settings.DiagnosticAiSettingsBridge.register((id, value) => id === 'remoteAi.uiStyle' && value === 'codex',
    (id) => (id === 'remoteAi.uiStyle' ? 'claude' : null));
  assert.match(settings.diagnosticAiSettingCatalog(), /remoteAi\.uiStyle\|远程 AI 界面风格\|claude=Claude 风格\/codex=Codex 风格\|当前=claude/);
  assert.equal(settings.diagnosticAiApplySetting('remoteAi.uiStyle', 'codex'), true);
  assert.equal(settings.diagnosticAiApplySetting('remoteAi.uiStyle', 'claude'), false, 'already at that value');
  assert.equal(settings.diagnosticAiApplySetting('remoteAi.uiStyle', 'dark'), false, 'not one of its values');
});

// ---------------------------------------------------------------- AiHostService keeps them per account
function hostService() {
  const state = { owner: 'owner-' + 'a'.repeat(64), visible: true, saved: [], stored: null, failSave: false, reads: 0 };
  const AiAccess = { getInstance: () => ({
    proVisible: () => state.visible,
    capture: () => { if (state.owner === '') throw new Error('AI_ACCOUNT_UNAVAILABLE'); return { owner: state.owner, generation: 1, lifecycle: 1 }; },
    current: (lease) => lease.owner === state.owner
  }) };
  const AiLocalStore = { getInstance: () => ({
    initialize: async () => {},
    hosts: async () => [],
    settings: async () => { state.reads++; return JSON.parse(JSON.stringify(state.stored)); },
    // Read, change and write in one step, as the real store's queue does.
    updateSettings: (lease, change) => {
      if (state.failSave) return Promise.reject(new Error('AI_SETTINGS_INVALID'));
      const next = change(JSON.parse(JSON.stringify(state.stored)));
      if (next === null) return Promise.resolve(JSON.parse(JSON.stringify(state.stored)));
      state.saved.push({ owner: lease.owner, uiStyle: next.uiStyle, showExecution: next.showExecution, textSize: next.textSize });
      state.stored = JSON.parse(JSON.stringify(next));
      return Promise.resolve(JSON.parse(JSON.stringify(next)));
    }
  }) };
  const models = load('services/ai/AiModels');
  state.stored = models.defaultAiSettings();
  const module = load('services/ai/AiHostService', { './AiAccess': { AiAccess }, './AiLocalStore': { AiLocalStore },
    '../../model/RemoteHost': { RemoteHost: class {} } });
  return { state, service: new (module.AiHostService.getInstance().constructor)() };
}

test('AiHostService reads 远程 AI settings with the hosts and saves the AI\'s change for the current account', async () => {
  const { state, service } = hostService();
  assert.equal(service.remoteSetting('remoteAi.uiStyle'), null, 'unknown until read');
  assert.equal(service.applyRemoteSetting('remoteAi.uiStyle', 'codex'), false, 'nothing to change before it was read');
  await service.refresh({});
  assert.equal(service.remoteSetting('remoteAi.uiStyle'), 'claude');
  assert.equal(service.applyRemoteSetting('remoteAi.uiStyle', 'codex'), true);
  assert.equal(service.remoteSetting('remoteAi.uiStyle'), 'codex', 'the new value shows at once');
  await settle();
  assert.deepEqual(state.saved, [{ owner: state.owner, uiStyle: 'codex', showExecution: true, textSize: 15 }]);
  // 设置 → 远程 AI saved another field since it was read: the AI's change keeps it.
  state.stored.textSize = 20;
  assert.equal(service.applyRemoteSetting('remoteAi.showExecution', 'false'), true);
  await settle();
  assert.deepEqual(state.saved[1], { owner: state.owner, uiStyle: 'codex', showExecution: false, textSize: 20 });
  assert.equal(service.remoteSetting('remoteAi.showExecution'), 'false', 'what the store kept');
  assert.equal(service.applyRemoteSetting('remoteAi.uiStyle', 'siri'), false);
  // Another account sees nothing of this one's settings.
  const first = state.owner;
  state.owner = 'owner-' + 'b'.repeat(64);
  assert.equal(service.remoteSetting('remoteAi.uiStyle'), null);
  assert.equal(service.applyRemoteSetting('remoteAi.showExecution', 'false'), false);
  state.owner = first;
  // Without 远程 AI access, nothing is read or changed.
  state.visible = false;
  assert.equal(service.remoteSetting('remoteAi.uiStyle'), null);
  state.visible = true;
  // A save that fails reads back what is stored, and says so.
  state.failSave = true;
  const reads = state.reads;
  let failed = 0;
  assert.equal(service.applyRemoteSetting('remoteAi.showExecution', 'true', () => { failed++; }), true);
  assert.equal(service.remoteSetting('remoteAi.showExecution'), 'true', 'shown at once');
  await settle();
  assert.equal(failed, 1);
  assert.equal(state.reads, reads + 1);
  assert.equal(service.remoteSetting('remoteAi.showExecution'), 'false', 'the stored value again');
  service.clear();
  assert.equal(service.remoteSetting('remoteAi.uiStyle'), null);
});

test('设置 → 远程 AI follows what the store holds and saves only the fields it changed', () => {
  const store = read('services/ai/AiLocalStore.ets');
  const update = store.slice(store.indexOf('updateSettings(lease: AiAccountLease'), store.indexOf('saveSettings(lease: AiAccountLease'));
  // One queue step: read, change, check, write, tell the subscribers.
  assert.match(update, /return this\.serialize\(lease, async/);
  const steps = ["SELECT data FROM ai_settings WHERE owner=?", 'change(', 'aiSettingsValid(next)',
    'INSERT OR REPLACE INTO ai_settings', 'this.publish();'];
  let at = -1;
  for (const step of steps) { const next = update.indexOf(step, at + 1); assert.ok(next > at, 'updateSettings: ' + step); at = next; }
  const page = read('pages/AiSettingsPage.ets');
  assert.match(page, /this\.stopStore = AiLocalStore\.getInstance\(\)\.subscribe\(\(\): void => \{ if \(this\.initialized\) \{ this\.scheduleReload\(\); \} \}\);/);
  assert.match(page, /aboutToDisappear\(\): void \{[^}]*this\.stopStore\(\);/);
  const save = page.slice(page.indexOf('  private save(): void {'), page.indexOf('  private openEditor('));
  assert.match(save, /updateSettings\(account,\s*\(stored: AiSettings\): AiSettings \| null => aiSettingsMerged\(stored, previous, next\)\)/);
  assert.doesNotMatch(save, /saveSettings\(/, 'no whole-snapshot write');
  assert.match(save, /this\.savedSettings = saved;[\s\S]*this\.settings = JSON\.parse\(JSON\.stringify\(saved\)\) as AiSettings;/);
  // The AI's change says so when it is not saved.
  assert.match(read('pages/HostListPage.ets'),
    /applyRemoteSetting\(id, value, \(\): void => \{\s*promptAction\.showToast\(\{ message: '远程 AI 设置没有保存，请重试'/);
});

// ---------------------------------------------------------------- app actions
test('手机通行密钥 and 安全密钥重定向 are app actions; 远程 AI words reach its pages', () => {
  const actions = load(D + 'DiagnosticAiAppActionPolicy');
  const ids = (step) => Array.from(actions.diagnosticAiAppActionsForSteps([step]), (a) => a.id);
  assert.deepEqual(ids('打开手机通行密钥'), ['pro.phonePasskey']);
  assert.deepEqual(ids('在 Pro 功能里打开安全密钥重定向'), ['pro.securityKey']);
  // Other keys are not SSH keys; SSH keys still are.
  assert.deepEqual(ids('在 AI 配置里重新保存 API Key'), ['ai.config']);
  assert.deepEqual(ids('打开 SSH 密钥库导入私钥'), ['ssh.keys', 'settings.keyVault']);
  // A VNC or Moonlight page needs its protocol and its subject, not either one.
  assert.deepEqual(ids('确认电脑上的 VNC 服务已经启动'), []);
  assert.deepEqual(ids('打开 VNC 安全设置，关闭 TLS'), ['settings.vncSecurity']);
  assert.deepEqual(ids('检查网络是否稳定'), []);
  assert.deepEqual(ids('在 Moonlight 网络设置里换个端口'), ['settings.moonlightNetwork']);
  assert.deepEqual(ids('在设置 → 远程 AI → 界面风格里选 Codex 风格'), ['settings.aiDisplay']);
  // (AI hosts are also added from the list's own 添加主机.)
  assert.deepEqual(ids('在远程 AI 里添加 Claude Agent 主机'), ['host.add', 'settings.aiHosts']);
  assert.deepEqual(ids('在电脑端安装远程 AI 插件'), ['settings.aiInstall']);
  assert.deepEqual(ids('在电脑上安装 Claude Agent 插件'), ['settings.aiInstall']);
  // 远程 AI on its own, or its pairing, is its host page.
  assert.deepEqual(ids('打开 设置 → 远程 AI'), ['settings.aiHosts']);
  assert.deepEqual(ids('打开设置 → 远程 AI → 连接与配对'), ['settings.aiHosts']);
  assert.deepEqual(ids('在设置 → 远程 AI 添加主机并扫码配对'), ['host.add', 'settings.aiHosts']);
  assert.deepEqual(ids('在设置 → 远程 AI 里导出 AI 配置'), ['settings.aiData']);
  // Installing other remote-desktop servers on the computer is not 远程 AI's install page.
  for (const step of ['在电脑上安装 RustDesk', '在电脑上安装 VNC 服务端，例如 TightVNC', 'Moonlight 需要电脑上安装 Sunshine',
    '在电脑上安装 OpenSSH Server', '在电脑上安装最新的显卡驱动', '在 Codex 中安装依赖', '用 DSH 安装依赖包']) {
    assert.ok(!ids(step).includes('settings.aiInstall'), step);
  }
  // Pairing is the host page's, whatever else the step mentions; 显示 alone is a verb, not the display page.
  assert.deepEqual(ids('打开设置 → 远程 AI → 连接与配对，粘贴插件显示的邀请'), ['settings.aiHosts']);
  assert.deepEqual(ids('确认电脑上的插件正在运行，再在远程 AI 里重新配对'), ['settings.aiHosts']);
  assert.deepEqual(ids('如果远程 AI 显示“未配对”，重新配对'), ['settings.aiHosts']);
  assert.deepEqual(ids('远程 AI 显示连接失败时，检查电脑防火墙'), ['settings.aiHosts']);
  assert.deepEqual(ids('在设置 → 远程 AI → 显示与恢复里关闭工具执行过程'), ['settings.aiDisplay']);
  // A security key is not an SSH key; a 远程 AI session is not the AI 助理's own conversations.
  assert.deepEqual(ids('使用 YubiKey 登录'), ['pro.securityKey']);
  assert.deepEqual(ids('在远程 AI 会话里批准文件改动'), ['settings.aiHosts']);
  // A subject alone (键盘, 终端, SSH, RDP) opens its own page, not every page about it.
  // (session.* actions are a session's own toolbar, offered only there.)
  const pages = (step) => ids(step).filter((id) => !id.startsWith('session.'));
  assert.deepEqual(pages('打开虚拟键盘'), ['settings.keyboard']);
  assert.deepEqual(pages('在键盘快捷键里加一个组合键'), ['settings.keyboard', 'settings.keyboardShortcuts']);
  assert.deepEqual(pages('确认 SSH 终端已经连上'), []);
  assert.deepEqual(pages('把 RDP 分辨率调低'), ['settings.rdpDisplay']);
  assert.equal(actions.diagnosticAiAppActionId('pro.phonePasskey'), 'pro.phonePasskey');
  assert.equal(actions.diagnosticAiAppActionTarget('pro.securityKey'), '安全密钥重定向');
  assert.match(actions.diagnosticAiAppActionCatalog(), /^pro\.phonePasskey\|打开手机通行密钥\|execute\|direct$/m);
  // The host list opens both in Pro 功能's detail sheet.
  const host = read('pages/HostListPage.ets');
  assert.match(host, /case 'pro\.phonePasskey':\s*this\.selectedProFeatureId = 'pro\.security\.phonePasskey'; this\.openSettingsLeafSheet\(SETTINGS_SHEET_PRO_FEATURE\)/);
  assert.match(host, /case 'pro\.securityKey':\s*this\.selectedProFeatureId = 'pro\.security\.webauthnRedirect'; this\.openSettingsLeafSheet\(SETTINGS_SHEET_PRO_FEATURE\)/);
});

// ---------------------------------------------------------------- what the AI knows
test('the knowledge base describes 远程 AI, its style, both keys and the session AI, with ids that exist', () => {
  const kb = load(D + 'DiagnosticAiKnowledgeBase');
  const settings = load(D + 'DiagnosticAiSettingsActionPolicy');
  const actions = load(D + 'DiagnosticAiAppActionPolicy');
  assert.match(kb.DIAGNOSTIC_AI_KNOWLEDGE_VERSION, /2026-10-05-v8$/);
  const guide = kb.aiAppGuide();
  for (const words of ['Claude Agent', 'Anthropic API Key', 'DSH', 'Codex 风格', '手机通行密钥', '安全密钥重定向',
    '退出主机回到主机列表后', '连接断开或重连时 AI 不会关闭', '当前登录账号的 AI 配置']) {
    assert.ok(guide.includes(words), 'the guide mentions ' + words);
  }
  // 手机通行密钥 as the prototype is: its own test page (and RDP on a HarmonyOS PC), not every website.
  assert.ok(guide.includes('「测试注册」「测试登录」'));
  assert.ok(!guide.includes('另一台设备注册或登录网站时'));
  for (const id of guide.match(/remoteAi\.[A-Za-z]+/g)) { assert.ok(settings.diagnosticAiSettingSpec(id), id + ' is a setting'); }
  for (const id of guide.match(/pro\.(phonePasskey|securityKey)/g)) { assert.ok(actions.diagnosticAiAppActionId(id), id + ' is an action'); }
  const snapshot = kb.diagnosticAiKnowledgeSnapshot();
  assert.ok(snapshot.includes('pro.phonePasskey|打开手机通行密钥'), 'the 助理 catalog lists the new actions');
  assert.ok(snapshot.includes('remoteAi.uiStyle|远程 AI 界面风格'), 'the 助理 catalog lists the new settings');
});

// ---------------------------------------------------------------- the session's AI (source contracts)
test('the session AI uses the signed-in account, survives a dropped connection and hands over when the page goes', () => {
  const chat = read('components/diagnosticAi/AiChatView.ets');
  assert.match(chat, /export function aiChatOwner\(\): string \{[\s\S]*?ownerScopeId\.trim\(\) === '' \? 'device-local' : scope\.ownerScopeId;/);
  // No surface falls back to 'device-local' because no panel opened before it.
  for (const file of ['components/diagnosticAi/AiLiftLayer.ets', 'components/diagnosticAi/SessionAiHost.ets']) {
    assert.doesNotMatch(read(file), /AiChatMemory\.owner !== '' \? AiChatMemory\.owner : 'device-local'/, file);
  }
  const lift = read('components/diagnosticAi/AiLiftLayer.ets');
  assert.match(lift, /AiChatView\(\{ mini: true, owner: aiChatOwner\(\),/);
  assert.match(lift, /const owner: string = aiChatOwner\(\);\s*void AiVoiceInput\.start/);

  const host = read('components/diagnosticAi/SessionAiHost.ets');
  assert.match(host, /private openOrb\(\): void \{[\s\S]*?const owner: string = aiChatOwner\(\);\s*if \(AiChatMemory\.owner !== owner\) \{ AiChatMemory\.clear\(owner\); \}[\s\S]*?this\.island\.openIsland/);
  assert.match(host, /p\.owner = aiChatOwner\(\);/);
  const leaving = host.slice(host.indexOf('aboutToDisappear(): void {'), host.indexOf('private active()'));
  assert.match(leaving, /const handover: boolean = this\.island\.isOpen\(\) \|\| this\.voice\.isOpen\(\) \|\| this\.reopenTimer >= 0;/);
  assert.ok(leaving.indexOf('AiSessionRouter.release(this.hostId)') < leaving.indexOf('AppStorage.setOrCreate(AI_SESSION_HANDOVER'),
    'released before the host list is asked (it skips while a session answers)');
  assert.match(leaving, /if \(handover\) \{[\s\S]*?AppStorage\.setOrCreate\(AI_SESSION_HANDOVER, Date\.now\(\)\);/);

  // Mounted for the whole page, not only while connected; toolbar actions wait for the connection.
  const rdp = read('pages/RemoteDesktop.ets');
  assert.doesNotMatch(rdp, /this\.connected && this\.sessionAiVisible\(\)/);
  assert.match(rdp, /if \(this\.sessionAiVisible\(\)\) \{\s*SessionAiHost\(\{/);
  assert.match(rdp, /private runSessionAiAction\(action: DiagnosticAiAppActionId\): boolean \{\s*(\/\/[^\n]*\n\s*)+if \(!this\.connected && action\.startsWith\('session\.'\) && action !== 'session\.disconnect'\) \{[\s\S]*?return true;/,
    'session actions wait for the connection; leaving (which also stops a reconnect) does not');
  for (const page of ['pages/MoonlightStreamPage.ets', 'pages/SshTerminal.ets']) {
    assert.match(read(page), /if \(this\.(sessionAiVisible|sshAiVisible)\(\)\) \{\s*SessionAiHost\(\{/, page);
  }
});

test('the host list carries the session AI on as the orb with its chat, only once it is back in front', () => {
  const keys = load(D + 'AiBridgeKeys');
  assert.equal(keys.AI_SESSION_HANDOVER, 'aiSession.handover');
  assert.ok(keys.AI_SESSION_HANDOVER_TTL_MS >= 5000 && keys.AI_SESSION_HANDOVER_TTL_MS <= 60000);
  const host = read('pages/HostListPage.ets');
  assert.match(host, /@StorageProp\(AI_SESSION_HANDOVER\) @Watch\('onSessionAiHandover'\) aiSessionHandover: number = 0;/);
  assert.match(host, /onPageShow\(\): void \{[\s\S]{0,200}this\.takeSessionAi\(\);/);
  const take = host.slice(host.indexOf('private takeSessionAi(): void {'), host.indexOf('private onAiVoiceRequest(): void {'));
  const order = ['AI_SESSION_HANDOVER_TTL_MS', "if (!this.pageShown || top !== 'HostListPage') { return; }",
    'AppStorage.setOrCreate(AI_SESSION_HANDOVER, 0);',
    'AiSessionRouter.sessionActive()', 'this.aiIslandStartFloat = true;', 'this.aiIslandStartChat = true;', 'this.aiIslandShown = true;'];
  let at = -1;
  for (const step of order) {
    const next = take.indexOf(step, at + 1);
    assert.ok(next > at, 'takeSessionAi: ' + step + ' in order');
    at = next;
  }
  // Only the list that is showing takes it (not one under a page pushed over it, or a second one after replaceUrl).
  assert.match(host, /private pageShown: boolean = false;/);
  assert.match(host, /onPageShow\(\): void \{\s*this\.pageActive = true;\s*this\.pageShown = true;/);
  assert.match(host, /onPageHide\(\): void \{\s*this\.pageShown = false;/);
  assert.match(host, /p\.startChat = this\.aiIslandStartChat;/);
  // Every way the list's AI goes resets the flag.
  assert.equal((host.match(/this\.aiIslandStartChat = false;/g) || []).length, 3);
  const island = read('components/diagnosticAi/AiIsland.ets');
  assert.match(island, /@Prop startChat: boolean = false;/);
  assert.match(island, /this\.liftUp\('', 'none', AiChatMemory\.active \? 'chat' : 'assistant', 'chat', this\.startChat && AiChatMemory\.active,/);
  assert.match(read('components/diagnosticAi/AiTopLayer.ets'), /startChat: p\.startChat/);
});

(async () => {
  let failed = 0;
  for (const { name, body } of tests) {
    try { await body(); console.log('PASS', name); }
    catch (error) { failed++; console.error('FAIL', name); console.error(error); }
  }
  if (failed > 0) process.exit(1);
})();
