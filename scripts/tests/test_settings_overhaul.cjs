'use strict';

/*
 * 设置优化 (2026-10-06), batch A: fixes that apply in both the classic and the new look.
 * - leaf sheets fit the live window; the four per-protocol sheets save each change at once;
 * - text on an accent fill stays white unless white is unreadable; Moonlight shows words, not status codes;
 * - source contracts for the ArkUI parts: switches that rebuild after a cancelled change, live switch rows,
 *   unsaved-change guards, confirmations before deleting, the PC way back to the settings panel.
 */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.AI_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const ETS = path.join(root, 'entry/src/main/ets');

function load(file) {
  const source = fs.readFileSync(path.join(ETS, file + '.ets'), 'utf8');
  const output = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(output, { module, exports: module.exports, require: () => ({}), Math, Number, String, JSON },
    { filename: file });
  return module.exports;
}
const read = (file) => fs.readFileSync(path.join(ETS, file), 'utf8');
/** The body of `@Builder name(` or `private name(` up to the next member at the same indent. */
function member(source, signature) {
  const start = source.indexOf(signature);
  assert.ok(start >= 0, 'missing ' + signature);
  const next = source.slice(start + signature.length).search(/\n  (?:@Builder |private |build\(|aboutTo|async |onPage)/);
  return next < 0 ? source.slice(start) : source.slice(start, start + signature.length + next);
}
let passed = 0;
function check(name, run) { run(); passed++; console.log('PASS ' + name); }

check('leaf sheets fit the live window and keep their preferred height when there is room', () => {
  const route = load('services/SettingsSheetRoutePolicy');
  const fit = route.settingsLeafSheetFitHeight;
  assert.equal(fit(620, 0), 620);
  assert.equal(fit(620, NaN), 620);
  assert.equal(fit(620, 1000), 620);
  assert.equal(fit(760, 700), 660);
  assert.equal(fit(760, 400), 388);
  assert.equal(fit(760, 10), 1);
  // The keyboard leaves keep the behavior they had before the helper was shared.
  assert.equal(route.virtualKeyboardSettingsLeafSheetHeight(route.SETTINGS_SHEET_VIRTUAL_KEYBOARD, 500), 488);
  assert.equal(route.virtualKeyboardSettingsLeafSheetHeight(route.SETTINGS_SHEET_VIRTUAL_KEYBOARD, 900), 620);
  // Without a 取消/保存 row the four per-protocol sheets are shorter.
  assert.equal(route.remoteWheelDirectionSettingsLeafSheetHeight(route.SETTINGS_SHEET_REMOTE_WHEEL_DIRECTION), 620);
  assert.equal(route.remotePinchZoomSettingsLeafSheetHeight(route.SETTINGS_SHEET_REMOTE_PINCH_ZOOM), 640);
  assert.equal(route.remotePortraitDisplaySettingsLeafSheetHeight(route.SETTINGS_SHEET_REMOTE_PORTRAIT_DISPLAY), 680);
  assert.equal(route.sessionControlBarSettingsLeafSheetHeight(route.SETTINGS_SHEET_SESSION_CONTROL_BAR), 560);
  const page = read('pages/HostListPage.ets');
  const height = member(page, 'private settingsLeafSheetHeight(): SheetSize | number {');
  for (const policy of ['diagnosticHeight', 'secretVisibilityHeight', 'wheelDirectionHeight', 'pinchZoomHeight',
    'portraitDisplayHeight', 'controlBarHeight', 'moonlightHeight', 'vncHeight']) {
    assert.ok(height.includes('settingsLeafSheetFitHeight(' + policy + ', this.pageViewportHeight)'), policy);
  }
  assert.ok(height.includes('SETTINGS_SHEET_FEEDBACK'));
  assert.ok(page.includes("height: this.breakpoint === 'xl' ? settingsLeafSheetFitHeight(760, this.pageViewportHeight)"));
});

check('text on an accent fill stays white unless white is unreadable', () => {
  const color = load('common/AppUiColorPolicy');
  assert.equal(color.appUiOnAccentText('#007DFF'), '#FFFFFF');
  assert.equal(color.appUiOnAccentText('#0A59F7'), '#FFFFFF');
  assert.equal(color.appUiOnAccentText('#1A1A2E'), '#FFFFFF');
  assert.equal(color.appUiOnAccentText('#FFD60A'), '#000000');
  assert.equal(color.appUiOnAccentText('#A8E6CF'), '#000000');
  assert.equal(color.appUiOnAccentText('not a color'), '#FFFFFF');
  // The older helper keeps its choice for the remote AI pages that already use it.
  assert.equal(color.appUiButtonText('#007DFF'), '#000000');
  for (const file of ['components/RemoteWheelDirectionSettingsSheet.ets', 'components/RemotePinchZoomSettingsSheet.ets',
    'components/RemotePortraitDisplaySettingsSheet.ets', 'components/RemoteSessionControlBarSettingsSheet.ets',
    'components/VncSettingsSheet.ets', 'pages/VncSettingsPage.ets', 'pages/MoonlightSettingsPage.ets']) {
    assert.ok(!/backgroundColor\(this\.accent(?:Color)?\)\.fontColor\((?:Color\.White|'#FFFFFF')\)/.test(read(file)), file);
  }
});

check('Moonlight shows status words instead of raw codes', () => {
  const text = load('services/MoonlightStatusTextPolicy').moonlightStatusText;
  for (const code of ['account_changed', 'stale_account', 'stale_lease', 'local_save_exception', 'readback_failed',
    'pending_local_verification', 'invalid_record', 'invalid_settings', 'not_ready', 'read_failed', 'version_exhausted',
    'invalid_request', 'invalid_data', 'not_found', 'cloud_unavailable']) {
    assert.ok(!text(code).includes(code), code);
    assert.ok(/[一-龥]/.test(text(code)), code);
  }
  assert.ok(text('something_new').includes('something_new'));
  for (const harmless of ['', 'ok', 'default', 'unchanged']) { assert.equal(text(harmless), '', harmless); }
  for (const code of ['invalid_owner', 'conflict', 'quarantined', 'local_write_failed']) {
    assert.ok(!text(code).includes(code), code);
  }
  const page = read('pages/MoonlightSettingsPage.ets');
  assert.ok(page.includes("if (moonlightStatusText(this.saveCode) !== '') {"));
  assert.ok(page.includes("'本地设置：' + moonlightStatusText(this.saveCode)"));
  assert.ok(page.includes("'当前无法生成完整预览：' + moonlightStatusText(this.dataStatusCode)"));
  assert.ok(!page.includes("'本地设置状态：' + this.saveCode"));
});

check('the four per-protocol sheets save each change at once and flash 已保存', () => {
  for (const name of ['RemoteWheelDirectionSettingsSheet', 'RemotePinchZoomSettingsSheet',
    'RemotePortraitDisplaySettingsSheet', 'RemoteSessionControlBarSettingsSheet']) {
    const source = read('components/' + name + '.ets');
    assert.ok(source.includes('SettingsSavedBadge({ savedTick: this.savedTick })'), name);
    assert.ok(source.includes('this.savedTick++;'), name);
    assert.ok(source.includes("accessibilityText('关闭')"), name);
    assert.ok(!source.includes("Text('保存')") && !source.includes("Button('保存')"), name + ' has no save button');
    assert.ok(!source.includes("Button('取消')") && !source.includes("Text('取消')"), name + ' has no cancel button');
    assert.ok(!source.includes('恢复全部正常'), name);
    // A failed save puts the switches back.
    assert.ok(/if \(!this\.onSave\([^)]*\)[^\n]*\{\n\s+this\.(restore\(previous\)|draft = previous;)/.test(source), name);
  }
  const wheel = read('components/RemoteWheelDirectionSettingsSheet.ets');
  // The switch reads the draft while rendering, so 全部反转 moves every switch.
  assert.ok(wheel.includes('Toggle({ type: ToggleType.Switch, isOn: this.value(protocol) })'));
  const bar = read('components/RemoteSessionControlBarSettingsSheet.ets');
  assert.ok(bar.includes('Toggle({ type: ToggleType.Switch, isOn: !this.hidden(protocol) })'), 'on = shown');
  assert.ok(bar.includes("accessibilityText('显示 ' + title + ' 会话控制栏')"));
  assert.ok(bar.includes('开关打开表示显示'));
});

check('settings switches show the saved value after a cancelled or failed change', () => {
  const page = read('pages/HostListPage.ets');
  const row = member(page, '@Builder rustdeskSwitchRow(row: SettingsSwitchRowArgs) {');
  assert.ok(row.includes('ForEach([this.settingsSwitchEpoch]'));
  assert.ok(row.includes('isOn: row.isOn'));
  assert.equal((page.match(/this\.rustdeskSwitchRow\(\{/g) || []).length, 13);
  assert.ok(!/this\.rustdeskSwitchRow\(\$r/.test(page), 'every switch row passes one object literal');
  for (const signature of ['private saveRdpSkipCertificatePreflight(on: boolean): void {',
    'private saveRdpTlsWithoutNla(on: boolean): void {']) {
    const body = member(page, signature);
    assert.ok(body.includes("if (value['index'] !== 1) { this.settingsSwitchEpoch++; return; }"), signature);
    assert.ok(body.includes('.catch((_err: Error): void => { this.settingsSwitchEpoch++; })'), signature);
  }
  assert.ok(page.includes("}, (epoch: number): string => 'totp-lock-' + epoch.toString())"));
  assert.ok(page.includes("}, (epoch: number): string => 'quick-exit-' + epoch.toString())"));
  const quickExit = member(page, '@Builder remoteSessionQuickExitRow() {');
  assert.ok(quickExit.includes('this.settingsSwitchEpoch++;'));
  assert.ok(member(page, 'private saveRustDeskRemoteAppTouchScaleEnabled(on: boolean): void {')
    .includes('this.settingsSwitchEpoch++;'));
});

check('closing an editor with unsaved changes asks first', () => {
  const page = read('pages/HostListPage.ets');
  const label = member(page, 'private settingsLeafUnsavedLabel(): string {');
  for (const editor of ['Moonlight 设置', 'VNC 设置', '终端皮肤', '远端显示尺寸', 'Windows 凭据', '组合键', '加密密码']) {
    assert.ok(label.includes("'" + editor + "'"), editor);
  }
  assert.ok(page.includes("return this.settingsLeafUnsavedLabel() !== '';"));
  const dismiss = member(page, 'private dismissSettingsLeafIfNeeded(continueAction: () => void): void {');
  assert.ok(!dismiss.includes('叶子'), 'no developer wording in the dialog');
  for (const host of ['SshSkinSettingsPanel({', 'RdpDisplayProfilePanel({', 'VirtualKeyboardSettingsSheet({']) {
    const start = page.indexOf(host);
    assert.ok(page.slice(start, start + 600).includes('this.dismissSettingsLeafIfNeeded('), host);
  }
  // The combo editor counts as unsaved only after something changed, not merely because it is open.
  assert.ok(label.includes("this.virtualKeyboardCustomEditorDirty) { return '组合键'; }"));
  const keyboard = read('components/VirtualKeyboardSettingsSheet.ets');
  assert.equal((keyboard.match(/@Watch\('reportEditorDirty'\)/g) || []).length, 6);
  assert.ok(member(keyboard, 'private beginEditor(').includes('this.editorStart = this.editorSnapshot();'));
  const skin = read('components/ssh/skin/SshSkinSettingsPanel.ets');
  assert.ok(skin.includes("@State @Watch('reportEditingDirty') editing"));
  const display = read('components/rdp/RdpDisplayProfilePanel.ets');
  assert.ok(display.includes("@State @Watch('reportDraftDirty') widthDraft"));
  // Applying a typed size re-checks against the saved values, so the flag does not stay set.
  assert.ok(member(display, 'onCustomChange(): void {').includes('this.reportDraftDirty();'));
  // The portrait sheet saves one thing per change, so a failure never leaves half of it stored.
  const portraitHost = page.slice(page.indexOf('RemotePortraitDisplaySettingsSheet({'));
  assert.ok(portraitHost.slice(0, 1600).includes('=== this.remotePortraitSidebarHeightMode'));
  // The credential editor goes back to the list it was opened from.
  const save = member(page, 'private saveRdpCredentialFromSettings(): void {');
  assert.ok(save.includes('this.openSettingsLeafSheet(SETTINGS_SHEET_RDP_CREDENTIALS);'));
  // A typed master password never outlives the crypto sheet.
  const disappear = member(page, 'private handleSettingsLeafSheetDisappear(): void {');
  assert.ok(disappear.includes("this.cryptoPwd = '';") && disappear.includes("this.cryptoPwdConfirm = '';"));
});

check('PC: a leaf the user closes goes back to the settings panel it came from', () => {
  const page = read('pages/HostListPage.ets');
  assert.ok(member(page, 'private openSettingsLeafSheet(').includes('this.settingsLeafReturnsToPanel = panelWasOpen;'));
  const willDismiss = member(page, 'private handleSettingsLeafWillDismiss(action: DismissSheetAction): void {');
  assert.equal((willDismiss.match(/this\.settingsLeafClosedByUser = true;/g) || []).length, 2);
  const disappear = member(page, 'private handleSettingsLeafSheetDisappear(): void {');
  assert.ok(disappear.includes('const returnToPanel: boolean = closedByUser && this.settingsLeafReturnsToPanel;'));
  const back = member(page, 'private returnToSettingsPanelAfterLeaf(): void {');
  assert.ok(back.includes("this.breakpoint !== 'xl'") && back.includes('!this.pageActive'));
  const blocked = member(page, 'private settingsPanelReturnBlocked(): boolean {');
  for (const sheet of ['showAddSheet', 'showWorkspaceEditor', 'showRemoteHostSheet', 'aiIslandShown']) {
    assert.ok(blocked.includes('this.' + sheet), sheet);
  }
  const leaf = member(page, '@Builder settingsLeafSheet() {');
  assert.ok(!leaf.includes('onClose: (): void => { this.closeSettingsLeafSheet(); }'), 'leaf close buttons are user closes');
  // The PC sheet does not keep the phone tab bar's spacer.
  assert.ok(page.includes("ListItem() { Column().height(this.isDesktopDevice && this.breakpoint === 'xl' ? 24 : 120) }"));
});

check('deleting or clearing asks first; the account sheet shows one action', () => {
  const ai = read('components/diagnosticAi/DiagnosticAiSettingsSheet.ets');
  assert.ok(!ai.includes('ClearArmed') && !ai.includes('再点一次'));
  for (const text of ["'清空用量统计？'", "'删除这个对话？'", "'清除你补充的偏好？'", "'删除「' + profile.displayName + '」？'"]) {
    assert.ok(ai.includes(text), text);
  }
  assert.ok(ai.includes("accessibilityText('删除对话')"), 'visible delete for mouse users');
  assert.ok(read('components/diagnosticAi/AiSkillsSettingsPanel.ets').includes('this.confirmUninstall(skill)'));
  assert.ok(read('components/diagnosticAi/AiVoiceSettingsPanel.ets').includes('this.confirmRemoveKey()'));
  const remote = read('pages/AiSettingsPage.ets');
  assert.ok(remote.includes('onAction: (): void => { this.confirmClearOperations(); }'));
  assert.ok(remote.indexOf("if (this.error !== '')") < remote.indexOf('Scroll() {'), 'errors show under the title');
  assert.ok(remote.includes('SettingsSavedBadge({ savedTick: this.savedTick })'));
  const page = read('pages/HostListPage.ets');
  const account = member(page, '@Builder accountSheet() {');
  assert.ok(account.includes('} else if (this.accountLoggedIn()) {'));
  assert.ok(account.includes('this.confirmLogout();') && !account.includes('this.doLogout();'));
  assert.ok(page.includes("title: '恢复终端默认显示？'"));
  assert.ok(!page.includes('暂不迁移 trust 入口'));
});

check('small fixes: breakpoint key, color drag, VNC draft and numbers, empty sheets', () => {
  for (const file of ['components/FeedbackSettingsSheet.ets', 'components/DiagnosticCaptureSettingsSheet.ets',
    'components/diagnosticAi/DiagnosticAiAssistantPanel.ets', 'components/diagnosticAi/DiagnosticAiSettingsSheet.ets']) {
    assert.ok(!read(file).includes("@StorageProp('breakpoint')"), file);
  }
  const picker = read('components/ColorPickerSheet.ets');
  assert.ok(member(picker, 'private applyHsvColor(').includes('if (persist) { this.commitAccent(); }'));
  assert.equal((picker.match(/\.onActionEnd\(\(\): void => \{ this\.commitAccent\(\); \}\)/g) || []).length, 2);
  const vnc = read('components/VncSettingsSheet.ets');
  assert.ok(!vnc.includes('else { this.load(); }'), '取消 keeps the draft');
  assert.ok(vnc.includes('.type(numeric ? InputType.Number : InputType.Normal)'));
  assert.equal((vnc.match(/this\.timeoutProblem\(/g) || []).length, 3);
  assert.ok(read('components/ProAppIconPanel.ets').includes('这台设备暂不支持更换应用图标'));
  assert.ok(read('components/AboutSettingsSheet.ets').includes("SymbolGlyph($r('sys.symbol.xmark'))"));
  const page = read('pages/HostListPage.ets');
  assert.ok(page.includes("this.cardDisabledRow($r('app.media.icon_info'), '本版本更新日志',"));
  assert.ok(page.includes('.height(this.wallpaperGridHeight())'));
  for (const panel of ['ProFeatureDetailPanel({', 'ProBadgeSettingsPanel({', 'RdpDisplayProfilePanel({', 'ProAppIconPanel({',
    'SshSkinSettingsPanel({']) {
    const start = page.indexOf(panel);
    assert.ok(page.slice(start, start + 400).includes('showClose: true'), panel);
  }
});

// ------------------------------------------------------------------ batch B: 全新视觉 (opt-in, off by default)
/** Loads a services module that imports other services modules (relative imports only). */
function loadTree(file, cache = new Map()) {
  if (cache.has(file)) return cache.get(file).exports;
  const source = fs.readFileSync(path.join(ETS, file + '.ets'), 'utf8');
  const output = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  cache.set(file, module);
  const requireRelative = (name) => {
    if (!name.startsWith('.')) return {};
    return loadTree(path.posix.normalize(path.posix.join(path.posix.dirname(file), name)), cache);
  };
  // $r() is a compile-time resource; here it only needs to give each name a distinct value.
  vm.runInNewContext(output, { module, exports: module.exports, require: requireRelative, Math, Number, String, JSON,
    $r: (name) => 'R:' + name }, { filename: file });
  return module.exports;
}

check('全新视觉 is opt-in: stored per account, cloud-synced, and readable and settable by the AI', () => {
  const style = load('services/SettingsVisualStylePolicy');
  assert.equal(style.SETTINGS_VISUAL_STYLE_KEY, 'settingsVisualStyle');
  for (const value of ['', 'classic', 'Modern', 'new', undefined]) {
    assert.equal(style.normalizeSettingsVisualStyle(value), 'classic', String(value));
    assert.equal(style.settingsVisualIsModern(value), false);
  }
  assert.equal(style.normalizeSettingsVisualStyle('modern'), 'modern');
  const sync = load('services/CloudSyncSettingsPolicy');
  assert.ok(sync.cloudUserSettingIsSyncable('settingsVisualStyle'));
  const page = read('pages/HostListPage.ets');
  assert.ok(page.includes("@StorageLink('settingsVisualStyle') settingsVisualStyle: string = 'classic';"));
  assert.ok(page.includes('prefs.getSync(SETTINGS_VISUAL_STYLE_KEY, SETTINGS_VISUAL_STYLE_CLASSIC)'));
  assert.ok(page.includes("case 'ui.settingsVisual': this.saveSettingsVisualStyle(value === SETTINGS_VISUAL_STYLE_MODERN)"));
  assert.ok(member(page, '@Builder settingsVisualStyleRow() {').includes("accessibilityText('全新视觉')"));
  const ai = read('services/diagnosticAi/DiagnosticAiSettingsActionPolicy.ets');
  assert.ok(ai.includes("new AiSettingSpec('ui.settingsVisual', '设置页外观', 'settingsVisualStyle',"));
  assert.ok(ai.includes("choices([['modern', '全新视觉'], ['classic', '经典']])"));
  const kb = read('services/diagnosticAi/DiagnosticAiKnowledgeBase.ets');
  assert.ok(kb.includes('全新视觉') && kb.includes('ui.settingsVisual'));
});

check('the classic page keeps its sections and order; the new look groups the same sections', () => {
  const page = read('pages/HostListPage.ets');
  const content = member(page, '@Builder settingsContent() {');
  const classicOrder = ['Appearance', 'Home', 'CloudSync', 'ConnectionLive', 'DisplayInteraction', 'VirtualKeyboard',
    'Rdp', 'RustDesk', 'Ssh', 'Vnc', 'Moonlight', 'RemoteAi', 'ProDebug', 'Pro', 'Security', 'Tutorial', 'About',
    'Diagnostics', 'Actions'];
  const classic = content.slice(content.indexOf('} else {\n          this.settingsSectionAppearance()'));
  const calls = [...classic.matchAll(/this\.settingsSection(\w+)\(\)/g)].map((m) => m[1]);
  assert.deepEqual(calls.slice(0, classicOrder.length), classicOrder);
  const modern = member(page, '@Builder settingsModernSections() {');
  const modernCalls = [...modern.matchAll(/this\.settingsSection(\w+)\(\)|this\.settingsGroupTitle\('([^']+)'\)/g)]
    .map((m) => m[1] || '#' + m[2]);
  assert.deepEqual(modernCalls, ['#通用', 'Appearance', 'Home', 'ConnectionLive', 'DisplayInteraction',
    'VirtualKeyboard', '#连接协议', 'Rdp', 'RustDesk', 'Ssh', 'Vnc', 'Moonlight', '#AI 与 Pro', 'Diagnostics',
    'RemoteAi', 'ProDebug', 'Pro', '#安全与数据', 'CloudSync', 'Security', '#帮助', 'Tutorial', 'About', 'Actions']);
  for (const name of classicOrder) { assert.ok(page.includes('  @Builder settingsSection' + name + '() {'), name); }
  // The scroll index follows the same layout: the policy's groups are the builder's groups.
  const policy = loadTree('services/SettingsModernPolicy');
  const sectionIds = { Appearance: 'appearance', Home: 'homeLayout', ConnectionLive: 'connectionLive',
    DisplayInteraction: 'displayInteraction', VirtualKeyboard: 'virtualKeyboard', Rdp: 'windowsRdp',
    RustDesk: 'rustdesk', Ssh: 'ssh', Vnc: 'vnc', Moonlight: 'moonlight', Diagnostics: 'diagnostics',
    RemoteAi: 'remoteAi', ProDebug: 'proDebug', Pro: 'proFeatures', CloudSync: 'cloudSync', Security: 'security',
    Tutorial: 'tutorial', About: 'about', Actions: 'actions' };
  // JSON round trip: the module runs in its own VM realm, so its arrays have another Array prototype.
  const fromPolicy = JSON.parse(JSON.stringify(policy.settingsModernGroups()
    .flatMap((group) => ['#' + group.title].concat(group.sections))));
  assert.deepEqual(fromPolicy, modernCalls.map((call) => call.startsWith('#') ? call : sectionIds[call]));
  const all = { remoteAi: true, proDebug: false, pro: true };
  // spacer, search, account | 通用 heading → 个性化 header at 4.
  assert.equal(policy.settingsModernSectionIndex('appearance', all), 4);
  assert.equal(policy.settingsModernSectionIndex('homeLayout', all), 6);
  assert.equal(policy.settingsModernSectionIndex('displayInteraction', all), 11);
  assert.equal(policy.settingsModernSectionIndex('windowsRdp', all), 16);
  assert.equal(policy.settingsModernSectionIndex('remoteAi', all), 29);
  assert.equal(policy.settingsModernSectionIndex('remoteAi', { remoteAi: false, proDebug: true, pro: false }), -1);
  assert.equal(policy.settingsModernSectionIndex('security', { remoteAi: false, proDebug: true, pro: false }), 33);
  // Each section builder renders as many ListItems as the policy counts.
  for (const [name, id] of Object.entries(sectionIds)) {
    const body = member(page, '@Builder settingsSection' + name + '() {');
    const items = (body.match(/\n    ListItem\(\)/g) || []).length;
    assert.equal(items, policy.settingsModernSectionItemCount(id, { remoteAi: true, proDebug: true, pro: true }), name);
  }
});

check('settings search finds rows by name or everyday words and opens them like the AI does', () => {
  const search = loadTree('services/SettingsSearchCatalog');
  const actions = loadTree('services/diagnosticAi/DiagnosticAiAppActionPolicy');
  const entries = search.settingsSearchEntries();
  assert.ok(entries.length >= 90);
  const top = (query) => (search.settingsSearchMatches(query, entries, 5)[0] || { title: '' }).title;
  assert.equal(top('滚轮'), '远程滚轮方向');
  assert.equal(top('深色'), '深色模式');
  assert.equal(top('暗色'), '深色模式');
  assert.equal(top('h265'), 'RustDesk 编码');
  assert.equal(top('rdp 音频'), 'RDP 远端音频');
  assert.equal(top('API Key'), '辅助 AI 配置');
  assert.equal(top('全新'), '全新视觉');
  assert.equal(search.settingsSearchMatches('完全无关的词', entries, 5).length, 0);
  assert.equal(search.settingsSearchMatches('   ', entries, 5).length, 0);
  const page = read('pages/HostListPage.ets');
  const requirement = member(page, 'private settingsSearchRequirementMet(requires: string): boolean {');
  const seen = new Set();
  for (const entry of entries) {
    assert.ok(!seen.has(entry.section + entry.title), 'duplicate ' + entry.title);
    seen.add(entry.section + entry.title);
    if (entry.action.startsWith('ai:')) {
      assert.ok(Number.isInteger(Number(entry.action.slice(3))), entry.title);
    } else if (entry.action !== '') {
      assert.ok(actions.diagnosticAiAppActionId(entry.action), entry.title + ' → ' + entry.action);
      assert.ok(page.includes("case '" + entry.action + "':"), entry.action + ' is handled by the page');
    }
    assert.ok(entry.requires === '' || requirement.includes("case '" + entry.requires + "':"), entry.requires);
    assert.notEqual(search.settingsSectionTitle(entry.section), '设置', entry.title);
  }
});

check('the new look changes only what it gates; classic values stay as they were', () => {
  const page = read('pages/HostListPage.ets');
  const sections = page.slice(page.indexOf('  @Builder settingsSectionAppearance() {'),
    page.indexOf('  /** 全新视觉: the same sections as the classic page'));
  // Every row height in the sections is either a fixed classic number or the gated auto height.
  for (const match of sections.matchAll(/\.height\(([^)]+)\)/g)) {
    assert.ok(/^\d+$/.test(match[1]) || /^this\.settingsModern\(\) \? 'auto' : \d+$/.test(match[1]) ||
      /^'100%'$/.test(match[1]) || match[1].startsWith('this.') || /^[\d.]+$/.test(match[1]), match[1]);
  }
  assert.ok(!/Text\(' >'\)/.test(sections), 'text arrows go through settingsRowChevron');
  assert.ok(member(page, '@Builder settingsRowChevron(leftMargin: number) {')
    .includes("Text(' >').fontSize(14).fontColor(this.pal().text3).margin({ left: leftMargin })"));
  for (const glyph of ["'⌖', 22, false", "'Aa', 16, true", "'T', 14, true", "'◎', 22, false"]) {
    assert.ok(sections.includes('this.settingsRowGlyph(' + glyph), glyph);
  }
  assert.ok(member(page, '@Builder settingsAccountGlyph() {').includes("Text('👤').fontSize(30)"));
  // Subtitles: classic keeps 11/text3 (or 10/text3), the new look reads 12/text2.
  assert.ok(!/\.fontSize\(11\)\.fontColor\(this\.pal\(\)\.text3\)/.test(sections));
  const header = member(page, '@Builder settingsAccordionHeader(');
  assert.ok(header.includes(".height(this.settingsModern() ? 'auto' : 64)"));
  assert.ok(header.includes('this.settingsSectionSummary(section, subtitle, this.settingsValuesRevision)'));
  assert.ok(page.includes("constraintSize({ maxWidth: this.settingsModern() && this.breakpoint !== 'sm' ? 760 : '100%' })"));
  assert.ok(member(page, 'private settingsLeafSheetWidth(): number | undefined {')
    .includes('if (!this.settingsModern() || this.settingsLeafUsesBottomSheet()) { return undefined; }'));
  assert.ok(member(page, 'private settingsSectionExpandedMaxHeight(section: string): number {')
    .includes('Math.ceil(classic * 1.5) : classic'));
});

check('inline fields save once confirmed, and the RDP account format fits a phone card', () => {
  const page = read('pages/HostListPage.ets');
  const drive = member(page, '@Builder rdpDriveNameRow() {');
  assert.ok(drive.includes('.onBlur((): void => { this.commitRdpDriveNameDraft(); })'));
  assert.ok(!drive.includes('.onChange((v: string): void => { this.saveRdpDriveName(v); })'));
  const scale = member(page, '@Builder remoteDisplayScaleRow() {');
  assert.ok(scale.includes('.onBlur((): void => { this.commitRemoteDisplayScaleDraft(); })'));
  assert.ok(!scale.includes('this.saveRemoteDisplayCustomScalePercent(value)'));
  assert.ok(member(page, 'private commitRemoteDisplayScaleDraft(): void {').includes('if (!valid) {'));
  // Five chips plus gaps and padding within a phone card (about 288vp).
  const phone = 5 * 52 + 4 * 2 + 6;
  assert.ok(phone <= 288, String(phone));
  assert.ok(page.includes("private rdpAuthChipWidth(): number { return this.breakpoint === 'sm' ? 52 : 58; }"));
});

check('batch B review: VNC scale words, phone-only rows, real Moonlight values, typing after Enter', () => {
  const policy = loadTree('services/SettingsModernPolicy');
  assert.equal(policy.settingsVncDisplayScaleLabel('fit', 100), '适应窗口');
  assert.equal(policy.settingsVncDisplayScaleLabel('100', 100), '100%');
  assert.equal(policy.settingsVncDisplayScaleLabel('integer', 100), '整数倍率');
  assert.equal(policy.settingsVncDisplayScaleLabel('custom', 135), '自定义 135%');
  const search = loadTree('services/SettingsSearchCatalog');
  const grip = search.settingsSearchEntries().find((entry) => entry.title === '握持手感知对齐');
  assert.equal(grip.requires, 'touchDevice');
  const page = read('pages/HostListPage.ets');
  const values = member(page, 'private settingsRowCurrentValue(label: string, _revision: number): string {');
  const summary = member(page, 'private settingsSectionSummary(section: string, fallback: string, _revision: number): string {');
  for (const body of [values, summary]) {
    assert.ok(!body.includes('this.moonlightSettingsService.load()'), 'Moonlight is read through the snapshot');
    assert.ok(body.includes('this.moonlightSnapshot(this.settingsValuesRevision)'));
  }
  assert.ok(values.includes('vnc.displayScaleMode, vnc.customScalePercent'));
  assert.ok(member(page, 'private moonlightSnapshot(revision: number): MoonlightSettings | null {')
    .includes('loaded.ok ? loaded.settings : null'));
  assert.ok(member(page, '@Builder rdpDriveNameRow() {')
    .includes('if (!this.rdpDriveNameEditing && v !== this.rdpDriveName) { this.rdpDriveNameEditing = true; }'));
  const hopeless = member(page, 'private remoteDisplayScaleDraftHopeless(): boolean {');
  assert.ok(hopeless.includes('return value < 50 && value * 10 > 300;'));
  // 1 → 15 → 150 shows no warning; 31 and 400 do.
  const isHopeless = (text) => !/^\d+$/.test(text) || Number(text) > 300 || (Number(text) < 50 && Number(text) * 10 > 300);
  for (const prefix of ['1', '15', '150', '30', '300']) { assert.equal(isHopeless(prefix), false, prefix); }
  for (const bad of ['31', '400', '1a']) { assert.equal(isHopeless(bad), true, bad); }
});

// ------------------------------------------------------------------ batch C: settings sheets in 全新视觉
check('shared sheet chrome: optional white-on-accent text and saved flash, defaults unchanged for the AI pages', () => {
  const header = read('components/AppSheetHeader.ets');
  assert.ok(header.includes('@Prop whiteOnAccent: boolean = false;'));
  assert.ok(header.includes('@Prop savedTick: number = 0;'));
  assert.ok(header.includes('this.whiteOnAccent ? appUiOnAccentText(this.accent) : appUiButtonText(this.accent)'));
  const choice = read('components/AppSettingsChoiceButton.ets');
  assert.ok(choice.includes('@Prop whiteOnAccent: boolean = false;'));
  // The remote AI pages keep the old contrast choice (they never pass whiteOnAccent).
  for (const file of ['pages/AiSettingsPage.ets', 'pages/RemoteAiWorkspace.ets', 'components/ai/AiHostInstallPanel.ets']) {
    assert.ok(!read(file).includes('whiteOnAccent'), file);
  }
});

check('settings sheets switch to the shared header only in 全新视觉 and keep their classic header otherwise', () => {
  const sheets = {
    'components/RemoteWheelDirectionSettingsSheet.ets': "title: '滚轮方向'",
    'components/RemotePinchZoomSettingsSheet.ets': "title: '双指缩放'",
    'components/RemotePortraitDisplaySettingsSheet.ets': "title: '竖屏显示'",
    'components/RemoteSessionControlBarSettingsSheet.ets': "title: '会话侧栏与顶栏'",
    'components/SecretVisibilitySettingsSheet.ets': "title: '密码与秘密回显'",
    'components/ColorPickerSheet.ets': "title: '主题色'",
    'components/FeedbackSettingsSheet.ets': "title: '反馈'",
    'components/DiagnosticCaptureSettingsSheet.ets': "title: '日志'",
    'components/VirtualKeyboardSettingsSheet.ets': 'title: this.pageTitle()'
  };
  for (const [file, title] of Object.entries(sheets)) {
    const source = read(file);
    assert.ok(source.includes("@StorageProp('settingsVisualStyle') visualStyle: string = 'classic';"), file);
    const at = source.indexOf('AppSheetHeader({ ' + title);
    assert.ok(at > 0, file + ' uses the shared header');
    assert.ok(source.slice(Math.max(0, at - 200), at).includes('this.modern()'), file + ' gates it');
  }
  for (const file of ['components/RemoteWheelDirectionSettingsSheet.ets', 'components/RemotePinchZoomSettingsSheet.ets',
    'components/RemotePortraitDisplaySettingsSheet.ets', 'components/RemoteSessionControlBarSettingsSheet.ets',
    'components/SecretVisibilitySettingsSheet.ets']) {
    const source = read(file);
    assert.ok(source.includes('} else {\n        this.header()\n      }'), file + ' keeps its classic header');
    assert.ok(source.includes('savedTick: this.savedTick'), file + ' flashes 已保存 in the shared header');
    // Switches read the sheet's state directly, so a failed save still flips them back.
    assert.ok(!source.includes('AppSettingsSwitchRow('), file);
  }
  const about = read('components/AboutSettingsSheet.ets');
  for (const title of ['操作引导中心', '关于应用', '隐私政策', '连接前准备']) {
    assert.ok(about.includes("AppSheetHeader({ title: '" + title + "'"), title);
  }
  const skin = read('components/ssh/skin/SshSkinSettingsPanel.ets');
  assert.ok(skin.includes(".onClick((): void => { this.skinMenu(skin); })"), 'a visible edit button opens the skin menu');
  assert.ok(skin.includes('.gesture(LongPressGesture({ duration: 450 }).onAction((): void => { this.skinMenu(skin); }))'));
  for (const [file, gate] of [['components/ProFeatureManagerPanel.ets', 'this.showClose && settingsVisualIsModern(this.visualStyle)'],
    ['components/ProAppIconPanel.ets', 'this.showClose && settingsVisualIsModern(this.visualStyle)'],
    ['components/rdp/RdpDisplayProfilePanel.ets', 'this.showClose && !this.forceDark && settingsVisualIsModern(this.visualStyle)']]) {
    assert.ok(read(file).includes(gate), file);
  }
});

check('the host page sheets use the shared header in 全新视觉 and drop the shadow inside a sheet', () => {
  const page = read('pages/HostListPage.ets');
  for (const builder of ['@Builder wallPicker() {', '@Builder haloColorSheet() {', '@Builder terminalFgColorSheet() {',
    '@Builder terminalFontSizeSheet() {', '@Builder terminalLineSpacingSheet() {', '@Builder keyVaultSheet() {',
    '@Builder sshHostKeyManagerSheet() {', '@Builder rdpCertificateManagerSheet() {',
    '@Builder rustDeskAuthTrustManagerSheet() {', '@Builder accountSheet() {', '@Builder cryptoSheet() {',
    '@Builder rdpCredentialSheet() {', '@Builder rdpCredentialEditorSheet() {']) {
    const body = member(page, builder);
    assert.ok(body.includes('if (this.settingsModern()) {') && body.includes('AppSheetHeader({'), builder);
  }
  assert.ok(member(page, '@Builder terminalFontSizeSheet() {').includes("subtitle: '当前 ' + this.terminalFontSize + 'vp，点选即保存'"));
  assert.ok(member(page, '@Builder keyVaultSheet() {').includes('密钥库里还没有 SSH 密钥'));
  for (const builder of ['@Builder rdpCredentialSheet() {', '@Builder rdpCredentialEditorSheet() {']) {
    assert.ok(member(page, builder).includes(".shadow(this.breakpoint === 'sm' || this.settingsModern()"), builder);
  }
  assert.ok(page.includes("ColorPickerSheet({ onClose: (): void => { this.closeSettingsLeafSheetByUser(); } })"));
  assert.ok(member(page, 'onPageShow(): void {').includes('this.settingsValuesRevision++;'));
});

console.log('settings overhaul: ' + passed + ' checks passed');
