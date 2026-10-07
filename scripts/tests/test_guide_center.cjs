// 设置 → 教程 → 操作引导中心 (2026-10-07): categories incl. 远程 AI and AI 助理, an entry path on every lesson,
// search across categories, and the sheet's search bar, device segments, category chips and auto-guide switch.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const ts = require(process.env.PRO_TYPESCRIPT_PATH || process.env.AI_TYPESCRIPT_PATH || 'typescript');
const root = path.join(__dirname, '../..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
function load(file) {
  const source = ts.transpileModule(read(file), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(source, { module, exports: module.exports, $r: name => ({ resource: name }),
    $rawfile: name => ({ rawfile: name }), require(id) { throw new Error('unexpected import ' + id); } }, { filename: file });
  return module.exports;
}
let passed = 0;
function test(name, fn) { fn(); passed++; console.log('PASS ' + name); }
const guide = load('entry/src/main/ets/services/GuideContentRegistry.ets');

test('eight categories, each with lessons on every device, and every lesson says where it starts', () => {
  const ids = Array.from(guide.guideProtocolOptions(), option => option.id);
  assert.deepEqual(ids, ['all', 'rdp', 'rustdesk', 'ssh', 'vnc', 'moonlight', 'ai', 'assistant']);
  const seen = new Set();
  for (const device of ['phone', 'tablet', 'desktop']) {
    for (const id of ids) {
      const lessons = guide.guideLessonsFor(device, id);
      assert.ok(lessons.length >= 3, device + ' ' + id);
      assert.equal(guide.guideLessonCount(device, id), lessons.length);
      for (const lesson of lessons) {
        seen.add(lesson.id);
        assert.ok(lesson.path.length > 0, lesson.id + ' path');
        assert.ok(lesson.steps.length >= 3 && lesson.steps.length <= 5, lesson.id + ' steps');
        assert.ok(lesson.title.length > 0 && lesson.summary.length > 0);
      }
    }
  }
  assert.ok(seen.size >= 40);
  assert.equal(guide.guideProtocolLabel('ai'), '远程 AI');
});

test('远程 AI covers install, QR pairing with all projects, the conversation list, chat, models and Pi', () => {
  const ai = guide.guideLessonsFor('phone', 'ai');
  assert.deepEqual(Array.from(ai, lesson => lesson.id), ['ai-install', 'ai-pair', 'ai-conversations', 'ai-chat', 'ai-model', 'ai-trouble']);
  const text = JSON.stringify(ai);
  for (const words of ['Codex（端口 9443）', 'Pi（9445）', '复制给 Agent 的安装提示词', '扫描电脑上的配对二维码', '全部项目（含电脑 App 里的项目）',
    '修改前询问', 'pi-gui']) assert.ok(text.includes(words), words);
  assert.ok(!/Anthropic API Key/.test(text));
});

test('search finds lessons across categories by every word, and nothing for an empty query', () => {
  const ids = (device, query) => Array.from(guide.guideLessonsMatching(device, query), lesson => lesson.id);
  assert.ok(ids('phone', '配对').includes('ai-pair'));
  assert.ok(ids('phone', '配对').includes('moonlight-prepare'));
  assert.ok(ids('phone', 'sftp').includes('ssh-sftp'), 'case-insensitive');
  assert.ok(ids('phone', '滚轮 VNC').includes('vnc-control'));
  assert.ok(!ids('phone', '滚轮 VNC').includes('rdp-control'), 'every word must match');
  assert.deepEqual(ids('phone', '   '), []);
  assert.deepEqual(ids('phone', '不存在的操作'), []);
  assert.ok(!ids('phone', '手柄').includes('moonlight-desktop-control'), 'device still filters');
  assert.ok(ids('desktop', '手柄').includes('moonlight-desktop-control'));
  // Copies: callers cannot change the registry.
  const found = guide.guideLessonsMatching('phone', '配对');
  found[0].steps.push('x');
  assert.notEqual(guide.guideLessonsMatching('phone', '配对')[0].steps.length, found[0].steps.length);
});

test('the sheet searches, segments devices, shows category chips with counts and switches auto guides', () => {
  const sheet = read('entry/src/main/ets/components/AboutSettingsSheet.ets');
  const ui = sheet.slice(sheet.indexOf('@Builder handsOnGuideSheet()'), sheet.indexOf('@Builder aboutAppSheet()'));
  assert.ok(ui.includes("placeholder: '搜索操作，例如 配对、滚轮、SFTP'"));
  assert.ok(ui.includes('this.guideSearchBar()') && ui.includes('this.guideAutoShowRow()'));
  assert.ok(ui.includes("this.guideDeviceSegment('desktop')"));
  assert.ok(ui.includes('guideLessonCount(this.guideDevice, option.id)'));
  assert.ok(ui.includes('Toggle({ type: ToggleType.Switch, isOn: this.guideAlwaysVisible })'));
  assert.ok(ui.includes('lesson.path') && ui.includes('this.guideEmptyState()'));
  assert.ok(ui.includes("accessibilityText('清除搜索')") && ui.includes("accessibilityText('关闭')"));
  assert.ok(sheet.includes('guideLessonsMatching(this.guideDevice, this.guideQuery)'));
  for (const id of ['all', 'rdp', 'rustdesk', 'ssh', 'vnc', 'moonlight', 'ai', 'assistant']) {
    if (id !== 'all') assert.ok(ui.includes("case '" + id + "': return $r('sys.symbol."), id + ' icon');
  }
});

console.log('guide center: ' + passed + ' checks passed');
