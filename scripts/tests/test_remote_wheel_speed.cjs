'use strict';
/*
 * 远程滚轮 (2026-10-07): per-protocol wheel speed next to the direction, one combined settings sheet (protocol first),
 * a calmer VNC default, RDP sending one notch per tick, and the AI's interfaces.
 */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.AI_TYPESCRIPT_PATH || 'typescript');

const ETS = path.resolve(__dirname, '../../entry/src/main/ets');
const read = (file) => fs.readFileSync(path.join(ETS, file), 'utf8');
function load(file, cache = new Map()) {
  if (cache.has(file)) { return cache.get(file).exports; }
  const output = ts.transpileModule(read(file + '.ets'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  cache.set(file, module);
  const req = (name) => {
    if (name.startsWith('@')) { return { hilog: { info() {}, warn() {} } }; }
    const child = path.posix.normalize(path.posix.join(path.posix.dirname(file), name));
    // Only the policies under test are real; the capture runtime and its graph are not needed here.
    if (child.endsWith('DiagnosticCaptureRuntime') || !fs.existsSync(path.join(ETS, child + '.ets'))) {
      return { recordDiagnosticEvent() {} };
    }
    return load(child, cache);
  };
  vm.runInNewContext(output, { module, exports: module.exports, require: req, Math, Number, String, JSON, Set, Map,
    Array, Object, Error, AppStorage: { get() { return undefined; }, setOrCreate() {} } }, { filename: file });
  return module.exports;
}
let passed = 0;
function check(name, run) { run(); passed++; console.log('PASS ' + name); }

check('a speed is snapped to the 25% grid between 25% and 400%, and labelled', () => {
  const p = load('services/RemoteWheelPreferencePolicy');
  assert.equal(p.normalizeRemoteWheelSpeed(100), 100);
  assert.equal(p.normalizeRemoteWheelSpeed(130), 125);
  assert.equal(p.normalizeRemoteWheelSpeed(1000), 400);
  assert.equal(p.normalizeRemoteWheelSpeed(5), 25);
  assert.equal(p.normalizeRemoteWheelSpeed(NaN), 100);
  assert.equal(p.remoteWheelSpeedChoices().length, 16);
  assert.equal(p.remoteWheelSpeedLabel(100), '100%（默认）');
  assert.equal(p.remoteWheelSpeedKey('vnc'), 'vncWheelSpeed');
  const directions = { rdp: false, rustdesk: false, ssh: false, vnc: true, moonlight: false };
  const speeds = { rdp: 150, rustdesk: 100, ssh: 100, vnc: 50, moonlight: 100 };
  assert.equal(p.remoteWheelSettingsSummary(directions, speeds), 'RDP 150% · VNC 反转 50%');
  assert.equal(p.remoteWheelSettingsSummary({ rdp: false, rustdesk: false, ssh: false, vnc: false, moonlight: false },
    { rdp: 100, rustdesk: 100, ssh: 100, vnc: 100, moonlight: 100 }), '方向与速度均为默认');
  assert.equal(p.remoteWheelProtocolSummary(true, 200), '方向反转 · 速度 200%');
});

check('the speed scales whole ticks and carries the fraction (50% = every other notch)', () => {
  const w = load('services/RemoteWheelPolicy');
  let r = 0; let sent = 0;
  for (let i = 0; i < 10; i++) { const s = w.scaleRemoteWheelTicks(1, 50, r); r = s.remainder; sent += s.delta; }
  assert.equal(sent, 5);
  r = 0; sent = 0;
  for (let i = 0; i < 4; i++) { const s = w.scaleRemoteWheelTicks(1, 150, r); r = s.remainder; sent += s.delta; }
  assert.equal(sent, 6);
  assert.equal(w.scaleRemoteWheelTicks(-1, 100, 0).delta, -1);
  // A reversal drops the stale fraction.
  assert.equal(w.scaleRemoteWheelTicks(-1, 50, 0.5).delta, 0);
  assert.equal(w.scaleRemoteWheelTicks(-1, 50, 0.5).remainder, -0.5);
  assert.equal(w.scaleRemoteWheelTicks(100, 400, 0).delta, w.REMOTE_WHEEL_SPEED_MAX_TICKS);
  assert.equal(w.scaleMoonlightWheelAmount(120, 50), 60);
  assert.equal(w.scaleMoonlightWheelAmount(1, 25), 1, 'a motion never rounds to nothing');
  assert.equal(w.rdpWheelEventCount(3), 3);
  assert.equal(w.rdpWheelEventCount(-40), w.RDP_WHEEL_MAX_EVENTS);
});

check('VNC is calmer by default: one tick per mouse notch, 3 clicks a tick, 12 vp per two-finger tick', () => {
  const w = load('services/RemoteWheelPolicy');
  assert.equal(w.VNC_WHEEL_OUTPUT_GAIN, 3);
  assert.equal(w.VNC_VIRTUAL_WHEEL_VP_PER_TICK, 12);
  assert.equal(w.amplifyVncWheelOutputDelta(1), 3);
  const v = load('services/VncPhysicalWheelPolicy');
  assert.equal(v.vncPhysicalMouseWheelDelta(15, 3), 1, 'the local scroll step no longer multiplies the clicks');
  assert.equal(v.vncPhysicalMouseWheelDelta(-15, 3), -1);
});

check('every session path applies the speed; RDP sends one notch per tick', () => {
  const rd = read('pages/RemoteDesktop.ets');
  assert.equal((rd.match(/scaleRemoteWheelTicks\(/g) || []).length, 4, 'two-finger, physical, 2D touchpad x and y');
  assert.ok(rd.includes('for (let i = 0; i < count; i++) { this.loader.sendMouseWheel(this.sessionId, x, y, notch); }'));
  assert.equal((rd.match(/this\.loader\.sendMouseWheel\(/g) || []).length, 2, 'all wheel sends go through sendWheelEvents');
  const ml = read('pages/MoonlightStreamPage.ets');
  assert.equal((ml.match(/scaleMoonlightWheelAmount\(/g) || []).length, 2);
  assert.ok(read('pages/SshTerminal.ets').includes('wheelSpeed: normalizeRemoteWheelSpeed(this.sshWheelSpeed),'));
  const html = fs.readFileSync(path.resolve(ETS, '../resources/rawfile/ssh-terminal/index.html'), 'utf8');
  assert.ok(html.includes('terminal.options.scrollSensitivity = wheelSensitivity();'));
  assert.ok(html.includes('scrollSensitivity: wheelSensitivity(),'));
});

check('设置 › 远程滚轮: protocol first, then direction and speed, each saved at once on this device', () => {
  const sheet = read('components/RemoteWheelDirectionSettingsSheet.ets');
  assert.ok(sheet.includes("if (this.selected === '') {\n            this.listPage()"));
  assert.ok(sheet.includes("Text('全部协议')"), 'a way back to the protocol list');
  assert.ok(sheet.includes('Slider({ value: this.speed(protocol), min: REMOTE_WHEEL_SPEED_MIN'));
  assert.ok(/if \(!this\.onSaveSpeed\(protocol, next\)\) \{\n\s+this\.speeds = previous;/.test(sheet), 'a failed save shows the old speed');
  const page = read('pages/HostListPage.ets');
  assert.ok(page.includes("Text('远程滚轮').fontSize(AppTheme.fontSize.body)"));
  assert.ok(page.includes('onSaveSpeed: (protocol: RemoteWheelProtocol, speed: number): boolean =>'));
  assert.ok(page.includes('AppStorage.setOrCreate(VNC_WHEEL_SPEED_KEY, this.vncWheelSpeed);'), 'sessions read it live');
  // Like the direction, input feel belongs to the device: neither syncs with the account.
  const sync = load('services/CloudSyncSettingsPolicy');
  for (const key of ['rdpWheelSpeed', 'vncWheelSpeed', 'vncReverseWheel', 'rustdeskImageQuality']) {
    assert.ok(!sync.cloudUserSettingIsSyncable(key), key);
  }
});

check('the AI can read and change each speed and knows the combined setting', () => {
  const settings = load('services/diagnosticAi/DiagnosticAiSettingsActionPolicy');
  for (const p of ['rdp', 'rustdesk', 'ssh', 'vnc', 'moonlight']) {
    const spec = settings.diagnosticAiSettingSpec('remote.' + p + 'WheelSpeed');
    assert.ok(spec, p);
    assert.equal(spec.key, p + 'WheelSpeed');
    assert.ok(spec.choices.some((c) => c.value === '100'));
  }
  const page = read('pages/HostListPage.ets');
  assert.ok(page.includes("case 'remote.vncWheelSpeed': return this.saveRemoteWheelSpeed('vnc', num);"));
  const kb = read('services/diagnosticAi/DiagnosticAiKnowledgeBase.ets');
  assert.ok(kb.includes('远程滚轮：设置 → 显示与交互 → 远程滚轮，先选择协议'));
  assert.ok(kb.includes('RustDesk 画质：速度优先 / 平衡 / 画质优先'));
});

console.log('remote wheel: ' + passed + ' checks passed');
