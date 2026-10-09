/* RDP 多显示器 (plan 2026-10-09 §4 D0/D1): the declared layout and its downgrade agree between ArkTS and the native
 * adapter, the local monitor view centres the chosen monitor, dynamic layout stays off, and a session without a
 * picture offers one screen. */
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');
const cache = {};
function load(relative) {
  if (cache[relative]) { return cache[relative]; }
  const module = { exports: {} };
  const source = ts.transpileModule(read(relative), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  vm.runInNewContext(source, { module, exports: module.exports, require: id => {
    if (id === './RemoteCanvasTransformPolicy') { return load('entry/src/main/ets/services/RemoteCanvasTransformPolicy.ets'); }
    throw new Error('unexpected import ' + id);
  }}, { filename: relative });
  cache[relative] = module.exports;
  return module.exports;
}
const m = load('entry/src/main/ets/services/RdpMultiMonitorPolicy.ets');
let passed = 0;
function check(name, body) { body(); passed++; console.log('PASS ' + name); }
const plain = (v) => JSON.parse(JSON.stringify(v));

const cases = [[0, 1920, 1080], [1, 2560, 1440], [2, 1920, 1080], [2, 2560, 1440], [3, 2560, 1440], [2, 3840, 2160],
  [4, 1920, 1080], [4, 2560, 1440], [9, 1920, 1080], [2, 100, 50], [3, 1921, 1081]];

check('layout: 2–4 side by side, downgrade beyond 8192 wide or two 4K screens', () => {
  assert.deepEqual(plain(m.rdpMultimonLayout(2, 2560, 1440)), { count: 2, monitorWidth: 2560, monitorHeight: 1440,
    desktopWidth: 5120, desktopHeight: 1440, downgraded: false });
  assert.equal(m.rdpMultimonLayout(3, 2560, 1440).downgraded, false);
  assert.deepEqual(plain(m.rdpMultimonLayout(4, 2560, 1440)), { count: 4, monitorWidth: 1920, monitorHeight: 1080,
    desktopWidth: 7680, desktopHeight: 1080, downgraded: true });
  assert.equal(m.rdpMultimonLayout(2, 3840, 2160).downgraded, false, 'two 4K screens are allowed');
  assert.equal(m.rdpMultimonLayout(9, 1920, 1080).count, 4);
  assert.equal(m.rdpMultimonLayout(1, 1920, 1080).count, 1);
  assert.equal(m.normalizeRdpMultimonCount(1), 0);
  assert.equal(m.normalizeRdpMultimonCount(NaN), 0);
  assert.deepEqual(plain(m.rdpMonitorRects(m.rdpMultimonLayout(3, 1920, 1080)).map((r) => r.x)), [0, 1920, 3840]);
});

check('native adapter applies the same rules (compiled with the host compiler)', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rdp-multimon-'));
  const src = path.join(dir, 't.cpp');
  fs.writeFileSync(src, '#include "rdp_multimon_policy.h"\n#include <cstdio>\nint main(){int c[][3]={' +
    cases.map((c) => '{' + c.join(',') + '}').join(',') + '};for(auto& x:c){auto l=RdpMultimonPolicy::Resolve(true,x[0],x[1],x[2]);' +
    'std::printf("%d %d %d %d %d %d\\n",l.count,l.monitorWidth,l.monitorHeight,l.desktopWidth,l.desktopHeight,l.downgraded?1:0);}}\n');
  const bin = path.join(dir, 't');
  // The host compiler: with the HarmonyOS environment sourced, plain clang++ is the SDK's, without host headers.
  const compiler = process.platform === 'darwin' && fs.existsSync('/usr/bin/clang++') ? '/usr/bin/clang++' : 'clang++';
  execFileSync(compiler, ['-std=c++17', '-I', path.join(root, 'entry/src/main/cpp/rdp'), src, '-o', bin]);
  const native = execFileSync(bin, { encoding: 'utf8' }).trim().split('\n');
  cases.forEach((c, i) => {
    const l = m.rdpMultimonLayout(c[0], c[1], c[2]);
    assert.equal(native[i], [l.count, l.monitorWidth, l.monitorHeight, l.desktopWidth, l.desktopHeight, l.downgraded ? 1 : 0].join(' '),
      'case ' + c.join('/'));
  });
  fs.rmSync(dir, { recursive: true, force: true });
});

