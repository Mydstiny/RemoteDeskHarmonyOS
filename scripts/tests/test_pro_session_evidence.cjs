/* 截屏给 AI 看与诊断证据包 (plan 2026-10-09 §2): the session summary states only what is known, the text handed to
 * the AI is capped, pack file names are ASCII; the capture is native and on request only; the three session entries
 * (RustDesk 顶栏, RDP and VNC toolbars) open it only when the Pro feature is on; only the recognised text reaches the AI. */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');
function load(relative) {
  const file = path.join(root, relative);
  const module = { exports: {} };
  const source = ts.transpileModule(read(relative), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  vm.runInNewContext(source, { module, exports: module.exports, require: id => {
    throw new Error('the evidence policy must stay pure: unexpected import ' + id);
  }}, { filename: file });
  return module.exports;
}
const e = load('entry/src/main/ets/services/pro/evidence/SessionEvidencePolicy.ets');
let passed = 0;
function check(name, body) { body(); passed++; console.log('PASS ' + name); }

const facts = (extra) => ({ protocol: 'rdp', hostLabel: '', capturedAt: new Date(2026, 9, 9, 14, 20, 5).getTime(),
  remoteWidth: 0, remoteHeight: 0, viewportWidth: 0, viewportHeight: 0, codec: '', decoder: '', fps: 0, route: '',
  lastError: '', appVersion: '', deviceType: '', ...extra });

check('summary: one fact per line, unknown facts left out, never an address', () => {
  const bare = e.sessionEvidenceSummary(facts({}));
  assert.equal(bare, 'RemoteDesktop 会话摘要\n时间：2026-10-09 14:20:05\n协议：RDP\n最近错误：无');
  const full = e.sessionEvidenceSummary(facts({ protocol: 'rustdesk', hostLabel: ' 书房 ', remoteWidth: 2560,
    remoteHeight: 1440, viewportWidth: 1280, viewportHeight: 800, codec: 'H.265', decoder: 'software', fps: 29.6,
    route: 'relay', lastError: ' 对端不在线 ', appVersion: '1.2.0', deviceType: 'PC' }));
  for (const line of ['协议：RustDesk（书房）', '远端画面：2560 × 1440', '本机显示区域：1280 × 800',
    '编解码：H.265（软件解码）', '帧率：30 fps', '连接路径：经中继', '最近错误：对端不在线', '应用版本：1.2.0', '设备：PC']) {
    assert.ok(full.split('\n').includes(line), line);
  }
});

check('question to the AI: names the protocol, normalises line breaks, cuts at the limit with a note', () => {
  const q = e.sessionScreenshotQuestion('  错误 0x80070005\r\n\r\n\r\n\r\n拒绝访问  ', 'vnc');
  assert.match(q, /VNC 远程会话/);
  assert.ok(q.endsWith('错误 0x80070005\n\n拒绝访问'));
  assert.doesNotMatch(q, /只截取了前/);
  const long = e.sessionScreenshotQuestion('x'.repeat(e.SESSION_SCREENSHOT_TEXT_LIMIT + 1), 'rustdesk');
  assert.match(long, new RegExp('只截取了前 ' + e.SESSION_SCREENSHOT_TEXT_LIMIT + ' 字'));
  assert.ok(long.endsWith('：\n\n' + 'x'.repeat(e.SESSION_SCREENSHOT_TEXT_LIMIT)));
});

check('pack file names are ASCII and dated', () => {
  const at = new Date(2026, 9, 9, 8, 5, 7).getTime();
  assert.equal(e.sessionEvidenceFileName('screenshot', at), 'RemoteDesk-screenshot-20261009-080507.png');
  assert.equal(e.sessionEvidenceFileName('summary', at), 'RemoteDesk-session-20261009-080507.txt');
});

check('native capture: on request only, at source size, before the swap, through async NAPI', () => {
  const header = read('entry/src/main/cpp/render/gl_renderer.h');
  assert.match(header, /uint64_t RequestFrameCapture\(\);/);
  assert.match(header, /bool WaitFrameCapture\(uint64_t token, int timeoutMs/);
  const cpp = read('entry/src/main/cpp/render/gl_renderer.cpp');
  assert.equal((cpp.match(/CaptureIfRequestedLocked\((true|false),/g) || []).length, 3, 'three present paths');
  assert.match(cpp, /glReadPixels/);
  const napi = fs.readdirSync(path.join(root, 'entry/src/main/cpp'), { recursive: true })
    .filter((f) => /\.cpp$/.test(f)).map((f) => read('entry/src/main/cpp/' + f)).join('\n');
  assert.match(napi, /"captureRendererFrame"/);
  assert.match(napi, /napi_create_async_work/);
  for (const dts of ['entry/src/main/cpp/types/librdpnapi/index.d.ts', 'entry/src/main/ets/types/rdpnapi.d.ts']) {
    assert.match(read(dts), /captureRendererFrame\(handle: number, timeoutMs\?: number\): Promise<RendererFrameCapture>/, dts);
  }
});

check('three entries, Pro-gated; the AI gets only the text the user confirmed', () => {
  const page = read('entry/src/main/ets/pages/RemoteDesktop.ets');
  assert.match(page, /ProEntries\.visible\(PRO_SESSION_EVIDENCE_FEATURE/);
  assert.match(page, /protocol === 'rdp' \|\| protocol === 'rustdesk' \|\| protocol === 'vnc'/);
  assert.match(page, /onSessionScreenshot: \(\): void => \{ this\.openSessionScreenshot\(\); \}/);
  assert.match(page, /if \(action === 'screenshot'\) \{ this\.openSessionScreenshot\(\); return; \}/);
  assert.match(page, /onScreenshot: \(\): void => \{[\s\S]{0,80}this\.openSessionScreenshot\(\);/);
  assert.equal((page.match(/screenshotVisible: this\.sessionScreenshotVisible\(\)/g) || []).length, 3);
  assert.match(page, /AppStorage\.setOrCreate<string>\(AI_SESSION_ASK, Date\.now\(\)\.toString\(\) \+ '\|' \+ question\)/);
  const host = read('entry/src/main/ets/components/diagnosticAi/SessionAiHost.ets');
  assert.match(host, /@StorageProp\(AI_SESSION_ASK\) @Watch\('onAskRequest'\)/);
  assert.match(host, /if \(!this\.island\.isOpen\(\)\) \{ this\.openOrb\(\); \}[\s\S]{0,300}AiChatMemory\.handoff = question;\s*aiChatRefresh\(\);/);
  const bar = read('entry/src/main/ets/components/RemoteSessionTopBar.ets');
  assert.match(bar, /if \(this\.screenshotAvailable\) \{\s*this\.menuItem\('截屏给 AI 看', 'sessionScreenshot'/);
  assert.match(read('entry/src/main/ets/services/RemoteSessionTopBarPolicy.ets'), /actionId === 'sessionScreenshot'\) \{/);
  const vnc = load('entry/src/main/ets/services/VncSessionUiPolicy.ets');
  const ids = Array.from(vnc.vncToolbarPrimaryActionIds(0, false, true, true));
  assert.deepEqual(ids.slice(-4), ['ai', 'screenshot', 'diagnostics', 'disconnect']);
  assert.ok(!Array.from(vnc.vncToolbarPrimaryActionIds(0, false, true)).includes('screenshot'));
  const sheet = read('entry/src/main/ets/components/pro/evidence/SessionScreenshotSheet.ets');
  assert.match(sheet, /this\.onAskAi\(sessionScreenshotQuestion\(this\.text, this\.protocol\)\)/);
  assert.match(sheet, /SaveButton\(/);
  assert.match(sheet, /void frame\.pixelMap\.release\(\)/);
});

check('诊断时间线: last N minutes only, oldest first, capped, plain lines', () => {
  const now = new Date(2026, 9, 9, 15, 0, 0).getTime();
  const ev = (minAgo, code, extra) => ({ wallTimeMs: now - minAgo * 60000, moduleId: 'connection.rdp', eventCode: code,
    outcome: 'failed', code: 0, durationMs: 0, ...extra });
  const text = e.sessionTimelineText([ev(0.5, 'b', { code: -14, durationMs: 120 }), ev(4, 'a'), ev(6, 'old')], 5, now);
  const lines = text.split('\n');
  assert.equal(lines[0], 'RemoteDesktop 诊断时间线（最近 5 分钟，2 条）');
  assert.match(lines[1], /^14:56:00\.000  connection\.rdp  a  failed$/);
  assert.match(lines[2], /^14:59:30\.000  connection\.rdp  b  failed  code=-14  120ms$/);
  const many = Array.from({ length: e.SESSION_TIMELINE_EVENT_LIMIT + 3 }, (_, i) => ev(0.0002 * i, 'x' + i));
  assert.match(e.sessionTimelineText(many, 1, now).split('\n')[0], /，更早的 3 条已省略）$/);
  assert.deepEqual(Array.from(e.SESSION_TIMELINE_MINUTES), [1, 5, 10]);
  assert.equal(e.sessionEvidenceFileName('timeline', now), 'RemoteDesk-timeline-20261009-150000.txt');
  const runtime = read('entry/src/main/ets/services/DiagnosticCaptureRuntime.ets');
  assert.match(runtime, /timelineSince\(sinceWallTimeMs: number\): DiagnosticTimelineEntry\[\] \{\s*if \(this\.phase === 'idle'\) \{ return \[\]; \}/);
  const sheet = read('entry/src/main/ets/components/pro/evidence/SessionScreenshotSheet.ets');
  assert.match(sheet, /status\(\)\.phase !== 'idle'/);
});

check('SSH: screen text on request from the interactive tab, confirmed and editable before the AI sees it', () => {
  assert.match(e.sessionScreenshotQuestion('ls: 权限不够', 'ssh', 'terminal'), /^这是我的 SSH 终端当前屏幕上的文字/);
  const html = read('entry/src/main/resources/rawfile/ssh-terminal/index.html');
  assert.match(html, /window\.__sshXtermGetScreenText = function \(\) \{[\s\S]{0,400}buffer\.viewportY \+ i/);
  const surface = read('entry/src/main/ets/components/SshXtermSurface.ets');
  assert.match(surface, /@Prop @Watch\('onScreenTextRequest'\) screenTextRequest: number = 0;/);
  const ssh = read('entry/src/main/ets/pages/SshTerminal.ets');
  assert.match(ssh, /screenTextRequest: this\.sshWorkspaceInteractiveForTab\(tab\.tabId, interactive\) \?\s*this\.sshScreenTextRequest : 0/);
  assert.match(ssh, /if \(this\.sshScreenTextVisible\(\) && this\.sshConnectionIsConnected\(\)\) \{\s*this\.SshHeaderActionRow\('屏幕文字交给 AI'/);
  assert.match(ssh, /ProEntries\.visible\(PRO_SESSION_EVIDENCE_FEATURE/);
  assert.match(ssh, /this\.showSshTabRenameSheet \|\| this\.showSftpTransferCenter \|\| this\.showSshScreenTextSheet;/);
  assert.match(ssh, /sessionScreenshotQuestion\(text, 'ssh', 'terminal'\)[\s\S]{0,200}AI_SESSION_ASK/);
  assert.match(read('entry/src/main/ets/components/pro/evidence/SessionTextToAiSheet.ets'), /this\.onSend\(this\.text\)/);
});

check('catalog and AI knowledge describe it', () => {
  const catalog = read('entry/src/main/ets/services/pro/ProFeatureCatalog.ets');
  assert.match(catalog, /planned\('pro\.session\.evidence', '截屏给 AI 看与诊断证据包'/);
  assert.match(catalog, /case 'pro\.session\.evidence':/);
  assert.match(read('entry/src/main/ets/services/diagnosticAi/DiagnosticAiKnowledgeBase.ets'), /截屏给 AI 看与诊断证据包（Pro）/);
});

console.log(passed + ' passed');
