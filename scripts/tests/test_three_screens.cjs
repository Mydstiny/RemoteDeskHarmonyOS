'use strict';
/*
 * 远程主机 / 密钥保险库 / 中继 优化 (2026-10-06). Batch 1, 中继 in both looks: tests that do not overwrite edits and
 * probe both endpoints, Pro account safety, VNC checks in plain words, scrollable sheets and the bound-host link.
 */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.AI_TYPESCRIPT_PATH || 'typescript');

const ETS = path.resolve(__dirname, '../../entry/src/main/ets');
const read = (file) => fs.readFileSync(path.join(ETS, file), 'utf8');
function load(file) {
  const output = ts.transpileModule(read(file + '.ets'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(output, { module, exports: module.exports, require: () => ({}), Math, Number, String, JSON, Set, Map },
    { filename: file });
  return module.exports;
}
/** The body of a member, up to the next member at the same indent. */
function member(source, signature) {
  const start = source.indexOf(signature);
  assert.ok(start >= 0, 'missing ' + signature);
  const next = source.slice(start + signature.length).search(/\n  (?:@Builder |private |build\(|aboutTo|async |onPage)/);
  return next < 0 ? source.slice(start) : source.slice(start, start + signature.length + next);
}
let passed = 0;
function check(name, run) { run(); passed++; console.log('PASS ' + name); }

check('relay tests probe both endpoints and say what failed', () => {
  const policy = load('services/RelayDirectoryPolicy');
  assert.equal(policy.summarizeRustDeskRelayProbe(true, 12, true, 34).status, 'online');
  assert.equal(policy.summarizeRustDeskRelayProbe(false, 0, true, 34).status, 'error', 'a dead ID server is not online');
  assert.equal(policy.summarizeRustDeskRelayProbe(false, 0, true, 34).detail, 'ID 服务器不可达，中继服务器可达');
  assert.equal(policy.summarizeRustDeskRelayProbe(false, 0, false, 0).status, 'offline');
  assert.match(policy.relayDeleteMessage(3, 2), /3 台主机正在使用它/);
  assert.match(policy.relayDeleteMessage(0, 2), /2 个 Server Pro 账户/);
  assert.equal(policy.vncGatewayCheckMessage('E-VNC-CERT-TRUST-REQUIRED', ''), '需要先确认这台网关的证书');
  assert.equal(policy.vncGatewayCheckMessage('', '请在证书信任 Sheet 中确认'), '请在证书信任弹窗中确认');
  assert.equal(policy.vncGatewayCheckMessage('E-VNC-RFB-BANNER', 'RFB banner 无效'), 'VNC 响应无效');
  assert.equal(policy.vncGatewayCheckMessage('E-VNC-X', 'E-VNC-X'), '检查失败', 'a bare code is not shown as the message');
  assert.equal(policy.relaySaveStageLabel('committing'), '正在保存到本机…');
  assert.equal(policy.vncGatewayCheckMessage('', 'targetId 无效'), 'targetId 无效', 'only whole words are replaced');
});

check('a relay test writes only the health fields, into the current record, and runs per relay', () => {
  const sync = read('services/HostSyncService.ets');
  const health = member(sync, 'updateRelayHealth(id: string, status: string, latency: number, checkedAt: number,');
  assert.ok(health.includes('const current: RustDeskRelayConfig | undefined = this.relays.get(id);') &&
    health.includes('next.healthStatus = status;') && health.includes('return this.updateRelay(next);'));
  const page = read('pages/RustDeskRelayPage.ets');
  const test = member(page, 'private async doTestRelay(relay: RustDeskRelayConfig): Promise<void> {');
  assert.ok(test.includes('if (this.isRelayTesting(id)) { return; }'));
  assert.ok(test.includes('this.tcpTest(relay.idServer, relay.idServerPort)') && test.includes('this.tcpTest(relay.relayServer, relay.relayPort)'));
  assert.ok(test.includes('this.srv.updateRelayHealth(id, summary.status, summary.latency, checkedAt, tested)'),
    'written only onto the endpoints it tested');
  assert.ok(health.includes('if (testedEndpoints !== \'\' && testedEndpoints !== relayEndpointSignature('));
  assert.ok(!test.includes("healthStatus = 'unknown'") && !test.includes('this.srv.updateRelay('), 'no whole-record write');
  assert.ok(!/testingRelayId\b/.test(page), 'one id per test, not one test at a time');
  for (const builder of ['@Builder rightSwipeActions(relay: RustDeskRelayConfig) {', '@Builder leftSwipeActions(relay: RustDeskRelayConfig) {',
    '@Builder pcMenuBuilder(relay: RustDeskRelayConfig) {']) {
    assert.ok(member(page, builder).includes('this.isRelayTesting(relay.id)'), builder);
  }
});

check('Pro accounts: masked password, partial login explained in the sheet, sync busy, logout confirmed', () => {
  const page = read('pages/RustDeskRelayPage.ets');
  const sheet = member(page, '@Builder proAccountEditSheet() {');
  assert.ok(sheet.includes("this._f('密码', '不会保存密码', this.formProPwd, (v: string) => { this.formProPwd = v; }, true)"));
  assert.ok(sheet.includes("SymbolGlyph($r('sys.symbol.xmark'))"), 'the sheet can be closed');
  assert.ok(member(page, 'private async doProLogin(): Promise<void> {').includes('this.formProNotice = toast.message;'));
  assert.ok(member(page, 'private async doProSync(accountId: string): Promise<void> {').includes('this.proSyncingIds.indexOf(accountId) >= 0'));
  const logout = member(page, 'private doProLogout(accountId: string): void {');
  assert.ok(logout.includes('promptAction.showDialog({') && logout.includes('this.removeProAccount(accountId)'));
  const remove = member(page, 'private async removeProAccount(accountId: string): Promise<void> {');
  assert.ok(remove.includes('catch (err)') && remove.includes("this.formProError = '没有删除：'") && remove.includes('finally'));
  assert.ok(member(page, 'private closeSheet(): void {').includes('if (!this.showSheet) { return; }'),
    'closing a sheet that is already gone does not leave the page stuck in closing');
});

check('VNC checks: structured state, a running check survives a closed sheet, cancel is per gateway', () => {
  const page = read('pages/RustDeskRelayPage.ets');
  assert.ok(!/startsWith\('✓'\)|startsWith\('✗'\)|'⏳|'✓ |'✗ /.test(page), 'no glyph-prefixed result strings');
  const dismiss = member(page, 'private finishSheetDismiss(): void {');
  assert.ok(!dismiss.includes("this.testingVncGatewayId = '';") && !dismiss.includes("this.vncTestResult = '';"));
  assert.ok(dismiss.includes('const next: (() => void) | null = this.afterSheetDismiss;'));
  const cancel = member(page, 'private cancelDeepTestVncGateway(gatewayId: string): void {');
  assert.ok(cancel.includes('this.testingVncGatewayId !== gatewayId') && cancel.includes("this.setVncCheck(gatewayId, 'cancelled', '已取消深度检查');"));
  assert.ok(!page.includes('this.cancelDeepTestVncGateway();'));
  assert.ok(page.includes('onRecheck: (trust: VncTrustView, _hostId: string): void => { this.recheckGatewayAfterTrust(trust); }'));
  const recheck = member(page, 'private recheckGatewayAfterTrust(trust: VncTrustView): void {');
  assert.ok(recheck.includes("if (trust.ownerType !== 'gateway') {") && recheck.includes('const gatewayId: string = trust.ownerId;'),
    're-checks the gateway of the row that was tapped');
  const deep = member(page, 'private async doDeepTestVncGateway(gateway: VncGatewayView): Promise<void> {');
  assert.ok(deep.includes('!this.showSheet && !this.relaySheetClosing'), 'never replaces a sheet the user is in');
  assert.ok(member(page, 'private gatewayAwaitsCertificate(gateway: VncGatewayView): boolean {')
    .includes('return this.pendingTrustGatewayId === gateway.id;'));
  assert.ok(member(page, '@Builder vncCheckResultView(gateway: VncGatewayView, size: number) {')
    .includes('this.openPendingVncCertificateTrust();'), '确认证书 reaches the pending certificate');
});

check('sheets scroll inside the window; the bound-host link opens the host list; deletes report back', () => {
  const page = read('pages/RustDeskRelayPage.ets');
  for (const builder of ['@Builder relayEditSheet() {', '@Builder relaySavedSheet() {', '@Builder proAccountEditSheet() {']) {
    assert.ok(member(page, builder).includes('.constraintSize({ maxHeight: this.sheetScrollMaxHeight() })'), builder);
  }
  for (const builder of ['@Builder pcDetailPanelContent() {', '@Builder vncGatewayDetailPanelContent() {']) {
    assert.ok(member(page, builder).includes('Scroll() {'), builder);
  }
  assert.ok(!page.includes("Text('查看 →')") && page.includes('this.onShowRelayHosts((this.selectedPcRelay as RustDeskRelayConfig).id)'));
  const host = read('pages/HostListPage.ets');
  assert.ok(host.includes('onShowRelayHosts: (relayId: string): void => { this.showRelayHostsFromRelayPage(relayId); },'));
  assert.ok(member(host, 'private showRelayHostsFromRelayPage(relayId: string): void {').includes('this.searchText = relay.displayName();'));
  const filter = read('services/HostListFilterService.ets');
  assert.ok(filter.includes("host.protocol === 'rustdesk' && host.rustdeskRelayId !== ''"), 'lists every host the card counts');
  const del = member(page, 'private doDeleteRelay(id: string): void {');
  assert.ok(del.includes('relayDeleteMessage(this.hostCountForRelay(id), this.accountCountForRelay(id))') &&
    del.includes("'已删除中继服务器'") && del.includes('if (!this.srv.removeRelay(id)) {'));
  assert.ok(member(page, 'private doDeleteVncGateway(gateway: VncGatewayView): void {').includes("'已删除 VNC Gateway'"));
  assert.ok(!page.includes('@Builder leftSwipeDelete('), 'the unused builder is gone');
  assert.ok(!/fontColor\('#FFFFFF'\)\.borderRadius\(8\)/.test(page));
  assert.ok(page.includes('(relay: RustDeskRelayConfig): string => this.relayCardKey(relay))'), 'cards rebuild only on change');
});

// ------------------------------------------------------------------ batch 2: 密钥保险库, both looks
check('2FA secrets and imports follow one rule in both add flows', () => {
  const policy = load('services/KeyVaultFormPolicy');
  assert.equal(policy.normalizeTotpSecret(' abcd efgh '), 'ABCDEFGH');
  assert.equal(policy.totpSecretProblem('ABC1', []), '密钥（Secret）只能包含字母 A–Z 和数字 2–7');
  assert.equal(policy.totpSecretProblem('ABCDEFGH', ['ABCDEFGH']), '这个 2FA 账户已经添加过了');
  assert.equal(policy.totpImportSummary(2, 1), '已导入 2 个，跳过 1 个已存在或无效的账户');
  const page = read('pages/KeyVaultPage.ets');
  const add = member(page, 'private doAddTotp(): void {');
  assert.ok(add.includes('totpSecretProblem(secret, this.existingTotpSecrets())') &&
    add.includes('entry.algorithm = this.formAlgorithm as TotpAlgorithm;'), 'keeps SHA256/512 from a parsed URI');
  assert.ok(member(page, 'private parseOtpAuthInput(): void {').includes('this.formAlgorithm = parsed.algorithm;'));
  const imp = member(page, 'private async importTotpFile(): Promise<void> {');
  assert.ok(imp.includes('this.totpImporter.pickAndParse()') && !imp.includes('fromCharCode'), 'UTF-8 and every format');
  const scan = member(page, 'private onQrScanned(entry: TotpEntry): void {');
  assert.ok(scan.includes('this.showSheet = false;') && scan.includes('totpSecretProblem('), 'the form closes too');
  assert.ok(!/\[CC-SSHKEY-|\[importTotp\]/.test(page + read('components/SshKeyManagerSheet.ets') +
    read('components/SshKeyInstallSheet.ets')), 'no internal codes in messages');
});

check('selection belongs to one list, taps select in multi-select, locked keys stay protected in batches', () => {
  const page = read('pages/KeyVaultPage.ets');
  assert.ok(page.includes("@Link @Watch('onInnerTabChange') keyVaultInnerTab: number;"));
  assert.ok(member(page, 'private onInnerTabChange(): void {').includes('this.selectionMode = false;'));
  const batch = member(page, 'private doBatchDelete(): void {');
  assert.ok(batch.indexOf('promptAction.showDialog({') < batch.indexOf('showLockGate('), 'confirm first, then verify once');
  assert.ok(batch.includes('keyVaultBatchDeleteMessage(ids.length, locked.length, ssh)') && batch.includes("'已删除 '"));
  const lock = member(page, 'private async toggleSshLock(key: SshKey): Promise<void> {');
  assert.ok(lock.indexOf('if (key.locked) {') < lock.indexOf('showLockGate('), 'only unlocking asks for verification');
  const card = read('components/SshKeyCard.ets');
  assert.ok(card.includes('if (this.showCheckbox) {\n          if (this.onCheckChange) { this.onCheckChange(!this.checkboxSelected); }'));
  assert.ok(card.includes('.selectedColor(this.accentColor)') && card.includes("Text('公钥未生成')"));
  const totp = read('components/TotpCodeCard.ets');
  assert.ok(totp.includes('if (this.isDesktopDevice && !this.showCheckbox && !this.pageLocked) {'), 'PC can rename and delete one entry');
  assert.ok(member(totp, 'private async unlockEntry(): Promise<void> {').includes("showLockGate(this.primaryLabel(), 'biometric')"));
  assert.ok(!page.includes('@Builder sshKeyContent()') && !page.includes('@Builder totpContent()') &&
    !page.includes('@Builder selectionDeleteBtn()'), 'dead builders are gone');
});

check('2FA relocks in the background; turning protection on starts locked', () => {
  const page = read('pages/KeyVaultPage.ets');
  assert.ok(page.includes("@StorageLink('totpUnlocked') totpUnlocked: boolean = false;"));
  assert.ok(member(page, 'private onAppBackground(): void {').includes('this.totpUnlocked = false;'));
  assert.ok(read('pages/HostListPage.ets').includes("// Protection starts locked: an earlier unlock of the 2FA page does not carry over.\n                      AppStorage.setOrCreate('totpUnlocked', false);"));
});

check('key sheets report real results, a removal is its own step, installs never dead-end', () => {
  const page = read('pages/KeyVaultPage.ets');
  assert.ok(member(page, 'private onKeyManagerChange(updated: SshKey): boolean {').includes('if (!this.kvs.updateSshKey(updated)) { return false; }'));
  const manager = read('components/SshKeyManagerSheet.ets');
  assert.ok(manager.includes("const saved: boolean = this.onChange ? this.onChange(updated) : false;"));
  assert.ok(manager.includes("SshKey.typeLabel(this.sshKey.keyType)") && manager.includes('Flex({ wrap: FlexWrap.Wrap })'));
  assert.ok(manager.includes("title: '移除私钥密码？'") && manager.includes('this.onManagePassphrase(this.sshKey, true)'));
  assert.ok(manager.includes('if (this.viewportHeight > 0) {'), 'fits the window, not the screen');
  const sub = member(manager, 'private submit(): void {');
  assert.ok(sub.includes("if (!this.removeMode && this.newPass === '') {"), 'changing needs a new password');
  const install = read('components/SshKeyInstallSheet.ets');
  assert.ok(install.includes("Button('重试')") && install.includes("Button('返回')") && install.includes("Button('取消')"));
  assert.ok(install.includes('if (result[\'ok\'] && targetKey.privateKeyEncrypted) {'), 'keys with a passphrase skip verification');
  assert.ok(member(install, 'private backToHostChoice(): void {').includes('this.installGeneration++;'));
  assert.ok(install.indexOf("Text('安装成功后，这台主机改用新密钥登录')") < install.indexOf("Button('安装公钥')"));
  assert.ok(page.includes('removeMode: this.passphraseRemoveMode,'));
});

check('classic forms: multi-line private keys, detected types, busy saves; PC offers no camera scan', () => {
  const page = read('pages/KeyVaultPage.ets');
  assert.ok(page.includes("TextArea({ placeholder: '粘贴 OpenSSH 格式私钥...', text: this.formPasteKey })"));
  assert.ok(page.includes("key.keyType = sshKeyTypeFromName(info['keyType'], key.keyType);"));
  assert.ok(member(page, 'private async doAddSshKey(): Promise<void> {').includes('if (this.savingKey) { return; }'));
  assert.ok(page.includes("      if (!this.isDesktopDevice) {\n        Button() {"), 'the classic form hides the scanner on PC');
  assert.ok(read('components/resourceadd/ResourceFabPicker.ets').includes("if (!this.isDesktopDevice) {\n          this.option('scan'"));
  const modern = read('components/resourceadd/modern/ModernKeyVaultAddFlow.ets');
  assert.ok(modern.includes("this.errorText = '两次输入的密钥密码不一致'") && modern.includes("Button(this.busy ? '生成中…' : '生成密钥')"));
  assert.ok(modern.includes('// File imports report on this step: there is no other step to show their errors.'));
  assert.ok(modern.includes(".constraintSize({ maxHeight: this.stepMaxHeight() })"));
  assert.ok(!/Color\.White/.test(modern));
  assert.ok(read('components/QrCodeScanner.ets').includes('if (this.showTitle) {'));
});

console.log('three screens: ' + passed + ' checks passed');
