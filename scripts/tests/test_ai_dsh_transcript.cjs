'use strict';
// DSH session events as @deepseek-ai/dsh-session declares them (types.d.ts SessionEventMap) and the DSH plugin
// forwards them: user/message is the message itself {id, role, content, source}, tool/call {callId, name,
// arguments: JSON string}, tool/result {message: {content: [{type: 'tool-result', toolCallId, content, isError}]},
// error?}, turn/end {reason: {kind}}. Runs the production mapper.
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
const { aiDshItems, AiTranscript } = load('AiTranscript', { './AiModels': models, './AiWirePolicy': wire });
const plain = value => JSON.parse(JSON.stringify(value));
const result = (callId, text, extra = {}) => ({ message: { id: 'm', role: 'user', source: { kind: 'tool', callId },
  content: [{ type: 'tool-result', toolCallId: callId, content: [{ type: 'text', text }], ...extra }] } });
// A user/message event's data: the UserMessage itself (dsh-session deriveEventMessage returns event.data).
const said = (text, source = { kind: 'user' }) => ({ id: 'm' + text.length, role: 'user', content: [{ type: 'text', text }], source });

const events = [
  { seq: 0, type: 'turn/start', data: { turn: 1 } },
  { seq: 1, type: 'user/message', data: said('跑一下测试'), surfaceOp: 'append' },
  { seq: 2, type: 'tool/call', data: { turn: 1, step: 0, callId: 'c1', name: 'bash', arguments: '{"command":"npm test"}' } },
  { seq: 3, type: 'tool/result', data: { turn: 1, step: 0, ...result('c1', '3 passing') }, surfaceOp: 'append' },
  { seq: 4, type: 'tool/call', data: { turn: 1, step: 1, callId: 'c2', name: 'edit',
    arguments: '{"file_path":"/r/a.ts","old_string":"a","new_string":"b"}' } },
  { seq: 5, type: 'tool/result', data: { turn: 1, step: 1, ...result('c2', 'no match', { isError: true }),
    error: { name: 'EditError', code: 'NO_MATCH' } }, surfaceOp: 'append' },
  { seq: 6, type: 'tool/call', data: { turn: 1, step: 2, callId: 'c3', name: 'read', arguments: '{"file_path":"/r/b.ts"' } },
  { seq: 7, type: 'assistant/message', data: { turn: 1, step: 2, message: { content: [{ type: 'text', text: '完成' }] } }, surfaceOp: 'append' },
  { seq: 8, type: 'turn/end', data: { turn: 1, reason: { kind: 'aborted', reason: 'user' } } },
];
const items = plain(aiDshItems(events));
assert.deepEqual(items.map(item => [item.kind, item.title, item.state]), [
  ['user', 'user', 'completed'],
  ['tool', 'bash', 'completed'],
  ['tool', 'edit', 'failed'],
  ['tool', 'read', 'interrupted'],
  ['assistant', 'assistant', 'completed']]);
// Results join their call: output shown once, arguments pretty-printed (or kept raw when they do not parse).
assert.equal(items[1].output, '3 passing');
assert.equal(items[1].detail, JSON.stringify({ command: 'npm test' }, null, 2));
assert.equal(items[2].output, 'no match');
assert.equal(items[3].detail, '{"file_path":"/r/b.ts"');
assert.equal(timeline.aiToolView(items[1]).target, 'npm test');
assert.equal(timeline.aiToolView(items[2]).stats, '+1 −1');
console.log('PASS DSH tool calls carry their results, arguments and final state');

// A result without its call (a page boundary) is still shown; surface replacements may name merged results.
const lone = plain(aiDshItems([{ seq: 9, type: 'tool/result', data: { turn: 2, ...result('gone', 'late output') } }]));
assert.deepEqual(lone.map(item => [item.title, item.output, item.state]), [['工具结果', 'late output', 'completed']]);
const replaced = plain(aiDshItems(events.slice(0, 4).concat([{ seq: 10, type: 'user/message',
  data: said('摘要'), surfaceOp: { op: 'replace', start: 1, end: 3 }, sourceEventSeqs: [1, 3] }])));
