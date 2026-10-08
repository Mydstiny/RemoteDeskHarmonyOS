const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
function load(relative, mocks = {}) {
  const file = path.join(root, relative); const module = { exports: {} };
  const source = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInNewContext(source, { module, exports: module.exports, require: id => {
    if (mocks[id]) return mocks[id]; if (id.startsWith('.')) return load(path.relative(root, path.resolve(path.dirname(file), id + '.ets')), mocks);
    throw new Error('unexpected import ' + id);
  }}, { filename: file }); return module.exports;
}
const capture = load('entry/src/main/ets/services/pro/workspace/WorkspaceCapture.ets');
const sessions = [
  { hostRef: ' h1 ', protocol: 'ssh', autoConnect: true, view: { sshPane: 'files', sshDirectory: '/srv', monitor: 0, scale: 1, panX: 0, panY: 0, inputMode: 'direct' } },
  { hostRef: 'h2', protocol: 'rdp', frame: { x: 0.5, y: 0, w: 0.5, h: 1, fullscreen: false } }
];
const workspace = capture.captureWorkspace('ws', 'Saved', '#007DFF', 'desktop', sessions, 'split', 10);
assert.equal(JSON.stringify(workspace.entries.map(entry => entry.hostRef)), JSON.stringify(['h1', 'h2']));
assert.equal(workspace.entries[0].view.sshDirectory, '/srv');
assert.equal(workspace.entries[1].view.sshPane, 'terminal');
assert.equal(workspace.entries[1].frame.w, 0.5);
assert.throws(() => capture.captureWorkspace('', 'Saved', '#007DFF', 'desktop', []), /invalid_workspace_capture/);
console.log('PASS workspace capture preserves safe views and frames');
