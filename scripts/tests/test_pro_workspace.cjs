const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
function load(relative) {
  const file = path.join(root, relative); const module = { exports: {} };
  const source = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInNewContext(source, { module, exports: module.exports, require: () => ({}) }, { filename: file }); return module.exports;
}
const p = load('entry/src/main/ets/services/pro/workspace/WorkspacePolicy.ets');
const view = p.defaultWorkspaceView();
const workspace = { schemaVersion: 1, id: 'ws-1', name: 'Daily', color: '#007DFF', icon: 'desktop', order: 0,
  entries: [{ hostRef: 'h1', protocol: 'ssh', order: 0, autoConnect: true, view }], layout: 'split', updatedAt: 1 };
assert.equal(JSON.stringify(p.validateWorkspace(workspace)), '[]');
assert.ok(p.validateWorkspace({ ...workspace, entries: [{ ...workspace.entries[0], hostRef: '' }] }).includes('invalid_host_ref'));
const entries = Array.from({ length: 4 }, (_, i) => ({ hostRef: 'h' + i, protocol: i === 0 ? 'ssh' : 'rdp', order: i, autoConnect: true, view: { ...view, ...(i === 0 ? {} : { strictBounds: true }) } }));
const laidOut = p.applyLayoutPreset(entries, 'grid4');
assert.equal(laidOut[3].frame.x, 0.5); assert.equal(laidOut[3].frame.y, 0.5);
assert.deepEqual(p.workspaceOpenPlan({ ...workspace, entries }, 'phone').items.map(i => i.mode), ['window', 'queued', 'queued', 'queued']);
assert.deepEqual(p.workspaceOpenPlan({ ...workspace, entries }, 'tablet').items.slice(0, 2).map(i => i.mode), ['split', 'split']);
assert.deepEqual(p.workspaceOpenPlan({ ...workspace, entries }, 'pc').items.map(i => i.mode), ['tab', 'window', 'window', 'window']);
assert.equal(p.workspaceOpenPlan({ ...workspace, entries }, 'phone').maxConcurrent, 3);
const created = p.newWorkspace('ws-2', '  晨间巡检  ', '#5856D6', '🖥️', 1, 5);
assert.equal(created.name, '晨间巡检'); assert.equal(JSON.stringify(p.validateWorkspace(created)), '[]');
let list = p.addWorkspaceEntries([], ['a', 'b', 'c', 'a'], ['ssh', 'rdp', 'vnc', 'ssh']);
assert.equal(list.map(e => e.hostRef).join(), 'a,b,c'); assert.equal(list[1].view.strictBounds, false);
assert.equal(JSON.stringify(p.validateWorkspace({ ...created, entries: list })), '[]');
list = p.moveWorkspaceEntry(list, 'c', -2); assert.equal(list.map(e => e.hostRef + e.order).join(), 'c0,a1,b2');
list = p.removeWorkspaceEntry(list, 'a'); assert.equal(list.map(e => e.hostRef + e.order).join(), 'c0,b1');
assert.equal(p.addWorkspaceEntries(Array.from({ length: 16 }, (_, i) => p.newWorkspaceEntry('x' + i, 'ssh', i)), ['y'], ['ssh']).length, 16);
const copy = p.copyWorkspace({ ...created, entries: list }); copy.entries[0].view.scale = 3;
assert.equal(list[0].view.scale, 1);
assert.equal(p.missingWorkspaceRefs({ ...created, entries: list }, ['c']).join(), 'b');
const snapped = p.snapWorkspaceFrame({ x: 0.93, y: -0.2, w: 0.3, h: 2, fullscreen: false });
assert.equal(JSON.stringify(snapped), JSON.stringify({ x: 0.75, y: 0, w: 0.25, h: 1, fullscreen: false }));
assert.equal(p.workspaceLayoutLabel('masterDetail'), '主副'); assert.equal(p.workspaceLayoutLabel(undefined), '自定义');
let run = p.workspaceRunFor({ ...created, entries: list }, { c: 'VNC 主机' }, 9);
assert.equal(run.items.map(i => i.state).join(), 'queued,skipped');
assert.equal(p.nextQueuedRunIndex(run), 0); assert.equal(p.workspaceRunFinished(run), false);
run = p.setRunItemState(run, 0, 'connecting', ''); assert.equal(p.connectingRunIndex(run), 0);
run = p.setRunItemState(run, 0, 'opened', ''); assert.equal(p.workspaceRunFinished(run), true);
assert.equal(p.workspaceRunSummary(run), '1 个已打开 · 1 个已跳过');
assert.equal(JSON.stringify(p.workspaceWindowRect({ x: 0.5, y: 0, w: 0.5, h: 1, fullscreen: false }, 2000, 1200, 600, 400)),
  JSON.stringify({ left: 1000, top: 0, width: 1000, height: 1200 }));
assert.equal(JSON.stringify(p.workspaceWindowRect({ x: 0.9, y: 0.9, w: 0.125, h: 0.125, fullscreen: false }, 2000, 1200, 600, 400)),
  JSON.stringify({ left: 1400, top: 800, width: 600, height: 400 }));
assert.equal(JSON.stringify(p.workspaceWindowRect({ x: 0.5, y: 0.5, w: 0.5, h: 0.5, fullscreen: true }, 2000, 1200, 600, 400)),
  JSON.stringify({ left: 0, top: 0, width: 2000, height: 1200 }));
assert.equal(p.addWorkspaceEntries([], ['a', 'b', 'c'], ['ssh', 'rdp', 'vnc'], 2).map(e => e.hostRef).join(), 'a,b');
assert.equal(p.workspaceRunFor({ ...created, entries: p.addWorkspaceEntries([], ['a', 'b', 'c'], ['ssh', 'ssh', 'ssh']) },
  { a: 'A', b: 'B', c: 'C' }, 1, 2).items.map(i => i.label).join(), 'A,B');
const d = (() => {
  const file = path.join(root, 'entry/src/main/ets/services/pro/workspace/WorkspaceDevicePolicy.ets'); const module = { exports: {} };
  const source = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInNewContext(source, { module, exports: module.exports, require: (id) => id === './WorkspacePolicy' ? p : {} }, { filename: file });
  return module.exports;
})();
assert.equal(d.workspaceDeviceKind(true, true), 'pc'); assert.equal(d.workspaceDeviceKind(false, true), 'tablet');
assert.equal(d.workspaceDeviceKind(false, false), 'phone');
assert.equal(d.workspaceEntryLimit('tablet'), 2); assert.equal(d.workspaceEntryLimit('pc'), 16); assert.equal(d.workspaceEntryLimit('phone'), 16);
assert.equal(d.workspaceUsableOnDevice('phone', false), false); assert.equal(d.workspaceUsableOnDevice('phone', true), true);
assert.equal(d.workspaceUsableOnDevice('tablet', false), true); assert.equal(d.workspaceUsableOnDevice('pc', false), true);
console.log('PASS Pro workspace validation, presets and device plans');
