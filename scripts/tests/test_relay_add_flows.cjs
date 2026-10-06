'use strict';
/**
 * 中继 tab's + : the 添加中继服务器 picker leads to the RustDesk relay form or the VNC Gateway flow. Both follow the
 * host-add flows: back on the first step returns to the picker, and the VNC Gateway sheet uses the VNC host-add
 * sheet contract (content-sized, keyboard translates and scrolls) instead of a bounded scaffold in a
 * FIT_CONTENT sheet.
 */
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

const ETS = path.resolve(__dirname, '../../entry/src/main/ets');
const read = (file) => fs.readFileSync(path.join(ETS, file), 'utf8');
/** The body of a member, up to the next member at the same indent. */
function member(source, signature) {
  const start = source.indexOf(signature);
  assert.ok(start >= 0, 'missing ' + signature);
  const next = source.slice(start + signature.length).search(/\n  (?:@Builder |private |build\(|aboutTo|async |onPage)/);
  return next < 0 ? source.slice(start) : source.slice(start, start + signature.length + next);
}
let passed = 0;
function check(name, run) { run(); passed++; console.log('PASS ' + name); }

check('the VNC Gateway flow sizes to its content and returns to the picker like the VNC host flow', () => {
  const flow = read('components/resourceadd/VncGatewayAddFlow.ets');
  assert.ok(flow.includes('@Prop fitContent: boolean = false;'));
  assert.ok(member(flow, 'build() {').includes('fitContent: this.fitContent,'));
  const back = member(flow, 'private back(): void {');
  assert.ok(back.indexOf('this.onBackToProtocols();') > back.indexOf('} else if (this.canReturnToProtocols) {'));
  assert.ok(back.includes('this.onClose();'), 'editing (no picker) still closes');
  assert.ok(flow.includes("this.step === 0 ? (this.canReturnToProtocols ? '返回协议' : '取消') : '上一步'"));
  assert.ok(!/Color\.White/.test(flow), 'button text follows the accent');

  const host = read('components/hostadd/VncAddFlow.ets');
  assert.ok(member(host, 'private back(): void {').includes('this.onBackToProtocols();'), 'the host flow it mirrors');
});

check('the relay page hosts the VNC Gateway flow with the host-add sheet contract', () => {
  const page = read('pages/RustDeskRelayPage.ets');
  assert.ok(!page.includes('rustDeskRelaySheetUsesResizeOnly'));
  assert.ok(member(page, 'private relaySheetKeyboardAvoidMode(): SheetKeyboardAvoidMode {')
    .includes("resolveHostAddSheetKeyboardAvoidMode(this.sheetContent === 10 ? 'vnc' : '', this.breakpoint)"));
  const sheet = member(page, '@Builder relaySheetBuilder() {');
  assert.ok(sheet.includes("fitContent: resolveHostAddSheetContentMode('vnc', this.breakpoint) === 'fitContent',"));
  assert.ok(sheet.includes('canReturnToProtocols: this.vncGatewayFromPicker && this.editingVncGateway === null,'));
  // Back to the picker (asks first when something typed would be lost, see test_three_screens batch 4).
  assert.ok(sheet.includes('this.vncGatewayFromPicker = false; this.vncGatewayDirty = false; this.sheetContent = 5;'));
  const picker = member(page, '@Builder relayProtocolChoiceSheet() {');
  assert.ok(picker.includes('this.relayFormFromPicker = true;') && picker.includes('this.openVncGatewaySheet(true);'));
  assert.ok(member(page, 'private openEditVncGatewaySheet(gateway: VncGatewayView): void {').includes('this.vncGatewayFromPicker = false;'));
  assert.ok(member(page, 'private openRustDeskRelaySheet(): void {').includes('this.relayFormFromPicker = false;'));
  const dismiss = member(page, 'private finishSheetDismiss(): void {');
  assert.ok(dismiss.includes('this.vncGatewayFromPicker = false;') && dismiss.includes('this.relayFormFromPicker = false;'));
  const form = member(page, '@Builder relayEditSheet() {');
  assert.ok(form.includes("if (this.relayFormFromPicker && this.editingRelayId === '') {") &&
    form.includes('.onClick((): void => { this.relayFormFromPicker = false; this.sheetContent = 5; })'),
    'the RustDesk relay form returns to the picker too');
});

console.log('relay add flows: ' + passed + ' checks passed');
