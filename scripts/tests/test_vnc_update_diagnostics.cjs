// Run with RDP_TYPESCRIPT_PATH=<TypeScript module> node scripts/tests/test_vnc_update_diagnostics.cjs.
// Executes production parsing, capture, JSONL serialization and facade deduplication.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.RDP_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const services = path.join(root, 'entry/src/main/ets/services');
const cache = new Map();
let time = 1000;
const stubs = {
  '@ohos.systemDateTime': { default: { getUptime: () => time, TimeType: { STARTUP: 0 } } },
  '@kit.ArkTS': { util: { TextEncoder, TextDecoder } },
  '@kit.BasicServicesKit': { deviceInfo: { deviceType: 'phone', sdkApiVersion: 26, abiList: 'arm64' } },
  '@kit.CoreFileKit': { fileIo: {}, picker: {} },
  'librdpnapi.so': { default: { VERSION: { gitShortSha: 'test' } } },
  './BoundedDocumentIo': { BoundedDocumentIo: {} },
  './ReleaseNotesRegistry': { CURRENT_RELEASE_VERSION: '1.1.4', CURRENT_RELEASE_VERSION_CODE: 1001004 }
};
function load(file) {
  if (cache.has(file)) return cache.get(file).exports;
  const module = { exports: {} }; cache.set(file, module);
  const source = fs.readFileSync(file, 'utf8');
  const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  const req = name => {
    if (Object.hasOwn(stubs, name)) return stubs[name];
    assert(name.startsWith('.'), 'unexpected dependency ' + name);
    const base = path.resolve(path.dirname(file), name);
    if (fs.existsSync(base + '.d.ts')) return {};
    return load(fs.existsSync(base + '.ets') ? base + '.ets' : base + '.ts');
  };
  vm.runInNewContext(output, { module, exports: module.exports, require: req, TextEncoder, TextDecoder, Date, console }, { filename: file });
  return module.exports;
}
const diag = load(path.join(services, 'VncUpdateDiagnostics.ets'));
const runtime = load(path.join(services, 'DiagnosticCaptureRuntime.ets'));
const exporter = load(path.join(services, 'DiagnosticCaptureExportService.ets'));
const capture = runtime.DiagnosticCaptureRuntime.getInstance();
const marker = '[VNC-FBU reason=1 advertised=65535 processed=4096 encoding=-239]';
let cases = 0;
function test(name, body) { body(); cases++; console.log('PASS ' + name); }
test('numeric suffix parsed exactly', () => {
  assert.deepEqual(JSON.parse(JSON.stringify(diag.parseVncUpdateFailure('VNC 会话已结束: limit ' + marker))),
    { reason: 1, advertised: 65535, processed: 4096, encoding: -239 });
});
test('all failure phases and signed encoding bounds', () => {
  for (let reason = 1; reason <= 4; reason++) for (const encoding of [-2147483648, 2147483647, 0])
    assert(diag.parseVncUpdateFailure(`[VNC-FBU reason=${reason} advertised=1 processed=0 encoding=${encoding}]`));
});
test('reject malformed or out-of-range diagnostics', () => {
  for (const m of [marker+'garbage', marker.replace('65535','65536'), marker.replace('4096','4097'),
    marker.replace('-239','2147483648'), marker.replace('-239','-2147483649'), marker.replace('reason=1','reason=0'),
    marker.replace('reason=1','reason=5'), marker.replace('65535','1'), marker.replace('65535','secret'),
    '[VNC-FBU reason=1 advertised=1e3 processed=0 encoding=0]', 'VNC update contains too many rectangles'])
    assert.equal(diag.parseVncUpdateFailure(m), null, m);
});
test('capture to validated JSONL preserves numbers and strips message', () => {
  assert.equal(capture.start(3, ['core.app','connection.vnc']), 'ok');
  diag.recordVncUpdateFailure(51, 'SECRET host=private.example pixels=password ' + marker);
  time += 10; assert.equal(capture.stop(), 'ok');
  const result = exporter.serializeDiagnosticCapture(capture.frozenCapture());
  assert.equal(result.code, 'ok'); assert(exporter.validateDiagnosticJsonl(result.text));
  assert(!result.text.includes('SECRET')); assert(!result.text.includes('private.example')); assert(!result.text.includes('password'));
  const events = result.text.trim().split('\n').map(JSON.parse).filter(x => x.moduleId === 'connection.vnc');
  assert.equal(events.length, 2); assert.equal(events[0].eventCode, 'vnc_update_rejected');
  assert.equal(events[0].code, 1); assert.equal(events[0].count, 65535);
  assert.equal(events[1].eventCode, 'vnc_update_progress'); assert.equal(events[1].code, -239);
  assert.equal(events[1].count, 4096); assert.equal(events[1].sessionRef, events[0].sessionRef);
  assert.equal(events[0].level, 'error');
});
const facadeSource = fs.readFileSync(path.join(services, 'ExtensionLoader.ets'), 'utf8');
const start = facadeSource.indexOf('  private recordDiagnosticConnectionState(sessionId:');
const end = facadeSource.indexOf('\n  }', start);
assert(start >= 0 && end > start);
const facadeJs = ts.transpileModule('class Facade {\n' + facadeSource.slice(start,end+4) + '\n}\nmodule.exports=Facade;',
  {compilerOptions:{target:ts.ScriptTarget.ES2020}}).outputText;
function facade() {
  const calls=[]; let captureId='capture-1'; let message=marker; let reads=0;
  const context={module:{exports:{}}, diagnosticCaptureIdForModule: () => captureId,
    rdpnapi:{getConnectionLastMessage:() => {reads++; if(message===null) throw Error('native unavailable'); return message;}},
    recordVncUpdateFailure:(...args)=>calls.push(args)};
  vm.runInNewContext(facadeJs,context);
  const f=new context.module.exports(); f.diagnosticConnectionStates=new Map();
  f.diagnosticModuleForSession=()=>'connection.vnc'; f.recordDiagnosticConnection=()=>{};
  return {f,calls,setCapture:v=>captureId=v,setMessage:v=>message=v,reads:()=>reads};
}
test('facade records VNC terminal diagnostic once per capture and state', () => {
  const x=facade(); x.f.recordDiagnosticConnectionState(1,1); assert.equal(x.reads(),0);
  x.f.recordDiagnosticConnectionState(1,4); x.f.recordDiagnosticConnectionState(1,4);
  assert.equal(x.reads(),1); assert.equal(x.calls.length,1); assert.equal(x.calls[0][0],1);
  x.setCapture('capture-2'); x.f.recordDiagnosticConnectionState(1,4); assert.equal(x.calls.length,2);
});
test('other protocols and disabled capture do not read VNC failure', () => {
  const x=facade(); x.f.diagnosticModuleForSession=()=>'connection.rdp'; x.f.recordDiagnosticConnectionState(1,4);
  x.f.diagnosticModuleForSession=()=>'connection.vnc'; x.setCapture(''); x.f.recordDiagnosticConnectionState(2,4);
  assert.equal(x.reads(),0); assert.equal(x.calls.length,0);
});
test('native diagnostic read failure cannot escape polling', () => {
  const x=facade(); x.setMessage(null); assert.doesNotThrow(()=>x.f.recordDiagnosticConnectionState(1,4));
  assert.equal(x.calls.length,0);
});
console.log(cases + ' VNC diagnostic checks passed');
