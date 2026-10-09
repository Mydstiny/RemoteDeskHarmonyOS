/* 工作区连接后步骤 (plan 2026-10-09 §3): steps are optional on SSH entries (older versions still read the workspace),
 * strictly validated, resolved against what is saved now (gone or input-needing references are 已失效), run in order
 * with 上一步成功才继续, paused/skipped/retried/cancelled; the SSH page fences every step and asks before auto-run. */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');
const cache = {};
function load(relative) {
  if (cache[relative]) { return cache[relative]; }
  const file = path.join(root, relative);
  const module = { exports: {} };
  const source = ts.transpileModule(read(relative), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  vm.runInNewContext(source, { module, exports: module.exports, Set, require: id => {
    if (id === './WorkspacePolicy') { return load('entry/src/main/ets/services/pro/workspace/WorkspacePolicy.ets'); }
    throw new Error('workspace step policy must stay pure: unexpected import ' + id);
  }}, { filename: file });
  cache[relative] = module.exports;
  return module.exports;
}
const w = load('entry/src/main/ets/services/pro/workspace/WorkspacePolicy.ets');
const p = load('entry/src/main/ets/services/pro/workspace/WorkspaceStepPolicy.ets');
let passed = 0;
function check(name, body) { body(); passed++; console.log('PASS ' + name); }
const plain = (v) => JSON.parse(JSON.stringify(v));
const step = (extra) => ({ kind: 'cd', ref: '', path: '/srv', execute: false, requirePrevious: false, ...extra });

check('schema stays 1; steps optional, SSH only, strict keys, at most 8', () => {
  assert.equal(w.WORKSPACE_SCHEMA_VERSION, 1);
  const ws = w.newWorkspace('id1', '开发', '#007DFF', 'sym.desktop_fill', 0, 1);
  ws.entries = [w.newWorkspaceEntry('h1', 'ssh', 0), w.newWorkspaceEntry('h2', 'rdp', 1)];
  assert.deepEqual(plain(w.validateWorkspace(ws)), []);
  ws.entries[0].steps = [step({}), step({ kind: 'forward', ref: 'f1', path: '' }),
    step({ kind: 'snippet', ref: 's1', path: '', execute: true, requirePrevious: true })];
  assert.deepEqual(plain(w.validateWorkspace(ws)), []);
  const bad = (s, protocol = 'ssh') => w.validateWorkspaceSteps(protocol, [s]);
  assert.equal(bad(step({ path: 'relative' })), false);
  assert.equal(bad(step({ execute: true })), false, 'cd never "executes" a command of its own');
  assert.equal(bad(step({ kind: 'forward', ref: '', path: '' })), false);
  assert.equal(bad(step({ kind: 'forward', ref: 'f', path: '', execute: true })), false);
  assert.equal(bad(step({ kind: 'snippet', ref: 's', path: '/x' })), false);
  assert.equal(bad(step({ kind: 'shell', ref: 'rm -rf /', path: '' })), false, 'no free-form command kind');
  assert.equal(bad({ ...step({}), extra: 1 }), false);
  assert.equal(bad(step({ path: '/a\u0007' })), false);
  assert.equal(bad(step({}), 'rdp'), false);
  assert.equal(w.validateWorkspaceSteps('ssh', Array.from({ length: 9 }, () => step({}))), false);
  assert.equal(w.validateWorkspaceSteps('ssh', undefined), true);
  const copied = w.copyWorkspace(ws);
  assert.deepEqual(JSON.parse(JSON.stringify(copied.entries[0].steps)), JSON.parse(JSON.stringify(ws.entries[0].steps)));
  copied.entries[0].steps[0].path = '/changed';
  assert.equal(ws.entries[0].steps[0].path, '/srv', 'copies are deep');
  assert.equal(copied.entries[1].steps, undefined);
});

check('resolving: gone or input-needing references are 已失效 up front; labels say what will happen', () => {
  const run = p.workspaceStepRunFor('ws', '开发', 5, 'h1', [step({}), step({ kind: 'forward', ref: 'gone', path: '' }),
    step({ kind: 'snippet', ref: 'v', path: '' }), step({ kind: 'snippet', ref: 'ok', path: '', execute: true })],
    [{ id: 'f1', title: '本地 127.0.0.1:8080', usable: true }],
    [{ id: 'v', title: '带变量', usable: false }, { id: 'ok', title: '重启服务', usable: true }]);
  assert.deepEqual(plain(run.items.map((i) => i.state)), ['pending', 'invalid', 'invalid', 'pending']);
  assert.equal(run.items[0].label, '进入目录 /srv');
  assert.equal(run.items[1].label, '启用转发 （已失效）');
  assert.match(run.items[2].message, /需要填写变量或含密钥/);
  assert.equal(run.items[3].label, '执行命令 重启服务');
  assert.equal(p.workspaceStepsNeedConfirmation(run), true);
  assert.match(p.workspaceStepPreview(run), /^1\. 进入目录 \/srv\n2\. 启用转发 （已失效）（已失效，不会执行）/);
  assert.equal(p.workspaceStepPreviewKey('ws', 5.7, 'h1'), 'ws|5|h1');
});

check('order, 上一步成功才继续, pause, skip, retry, cancel', () => {
  let run = p.workspaceStepRunFor('ws', '开发', 1, 'h1', [step({}), step({ kind: 'forward', ref: 'f1', path: '' }),
    step({ path: '/b', requirePrevious: true }), step({ path: '/c' })], [{ id: 'f1', title: 'F', usable: true }], []);
  let pick = p.nextWorkspaceStep(run); assert.equal(pick.index, 0);
  run = p.setWorkspaceStepState(pick.run, 0, 'running', '');
  assert.equal(p.nextWorkspaceStep(run).index, -1, 'one step at a time');
  run = p.setWorkspaceStepState(run, 0, 'done', '');
  pick = p.nextWorkspaceStep(run); assert.equal(pick.index, 1);
  run = p.setWorkspaceStepState(pick.run, 1, 'failed', '端口被占用');
  pick = p.nextWorkspaceStep(run);
  assert.equal(pick.index, 3, 'the dependent step is skipped, the independent one runs');
  assert.equal(pick.run.items[2].state, 'skipped');
  run = p.setWorkspaceStepState(pick.run, 3, 'done', '');
  assert.equal(p.workspaceStepRunFinished(run), true);
  assert.equal(p.workspaceStepRunSummary(run), '2 步完成 · 1 步失败 · 1 步跳过');
  run = p.retryWorkspaceSteps(run);
  assert.deepEqual(plain(run.items.map((i) => i.state)), ['done', 'pending', 'pending', 'done']);
  run = p.setWorkspaceStepRunPaused(run, true);
  assert.equal(p.nextWorkspaceStep(run).index, -1);
  run = p.skipNextWorkspaceStep(p.setWorkspaceStepRunPaused(run, false));
  assert.equal(run.items[1].state, 'skipped');
  run = p.cancelWorkspaceStepRun(run, '已取消');
  assert.equal(run.items[2].state, 'skipped');
  assert.equal(p.retryWorkspaceSteps(run), run, 'a cancelled run stays cancelled');
  assert.equal(p.nextWorkspaceStep(run).index, -1);
});

check('cd quotes the path so the shell reads nothing in it', () => {
  assert.equal(p.workspaceStepCdCommand('/srv/my app'), "cd -- '/srv/my app'");
  assert.equal(p.workspaceStepCdCommand("/x/it's;rm -rf $HOME"), "cd -- '/x/it'\\''s;rm -rf $HOME'");
});

check('handoff and runner: staged per host with the workspace version, fenced, confirmed, cancelled on disconnect', () => {
  const handoff = read('entry/src/main/ets/services/pro/workspace/WorkspaceHandoff.ets');
  assert.match(handoff, /stageSteps\(hostId: string, staged: WorkspaceStagedSteps/);
  assert.match(handoff, /this\.steps = this\.steps\.filter\(\(item: StagedSteps\): boolean => item\.hostId !== hostId\);\n  \}/);
  const list = read('entry/src/main/ets/pages/HostListPage.ets');
  assert.match(list, /handoff\.stage\(host\.id, sshView, frame\);\s*if \(entry !== null && host\.protocol === 'ssh' && entry\.steps !== undefined[\s\S]{0,300}handoff\.stageSteps\(host\.id/);
  const ssh = read('entry/src/main/ets/pages/SshTerminal.ets');
  assert.match(ssh, /void this\.restoreProWorkspaceView\(bindingHostId\);\s*void this\.startProWorkspaceSteps\(bindingHostId\);/);
  assert.match(ssh, /if \(firstRun \|\| confirm\) \{[\s\S]{0,700}answer\.index !== 1[\s\S]{0,200}cancelWorkspaceStepRun\(run, '你选择了不执行'\)/);
  for (const reason of ['会话已断开', '会话已切换', 'Pro 不可用', '工作区已删除或账号已切换', '工作区已修改']) {
    assert.ok(ssh.includes("'" + reason + "'"), reason);
  }
  assert.match(ssh, /const reason: string = this\.proWorkspaceStepStopReason\(run\);/);
  assert.match(ssh, /this\.sendTerminalBytes\(workspaceStepCdCommand\(item\.path\) \+ '\\r', true\);/);
  assert.match(ssh, /this\.sendTerminalBytes\(rendered\.insertion \+ \(item\.execute \? '\\r' : ''\), item\.execute\);/);
  assert.match(ssh, /this\.sshForwardingController\.start\(handle, profile\)/);
  assert.match(ssh, /if \(!this\.connected && this\.proWorkspaceStepRun !== null &&[\s\S]{0,120}this\.cancelProWorkspaceSteps\('已停止：会话已断开'\);/);
  assert.match(ssh, /WorkspaceStepRunCard\(\{/);
  const editor = read('entry/src/main/ets/components/ProWorkspaceEditorPanel.ets');
  assert.match(editor, /this\.entrySteps\(entry\)/);
  assert.match(editor, /this\.chip\('自动执行'/);
  assert.match(editor, /this\.chip\('上一步成功才继续'/);
  assert.match(editor, /if \(!target\.usable\) \{ return; \}/);
});

check('catalog and AI knowledge', () => {
  assert.match(read('entry/src/main/ets/services/pro/ProFeatureCatalog.ets'), /连接后步骤（启用转发、进入目录、插入常用命令）/);
  assert.match(read('entry/src/main/ets/services/diagnosticAi/DiagnosticAiKnowledgeBase.ets'), /'工作区连接后步骤（Pro）：/);
});

console.log(passed + ' passed');
