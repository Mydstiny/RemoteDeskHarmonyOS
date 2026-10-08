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
  // An added file carries its content (Codex app-server FileChange.diff for add/delete), not a diff.
  { path: 'b.ts', kind: { type: 'add' }, diff: 'new' }] });
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

// DSH names its tools in lower case and passes the model's raw arguments; they read like the Claude tools.
assert.deepEqual(plain(timeline.aiToolView(tool('bash', { command: 'npm test\nnpm run lint' }))),
  { icon: 'terminal', verb: '运行', target: 'npm test', stats: '' });
assert.deepEqual(plain(timeline.aiToolView(tool('edit', { file_path: '/repo/src/a.ts', old_string: 'x\ny', new_string: 'z' }))),
  { icon: 'edit', verb: '修改', target: '…/src/a.ts', stats: '+1 −2' });
assert.equal(timeline.aiToolView(tool('write', { file_path: '/repo/b.md', content: 'one\ntwo\n' })).stats, '+2');
assert.equal(timeline.aiToolView(tool('web_search', { queries: ['harmonyos passkey', 'ctap2'] })).target, 'harmonyos passkey');
assert.equal(timeline.aiToolView(tool('read', { file_path: '/repo/c.ts' })).verb, '读取');
assert.deepEqual(plain(timeline.aiItemDiff(tool('str_replace_editor', { command: 'create', path: '/r/new.ts', file_text: 'a\nb' })))
  .map(file => [file.path, file.added, file.removed]), [['/r/new.ts', 2, 0]]);
assert.equal(timeline.aiToolView(tool('str_replace_editor', { command: 'view', path: '/r/x.ts' })).verb, '读取');
console.log('PASS DSH tool names and arguments');

// Remote text is untrusted: CRLF diffs, huge files and pathological header lines stay bounded and fast.
const crlf = plain(timeline.aiDiffFiles('diff --git a/a b c.txt b/a b c.txt\r\n@@ -1 +1 @@\r\n-old\r\n+new\r\n'));
assert.deepEqual(crlf.map(file => [file.path, file.added, file.removed]), [['a b c.txt', 1, 1]]);
assert.deepEqual(crlf[0].lines.map(line => line.text), ['@@ -1 +1 @@', 'old', 'new']);
let started = Date.now();
timeline.aiDiffFiles('diff --git a/' + ' b/x'.repeat(15000) + '\r');
assert.ok(Date.now() - started < 200, 'a long git header parses in linear time');
const huge = Array.from({ length: 60000 }, (_value, index) => 'line ' + index).join('\n');
const written = plain(timeline.aiItemDiff(tool('Write', { file_path: '/big.txt', content: huge })))[0];
assert.equal(written.added, 60000);
assert.equal(written.lines.length, 4000);
assert.equal(written.truncated, true);
const unified = plain(timeline.aiDiffFiles('diff --git a/x b/x\n@@ -1 +1 @@\n' + Array.from({ length: 5000 }, () => '+y').join('\n')));
assert.equal(unified[0].lines.length, 4000);
assert.equal(unified[0].truncated, true);
console.log('PASS diffs from remote text are bounded and parse in linear time');

// Codex added and deleted files carry their content, so lines starting with + or - are content, not diff marks.
const added = plain(transcript.aiCodexItem({ id: 'f', type: 'fileChange', status: 'completed',
  changes: [{ path: 'notes.md', kind: { type: 'add' }, diff: '- a list item\n+ not a diff\nplain\n' },
    { path: 'old.txt', kind: 'delete', diff: 'gone\n' }] }, 't'));
assert.deepEqual(plain(timeline.aiDiffFiles(added.output)).map(file => [file.path, file.added, file.removed]),
  [['notes.md', 3, 0], ['old.txt', 0, 1]]);
console.log('PASS Codex added and deleted files count every line');

// Hunk counts tell content from headers: content lines that start with '++ ' or '-- ' keep counting.
{
  const sql = plain(timeline.aiDiffFiles(['diff --git a/a.sql b/a.sql', '--- a/a.sql', '+++ b/a.sql', '@@ -1,3 +1,3 @@',
    '--- old comment', ' select 1;', '-select 2;', '+++ new comment', '+select 3;', ' end;'].join('\n')));
  assert.deepEqual(sql.map(file => [file.path, file.added, file.removed]), [['a.sql', 2, 2]]);
  const added = plain(transcript.aiCodexItem({ id: 'g', type: 'fileChange', status: 'completed', changes: [
    { path: 'lua.lua', kind: { type: 'add' }, diff: '-- comment\n++ counter\n@@ not a hunk\nprint(1)\n' }] }, 't'));
  assert.deepEqual(plain(timeline.aiDiffFiles(added.output)).map(file => [file.path, file.added, file.removed]), [['lua.lua', 4, 0]]);
  // A header line that is content of a hunk does not open a new file; the next git header does.
  const two = plain(timeline.aiDiffFiles(['diff --git a/x b/x', '@@ -1 +1 @@', '-a', '+b', 'diff --git a/y b/y', '@@ -0,0 +1 @@', '+c'].join('\n')));
  assert.deepEqual(two.map(file => [file.path, file.added, file.removed]), [['x', 1, 1], ['y', 1, 0]]);
  console.log('PASS diffs follow hunk counts, so content that looks like a header stays content');
}