assert.deepEqual(replaced.map(item => item.text), ['摘要']);
assert.throws(() => aiDshItems([{ seq: 1, type: 'user/message', data: { turn: 1, message: 'x' },
  surfaceOp: { op: 'replace', start: 7, end: 8 } }]), /AI_SURFACE_RANGE_INVALID/);
console.log('PASS DSH results without calls show alone and replacements still find merged results');

// Live events are recorded and mapped once per flush; a range that cannot be placed is reported, not thrown.
const live = new AiTranscript();
events.forEach(event => live.dshEvent(event, true));
assert.equal(live.items.length, 0);
assert.equal(live.flush(), '');
assert.equal(live.items.length, 5);
live.dshEvent({ seq: 20, type: 'user/message', data: { turn: 3, message: 'x' }, surfaceOp: { op: 'replace', start: 30, end: 31 } }, true);
assert.equal(live.flush(), 'AI_SURFACE_RANGE_INVALID');
assert.equal(live.items.length, 5);
console.log('PASS DSH live events are mapped on flush and a bad replacement is reported');

// Streaming: text and reasoning deltas each grow one row; the assembled message (reasoning block, text block)
// replaces them; block markers and usage carry no text.
{
  const chunk = (seq, type, text, step = 0) => ({ seq, type: 'assistant/chunk', data: { turn: 4, step, chunk: { type, index: 0, text } } });
  const stream = [
    { seq: 1, type: 'user/message', data: said('解释一下') },
    { seq: 2, type: 'assistant/chunk', data: { turn: 4, step: 0, chunk: { type: 'block-start', index: 0, blockType: 'reasoning' } } },
    chunk(3, 'reasoning-delta', '先看'), chunk(4, 'reasoning-delta', '代码'),
    chunk(5, 'text-delta', '这是'), chunk(6, 'text-delta', '答案'),
    { seq: 7, type: 'assistant/chunk', data: { turn: 4, step: 0, chunk: { type: 'usage', usage: {} } } },
  ];
  let mapped = plain(aiDshItems(stream));
  assert.deepEqual(mapped.map(item => [item.kind, item.text, item.state]), [
    ['user', '解释一下', 'completed'], ['thinking', '先看代码', 'running'], ['assistant', '这是答案', 'running']]);
  stream.push({ seq: 8, type: 'assistant/message', data: { turn: 4, step: 0, message: { content: [
    { type: 'reasoning', text: '先看代码' }, { type: 'text', text: '这是答案' },
    { type: 'tool-call', id: 'c9', name: 'bash', arguments: '{}' }] } }, sourceEventSeqs: [2, 3, 4, 5, 6, 7] });
  mapped = plain(aiDshItems(stream));
  assert.deepEqual(mapped.map(item => [item.id, item.kind, item.text, item.state]), [
    ['dsh:1', 'user', '解释一下', 'completed'], ['dsh:8:r', 'thinking', '先看代码', 'completed'],
    ['dsh:8', 'assistant', '这是答案', 'completed']]);
  // A compaction naming the message removes its reasoning row too.
  stream.push({ seq: 9, type: 'user/message', data: said('摘要'), surfaceOp: { op: 'replace', start: 1, end: 8 } });
  assert.deepEqual(plain(aiDshItems(stream)).map(item => item.text), ['摘要']);
  console.log('PASS DSH streams one row per answer and reasoning, replaced by the assembled message');
}

