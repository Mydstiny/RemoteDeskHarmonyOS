// Every Pro entry point must follow the entitlement, not only the user's display choice.
// A new ProBadge or Pro entry fails this test until it is gated through ProEntries.visible
// (or ProFeatureGate / AiAccess.proVisible, which apply the same rule) and registered below.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '../../entry/src/main/ets');
function files(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const full = path.join(dir, entry.name);
    return entry.isDirectory() ? files(full) : entry.name.endsWith('.ets') ? [full] : [];
  });
}
const sources = new Map(files(root).map(file => [path.relative(root, file).split(path.sep).join('/'), fs.readFileSync(file, 'utf8')]));
const count = (text, pattern) => (text.match(pattern) || []).length;

// 1. The display toggle alone is never an entitlement check.
const rawVisibility = /ProFeatureVisibility\.getInstance\(\)\.isVisible\(|\bproVisibility\.isVisible\(/g;
const rawAllowed = new Map([
  ['services/pro/ProEntries.ets', 'defines visible() = display choice AND entitlement decision'],
  ['services/pro/ProFeatureVisibility.ets', 'the display-choice store itself'],
  ['components/ProFeatureVisibilityPanel.ets', 'edits the display choice for every catalog feature'],
  ['components/ProFeatureManagerPanel.ets', 'Pro management list (shown only while Pro is active): edits display choices, shows the decision separately'],
  ['components/ProPurchaseSheet.ets', 'purchase list describes features the user does not own yet'],
  ['services/ai/AiAccess.ets', 'proVisible()/executable() combine it with runtime.decision']
]);
for (const [file, text] of sources) {
  if (count(text, rawVisibility) > 0) {
    assert.ok(rawAllowed.has(file), `${file}: use ProEntries.visible(featureId) instead of the display toggle alone`);
  }
}
for (const file of rawAllowed.keys()) assert.ok(sources.has(file), `allowlisted ${file} no longer exists`);
const entries = sources.get('services/pro/ProEntries.ets');
assert.match(entries, /ProEntries\.shown\(featureId\) &&\s*ProAppRuntime\.getInstance\(\)\.runtime\.decision\(featureId, context\)\.visible/);
assert.match(sources.get('components/ProFeatureGate.ets'), /ProEntries\.visible\(this\.featureId, this\.context\)/);
assert.match(sources.get('services/ai/AiAccess.ets'),
  /proVisible\(\): boolean \{[\s\S]*?isVisible\('pro\.ai\.workspace'\) &&\s*pro\.runtime\.decision\('pro\.ai\.workspace', pro\.context\('ai'\)\)\.visible/);

// 2. Every Pro badge is a registered, gated entry.
const badges = new Map([
  ['components/ProConnectionShareControls.ets', [1, /ProFeatureGate\(\{ featureId: 'pro\.connection\.knockShare'/]],
  ['components/ProContinuationControls.ets', [1, /ProFeatureGate\(\{ featureId: 'pro\.connection\.continuation'/]],
  ['components/ProAppIconPanel.ets', [1, /ProFeatureGate\(\{ featureId: 'pro\.personalization\.appIcon'/]],
  ['components/ProPurchaseSheet.ets', [1, /purchase/i]],
  ['components/ProFeatureVisibilityPanel.ets', [1, /ProFeatureVisibility/]],
  ['components/AppSheetHeader.ets', [1, /if \(this\.showProBadge\)/]],
  ['components/hostadd/HostProtocolPicker.ets', [1, /aiProVisible = AiAccess\.getInstance\(\)\.proVisible\(\)/]],
  ['components/ai/AiHostEditor.ets', [1, /AiAccess\.getInstance\(\)\.proVisible\(\)/]],
  ['pages/AiSettingsPage.ets', [1, /allowed = AiAccess\.getInstance\(\)\.proVisible\(\)/]],
  ['pages/SshTerminal.ets', [1, /ProFeatureGate\(\{ featureId: 'pro\.file\.knockTransfer'/]],
  // Per-feature sheets open only from the Pro 功能 section, which requires an active Pro.
  // The skin sheet opens only from the Pro-gated 终端皮肤 row in settings.
  ['components/ssh/skin/SshSkinSettingsPanel.ets', [1, /export struct SshSkinSettingsPanel/]],
  ['components/ProFeatureManagerPanel.ets', [2, /export struct ProBadgeSettingsPanel/]],
  // AI cards/section (4) follow aiProVisible; the app-icon row follows ProEntries; the account card
  // marker follows ProEntries.proActive().
  ['pages/HostListPage.ets', [8, /aiProVisible = AiAccess\.getInstance\(\)\.proVisible\(\)/]]
]);
for (const [file, text] of sources) {
  if (file === 'components/ProBadge.ets') continue;  // the badge component itself
  const found = count(text, /\bProBadge\(\)/g);
  if (found === 0) continue;
  assert.ok(badges.has(file), `${file}: new Pro entry — gate it with ProEntries.visible/ProFeatureGate and register it here`);
  const [expected, gate] = badges.get(file);
  assert.equal(found, expected, `${file}: Pro badge count changed; gate and re-register each entry`);
  assert.match(text, gate, `${file}: registered gate is missing`);
}
// Header badges only appear on AI workspace sheets, which close when AI access is revoked.
for (const [file, text] of sources) {
  if (file === 'components/AppSheetHeader.ets' || !/showProBadge: true/.test(text)) continue;
  assert.equal(file, 'pages/RemoteAiWorkspace.ets', `${file}: Pro sheet header needs a registered gate`);
}

// 3. Regression: the settings app-icon row follows the entitlement.
const host = sources.get('pages/HostListPage.ets');
assert.match(host, /this\.appIconProVisible = ProEntries\.visible\(id\) \|\|\s*\(ProEntries\.shown\(id\) && icons\.loaded && icons\.currentName !== ''\)/);
assert.match(host, /if \(this\.appIconProVisible && this\.appIconSupported\) \{[\s\S]{0,600}ProBadge\(\)/);
assert.match(host, /this\.openSettingsLeafSheet\(SETTINGS_SHEET_PRO_FEATURE\)/);
assert.equal(host.indexOf('ProFeatureDetailPanel({') > host.indexOf('SETTINGS_SHEET_PRO_FEATURE) {'), true);
assert.match(host, /if \(this\.proManagerVisible\) \{\s*ListItem\(\) \{\s*this\.settingsAccordionHeader\(SETTINGS_SECTION_PRO/);
assert.match(host, /this\.proManagerVisible = ProEntries\.proActive\(\)/);
assert.match(entries, /static proActive\(\): boolean \{\s*return ProAppRuntime\.getInstance\(\)\.runtime\.snapshot\(\)\.effectiveState === 'active';/);
// Settings order: protocol sections, then remote AI and Pro management, then security.
const order = ['SETTINGS_SECTION_VNC', 'SETTINGS_SECTION_MOONLIGHT', 'SETTINGS_SECTION_AI', 'SETTINGS_SECTION_PRO', 'SETTINGS_SECTION_SECURITY']
  .map(name => host.indexOf('this.settingsAccordionHeader(' + name));
assert.ok(order.every((index, i) => index > 0 && (i === 0 || index > order[i - 1])), 'settings section order changed');
assert.match(host, /this\.aiProVisible\) \{\s*ListItem\(\) \{\s*this\.settingsAccordionHeader\(SETTINGS_SECTION_AI/);
// 4. The account card and sheet show the Pro marker only while the account's Pro is active.
assert.equal(count(host, /if \(this\.proManagerVisible && !this\.appCloneLocalOnly\) \{\s*ProBadge\(/g), 2);
// 5. Custom key combinations belong to Pro 个性化方案 in settings, the session panel and the editor.
assert.match(host, /if \(this\.personalizationProVisible\) \{[\s\S]{0,900}ProBadge\(\)[\s\S]{0,300}SETTINGS_SHEET_VIRTUAL_KEYBOARD_CUSTOM/);
assert.match(host, /this\.personalizationProVisible = ProEntries\.visible\(PRO_PERSONALIZATION_FEATURE\)/);
const panel = sources.get('components/RemoteModifierPanel.ets');
assert.match(panel, /if \(this\.proCustomShortcuts\) \{\s*this\.SectionChoice\('custom'/);
assert.match(panel, /this\.proCustomShortcuts = ProEntries\.visible\(PRO_PERSONALIZATION_FEATURE\)/);
assert.match(sources.get('components/VirtualKeyboardSettingsSheet.ets'),
  /requestedSection === 'custom'\) \{\s*if \(ProEntries\.visible\(PRO_PERSONALIZATION_FEATURE\)\)/);
assert.match(host, /if \(this\.personalizationProVisible\) \{[\s\S]{0,900}ProBadge\(\)[\s\S]{0,300}SETTINGS_SHEET_SSH_SKIN/);
assert.match(sources.get('services/ssh/skin/SshSkinStore.ets'),
  /resolveSshSkin\(this\.settings, hostId, ProEntries\.visible\(PRO_PERSONALIZATION_FEATURE\)\)/);
console.log('PASS Pro entry points follow the entitlement through ProEntries and every Pro badge is registered');

// New Pro surfaces remain entitlement-gated while Debug exposes their experimental stage.
const vm = require('node:vm');
const entryTs = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const catalogPath = path.resolve(__dirname, '../../entry/src/main/ets/services/pro/ProFeatureCatalog.ets');
const entryModule = { exports: {} };
const catalogSource = entryTs.transpileModule(fs.readFileSync(catalogPath, 'utf8'), {
  compilerOptions: { target: entryTs.ScriptTarget.ES2021, module: entryTs.ModuleKind.CommonJS }
}).outputText;
vm.runInNewContext(catalogSource, { module: entryModule, exports: entryModule.exports, require: () => ({}) }, { filename: catalogPath });
const proCatalog = entryModule.exports.proFeatures();
for (const id of ['pro.workspaces', 'pro.hostManagement']) {
  const item = proCatalog.find(item => item.id === id); assert.ok(item);
  assert.equal(item.requiredEntitlementId, 'pro.lifetime');
  assert.equal(item.availability, 'experimental');
  assert.ok(item.devices.includes('phone')); assert.ok(item.devices.includes('tablet')); assert.ok(item.devices.includes('pc'));
}
assert.match(entryModule.exports.proFeatureProgress('pro.workspaces'), /实验中/);
assert.match(entryModule.exports.proFeatureProgress('pro.hostManagement'), /实验中/);
const hostPage = fs.readFileSync(path.resolve(__dirname, '../../entry/src/main/ets/pages/HostListPage.ets'), 'utf8');
assert.equal(hostPage.includes('加入 ops 工作组'), false); assert.equal(hostPage.includes('移出工作组'), false);
console.log('PASS Pro workspace/host-management entry gating');
