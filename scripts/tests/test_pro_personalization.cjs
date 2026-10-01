// Pro 个性化方案: custom key combination model (v2) and its migration from v1 storage.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const tsPath = process.env.PRO_TYPESCRIPT_PATH || 'typescript';
const ts = require(tsPath);
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

const p = load('entry/src/main/ets/services/RemoteCustomShortcutPolicy.ets');
const CTRL = 2072, ALT = 2045, SHIFT = 2047, WIN = 2076;
let passed = 0;
// Objects come from another VM realm; compare their JSON form.
const same = (actual, expected, message) => assert.equal(JSON.stringify(actual), JSON.stringify(expected), message);
function test(name, fn) { fn(); passed++; console.log('PASS ' + name); }

test('new key groups: system keys and numpad are offered and mapped to labels', () => {
  same(p.remoteCustomShortcutKeyOptions('system').map(o => o.keyCode), [2079, 2067, 2074, 2102, 2075]);
  const numpad = p.remoteCustomShortcutKeyOptions('numpad');
  assert.equal(numpad.length, 16);
  assert.equal(numpad[0].label, 'Num0');
  assert.equal(numpad[15].keyCode, 2119);
  assert.equal(p.remoteCustomShortcutKeyGroupForKeyCode(2079), 'system');
  assert.equal(p.remoteCustomShortcutKeyGroupForKeyCode(2110), 'numpad');
});

test('standalone actions: system, function, navigation and numpad keys; typing keys still need a modifier', () => {
  assert.ok(p.createRemoteCustomShortcut('prtsc', [2079]));
  assert.ok(p.createRemoteCustomShortcut('f5', [2094]));
  assert.ok(p.createRemoteCustomShortcut('num7', [2110]));
  assert.equal(p.createRemoteCustomShortcut('a', [2017]), null);
  assert.equal(p.createRemoteCustomShortcut('one', [2001]), null);
  assert.equal(p.createRemoteCustomShortcut('comma', [2043]), null);
  assert.equal(p.createRemoteCustomShortcut('ctrl-only', [CTRL]), null);
  assert.equal(p.createRemoteCustomShortcut('ctrl-a', [SHIFT, CTRL, 2017]).label, 'Ctrl + Shift + A');
});

test('sequences: up to four ordered steps with a readable label and display name', () => {
  const chord = p.createRemoteCustomShortcutSteps('save-all', '全部保存', [[CTRL, 2027], [CTRL, 2035]]);
  assert.ok(chord);
  assert.equal(chord.steps.length, 2);
  assert.equal(p.remoteCustomShortcutStepsLabel(chord.steps), 'Ctrl + K → Ctrl + S');
  assert.equal(p.remoteCustomShortcutDisplayName(chord), '全部保存');
  assert.equal(p.remoteCustomShortcutDisplayName({ ...chord, name: '' }), 'Ctrl + K → Ctrl + S');
  same(chord.keyCodes, [CTRL, 2027], 'first step kept for v1 callers');
  assert.equal(p.createRemoteCustomShortcutSteps('five', '', [[2090], [2091], [2092], [2093], [2094]]), null);
  assert.equal(p.createRemoteCustomShortcutSteps('bad-step', '', [[CTRL, 2027], [2017]]), null);
  assert.equal(p.createRemoteCustomShortcutSteps('mac', 'x', [[WIN, 2019]]) !== null, true);
  assert.equal(p.remoteCustomShortcutStepsLabel([[WIN, ALT, 2019]], 'macos'), 'Option + Cmd + C');
});

test('names are trimmed to 16 characters and never carry control characters', () => {
  const item = p.createRemoteCustomShortcutSteps('named', '  一个非常非常非常非常非常长的名字\n换行  ', [[CTRL, 2019]]);
  assert.equal(item.name.length <= 16, true);
  assert.equal(item.name.includes('\n'), false);
});

test('duplicates across names are rejected and the cap stays at 32', () => {
  let list = p.upsertRemoteCustomShortcutSteps([], 'a', '复制', [[CTRL, 2019]]).shortcuts;
  const dup = p.upsertRemoteCustomShortcutSteps(list, 'b', '另一个名字', [[CTRL, 2019]]);
  assert.equal(dup.accepted, false);
  for (let i = 0; i < 31; i++) {
    list = p.upsertRemoteCustomShortcutSteps(list, 'k' + i, '', [[CTRL, ALT, 2090 + (i % 12)], [2103 + (i % 10)]]).shortcuts;
  }
  assert.equal(list.length, 32);
  assert.equal(p.upsertRemoteCustomShortcutSteps(list, 'over', '', [[2079]]).accepted, false);
});

