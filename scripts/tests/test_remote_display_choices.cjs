// RDP/RustDesk display choices: exactly one chip selected, honest summaries when a Pro value cannot be used.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const root = path.join(__dirname, '../..');

function load(file) {
  const source = ts.transpileModule(fs.readFileSync(path.join(root, file), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(source, { module, exports: module.exports, require(id) { throw new Error('unexpected import ' + id); } },
    { filename: file });
  return module.exports;
}

const p = load('entry/src/main/ets/services/RemoteDisplayProfilePolicy.ets');
let passed = 0;
function test(name, fn) { fn(); passed++; console.log('PASS ' + name); }

test('Windows scale: one selection per state, never 自动 and 标准 together', () => {
  assert.equal(p.rdpDesktopScaleSelection('auto', 100, true), 'auto');
  assert.equal(p.rdpDesktopScaleSelection('preset', 100, true), '100');
  assert.equal(p.rdpDesktopScaleSelection('preset', 140, false), '140');
  assert.equal(p.rdpDesktopScaleSelection('preset', 180, true), '180');
  assert.equal(p.rdpDesktopScaleSelection('custom', 125, true), 'custom');
  // A preset that is not a free step (older data) is a custom value.
  assert.equal(p.rdpDesktopScaleSelection('preset', 150, true), 'custom');
  // Without Pro the session negotiates automatically, so 自动 is what is selected.
  assert.equal(p.rdpDesktopScaleSelection('custom', 125, false), 'auto');
  assert.equal(p.rdpDesktopScaleSelection('bogus', 300, true), 'auto');
});

test('desktop size: custom falls back to 自适应 without Pro', () => {
  assert.equal(p.rdpResolutionSelection('custom', true), 'custom');
  assert.equal(p.rdpResolutionSelection('custom', false), 'auto');
  assert.equal(p.rdpResolutionSelection('1920x1080', false), '1920x1080');
});

test('aspect labels: common ratios by name, others reduced, invalid empty', () => {
  assert.equal(p.remoteDisplayAspectLabel(1920, 1080), '16:9');
  assert.equal(p.remoteDisplayAspectLabel(2560, 1600), '16:10');
  assert.equal(p.remoteDisplayAspectLabel(3440, 1440), '21:9');
  assert.equal(p.remoteDisplayAspectLabel(2160, 1440), '3:2');
  assert.equal(p.remoteDisplayAspectLabel(1366, 768), '16:9');
  assert.equal(p.remoteDisplayAspectLabel(1000, 300), '10:3');
  assert.equal(p.remoteDisplayAspectLabel(NaN, 100), '');
  assert.equal(p.remoteDisplayAspectLabel(0, 100), '');
  assert.equal(p.remoteDisplaySizeLabel(2560, 1600), '2560 × 1600');
});

test('free scale steps are exactly the RDPEDISP device steps', () => {
  [125, 150, 175, 200].forEach((percent) => assert.equal(p.isRdpFreeDesktopScale(percent), false));
  p.RDP_FREE_DESKTOP_SCALES.forEach((percent) => assert.equal(p.isRdpFreeDesktopScale(percent), true));
});

test('Pro entry summary: size then Windows scale', () => {
  assert.equal(p.rdpDisplayProfileSummary('auto', 0, 0, '', 'auto', 100), '自适应 · Windows 缩放 自动');
  assert.equal(p.rdpDisplayProfileSummary('custom', 2560, 1600, '', 'custom', 125), '2560 × 1600 · Windows 缩放 125%');
  assert.equal(p.rdpDisplayProfileSummary('1920x1080', 0, 0, '1920 × 1080', 'preset', 140), '1920 × 1080 · Windows 缩放 140%');
  assert.ok(p.RDP_PRO_DESKTOP_SCALE_GRID.every((v, i, a) => i === 0 || v > a[i - 1]), 'grid ascending');
});
console.log(passed + ' remote display choice checks passed');
