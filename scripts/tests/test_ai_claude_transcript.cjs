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
// The plugin numbers live events apart from the history it read (its live seq restarts at 0), so events keep their
// arrival order and are renumbered: history first, then live events, every item id unique.
const transcript = new AiTranscript();
transcript.claudeEvent({ seq: 0, type: 'user/message', data: { message: 'first' }, turn: 'h1' });
transcript.claudeEvent({ seq: 1, type: 'assistant/message', data: { message: 'second', kind: 'text' }, turn: 'h2' });
transcript.claudeEvent({ seq: 0, type: 'user/message', data: { message: 'third' }, turn: 'run' });
transcript.claudeEvent({ seq: 1, type: 'assistant/message', data: { message: 'fourth', kind: 'text' }, turn: 'run' });
assert.deepEqual(plain(transcript.items).map(item => item.role + ':' + item.text),
  ['user:first', 'assistant:second', 'user:third', 'assistant:fourth']);
assert.deepEqual(plain(transcript.items).map(item => item.id), ['claude:0', 'claude:1', 'claude:2', 'claude:3']);
transcript.clear();
assert.equal(transcript.items.length, 0);
console.log('PASS malformed Claude events are skipped and events keep their arrival order');

// History pages are recorded first and mapped once; a later flush maps nothing new.
const batched = new AiTranscript();
for (let index = 0; index < 50; index++) {
  batched.claudeEvent({ seq: index, type: index % 2 ? 'assistant/message' : 'user/message',
    data: { message: 'm' + index, kind: 'text' }, turn: 'h' + index }, true);
}
assert.equal(batched.items.length, 0);
assert.equal(batched.flush(), '');
assert.equal(batched.items.length, 50);
console.log('PASS deferred Claude events are mapped once on flush');

// A finished message replaces its turn's streamed chunks; dropping those chunks from the log changes nothing shown.
seq = 0;
const stream = [ev('turn/start', { id: 'run' }, 'run')];
for (let round = 0; round < 3; round++) {
  for (let index = 0; index < 20; index++) { stream.push(ev('assistant/chunk', { chunk: { text: 'r' + round + 'c' + index + ' ' } }, 'run')); }
  stream.push(ev('assistant/message', { message: 'round ' + round, kind: 'text' }, 'run'));
  stream.push(ev('tool/call', { id: 'tool' + round, name: 'Read', input: { file_path: '/a' + round } }, 'run'));
}
stream.push(ev('assistant/chunk', { chunk: { text: 'tail' } }, 'run'));
const compacted = new AiTranscript();
stream.forEach(event => compacted.claudeEvent(event, true));
compacted.flush();
assert.deepEqual(view(compacted.items), view(aiClaudeItems(stream)));
assert.deepEqual(view(compacted.items).slice(-1), [['assistant', 'tail', 'running']]);
console.log('PASS dropping replaced chunks keeps the mapped transcript identical');

// A sent prompt shows at once and sits before its turn's output; the engine's own copy replaces it.
const echoed = new AiTranscript();
echoed.claudeEvent({ seq: 0, type: 'turn/start', data: { id: 'run-1' }, turn: 'run-1' });
echoed.echo('Fix the login timeout', 'run-1');
assert.deepEqual(plain(echoed.items).map(item => item.role + ':' + item.text), ['user:Fix the login timeout']);
echoed.claudeEvent({ seq: 1, type: 'assistant/chunk', data: { chunk: { text: 'On it' } }, turn: 'run-1' });
assert.deepEqual(plain(echoed.items).map(item => item.role + ':' + item.text), ['user:Fix the login timeout', 'assistant:On it']);
echoed.claudeEvent({ seq: 2, type: 'user/message', data: { message: 'Fix the login timeout' }, turn: 'run-1' });
assert.deepEqual(plain(echoed.items).filter(item => item.role === 'user').map(item => item.id), ['claude:2']);
echoed.echo('   ', 'run-2');
assert.equal(plain(echoed.items).length, 2);
console.log('PASS sent prompts show at once and give way to the engine copy');

// The same words already in the history never stand for a new prompt: only a later engine event can.
const repeated = new AiTranscript();
repeated.claudeEvent({ seq: 0, type: 'user/message', data: { message: [{ type: 'text', text: '继续' }] }, turn: 'old' });
repeated.claudeEvent({ seq: 1, type: 'assistant/message', data: { message: '好的', kind: 'text' }, turn: 'old' });
repeated.echo('继续', 'run-9');
assert.deepEqual(plain(repeated.items).map(item => item.role + ':' + item.text), ['user:继续', 'assistant:好的', 'user:继续']);
repeated.claudeEvent({ seq: 0, type: 'assistant/chunk', data: { chunk: { text: '继续处理' } }, turn: 'run-9' });
assert.deepEqual(plain(repeated.items).map(item => item.role + ':' + item.text),
  ['user:继续', 'assistant:好的', 'user:继续', 'assistant:继续处理']);
