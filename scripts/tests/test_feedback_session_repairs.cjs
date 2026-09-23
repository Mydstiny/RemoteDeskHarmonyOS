/* Executes the actual ArkTS policy/service tests; platform input delivery is mocked. */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('typescript');
const root = path.resolve(__dirname, '../..');
const tests = [], modules = new Map();
const hypium = {
  describe: (_name, body) => body(), it: (name, _level, body) => tests.push({name, body}),
  expect: value => ({assertEqual: expected => assert.equal(value, expected),
    assertTrue: () => assert.equal(value, true), assertFalse: () => assert.equal(value, false)})
};
function load(file) {
  file = path.resolve(root, file);
  if (modules.has(file)) return modules.get(file).exports;
  const module = {exports: {}}; modules.set(file, module);
  const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021}
  }).outputText;
  vm.runInNewContext(code, {module, exports: module.exports, require: id => {
    if (id === '@ohos/hypium') return hypium;
    if (id === '@kit.PerformanceAnalysisKit') return {hilog: {info() {}, warn() {}}};
    if (id === '@kit.CryptoArchitectureKit') return {cryptoFramework: {
      createRandom: () => ({generateRandomSync: n => ({data: require('node:crypto').randomBytes(n)})})}};
    if (id === '@kit.ArkTS') return {util: {
      TextEncoder: class {encodeInto(value) {return Buffer.from(value, 'utf8');}},
      TextDecoder: class {decodeToString(value) {return Buffer.from(value).toString('utf8');}},
      Base64Helper: class {
        decodeSync(value) {return Buffer.from(value, 'base64');}
        encodeToStringSync(value) {return Buffer.from(value).toString('base64');}
      }
    }};
    if (id === '@kit.InputKit') return {Action: {DOWN: 1, UP: 2, CANCEL: 3},
      KeyCode: {KEYCODE_VOLUME_UP: 16, KEYCODE_VOLUME_DOWN: 17, KEYCODE_MEDIA_PLAY_PAUSE: 10,
        KEYCODE_MEDIA_NEXT: 12, KEYCODE_MEDIA_PREVIOUS: 13}};
    if (id.startsWith('.')) return load(path.resolve(path.dirname(file), id + '.ets'));
    throw Error('Unexpected import: ' + id);
  }}, {filename: file});
  return module.exports;
}
for (const name of ['HarmonyShortcutCaptureService', 'HarmonyShortcutBlockingPolicy',
  'RemoteOrientationPolicy', 'RustDeskHostConfigPolicy']) {
  load('entry/src/test/' + name + '.test.ets').default();
}
const pageSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/RemoteDesktop.ets'), 'utf8');
const cursorMethods = ['shouldShowTouchIndicator', 'shouldShowArrowCursor',
  'isRemoteCursorNativePointerEligible', 'onRustDeskLocalCursorChanged',
  'syncRemoteSystemPointer', 'shouldHideRustDeskLocalPointer'].map(name => {
  const match = new RegExp('^  private ' + name + '\\(', 'm').exec(pageSource);
  assert.ok(match, name);
  const end = pageSource.indexOf('\n  private ', match.index + 1);
  assert.ok(end > match.index);
  return pageSource.slice(match.index, end);
});
const pageModule = {exports: {}};
vm.runInNewContext(ts.transpileModule('export class CursorHarness {\n' + cursorMethods.join('\n') + '\n}', {
  compilerOptions: {module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021}
}).outputText, {module: pageModule, exports: pageModule.exports,
  shouldHideVncSystemPointer: () => false, shouldUseSystemMousePointer: () => true});
tests.push({name: 'disabled RustDesk cursor preference suppresses every local cursor path', body: () => {
  const page = new pageModule.exports.CursorHarness();
  page.isRustDeskSession = () => true; page.rustdeskShowLocalCursor = false;
  assert.equal(page.shouldShowTouchIndicator(), false);
  assert.equal(page.shouldShowArrowCursor(), false);
  assert.equal(page.isRemoteCursorNativePointerEligible(), false);
}});
tests.push({name: 'cursor preference refreshes current RustDesk rendering and leaves other protocols alone', body: () => {
  const page = new pageModule.exports.CursorHarness(), events = [];
  page.isRustDeskSession = () => true;
  page.syncRemoteSystemPointer = () => events.push('native');
  page.requestRemoteCursorViewRefresh = immediate => {assert.equal(immediate, true); events.push('overlay');};
  page.onRustDeskLocalCursorChanged(); assert.deepEqual(events, ['native', 'overlay']);
  page.isRustDeskSession = () => false; page.onRustDeskLocalCursorChanged(); assert.equal(events.length, 2);
}});
tests.push({name: 'system pointer hide is canvas scoped and restored after hover exit or disconnect', body: () => {
  const page = new pageModule.exports.CursorHarness(), events = [];
  page.connected = true; page.rustdeskShowLocalCursor = false;
  page.isRustDeskSession = () => true; page.isKeyboardMouseControlMode = () => true;
  page.currentProtocolName = () => 'rustdesk'; page.vncCursorOwnershipEvidence = () => ({});
  page.shouldHideSystemPointerForVirtualTouchpad = () => false;
  page.setRemoteSurfacePointerStyle = () => events.push('style');
  page.setRemoteSystemPointerVisible = visible => events.push(visible);
  page.syncRemoteSystemPointer('setting', true, true); assert.deepEqual(events, ['style', false]);
  events.length = 0; page.syncRemoteSystemPointer('exit', false, true); assert.deepEqual(events, ['style', true]);
  events.length = 0; page.connected = false; page.syncRemoteSystemPointer('disconnect', true, true);
  assert.deepEqual(events, ['style', true]);
}});
(async () => {
  for (const test of tests) { await test.body(); console.log('PASS ' + test.name); }
  console.log(tests.length + ' feedback session checks passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
