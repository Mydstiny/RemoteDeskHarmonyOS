'use strict';

/* Local behavior checks for the AI chat mode: Markdown, Office files, routing, document blocks and session kinds. */
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const zlib = require('node:zlib');
const { execFileSync } = require('node:child_process');
const assert = require('node:assert/strict');
const ts = require(process.env.AI_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const modules = new Map();
const preferenceStores = new Map();

class PreferenceStore {
  constructor(name) { this.name = name; this.values = preferenceStores.get(name) || new Map(); preferenceStores.set(name, this.values); }
  getSync(key, fallback) { return this.values.has(key) ? this.values.get(key) : fallback; }
  putSync(key, value) { this.values.set(key, value); }
  flushSync() {}
}

const kits = {
  '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } } } },
  '@kit.ArkData': { preferences: { getPreferencesSync: (_context, options) => new PreferenceStore(options.name) } },
  '@kit.AbilityKit': { common: {} }
};

function load(file, mocks = {}) {
  if (modules.has(file)) return modules.get(file).exports;
  const source = fs.readFileSync(path.join(root, file + '.ets'), 'utf8');
  const context = vm.createContext({ Date, JSON, Math, Number, String, Object, Array, Map, Set, Error, isFinite,
    parseInt, Uint8Array, DataView, ArrayBuffer, RegExp });
  const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const requireRelative = name => {
    if (mocks[name]) return mocks[name];
    if (kits[name]) return kits[name];
    const child = path.posix.normalize(path.posix.join(path.posix.dirname(file), name));
    return load(child.endsWith('.ets') ? child.slice(0, -4) : child, mocks);
  };
  const wrapped = vm.runInContext('(function(require,module,exports){' + output + '\n})', context);
  const fresh = { exports: {} };
  wrapped(requireRelative, fresh, fresh.exports);
  modules.set(file, fresh);
  return fresh.exports;
}

const D = 'entry/src/main/ets/services/diagnosticAi/';

// ---------------------------------------------------------------- Markdown
const md = load(D + 'AiMarkdownPolicy');
const blocks = md.aiMarkdownBlocks([
  '# 周报', '', '本周完成了 **三件事**：', '- 修复 `RDP` 黑屏', '  - 子项', '1. 第一步', '2) 第二步', '',
  '| 项目 | 进度 |', '| --- | ---: |', '| 远程桌面 | 80% |', '', '> 备注', '---', '```', 'code line', '```'
].join('\n'));
assert.deepEqual(Array.from(blocks, b => b.kind), ['h1', 'p', 'bullet', 'bullet', 'number', 'number', 'table', 'quote', 'rule', 'code']);
assert.equal(blocks[1].spans.find(s => s.bold).text, '三件事');
assert.equal(blocks[2].spans.find(s => s.code).text, 'RDP');
assert.equal(blocks[3].level, 1);
assert.equal(blocks[5].marker, '2.');
assert.deepEqual(Array.from(blocks[6].rows, r => Array.from(r)), [['项目', '进度'], ['远程桌面', '80%']]);
assert.equal(blocks[9].text, 'code line');
console.log('PASS Markdown blocks: headings, lists, tables, quotes, rules, code and inline marks');

// Reading aloud never says a Markdown mark: a line that starts with bold used to lose one * and read the rest.
const spoken = md.aiSpeechText([
  '**赶车提醒**：留出 40 分钟', '## 路线', '- **地铁**：9 号线 -> 10 号线', '1. 打开 [官网](https://developer.huawei.com/cn/)',
  '| 方式 | 耗时 |', '| --- | --- |', '| 地铁 | 80 分钟 |', '---', '```', 'rm -rf /', '```', '详见 https://example.com/a?b=1 页面'
].join('\n'));
assert.doesNotMatch(spoken, /[*#|`]/);
assert.match(spoken, /^赶车提醒：留出 40 分钟。/);
assert.match(spoken, /路线。\n地铁：9 号线，然后10 号线。/);
assert.match(spoken, /1、打开 官网。/);
assert.match(spoken, /地铁，耗时：80 分钟。/);
assert.match(spoken, /这里有一段代码/);
assert.doesNotMatch(spoken, /rm -rf|https?:/);
assert.match(spoken, /详见 链接 页面。$/);
console.log('PASS read aloud text: no Markdown marks, tables by row, links and code not spelled out');

// ---------------------------------------------------------------- zip + Office
const zip = load(D + 'AiZipWriter');
const sample = new TextEncoder().encode('hello zip');
if (typeof zlib.crc32 === 'function') { assert.equal(zip.aiCrc32(sample), zlib.crc32(sample)); }
const office = load(D + 'AiOfficeFormat');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-chat-'));
const docx = office.aiDocxBytes('第 40 周周报', '## 进展\n- 完成 **AI 聊天**\n\n| 模块 | 状态 |\n| --- | --- |\n| 文档 | 完成 & 验证 |\n\n普通段落 <tag>');
const docxPath = path.join(tmp, 'report.docx');
fs.writeFileSync(docxPath, Buffer.from(docx));
execFileSync('unzip', ['-tq', docxPath]);
const documentXml = execFileSync('unzip', ['-p', docxPath, 'word/document.xml']).toString('utf8');
execFileSync('python3', ['-c', 'import sys,xml.dom.minidom;xml.dom.minidom.parseString(sys.stdin.buffer.read())'], { input: documentXml });
assert.match(documentXml, /w:val="Title"/);
assert.match(documentXml, /<w:tbl>/);
assert.match(documentXml, /完成 &amp; 验证/);
assert.match(documentXml, /&lt;tag&gt;/);
const readBack = office.aiDocxText(documentXml);
assert.match(readBack, /第 40 周周报/);
assert.match(readBack, /文档 \| 完成 & 验证/);
console.log('PASS .docx is a valid zip with well-formed XML, and reads back as text');

const xlsx = office.aiXlsxBytes('销售/统计', '| 月份 | 金额 |\n| --- | --- |\n| 1月 | 1200.5 |\n| 2月 | 980 |');
const xlsxPath = path.join(tmp, 'sheet.xlsx');
fs.writeFileSync(xlsxPath, Buffer.from(xlsx));
execFileSync('unzip', ['-tq', xlsxPath]);
const sheetXml = execFileSync('unzip', ['-p', xlsxPath, 'xl/worksheets/sheet1.xml']).toString('utf8');
const workbookXml = execFileSync('unzip', ['-p', xlsxPath, 'xl/workbook.xml']).toString('utf8');
for (const xml of [sheetXml, workbookXml]) {
  execFileSync('python3', ['-c', 'import sys,xml.dom.minidom;xml.dom.minidom.parseString(sys.stdin.buffer.read())'], { input: xml });
}
assert.match(sheetXml, /<c r="B2"><v>1200.5<\/v><\/c>/);
assert.match(sheetXml, /<c r="A1" s="1" t="inlineStr">/);
assert.match(workbookXml, /name="销售 统计"/);
assert.equal(office.aiXlsxSheetText(sheetXml, []), '月份\t金额\n1月\t1200.5\n2月\t980');
assert.deepEqual(Array.from(office.aiSheetRows('a,b\n"x, y",2'), r => Array.from(r)), [['a', 'b'], ['x, y', '2']]);
console.log('PASS .xlsx has typed cells, a safe sheet name, and reads back as tab separated text');

assert.deepEqual(Array.from(office.aiXlsxSharedStrings('<sst><si><t>甲</t></si><si><r><t>乙</t></r><r><t>丙</t></r></si></sst>')), ['甲', '乙丙']);
assert.equal(office.aiPptxSlideText('<p:sld><a:p><a:r><a:t>标题</a:t></a:r></a:p><a:p><a:r><a:t>要点 &amp; 说明</a:t></a:r></a:p></p:sld>'), '标题\n要点 & 说明');
assert.equal(office.aiXmlUnescape('&#20013;&#x6587;&amp;lt;'), '中文&lt;');
assert.equal(office.aiHtmlText('<p>第一段</p><script>x()</script><div>第二&nbsp;段</div>'), '第一段\n第二 段');
console.log('PASS shared strings, slides, entities and HTML read as plain text');

// ---------------------------------------------------------------- routing
const route = load(D + 'AiChatRoutePolicy', {
  './DiagnosticAiSettingsActionPolicy': { diagnosticAiSettingIntents: q => /画质|色深/.test(q) ? [{}] : [] },
  './DiagnosticAiAgentService': { diagnosticAiAgentModeForQuestion: q => /反馈/.test(q) ? 'feedback' :
    /画质|色深/.test(q) ? 'configure' : /连不上|失败|黑屏|卡顿/.test(q) ? 'diagnose' : 'answer' }
});
assert.equal(route.aiRouteSuggestion('RDP 连不上怎么办', 'chat', false), 'assistant');
assert.equal(route.aiRouteSuggestion('把画质调成速度优先', 'chat', false), 'assistant');
assert.equal(route.aiRouteSuggestion('RDP 连不上怎么办', 'chat', true), '');
assert.equal(route.aiRouteSuggestion('帮我写一份周报', 'chat', false), '');
assert.equal(route.aiRouteSuggestion('帮我写一份周报', 'assistant', false), 'chat');
assert.equal(route.aiRouteSuggestion('把这段话翻译成英文', 'assistant', false), 'chat');
assert.equal(route.aiRouteSuggestion('SSH 连接失败', 'assistant', false), '');
assert.equal(route.aiRouteSuggestion('怎么添加主机', 'assistant', false), '');
for (const q of ['缩成悬浮球', '进入悬浮球模式。', '帮我缩成悬浮球', '先收起来', '最小化']) { assert.ok(route.aiQuestionIsFloat(q), q); }
for (const q of ['悬浮球的样式怎么改', '把悬浮球动效换成玻璃球', '收起来的东西在哪']) { assert.ok(!route.aiQuestionIsFloat(q), q); }
console.log('PASS routing suggests 助理 for app questions and 聊天 for general tasks, never both ways at once');

// Every mode hands over by itself: 聊天 → 助理 only to diagnose or send feedback; 助理 → 聊天 for anything not about the app.
assert.equal(route.aiAutoRoute('RDP 连不上怎么办', 'chat', false), 'assistant');
assert.equal(route.aiAutoRoute('RDP 黑屏了帮我反馈给开发者', 'chat', false), 'assistant');
assert.equal(route.aiAutoRoute('把画质调成速度优先', 'chat', false), '');
assert.equal(route.aiAutoRoute('帮我写一份周报', 'chat', false), '');
assert.equal(route.aiAutoRoute('RDP 连不上怎么办', 'chat', true), '');
assert.equal(route.aiAutoRoute('帮我写一份周报', 'assistant', false), 'chat');
assert.equal(route.aiAutoRoute('十分钟后提醒我喝水', 'assistant', false), 'chat');
assert.equal(route.aiAutoRoute('SSH 连接失败', 'assistant', false), '');
assert.equal(route.aiAutoRoute('怎么添加主机', 'assistant', false), '');
// A feature idea goes to 聊天 (it keeps the list) from any mode; a fault report still goes to 助理.
for (const q of ['要是能在 RDP 里录屏就好了', '希望 SSH 能支持分屏', '把我的需求发给开发者', '能不能加个暗色终端主题']) {
  assert.ok(route.aiQuestionIsFeatureIdea(q), q);
  assert.equal(route.aiAutoRoute(q, 'chat', false), '', q);
  assert.equal(route.aiAutoRoute(q, 'assistant', false), 'chat', q);
}
assert.equal(route.aiQuestionIsFeatureIdea('RDP 连不上怎么办'), false);
assert.equal(route.aiQuestionIsFeatureIdea('我希望能连上公司的电脑'), false, 'asking for help is not a feature request');
for (const q of ['RDP 连不上，我想要一个解决办法', 'SSH 老是断开，有没有改进建议', '我的需求是让 SSH 不断开', '你对这个报错有什么想法',
  '1.2.0 有什么新功能', '帮我写一份需求文档', '希望有人能帮我解决连不上的问题', '要是能连上就好了',
  '如果能正常连接就好了，RDP 一直报错', 'RDP 连接能不能加速', 'SSH 能不能加密传输', '希望能有办法解决断连', 'RDP 能不能支持多显示器']) {
  assert.equal(route.aiQuestionIsFeatureIdea(q), false, q);
}
for (const q of ['RDP 老是断开，能不能加个自动重连', '希望有个暗色主题', '我想要一个分屏的功能', '我有个想法：主机卡片可以拖动排序',
  '帮我记下这个需求', '给你提个建议，加个批量主机操作', '要是能在 SSH 里分屏就好了', '希望可以有主机分组颜色']) {
  assert.ok(route.aiQuestionIsFeatureIdea(q), q);
}
// Goodbyes and mode commands, said or typed in any mode.
for (const q of ['拜拜', '好的拜拜。', '拜拜啦', '再见', '那就先这样吧，拜拜', '退出', '退出吧', '关闭AI', '没事了谢谢', '好了，谢谢，就这样吧', '晚安']) {
  assert.ok(route.aiQuestionIsGoodbye(q), q);
  assert.equal(route.aiModeCommand(q), 'exit', q);
}
for (const q of ['怎么跟同事礼貌地说再见，帮我写三种说法', '退出登录怎么操作', '关闭深色模式']) {
  assert.ok(!route.aiQuestionIsGoodbye(q), q);
}
for (const [q, mode] of [['回到文字模式', 'text'], ['切换到文字聊天', 'text'], ['我要打字', 'text'], ['退出语音模式', 'text'],
  ['文字模式', 'text'], ['切换到语音模式', 'voice'], ['语音模式', 'voice'], ['切到助理', 'assistant'], ['交给助理吧', 'assistant'],
  ['切到聊天模式', 'chat'], ['缩成悬浮球', 'orb'], ['帮我写一份周报', ''], ['把语音设置打开', ''], ['RDP 连不上', '']]) {
  assert.equal(route.aiModeCommand(q), mode, q);
}
console.log('PASS goodbyes close the AI and mode commands switch it, from any mode; each mode hands over by itself');

// 联网搜索: Bing result pages read into title, address and summary; HTML to plain text.
const web = load(D + 'AiWebTools', { '@kit.NetworkKit': {}, '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {} } } });
const page = '<ol><li class="b_algo"><h2><a href="https://example.com/a?x=1&amp;y=2" h="x">杭州 <strong>西湖</strong></a></h2>' +
  '<div class="b_caption"><p>西湖位于杭州市&nbsp;西部。</p></div></li><li class="b_algo"><h2><a href="javascript:void(0)">坏链接</a></h2></li>' +
  '<li class="b_algo"><h2><a href="https://b.example/">第二条</a></h2></li></ol>';
const found = web.aiParseBingResults(page, 6);
assert.equal(found.length, 2);
assert.equal(found[0].title, '杭州 西湖');
assert.equal(found[0].url, 'https://example.com/a?x=1&y=2');
assert.equal(found[0].snippet, '西湖位于杭州市 西部。');
assert.equal(web.aiHtmlText('<script>x()</script><p>a&lt;b</p><style>p{}</style>'), 'a<b');
console.log('PASS web search results parse to title, address and summary; pages read as text');

// ---------------------------------------------------------------- document blocks
const chat = load(D + 'AiChatService', {
  '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {} } },
  './DiagnosticAiProviderCatalog': {}, './DiagnosticAiProviderService': {}, './DiagnosticAiRequestLog': {},
  './AiDocumentService': {}, './DiagnosticAiModels': {},
  './AiSystemTools': { AI_CONFIRM_TOOLS: [], aiActionFor: () => '', aiRunSystemTool: async () => '' },
  './DiagnosticAiSettingsActionPolicy': { diagnosticAiSettingSpec: () => undefined, diagnosticAiSettingCurrent: () => null,
    diagnosticAiSettingValueLabel: (_id, value) => value },
  './AiWebTools': { aiWebSearch: async () => '', aiReadWebpage: async () => '' }
});
const answer = '好的，周报如下。\n<document title="第 40 周周报" format="docx">\n# 周报\n- 完成\n</document>\n请查看。';
assert.deepEqual(Array.from(chat.aiChatDocumentBlocks(answer), b => Array.from(b)), [['第 40 周周报', 'docx', '# 周报\n- 完成']]);
assert.equal(chat.aiChatStripDocumentBlocks(answer), '好的，周报如下。\n\n请查看。');
assert.deepEqual(Array.from(chat.aiChatSuggestions('好的。\n<suggest>生成 Word 文档|翻译成英文|再精简一些</suggest>')),
  ['生成 Word 文档', '翻译成英文', '再精简一些']);
assert.equal(chat.aiChatStripSuggestions('正文\n<suggest>a|b</suggest>'), '正文');
assert.equal(chat.aiChatStripSuggestions('正文\n<suggest>被截断'), '正文');
console.log('PASS document blocks become files and leave the answer text; suggested next steps become pills');

// ---------------------------------------------------------------- memory (update_memory)
let mem = chat.aiMemoryEdit('', 'add', '我喜欢简洁的回答', '');
assert.equal(mem[0], '我喜欢简洁的回答');
mem = chat.aiMemoryEdit(mem[0], 'add', '常用主机是办公室电脑', '');
assert.equal(mem[0], '我喜欢简洁的回答\n常用主机是办公室电脑');
assert.match(chat.aiMemoryEdit(mem[0], 'add', '我喜欢简洁的回答', '')[1], /已经记着/);
assert.equal(chat.aiMemoryEdit(mem[0], 'replace', '常用主机是家里的 NAS', '常用主机')[0], '我喜欢简洁的回答\n常用主机是家里的 NAS');
const forgot = chat.aiMemoryEdit(mem[0], 'remove', '简洁', '');
assert.equal(forgot[0], '常用主机是办公室电脑');
assert.match(forgot[1], /已忘掉 1 条/);
assert.match(chat.aiMemoryEdit(mem[0], 'remove', '生日', '')[1], /没有/);
assert.equal(chat.aiMemoryEdit(mem[0], 'clear', '', '')[0], '');
console.log('PASS memory: add (no duplicates), replace, remove and clear, one note a line');

// ---------------------------------------------------------------- sessions
const storeModule = load(D + 'DiagnosticAiConversationStore');
const store = new storeModule.DiagnosticAiConversationStore();
store.init({}, 'chat-owner');
store.saveSession({ id: 'a1', title: 'RDP 黑屏', createdAt: 1, updatedAt: 1, providerId: 'p', modelId: 'm',
  turns: [{ question: 'RDP 黑屏', answer: '检查显卡', mode: 'diagnose', createdAt: 1 }] });
store.saveSession({ id: 'c1', title: '写周报', createdAt: 2, updatedAt: 2, providerId: 'p', modelId: 'm', kind: 'chat',
  turns: [{ question: '写周报', answer: '已生成', mode: 'chat', createdAt: 2, attachments: ['需求.docx'],
    documents: [{ name: '周报.docx', format: 'docx', path: '/data/x/周报.docx', bytes: 2048 }] }] });
const listed = store.listSessions();
assert.equal(storeModule.diagnosticAiSessionKind(listed.find(s => s.id === 'a1')), 'assistant');
const saved = listed.find(s => s.id === 'c1');
assert.equal(saved.kind, 'chat');
assert.equal(saved.turns[0].documents[0].name, '周报.docx');
assert.equal(saved.turns[0].attachments[0], '需求.docx');
assert.match(store.memoryContext(), /RDP 黑屏/);
assert.doesNotMatch(store.memoryContext(), /写周报/);
assert.match(store.memoryContext('chat'), /写周报/);
store.recordUsage(100, 50, 0, 0.01, 'p', 'm', false, true);
store.recordUsage(10, 5, 0, 0.001, 'p', 'm', false, false);
assert.equal(store.usage().chatRequestCount, 1);
assert.equal(store.usage().chatTokens, 150);
assert.equal(store.usage().requestCount, 2);
assert.equal(store.clearSessions('chat'), true);
assert.deepEqual(Array.from(store.listSessions(), s => s.id), ['a1']);
console.log('PASS 助理 and 聊天 sessions, memory and usage stay apart; clearing one kind keeps the other');

// ---------------------------------------------------------------- feature requests (需求收集)
const requests = new storeModule.DiagnosticAiConversationStore();
requests.init({}, 'request-owner');
assert.ok(requests.addFeatureRequest('希望 SSH 支持分屏'));
assert.equal(requests.addFeatureRequest('希望SSH支持分屏。'), null, 'the same request is kept once');
assert.ok(requests.addFeatureRequest('RDP 能录屏'));
assert.equal(requests.featureRequests().length, 2);
const firstId = requests.featureRequests()[0].id;
assert.ok(requests.markFeatureRequestsSent([firstId], 1234));
assert.equal(requests.featureRequests().find(row => row.id === firstId).sentAt, 1234);
assert.ok(requests.addFeatureRequest('希望 SSH 支持分屏'), 'a sent request may be asked for again');
assert.equal(requests.removeFeatureRequests('录屏'), 1);
const other = new storeModule.DiagnosticAiConversationStore();
other.init({}, 'someone-else');
assert.equal(other.featureRequests().length, 0, 'requests are per account');
const keptCount = requests.featureRequests().length;
assert.equal(requests.removeFeatureRequests(''), keptCount, 'an empty text clears the list');
assert.equal(requests.featureRequests().length, 0);
console.log('PASS feature requests: kept per account, no duplicates while waiting, marked sent, removable');

// ---------------------------------------------------------------- mails: structured, the log as an attachment
const mailPolicy = load(D + 'DiagnosticAiMailPolicy');
const diagnosis = { summary: 'RDP 在握手阶段被服务器断开，最可能是 NLA 凭据被拒。', severity: 'medium', confidence: 0.72,
  evidenceRefs: [], hypotheses: ['NLA 凭据错误（rdp.auth 1326）', '服务器只允许 TLS 1.2'], unknowns: ['服务器是否启用了 NLA'],
  recommendedReadOnlySteps: ['核对用户名和密码', '在服务器上检查远程桌面设置', '重新连接一次'], settingProposals: [], appActions: [],
  knowledgeVersion: 'kb-v6', createdAt: 1, developerNotes: '10:01:02 rdp.auth 1326\n10:01:03 断开' };
const mail = mailPolicy.diagnosticAiMailDraft({ question: 'RDP 连不上', result: diagnosis,
  attachmentNames: ['RemoteDesktop-diagnostics-20261004-100000.json'], featureRequests: ['希望 SSH 支持分屏'], appVersion: '1.2.0' });
assert.match(mail.subject, /RDP 连不上/);
for (const part of ['一、问题概述', '二、初步诊断', '严重程度：中 · 置信度：72%', '三、详细诊断', '（一）可能的原因',
  '1. NLA 凭据错误', '2. 服务器只允许 TLS 1.2', '（二）技术分析', '四、建议步骤', '1. 核对用户名和密码', '3. 重新连接一次',
  '五、尚未确认', '六、用户提出的功能需求', '七、附件', 'RemoteDesktop-diagnostics-20261004-100000.json', 'App 版本：1.2.0']) {
  assert.ok(mail.body.includes(part), 'mail has ' + part);
}
assert.ok(mail.body.indexOf('二、初步诊断') < mail.body.indexOf('三、详细诊断'));
assert.equal(/[{}]/.test(mail.body), false, 'no log JSON pasted into the mail');
const early = mailPolicy.diagnosticAiMailDraft({ question: '', result: null, attachmentNames: [], featureRequests: [], appVersion: '1.2.0' });
assert.match(early.body, /还没有完成分析/);
assert.equal(early.body.includes('、附件'), false, 'no attachment section without attachments');
const wish = mailPolicy.aiFeatureRequestMail(['希望 SSH 支持分屏', 'RDP 能录屏'], '多开终端时用得上', '1.2.0');
assert.equal(wish.subject, 'RemoteDesktop 功能需求（2 条）');
assert.match(wish.body, /1\. 希望 SSH 支持分屏\n2\. RDP 能录屏/);
assert.match(wish.body, /补充说明：\n多开终端时用得上/);
console.log('PASS mails: overview, preliminary and detailed diagnosis, numbered steps, attachments by name, no inline log');


// ---------------------------------------------------------------- tools and skills
const catalog = load(D + 'AiSkillCatalog');
for (const tool of catalog.AI_TOOLS) {
  const parsed = JSON.parse(tool.schema);
  assert.equal(parsed.function.name, tool.fn);
}
assert.equal(new Set(Array.from(catalog.AI_TOOLS, t => t.fn)).size, catalog.AI_TOOLS.length);
const md1 = catalog.aiParseSkill('---\nname: 项目周报\ndescription: 按项目写周报\nstarter: 帮我写项目周报\nkeywords: [项目周报, 进展]\n---\n按 本周完成 / 下周计划 写。', 'SKILL.md', 'file-1');
assert.equal(md1.name, '项目周报');
assert.deepEqual(Array.from(md1.keywords), ['项目周报', '进展']);
assert.equal(md1.instructions, '按 本周完成 / 下周计划 写。');
const js1 = catalog.aiParseSkill('{"name":"客服回复","instructions":"礼貌回复","keywords":["客服"]}', 'x.json', 'file-2');
assert.equal(js1.name, '客服回复');
assert.equal(catalog.aiParseSkill('直接写成要点', 'skill-要点提炼.txt', 'file-3').name, '要点提炼');
assert.equal(catalog.aiParseSkill('---\nname: 空\n---\n', 'a.md', 'file-4'), null);
const library = Array.from(catalog.AI_SKILL_LIBRARY);
assert.deepEqual(Array.from(catalog.aiSkillsForQuestion(library, '帮我写这周的周报'), s => s.id), ['weekly-report']);
assert.equal(catalog.aiThinkingPhrases('总结一下', ['需求.docx'])[0], '正在阅读《需求.docx》');
assert.equal(catalog.aiThinkingPhrases('翻译成英文', [])[0], '正在逐句翻译');
assert.equal(catalog.aiToolStatus('create_document', '周报'), '正在生成《周报》');
console.log('PASS tool schemas, skill files (SKILL.md, JSON, text), skill matching and thinking lines');

const skillStoreModule = load(D + 'AiSkillStore');
const skills = new skillStoreModule.AiSkillStore();
skills.init({}, 'skill-owner');
assert.deepEqual(Array.from(skills.installedSkills(), s => s.id), Array.from(catalog.AI_DEFAULT_SKILLS).filter(id =>
  library.some(s => s.id === id)).sort((a, b) => library.findIndex(s => s.id === a) - library.findIndex(s => s.id === b)));
assert.equal(skills.toolEnabled('app.hosts'), true);
skills.setToolEnabled('app.hosts', false);
assert.equal(skills.toolEnabled('app.hosts'), false);
assert.equal(Array.from(skills.enabledTools(), t => t.id).includes('app.hosts'), false);
skills.install('host-report');
assert.equal(skills.installedSkills().some(s => s.id === 'host-report'), true);
skills.uninstall('translator');
assert.equal(skills.availableSkills().some(s => s.id === 'translator'), true);
skills.saveCustom(new catalog.AiSkill('custom-1', '我的技能', '', '这样做', '', [], 'custom'));
assert.equal(skills.installedSkills().at(-1).name, '我的技能');
skills.uninstall('custom-1');
assert.equal(skills.customSkills().length, 0);
console.log('PASS tool switches, skill install/remove and custom skills are kept per account');

const bridge = load(D + 'AiAppDataBridge');
const hosts = [new bridge.AiHostSummary('办公室电脑', 'rdp', '公司', Date.now() - 3600000, 2, 35),
  new bridge.AiHostSummary('NAS', 'ssh', '', 0, 0, 0)];
const hostText = bridge.aiHostsText(hosts, '');
assert.match(hostText, /共 2 台主机（RDP 1 台、SSH 1 台）/);
assert.match(hostText, /办公室电脑 \| RDP \| 公司/);
assert.doesNotMatch(hostText, /192\.168|password/);
const now = Date.now();
const rows = [{ at: now - 7200000, label: '办公室电脑', protocol: 'rdp', outcome: 'connected', detail: '' },
  { at: now - 3600000, label: '', protocol: 'rdp', outcome: 'failed', detail: '用户名或密码错误' },
  { at: now - 1800000, label: '办公室电脑', protocol: 'rdp', outcome: 'connected', detail: '' }];
const logText = bridge.aiConnectionsText(rows, 7, hosts);
assert.match(logText, /成功连接 2 次/);
assert.match(logText, /失败 1 次/);
assert.match(logText, /办公室电脑（RDP） 2 次/);
assert.match(bridge.aiConnectionsText([], 7, hosts), /办公室电脑（RDP，/);
console.log('PASS host list and connection log read as words, without addresses or credentials');

const journalModule = load('entry/src/main/ets/services/ConnectionJournal');
journalModule.ConnectionJournal.init({}, () => 'owner-a');
journalModule.ConnectionJournal.connected('h1', '办公室电脑', 'rdp');
journalModule.ConnectionJournal.connected('h1', '办公室电脑', 'rdp');
journalModule.ConnectionJournal.failed('ssh', '认证失败');
assert.equal(journalModule.ConnectionJournal.recent(7).length, 2);
journalModule.ConnectionJournal.init({}, () => 'owner-b');
assert.equal(journalModule.ConnectionJournal.recent(7).length, 0);
console.log('PASS the connection log merges a quick reconnect and stays per account');

const system = load(D + 'AiSystemTools', {
  '@kit.AbilityKit': { abilityAccessCtrl: {}, common: {} }, '@kit.BasicServicesKit': {}, '@kit.CalendarKit': {},
  '@kit.CameraKit': {}, '@kit.ContactsKit': {}, '@kit.LocationKit': {}, '@kit.NetworkKit': {}, '@kit.BackgroundTasksKit': {},
  '@kit.NotificationKit': {}, '@kit.TelephonyKit': {}, '@kit.MediaLibraryKit': {},
  '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {} } }, './AiDocumentService': {},
  './DiagnosticAiSettingsActionPolicy': {}, '@kit.ShareKit': {}, './DiagnosticAiConversationStore': {},
  './AiMailService': { AI_DEVELOPER_EMAIL: 'dev@example.com', AiMailDraft: class {}, aiOpenMailEditor: async () => '' }
});
const t = system.aiParseLocalTime('2030-03-05 14:30');
assert.equal(new Date(t).getFullYear(), 2030);
assert.equal(new Date(t).getMonth(), 2);
assert.equal(new Date(t).getHours(), 14);
assert.equal(new Date(system.aiParseLocalTime('2030年3月5日')).getHours(), 9);
assert.ok(Number.isNaN(system.aiParseLocalTime('明天下午')));
assert.match(system.aiActionFor('a1', 'set_reminder', { title: '开会', time: '2001-01-01 09:00' }), /已经过去/);
const timer = system.aiActionFor('a2', 'set_reminder', { title: '喝水', minutes: 30 });
assert.equal(timer.title, '提醒：喝水');
assert.equal(timer.status, 'pending');
assert.equal(system.aiActionFor('a3', 'call_phone', { number: '138-1234-5678', name: '张三' }).detail, '138****5678');
assert.match(system.aiActionFor('a4', 'open_link', { url: 'javascript:alert(1)' }), /http/);
assert.equal(system.aiActionFor('a5', 'navigate', { destination: '虹桥机场' }).title, '导航到 虹桥机场');
assert.ok(system.AI_CONFIRM_TOOLS.includes('call_phone') && !system.AI_CONFIRM_TOOLS.includes('read_calendar'));
for (const tool of catalog.AI_TOOLS.filter(t => t.group === 'system')) {
  assert.ok(['read_clipboard', 'copy_to_clipboard', 'device_status', 'get_location', 'read_calendar', 'add_calendar_event',
    'pick_contact', 'add_contact', 'flashlight', 'recognize_image_text', 'share_text', 'open_system_settings',
    'list_reminders'].includes(tool.fn) ||
    system.AI_CONFIRM_TOOLS.includes(tool.fn),
    tool.fn + ' is neither run at once nor confirmed');
}
assert.match(system.aiActionErrorText({ code: 1700001, message: 'Notification is not enabled.' }), /通知被关闭/);
assert.match(system.aiActionErrorText({ code: 1700002 }), /上限/);
assert.equal(system.aiActionErrorText({ code: 16000050, message: 'Internal error.' }), '系统返回错误 16000050：Internal error.');
assert.equal(system.aiActionErrorText(new Error('没有提醒权限')), '没有提醒权限');
assert.equal(system.aiActionErrorText({}), '没有完成，请稍后再试');
assert.equal(system.aiActionFor('a6', 'cancel_reminder', { id: 7, title: '喝水' }).title, '取消提醒：喝水');
assert.match(system.aiActionFor('a7', 'cancel_reminder', { title: '喝水' }), /编号/);
assert.ok(system.AI_CONFIRM_TOOLS.includes('cancel_reminder'));
// Create, read, update and delete for what the AI makes or keeps: every tool exists, is on and has a valid schema.
for (const fn of ['manage_feature_requests', 'switch_mode', 'create_document', 'list_documents', 'read_document', 'update_document', 'delete_document',
  'list_conversations', 'delete_conversation', 'update_memory', 'edit_host', 'delete_host', 'list_reminders', 'cancel_reminder']) {
  const tool = catalog.AI_TOOLS.find(t => t.fn === fn);
  assert.ok(tool && tool.defaultOn, fn + ' exists and is on by default');
  assert.doesNotThrow(() => JSON.parse(tool.schema), fn + ' schema is valid JSON');
  assert.notEqual(catalog.aiToolStatus(fn, ''), '正在调用工具', fn + ' has its own status line');
}
assert.equal(new Set(catalog.AI_TOOLS.map(t => t.fn)).size, catalog.AI_TOOLS.length, 'tool names are unique');
for (const fn of ['change_setting', 'open_app_screen', 'ask_assistant']) {
  const tool = catalog.AI_TOOLS.find(t => t.fn === fn);
  assert.ok(tool && tool.group === 'app' && tool.defaultOn, fn + ' is an app tool, on by default');
  assert.doesNotThrow(() => JSON.parse(tool.schema), fn + ' schema is valid JSON');
}
assert.doesNotMatch(catalog.AI_TOOLS.find(t => t.fn === 'open_app_screen').schema, /session\./);
console.log('PASS system tools: local times, confirm cards (past time, masked number, http only) and every tool routed');

fs.rmSync(tmp, { recursive: true, force: true });