// Two prompts of one turn keep their sending order and their own ids.
repeated.echo('再补充一句', 'run-9');
const echoes = plain(repeated.items).filter(item => item.id.startsWith('echo:'));
assert.deepEqual(echoes.map(item => item.text), ['继续', '再补充一句']);
assert.equal(new Set(echoes.map(item => item.id)).size, 2);
// A tool result of the same turn is not the prompt; the engine's own copy of the prompt is.
repeated.claudeEvent({ seq: 1, type: 'user/message', data: { message: [{ type: 'tool_result', tool_use_id: 'x', content: 'ok' }] }, turn: 'run-9' });
assert.equal(plain(repeated.items).filter(item => item.id.startsWith('echo:')).length, 2);
repeated.claudeEvent({ seq: 2, type: 'user/message', data: { message: [{ type: 'text', text: '继续' }] }, turn: 'run-9' });
assert.deepEqual(plain(repeated.items).filter(item => item.id.startsWith('echo:')).map(item => item.text), ['再补充一句']);
// A steered prompt has no turn id; the engine copy with the same words replaces it.
repeated.echo('改用 TypeScript', '');
assert.deepEqual(plain(repeated.items).slice(-1).map(item => item.text), ['改用 TypeScript']);
repeated.claudeEvent({ seq: 3, type: 'user/message', data: { message: [{ type: 'text', text: '改用 TypeScript' }] }, turn: 'run-9' });
assert.ok(!plain(repeated.items).some(item => item.id.startsWith('echo:') && item.text === '改用 TypeScript'));
console.log('PASS a prompt echo is replaced only by a later engine event, one for one, in sending order');

// The engine's copy may arrive before the acknowledgement: marked before sending, it still stands for the prompt.
{
  const early = new AiTranscript();
  early.claudeEvent({ seq: 0, type: 'assistant/message', data: { message: 'earlier', kind: 'text' }, turn: 'old' });
  const sentAt = early.mark();
  early.claudeEvent({ seq: 0, type: 'user/message', data: { message: [{ type: 'text', text: '修复登录' }] }, turn: 'run-2' });
  early.echo('修复登录', 'run-2', sentAt);
  assert.deepEqual(plain(early.items).map(item => item.role + ':' + item.text), ['assistant:earlier', 'user:修复登录']);
  assert.ok(!plain(early.items).some(item => item.id.startsWith('echo:')));
  // That copy is used up: the same words sent again show their own echo.
  early.echo('修复登录', 'run-3', early.mark());
  assert.equal(plain(early.items).filter(item => item.id.startsWith('echo:')).length, 1);
}
// A steered prompt (no turn id) sits where it was sent, not after everything that followed.
{
  const steered = new AiTranscript();
  steered.claudeEvent({ seq: 0, type: 'assistant/chunk', data: { chunk: { text: '处理中' } }, turn: 'run' });
  const sentAt = steered.mark();
  steered.echo('改用 TypeScript', '', sentAt);
  steered.claudeEvent({ seq: 1, type: 'tool/call', data: { id: 't1', name: 'Read', input: { file_path: '/a.ts' } }, turn: 'run' });
  steered.claudeEvent({ seq: 2, type: 'assistant/message', data: { message: '好的，改用 TypeScript', kind: 'text' }, turn: 'run' });
  assert.deepEqual(plain(steered.items).map(item => item.kind + ':' + (item.text || item.title)),
    ['user:改用 TypeScript', 'tool:Read', 'assistant:好的，改用 TypeScript']);
}
// Context the engine injects into the same turn (a hook, a skill) never stands for the prompt.
{
  const injected = new AiTranscript();
  injected.echo('部署到预发环境', 'run-7', injected.mark());
  injected.claudeEvent({ seq: 0, type: 'user/message', data: { message: [{ type: 'text', text: '<system-reminder>hook output</system-reminder>' }] }, turn: 'run-7' });
  assert.equal(plain(injected.items).filter(item => item.id.startsWith('echo:')).length, 1);
  // The engine's own copy with attachments added still does.
  injected.claudeEvent({ seq: 1, type: 'user/message', data: { message: [{ type: 'text', text: '部署到预发环境\n[附件 1]' }] }, turn: 'run-7' });
  assert.equal(plain(injected.items).filter(item => item.id.startsWith('echo:')).length, 0);
}
// Malformed events are skipped, not thrown.
{
  const odd = new AiTranscript();
  odd.echo('hello', 't', odd.mark());
  assert.doesNotThrow(() => odd.claudeEvent({ seq: 0, type: 'user/message', data: 'oops', turn: 't' }));
  assert.doesNotThrow(() => odd.claudeEvent({ seq: 1, type: 'user/message', turn: 't' }));
  assert.equal(plain(odd.items).filter(item => item.id.startsWith('echo:')).length, 1);
}
console.log('PASS early engine copies, steered prompts, injected context and malformed events');

// The backend table: Claude Agent is a third backend with its own port, name and validation.
assert.deepEqual(Array.from(models.AI_BACKENDS), ['codex', 'dsh', 'claudecode']);
assert.equal(models.aiBackendDefaultPort('claudecode'), 9445);
assert.equal(models.aiBackendName('claudecode'), 'Claude Agent');
assert.equal(models.emptyAiHost('owner-' + 'a'.repeat(64), 'h1', 'claudecode').port, 9445);
assert.equal(models.aiBackendValid('claude'), false);
assert.equal(models.aiSettingsValid({ ...models.defaultAiSettings(), defaultBackend: 'claudecode' }), true);
console.log('PASS Claude Agent backend table');
