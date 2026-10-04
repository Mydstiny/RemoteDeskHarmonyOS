'use strict';

/* AI 风格 (Siri / 小艺): ink tokens, the 小艺 halo's light and voice model, and the AI surfaces' sizes in every window. */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.AI_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const modules = new Map();
const storage = new Map();
const AppStorage = {
  get: (key) => storage.get(key),
  setOrCreate: (key, value) => { storage.set(key, value); }
};
const prefs = new Map();
const kits = {
  '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {} } },
  '@kit.AbilityKit': { common: {} },
  '@kit.ArkData': { preferences: { getPreferencesSync: () => ({
    getSync: (k, f) => (prefs.has(k) ? prefs.get(k) : f), putSync: (k, v) => { prefs.set(k, v); }, flush: () => {} }) } }
};

const anyModule = new Proxy(function () {}, {
  get: (_t, key) => (key === '__esModule' ? false : key === 'default' ? anyModule : anyModule),
  apply: () => anyModule,
  construct: () => anyModule
});

function load(file) {
  if (modules.has(file)) return modules.get(file).exports;
  const ets = path.join(root, file + '.ets');
  const plain = path.join(root, file + '.ts');
  if (!fs.existsSync(ets) && !fs.existsSync(plain)) return anyModule;
  const source = fs.readFileSync(fs.existsSync(ets) ? ets : plain, 'utf8');
  const context = vm.createContext({ Math, Number, String, Object, Array, Map, Set, Error, JSON, Date, AppStorage, isNaN });
  const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const requireRelative = (name) => {
    if (kits[name]) return kits[name];
    // Any other system module: a permissive stand-in (these tests never reach the system).
    if (name.startsWith('@')) return anyModule;
    const child = path.posix.normalize(path.posix.join(path.posix.dirname(file), name));
    return load(child.endsWith('.ets') ? child.slice(0, -4) : child);
  };
  const wrapped = vm.runInContext('(function(require,module,exports){' + output + '\n})', context);
  const fresh = { exports: {} };
  modules.set(file, fresh);
  wrapped(requireRelative, fresh, fresh.exports);
  return fresh.exports;
}

const D = 'entry/src/main/ets/services/diagnosticAi/';

// ---------------------------------------------------------------- ink and presets
const style = load(D + 'AiStylePolicy');
const SIRI = { text2: '#8E8E93', text3: '#AEAEB2', text4: '#636366', icon: '#C7C7CC', textSoft: '#E5E5EA', surface: '#2C2C2E',
  surfaceDeep: '#1C1C1E', surfaceRaised: '#3A3A3C', fillGray: '#2E3A3A3C', menu: '#F01C1C1F', hint: '#E61C1C1E' };
