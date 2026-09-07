/* Host-side evidence tests. VIDEO_TYPESCRIPT_PATH selects the installed compiler;
 * Hvigor separately validates ArkTS and native/device behavior is not simulated. */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.VIDEO_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const cache = new Map();
const tests = [];
const hypium = { describe: (_name, body) => body(), it: (name, _level, body) => tests.push({ name, body }),
  expect: (value) => ({ assertEqual: expected => assert.equal(value, expected),
    assertTrue: () => assert.equal(value, true), assertFalse: () => assert.equal(value, false),
    assertNull: () => assert.equal(value, null) }) };
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
    if (id === '@kit.CoreFileKit') return {};
    if (id === '@kit.BasicServicesKit') return { deviceInfo: { deviceType: '2in1', sdkApiVersion: 23, abiList: 'arm64-v8a' } };
    if (id === '@ohos.systemDateTime') return { getUptime: () => 100, getTime: () => 1700000000000 };
    if (id === 'librdpnapi.so') return { getNativeVersion: () => ({ gitShortSha: 'test' }) };
    if (!id.startsWith('.')) throw new Error('Unexpected import ' + id);
    const resolved = path.resolve(path.dirname(file), id + '.ets');
    if (!fs.existsSync(resolved) && fs.existsSync(path.resolve(path.dirname(file), id + '.d.ts'))) return {};
    return load(resolved);
  };
  vm.runInNewContext(source, { module, exports: module.exports, require: requireEts,
    Date, Uint8Array, ArrayBuffer, TextEncoder, TextDecoder, setTimeout, clearTimeout }, { filename: file });
  return module.exports;
}
for (const suite of ['DiagnosticCapturePolicy', 'DiagnosticCaptureRuntime',
  'DiagnosticCaptureExportService', 'DiagnosticRuntimeSnapshotPolicy']) {
  load('entry/src/test/' + suite + '.test.ets').default();
}
load('entry/src/ohosTest/ets/test/RustDeskDiagnosticsPolicy.test.ets').default();
const svc = 'entry/src/main/ets/services/';
const policy = load(svc + 'DiagnosticCapturePolicy.ets');
const evidence = load(svc + 'VideoDiagnosticEvidence.ets');
const { DiagnosticCaptureRuntime } = load(svc + 'DiagnosticCaptureRuntime.ets');
const exporter = load(svc + 'DiagnosticCaptureExportService.ets');
function test(name, body) { tests.push({ name, body }); }
test('full failure journal survives JSONL roundtrip and rejects nested unexpected fields', () => {
  const runtime = new DiagnosticCaptureRuntime({ uptimeMs: () => 1000, wallTimeMs: () => 1700000000000 });
  runtime.start(10, ['connection.rustdesk']);
  const facts = policy.emptyDiagnosticRuntimeFacts();
  facts.presentation = 'top_left_producer';
  facts.video = evidence.videoDiagnosticEvidence({ connectionCodecPreference: 5, sentCodecPreference: 5,
    advertisedDecoderMask: 15, firstFrameCodec: 1, decodeOk: 0, presentedFrames: 0,
    decoderAttempts: [1, 2, 3, 4].map(serial => ({ serial, decoderGeneration: serial,
      codec: 1, width: 3840, height: 2160, stage: 6, result: -1, platformCode: 5400106,
      capabilityHardware: 1, capabilitySizeSupported: 1, outputWidth: 0, outputHeight: 0,
      outputPixelFormat: -1, asyncErrors: 0, lastAsyncError: 0 })) });
  facts.video.observedOrientation = 2;
  const identity = [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1];
  facts.video.finalSamplingCorners = evidence.finalVideoSamplingCorners(identity, 0, false, true);
  assert.equal(JSON.stringify(facts.video.finalSamplingCorners), '[0,1,1,1,0,0,1,0]');
  assert.equal(policy.diagnosticRuntimeFactsAreValid(facts), true);
  runtime.record('connection.rustdesk', 'rustdesk_orientation_observation', 'state', 77, 0, 2, 0, 0, 0, facts);
  // Mutation after capture must not change the journal already copied into the event.
  facts.video.decoderAttempts[0].platformCode = 99;
  runtime.stop();
  const result = exporter.serializeDiagnosticCapture(runtime.frozenCapture());
  assert.equal(result.ok, true, result.code);
  assert.equal(exporter.validateDiagnosticJsonl(result.text), true);
  const rows = result.text.trim().split('\n').map(JSON.parse);
  const row = rows.find(r => r.eventCode === 'rustdesk_orientation_observation');
  assert.ok(row, 'extended evidence was not dropped by the event byte cap');
  assert.equal(row.runtime.video.decoderAttempts[0].platformCode, 5400106);
  assert.equal(row.runtime.video.decoderAttempts.length, 4);
  row.runtime.video.password = 'must reject';
  assert.equal(evidence.parseVideoDiagnosticEvidence(row.runtime.video), null);
  delete row.runtime.video.password;
  row.runtime.video.decoderAttempts[0].host = 'must reject';
  assert.equal(evidence.parseVideoDiagnosticEvidence(row.runtime.video), null);
  delete row.runtime.video.decoderAttempts[0].host;
  row.runtime.video.decoderAttempts[0].stage = 'not numeric';
  assert.equal(evidence.parseVideoDiagnosticEvidence(row.runtime.video), null);
});
test('maximum numeric evidence with four failures fits the per-event byte limit', () => {
  const runtime = new DiagnosticCaptureRuntime({ uptimeMs: () => 1000, wallTimeMs: () => 1700000000000 });
  runtime.start(10, ['connection.rustdesk']);
  const facts = policy.emptyDiagnosticRuntimeFacts();
  facts.video = evidence.videoDiagnosticEvidence({ decoderAttempts: [1,2,3,4].map(() => ({
    serial: 1, decoderGeneration: 1, codec: 1, width: 1, height: 1, stage: 1, result: -1,
    platformCode: 1, capabilityHardware: 1, capabilitySizeSupported: 1, outputWidth: 1,
    outputHeight: 1, outputPixelFormat: 1, asyncErrors: 1, lastAsyncError: 1 })) });
  for (const key of Object.keys(facts.video)) {
    if (typeof facts.video[key] === 'number' && key !== 'evidenceVersion') facts.video[key] = Number.MAX_SAFE_INTEGER;
  }
  for (const attempt of facts.video.decoderAttempts) {
    for (const key of Object.keys(attempt)) attempt[key] = Number.MAX_SAFE_INTEGER;
  }
  facts.producerTransformMatrix = Array(16).fill(-15.123456);
  facts.appliedTextureTransform = Array(16).fill(-15.123456);
  facts.video.finalSamplingCorners = Array(8).fill(-63.123456);
  runtime.record('connection.rustdesk', 'rustdesk_runtime_snapshot', 'state', 1, 0, 0, 0, 0, 0, facts);
  assert.equal(runtime.status().eventCount, 2);
  assert.equal(runtime.status().droppedEventCount, 0);
  runtime.stop();
  assert.equal(exporter.serializeDiagnosticCapture(runtime.frozenCapture()).ok, true);
});
test('rotated asymmetric crop corners follow shader composition order', () => {
  const crop = [0.6,0,0,0,0,0.7,0,0,0,0,1,0,0.1,0.2,0,1];
  assert.equal(JSON.stringify(evidence.finalVideoSamplingCorners(crop, 1, true, false)),
    '[0.7,0.9,0.7,0.2,0.1,0.9,0.1,0.2]');
});
(async () => {
  let failures = 0;
  for (const { name, body } of tests) {
    try { await body(); } catch (error) { failures++; console.error('FAIL', name, error.message); }
  }
  console.log(`${tests.length - failures}/${tests.length} video diagnostics tests passed`);
  process.exitCode = failures ? 1 : 0;
})();
