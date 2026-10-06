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

console.log('three screens: ' + passed + ' checks passed');