test('reordering moves one entry and keeps the others', () => {
  let list = [];
  for (const [id, key] of [['x', 2090], ['y', 2091], ['z', 2092]]) {
    list = p.upsertRemoteCustomShortcutSteps(list, id, '', [[key]]).shortcuts;
  }
  same(p.moveRemoteCustomShortcut(list, 'z', -1).map(s => s.id), ['x', 'z', 'y']);
  same(p.moveRemoteCustomShortcut(list, 'x', -1).map(s => s.id), ['x', 'y', 'z']);
  same(p.moveRemoteCustomShortcut(list, 'x', 1).map(s => s.id), ['y', 'x', 'z']);
});

test('storage: v1 entries migrate to single-step v2; v2 round-trips names and steps; bad rows are dropped', () => {
  const v1 = JSON.stringify({ version: 1, items: [{ id: 'old', label: 'x', keyCodes: [CTRL, 2019] },
    { id: 'bad', keyCodes: [CTRL, 'A'] }] });
  const migrated = p.decodeRemoteCustomShortcuts(v1);
  assert.equal(migrated.length, 1);
  same(migrated[0].steps, [[CTRL, 2019]]);
  const encoded = p.encodeRemoteCustomShortcuts([
    p.createRemoteCustomShortcutSteps('seq', '序列', [[CTRL, 2027], [CTRL, 2035]]), migrated[0]]);
  assert.equal(JSON.parse(encoded).version, 2);
  const back = p.decodeRemoteCustomShortcuts(encoded);
  assert.equal(back.length, 2);
  assert.equal(back[0].name, '序列');
  assert.equal(back[0].steps.length, 2);
  const hostile = JSON.stringify({ version: 2, items: [{ id: 'evil', name: 'x', steps: [[CTRL, 2019], 'rm -rf'] },
    { id: 'evil2', steps: [[CTRL, 1e9]] }] });
  assert.equal(p.decodeRemoteCustomShortcuts(hostile).length, 0);
  assert.equal(p.decodeRemoteCustomShortcuts(JSON.stringify({ version: 3, items: [] })).length, 0);
});

test('platform availability checks every step (macOS lacks F21-F24)', () => {
  const s = p.createRemoteCustomShortcutSteps('f21', '', [[CTRL, 2019], [2824]]);
  assert.equal(p.remoteCustomShortcutAvailableOnPlatform(s, 'windows'), true);
  assert.equal(p.remoteCustomShortcutAvailableOnPlatform(s, 'macos'), false);
});

const k = load('entry/src/main/ets/services/ssh/skin/SshSkinPolicy.ets');