// Context a plugin injected is part of the work, not the user's words; malformed fields are skipped.
{
  const injected = plain(aiDshItems([
    { seq: 1, type: 'user/message', data: said('# AGENTS.md\nrules…', { kind: 'plugin', plugin: 'dsh-agent-instructions' }) },
    { seq: 2, type: 'user/message', data: said('x', { kind: 'plugin', plugin: 'notice', form: 'notice', summary: '文件已变化' }) },
    { seq: 3, type: 'user/message', data: said('你好') },
    // Older logs wrapped the message; it still reads the same.
    { seq: 4, type: 'user/message', data: { turn: 1, message: said('[fixture] 上下文注入', { kind: 'plugin', plugin: 'fixture' }) } }]));
  assert.deepEqual(injected.map(item => [item.role, item.kind, item.title, item.text]), [
    ['execution', 'tool', '上下文', '# AGENTS.md'], ['execution', 'tool', '上下文', '文件已变化'], ['user', 'user', 'user', '你好'],
    ['execution', 'tool', '上下文', '[fixture] 上下文注入']]);
  assert.equal(injected[0].output, '# AGENTS.md\nrules…');
  const odd = [{ seq: 1, type: 'turn/end', data: { turn: 1 } }, { seq: 2, type: 'tool/result', data: { turn: 1 } },
    { seq: 3, type: 'tool/call', data: { turn: 1, callId: 5, name: 7, arguments: 9 } }, { seq: 4, type: 'assistant/message', data: { turn: 1, message: 'plain' } },
    { seq: 5, type: 'user/message', data: { turn: 1, message: 12 } }, { seq: 6, type: 'assistant/chunk', data: { turn: 1, chunk: 'x' } },
    { seq: 7, type: 'user/message', data: 'oops' }, { seq: 8, type: 'assistant/message', data: { turn: 1 }, surfaceOp: 'append' }];
  assert.doesNotThrow(() => aiDshItems(odd));
  assert.deepEqual(plain(aiDshItems(odd)).map(item => item.title), ['工具结果', '工具', 'assistant', 'user']);
  console.log('PASS DSH injected context reads as a step and malformed fields are skipped');
}

// Mapping event by event, in any batch sizes, equals mapping the whole log; a long session stays fast.
{
  const random = (n) => Math.floor(Math.random() * n);
  const session = (count) => {
    const events = []; let seq = 0; let turn = 0;
    while (events.length < count) {
      turn++;
      events.push({ seq: seq++, type: 'user/message', data: said('q' + turn, random(6) ? { kind: 'user' } : { kind: 'plugin', plugin: 'skills' }) });
      for (let step = 0; step < 1 + random(3); step++) {
        const chunks = [];
        for (let k = 0; k < 5 + random(30); k++) {
          chunks.push(seq);
          events.push({ seq: seq++, type: 'assistant/chunk', data: { turn, step, chunk: { type: random(4) ? 'text-delta' : 'reasoning-delta', text: 't' + k } } });
        }
        events.push({ seq: seq++, type: 'assistant/message', data: { turn, step, message: { content: [{ type: 'reasoning', text: 'r' }, { type: 'text', text: 'a' + step }] } }, sourceEventSeqs: chunks });
        const callId = 'c' + seq;
        events.push({ seq: seq++, type: 'tool/call', data: { turn, step, callId, name: 'bash', arguments: '{"command":"ls"}' } });
        events.push({ seq: seq++, type: 'tool/result', data: { turn, step, message: { content: [{ type: 'tool-result', toolCallId: callId, content: [{ type: 'text', text: 'ok' }] }] } } });
      }
      events.push({ seq: seq++, type: 'turn/end', data: { turn, reason: { kind: random(5) ? 'completed' : 'aborted' } } });
    }
    return events;
  };
  for (let round = 0; round < 20; round++) {
    const events = session(400);
    const live = new AiTranscript();
    let at = 0;
    while (at < events.length) {
      const size = 1 + random(40);
      events.slice(at, at + size).forEach(event => live.dshEvent(event, true));
      assert.equal(live.flush(), '');
      at += size;
    }
    assert.deepEqual(plain(live.items), plain(aiDshItems(events)), 'round ' + round);
  }
  // An event that arrives out of order (or again with other content) still yields the full mapping.
  const events = session(200);
  const shuffled = new AiTranscript();
  events.slice(100).forEach(event => shuffled.dshEvent(event, true)); shuffled.flush();
  events.slice(0, 100).forEach(event => shuffled.dshEvent(event, true)); shuffled.flush();
  assert.deepEqual(plain(shuffled.items), plain(aiDshItems(events)));
  const big = session(30000);
  const started = Date.now();
  const paged = new AiTranscript();
  for (let page = 0; page < big.length; page += 200) {
    big.slice(page, page + 200).forEach(event => paged.dshEvent(event, true));
    assert.equal(paged.flush(), '');
  }
  const elapsed = Date.now() - started;
  assert.ok(elapsed < 3000, '30k events mapped page by page in ' + elapsed + ' ms');
  console.log('PASS DSH maps incrementally like the whole log; 30k events in ' + elapsed + ' ms');
}
