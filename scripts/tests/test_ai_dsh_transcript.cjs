'use strict';
// DSH session events as @deepseek-ai/dsh-session declares them (types.d.ts SessionEventMap) and the DSH plugin
// forwards them: tool/call {callId, name, arguments: JSON string}, tool/result {message: {content: [{type:
// 'tool-result', toolCallId, content, isError}]}, error?}, turn/end {reason: {kind}}. Runs the production mapper.
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

const events = [
  { seq: 0, type: 'turn/start', data: { turn: 1 } },
  { seq: 1, type: 'user/message', data: { turn: 1, message: { content: [{ type: 'text', text: '跑一下测试' }] } }, surfaceOp: 'append' },
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
  data: { turn: 1, message: { content: [{ type: 'text', text: '摘要' }] } }, surfaceOp: { op: 'replace', start: 1, end: 3 },
  sourceEventSeqs: [1, 3] }])));
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