for (const [role, color] of Object.entries(SIRI)) {
  assert.equal(style.aiInk('siri', role), color, 'Siri keeps its exact ' + role);
  const xy = style.aiInk('xiaoyi', role);
  assert.ok(/^#[0-9A-F]{8}$/.test(xy), role);
  assert.ok(!Object.values(SIRI).includes(xy), '小艺 replaces the grey for ' + role);
}
assert.equal(style.aiInk('anything else', 'text2'), '#8E8E93', 'unknown styles fall back to Siri');
assert.deepEqual({ ...style.aiStylePreset('xiaoyi') }, { thinking: 'xiaoyi', orb: 'xiaoyiRing', done: 'xiaoyi' });
assert.deepEqual({ ...style.aiStylePreset('siri') }, { thinking: 'dots', orb: 'voice', done: 'check' });
assert.notEqual(style.aiXiaoyiGlass(false).from, style.aiXiaoyiGlass(true).from, 'light and dark glass differ');
assert.equal(style.aiXiaoyiWash(false).length, 2);
console.log('PASS ink: Siri unchanged, 小艺 whites instead of greys; style presets; light and dark glass');

// ---------------------------------------------------------------- style choice applies its motions
const motion = load(D + 'DiagnosticAiMotionPolicy');
assert.equal(motion.AI_MOTION_KINDS[0].key, 'aiStyle', 'AI 风格 is the first choice in AI 动效');
['xiaoyi'].forEach((id) => assert.ok(motion.AI_MOTION_KINDS.find((k) => k.key === 'aiMotion.thinking').options.some((o) => o.id === id)));
assert.ok(motion.AI_MOTION_KINDS.find((k) => k.key === 'aiMotion.orb').options.some((o) => o.id === 'xiaoyiRing'));
assert.ok(motion.AI_MOTION_KINDS.find((k) => k.key === 'aiMotion.done').options.some((o) => o.id === 'xiaoyi'));
motion.DiagnosticAiMotionStore.save({}, 'aiStyle', 'xiaoyi');
assert.equal(storage.get('aiStyle'), 'xiaoyi');
assert.equal(storage.get('aiMotion.thinking'), 'xiaoyi');
assert.equal(storage.get('aiMotion.orb'), 'xiaoyiRing');
assert.equal(storage.get('aiMotion.done'), 'xiaoyi');
motion.DiagnosticAiMotionStore.save({}, 'aiMotion.orb', 'glass');
assert.equal(storage.get('aiMotion.orb'), 'glass', 'each motion can still be changed on its own');
motion.DiagnosticAiMotionStore.save({}, 'aiStyle', 'xiaoyi');
assert.equal(storage.get('aiMotion.orb'), 'glass', 'choosing the current style again keeps what was adjusted');
motion.DiagnosticAiMotionStore.save({}, 'aiStyle', 'siri');
assert.equal(storage.get('aiMotion.thinking'), 'dots');
assert.equal(storage.get('aiMotion.orb'), 'voice');
storage.set('diagnosticAiReducedMotion', true);
storage.set('aiStyle', 'xiaoyi');
assert.equal(motion.aiMotionStyle('aiStyle'), 'xiaoyi', 'reducing motion keeps the chosen look');
assert.equal(motion.aiMotionStyle('aiMotion.thinking'), 'minimal');
storage.set('diagnosticAiReducedMotion', false);
console.log('PASS choosing a style sets its thinking ring, orb and done mark; each stays adjustable; reduced motion keeps the look');

// ---------------------------------------------------------------- the orb listening into its small chat
const bridge = load(D + 'AiBridgeKeys');
const heard = bridge.aiOrbDictationDecode(bridge.aiOrbDictationEncode('listen', '打开 | AI 配置'));
assert.equal(heard.state, 'listen');
assert.equal(heard.text, '打开 | AI 配置', 'the words survive a | in them');
assert.equal(bridge.aiOrbDictationDecode('').state, '', 'nothing yet');
assert.equal(bridge.aiOrbDictationDecode(bridge.aiOrbDictationEncode('done', '')).state, 'done');
console.log('PASS the orb hands what it hears to its small chat: listening, done, cancelled');

// ---------------------------------------------------------------- sizes in every window
const geo = load(D + 'AiSurfaceGeometry');
const windows = [
  ['phone', 320, 700], ['phone', 360, 780], ['phone', 412, 915], ['phone', 780, 360], ['pad', 720, 780], ['pad', 1280, 800],
  ['pad', 800, 1280], ['pad', 420, 800], ['pc', 1200, 760], ['pc', 480, 600]
];
for (const [device, w, h] of windows) {
  for (const width of [geo.aiPanelWidth(device, w, h), geo.aiVoiceCardWidth(device, w, h)]) {
    assert.ok(width <= w - 21 + 1e-9, device + ' ' + w + 'x' + h + ' stays inside the window: ' + width);
    assert.ok(width >= Math.min(w - 24, 300), device + ' ' + w + 'x' + h + ' is not squeezed: ' + width);
  }
  assert.ok(geo.aiTranscriptWidth(device, w, h) <= geo.aiVoiceCardWidth(device, w, h));
}
assert.equal(geo.aiPanelWidth('phone', 360, 780), 360 - 25 * (360 / 375), 'phone upright keeps Siri\'s 12.5 vp margins');
assert.equal(geo.aiPanelWidth('phone', 320, 700), 320 - 25 * (320 / 375), 'a narrow phone too (no extra squeeze)');
assert.equal(geo.aiPanelWidth('phone', 780, 360), 560, 'phone sideways (a session): centred, capped');
assert.equal(geo.aiPanelWidth('pad', 1280, 800), 640);
assert.equal(geo.aiPanelWidth('pad', 420, 800), 396, 'split screen: no longer 460 wide in a 420 window');
assert.equal(geo.aiVoiceCardWidth('pad', 420, 800), 396);
assert.equal(geo.aiPanelWidth('pc', 1200, 760), 620);
assert.equal(geo.aiPanelWidth('pc', 480, 600), 456, 'a small PC window: no longer 520 wide');
assert.equal(geo.aiSurfaceScale('phone', 780, 360), geo.aiSurfaceScale('phone', 360, 780), 'turning the phone keeps its scale');
assert.equal(geo.aiPanelHeightShare('phone', 780, 360), 0.86);
assert.equal(geo.aiVoiceCardHeightShare('phone', 780, 360), 0.8);
assert.ok(geo.aiPanelRadius('phone', 360, 780) > geo.aiPanelRadius('phone', 780, 360));
// The floating orb after a rotation: same side, inside the new window.
const [ox, oy] = geo.aiReclampOrb(150, 500, 360, 780, 780, 360, 40, 48);
assert.ok(ox > 0 && ox <= 780 / 2 - 24 - 6 + 1e-9, 'still on the right, inside');
assert.ok(oy >= 0 && oy <= 360 - 40 - 48 - 24, 'still inside vertically');
console.log('PASS panel, voice card and transcript fit phone (upright, sideways), foldable, tablet (split), PC windows; orb kept inside');

// ---------------------------------------------------------------- the 小艺 halo: light and voice
const light = load(D + 'AiXiaoyiLight');
const around = Array.from({ length: 36 }, (_, i) => light.xyLight(i / 36 * Math.PI * 2, 0, light.XY_CYAN, 0.7, 3));
assert.ok(around.every((c) => c.every((v) => v >= 0 && v <= 255)));
const mean = (k) => around.reduce((sum, c) => sum + c[k], 0) / around.length;
assert.ok(mean(1) > mean(0), 'the water light is cyan on the whole: more green than red');
const flows = [0, 0.5, 1, 1.5, 2].map((t) => light.xyLight(0.3, t, light.XY_WHITE, 0.35, 2.6).map(Math.round).join(','));
assert.ok(new Set(flows).size >= 4, 'the colors flow round the ring');
let seq = 1;
const random = () => { seq = (seq * 16807) % 2147483647; return seq / 2147483647; };
const quiet = new light.XyVoice();
const loud = new light.XyVoice();
for (let i = 0; i < 90; i++) { quiet.step(1 / 60, 'listen', 0.05, random); loud.step(1 / 60, 'listen', 0.95, random); }
const rq = light.xyRipples(quiet);
const rl = light.xyRipples(loud);
assert.equal(rl.length, 3);
assert.ok(rl[2].radius > rq[2].radius && rl[0].strength > rq[0].strength, 'a louder voice pushes the water out and brightens it');
// The water follows the voice as a damped spring: a sudden voice comes in smoothly at 120 frames a second, and
// the ripples move by small steps every frame (no 60 Hz steps either).
const sv = new light.XyVoice();
let prevLevel = 0, maxStep = 0, peakLevel = 0, prevRadius = -1, maxRadiusStep = 0;
for (let i = 0; i < 240; i++) {
  sv.step(1 / 120, 'listen', i < 4 ? 0 : 1, random);
  maxStep = Math.max(maxStep, Math.abs(sv.level - prevLevel));
  prevLevel = sv.level;
  peakLevel = Math.max(peakLevel, sv.level);
  const r = light.xyRipples(sv)[2].radius;
  if (prevRadius >= 0) { maxRadiusStep = Math.max(maxRadiusStep, Math.abs(r - prevRadius)); }
  prevRadius = r;
}
assert.ok(maxStep < 0.08, 'no jump from one frame to the next: ' + maxStep);
assert.ok(peakLevel < 1.08 && prevLevel > 0.95, 'settles at the voice without overshooting much');
assert.ok(maxRadiusStep < 0.02, 'the outer ripple moves smoothly: ' + maxRadiusStep);
assert.ok(rl[0].radius < rl[1].radius && rl[1].radius < rl[2].radius, 'ripples stay in order');
// A voice that starts now reaches the inner ripple before the outer one.
const onset = new light.XyVoice();
for (let i = 0; i < 60; i++) { onset.step(1 / 60, 'listen', 0, random); }
for (let i = 0; i < 12; i++) { onset.step(1 / 60, 'listen', 1, random); }
const ro = light.xyRipples(onset);
assert.ok(ro[0].radius - 1.24 > ro[2].radius - 1.95 + 1e-6, 'the voice travels outward: the inner ripple answers first');
// Thinking: the ripples stay where they were.
const still = new light.XyVoice();
for (let i = 0; i < 90; i++) { still.step(1 / 60, 'listen', 0.4 + 0.5 * Math.sin(i * 0.3), random); }
still.step(1 / 60, 'think', 0, random);
const before = light.xyRipples(still).map((r) => r.ox.toFixed(4) + '/' + r.oy.toFixed(4));
for (let i = 0; i < 60; i++) { still.step(1 / 60, 'think', 0, random); }
const after = light.xyRipples(still).map((r) => r.ox.toFixed(4) + '/' + r.oy.toFixed(4));
assert.deepEqual(after, before, 'thinking keeps the ripples where they were');
assert.ok(still.think > 0.9 && still.listen < 0.1);
// The ring: flat at rest, tumbling while thinking; the sphere is lit where it reaches.
const flat = light.xyRingPoints(1.3, 0, 72);
assert.ok(flat.every((p) => Math.abs(Math.hypot(p[0], p[1]) - 1) < 1e-9 && p[2] === 0));
const spun = light.xyRingPoints(0.4, 1, 72);
assert.ok(spun.some((p) => Math.abs(p[2]) > 0.3), 'the ring turns out of the screen plane while thinking');
const reach = new light.XyReach([spun], 1);
const lit = Array.from({ length: 48 }, (_, k) => reach.lightAt(k / 48 * Math.PI * 2));
assert.ok(Math.max(...lit) > 0.6 && Math.min(...lit) < 0.1, 'the still sphere is lit where the ring passes, dark elsewhere');
// Ripples shine more where they come closer to the ring.
const rp = new light.XyRipple(0.15, 0, 1.24, 0.12, 1, 0.13);
assert.ok(light.xyRippleShine(rp, Math.PI, 0) > light.xyRippleShine(rp, 0, 0) * 0.9, 'the near side forms the crescent');
assert.equal(light.xyCss([300, 10, 10], 2), 'rgba(255,20,20,1.000)');
console.log('PASS 小艺 halo: cyan light, flowing colors, ripples follow the voice outward, freeze while thinking, sphere lit by the ring');

// ---------------------------------------------------------------- "切到小艺风格" said to the AI
const settings = load(D + 'DiagnosticAiSettingsActionPolicy');
const said = settings.diagnosticAiSettingIntents('切到小艺风格');
assert.ok(said.some((p) => p.settingId === 'ai.style' && p.proposedValue === 'xiaoyi'), JSON.stringify(said));
const back = settings.diagnosticAiSettingIntents('换回 Siri 风格');
assert.ok(back.some((p) => p.settingId === 'ai.style' && p.proposedValue === 'siri'), JSON.stringify(back));
const route = load(D + 'AiChatRoutePolicy');
assert.equal(route.aiModeCommand('切到小艺风格'), '', 'a style is a setting, not a mode switch');
console.log('PASS 「切到小艺风格」/「换回 Siri 风格」 become the AI 风格 setting, not a mode command');
