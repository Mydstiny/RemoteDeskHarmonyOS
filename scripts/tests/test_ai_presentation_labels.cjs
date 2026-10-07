'use strict';
// Remote AI details sheet (2026-10-07): modes in words, pending writes summarised, phone-friendly times.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require(process.env.AI_TYPESCRIPT_PATH || 'typescript');
const file = path.resolve(__dirname, '../../entry/src/main/ets/services/ai/AiPresentation.ets');
const loaded = { exports: {} };
const wire = { aiString: (v, f = '') => typeof v === 'string' ? v : f,
  aiRecord: (v) => { if (v === null || typeof v !== 'object' || Array.isArray(v)) throw new Error('AI_RESPONSE_INVALID'); return v; },
  aiArray: (v) => Array.isArray(v) ? v : [] };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText,
  { module: loaded, exports: loaded.exports, JSON, Date, require: (name) => name === './AiWirePolicy' ? wire : { aiContentText: () => '' } });
const p = loaded.exports;
assert.equal(p.aiModeLabel('read-only'), '只读');
assert.equal(p.aiModeLabel('workspace-write'), '可写工作区');
assert.equal(p.aiModeLabel('default'), '默认');
assert.equal(p.aiModeLabel('somethingNew'), 'somethingNew', 'an unknown mode keeps its name');
const body = (method) => JSON.stringify({ method, params: {}, operationId: 'x', epoch: 'e' });
assert.deepEqual(Array.from(p.aiOperationSummary(body('lease.renew'), JSON.stringify({ status: 'succeeded' }))), ['续期控制权', '已完成']);
assert.deepEqual(Array.from(p.aiOperationSummary(body('turn.start'), '')), ['发送任务', '结果待确认']);
assert.deepEqual(Array.from(p.aiOperationSummary(body('session.archive'), JSON.stringify({ status: 'rejected' }))), ['归档会话', '电脑端已拒绝']);
assert.deepEqual(Array.from(p.aiOperationSummary('not json', 'not json')), ['未知操作', '结果待确认']);
assert.match(p.aiShortTime(new Date(2026, 9, 7, 15, 5, 2).getTime()), /^10-07 15:05:02$/);
const page = fs.readFileSync(path.resolve(__dirname, '../../entry/src/main/ets/pages/RemoteAiWorkspace.ets'), 'utf8');
assert.ok(page.includes('ForEach(this.unsettledOperations(), (operation: AiPendingOperation): void => {'), 'renewals do not flood the list');
assert.ok(page.includes("this.chip({ label: this.permission !== '' ? aiModeLabel(this.permission) : '权限模式'"));
console.log('PASS remote AI labels: modes, pending writes and times read as words');
