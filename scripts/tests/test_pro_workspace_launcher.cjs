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
const p = load('entry/src/main/ets/services/pro/workspace/WorkspacePolicy.ets');
const launcher = load('entry/src/main/ets/services/pro/workspace/WorkspaceLauncher.ets', { '../ProEntries': { ProEntries: { visible: () => true } } });
const view = p.defaultWorkspaceView();
const workspace = { schemaVersion: 1, id: 'ws', name: 'Daily', color: '#007DFF', icon: 'desktop', order: 0,
  entries: [0, 1, 2].map((i) => ({ hostRef: 'h' + i, protocol: 'ssh', order: i, autoConnect: true, view })), layout: 'split', updatedAt: 1 };
const seen = []; const adapter = { open: async (item) => { seen.push(item.hostRef); if (item.hostRef === 'h1') throw new Error('offline'); } };
(async () => {
  const result = await new launcher.WorkspaceLauncher().launch(workspace, 'phone', adapter);
  assert.deepEqual(result.map((item) => item.state), ['connected', 'failed', 'connected']);
  assert.deepEqual(seen, ['h0', 'h1', 'h2']);
  console.log('PASS workspace launcher isolates failures and preserves order');
})().catch((error) => { console.error(error); process.exitCode = 1; });