// The diff signature changes with the content even when the counts stay the same.
{
  const a = timeline.aiDiffFiles('diff --git a/c b/c\n@@ -1 +1 @@\n-RETRY = 5\n+RETRY = 6');
  const b = timeline.aiDiffFiles('diff --git a/c b/c\n@@ -1 +1 @@\n-RETRY = 5\n+RETRY = 7');
  assert.notEqual(timeline.aiDiffSignature(a), timeline.aiDiffSignature(b));
  assert.equal(timeline.aiDiffSignature(a), timeline.aiDiffSignature(timeline.aiDiffFiles('diff --git a/c b/c\n@@ -1 +1 @@\n-RETRY = 5\n+RETRY = 6')));
  assert.equal(timeline.aiToolView(tool('job_output', { job_id: 'job-7' })).target, 'job-7');
  assert.deepEqual([timeline.aiToolView(tool('pwsh', { command: 'Get-ChildItem' })).verb, timeline.aiToolView(tool('pwsh', { command: 'Get-ChildItem' })).target],
    ['运行', 'Get-ChildItem']);
  console.log('PASS diff signatures follow content; job_output and pwsh read like their Claude tools');
}

// Binary patches show as a binary file; long lines that differ after their first 256 characters sign differently;
// a new file whose first line looks like a header is content.
{
  const binary = plain(timeline.aiDiffFiles(['diff --git a/logo.png b/logo.png', 'index 1..2 100644', 'GIT binary patch',
    'literal 1234', 'zcmV-uz1A2=K~#7F', '', 'literal 0', 'HcmV?d00001', '', 'diff --git a/a.txt b/a.txt', '@@ -1 +1 @@', '-a', '+b'].join('\n')));
  assert.deepEqual(binary.map(file => [file.path, file.added, file.removed, file.lines.length]), [['logo.png', 0, 0, 1], ['a.txt', 1, 1, 3]]);
  assert.equal(binary[0].lines[0].text, '（二进制文件）');
  const long = suffix => timeline.aiDiffFiles('diff --git a/m.js b/m.js\n@@ -1 +1 @@\n-' + 'x'.repeat(300) + 'v1' + 'y'.repeat(100) +
    '\n+' + 'x'.repeat(300) + suffix + 'y'.repeat(100));
  assert.notEqual(timeline.aiDiffSignature(long('v2')), timeline.aiDiffSignature(long('v3')));
  const titled = plain(transcript.aiCodexItem({ id: 'h', type: 'fileChange', status: 'completed', changes: [
    { path: 'notes.md', kind: { type: 'add' }, diff: '--- title\nbody\n' }] }, 't'));
  assert.deepEqual(plain(timeline.aiDiffFiles(titled.output)).map(file => [file.path, file.added, file.removed]), [['notes.md', 2, 0]]);
  // An added .patch file is content too: every line counts as added, nothing is read as a diff of another file.
  const patch = plain(transcript.aiCodexItem({ id: 'i', type: 'fileChange', status: 'completed', changes: [
    { path: 'fix.patch', kind: { type: 'add' }, diff: 'diff --git a/src/x.ts b/src/x.ts\n--- a/src/x.ts\n+++ b/src/x.ts\n@@ -1 +1 @@\n-a\n+b\n' }] }, 't'));
  assert.deepEqual(plain(timeline.aiDiffFiles(patch.output)).map(file => [file.path, file.added, file.removed]), [['fix.patch', 6, 0]]);
  // A binary file right at the line limit is not marked as cut short; real excess still is.
  const filler = Array.from({ length: 3998 }, () => '+x').join('\n');
  const atLimit = plain(timeline.aiDiffFiles('diff --git a/a b/a\n@@ -0,0 +1,3998 @@\n' + filler +
    '\ndiff --git a/i.png b/i.png\nGIT binary patch\nliteral 3\nabc\n'));
  assert.deepEqual(atLimit.map(file => [file.path, file.lines.length, file.truncated === true]), [['a', 3999, false], ['i.png', 1, false]]);
  const over = plain(timeline.aiDiffFiles('diff --git a/a b/a\n@@ -0,0 +1,4001 @@\n' + filler + '\n+y\n+z\n+w\n'));
  assert.deepEqual(over.map(file => [file.lines.length, file.truncated === true]), [[4000, true]]);
  // Plain diffs without git headers keep their files apart; a cut-short diff signs differently.
  const plainFiles = plain(timeline.aiDiffFiles(['--- a/a', '+++ b/a', '@@ -1 +1 @@', '-1', '+2', '--- a/b', '+++ b/b',
    '@@ -1 +1 @@', '-3', '+4'].join('\n')));
  assert.deepEqual(plainFiles.map(file => [file.path, file.added, file.removed]), [['a', 1, 1], ['b', 1, 1]]);
  // A deleted file keeps its own name (not /dev/null); timestamps after a tab are not part of the path.
  const deleted = plain(timeline.aiDiffFiles(['--- a/a\t2026-10-05 10:00', '+++ b/a\t2026-10-05 10:01', '@@ -1 +1 @@', '-1', '+2',
    '--- a/y\t2026-10-05 10:00', '+++ /dev/null', '@@ -1 +0,0 @@', '-gone'].join('\n')));
  assert.deepEqual(deleted.map(file => [file.path, file.added, file.removed]), [['a', 1, 1], ['y', 0, 1]]);
  // A '--- ' line not followed by '+++ ' is content, even past a hunk whose counts are short or missing.
  const short = plain(timeline.aiDiffFiles(['diff --git a/s b/s', '@@ -1 +1 @@', '-a', '+b', '--- x', '+++y'].join('\n')));
  assert.deepEqual(short.map(file => [file.path, file.added, file.removed]), [['s', 2, 2]]);
  const bare = plain(timeline.aiDiffFiles(['diff --git a/t b/t', '@@', '-a', '--- x', ' c'].join('\n')));
  assert.deepEqual(bare.map(file => [file.path, file.removed]), [['t', 2]]);
  const whole = timeline.aiDiffFiles('diff --git a/z b/z\n@@ -1 +1 @@\n-x\n+y');
  const cut = timeline.aiDiffFiles('diff --git a/z b/z\n@@ -1 +1 @@\n-x\n+y');
  cut[0].truncated = true;
  assert.notEqual(timeline.aiDiffSignature(whole), timeline.aiDiffSignature(cut));
  console.log('PASS binary patches, long-line signatures and file content that looks like a diff');
}

