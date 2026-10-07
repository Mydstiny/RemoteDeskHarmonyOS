'use strict';

/*
 * The AI in a remote session and what the AI knows about the newest features:
 * - the session's orb works for the signed-in account (its AI 配置), survives a dropped connection, and the host list
 *   carries it on when the user leaves the host (source contracts: these are ArkUI components);
 * - 远程 AI 设置 (界面风格, 显示工具执行过程, 回到前台后恢复查看) are in the AI's settings catalog, read and saved per
 *   account through AiHostService;
 * - 手机通行密钥 and 安全密钥重定向 are app actions; the knowledge base describes 远程 AI, Pi and both keys
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
    isNaN, console, TouchType: { Down: 0, Up: 1, Move: 2, Cancel: 3 } });
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
  assert.equal(models.aiRemoteSettingValue(base, 'remoteAi.textSize'), '15');
  assert.equal(models.aiRemoteSettingValue(base, 'remoteAi.defaultBackend'), 'codex');
  assert.equal(models.aiRemoteSettingValue(base, 'remoteAi.colorScheme'), null);
  const codex = models.aiRemoteSettingChanged(base, 'remoteAi.uiStyle', 'codex');
  assert.equal(codex.uiStyle, 'codex');
  assert.equal(base.uiStyle, undefined, 'the settings passed in stay as they were');
  assert.equal(models.aiRemoteSettingChanged(base, 'remoteAi.showExecution', 'false').showExecution, false);
  assert.equal(models.aiRemoteSettingChanged(base, 'remoteAi.reconnectOnForeground', 'false').reconnectOnForeground, false);
  assert.equal(models.aiRemoteSettingChanged(base, 'remoteAi.defaultBackend', 'pi').defaultBackend, 'pi');
  assert.equal(models.aiRemoteSettingChanged(base, 'remoteAi.textSize', '20').textSize, 20);
  for (const [id, value] of [['remoteAi.uiStyle', 'siri'], ['remoteAi.showExecution', '开启'], ['remoteAi.textSize', '30'],
    ['remoteAi.textSize', '1e1'], ['remoteAi.defaultBackend', 'claudecode'], ['ai.style', 'xiaoyi']]) {
    assert.equal(models.aiRemoteSettingChanged(base, id, value), null, id + '=' + value);
  }
  assert.deepEqual(Array.from(models.AI_REMOTE_SETTING_IDS),
    ['remoteAi.uiStyle', 'remoteAi.showExecution', 'remoteAi.reconnectOnForeground', 'remoteAi.defaultBackend',
      'remoteAi.textSize']);
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
  // 默认电脑端 AI and 文字大小 only with the setting named: Pi is inside API, Codex in 安装 Codex, a number anywhere.
  assert.deepEqual(pick('远程 AI 默认 AI 改成 Pi'), ['remoteAi.defaultBackend=pi']);
  assert.deepEqual(pick('把默认电脑端 AI 换成 DSH'), ['remoteAi.defaultBackend=dsh']);
  assert.deepEqual(pick('远程 AI 默认用 Codex'), ['remoteAi.defaultBackend=codex']);
  assert.deepEqual(pick('远程 AI 的文字大小调到 18'), ['remoteAi.textSize=18']);
  assert.deepEqual(pick('把会话文字大小改成 20'), ['remoteAi.textSize=20']);
  for (const other of ['帮我把 API Key 改一下', '远程 AI 添加 Pi 主机', '在电脑上安装 Codex', '把端口改成 20', 'SSH 字号调到 16']) {
    assert.deepEqual(pick(other), [], other);
  }
  assert.deepEqual(Array.from(settings.diagnosticAiSettingSpec('remoteAi.defaultBackend').choices, (c) => c.value), ['codex', 'dsh', 'pi']);
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
  // Each named toggle takes its own verb: an attributive 关掉的 is no verb, a trailing 再打开 wins, 要不要 asks for on.
  const cases = [
    ['把关掉的 RDP 音频重新打开', ['rdp.audioEnabled=true']],
    ['先关闭再打开 RDP 剪贴板', ['rdp.clipboardEnabled=true']],
    ['关闭 RDP 音频后再打开', ['rdp.audioEnabled=true']],
    ['把禁用的 RDP 驱动器映射重新启用', ['rdp.driveEnabled=true']],
    ['打开之前关闭的 RustDesk 剪贴板', ['rustdesk.clipboardEnabled=true']],
    ['RDP 音频要不要打开', ['rdp.audioEnabled=true']],
    ['要不要开启 RustDesk 隐私模式', ['rustdesk.privacyMode=true']],
    ['别打开 RDP 音频', ['rdp.audioEnabled=false']],
    ['不用打开 RDP 剪贴板', ['rdp.clipboardEnabled=false']],
    ['RDP 音频不需要打开', ['rdp.audioEnabled=false']],
    ['先关掉 RustDesk 隐私模式再开启音频', ['rustdesk.audioEnabled=true', 'rustdesk.privacyMode=false']],
    ['把 RDP 音频关了再打开剪贴板', ['rdp.audioEnabled=false', 'rdp.clipboardEnabled=true']],
    ['打开 RDP 剪贴板不要音频', ['rdp.audioEnabled=false', 'rdp.clipboardEnabled=true']],
    // Lists: a name alone waits for the next clause's verb; protocols named alone go on to it.
    ['RDP 音频和剪贴板都关了', ['rdp.audioEnabled=false', 'rdp.clipboardEnabled=false']],
    ['RDP 和 RustDesk 都关掉音频', ['rdp.audioEnabled=false', 'rustdesk.audioEnabled=false']],
    ['RDP 剪贴板不能用了，先关闭再打开试试', []],
    // 显示 / 不显示 / 隐藏 only for the 显示… toggles, before what they show, never in a question.
    ['别显示 RustDesk 诊断信息', ['rustdesk.showDiagnostics=false']],
    ['RustDesk 显示本地光标', ['rustdesk.showLocalCursor=true']],
    ['隐藏 RustDesk 本地光标', ['rustdesk.showLocalCursor=false']],
    ['把诊断信息显示出来', ['rdp.showDiagnostics=true', 'rustdesk.showDiagnostics=true']],
    ['远程 AI 里不显示执行过程', ['remoteAi.showExecution=false']],
    ['RDP 的诊断信息怎么不显示', []],
    ['为什么 RustDesk 本地光标不显示', []],
    ['RustDesk 本地光标显示异常', []],
    ['诊断信息显示不出来', []],
    ['显示主机卡片敏感信息', []],
    ['如何显示剪贴板历史', []],
    ['为什么微信语音不显示', []],
    ['关闭 RDP 音频，显示比例改成填满，剪贴板也一样',
      ['rdp.audioEnabled=false', 'remote.displayScaleMode=fill', 'rdp.clipboardEnabled=false']],
    // A value of a setting the clause does not name stays, unless a named one's words or values hold it.
    ['RustDesk 用 H265 关掉声音', ['rustdesk.codec=5', 'rustdesk.audioEnabled=false']],
    ['RustDesk 编码设为 H264 速度优先', ['rustdesk.imageQuality=0', 'rustdesk.codec=4']],
    ['切到深色并打开沉浸光感', ['ui.theme=dark', 'ui.ambientLightEffect=true']],
    ['局域网里 RustDesk 改成 H265', ['rustdesk.codec=5']],
    ['思考动画换成小艺光环', ['ai.motion.thinking=xiaoyi']]
  ];
  cases.push(
    // 关闭 / 取消 / 不再 / 别再 / 不想 / 停止 before a 显示… switch turn it off; 不要显示 / 别显示 may follow it.
    ['关闭 RustDesk 显示本地光标', ['rustdesk.showLocalCursor=false']],
    ['取消显示RDP诊断信息', ['rdp.showDiagnostics=false']],
    ['关闭远程 AI 显示工具执行过程', ['remoteAi.showExecution=false']],
    ['以后不再显示RDP诊断信息', ['rdp.showDiagnostics=false']],
    ['别再显示本地光标了', ['rustdesk.showLocalCursor=false']],
    ['RustDesk 诊断信息不要显示', ['rustdesk.showDiagnostics=false']],
    ['RDP 诊断信息别显示了', ['rdp.showDiagnostics=false']],
    ['显示 RustDesk 本地光标和诊断信息', ['rustdesk.showDiagnostics=true', 'rustdesk.showLocalCursor=true']],
    ['隐藏 RDP 和 RustDesk 的诊断信息', ['rdp.showDiagnostics=false', 'rustdesk.showDiagnostics=false']],
    ['把 RDP 诊断信息隐藏', ['rdp.showDiagnostics=false']],
    // A protocol said in passing is not carried into the next clause.
    ['RDP 连不上，RustDesk 音频打开', ['rustdesk.audioEnabled=true']],
    ['我平时用 RDP，RustDesk 的剪贴板帮我关了', ['rustdesk.clipboardEnabled=false']],
    // A verb goes to the setting right next to it; one with its own object (取消静音) is not the setting's.
    ['光感打开分组关掉', ['ui.ambientLightEffect=true', 'ui.groupedHostCards=false']],
    ['rdp音频打开rustdesk音频关闭', ['rdp.audioEnabled=true', 'rustdesk.audioEnabled=false']],
    ['远程 AI 回到前台恢复查看打开 工具执行过程关掉',
      ['remoteAi.reconnectOnForeground=true', 'remoteAi.showExecution=false']],
    ['开启RustDesk隐私模式不要让别人看到屏幕', ['rustdesk.privacyMode=true']],
    ['打开RDP音频取消静音', ['rdp.audioEnabled=true']],
    ['远程AI工具调用关掉', ['remoteAi.showExecution=false']],
    // Keeping something on, leaving it off, and switches stored the other way round.
    ['不要关闭 RDP 剪贴板', ['rdp.clipboardEnabled=true']],
    ['RDP 音频不要关', ['rdp.audioEnabled=true']],
    ['RDP 音频不用开', ['rdp.audioEnabled=false']],
    ['不得不打开 RDP 剪贴板', ['rdp.clipboardEnabled=true']],
    ['关闭会话快速退出', ['remote.quickExitDisabled=true']],
    ['语气温和一点', ['ai.personality=warm']],
    ['AI 回答简短一点', ['ai.verbosity=concise']],
    // Connectors after a setting's own verb (再把, 但是); 关闭后再打开 ends on.
    ['帮我把RDP声音打开再把剪贴板关掉', ['rdp.audioEnabled=true', 'rdp.clipboardEnabled=false']],
    ['RDP音频开启但是剪贴板关闭', ['rdp.audioEnabled=true', 'rdp.clipboardEnabled=false']],
    ['把RDP音频关闭后再打开', ['rdp.audioEnabled=true']],
    // A list head takes the next switch's verb; after 和 a switch with no verb of its own follows the clause before.
    ['RDP的音频和剪贴板打开驱动器映射关掉', ['rdp.audioEnabled=true', 'rdp.clipboardEnabled=true', 'rdp.driveEnabled=false']],
    ['RDP音频剪贴板打开驱动器映射关闭', ['rdp.audioEnabled=true', 'rdp.clipboardEnabled=true', 'rdp.driveEnabled=false']],
    ['打开RDP音频和剪贴板关闭驱动器映射', ['rdp.audioEnabled=true', 'rdp.clipboardEnabled=true', 'rdp.driveEnabled=false']],
    // Negations across 让 / 再 / 把, refusals, negated off words, keeping things on.
    ['不要让RDP显示诊断信息', ['rdp.showDiagnostics=false']],
    ['不要再显示RustDesk本地光标', ['rustdesk.showLocalCursor=false']],
    ['别让RustDesk显示本地光标', ['rustdesk.showLocalCursor=false']],
    ['别隐藏RDP诊断信息', ['rdp.showDiagnostics=true']],
    ['取消隐藏远程AI工具执行过程', ['remoteAi.showExecution=true']],
    ['不要再打开RDP音频', ['rdp.audioEnabled=false']],
    ['不准打开RDP音频', ['rdp.audioEnabled=false']],
    ['不要让RDP音频打开', ['rdp.audioEnabled=false']],
    ['别把RDP音频打开', ['rdp.audioEnabled=false']],
    ['别让RDP音频开着', ['rdp.audioEnabled=false']],
    ['不要再关掉RDP音频', ['rdp.audioEnabled=true']],
    ['RDP音频别再关了', ['rdp.audioEnabled=true']],
    ['让RDP音频一直开着', ['rdp.audioEnabled=true']],
    ['保持RustDesk局域网发现关闭', ['rustdesk.lanDiscovery=false']],
    ['RDP声音开一下剪贴板关一下', ['rdp.audioEnabled=true', 'rdp.clipboardEnabled=false']],
    ['不需要RDP音频了', ['rdp.audioEnabled=false']],
    ['我不想要RustDesk的声音', ['rustdesk.audioEnabled=false']],
    // A refused value is not proposed; a two-valued setting gets the other one; a later change of mind wins.
    ['关掉深色模式', []],
    ['RustDesk 不要用H265', []],
    ['关闭小艺风格', ['ai.style=siri']],
    ['取消Claude风格', ['remoteAi.uiStyle=codex']],
    ['不要速度优先，RustDesk改成画质优先', ['rustdesk.imageQuality=2']],
    ['打开RDP音频，算了还是关掉吧', ['rdp.audioEnabled=false']],
    ['开启夜间模式', ['ui.theme=dark']],
    ['AI风格改成小艺，晕染关掉', ['ai.style=xiaoyi', 'ai.style.wash=off']],
    ['发送按钮光晕关掉', ['ai.motion.sendGlow=off']],
    ['小艺风格的思考动画换成彩丝声波', ['ai.motion.thinking=strands']],
    ['虚拟鼠标改成圆形的', ['ui.virtualMouseStyle=circle']],
    // Questions and problems are for the assistant to answer: no card.
    ['音频打开了吗', []],
    ['RustDesk隐私模式打开了没有', []],
    ['我打开了RDP音频但是没声音', []],
    ['RDP音频为什么自己打开了', []],
    ['关闭隐私模式后黑屏了', []],
    ['RDP音频关掉之后还是有声音', []],
    ['RustDesk 局域网发现开启失败', []],
    ['H265和H264哪个好', []],
    ['编码选H265还是H264好', []],
    ['深色模式好看吗', []],
    ['小艺风格是什么样子', []],
    ['RDP剪贴板关了以后就不能复制了', []],
    ['可以帮我打开RDP音频吗', ['rdp.audioEnabled=true']],
    // A question or a problem keeps its protocol for the next sentence; a request after a problem is still read.
    ['RDP为什么没声音，帮我打开音频', ['rdp.audioEnabled=true']],
    ['RustDesk画面卡住了，打开诊断信息', ['rustdesk.showDiagnostics=true']],
    ['RDP用着有点卡，RustDesk黑屏了，帮我关掉隐私模式', ['rustdesk.privacyMode=false']],
    ['RustDesk黑屏了帮我关掉隐私模式', ['rustdesk.privacyMode=false']],
    ['RDP卡住了把色深调到16位', ['rdp.colorDepth=16']],
    ['RDP画面卡住了色深改16位', ['rdp.colorDepth=16']],
    ['为什么RDP这么卡？先把色深调到16位', ['rdp.colorDepth=16']],
    ['H265和H264哪个好？先给我换成H265', ['rustdesk.codec=5']],
    ['RDP音频怎么关？帮我关掉吧', ['rdp.audioEnabled=false']],
    ['RDP色深改成16位会不会好点？帮我改一下', ['rdp.colorDepth=16']],
    ['RustDesk隐私模式是干嘛的？先帮我关掉', ['rustdesk.privacyMode=false']],
    ['RDP驱动器映射打开以后看不到文件夹', []],
    // Refusals after a value or of a change; leaving something as it is; 夜间模式 turned off is not dark.
    ['夜间模式关掉', []],
    ['我不想要夜间模式', []],
    ['AI风格不要小艺', []],
    ['深色模式关掉', []],
    ['H265不要了', []],
    ['小艺风格关掉', ['ai.style=siri']],
    ['不要换成深色模式', []],
    ['RustDesk编码先不要换成H265', []],
    ['不要改RDP音频', []],
    ['关掉RDP音频，剪贴板留着', ['rdp.audioEnabled=false']],
    ['RustDesk 用 H264 速度优先 关闭音频', ['rustdesk.audioEnabled=false', 'rustdesk.codec=4', 'rustdesk.imageQuality=0']],
    ['远程 AI 风格改成 Claude 风格 关闭工具执行过程', ['remoteAi.showExecution=false', 'remoteAi.uiStyle=claude']],
    // A previous verb carries only into a clause that is just names; 开 / 关 next to a setting are verbs.
    ['关闭RDP音频，开剪贴板', ['rdp.audioEnabled=false', 'rdp.clipboardEnabled=true']],
    ['先把RDP双指缩放关了，再把反向滚轮开了', ['remote.rdpPinchZoom=false', 'remote.rdpReverseWheel=true']],
    ['先关RDP音频再开剪贴板', ['rdp.audioEnabled=false', 'rdp.clipboardEnabled=true']],
    ['RustDesk 音频关 RDP 音频开', ['rdp.audioEnabled=true', 'rustdesk.audioEnabled=false']],
    ['别给我开RDP音频', ['rdp.audioEnabled=false']],
    ['这次先不开RDP驱动器映射', ['rdp.driveEnabled=false']],
    ['跟RDP音频相关的设置', []],
    // A change of mind in its own sentence; a protocol named after the change narrows it.
    ['打开RDP音频。不对，关掉。', ['rdp.audioEnabled=false']],
    ['把诊断信息显示出来，RDP 的', ['rdp.showDiagnostics=true']],
    // A problem described, then something unrelated: no card; only a plain request follows a question.
    ['剪贴板复制失败，不要紧', []],
    ['RDP声音就没了，不知道是不是被关了', []],
    ['声音没反应，不要重连', []],
    ['RDP 音频是什么？不想让同事看到', []],
    ['RDP 音频是什么？不想要了吗', []],
    ['RustDesk隐私模式，我没打开过', []],
    ['RDP驱动器映射，同事说要关掉', []],
    ['声音没反应，先在远程电脑上关掉防火墙，再把RDP剪贴板打开', ['rdp.clipboardEnabled=true']],
    ['RDP音频开着但是声音很小', []],
    ['RustDesk剪贴板开着但是复制不了', []],
    // Casual endings, polite endings and 的 at the end.
    ['RustDesk显示本地光标关掉啦', ['rustdesk.showLocalCursor=false']],
    ['远程AI显示工具执行过程关掉啦', ['remoteAi.showExecution=false']],
    ['RDP音频打开并且剪贴板也关掉啦', ['rdp.audioEnabled=true', 'rdp.clipboardEnabled=false']],
    ['关掉RDP音频好吗', ['rdp.audioEnabled=false']],
    ['把RDP色深改成16位行吗', ['rdp.colorDepth=16']],
    ['把外观改成深色的谢谢', ['ui.theme=dark']],
    ['把RDP色深改成16位的吧谢谢', ['rdp.colorDepth=16']],
    // Numbered lists.
    ['1.RustDesk隐私模式打开 2.RustDesk局域网发现关闭', ['rustdesk.lanDiscovery=false', 'rustdesk.privacyMode=true']],
    ['①RDP音频打开②RDP剪贴板关闭', ['rdp.audioEnabled=true', 'rdp.clipboardEnabled=false']],
    ['RDP 音频、剪贴板、驱动器映射全部关闭', ['rdp.audioEnabled=false', 'rdp.clipboardEnabled=false', 'rdp.driveEnabled=false']],
    ['RDP音频和剪贴板打开但是驱动器映射关闭', ['rdp.audioEnabled=true', 'rdp.clipboardEnabled=true', 'rdp.driveEnabled=false']],
    // An adverb between a negation and its verb; a lag described; how-to questions; 然后呢 mid-request.
    ['RDP声音不要一直开着', ['rdp.audioEnabled=false']],
    ['RDP剪贴板别老开着', ['rdp.clipboardEnabled=false']],
    ['RDP音频开了以后很卡，关了吧', []],
    ['怎么关RDP音频', []],
    ['关RDP音频有什么坏处', []],
    ['把RDP音频打开然后呢把剪贴板关掉', ['rdp.audioEnabled=true', 'rdp.clipboardEnabled=false']],
    // Bracketed markers; a value said with 、 is not a marker; a request's opening words keep a list.
    ['（1）别把RDP剪贴板关了 （2）打开RDP音频', ['rdp.audioEnabled=true', 'rdp.clipboardEnabled=true']],
    ['RDP色深改成16、音频关掉', ['rdp.audioEnabled=false', 'rdp.colorDepth=16']],
    ['帮我把RDP音频和剪贴板都打开', ['rdp.audioEnabled=true', 'rdp.clipboardEnabled=true']],
    // Follow-ups after a question.
    ['RDP音频是干嘛的？你帮我打开一下', ['rdp.audioEnabled=true']],
    ['RDP驱动器映射有用吗？没用的话关了', ['rdp.driveEnabled=false']],
    ['为什么RDP剪贴板用不了？帮我打开', ['rdp.clipboardEnabled=true']]);
  for (const [question, expected] of cases) {
    assert.deepEqual(pick(question).sort(), expected.slice().sort(), question);
  }
  // Two switches joined by a connector, each verb before or after its own.
  const joins = ['', '再', '再把', '但是', '顺便把', '把', '另外'];
  for (const join of joins) {
    for (const [first, second] of [[true, false], [false, true]]) {
      for (const [firstAfter, secondAfter] of [[true, true], [false, false], [true, false], [false, true]]) {
        const one = firstAfter ? '音频' + (first ? '打开' : '关掉') : (first ? '打开' : '关掉') + '音频';
        const two = secondAfter ? '剪贴板' + (second ? '开启' : '关闭') : (second ? '开启' : '关闭') + '剪贴板';
        const said = 'RDP' + one + join + two;
        assert.deepEqual(pick(said).sort(), ['rdp.audioEnabled=' + first, 'rdp.clipboardEnabled=' + second].sort(), said);
      }
    }
  }
  // Run-on speech: two or three RDP switches, each verb before or after its own.
  const parts = [['音频', 'rdp.audioEnabled'], ['剪贴板', 'rdp.clipboardEnabled'], ['驱动器映射', 'rdp.driveEnabled']];
  for (const count of [2, 3]) {
    for (let ways = 0; ways < (1 << count); ways++) {
      for (let after = 0; after < (1 << count); after++) {
        let said = 'RDP';
        const expected = [];
        for (let i = 0; i < count; i++) {
          const on = Boolean(ways >> i & 1);
          const verb = on ? ['打开', '开启'][i % 2] : ['关闭', '关掉'][i % 2];
          said += (after >> i & 1) ? parts[i][0] + verb : verb + parts[i][0];
          expected.push(parts[i][1] + '=' + on);
        }
        assert.deepEqual(pick(said).sort(), expected.sort(), said);
      }
    }
  }
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
test('手机通行密钥 lives in 安全与数据: one entry check for every way in, a sheet with steps and two roles', () => {
  const page = read('pages/HostListPage.ets'), catalog = read('services/SettingsSearchCatalog.ets');
  const entry = read('services/pro/passkey/ProPasskeyEntry.ets'), sheet = read('components/pro/passkey/PhonePasskeySettingsSheet.ets');
  assert.ok(entry.includes('if (!DEBUG) { return false; }') && entry.includes('.executable'), 'Debug builds with Pro only');
  const security = page.slice(page.indexOf('@Builder settingsSectionSecurity()'), page.indexOf('@Builder settingsSectionSecurity()') + 6000);
  assert.ok(security.includes('if (phonePasskeyEntryAvailable()) {\n            this.phonePasskeyRow()'));
  assert.ok(page.includes(".onClick((): void => { this.openSettingsLeafSheet(SETTINGS_SHEET_PHONE_PASSKEY); })"));
  assert.ok(page.includes("if (phonePasskeyEntryAvailable()) { this.openSettingsLeafSheet(SETTINGS_SHEET_PHONE_PASSKEY); return; }"),
    'the AI 助理\'s 打开手机通行密钥 goes to the new page');
  assert.ok(page.includes("onOpenPasskey: (): void => { this.openSettingsLeafSheet(SETTINGS_SHEET_PHONE_PASSKEY); }"), 'Pro 功能 leads there');
  assert.ok(page.includes("case 'phonePasskey': return phonePasskeyEntryAvailable();"));
  assert.ok(catalog.includes("entry(SETTINGS_SECTION_SECURITY, '手机通行密钥'") && !catalog.includes("entry(SETTINGS_SECTION_PRO, '手机通行密钥'"));
  assert.ok(sheet.includes("AppSheetHeader({ title: '手机通行密钥'") && sheet.includes('showProBadge: true'));
  assert.equal((sheet.match(/^  '[^']+',?$/gm) || []).length, 3, 'three short steps');
  assert.ok(sheet.includes("this.role = this.isDesktopDevice || this.isPadDevice ? 1 : 0;"), 'a phone opens as the key, a tablet or PC as its user');
  assert.ok(sheet.includes("ForEach(['作为密钥', '使用手机密钥']"));
  const kb = read('services/diagnosticAi/DiagnosticAiKnowledgeBase.ets');
  assert.ok(kb.includes('设置 → 安全与数据 → 手机通行密钥') && !kb.includes('设置 → Pro 功能 → 手机通行密钥'));
  assert.ok(read('services/pro/ProRdpSecurityKey.ets').includes('设置 → 安全与数据 → 手机通行密钥'));
});

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
  assert.deepEqual(ids('在远程 AI 里添加 Pi 主机'), ['host.add', 'settings.aiHosts']);
  assert.deepEqual(ids('在电脑端安装远程 AI 插件'), ['settings.aiInstall']);
  assert.deepEqual(ids('在电脑上安装 Pi 插件'), ['settings.aiInstall']);
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
  // A security key is not an SSH key, unless the step is about an SSH key; a 远程 AI session is not the AI 助理's own
  // conversations.
  assert.deepEqual(ids('使用 YubiKey 登录'), ['pro.securityKey']);
  assert.deepEqual(ids('用 ed25519-sk (FIDO) 生成 SSH 密钥'), ['ssh.keys', 'settings.keyVault']);
  // The install page by its own name and the hosts' plugins; pairing words keep the host page.
  for (const step of ['在电脑上安装 Codex', '在电脑上安装DSH', '在电脑上安装 Pi', '按电脑端安装里的指引安装 DSH',
    '在电脑端安装页复制 Codex 安装命令', '在电脑端安装 Codex 后回到 App 配对', '在 Codex 主机上更新插件到最新版本',
    '在电脑上运行 DSH 安装脚本', 'Codex 安装失败时检查 Node 版本', '确认电脑端插件正在运行']) {
    assert.deepEqual(ids(step), ['settings.aiInstall'], step);
  }
  assert.deepEqual(ids('扫描电脑端插件显示的二维码完成配对'), ['settings.aiHosts']);
  assert.deepEqual(ids('电脑端插件已运行但远程AI仍显示离线，请在远程AI里刷新主机'), ['settings.aiHosts']);
  for (const step of ['在电脑端安装 RustDesk 服务', '在电脑端安装 VNC 服务器', '在电脑端安装 Sunshine', '在电脑端安装显卡驱动']) {
    assert.ok(!ids(step).includes('settings.aiInstall'), step);
  }
  // The install page named outright is that page whatever else the step mentions.
  assert.deepEqual(ids('打开电脑端安装页，安装 Codex 插件和所需依赖'), ['settings.aiInstall']);
  assert.deepEqual(ids('用 pip 安装 DSH 依赖'), []);
  assert.deepEqual(ids('在远程 AI 里关闭工具执行过程'), ['settings.aiDisplay']);
  assert.deepEqual(ids('在远程 AI 主机里导出数据'), ['settings.aiData']);
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
  // Its page is 安全与数据 → 手机通行密钥; where that page is not open the Pro detail explains why.
  assert.match(host, /case 'pro\.phonePasskey':[\s\S]{0,200}SETTINGS_SHEET_PHONE_PASSKEY[\s\S]{0,200}this\.selectedProFeatureId = 'pro\.security\.phonePasskey'; this\.openSettingsLeafSheet\(SETTINGS_SHEET_PRO_FEATURE\)/);
  assert.match(host, /case 'pro\.securityKey':\s*this\.selectedProFeatureId = 'pro\.security\.webauthnRedirect'; this\.openSettingsLeafSheet\(SETTINGS_SHEET_PRO_FEATURE\)/);
});

// ---------------------------------------------------------------- what the AI knows
test('the knowledge base describes 远程 AI, its style, both keys and the session AI, with ids that exist', () => {
  const kb = load(D + 'DiagnosticAiKnowledgeBase');
  const settings = load(D + 'DiagnosticAiSettingsActionPolicy');
  const actions = load(D + 'DiagnosticAiAppActionPolicy');
  assert.match(kb.DIAGNOSTIC_AI_KNOWLEDGE_VERSION, /2026-10-07-v19$/);
  const guide = kb.aiAppGuide();
  for (const words of ['Pi（Pi 编程代理，9445', 'pi-gui', '全部项目（含电脑 App 里的项目）', '修改前询问', 'DSH', 'Codex 风格', '手机通行密钥', '安全密钥重定向',
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
  // Answers are read with the signed-in account's AI 语音 (the chat's owner).
  assert.match(chat, /private readInSession\([^)]*\): void \{[\s\S]*?settings\.init\(context, this\.owner\);[\s\S]*?AiReadAloud\.speak\(context, this\.owner,/);
  const leaving = host.slice(host.indexOf('aboutToDisappear(): void {'), host.indexOf('private active()'));
  assert.match(leaving, /const handover: boolean = this\.island\.isOpen\(\);/);
  assert.match(leaving, /this\.stopTalking\(\);/, 'reading aloud stops with the session page');
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

// ---------------------------------------------------------------- the session AI talks in its orb
test('连接中语音回答: when a session answer is read aloud, and voice mode listens again', () => {
  const policy = load(D + 'AiSessionVoicePolicy');
  assert.deepEqual(Array.from(policy.AI_SESSION_REPLY_MODES, m => m[0]), ['spoken', 'always', 'off']);
  assert.equal(policy.aiSessionReplyMode('nonsense'), 'spoken');
  // The setting: a question the orb heard (spoken), every answer, or none.
  assert.equal(policy.aiSessionReadsAnswer('spoken', '', true, true), true);
  assert.equal(policy.aiSessionReadsAnswer('spoken', '', false, true), false);
  assert.equal(policy.aiSessionReadsAnswer('always', '', false, true), true);
  assert.equal(policy.aiSessionReadsAnswer('off', '', true, true), false);
  // Voice mode (语音模式 / 用语音回答我) reads everything; 回到文字 reads nothing; AI 语音 off reads nothing.
  assert.equal(policy.aiSessionReadsAnswer('off', 'on', false, true), true);
  assert.equal(policy.aiSessionReadsAnswer('always', 'off', true, true), false);
  assert.equal(policy.aiSessionReadsAnswer('always', 'on', true, false), false);
  assert.equal(policy.aiSessionListensAgain('on', true), true);
  assert.equal(policy.aiSessionListensAgain('on', false), false);
  assert.equal(policy.aiSessionListensAgain('', true), false);
});

test('in a session no voice ball opens: the orb listens and reads, and the AI can change 连接中语音回答', () => {
  const host = read('components/diagnosticAi/SessionAiHost.ets');
  assert.doesNotMatch(host, /openVoice|AiVoiceLayerParams/, 'no voice ball over the session');
  const voice = host.slice(host.indexOf('private onVoiceRequest(): void {'), host.indexOf('private onAppActionRequest(): void {'));
  assert.match(voice, /AiChatMemory\.sessionTalk = 'on';/);
  assert.match(voice, /if \(AiChatMemory\.requestId === '' && AiReadAloud\.speakingId === ''\) \{\s*AppStorage\.setOrCreate\(AI_ORB_LISTEN_REQUEST, Date\.now\(\)\);/,
    'an answer on its way is read first, then the orb listens');
  const close = host.slice(host.indexOf('private closeAi(): void {'), host.indexOf('private publishOpen(): void {'));
  assert.match(close, /this\.stopTalking\(\);/, 'closing the AI stops reading and voice mode');
  const lift = read('components/diagnosticAi/AiLiftLayer.ets');
  assert.match(lift, /private onListenRequest\(\): void \{\s*if \(!this\.controller\.sessionMode \|\| this\.phase !== 2\) \{ return; \}/);
  assert.match(lift, /if \(AiReadAloud\.speakingId !== ''\) \{ AiReadAloud\.stop\(\); \}/, 'a double tap talks over the reading');
  assert.match(lift, /sessionVoice: this\.controller\.sessionMode,/);
  const chat = read('components/diagnosticAi/AiChatView.ets');
  assert.match(chat, /this\.spokenNext = true; this\.submit\(\);/, 'what the orb heard counts as spoken');
  assert.match(chat, /this\.readInSession\(context, answer, spoken\);/);
  const island = read('components/diagnosticAi/AiIsland.ets');
  assert.match(island, /if \(mode === 'text'\) \{\s*AiChatMemory\.sessionTalk = 'off';\s*AiReadAloud\.stop\(\);/);
  // The AI's interfaces: its settings catalog and the host page's bridge.
  const settings = load(D + 'DiagnosticAiSettingsActionPolicy');
  for (const id of ['ai.voice.enabled', 'ai.voice.sessionReply', 'ai.voice.rate', 'ai.voice.continuous']) {
    assert.ok(settings.diagnosticAiSettingSpec(id), id + ' is a setting');
  }
  assert.deepEqual(Array.from(settings.diagnosticAiSettingSpec('ai.voice.sessionReply').choices, c => c.value), ['spoken', 'always', 'off']);
  const page = read('pages/HostListPage.ets');
  assert.match(page, /if \(id\.indexOf\('ai\.voice\.'\) === 0\) \{ return this\.assistantVoiceSetting\(id\); \}/);
  assert.match(page, /else if \(id === 'ai\.voice\.sessionReply'\) \{ voice\.setSessionReply\(value\); \}/);
  assert.match(read('services/diagnosticAi/AiSkillCatalog.ets'), /voice=进入语音模式（用户说语音模式、用语音回答我时；在远程连接里是悬浮球把回答读出来并接着听，不会弹出语音大球）/);
  assert.ok(load(D + 'DiagnosticAiKnowledgeBase').aiAppGuide().includes('连接中语音回答'));
  assert.match(read('components/diagnosticAi/AiVoiceSettingsPanel.ets'), /AiSegmented\(\{ options: AI_SESSION_REPLY_MODES, current: this\.config\.sessionReply,/);
});

test('AI 控制面板: the AI button opens it (or starts the AI with 点 AI 按钮直接启动, a long press then opens it)', () => {
  const host = read('components/diagnosticAi/SessionAiHost.ets');
  const open = host.slice(host.indexOf('private onOpenRequest(): void {'), host.indexOf('private onPanelRequest(): void {'));
  assert.match(open, /if \(!this\.voiceConfig\(\)\.sessionQuickStart\) \{ this\.openPanel\(\); return; \}/);
  assert.match(open, /this\.closeAi\(\);[\s\S]*this\.startAi\(\);/);
  assert.match(host, /@StorageProp\(AI_SESSION_PANEL_REQUEST\) @Watch\('onPanelRequest'\)/);
  assert.match(host, /AiSessionRouter\.isInFront\(this\.hostId\)/, 'only the window the user is in opens it');
  assert.match(host, /if \(wasOpen\) \{ this\.closeAi\(\); \} else \{ this\.startAi\(\); \}/, 'the foot button starts or closes');
  // Voice mode off (panel or double tap): nothing more is read and the orb stops listening.
  assert.match(host, /private leaveVoiceMode\(\): void \{\s*AiChatMemory\.sessionTalk = '';\s*AiReadAloud\.stop\(\);\s*AppStorage\.setOrCreate\(AI_ORB_LISTEN_REQUEST, -Date\.now\(\)\);/);
  const lift = read('components/diagnosticAi/AiLiftLayer.ets');
  assert.match(lift, /if \(this\.listenRequest < 0\) \{ this\.stopOrbVoice\(false\); return; \}/);
  assert.match(lift, /if \(this\.controller\.sessionMode && AiChatMemory\.sessionTalk === 'on'\) \{\s*AiChatMemory\.sessionTalk = '';\s*AiReadAloud\.stop\(\);/);
  const panel = read('components/diagnosticAi/SessionAiPanel.ets');
  for (const words of ["'语音模式'", "'连续对话'", "'点 AI 按钮直接启动'", "'关闭 AI'", "'启动 AI'", "'模型'", "'回答风格'",
    "'回答长度'", "'联网搜索'", "'朗读语速'", "'AI 风格'", "'悬浮球样式'", "'开始新对话'"]) { assert.ok(panel.includes(words), words); }
  // A bind sheet (as the app's settings are), not a dialog.
  assert.match(host, /this\.getUIContext\(\)\.openBindSheet\(content, \{/);
  assert.match(host, /this\.getUIContext\(\)\.closeBindSheet\(content\)/);
  assert.doesNotMatch(host, /openCustomDialog/);
  for (const file of ['components/rdp/RdpSessionToolbar.ets', 'components/moonlight/MoonlightSessionToolbar.ets',
    'components/VncSessionToolbar.ets', 'components/RemoteSessionTopBar.ets']) {
    assert.match(read(file), /AppStorage\.setOrCreate\(AI_SESSION_PANEL_REQUEST, Date\.now\(\)\)/, file + ' long press');
  }
  const settings = load(D + 'DiagnosticAiSettingsActionPolicy');
  for (const id of ['ai.voice.sessionStartVoice', 'ai.voice.sessionQuickStart']) { assert.ok(settings.diagnosticAiSettingSpec(id), id); }
  assert.ok(load(D + 'DiagnosticAiKnowledgeBase').aiAppGuide().includes('AI 控制面板'));
});

test('a touch that starts on the AI orb or its chat never reaches the remote side', () => {
  const lift = read('components/diagnosticAi/AiLiftLayer.ets');
  assert.match(lift, /AiTouchShield\.register\(this\.shieldId, \(x: number, y: number\): boolean => this\.covers\(x, y\)\);/);
  assert.match(lift, /AiTouchShield\.unregister\(this\.shieldId\);/);
  assert.match(read('pages/RemoteDesktop.ets'),
    /private handleConfiguredTouchInput = \(event: TouchEvent\): void => \{\s*if \(this\.aiTouchShield\.shields\(event\)\) \{ return; \}/);
  const ml = read('pages/MoonlightStreamPage.ets');
  assert.match(ml, /private handleMoonlightSurfaceTouch = \(event: TouchEvent\): void => \{\s*if \(this\.aiTouchShield\.shields\(event\)\) \{ return; \}/);
  // The tracker: a finger down on the AI is kept out (moves and lift too); others pass.
  const shield = load(D + 'AiTouchShield');
  shield.AiTouchShield.register('t', (x, y) => x < 100 && y < 100);
  const tracker = new shield.AiTouchShieldTracker();
  const ev = (type, id, x, y) => ({ type, changedTouches: [{ id, windowX: x, windowY: y }], touches: [] });
  assert.equal(tracker.shields(ev(0, 1, 50, 50)), true);
  assert.equal(tracker.shields(ev(2, 1, 400, 400)), true, 'the drag moves away from where it started');
  assert.equal(tracker.shields(ev(1, 1, 400, 400)), true);
  assert.equal(tracker.shields(ev(0, 2, 300, 300)), false);
  assert.equal(tracker.shields(ev(2, 2, 310, 300)), false);
  shield.AiTouchShield.unregister('t');
  assert.equal(tracker.shields(ev(0, 3, 50, 50)), false);
});

(async () => {
  let failed = 0;
  for (const { name, body } of tests) {
    try { await body(); console.log('PASS', name); }
    catch (error) { failed++; console.error('FAIL', name); console.error(error); }
  }
  if (failed > 0) process.exit(1);
})();