test('built-in skins: 28 complete, valid palettes with matching chrome', () => {
  const skins = k.sshBuiltInSkins();
  assert.equal(skins.length, 28);
  assert.equal(new Set(skins.map(s => s.id)).size, 28);
  for (const skin of skins) {
    assert.equal(skin.terminal.palette.length, 16, skin.id);
    for (const c of [skin.terminal.background, skin.terminal.foreground, skin.terminal.cursor, skin.terminal.selection,
      ...skin.terminal.palette]) assert.match(c, /^#[0-9A-F]{6}$/i, skin.id);
    for (const c of Object.values(skin.chrome)) assert.match(c, /^#([0-9A-F]{6}|[0-9A-F]{8})$/i, skin.id);
    assert.ok(k.sshSkinContrast(skin.terminal.foreground, skin.terminal.background) >= 3, skin.id + ' readable');
    assert.equal(k.sshSkinFont(skin.fontId).id, skin.fontId);
  }
  assert.equal(skins.find(s => s.id === 'solarized-light').dark, false);
  assert.equal(skins.find(s => s.id === 'dracula').dark, true);
});

test('bar and key text stay readable (>= 4.5:1) on every built-in skin', () => {
  for (const skin of k.sshBuiltInSkins()) {
    assert.ok(k.sshSkinContrast(skin.chrome.barText, skin.chrome.bar) >= 4.5, skin.id + ' bar text');
    assert.ok(k.sshSkinContrast(skin.chrome.keyText, skin.chrome.keyBar) >= 4.5, skin.id + ' key text');
  }
});

test('auto chrome follows the terminal: lighter bars on dark skins, darker on light ones', () => {
  const dark = k.sshSkinAutoChrome({ background: '#101010', foreground: '#EEEEEE', cursor: '#EEEEEE',
    selection: '#333333', palette: [] }, '#00AAFF');
  assert.ok(k.sshSkinLuminance(dark.bar) > k.sshSkinLuminance('#101010'));
  const light = k.sshSkinAutoChrome({ background: '#FAFAFA', foreground: '#222222', cursor: '#222222',
    selection: '#DDDDDD', palette: [] }, '#00AAFF');
  assert.ok(k.sshSkinLuminance(light.bar) < k.sshSkinLuminance('#FAFAFA'));
  assert.equal(dark.accent, '#00AAFF');
  assert.equal(k.sshSkinAlpha('#112233', 0.5), '#80112233');
});

test('resolution: Pro required, host beats global, custom skins and font override apply', () => {
  const settings = k.emptySshSkinSettings();
  settings.globalSkinId = 'nord';
  assert.equal(k.resolveSshSkin(settings, 'h1', false), null, 'free users keep the free appearance');
  assert.equal(k.resolveSshSkin(settings, 'h1', true).id, 'nord');
  const custom = k.sshSkinCopy(k.sshBuiltInSkins()[1], 'custom-abc', '我的');
  custom.terminal.background = '#000000';
  settings.custom.push(custom);
  settings.hostSkins.h1 = 'custom-abc';
  assert.equal(k.resolveSshSkin(settings, 'h1', true).terminal.background, '#000000');
  assert.equal(k.resolveSshSkin(settings, 'h2', true).id, 'nord');
  settings.fontId = 'fira-code';
  assert.equal(k.resolveSshSkin(settings, 'h2', true).fontId, 'fira-code');
  assert.equal(k.sshBuiltInSkins().find(s => s.id === 'nord').fontId, 'jetbrains-mono', 'built-ins are not mutated');
  settings.globalSkinId = '';
  assert.equal(k.resolveSshSkin(settings, 'h2', true), null, 'no skin selected keeps the free appearance');
  settings.globalSkinId = 'missing';
  assert.equal(k.resolveSshSkin(settings, 'h2', true), null);
});

test('storage: custom skins are whitelisted, colors validated, names bounded; hostile input is dropped', () => {
  const settings = k.emptySshSkinSettings();
  settings.globalSkinId = 'custom-one';
  settings.fontId = 'jetbrains-mono';
  settings.hostSkins = { 'host-1': 'dracula' };
  settings.custom = [k.sshSkinCopy(k.sshBuiltInSkins()[0], 'custom-one', '一'.repeat(40))];
  const back = k.decodeSshSkinSettings(k.encodeSshSkinSettings(settings));
  assert.equal(back.globalSkinId, 'custom-one');
  assert.equal(back.custom.length, 1);
  assert.equal(back.custom[0].name.length, 20);
  assert.equal(back.hostSkins['host-1'], 'dracula');
  const evil = JSON.stringify({ version: 1, globalSkinId: 'x', fontId: '"; alert(1)',
    custom: [{ ...settings.custom[0], id: 'custom-two', terminal: { ...settings.custom[0].terminal, background: 'red;x' } },
      { ...settings.custom[0], id: '../escape' }, { ...settings.custom[0], id: 'custom-ok', extra: 'dropped' }] });
  const parsed = k.decodeSshSkinSettings(evil);
  assert.equal(parsed.fontId, 'system', 'unknown fonts fall back to the system font');
  same(parsed.custom.map(s => s.id), ['custom-ok']);
  assert.equal('extra' in parsed.custom[0], false);
  assert.equal(k.decodeSshSkinSettings('{bad').custom.length, 0);
});

test('bundled fonts are shipped with their OFL licenses', () => {
  const dir = path.join(root, 'entry/src/main/resources/rawfile/ssh-terminal/fonts');
  for (const font of k.SSH_SKIN_FONTS.filter(f => f.bundled)) {
    for (const weight of ['400', '700']) assert.ok(fs.existsSync(path.join(dir, `${font.id}-latin-${weight}-normal.woff2`)), font.id);
    assert.match(fs.readFileSync(path.join(dir, `${font.id}-LICENSE.txt`), 'utf8'), /SIL Open Font License/);
  }
  const html = fs.readFileSync(path.join(root, 'entry/src/main/resources/rawfile/ssh-terminal/index.html'), 'utf8');
  for (const font of k.SSH_SKIN_FONTS.filter(f => f.bundled)) assert.ok(html.includes(`./fonts/${font.id}-latin-400-normal.woff2`), font.id);
});

test('Pro badge flow: stops are ordered, bounded and continuous across phases and the loop seam', () => {
  const stops = load('entry/src/main/ets/services/pro/ProBadgeFlowPolicy.ets').proBadgeFlowStops;
  const rgb = h => [1, 3, 5].map(i => parseInt(h.substr(i, 2), 16));
  const colorAt = (list, x) => {
    for (let i = 1; i < list.length; i++) if (x <= list[i][1]) {
      const [c0, p0] = list[i - 1], [c1, p1] = list[i]; const t = p1 === p0 ? 0 : (x - p0) / (p1 - p0);
      return rgb(c0).map((v, j) => v + (rgb(c1)[j] - v) * t);
    }
    return rgb(list[list.length - 1][0]);
  };
  let worst = 0;
  for (let f = 0; f <= 400; f++) {
    const a = stops(f / 400), b = stops(((f + 1) / 400) % 1);
    assert.equal(a[0][1], 0); assert.equal(a[a.length - 1][1], 1);
    for (let i = 1; i < a.length; i++) assert.ok(a[i][1] >= a[i - 1][1]);
    for (let x = 0; x <= 1; x += 0.05) {
      const ca = colorAt(a, x), cb = colorAt(b, x);
      worst = Math.max(worst, ...ca.map((v, j) => Math.abs(v - cb[j])));
    }
  }
  assert.ok(worst < 12, 'adjacent frames differ by at most a few levels, including 1 -> 0: ' + worst);
});

test('Pro badge styles: palettes, alpha order, meteors, shimmer and readable ink', () => {
  const b = load('entry/src/main/ets/services/pro/ProBadgeFlowPolicy.ets');
  for (const palette of b.PRO_BADGE_PALETTES) {
    assert.ok(palette.colors.length >= 2 && palette.colors.length <= 4, palette.id);
    palette.colors.forEach(c => assert.ok(b.validBadgeHex(c), palette.id + c));
  }
  assert.equal(b.withAlpha('#112233', '59'), '#59112233');
  assert.equal(b.cleanBadgeColors(['#ffffff', 'bad']).length, 4, 'fewer than two valid colors falls back');
  assert.equal(b.cleanBadgeColors(['#ffffff', '#000000', '#111111', '#222222', '#333333']).length, 4);
  assert.equal(b.badgeInkFor(['#B9F3EA', '#CDC9FF']), '#29223F');
  assert.equal(b.badgeInkFor(['#1A1A40', '#3A0050']), '#FFFFFF');
  let lastPulse = b.proBadgePulse(0);
  for (let f = 1; f <= 200; f++) {
    const value = b.proBadgePulse(f / 200);
    assert.ok(Math.abs(value - lastPulse) < 0.05, 'pulse is continuous'); lastPulse = value;
  }
  const aurora = b.PRO_BADGE_PALETTES[0].colors;
  for (let f = 0; f <= 100; f++) {
    const stops = b.proBadgeShimmerStops(f / 100, aurora);
    assert.equal(stops[0][1], 0); assert.equal(stops[stops.length - 1][1], 1);
    for (let i = 1; i < stops.length; i++) assert.ok(stops[i][1] >= stops[i - 1][1], 'shimmer stops ordered at ' + f);
    const meteors = b.proBadgeMeteors(f / 100, aurora);
    assert.equal(meteors.length, 6, 'six streaks every frame');
    meteors.forEach(m => { assert.ok(m.opacity >= 0 && m.opacity <= 1); assert.ok(m.travel >= 0 && m.length > 0); });
  }
  const seamA = b.proBadgeMeteors(0.9999, aurora), seamB = b.proBadgeMeteors(0, aurora);
  seamA.forEach((m, i) => assert.ok(Math.abs(m.opacity - seamB[i].opacity) < 0.05, 'no jump at the loop seam'));
});

console.log(passed + ' personalization checks passed');
