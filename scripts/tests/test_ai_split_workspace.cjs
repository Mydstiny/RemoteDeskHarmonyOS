'use strict';
// Remote AI on Pad/PC (2026-10-07): the list beside the conversation (1:2), two conversations side by side (1:1)
// from ⋯ 分屏打开 or a workspace pair, and the pair references a workspace keeps.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.AI_TYPESCRIPT_PATH || 'typescript');
const ETS = path.resolve(__dirname, '../../entry/src/main/ets');
const read = (file) => fs.readFileSync(path.join(ETS, file), 'utf8');
const module_ = { exports: {} };
vm.runInNewContext(ts.transpileModule(read('services/ai/AiWorkspacePairPolicy.ets'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText,
  { module: module_, exports: module_.exports });
const pair = module_.exports;

assert.equal(pair.aiPairRef('h1', 's1', ''), 'ai:h1@s1');
assert.equal(pair.aiPairRef('h1', '', ''), 'ai:h1');
assert.equal(pair.aiPairRef('h1', '', 'ai:h1'), 'ai:h1#2', 'the same host twice stays two entries');
assert.equal(pair.aiPairRef('h1', 's1', 'ai:h1@s1'), 'ai:h1@s1#2');
assert.deepEqual({ ...pair.aiPairTarget('ai:h1@s1#2') }, { hostId: 'h1', sessionId: 's1' });
assert.deepEqual({ ...pair.aiPairTarget('ai:h1') }, { hostId: 'h1', sessionId: '' });
assert.equal(pair.aiPairTarget('rdp:x'), null);
assert.equal(pair.aiPairTarget('ai:../x'), null);

const page = read('pages/RemoteAiWorkspace.ets');
// One view per host: phone / pane = list then conversation; Pad/PC = list (34%) beside the conversation.
assert.ok(page.includes("private wide(): boolean { return this.layout === 'auto' && (this.isPadDevice || this.isDesktopDevice) && this.pageWidth >= 600; }"));
assert.ok(page.includes("Column() { this.sidebar() }.width('34%').height('100%')"));
assert.ok(page.includes("if (this.sessionId === '' && this.wide()) {\n          ListItem() { this.splitPlaceholder() }"));
assert.ok(page.includes('this.wide() && session.id === this.sessionId ? this.palette().surface : Color.Transparent'));
// The page: one view, or two (1:1) each with its own connection; ⋯ opens the second and saves the pair.
const entry = page.slice(page.indexOf('@Entry'));
assert.ok(entry.includes('struct RemoteAiWorkspacePage'));
assert.equal((entry.match(/layout: 'pane'/g) || []).length, 2);
assert.equal((entry.match(/\.layoutWeight\(1\)\.height\('100%'\)/g) || []).length, 2);
assert.ok(entry.includes("this.secondHost = params['hostId2'] ?? ''"));
assert.ok(page.includes("items.push({ value: '分屏打开「' + host.label + '」'"));
assert.ok(page.includes("items.push({ value: '保存为工作区组合'"));
assert.ok(entry.includes("newWorkspaceEntry(firstRef, 'ai', 0), newWorkspaceEntry(secondRef, 'ai', 1)"));
// A workspace of one or two AI entries opens that page directly.
const host = fs.readFileSync(path.join(ETS, 'pages/HostListPage.ets'), 'utf8');
assert.ok(host.includes("params['hostId2'] = secondTarget.hostId; params['sessionId2'] = secondTarget.sessionId;"));
assert.ok(host.includes("if (host.protocol === 'ai') { return host.username; }"), 'a Pi host is not labelled Codex');
console.log('PASS remote AI split view, side-by-side pair and workspace pairs');
