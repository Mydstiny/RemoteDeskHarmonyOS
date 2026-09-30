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

console.log(passed + ' personalization checks passed');
