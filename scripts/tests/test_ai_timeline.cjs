'use strict';
// Remote AI page styles (Claude Code / Codex): tool step summaries, diffs, Codex item mapping, palettes and the
// saved style. Runs the production modules; rendering is checked on devices.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require(process.env.AI_TYPESCRIPT_PATH || 'typescript');
const base = path.resolve(__dirname, '../../entry/src/main/ets/services/ai') + '/';
function load(name, mocks) {
  const module = { exports: {} };
  const source = ts.transpileModule(fs.readFileSync(base + name + '.ets', 'utf8'),
    { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInNewContext(source, { module, exports: module.exports, require: key => mocks[key] }, { filename: name });
  return module.exports;
}
const models = load('AiModels', { '../EndpointAddressPolicy': { parseEndpointHost: () => ({ ok: true }), parseEndpointServerIdentity: () => ({ ok: true }) } });
const wire = load('AiWirePolicy', { './AiModels': models, '@kit.ArkTS': { util: {} } });
const timeline = load('AiTimeline', { './AiModels': models });
const transcript = load('AiTranscript', { './AiModels': models, './AiWirePolicy': wire });
const palettes = load('AiStylePalette', { './AiModels': models });
const plain = value => JSON.parse(JSON.stringify(value));
const tool = (title, input, extra = {}) => ({ id: 'x', role: 'execution', title, text: '', state: 'completed', turnId: 't',
  kind: 'tool', detail: JSON.stringify(input), output: '', ...extra });

// Unified diffs: git headers, several files, hunks, metadata lines and the no-newline marker.
const diff = [
  'diff --git a/src/auth.ts b/src/auth.ts', 'index 1..2 100644', '--- a/src/auth.ts', '+++ b/src/auth.ts',
  '@@ -1,3 +1,3 @@', ' const a = 1;', '-const RETRY = 5;', '+const RETRY = 3;', '\\ No newline at end of file',
  'diff --git a/README.md b/README.md', 'new file mode 100644', '--- /dev/null', '+++ b/README.md', '@@ -0,0 +1,2 @@',
  '+# Title', '+text'].join('\n');
const files = plain(timeline.aiDiffFiles(diff));
assert.deepEqual(files.map(file => [file.path, file.added, file.removed]), [['src/auth.ts', 1, 1], ['README.md', 2, 0]]);
assert.deepEqual(files[0].lines.map(line => line.kind), ['hunk', 'context', 'del', 'add']);
assert.deepEqual(plain(timeline.aiDiffFiles('--- a/x.ts\n+++ b/x.ts\n@@ -1 +1 @@\n-a\n+b')).map(file => file.path), ['x.ts']);
assert.deepEqual(plain(timeline.aiDiffFiles('')), []);
assert.equal(timeline.aiDiffStats(0, 0), '');
assert.equal(timeline.aiDiffStats(12, 3), '+12 −3');
console.log('PASS unified diffs split by file with counted lines');

// Tool steps of the three engines read as verb + target (+ change counts).
const view = item => plain(timeline.aiToolView(item));
assert.deepEqual(view(tool('Bash', { command: 'npm test -- auth\nsecond line' })), { icon: 'terminal', verb: '运行', target: 'npm test -- auth', stats: '' });
assert.deepEqual(view(tool('Read', { file_path: '/repo/src/auth/login.ts' })), { icon: 'doc', verb: '读取', target: '…/auth/login.ts', stats: '' });
assert.deepEqual(view(tool('Write', { file_path: 'a.md', content: 'x\ny\n' })), { icon: 'edit', verb: '写入', target: 'a.md', stats: '+2' });
assert.deepEqual(view(tool('Edit', { file_path: 'src/a.ts', old_string: 'a\nb', new_string: 'c' })).stats, '+1 −2');
assert.deepEqual(view(tool('MultiEdit', { file_path: 'src/a.ts', edits: [{ old_string: 'a', new_string: 'b' }, { old_string: 'c', new_string: 'd\ne' }] })).stats, '+3 −2');
assert.equal(view(tool('Grep', { pattern: 'RETRY' })).target, 'RETRY');
assert.equal(view(tool('WebFetch', { url: 'https://example.com' })).icon, 'globe');
assert.equal(view(tool('UnknownTool', {}, { text: 'did a thing' })).verb, 'UnknownTool');
assert.equal(view(tool('', {}, { text: '' })).verb, '工具');
console.log('PASS Claude tool steps summarise as verb, target and counts');

// Codex thread items map to the same timeline (commands with output, file changes as diffs, reasoning, MCP).
const codex = raw => plain(transcript.aiCodexItem(raw, 'turn-1', 'completed'));
const command = codex({ id: 'c1', type: 'commandExecution', command: 'git status', cwd: '/repo', status: 'completed', exitCode: 0, aggregatedOutput: 'clean' });
assert.deepEqual([command.kind, command.text, command.output], ['tool', 'git status', 'clean']);
assert.deepEqual(view(command), { icon: 'terminal', verb: '运行', target: 'git status', stats: '' });
const change = codex({ id: 'f1', type: 'fileChange', status: 'completed', changes: [
  { path: 'a.ts', kind: { type: 'update' }, diff: '@@ -1 +1 @@\n-a\n+b' },
  { path: 'b.ts', kind: { type: 'add' }, diff: '@@ -0,0 +1 @@\n+new' }] });
assert.equal(change.kind, 'tool');
assert.deepEqual(view(change), { icon: 'edit', verb: '修改', target: '2 个文件', stats: '+2 −1' });
assert.deepEqual(plain(timeline.aiItemDiff(change)).map(file => file.path), ['a.ts', 'b.ts']);
assert.deepEqual([codex({ id: 'r', type: 'reasoning', summary: ['Plan the fix'] }).kind, codex({ id: 'r', type: 'reasoning', summary: ['Plan the fix'] }).text], ['thinking', 'Plan the fix']);
assert.deepEqual([codex({ id: 'm', type: 'agentMessage', text: 'Done' }).role, codex({ id: 'u', type: 'userMessage', content: [{ type: 'text', text: 'Hi' }] }).text], ['assistant', 'Hi']);
const mcp = codex({ id: 'p', type: 'mcpToolCall', server: 'docs', tool: 'search', arguments: { q: 'x' }, error: { message: 'boom' }, status: 'failed' });
assert.deepEqual([mcp.text, mcp.output, mcp.state], ['docs · search', 'boom', 'failed']);
assert.equal(codex({ id: 'w', type: 'webSearch', query: 'harmonyos' }).text, 'harmonyos');
assert.equal(codex({ id: 'z', type: 'imageView', path: 'a.png' }).kind, 'tool');
console.log('PASS Codex items map to conversation, thinking and tool steps');

// Conversation vs log split (Codex style tabs) and step states.
assert.equal(timeline.aiConversationItem({ role: 'user', kind: 'user' }), true);
assert.equal(timeline.aiConversationItem({ role: 'assistant', kind: 'assistant' }), true);
assert.equal(timeline.aiConversationItem({ role: 'execution', kind: 'notice' }), true);
assert.equal(timeline.aiConversationItem({ role: 'execution', kind: 'thinking' }), false);
assert.equal(timeline.aiConversationItem({ role: 'execution' }), false);
assert.deepEqual(['running', 'inProgress', 'completed', 'declined', 'interrupted', ''].map(timeline.aiStepState),
  ['running', 'running', 'ok', 'failed', 'failed', '']);
console.log('PASS conversation/log split and step states');

// Palettes: Claude classic and Codex neutral colours, both themes, all valid colours.
const claudeLight = plain(palettes.aiStylePalette('claude', false));
assert.equal(claudeLight.bg, '#F5F4EE'); assert.equal(claudeLight.accent, '#C96442');
assert.equal(plain(palettes.aiStylePalette('claude', true)).accent, '#D97757');
assert.equal(plain(palettes.aiStylePalette('codex', true)).bg, '#212121');
for (const style of ['claude', 'codex']) for (const dark of [false, true]) {
  const palette = plain(palettes.aiStylePalette(style, dark));
  assert.equal(Object.keys(palette).length, 18);
  for (const [key, value] of Object.entries(palette)) assert.match(value, /^#[0-9A-F]{6}$/, style + ' ' + key);
  assert.notEqual(palette.text, palette.bg); assert.notEqual(palette.addText, palette.delText);
}
console.log('PASS style palettes');

// The saved style: Claude by default, old settings without the field stay valid, unknown values are refused.
assert.equal(models.defaultAiSettings().uiStyle, 'claude');
const old = { showExecution: true, textSize: 15, reconnectOnForeground: true, defaultBackend: 'codex' };
assert.equal(models.aiSettingsValid(old), true);
assert.equal(models.aiUiStyle(old), 'claude');
assert.equal(models.aiUiStyle({ ...old, uiStyle: 'codex' }), 'codex');
assert.equal(models.aiSettingsValid({ ...old, uiStyle: 'codex' }), true);
assert.equal(models.aiSettingsValid({ ...old, uiStyle: 'material' }), false);
console.log('PASS saved page style');
