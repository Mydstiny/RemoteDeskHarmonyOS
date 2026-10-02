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
    require(id) { throw new Error('unexpected import ' + id); } }, { filename: file });
  return module.exports;
}

let passed = 0;
function test(name, fn) { fn(); passed++; console.log('PASS ' + name); }
const hex = /^#[0-9A-F]{6}$/;

test('Pro 功能介绍 lists eight distinct areas with colors and two or three tags each', () => {
  const pro = load('entry/src/main/ets/services/ProIntroRegistry.ets');
  const items = pro.proIntroItems();
  assert.equal(items.length, 8);
  assert.equal(new Set(items.map(item => item.id)).size, 8);
  items.forEach(item => {
    assert.match(item.hue, hex); assert.match(item.hue2, hex);
    assert.ok(item.tags.length >= 2 && item.tags.length <= 3, item.id + ' tags');
    assert.ok(item.title.length > 0 && item.desc.length > 0);
  });
  // Copies: callers cannot change the registry.
  items[0].tags.push('x'); assert.equal(pro.proIntroItems()[0].tags.length, items[0].tags.length - 1);
  assert.notEqual(pro.proIntroStatus(true), pro.proIntroStatus(false));
  assert.match(pro.proIntroStatus(false), /正式开放/);
  assert.deepEqual([...pro.proIntroPromises()], ['一次购买', '不自动续费', '核心连接永久免费']);
});

test('first-install guide has nine colored slides, device page fourth, start last', () => {
  const guide = load('entry/src/main/ets/services/GuideContentRegistry.ets');
  for (const device of ['phone', 'tablet', 'desktop']) {
    const pages = guide.firstInstallGuidePages(device);
    assert.equal(pages.length, 9);
    assert.equal(pages[3].id, 'device-path-' + device);
    assert.equal(pages[pages.length - 1].id, 'start-first-host');
    pages.forEach(page => assert.match(page.hue, hex, page.id));
    assert.ok(pages.some(page => page.id === 'home-at-a-glance'));
    assert.ok(pages.some(page => page.id === 'security-locks'));
  }
  assert.equal(guide.settingsUsageGuidePages('phone').length, 9);
});

test('1.1.6 notes end with the Pro preview and keep every item tagged', () => {
  const notes = load('entry/src/main/ets/services/ReleaseNotesRegistry.ets');
  const pages = notes.pagesForReleasedVersion(notes.CURRENT_RELEASE_VERSION);
  assert.equal(pages.length, 14);
  assert.equal(pages[pages.length - 1].id, 'release-pro-preview');
  assert.equal(pages[pages.length - 1].tag, '即将推出');
  pages.forEach(page => assert.ok((page.tag || '').length > 0, page.id));
});

test('both startup flows continue into the Pro sheet, which also opens from 设置 → 教程', () => {
  const guidePage = read('entry/src/main/ets/pages/GuidePage.ets');
  assert.match(guidePage, /onPrimary: \(\): void => \{ this\.showProIntro\(\); \}/);
  assert.match(guidePage, /onFinish: \(\): void => \{ this\.showProIntro\(\); \}/);
  assert.match(guidePage, /onSkip: \(\): void => \{ this\.showProIntro\(\); \}/);
  assert.match(guidePage, /if \(isSheet && this\.stage === 'pro'\) \{\s*ProShowcase\(/);
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

test('Pro 功能介绍 has 完成 on the left and 现在订购 on the right, which reaches the Pro page', () => {
  const showcase = read('entry/src/main/ets/components/guide/ProShowcase.ets');
  assert.ok(showcase.indexOf('Button(this.primaryLabel).layoutWeight(1)') < showcase.indexOf('Button(this.orderLabel)'));
  const about = read('entry/src/main/ets/components/AboutSettingsSheet.ets');
  assert.match(about, /orderLabel: '现在订购'[\s\S]{0,200}onOrder: \(\): void => \{ this\.onOrderPro\(\); \}/);
  const host = read('entry/src/main/ets/pages/HostListPage.ets');
  assert.match(host, /onOrderPro: \(\): void => \{ this\.openSettingsLeafSheet\(SETTINGS_SHEET_PRO\); \}/);
  assert.match(host, /onPageShow\(\): void \{\s*this\.pageActive = true;\s*this\.openPendingProOrder\(\);/);
  assert.match(host, /AppStorage\.setOrCreate\(PRO_ORDER_PENDING_KEY, false\);/);
  const guidePage = read('entry/src/main/ets/pages/GuidePage.ets');
  assert.match(guidePage, /AppStorage\.setOrCreate\(PRO_ORDER_PENDING_KEY, true\);\s*this\.finish\(\);/);
});

console.log(passed + ' guide and Pro intro checks passed');
