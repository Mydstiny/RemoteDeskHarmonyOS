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

console.log('settings overhaul batch A: ' + passed + ' checks passed');