check('monitor view: the chosen monitor is centred and as large as the surface allows', () => {
  const viewport = { surfaceWidth: 2000, surfaceHeight: 1200, sourceWidth: 3840, sourceHeight: 1080 };
  const rects = m.rdpMonitorRects(m.rdpMultimonLayout(2, 1920, 1080));
  const t = m.rdpMonitorFocusTransform(viewport, rects[1]);
  const fit = Math.min(2000 / 3840, 1200 / 1080);
  const physical = fit * t.scale;
  assert.ok(Math.abs(physical - Math.min(2000 / 1920, 1200 / 1080)) < 1e-9);
  const left = (2000 - 3840 * physical) / 2 + t.panX;
  const monitorCenter = left + (1920 + 960) * physical;
  assert.ok(Math.abs(monitorCenter - 1000) < 0.5, 'centre ' + monitorCenter);
  const all = m.rdpMonitorFocusTransform(viewport, null);
  assert.equal(all.scale, 1); assert.equal(all.panX, 0);
  assert.equal(m.nextRdpMonitorFocus(-1, 2), 0);
  assert.equal(m.nextRdpMonitorFocus(1, 2), -1);
  assert.equal(m.rdpMonitorLabel(-1), '全部屏幕');
  assert.equal(m.rdpMonitorLabel(1), '屏幕 2');
});

check('native: monitors declared, Display Control off, server layout logged; the old "ignored" path is gone', () => {
  const cpp = read('entry/src/main/cpp/rdp/freerdp_adapter.cpp');
  assert.doesNotMatch(cpp, /多显示器配置已忽略/);
  assert.match(cpp, /RdpMultimonPolicy::Resolve\(cfg\.multiMonitor, cfg\.monitorCount,/);
  assert.match(cpp, /freerdp_settings_set_bool\(s, FreeRDP_UseMultimon, TRUE\);/);
  assert.match(cpp, /freerdp_settings_set_bool\(s, FreeRDP_SupportDisplayControl, FALSE\);\s*freerdp_settings_set_bool\(s, FreeRDP_DynamicResolutionUpdate, FALSE\);/);
  assert.match(cpp, /freerdp_settings_get_pointer_array_writable\(s, FreeRDP_MonitorDefArray/);
  assert.match(cpp, /instance->update->RemoteMonitors = rdpCbRemoteMonitors;/);
  assert.match(cpp, /context->update->RemoteMonitors = nullptr;/);
});

check('ArkTS: Pro-gated, per-host fallback, dynamic layout off, toolbar and control center', () => {
  const page = read('entry/src/main/ets/pages/RemoteDesktop.ets');
  assert.match(page, /private rdpMultimonCountFor\(host: RemoteHost\): number \{\s*if \(!this\.rdpAdvancedDisplayDecision\(\)\.executable\) \{ return 0; \}\s*if \(this\.rdpMultimonFallbackHosts\(\)\.indexOf\(host\.id\) >= 0\) \{ return 0; \}/);
  assert.match(page, /multiMonitor: true, monitorCount: layout\.count \};/);
  assert.match(page, /if \(!this\.canRequestRdpDynamicLayout\(\) \|\| this\.rdpMultimonActive !== null\) \{/);
  assert.match(page, /stats\.renderedPaintCount <= 0 &&\s*Date\.now\(\) - this\.rdpMultimonStartedAt > RDP_MULTIMON_FIRST_FRAME_TIMEOUT_MS/);
  assert.match(page, /if \(action === 'monitor'\) \{ this\.cycleRdpMonitorFocus\(\); return; \}/);
  assert.equal((page.match(/monitorLabel: this\.rdpMultimonActive === null \? '' : rdpMonitorLabel\(this\.rdpMonitorFocus\)/g) || []).length, 2);
  const center = read('entry/src/main/ets/components/rdp/RdpControlCenter.ets');
  assert.match(center, /this\.multimonSection\(\)/);
  assert.doesNotMatch(center, /this\.choice\([^)]*< \d, \(\): void/, 'no bare < before a typed arrow argument (es2abc)');
  assert.match(read('entry/src/main/ets/services/diagnosticAi/DiagnosticAiKnowledgeBase.ets'), /'RDP 多显示器（Pro 高级显示，实验）：/);
});

console.log(passed + ' passed');
