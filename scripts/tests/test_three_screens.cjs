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
  assert.ok(scan.includes('this.closeKeyVaultSheet();') && scan.includes('totpSecretProblem('), 'the form closes too');
  assert.ok(!/\[CC-SSHKEY-|\[importTotp\]/.test(page + read('components/SshKeyManagerSheet.ets') +
    read('components/SshKeyInstallSheet.ets')), 'no internal codes in messages');
});

check('selection belongs to one list, taps select in multi-select, locked keys stay protected in batches', () => {
  const page = read('pages/KeyVaultPage.ets');
  assert.ok(page.includes("@Link @Watch('onInnerTabChange') keyVaultInnerTab: number;"));
  assert.ok(member(page, 'private onInnerTabChange(): void {').includes('this.selectionMode = false;'));
  const batch = member(page, 'private doBatchDelete(): void {');
  assert.ok(batch.indexOf('promptAction.showDialog({') < batch.indexOf('showLockGate('), 'confirm first, then verify once');
  assert.ok(batch.includes('keyVaultBatchDeleteMessage(ids.length, this.lockedSelectionCount(ids, ssh), ssh)') &&
    batch.includes("'已删除 '"));
  assert.ok(batch.includes('const lockedNow: number = this.lockedSelectionCount(ids, ssh);'), 'locks read after the confirmation');
  assert.ok((batch.match(/if \(!ssh && this\.totpListLocked\(\)\) \{/g) || []).length === 2, 'a locked 2FA page cannot be batch deleted');
  assert.ok(page.includes("if (this.selectionMode && !(this.keyVaultInnerTab === 1 && this.totpListLocked())) {"),
    'no selection toolbar over a locked 2FA page');
  assert.ok(member(page, 'private onTotpLockChange(): void {').includes('this.selectionMode = false;'));
  assert.ok(member(page, 'private async deleteTotpItem(entry: TotpEntry): Promise<void> {').includes('if (entry.locked) {'));
  const lock = member(page, 'private async toggleSshLock(key: SshKey): Promise<void> {');
  assert.ok(lock.indexOf('if (key.locked) {') < lock.indexOf('showLockGate('), 'only unlocking asks for verification');
  const card = read('components/SshKeyCard.ets');
  assert.ok(card.includes('if (this.showCheckbox) {\n          if (this.onCheckChange) { this.onCheckChange(!this.checkboxSelected); }'));
  assert.ok(card.includes('.selectedColor(this.accentColor)') && card.includes("Text('公钥未生成')"));
  const totp = read('components/TotpCodeCard.ets');
  assert.ok(totp.includes('if ((this.isDesktopDevice || settingsVisualIsModern(this.visualStyle)) && !this.showCheckbox && !this.pageLocked) {'),
    'PC (and 全新视觉) can rename and delete one entry');
  assert.ok(member(totp, 'private async unlockEntry(): Promise<void> {').includes("showLockGate(this.primaryLabel(), 'biometric')"));
  assert.ok(!page.includes('@Builder sshKeyContent()') && !page.includes('@Builder totpContent()') &&
    !page.includes('@Builder selectionDeleteBtn()'), 'dead builders are gone');
});

check('2FA relocks in the background; turning protection on starts locked', () => {
  const page = read('pages/KeyVaultPage.ets');
  assert.ok(page.includes("@StorageLink('totpUnlocked') @Watch('onTotpLockChange') totpUnlocked: boolean = false;"));
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
  assert.ok(page.includes("key.keyType = info['keyType'] !== '' ? sshKeyTypeFromNative(info['keyType']) : key.keyType;"));
  assert.ok(page.includes("if (key.privateKey.indexOf('BEGIN RSA PRIVATE KEY') >= 0) { key.keyType = SshKeyType.RSA; }"),
    'an encrypted PEM key keeps its type');
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

check('batch 2 review: scans and imports keep the 2FA page unlocked; backups keep algorithm and names', () => {
  const page = read('pages/KeyVaultPage.ets');
  assert.ok(member(page, 'private onAppBackground(): void {').includes('!keyVaultPickerExplainsBackground()'));
  for (const file of ['components/QrCodeScanner.ets', 'components/resourceadd/modern/ModernKeyVaultAddFlow.ets', 'pages/KeyVaultPage.ets']) {
    const text = read(file);
    assert.ok(text.includes('beginKeyVaultExternalPicker();') && text.includes('endKeyVaultExternalPicker();'), file);
    assert.ok(!text.includes('keyVaultExternalPickerActive'), file);
  }
  const parser = read('services/AtsfTotpImportParser.ets');
  assert.ok(parser.includes('entry.algorithm = algorithmValue as TotpAlgorithm;') && parser.includes('entry.displayName ='));
  const modern = read('components/resourceadd/modern/ModernKeyVaultAddFlow.ets');
  assert.ok(modern.includes("if (this.passphrase !== '' && this.passphrase !== this.passphraseConfirm)"));
  assert.ok(modern.includes('totpSecretProblem(normalized, this.existingSecrets())'), 'one duplicate rule');
  const install = read('components/SshKeyInstallSheet.ets');
  assert.ok(install.includes("Button('重新安装并验证')") && install.includes("'已取消验证；公钥已写入这台主机'"));
  assert.ok(install.includes('.enabled(!this.targetEncrypted())'));
});

check('batch 2 review 2: a picker keeps 2FA open only for a while; an encrypted PKCS#8 key has no guessed type', () => {
  const policy = load('services/KeyVaultFormPolicy');
  assert.equal(policy.keyVaultPickerKeepsUnlocked(0, 1000), false, 'no picker open');
  assert.equal(policy.keyVaultPickerKeepsUnlocked(1000, 1000 + policy.KEY_VAULT_PICKER_GRACE_MS), true);
  assert.equal(policy.keyVaultPickerKeepsUnlocked(1000, 1001 + policy.KEY_VAULT_PICKER_GRACE_MS), false, 'left open too long');
  assert.equal(policy.keyVaultPickerKeepsUnlocked(5000, 1000), false, 'clock went back');
  assert.equal(policy.sshKeyTypePending('BEGIN ENCRYPTED PRIVATE KEY (header text only)', ''), true);
  assert.equal(policy.sshKeyTypePending('BEGIN ENCRYPTED PRIVATE KEY (header text only)', 'ssh-rsa AAAA'), false);
  assert.equal(policy.sshKeyTypePending('BEGIN OPENSSH PRIVATE KEY (header text only)', ''), true, 'unreadable when saved');
  assert.equal(policy.sshKeyTypePending('BEGIN OPENSSH PRIVATE KEY (header text only)', 'ssh-ed25519 AAAA'), false);
  assert.equal(policy.sshKeyTypeText('BEGIN ENCRYPTED PRIVATE KEY (header text only)', '', 'RSA'), '类型待识别');
  assert.equal(policy.sshKeyTypeText('x', 'ssh-rsa AAAA', 'RSA'), 'RSA');
  const guard = read('services/KeyVaultPickerGuard.ets');
  assert.ok(guard.includes("AppStorage.setOrCreate<boolean>('totpUnlocked', false);"), 'a long trip relocks on return');
  assert.ok(read('components/SshKeyCard.ets').includes("this.typePending() ? '类型待识别' :"));
  assert.ok(read('components/SshKeyManagerSheet.ets').includes("? '类型待识别' :"));
  const modern = read('components/resourceadd/modern/ModernKeyVaultAddFlow.ets');
  assert.ok(member(modern, 'private saveImportedTotp(): void {').includes('entry.secret = normalizeTotpSecret(entry.secret);'));
  assert.ok(modern.includes("'密钥格式无效，将跳过'"));
});

// ------------------------------------------------------------------ batch 3: 远程主机, both looks
function loadWith(file, deps) {
  const output = ts.transpileModule(read(file + '.ets'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(output, { module, exports: module.exports, require: (spec) => deps[spec] || {}, Math, Number,
    String, JSON, Set, Map }, { filename: file });
  return module.exports;
}
function hostRecord(fields) {
  return Object.assign({ id: 'h', label: '', host: '', username: '', protocol: 'rdp', groupId: '', customHostname: '',
    rustdeskProPeerId: '', locked: false }, fields);
}

check('host search: RustDesk IDs, Chinese group names, locked hosts only by their card name', () => {
  const privacy = load('services/HostCardPrivacyPolicy');
  const policy = loadWith('services/HostWorkspacePolicy', { './HostCardPrivacyPolicy': privacy });
  assert.equal(policy.normalizeGroupId(' 办公室 A '), '办公室-a');
  assert.notEqual(policy.normalizeGroupId('研发部'), policy.normalizeGroupId('办公室'), 'Chinese names no longer collapse to one');
  const rd = hostRecord({ id: 'rd', label: 'Studio', protocol: 'rustdesk', customHostname: '123456789', rustdeskProPeerId: 'peer-42' });
  assert.equal(policy.searchHosts([rd], '1234').length, 1);
  assert.equal(policy.searchHosts([rd], 'PEER-42').length, 1);
  const office = hostRecord({ id: 'o', label: 'PC', groupId: '办公室' });
  assert.equal(policy.searchHosts([office], '办公').length, 1, 'a raw Chinese group id matches');
  const locked = hostRecord({ id: 'l', label: 'Vault', host: '10.0.0.8', username: 'admin', locked: true });
  assert.equal(policy.searchHosts([locked], '10.0.0').length, 0, 'a locked host hides its address');
  assert.equal(policy.searchHosts([locked], 'admin').length, 0);
  assert.equal(policy.searchHosts([locked], 'vault').length, 1);
  const lockedId = hostRecord({ id: 'li', label: '987654321', protocol: 'rustdesk', customHostname: '987654321', locked: true });
  assert.equal(policy.searchHosts([lockedId], '9876').length, 0, 'an ID used as the name stays hidden too');
});

check('batches act on visible hosts, confirm first and verify once; single deletes and locks use the card name', () => {
  const page = read('pages/HostListPage.ets');
  const refresh = member(page, 'private refreshFilteredHostView(): void {');
  assert.ok(refresh.includes('new Set<string>(this.selectionKeysForCurrentView())'), 'hidden hosts leave the selection');
  const batch = member(page, 'private async doHostBatchDelete(): Promise<void> {');
  assert.ok(batch.indexOf('await promptAction.showDialog(') < batch.indexOf('await showLockGate('), 'confirm, then verify');
  assert.equal(batch.split('showLockGate(').length - 1, 1, 'one verification for all locked hosts');
  assert.ok(batch.includes('hostBatchDeleteNameList(names)'));
  assert.ok(batch.includes("(moonlightPreviews.length > 0 ? 'Moonlight 主机还会清理"), 'Moonlight only when selected');
  const single = member(page, 'private async doDeleteHost(host: RemoteHost): Promise<void> {');
  assert.ok(single.includes('hostCardDisplayLabel(') && single.indexOf('showDialog(') < single.indexOf('showLockGate('));
  assert.ok(single.includes("'已删除「' + name + '」'"));
  const lock = member(page, 'private async toggleLock(cardHost: RemoteHost): Promise<void> {');
  assert.ok(lock.includes('this.srv.getHost(cardHost.id) ?? cardHost') && lock.includes('hostCardDisplayLabel('));
  assert.ok(page.includes('if (!this.hostSelectionMode && this.isDesktopDevice) { return {}; }'), 'PC drag sorts only in sort mode');
});

check('saves are announced and a host hidden by a search is brought into view; empty states say why', () => {
  const page = read('pages/HostListPage.ets');
  for (const sig of ['private saveHostFromAddFlow(', 'private saveSshHostFromAddFlow(', 'private saveVncHostFromAddFlow(']) {
    const body = member(page, sig);
    assert.ok(body.includes('this.announceSavedHost('), sig);
    assert.ok(!body.includes('promptAction.showToast('), sig + ' reports failures through addFlowSaveFailed');
  }
  assert.ok(member(page, 'private announceSavedHost(hostId: string, message: string): void {').includes('this.clearHostSearchAndFilters()'));
  assert.ok(page.includes("this.hostSearchOrFilterActive() ? '没有找到匹配的主机' : '还没有远程主机'"));
  assert.ok(page.includes("Button('清除搜索和筛选')"));
  assert.ok(page.includes("(this.hostSearchOrFilterActive() ? '没有匹配的 ' : '暂无 ') + hostGroupTitle(card.type)"));
  assert.ok(!/点击底部/.test(page) && !/到底部「/.test(page), 'no "bottom" in the hints');
});

check('add flows: a close button everywhere, typed names kept, plain summaries, failures in the form', () => {
  const page = read('pages/HostListPage.ets');
  const sheet = member(page, '@Builder hostAddSheetContent() {');
  for (const flow of ['RdpAddFlow({', 'RustDeskAddFlow({', 'MoonlightHostAddFlow({', 'SshAddFlow({', 'VncAddFlow({']) {
    const start = sheet.indexOf(flow);
    const end = sheet.indexOf('\n      })', start);
    const call = sheet.slice(start, end);
    assert.ok(call.includes('onClose: (): void => { this.requestAddSheetCloseByUser(); }'), flow);
    if (flow !== 'MoonlightHostAddFlow({') {
      assert.ok(call.includes('saveError: this.addFlowSaveError') && call.includes('saveErrorRevision: this.addFlowSaveErrorRevision'), flow);
    }
  }
  assert.ok(read('pages/VncSettingsPage.ets').includes('onClose: (): void => { this.hostFlowVisible = false; },'));
  for (const file of ['RdpAddFlow', 'RustDeskAddFlow', 'MoonlightHostAddFlow', 'SshAddFlow']) {
    const text = read('components/hostadd/' + file + '.ets');
    assert.ok(text.includes("SymbolGlyph($r('sys.symbol.xmark'))") && text.includes(".accessibilityText('关闭')"), file);
    assert.ok(!/Color\.White|\? '#EAF3FF' :|\? '#DDEEFF' :/.test(text), file + ' reads on any accent');
  }
  const scaffold = read('components/vnc/VncSheetScaffold.ets');
  assert.ok(scaffold.includes('} else if (this.trailingClose) {'));
  const vnc = read('components/hostadd/VncAddFlow.ets');
  assert.ok(vnc.includes('trailingClose: true,') && read('components/resourceadd/VncGatewayAddFlow.ets').includes('trailingClose: true,'));
  assert.ok(!/\? Color\.White :|\.fontColor\(Color\.White\)|\? '#EAF3FF' :|\? '#DDEEFF' :/.test(vnc));
  assert.ok(vnc.includes("vncSecurityPolicyLabel(this.securityPolicy)") && vnc.includes('vncScalingModeLabel(this.scalingMode)'));
  assert.ok(!/reviewRow\('(?:target ID|Gateway|Gateway 端点|TLS \/ 策略)'/.test(vnc), 'summary labels in words');
  assert.ok(vnc.indexOf('function vncSecurityPolicyLabel') > vnc.lastIndexOf("from '../vnc/VncSheetScaffold';"), 'helpers after the imports');
  for (const file of ['RdpAddFlow', 'RustDeskAddFlow']) {
    const text = read('components/hostadd/' + file + '.ets');
    assert.ok(text.includes("if (this.label.trim() === '' || this.label === this.lanAutoLabel) {"), file + ' keeps a typed name');
  }
  assert.ok(read('components/hostadd/RdpAddFlow.ets').includes('if (this.credentials.length === 0) { this.onAddCredential(); return; }'));
  const ssh = read('components/hostadd/SshAddFlow.ets');
  assert.ok(!ssh.includes("'请完整填写名称、地址和用户名'") && !ssh.includes("'请完整填写基础信息和有效端口'"));
  assert.ok(ssh.includes("this.errorText = '请填写主机地址'"));
  for (const file of ['RdpAddFlow', 'RustDeskAddFlow', 'SshAddFlow', 'VncAddFlow']) {
    const text = read('components/hostadd/' + file + '.ets');
    assert.ok(text.includes("@Prop @Watch('onSaveError') saveErrorRevision: number = 0;") &&
      text.includes('if (this.saveError !== \'\') { this.errorText = this.saveError; }'), file);
  }
  const colors = read('common/AppUiColorPolicy.ets');
  assert.ok(colors.indexOf('export function accentSecondaryText') > colors.indexOf('export function appUiOnAccentText'));
});

check('classic editor: clearable numeric ports checked on save, a close button, AI only with Pro, even spacing', () => {
  const page = read('pages/HostListPage.ets');
  assert.ok(page.includes("this.sshPortVal = v.trim() === '' || isNaN(n) ? 0 : n;") &&
    page.includes("this.rdpPortVal = v.trim() === '' || isNaN(n) ? 0 : n;"));
  assert.ok(page.includes('TextInput({ placeholder: h, text: v }).type(numeric ? InputType.Number : InputType.Normal)'));
  assert.ok(member(page, 'private doAdd(): void {').includes("this.sheetErr = '请输入 1–65535 之间的端口';"));
  assert.ok(member(page, '@Builder private classicHostEditorTitle() {').includes('this.requestAddSheetCloseByUser();'));
  assert.ok(page.includes("if (this.aiProVisible) {\n              this.protoBtn('AI · Pro', 'ai', 9443)"));
  assert.ok(page.includes(".margin({ left: protoVal === 'rdp' ? 0 : 8 })"));
});

check('PC and accessibility: right-click menus, scrollbars, labels, the open-lock icon', () => {
  const page = read('pages/HostListPage.ets');
  assert.ok(page.includes('.bindContextMenu(this.hostContextMenuBuilder(host), ResponseType.RightClick)'));
  assert.ok(page.includes('.bindContextMenu(this.moonlightContextMenuBuilder(view), ResponseType.RightClick)'));
  const menu = member(page, '@Builder hostContextMenuBuilder(host: RemoteHost) {');
  assert.ok(menu.includes("'取消选择' : '选择'") && menu.includes("MenuItem({ content: '删除' })"));
  const swipe = member(page, '@Builder hostEditLockRow(host: RemoteHost) {');
  assert.ok(swipe.includes("host.locked ? $r('sys.symbol.lock_open') : $r('sys.symbol.ohos_lock')"));
  assert.ok(swipe.includes(".accessibilityText(host.locked ? '解锁' : '上锁')") && swipe.includes(".accessibilityText('部署公钥')"));
  assert.ok(page.includes(".accessibilityText('添加')") && page.includes(".accessibilityText('清除搜索')"));
  for (const label of ['远程主机', '密钥保险库', '中继', '设置']) {
    assert.ok(page.includes(".accessibilityGroup(true).accessibilityText('" + label + "')"), label);
  }
  for (const file of ['components/pro/org/HostGroupBar.ets', 'components/pro/workspace/WorkspaceStrip.ets', 'components/pro/org/HostBatchActions.ets']) {
    assert.ok(read(file).includes('.scrollBar(this.isDesktopDevice ? BarState.Auto : BarState.Off)'), file);
  }
  for (const file of ['org/HostBatchActions', 'org/HostImportPanel', 'org/HostOrganizationManager', 'workspace/WorkspaceAddFlow',
    'workspace/WorkspaceLaunchPrepPanel', 'workspace/WorkspaceRunPanel', 'workspace/WorkspaceStrip']) {
    assert.ok(!/fontColor\(\[?Color\.White\]?\)/.test(read('components/pro/' + file + '.ets')), file);
  }
});

check('batch 3 review: locked Moonlight hosts, 在列表中选中, relay search, classic strip, actionable dialogs', () => {
  const privacy = load('services/HostCardPrivacyPolicy');
  const policy = loadWith('services/HostWorkspacePolicy', { './HostCardPrivacyPolicy': privacy });
  assert.equal(policy.moonlightHostMatchesSearch('Gaming PC', 'uuid-1', ['192.168.1.20'], false, '192.168'), true);
  assert.equal(policy.moonlightHostMatchesSearch('Gaming PC', 'uuid-1', ['192.168.1.20'], true, '192.168'), false,
    'a locked card hides its address');
  assert.equal(policy.moonlightHostMatchesSearch('Gaming PC', 'uuid-1', ['192.168.1.20'], true, 'uuid'), false);
  assert.equal(policy.moonlightHostMatchesSearch('Gaming PC', 'uuid-1', ['192.168.1.20'], true, 'gaming'), true);
  const filter = loadWith('services/HostListFilterService', { './HostWorkspacePolicy': policy });
  const relays = new Map([['r1', 'relay.example.com']]);
  const lockedRd = hostRecord({ id: 'lr', label: 'Box', protocol: 'rustdesk', rustdeskRelayId: 'r1', locked: true });
  const openRd = hostRecord({ id: 'or', label: 'Desk', protocol: 'rustdesk', rustdeskRelayId: 'r1' });
  assert.deepEqual(filter.searchHosts([lockedRd, openRd], 'relay.example', relays).map((h) => h.id), ['or'],
    'a typed relay address does not find a locked host');
  assert.deepEqual(filter.searchHosts([lockedRd, openRd], 'relay.example', relays, true).map((h) => h.id), ['lr', 'or'],
    '中继 → 查看主机 lists every host on the relay');
  const page = read('pages/HostListPage.ets');
  assert.ok(member(page, 'private visibleMoonlightHosts(): MoonlightHostLocalView[] {').includes('moonlightHostMatchesSearch('));
  const select = member(page, 'private selectHostsByRefs(refs: string[]): void {');
  assert.ok(select.indexOf("this.searchText = '';") < select.indexOf('this.refreshFilteredHostView();'));
  assert.ok(select.includes('this.hostSelectedIds = new Set<string>(shown);') && select.includes("没有选中"));
  assert.ok(member(page, 'private onSearchChange(value: string): void {')
    .includes("if (value !== this.relaySearchFromRelayPage) { this.relaySearchFromRelayPage = ''; }"));
  assert.ok(member(page, 'private showRelayHostsFromRelayPage(relayId: string): void {')
    .includes('this.relaySearchFromRelayPage = this.searchText;'));
  const strip = member(page, '@Builder HostWorkspaceFilterBar() {');
  assert.ok(strip.includes(".padding({ left: 16, right: 16, top: 4, bottom: 6 })") && strip.includes("Column().width('100%').height(10)"),
    'the classic strip keeps its size, with or without groups');
  assert.ok(!strip.includes('padding({ top: 8, bottom: 8 })') && strip.includes('.margin({ right: 12 })'));
  const colors = read('common/AppUiColorPolicy.ets');
  assert.ok(colors.includes("export function accentSecondaryText(accent: string, whiteTint: string = '#EAF3FF'): string {"));
  assert.ok(read('components/hostadd/MoonlightHostAddFlow.ets').includes("accentSecondaryText(this.accentColor, '#DDEEFF')"));
  assert.equal((read('components/hostadd/RustDeskAddFlow.ets').match(/accentSecondaryText\(this\.accentColor, '#DDEEFF'\)/g) || []).length, 2);
  assert.ok(read('components/hostadd/VncAddFlow.ets').includes("accentSecondaryText(this.accentColor, '#DDEEFF')"));
  const batch = member(page, 'private async doHostBatchDelete(): Promise<void> {');
  assert.ok(batch.includes('filter((key: string): boolean => inView.has(key))'), 'acts on hosts on screen now');
  assert.ok(batch.indexOf('const actionableMoonlight') > batch.indexOf('moonlightPreviews.push(preview);') &&
    batch.includes('actionableMoonlight.filter((host: MoonlightHost): boolean => host.locked === true)'));
  const single = member(page, 'private async doDeleteHost(host: RemoteHost): Promise<void> {');
  assert.ok(single.includes('this.hostStoredLocked(host) || host.locked') &&
    (single.match(/if \(!this\.pageActive\) \{ return; \}/g) || []).length === 2);
  const lock = member(page, 'private async toggleLock(cardHost: RemoteHost): Promise<void> {');
  assert.ok(lock.indexOf('const nextLocked: boolean = !host.locked;') < lock.indexOf('await showLockGate(') &&
    lock.includes('(this.srv.getHost(host.id) ?? host).runtimeClone()'));
  const open = member(page, 'private openGroupWithSearchMatches(): void {');
  assert.ok(open.includes("type === 'moonlight' ? moonlightMatches :") && open.includes("'vnc', 'moonlight'"));
  assert.ok(member(page, 'private hostSearchOrFilterActive(): boolean {')
    .includes("this.workspaceGroupId !== '' && !this.groupedHostCardsActive() && !this.proOrgVisible"));
  assert.ok(member(page, 'private announceSavedHost(hostId: string, message: string): void {').includes('this.desktopTabProtocol()'));
});

check('batch 3 review nits: accent text, danger fills, grouped cards, ports, key types, pickers, duplicate imports', () => {
  const page = read('pages/HostListPage.ets');
  const vncClassic = page.slice(page.indexOf("Button('TCP 直连').layoutWeight(1).height(34)"), page.indexOf("Button('允许明文').layoutWeight(1).height(32)"));
  assert.ok(vncClassic.length > 0 && !/Color\.White/.test(vncClassic), 'classic VNC editor choices');
  assert.ok(page.includes(".fontColor(this.vncHostSecurityPolicy === 'allow_plaintext' ? Color.White : this.pal().text2)"),
    'white stays on the danger fill');
  assert.ok(page.includes(".fontColor(this.sshPublicKeyInstallBusy ? Color.White : appUiOnAccentText(this.accentColor))"));
  assert.ok(page.includes(".fontColor(this.moonlightEditHostType === 'sunshine' ? appUiOnAccentText(this.accentColor) : this.pal().text2)"));
  assert.ok(read('components/hostadd/VncAddFlow.ets').includes("(danger ? '#FFFFFF' : appUiOnAccentText(this.accentColor))"));
  const grouped = member(page, '@Builder hostGroupedHostCard(host: RemoteHost) {');
  assert.ok(grouped.includes('void this.probeHostConnectivity(host);') &&
    grouped.indexOf('if (this.hostSelectionMode) { this.toggleHostSelect(') < grouped.indexOf('void this.probeHostConnectivity(host);'));
  assert.ok(grouped.includes('.bindContextMenu(this.hostContextMenuBuilder(host), ResponseType.RightClick)'));
  assert.ok(member(page, '@Builder moonlightGroupedHostCard(view: MoonlightHostLocalView) {')
    .includes('.bindContextMenu(this.moonlightContextMenuBuilder(view), ResponseType.RightClick)'));
  const sw = member(page, 'private switchHostProtocol(protocol: string, defaultPort: number): void {');
  assert.ok(sw.includes('if (this.rdpPortVal <= 0) { this.rdpPortVal = defaultPort; }') &&
    sw.includes('if (this.sshPortVal <= 0) { this.sshPortVal = defaultPort; }'));
  assert.ok(page.includes('sshKeyTypeText(key.privateKey, key.publicKey, SshKey.typeLabel(key.keyType))'));
  assert.ok(read('components/hostadd/SshAddFlow.ets').includes('sshKeyTypeText(key.privateKey, key.publicKey, SshKey.typeLabel(key.keyType))'));
  const guard = read('services/KeyVaultPickerGuard.ets');
  assert.ok(guard.includes('if (since > 0 && skipped && !keyVaultPickerKeepsUnlocked(since, Date.now())) {'),
    'only a real trip to the background relocks');
  assert.ok(member(guard, 'export function keyVaultPickerExplainsBackground(): boolean {')
    .includes('AppStorage.setOrCreate<boolean>(PICKER_SKIPPED_BACKGROUND_KEY, true);'));
  assert.ok(read('components/resourceadd/modern/ModernKeyVaultAddFlow.ets').includes("'与文件中前一条重复，将跳过'"));
});

// ------------------------------------------------------------------ batch 4: unsaved input is not lost silently
check('relay sheets ask before throwing away typed input (✕, 取消, swipe-down), saves close straight away', () => {
  const page = read('pages/RustDeskRelayPage.ets');
  const label = member(page, 'private relaySheetUnsavedLabel(): string {');
  assert.ok(label.includes('this.relayFormSnapshot() !== this.relayFormBaseline') &&
    label.includes('this.proFormSnapshot() !== this.proFormBaseline') && label.includes('this.pasteConfigDirty') &&
    label.includes('this.vncGatewayDirty'));
  assert.ok(member(page, 'private resetRelayForm(): void {').includes('this.relayFormBaseline = this.relayFormSnapshot();'));
  assert.ok(member(page, 'private openEditRelaySheet(relay: RustDeskRelayConfig): void {')
    .includes('this.relayFormBaseline = this.relayFormSnapshot();'), 'an edit starts clean');
  assert.equal((page.match(/this\.proFormBaseline = this\.proFormSnapshot\(\);/g) || []).length, 4,
    'both Pro openers, the sign-in and a discard reset the baseline');
  assert.ok(page.includes(".enabled(!this.relaySaving).onClick((): void => { this.closeSheetByUser(); })"), '取消 asks');
  assert.ok(page.includes(".enabled(!this.proBusy).accessibilityText('关闭')\n          .onClick((): void => { this.closeSheetByUser(); })"));
  assert.ok(page.includes('if (this.relaySheetClosing || this.relaySheetUnsavedLabel() === \'\') {'), 'a programmatic close is not asked about');
  assert.ok(page.includes("if (!this.relaySheetClosing && this.relaySheetUnsavedLabel() !== '') { action.springBack(); }"));
  const paste = read('components/resourceadd/modern/RustDeskRelayConfigPasteSheet.ets');
  assert.ok(paste.includes("title: '放弃粘贴的配置？'") && paste.includes(".accessibilityText('关闭').onClick((): void => { this.onClose(); })"));
  assert.ok(paste.includes("this.onDirtyChange(value.trim() !== '');") && !/Color\.White/.test(paste));
});

check('the VNC relay flow reports unsaved input; back to the picker asks too', () => {
  const flow = read('components/resourceadd/VncGatewayAddFlow.ets');
  assert.ok(flow.includes("@State @Watch('reportDirty') label: string = '';") &&
    flow.includes("@State @Watch('reportDirty') accessToken: string = '';"));
  assert.ok(member(flow, 'aboutToAppear(): void {').includes('this.draftBaseline = this.draftSnapshot();'),
    'an edit starts clean, after its values are loaded');
  assert.ok(member(flow, 'private reportDirty(): void {').includes("if (this.draftBaseline === '') { return; }"));
  const page = read('pages/RustDeskRelayPage.ets');
  assert.ok(page.includes('onDirtyChange: (dirty: boolean): void => { this.vncGatewayDirty = dirty; },'));
  assert.ok(page.includes("onClose: (): void => { this.closeSheetByUser(); },\n        onDirtyChange"));
  assert.ok(page.includes('this.confirmDiscardRelaySheet((): void => {\n            this.vncGatewayFromPicker = false;'));
});

check('host add flows report unsaved input; ✕, back to the picker and swipe-down ask; saves close straight away', () => {
  const flows = {
    RdpAddFlow: "@State @Watch('reportDirty') hostAddress: string = '';",
    RustDeskAddFlow: "@State @Watch('reportDirty') controlId: string = '';",
    SshAddFlow: "@State @Watch('reportDirty') address: string = '';",
    VncAddFlow: "@State @Watch('reportDirty') passwordChanged: boolean = false;",
  };
  for (const [file, field] of Object.entries(flows)) {
    const text = read('components/hostadd/' + file + '.ets');
    assert.ok(text.includes('onDirtyChange: (dirty: boolean) => void') && text.includes(field), file);
    assert.ok(member(text, 'private reportDirty(): void {').includes("if (this.draftBaseline === '') { return; }"), file);
  }
  const rd = member(read('components/hostadd/RustDeskAddFlow.ets'), 'aboutToAppear(): void {');
  assert.ok(rd.indexOf('this.draftBaseline = this.draftSnapshot();') < rd.indexOf('this.applyDraft(this.initialDraft);'),
    'a resumed draft is still unsaved');
  const ssh = member(read('components/hostadd/SshAddFlow.ets'), 'aboutToAppear(): void {');
  assert.ok(ssh.indexOf('this.draftBaseline = this.draftSnapshot();') < ssh.indexOf('const fields = this.initialBasicFields;'));
  const vnc = member(read('components/hostadd/VncAddFlow.ets'), 'aboutToAppear(): void {');
  assert.ok(vnc.trim().endsWith('this.draftBaseline = this.draftSnapshot();\n  }'), 'an edit starts clean');
  const moon = read('components/hostadd/MoonlightHostAddFlow.ets');
  assert.ok(moon.includes("@State @Watch('reportDirty') flow: MoonlightHostAddState") &&
    member(moon, 'private reportDirty(): void {').includes('moonlightHostAddDraftIsDirty(this.flow)'));
  assert.ok(moon.includes(".accessibilityText('关闭').onClick((): void => { this.onClose(); })"), 'the page may keep it open');
  assert.ok(read('components/ai/AiHostEditor.ets').includes("@State @Watch('reportDirty') invite: string = '';"));
  assert.ok(read('components/pro/workspace/WorkspaceAddFlow.ets').includes("@State @Watch('reportDirty') picked: string[] = [];"));

  const page = read('pages/HostListPage.ets');
  const unsaved = member(page, 'private hostAddHasUnsavedInput(): boolean {');
  assert.ok(unsaved.includes("this.modernAddProtocol === 'moonlight' && this.moonlightAddCommitted") &&
    unsaved.includes('return this.hostAddFlowDirty;') && unsaved.includes('this.classicEditorSnapshot() !== this.classicEditorBaseline'));
  assert.ok(member(page, 'private confirmDiscardHostAdd(proceed: () => void): void {').includes("title: '放弃未保存的内容？'"));
  const sheet = member(page, '@Builder hostAddSheetContent() {');
  assert.equal((sheet.match(/onClose: \(\): void => \{ this\.requestAddSheetCloseByUser\(\); \}/g) || []).length, 7,
    'RDP, RustDesk, Moonlight, SSH, VNC, 远程 AI and 工作区 ask before closing');
  assert.equal((sheet.match(/this\.backToHostAddPicker\(/g) || []).length, 6, 'back to the picker asks (Moonlight asks itself)');
  assert.equal((sheet.match(/onDirtyChange: \(dirty: boolean\): void => \{ this\.hostAddFlowDirty = dirty; \}/g) || []).length, 7);
  assert.equal((sheet.match(/onClose: \(\): void => \{ this\.requestAddSheetClose\(\); \}/g) || []).length, 1,
    'only the protocol picker (nothing to lose there) closes directly');
  assert.ok(member(page, '@Builder private classicHostEditorTitle() {').includes('this.requestAddSheetCloseByUser();'));
  assert.ok(page.includes("if (this.addSheetClosing || !this.hostAddHasUnsavedInput()) {\n              action.dismiss();"),
    'a programmatic close is not asked about');
  assert.ok(page.includes('if (!this.addSheetClosing && this.hostAddHasUnsavedInput()) { action.springBack(); }'));
  assert.ok(page.includes("if (this.classicEditorBaseline === '') { this.classicEditorBaseline = this.classicEditorSnapshot(); }\n          },\n          onWillDismiss"));
  assert.ok(page.includes("if (untouched || protoVal === 'vnc') { this.classicEditorBaseline = this.classicEditorSnapshot(); }"),
    'switching the protocol of an untouched classic form is not input');
  const gone = member(page, 'private handleAddSheetDisappear(): void {');
  assert.ok(gone.includes('this.hostAddFlowDirty = false;') && gone.includes("this.classicEditorBaseline = '';"));
});

check('key vault sheets ask before throwing away input; saves and transitions close straight away', () => {
  const page = read('pages/KeyVaultPage.ets');
  assert.ok(!/this\.showSheet = false/.test(page.replace("    this.keyVaultSheetClosing = true;\n    this.showSheet = false;", '')),
    'every close goes through closeKeyVaultSheet or closeKeyVaultSheetByUser');
  assert.ok(member(page, 'private closeKeyVaultSheet(): void {').includes('if (!this.showSheet) { return; }'));
  const label = member(page, 'private keyVaultSheetUnsavedLabel(): string {');
  assert.ok(label.includes('this.sheetMode === 6 && this.modernFlowDirty') &&
    label.includes('this.editingTotpName.trim() !== this.editingTotpEntry.displayName.trim()'));
  assert.equal((page.match(/this\.closeKeyVaultSheetByUser\(\)/g) || []).length, 4, 'flow ✕, both pickers, rename 取消');
  assert.ok(page.includes('onSaved: (_resourceId: string): void => { this.modernFlowDirty = false; this.load(); }'));
  assert.ok(page.includes("if (this.keyVaultSheetClosing || this.keyVaultSheetUnsavedLabel() === '') {"));
  assert.ok(page.includes("if (!this.keyVaultSheetClosing && this.keyVaultSheetUnsavedLabel() !== '') { action.springBack(); }"));
  const modern = read('components/resourceadd/modern/ModernKeyVaultAddFlow.ets');
  assert.ok(modern.includes("@State @Watch('reportDirty') privateKeyText: string = '';") && !modern.includes('this.onClose(); this.reset(); })'),
    'closing does not clear what the page may keep');
  assert.ok(member(page, 'private onAppBackground(): void {').includes('} else if (keyVaultPickerStaleOnReturn()) {'));
  assert.ok(modern.includes('this.importFirstIdBySecret.get(secret)'));
  const host = read('pages/HostListPage.ets');
  assert.ok(host.includes("'选中的主机已不在当前列表中'") &&
    host.includes('.enabled(this.hostSelectionMode || !this.hostPresenceProbeBusyIds.has(host.id))'));
});

check('batch 4 review: a stale question does nothing, kept forms keep their baseline, every input counts', () => {
  const page = read('pages/HostListPage.ets');
  const confirm = member(page, 'private confirmDiscardHostAdd(proceed: () => void): void {');
  assert.ok(confirm.includes('if (this.hostAddSheetDismissCount !== dismissCount || !this.showAddSheet) { return; }'),
    'a sheet closed by rotation or resize leaves no stuck closing flag');
  assert.ok(member(page, 'private requestAddSheetClose(): void {').includes('if (!this.showAddSheet) { return; }'));
  const gone = member(page, 'private handleAddSheetDisappear(): void {');
  assert.ok(gone.includes('this.hostAddSheetDismissCount++;') &&
    gone.includes("if (!preserveForm) { this.classicEditorBaseline = ''; }"), 'the 2FA binding round trip keeps the baseline');
  assert.ok(page.includes("if (this.classicEditorBaseline === '') { this.classicEditorBaseline = this.classicEditorSnapshot(); }"));
  const snap = member(page, 'private classicEditorSnapshot(): string {');
  for (const field of ['sshProxyEditorInputKey(this.sheetSshProxyEditorValue)', 'this.keyPassphraseInputMarker()', 'this.sheetRustdeskAuthMode',
    'this.sheetRustdeskTargetDevice', 'this.sheetRdpCredentialStorageMode', 'this.vncHostRepeaterMode']) {
    assert.ok(snap.includes(field), field);
  }
  assert.ok(page.includes("if (untouched || protoVal === 'vnc') { this.classicEditorBaseline = this.classicEditorSnapshot(); }"));
  assert.equal((page.match(/this\.confirmDiscardHostAdd\(\(\): void => \{\n\s+this\.pendingRustDeskRelayDirectoryOpen = true;/g) || []).length, 2,
    '去添加中继 and 去添加 → ask first');
  assert.ok(page.includes('this.confirmDiscardHostAdd((): void => {\n            this.pendingVncGatewayDirectoryOpen = true;'));

  const relay = read('pages/RustDeskRelayPage.ets');
  assert.ok(member(relay, 'private confirmDiscardRelaySheet(proceed: () => void): void {')
    .includes('if (this.relaySheetDismissCount !== dismissCount || !this.showSheet) { return; }'));
  const label = member(relay, 'private relaySheetUnsavedLabel(): string {');
  assert.ok(label.includes('(this.sheetContent === 1 || this.sheetContent === 5 || this.sheetContent === 9 ||') &&
    label.includes("'粘贴内容'"), 'the form typed before the paste sheet or the picker is still protected');
  assert.ok(relay.includes('// Stored on this device already: closing loses nothing typed.'));

  const keys = read('pages/KeyVaultPage.ets');
  assert.ok(member(keys, 'private confirmDiscardKeyVaultSheet(proceed: () => void): void {')
    .includes('if (this.keyVaultSheetDismissCount !== dismissCount || !this.showSheet) { return; }'));
  assert.ok(member(keys, 'private keyVaultSheetUnsavedLabel(): string {').includes("if (this.sheetMode === 4 && this.passphraseSheetDirty) { return '口令'; }"));
  assert.ok(keys.includes('onDirtyChange: (dirty: boolean): void => { this.passphraseSheetDirty = dirty; },'));
  assert.ok(read('components/SshKeyManagerSheet.ets').includes("@State @Watch('reportDirty') newPass: string = '';"));

  const ai = read('components/ai/AiHostEditor.ets');
  assert.ok(ai.includes('else if (this.canReturnToProtocols) { this.onBackToProtocols(); }'), 'back clears nothing before the question');
  assert.equal((member(ai, 'private async save(connect: boolean): Promise<void> {').match(/this\.markSaved\(\);/g) || []).length, 3,
    'a stored host is clean at once');
  assert.ok(read('components/pro/workspace/WorkspaceAddFlow.ets').includes('JSON.stringify([this.name, this.color, this.icon, this.picked])'));
  assert.ok(read('components/hostadd/RdpAddFlow.ets').includes('this.authMode, this.credentialStorageMode]);'));
  assert.ok(read('components/hostadd/RustDeskAddFlow.ets').includes('this.targetDevice, this.adaptiveOrientation]);'));
  assert.ok(read('components/hostadd/SshAddFlow.ets').includes('sshProxyEditorInputKey(this.proxyEditorValue)'));
  const proxy = read('services/SshProxyEditorPolicy.ets');
  const inputKey = proxy.slice(proxy.indexOf('export function sshProxyEditorInputKey('),
    proxy.indexOf('export function defaultSshProxyHop('));
  assert.ok(inputKey.length > 0 && inputKey.indexOf('hop.hopId') < 0 && inputKey.includes('hop.host'), 'a generated hop id is not input');
});

check('batch 4 review 2: no secret in a baseline, no stale baseline, failed saves keep the question', () => {
  const page = read('pages/HostListPage.ets');
  const snap = member(page, 'private classicEditorSnapshot(): string {');
  assert.ok(snap.includes('this.keyPassphraseInputMarker()') && !snap.includes('this.sheetKeyPassphrase,'),
    'the passphrase itself never goes into the baseline');
  assert.ok(member(page, 'private keyPassphraseInputMarker(): string {').includes("return this.sheetKeyPassphrase === '' ? '' : 'typed';"));
  assert.ok(member(page, 'private resetForm(): void {').includes("this.classicEditorBaseline = '';"));
  assert.ok(member(page, 'private async editHost(host: RemoteHost): Promise<void> {').includes("this.classicEditorBaseline = '';"));
  assert.equal((page.match(/if \(!this\.showAddSheet \|\| !shouldAcceptHostAddPostSaveHandoff\(/g) || []).length, 2,
    'a Moonlight post-save after the sheet went away hands nothing off');
  const keys = read('pages/KeyVaultPage.ets');
  const complete = keys.slice(keys.indexOf('onComplete: (newPrivateKey: string, newEncrypted: boolean) => {'));
  assert.ok(complete.indexOf('this.passphraseSheetDirty = false;') > complete.indexOf("'密码没有保存，请重试'"),
    'a failed save keeps the typed passphrases protected');
  const relay = member(read('pages/RustDeskRelayPage.ets'), 'private relaySheetUnsavedLabel(): string {');
  assert.ok(relay.includes("relayFormTyped ? '中继配置和粘贴内容' : '粘贴内容'") && relay.includes('this.sheetContent === 10) && !this.relaySaving'));
});

check('batches 5-7: 全新视觉 extends to the three main pages; the classic look keeps its glyphs and sizes', () => {
  const page = read('pages/HostListPage.ets');
  assert.ok(member(page, '@Builder hostSearchClearButton() {').includes("Text('✕')"), 'classic keeps ✕');
  assert.ok(page.includes('if (this.hostSelectionMode && !this.settingsModern()) {'), 'classic keeps the bar in the list');
  assert.ok(page.includes('.onClick(() => { this.onFabAddClick(); })') && page.includes('this.onFabAddClick(); })\n              }'));
  assert.ok(page.includes('if (!this.hostSelectionMode && (this.isDesktopDevice || this.settingsModern())) {'));
  assert.ok(read('components/SshKeyCard.ets').includes("Text('复制公钥')") && !read('components/SshKeyCard.ets').includes("Button('复制公钥')"));
  assert.ok(read('components/TotpCodeCard.ets').includes("settingsVisualIsModern(this.visualStyle) && this.codeStr.length >= 6"));
  assert.ok(read('pages/RustDeskRelayPage.ets').includes("if (this.breakpoint !== 'sm' || settingsVisualIsModern(this.visualStyle)) {"));
});

console.log('three screens: ' + passed + ' checks passed');
