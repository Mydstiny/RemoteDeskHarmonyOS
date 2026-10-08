// First-install guide, 1.1.6 notes and the Pro 功能介绍 sheet: content shape, colors and the startup flow wiring.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const root = path.join(__dirname, '../..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');

function load(file) {
  const source = ts.transpileModule(read(file), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  const module = { exports: {} };
  // Resource helpers are opaque handles here.
  const $r = name => ({ resource: name });
  const $rawfile = name => ({ rawfile: name });
  vm.runInNewContext(source, { module, exports: module.exports, $r, $rawfile,
    require(id) {
      // The trial story is shared by the Pro intro and the release notes (a sibling with no imports of its own).
      if (id === './ProTrialStory') { return load(path.posix.join(path.posix.dirname(file), 'ProTrialStory.ets')); }
      throw new Error('unexpected import ' + id);
    } }, { filename: file });
  return module.exports;
}

let passed = 0;
function test(name, fn) { fn(); passed++; console.log('PASS ' + name); }
const hex = /^#[0-9A-F]{6}$/;

test('Pro 功能介绍 lists eight distinct areas, AI 助理 first and featured, with colors and two or three tags each', () => {
  const pro = load('entry/src/main/ets/services/ProIntroRegistry.ets');
  const items = pro.proIntroItems();
  assert.equal(items.length, 8);
  assert.equal(new Set(items.map(item => item.id)).size, 8);
  items.forEach(item => {
    assert.match(item.hue, hex); assert.match(item.hue2, hex);
    assert.ok(item.tags.length >= 2 && item.tags.length <= 3, item.id + ' tags');
    assert.ok(item.title.length > 0 && item.desc.length > 0);
  });
  assert.equal(items[0].id, 'pro-intro-ai-assistant');
  assert.equal(items[0].featured, true);
  assert.ok(items[0].points.length >= 4, 'the featured AI card lists what it does');
  assert.equal(items.filter(item => item.featured).length, 1);
  assert.equal(items[1].id, 'pro-intro-ai');
  assert.equal(items.some(item => item.id === 'pro-intro-diagnostics'), false, 'diagnostics merged into AI 助理');
  // Copies: callers cannot change the registry.
  items[0].tags.push('x'); assert.equal(pro.proIntroItems()[0].tags.length, items[0].tags.length - 1);
  items[0].points.push('x'); assert.equal(pro.proIntroItems()[0].points.length, items[0].points.length - 1);
  assert.notEqual(pro.proIntroStatus(true), pro.proIntroStatus(false));
  assert.match(pro.proIntroStatus(true), /需要购买鸿蒙 PC 做测试/);
  assert.match(pro.proIntroStatus(true), /商务合同审核通过前/);
  assert.match(load('entry/src/main/ets/services/ProTrialStory.ets').PRO_TRIAL_STORY, /年底前 25 元，明年起 38\.8 元/);
  assert.match(load('entry/src/main/ets/services/ProTrialStory.ets').PRO_TRIAL_STORY, /买断制：一次购买、永久使用，不是订阅，不会自动续费/);
  assert.match(pro.proIntroStatus(false), /正式开放/);
  // No 「收费前提前通知」: the story under the hero says why Pro is here and what it will cost.
  assert.deepEqual([...pro.proIntroPromises()], ['全部功能免费试用', '核心连接永久免费']);
  const showcase = read('entry/src/main/ets/components/guide/ProShowcase.ets');
  assert.equal(showcase.includes('Pro 主打'), false, 'AI 助理 carries no 主打 tag');
});

test('first-install guide has ten colored slides, device page fourth, AI 助理 included, start last', () => {
  const guide = load('entry/src/main/ets/services/GuideContentRegistry.ets');
  for (const device of ['phone', 'tablet', 'desktop']) {
    const pages = guide.firstInstallGuidePages(device);
    assert.equal(pages.length, 10);
    assert.equal(pages[3].id, 'device-path-' + device);
    assert.ok(pages.some(page => page.id === 'ai-assistant'));
    assert.equal(pages[pages.length - 1].id, 'start-first-host');
    pages.forEach(page => assert.match(page.hue, hex, page.id));
    assert.ok(pages.some(page => page.id === 'home-at-a-glance'));
    assert.ok(pages.some(page => page.id === 'security-locks'));
  }
  assert.equal(guide.settingsUsageGuidePages('phone').length, 10);
});

test('1.2.0 notes lead with the free Pro trial; the 1.1.6 notes are kept as they shipped', () => {
  const notes = load('entry/src/main/ets/services/ReleaseNotesRegistry.ets');
  assert.equal(notes.CURRENT_RELEASE_VERSION, '1.2.0');
  assert.equal(notes.CURRENT_RELEASE_VERSION_CODE, 1001008);
  const pages = notes.pagesForReleasedVersion(notes.CURRENT_RELEASE_VERSION);
  assert.equal(pages.length, 12);
  assert.equal(pages[0].id, 'release-pro-trial');
  assert.match(pages[0].desc, /年底前 25 元，明年起 38\.8 元/);
  for (const id of ['release-remote-ai', 'release-new-look', 'release-touch-scroll', 'release-rustdesk-display']) {
    assert.ok(pages.some(page => page.id === id), id);
  }
  assert.equal(pages[pages.length - 1].id, 'release-1-1-6-summary');
  assert.equal(pages[0].tag, '免费试用');
  assert.match(notes.releaseHeadline('1.2.0'), /免费试用/);
  pages.forEach(page => assert.ok((page.tag || '').length > 0, page.id));
  const older = notes.pagesForReleasedVersion('1.1.6');
  assert.equal(older.length, 14);
  assert.equal(older[older.length - 1].id, 'release-pro-preview');
  assert.equal(older[older.length - 1].tag, '即将推出');
  const app = read('AppScope/app.json5');
  assert.match(app, /"versionCode": 1001008,\s*"versionName": "1\.2\.0"/);
});

test('both startup flows continue into the Pro sheet, which also opens from 设置 → 教程', () => {
  const guidePage = read('entry/src/main/ets/pages/GuidePage.ets');
  assert.match(guidePage, /onPrimary: \(\): void => \{ this\.showProIntro\(\); \}/);
  assert.match(guidePage, /onFinish: \(\): void => \{ this\.showProIntro\(\); \}/);
  assert.match(guidePage, /onSkip: \(\): void => \{ this\.showProIntro\(\); \}/);
  assert.match(guidePage, /if \(isSheet && this\.stage === 'pro'\) \{\s*(\/\/[^\n]*\n\s*)*ProShowcase\(/);
  // A reflow at a new breakpoint is not a dismissal.
  assert.match(guidePage, /this\.stage === 'pro' && !this\.appInBackground && !this\.reflowingSheet/);
  const about = read('entry/src/main/ets/components/AboutSettingsSheet.ets');
  assert.match(about, /aboutSheetMode === 6\) \{\s*this\.proIntroSheet\(\);/);
  const host = read('entry/src/main/ets/pages/HostListPage.ets');
  assert.match(host, /'Pro 功能介绍'[\s\S]{0,300}this\.aboutSheetMode = 6;/);
  // The Pro sheet never sells: it imports no purchase, billing or entitlement runtime.
  const showcase = read('entry/src/main/ets/components/guide/ProShowcase.ets');
  const imports = showcase.split('\n').filter(line => line.startsWith('import ')).join('\n');
  assert.equal(/Purchase|Billing|ProAppRuntime|Entitlement/.test(imports), false);
});

test('Pro 功能介绍 has one button, 立即试用, and the startup popup cannot be dismissed any other way', () => {
  const showcase = read('entry/src/main/ets/components/guide/ProShowcase.ets');
  assert.equal((showcase.match(/Button\(/g) || []).length, 1, 'a single button');
  assert.match(showcase, /actionLabel: string = '立即试用'/);
  assert.match(showcase, /previewStyle: 'capsule', previewMotion: 'sweep'/, 'the hero shows 极光流彩');
  assert.equal(showcase.includes("previewStyle: 'warp'"), false);
  const guidePage = read('entry/src/main/ets/pages/GuidePage.ets');
  assert.match(guidePage, /actionLabel: '立即试用',\s*onAction: \(\): void => \{ this\.startProTrial\(\); \}/);
  assert.match(guidePage, /onWillDismiss: \(action: DismissSheetAction\): void => \{\s*if \(this\.stage === 'pro' && !this\.isFinishing && !this\.reflowingSheet && !this\.appInBackground\) \{ return; \}\s*action\.dismiss\(\);/);
  assert.match(guidePage, /markProTrialStarted\(getContext\(this\)\);[\s\S]{0,240}this\.finish\(\);/);
  const about = read('entry/src/main/ets/components/AboutSettingsSheet.ets');
  assert.match(about, /actionLabel: proTrialStarted\(getContext\(this\)\) \? '继续使用 Pro' : '立即试用'/);
});

console.log(passed + ' guide and Pro intro checks passed');
