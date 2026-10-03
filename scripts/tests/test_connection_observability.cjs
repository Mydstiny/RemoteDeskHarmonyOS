/* Host-side tests for connection observability: RDP graphics negotiation
 * facts, RustDesk live image-quality confirmation and RustDesk direct-route
 * evidence. OBSERVABILITY_TYPESCRIPT_PATH selects the installed compiler;
 * Hvigor validates ArkTS separately and FreeRDP/RustDesk wire behavior is
 * covered by native and Rust tests. */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.OBSERVABILITY_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const cache = new Map();
const tests = [];
const hypium = { describe: (_name, body) => body(), it: (name, _level, body) => tests.push({ name, body }),
  expect: (value) => ({ assertEqual: expected => assert.equal(value, expected),
    assertTrue: () => assert.equal(value, true), assertFalse: () => assert.equal(value, false) }) };
function load(file) {
  file = path.resolve(root, file);
  if (cache.has(file)) return cache.get(file).exports;
  const module = { exports: {} }; cache.set(file, module);
  const source = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const requireEts = id => {
    if (id === '@ohos/hypium') return hypium;
    if (id === '@kit.ArkTS') return { util: { TextEncoder, TextDecoder } };
    if (id === '@kit.CoreFileKit' || id === '@kit.AbilityKit') return {};
    if (id === '@kit.ArkData') return { preferences: {} };
    if (id === '@kit.CryptoArchitectureKit') return { cryptoFramework: {} };
    if (id === '@kit.BasicServicesKit') return { deviceInfo: { deviceType: '2in1', sdkApiVersion: 26, abiList: 'arm64-v8a', productModel: 'test', osFullName: 'test' } };
    if (id === '@ohos.systemDateTime') return { getUptime: () => 100, getTime: () => 1700000000000 };
    if (id === 'librdpnapi.so') return { VERSION: { gitShortSha: 'test' } };
    if (id === '../common/Theme') return { buildDark: () => ({}) };
    if (!id.startsWith('.')) throw new Error('Unexpected import ' + id);
    const resolved = path.resolve(path.dirname(file), id + '.ets');
    if (!fs.existsSync(resolved) && fs.existsSync(path.resolve(path.dirname(file), id + '.d.ts'))) return {};
    return load(resolved);
  };
  // ArkUI component files are only needed for their exported constants.
  const sandbox = { module, exports: module.exports, require: requireEts, Date, Uint8Array,
    ArrayBuffer, TextEncoder, TextDecoder, setTimeout, clearTimeout,
    Component: () => () => {}, Prop: () => () => {}, State: () => () => {}, Builder: () => () => {},
    Link: () => () => {}, Watch: () => () => {}, StorageLink: () => () => {}, Consume: () => () => {} };
  vm.runInNewContext(source, sandbox, { filename: file });
  return module.exports;
}
function loadHudConstant() {
  // The HUD is an ArkUI struct; extract only its pure EMPTY_RDP_RENDER_STATS literal.
  const text = fs.readFileSync(path.resolve(root, 'entry/src/main/ets/components/RdpDiagnosticsHud.ets'), 'utf8');
  const start = text.indexOf('export const EMPTY_RDP_RENDER_STATS');
  const end = text.indexOf('\n};', start) + 3;
  const literal = ts.transpileModule(text.substring(start, end), { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(literal, { module, exports: module.exports });
  return module.exports;
}
const hud = loadHudConstant();
cache.set(path.resolve(root, 'entry/src/main/ets/components/RdpDiagnosticsHud.ets'), { exports: hud });
load('entry/src/test/RdpGraphicsEvidencePolicy.test.ets').default();
load('entry/src/test/RustDeskQualityConfirmationPolicy.test.ets').default();
load('entry/src/test/RustDeskDirectRoutePolicy.test.ets').default();
load('entry/src/test/DiagnosticEvidenceCoveragePolicy.test.ets').default();

const svc = 'entry/src/main/ets/services/';
const graphics = load(svc + 'RdpGraphicsEvidencePolicy.ets');
const policy = load(svc + 'DiagnosticCapturePolicy.ets');
const { DiagnosticCaptureRuntime } = load(svc + 'DiagnosticCaptureRuntime.ets');
const exporter = load(svc + 'DiagnosticCaptureExportService.ets');
function test(name, body) { tests.push({ name, body }); }

function observedStats() {
  const stats = JSON.parse(JSON.stringify(hud.EMPTY_RDP_RENDER_STATS));
  stats.graphicsMode = 'gfx';
  stats.gfxChannelConnected = true;
  stats.copiedBytes = 123456789;
  stats.gfxEvidence = { requestedApplied: true, compiledGfx: true, compiledH264: true,
    h264PathSafe: false, supportGraphicsPipeline: true, remoteFxCodec: true, h264Advertised: false,
    fallbackConsumed: false, fallbackReason: '', capsAdvertisedCount: 6,
    capsAdvertisedMaxVersion: '10.7', capsAdvertisedAvc: false, capsConfirmed: true,
    capsConfirmedVersion: '10.7', capsConfirmedFlags: 32, capsConfirmedAvc: false,
    surfaceCommands: 42, surfaceCommandBytes: 98765, avcSurfaceCommands: 0,
    unknownCodecCommands: 0, wireCodecMask: 8, wireCodec: 'remotefx' };
  return stats;
}

test('RDP graphics facts survive the JSONL export round trip', () => {
  const runtime = new DiagnosticCaptureRuntime({ uptimeMs: () => 1000, wallTimeMs: () => 1700000000000 });
  runtime.start(10, ['connection.rdp']);
  const facts = policy.emptyDiagnosticRuntimeFacts();
  facts.rdpGraphics = graphics.rdpGraphicsFactsFromRenderStats(observedStats());
  assert.equal(policy.diagnosticRuntimeFactsAreValid(facts), true);
  runtime.record('connection.rdp', 'rdp_runtime_snapshot', 'state', 7, 0, 0, 0, 0, 0, facts);
  runtime.stop();
  const result = exporter.serializeDiagnosticCapture(runtime.frozenCapture());
  assert.equal(result.ok, true, result.code);
  assert.equal(exporter.validateDiagnosticJsonl(result.text), true);
  const row = result.text.trim().split('\n').map(JSON.parse)
    .find(r => r.eventCode === 'rdp_runtime_snapshot');
  assert.equal(row.runtime.rdpGraphics.wireCodec, 'remotefx');
  assert.equal(row.runtime.rdpGraphics.wireBytes, 98765);
  assert.equal(row.runtime.rdpGraphics.copiedBytes, 123456789);
  assert.equal(row.runtime.rdpGraphics.h264Status, 'gated_off');
  assert.equal(JSON.stringify(row).includes('10.0.0'), false);
});

test('a tampered rdpGraphics section invalidates the exported JSONL', () => {
  const runtime = new DiagnosticCaptureRuntime({ uptimeMs: () => 1000, wallTimeMs: () => 1700000000000 });
  runtime.start(10, ['connection.rdp']);
  const facts = policy.emptyDiagnosticRuntimeFacts();
  facts.rdpGraphics = graphics.rdpGraphicsFactsFromRenderStats(observedStats());
  runtime.record('connection.rdp', 'rdp_runtime_snapshot', 'state', 7, 0, 0, 0, 0, 0, facts);
  runtime.stop();
  const result = exporter.serializeDiagnosticCapture(runtime.frozenCapture());
  const tampered = result.text.replace('"wireCodec":"remotefx"', '"wireCodec":"avc444"')
    .replace('"h264Status":"gated_off"', '"h264Status":"in_use"');
  assert.notEqual(tampered, result.text);
  assert.equal(exporter.validateDiagnosticJsonl(tampered), false);
});

test('summary carries recomputed evidence coverage and rejects a forged one', () => {
  const runtime = new DiagnosticCaptureRuntime({ uptimeMs: () => 1000, wallTimeMs: () => 1700000000000 });
  runtime.start(10, ['connection.rdp', 'connection.rustdesk']);
  const facts = policy.emptyDiagnosticRuntimeFacts();
  const stats = observedStats();
  stats.gfxEvidence.capsConfirmed = false;
  stats.gfxEvidence.capsConfirmedVersion = 'unknown';
  stats.gfxEvidence.capsConfirmedAvc = false;
  stats.gfxEvidence.surfaceCommands = 0;
  stats.gfxEvidence.surfaceCommandBytes = 0;
  stats.gfxEvidence.wireCodec = 'none';
  stats.gfxEvidence.wireCodecMask = 0;
  facts.rdpGraphics = graphics.rdpGraphicsFactsFromRenderStats(stats);
  runtime.record('connection.rdp', 'rdp_runtime_snapshot', 'state', 7, 0, 0, 0, 0, 0, facts);
  runtime.stop();
  const result = exporter.serializeDiagnosticCapture(runtime.frozenCapture());
  assert.equal(result.ok, true, result.code);
  const lines = result.text.trim().split('\n').map(JSON.parse);
  const summary = lines[lines.length - 1];
  assert.deepEqual(summary.evidenceCoverage.missingEvidence,
    ['rdp_gfx_caps_unconfirmed', 'rdp_wire_codec_unobserved', 'rustdesk_activity_unobserved']);
  assert.equal(summary.evidenceCoverage.coverageComplete, false);
  assert.equal(summary.evidenceCoverage.moduleCoverage['connection.rustdesk'], 'no_events');
  // Same byte length so only the recomputed-coverage comparison can reject it.
  const forged = result.text.replace('"coverageComplete":false', '"coverageComplete":true ');
  assert.notEqual(forged, result.text);
  assert.equal(Buffer.byteLength(forged), Buffer.byteLength(result.text));
  assert.equal(exporter.validateDiagnosticJsonl(forged), false);
});

let failed = 0;
for (const { name, body } of tests) {
  try { body(); } catch (err) { failed++; console.error('FAIL ' + name + '\n' + (err && err.stack || err)); }
}
if (failed) { console.error(failed + '/' + tests.length + ' connection observability tests failed'); process.exit(1); }
console.log(tests.length + '/' + tests.length + ' connection observability tests passed');