{
  // One working line: none while the newest row already shows the turn at work (a running step, a streaming reply).
  const item = (id, role, kind, state) => ({ id, role, title: role, text: id, state, turnId: 't', kind, detail: '', output: '' });
  const running = entries => timeline.aiLastEntryRunning(timeline.aiStepEntries(entries));
  assert.equal(running([]), false);
  assert.equal(running([item('u', 'user', 'user', 'completed'), item('k', 'execution', 'thinking', 'running')]), true);
  assert.equal(running([item('u', 'user', 'user', 'completed'), item('c', 'execution', 'tool', 'inProgress')]), true);
  assert.equal(running([item('u', 'user', 'user', 'completed'), item('a', 'assistant', 'assistant', 'running')]), true);
  assert.equal(running([item('u', 'user', 'user', 'completed'), item('c', 'execution', 'tool', 'completed')]), false,
    'between steps the turn shows its working line');
  assert.equal(running([item('a', 'assistant', 'assistant', 'completed')]), false);
  console.log('PASS the working line gives way to a row that already shows the turn at work');
}

{
  // The typewriter: a few characters a frame when close behind, faster when far behind, never past the text, and
  // never half of an emoji.
  const twSource = fs.readFileSync(base + '../../components/ai/AiTypewriter.ets', 'utf8');
  const pure = twSource.slice(twSource.indexOf('/** How many characters to show next'), twSource.indexOf('/**\n * Types a streaming reply'));
  const tw = { exports: {} };
  vm.runInNewContext(ts.transpileModule(pure, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText,
    { module: tw, exports: tw.exports });
  Object.assign(tw, tw.exports);
  assert.equal(tw.aiTypewriterStep(0, 3), 1);
  assert.equal(tw.aiTypewriterStep(0, 70), 10);
  assert.equal(tw.aiTypewriterStep(68, 70), 69);
  assert.equal(tw.aiTypewriterStep(70, 70), 70);
  let shown = 0, frames = 0;
  while (shown < 600) { shown = tw.aiTypewriterStep(shown, 600); frames++; }
  assert.ok(frames < 60, 'a large batch is caught up within about two seconds');
  assert.equal(tw.aiTypewriterCut('a😀b', 2), 3);
  assert.equal(tw.aiTypewriterCut('abc', 2), 2);
  console.log('PASS the typewriter follows a reply smoothly and never splits a character');
}
