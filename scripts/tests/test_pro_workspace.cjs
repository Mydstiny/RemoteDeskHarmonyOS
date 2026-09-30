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
console.log('PASS Pro workspace validation, presets and device plans');
