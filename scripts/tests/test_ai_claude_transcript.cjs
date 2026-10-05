'use strict';
// Claude Agent event contract (remotedesk-claudecode-plugin src/claude-adapter.mjs): live turns stream text chunks
// and then repeat the whole message, tool results arrive as user messages of tool_result blocks, and stored history
// has one event per message with every block inside. Runs the production mapper in AiTranscript.ets.
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
const { aiClaudeItems, AiTranscript } = load('AiTranscript', { './AiModels': models, './AiWirePolicy': wire });
const plain = value => JSON.parse(JSON.stringify(value));
const view = items => plain(items).map(item => [item.kind, item.text, item.state]);
let seq = 0;
const ev = (type, data, turn = 't1') => ({ seq: seq++, type, data, turn });

// Live turn: chunks, then the whole text; a tool call and its result; more text; the turn ends.
seq = 0;
const live = [
  ev('turn/start', { id: 't1' }),
  ev('assistant/chunk', { chunk: { text: 'Look' } }), ev('assistant/chunk', { chunk: { text: 'ing…' } }),
  ev('assistant/message', { message: 'Looking…', kind: 'text' }),
  ev('assistant/message', { message: '', kind: 'thinking' }),
  ev('tool/call', { id: 'u1', name: 'Bash', input: { command: 'npm test' } }),
  ev('user/message', { message: [{ type: 'tool_result', tool_use_id: 'u1', content: [{ type: 'text', text: 'ok 3 tests' }] }] }),
  ev('assistant/chunk', { chunk: { text: 'All ' } }),
];
let items = aiClaudeItems(live);
assert.deepEqual(view(items), [
  ['assistant', 'Looking…', 'completed'],
  ['tool', '', 'completed'],
  ['assistant', 'All ', 'running']]);
assert.equal(plain(items)[1].title, 'Bash');
assert.equal(plain(items)[1].output, 'ok 3 tests');
assert.ok(plain(items)[1].detail.includes('npm test'));
live.push(ev('assistant/message', { message: 'All tests pass.', kind: 'text' }), ev('turn/end', { status: 'completed', result: 'All tests pass.' }));
items = aiClaudeItems(live);
assert.deepEqual(view(items), [
  ['assistant', 'Looking…', 'completed'], ['tool', '', 'completed'], ['assistant', 'All tests pass.', 'completed']]);
console.log('PASS live chunks are replaced by the whole message and tool results join their call');

// A tool still running when the turn is interrupted ends with the turn; refused tools and errors are notices.
seq = 0;
items = aiClaudeItems([
  ev('tool/call', { id: 'u2', name: 'Edit', input: { file_path: 'a.ts' } }),
  ev('tool/result', { name: 'Bash', denied: true, message: 'Denied by user' }),
  ev('error', { code: 'CLAUDE_API_KEY_REQUIRED' }),
  ev('turn/end', { status: 'interrupted', result: '' }),
]);
assert.deepEqual(view(items).map(row => row[0] + ':' + row[2]), ['tool:interrupted', 'tool:declined', 'notice:failed']);
assert.equal(plain(items)[1].output, 'Denied by user');
assert.ok(plain(items)[2].text.includes('Anthropic API Key'));
seq = 0;
items = aiClaudeItems([ev('turn/end', { status: 'failed', result: 'Credit balance is too low' })]);
assert.deepEqual(view(items), [['notice', 'Credit balance is too low', 'failed']]);
console.log('PASS interrupted, refused and failed turns are shown without running leftovers');

// Stored history: one event per message; tool_use and thinking live inside the message content.
seq = 0;
items = aiClaudeItems([
  ev('user/message', { message: { role: 'user', content: 'Fix the login timeout' }, text: 'Fix the login timeout' }, 'm1'),
  ev('assistant/message', { message: { role: 'assistant', content: [
    { type: 'thinking', thinking: 'Check retry interval' }, { type: 'text', text: 'Reading the auth module.' },
    { type: 'tool_use', id: 'h1', name: 'Read', input: { file_path: 'src/auth.ts' } }] } }, 'm2'),
  ev('user/message', { message: { role: 'user', content: [
    { type: 'tool_result', tool_use_id: 'h1', content: 'export const RETRY = 5;', is_error: false }] } }, 'm3'),
  ev('assistant/message', { message: { role: 'assistant', content: [{ type: 'tool_use', id: 'h2', name: 'Bash', input: { command: 'false' } }] } }, 'm4'),
  ev('user/message', { message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'h2', content: 'exit 1', is_error: true }] } }, 'm5'),
  ev('assistant/message', { message: { role: 'assistant', content: [{ type: 'tool_use', id: 'h3', name: 'Grep', input: {} }] } }, 'm6'),
]);
assert.deepEqual(view(items), [
  ['user', 'Fix the login timeout', 'completed'], ['thinking', 'Check retry interval', 'completed'],
  ['assistant', 'Reading the auth module.', 'completed'], ['tool', '', 'completed'], ['tool', '', 'failed'], ['tool', '', '']]);
assert.equal(plain(items)[3].output, 'export const RETRY = 5;');
console.log('PASS stored history maps text, thinking, tools and their results');

// Malformed events never throw and never become items; the transcript orders events by sequence number.
seq = 0;
assert.deepEqual(plain(aiClaudeItems([ev('assistant/chunk', 'oops'), ev('assistant/chunk', { chunk: ['x'] }),
  ev('user/message', { message: 42 }), ev('unknown/type', {})])), []);
const transcript = new AiTranscript();
transcript.claudeEvent({ seq: 2, type: 'assistant/message', data: { message: 'second', kind: 'text' }, turn: 't' });
transcript.claudeEvent({ seq: 1, type: 'user/message', data: { message: 'first' }, turn: 't' });
transcript.claudeEvent({ seq: -1, type: 'user/message', data: { message: 'ignored' }, turn: 't' });
assert.deepEqual(plain(transcript.items).map(item => item.role + ':' + item.text), ['user:first', 'assistant:second']);
transcript.clear();
assert.equal(transcript.items.length, 0);
console.log('PASS malformed Claude events are skipped and events are ordered by sequence');

// The backend table: Claude Agent is a third backend with its own port, name and validation.
assert.deepEqual(Array.from(models.AI_BACKENDS), ['codex', 'dsh', 'claudecode']);
assert.equal(models.aiBackendDefaultPort('claudecode'), 9445);
assert.equal(models.aiBackendName('claudecode'), 'Claude Agent');
assert.equal(models.emptyAiHost('owner-' + 'a'.repeat(64), 'h1', 'claudecode').port, 9445);
assert.equal(models.aiBackendValid('claude'), false);
assert.equal(models.aiSettingsValid({ ...models.defaultAiSettings(), defaultBackend: 'claudecode' }), true);
console.log('PASS Claude Agent backend table');
