/* Executes production RDP ImageKit/pasteboard methods with bounded fake ports.
 * Host proofs cover ownership/resource/budget behavior; actual codecs and
 * Harmony clipboard consumers still require signed device acceptance.
 */
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TRANSFER_TYPESCRIPT_PATH || process.env.SSH_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const tests = [], test = (name, run) => tests.push({ name, run });
async function drain() { for (let i = 0; i < 100; i++) await Promise.resolve(); }
function deferred() { let resolve; const promise = new Promise(value => { resolve = value; }); return { resolve, promise }; }
function png(width = 1, height = 1, size = 33) {
  const buffer = new ArrayBuffer(size), bytes = new Uint8Array(buffer);
  bytes.set([137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82]);
  const view = new DataView(buffer); view.setUint32(16, width); view.setUint32(20, height); return buffer;
}
function rtf(size = 13) { const value = new Uint8Array(size); value.fill(32); value.set([123,92,114,116,102,49,32]); value[value.length - 1] = 125; return value.buffer; }
const lease = () => ({ accountScopeId: 'account', accountGeneration: 1, windowId: 'window', hostId: 'host', protocol: 'rdp',
  routeIdentity: 'route', sessionId: 7, attemptId: 3, nativeGeneration: 11 });
const remote = sequence => ({ sequence, text: '', kind: 'rich', ready: true });
const tag = 'remotedesk:remote-text:v1:test:1';
function environment() {
  const cache = new Map(), timers = new Map(), published = [], requests = [], released = [], writes = [], events = [];
  const pixels = [], sources = [], packers = [], reads = [], listeners = new Set();
  let now = 1000, timer = 0, count = 1, data, publicationState = 2, nextRequest = 0;
  let infoOverride = null, pixelOverride = null, decodeGate = null, packGate = null, readGate = null, pixelReadGate = null;
  let packed = png(), imageFailure = false, writeFailure = false, getResultFailure = false;
  let offered = { sequence: 1, formats: [] }; const results = new Map();
  class FakeDate extends Date { static now() { return now; } }
  class PixelMap {
    constructor(options = {}) {
      this.width = options.width ?? 1; this.height = options.height ?? 1; this.stride = options.stride ?? this.width * 4;
      this.alpha = options.alpha ?? 3; this.format = options.format ?? 3; this.bytes = options.bytes ?? this.stride * this.height;
      this.rgba = options.rgba ?? [10,20,30,255]; this.released = false; pixels.push(this);
    }
    getImageInfoSync() { assert.equal(this.released, false); return { size: { width: this.width, height: this.height },
      pixelFormat: this.format, alphaType: this.alpha, stride: this.stride, density: 0, mimeType: 'image/png' }; }
    getPixelBytesNumber() { return this.bytes; } getBytesNumberPerRow() { return this.stride; }
    async readPixelsToBuffer(buffer) { if (pixelReadGate) await pixelReadGate.promise;
      new Uint8Array(buffer).set(this.rgba.slice(0, buffer.byteLength)); }
    async release() { assert.equal(this.released, false, 'PixelMap double release'); this.released = true; events.push('pixel-release'); }
  }
  function pasteData(values = {}, marker = '') {
    let property = { tag: marker };
    return { values, hasType: type => Object.hasOwn(values, type), getTag: () => property.tag,
      getProperty: () => ({ ...property }), setProperty: value => { property = { ...value }; },
      getRecordCount: () => 1, getPrimaryText: () => values['text/plain'],
      getRecord: () => ({ getValidTypes: types => types.filter(type => Object.hasOwn(values, type)),
        async getData(type) { reads.push(type); if (readGate) await readGate.promise; return values[type]; } }) };
  }
  data = pasteData({ 'text/plain': 'existing' });
  const board = { getChangeCount: () => count, hasDataSync: () => true,
    getData(callback) { reads.push('PasteData'); const snapshot = data; if (callback) { queueMicrotask(() => callback(null, snapshot)); return; } return Promise.resolve(snapshot); }, getDataSync: () => data,
    setDataSync(value) { if (writeFailure) throw Error('write failed');
      // System serialization must run before releasing supplied image resources.
      if (value.values.pixelMap) assert.equal(value.values.pixelMap.released, false);
      data = value; count++; writes.push(value); events.push('system-write'); for (const callback of listeners) callback(); },
    on(_event, callback) { listeners.add(callback); }, off(_event, callback) { listeners.delete(callback); } };
  const image = { PixelMapFormat: { RGBA_8888: 3 }, AlphaType: { OPAQUE: 1, PREMUL: 2, UNPREMUL: 3 },
    DecodingDynamicRange: { SDR: 1 },
    createImageSource(buffer) {
      const view = new DataView(buffer), source = { released: false,
        getImageInfoSync() { return infoOverride ?? { size: { width: view.getUint32(16), height: view.getUint32(20) }, mimeType: 'image/png' }; },
        async createPixelMap(options) { assert.equal(options.desiredPixelFormat, 3); assert.equal(options.desiredColorSpace, 'srgb');
          events.push('decode'); if (decodeGate) await decodeGate.promise; if (imageFailure) throw Error('invalid IDAT');
          return new PixelMap(pixelOverride ?? { width: view.getUint32(16), height: view.getUint32(20) }); },
        async release() { assert.equal(this.released, false); this.released = true; events.push('source-release'); }
      }; sources.push(source); return source;
    },
    createImagePacker() { const packer = { released: false,
      async packing(value, options) { assert.equal(options.format, 'image/png'); assert.equal(options.bufferSize, 8 * 1024 * 1024);
        events.push('pack'); if (packGate) await packGate.promise; return packed; },
      async release() { assert.equal(this.released, false); this.released = true; events.push('packer-release'); }
    }; packers.push(packer); return packer; },
    async createPixelMap(buffer, options) { assert.equal(options.srcPixelFormat, 3); assert.equal(options.alphaType, 3);
      events.push('create-dib'); if (decodeGate) await decodeGate.promise;
      return new PixelMap(pixelOverride ?? { width: options.size.width, height: options.size.height, rgba: Array.from(new Uint8Array(buffer)) }); }
  };
  const loader = {
    publishSessionRdpClipboardContent(sessionId, generation, content) { published.push({ sessionId, generation, content }); return { publicationId: published.length, state: publicationState }; },
    getSessionClipboardPublicationState(sessionId, generation, id) { assert.equal(sessionId, 7); assert.equal(generation, 11); assert.ok(id > 0); return publicationState; },
    getSessionRdpClipboardFormats(sessionId, generation) { assert.equal(sessionId, 7); assert.equal(generation, 11); return offered; },
    requestSessionRdpClipboardFormat(sessionId, generation, sequence, format) { const id = ++nextRequest; requests.push({ id, sessionId, generation, sequence, format }); return id; },
    getSessionRdpClipboardFormatResult(sessionId, generation, id) { if (getResultFailure) throw Error('poll failed');
      const request = requests.find(value => value.id === id), configured = results.get(request.format);
      return { requestId: id, sequence: request.sequence, format: request.format, state: configured?.state ?? 'loading',
        diagnosticCode: '', content: configured?.content ?? {} }; },
    releaseSessionRdpClipboardFormat(sessionId, generation, id) { released.push({ sessionId, generation, id }); return true; }
  };
  function load(file) {
    file = path.resolve(root, file); if (cache.has(file)) return cache.get(file).exports;
    const module = { exports: {} }; cache.set(file, module);
    const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
    function requireEts(id) {
      if (id === '@kit.BasicServicesKit') return { pasteboard: { getSystemPasteboard: () => board,
        MIMETYPE_TEXT_PLAIN: 'text/plain', MIMETYPE_TEXT_HTML: 'text/html', MIMETYPE_PIXELMAP: 'pixelMap',
        createData: (values, text) => typeof values === 'string' ? pasteData({ [values]: text }) : pasteData(values) } };
      if (id === '@kit.ImageKit') return { image };
      if (id === '@kit.ArkGraphics2D') return { colorSpaceManager: { create: () => 'srgb', ColorSpace: { SRGB: 4 } } };
      if (id === '@kit.PerformanceAnalysisKit') return { hilog: { info() {}, warn() {} } };
      if (id === '@kit.AbilityKit') return { abilityAccessCtrl: { createAtManager: () => ({ on() {}, off() {} }) } };
      if (!id.startsWith('.')) throw Error('Unexpected dependency ' + id);
      return load(path.resolve(path.dirname(file), id + '.ets'));
    }
    vm.runInNewContext(code, { module, exports: module.exports, require: requireEts, Date: FakeDate, ArrayBuffer, Uint8Array, DataView,
      setTimeout(callback, delay) { timers.set(++timer, { callback, at: now + delay, repeat: false, delay }); return timer; },
      clearTimeout(id) { timers.delete(id); },
      setInterval(callback, delay) { timers.set(++timer, { callback, at: now + delay, repeat: true, delay }); return timer; },
      clearInterval(id) { timers.delete(id); }
    }, { filename: file }); return module.exports;
  }
  const { RdpClipboardContentService: Service } = load('entry/src/main/ets/services/RdpClipboardContentService.ets');
  const { ClipboardBridgeService: Bridge } = load('entry/src/main/ets/services/ClipboardBridgeService.ets');
  const coordinator = load('entry/src/main/ets/services/ClipboardCoordinator.ets').ClipboardCoordinator.getInstance();
  return { authorize: value => ({ lease: value, authorization: coordinator.claimExplicit(value), isAuthorized: () => true }), Service, Bridge, loader, board, pixels, sources, packers, published, requests, released, writes, events, reads,
    service(value = lease()) { return new Service(loader, value); }, pixel(options) { return new PixelMap(options); }, pasteData,
    local(values) { data = pasteData(values); count++; for (const callback of listeners) callback(); return data; },
    setOffer(formats, sequence = 1) { offered = { sequence, formats }; }, result(format, content, state = 'ready') { results.set(format, { content, state }); },
    state(value) { publicationState = value; }, packed(value) { packed = value; }, info(value) { infoOverride = value; }, pixelInfo(value) { pixelOverride = value; },
    gateDecode(value) { decodeGate = value; }, gatePack(value) { packGate = value; }, gateRead(value) { readGate = value; }, gatePixels(value) { pixelReadGate = value; },
    failDecode(value) { imageFailure = value; }, failWrite(value) { writeFailure = value; }, failResult(value) { getResultFailure = value; },
    advance(ms) { now += ms; for (const [id, item] of Array.from(timers)) if (item.at <= now) {
      if (item.repeat) item.at = now + item.delay; else timers.delete(id); item.callback();
    } }, allReleased() { return pixels.every(value => value.released) && sources.every(value => value.released) && packers.every(value => value.released); }
  };
}

test('plain-only returns null and a rich multi-MIME record publishes once with its explicit fallback', async () => {
  const env = environment(), service = env.service(); assert.equal(await service.publishLocal(() => true), null);
  const value = env.local({ 'text/plain': 'fallback', 'text/html': '<b>中文</b>', 'text/rtf': rtf(), 'image/png': png() });
  assert.equal(await service.publishLocal(() => true, value), true); assert.equal(env.published.length, 1);
  const content = env.published[0].content; assert.equal(content.textUtf8, 'fallback'); assert.equal(content.htmlUtf8, '<b>中文</b>');
  assert.equal(content.width, 1); assert.equal(content.height, 1); assert.equal(content.rgbaStraight.byteLength, 4); assert.ok(content.rtfBytes);
  assert.equal(env.reads.filter(value => value === 'PasteData').length, 1, 'supplied rich PasteData must not be read again'); assert.equal(env.allReleased(), true);
});
test('publication waits for the actual ACK and does not accept queued admission', async () => {
  const env = environment(), service = env.service(); env.state(1); let done = false;
  const result = service.publishLocal(() => true, env.local({ 'text/html': '<b>x</b>' })).then(value => { done = true; return value; });
  await drain(); assert.equal(done, false); env.advance(100); await drain(); assert.equal(done, false);
  env.state(2); env.advance(50); await drain(); assert.equal(await result, true);
});
test('publication keeps the captured native identity when the caller mutates its lease', async () => {
  const env = environment(), identity = lease(), service = env.service(identity); identity.sessionId = 99; identity.nativeGeneration = 100;
  assert.equal(await service.publishLocal(() => true, env.local({ 'text/html': 'x' })), true);
  assert.equal(env.published[0].sessionId, 7); assert.equal(env.published[0].generation, 11);
});
test('remote requests every offered representation, releases each request and serializes once before PixelMap release', async () => {
  const env = environment(), service = env.service(); env.setOffer([1,2,3,4,5]);
  env.result(1, { textUtf8: 'fallback' }); env.result(2, { png: png() });
  env.result(3, { rgbaStraight: new ArrayBuffer(4), width: 1, height: 1 }); env.result(4, { htmlUtf8: '<i>rich</i>' }); env.result(5, { rtfBytes: rtf() });
  assert.equal(await service.receiveRemote(remote(1), () => true, tag), true);
  assert.deepEqual(env.requests.map(value => value.format), [1,2,3,4,5]); assert.equal(env.released.length, 5); assert.equal(env.writes.length, 1);
  assert.deepEqual(Object.keys(env.writes[0].values), ['pixelMap','text/html','text/rtf','text/plain']);
  assert.ok(env.events.indexOf('system-write') < env.events.lastIndexOf('pixel-release')); assert.equal(env.allReleased(), true);
});
test('PNG encoded and IHDR budgets reject before ImageKit source creation', async () => {
  for (const buffer of [png(8193,1), png(4096,2048), png(1,1,8*1024*1024+1)]) {
    const env = environment(), service = env.service(); env.setOffer([2]); env.result(2, { png: buffer });
    assert.equal(await service.receiveRemote(remote(1), () => true, tag), false); assert.equal(env.sources.length, 0); assert.equal(env.writes.length, 0);
  }
});
test('ImageSource metadata rejects over-budget or changed dimensions before decoded allocation', async () => {
  const env = environment(), service = env.service(); env.setOffer([2]); env.result(2, { png: png() });
  env.info({ size: { width: 8192, height: 8192 }, mimeType: 'image/png' });
  assert.equal(await service.receiveRemote(remote(1), () => true, tag), false); assert.equal(env.events.includes('decode'), false); assert.equal(env.allReleased(), true);
});
test('actual decode dimensions are checked afterward and a valid offered text fallback remains usable', async () => {
  const env = environment(), service = env.service(); env.setOffer([1,2]); env.result(1, { textUtf8: 'explicit fallback' }); env.result(2, { png: png() });
  env.pixelInfo({ width: 8192, height: 8192, bytes: 268435456 });
  assert.equal(await service.receiveRemote(remote(1), () => true, tag), true); assert.deepEqual(Object.keys(env.writes[0].values), ['text/plain']);
  assert.equal(service.getDiagnosticCode(), 'clipboard_plain_text_fallback'); assert.equal(env.allReleased(), true);
});
test('invalid PNG decoding releases its source and can use strict DIBV5 pixels', async () => {
  const env = environment(), service = env.service(); env.setOffer([2,3]); env.result(2, { png: png() });
  env.result(3, { rgbaStraight: new ArrayBuffer(4), width: 1, height: 1 }); env.failDecode(true);
  assert.equal(await service.receiveRemote(remote(1), () => true, tag), true); assert.ok(env.writes[0].values.pixelMap); assert.equal(env.allReleased(), true);
});
test('DIBV5 length and dimension mismatches reject before PixelMap creation', async () => {
  const env = environment(), service = env.service(); env.setOffer([3]); env.result(3, { rgbaStraight: new ArrayBuffer(4), width: 2, height: 1 });
  assert.equal(await service.receiveRemote(remote(1), () => true, tag), false); assert.equal(env.events.includes('create-dib'), false);
});
test('local PixelMap budgets are checked before packing and its handle is always released', async () => {
  const env = environment(), service = env.service(), pixel = env.pixel({ width: 9000, height: 1 });
  assert.equal(await service.publishLocal(() => true, env.local({ pixelMap: pixel })), false);
  assert.equal(env.events.includes('pack'), false); assert.equal(pixel.released, true);
});
test('local packing is capped and premultiplied RGBA is converted to straight alpha', async () => {
  const env = environment(), service = env.service(), pixel = env.pixel();
  env.pixelInfo({ rgba: [50,25,0,128], alpha: 2 });
  assert.equal(await service.publishLocal(() => true, env.local({ pixelMap: pixel })), true);
  assert.deepEqual(Array.from(new Uint8Array(env.published[0].content.rgbaStraight)), [100,50,0,128]); assert.equal(env.allReleased(), true);
});
test('PNG packing over its encoded budget releases the original PixelMap and ImagePacker', async () => {
  const env = environment(), service = env.service(), pixel = env.pixel(); env.packed(png(1,1,8*1024*1024+1));
  assert.equal(await service.publishLocal(() => true, env.local({ pixelMap: pixel })), false); assert.equal(env.allReleased(), true); assert.equal(env.published.length, 0);
});
test('ownership lost during ImageKit decode releases both ImageSource and late PixelMap without writing', async () => {
  const env = environment(), service = env.service(), gate = deferred(); let current = true;
  env.setOffer([2]); env.result(2, { png: png() }); env.gateDecode(gate);
  const result = service.receiveRemote(remote(1), () => current, tag); await drain(); current = false; gate.resolve();
  assert.equal(await result, false); assert.equal(env.writes.length, 0); assert.equal(env.allReleased(), true); assert.equal(env.released.length, 1);
});
test('native requests cancelled while loading are released with their captured generation', async () => {
  const env = environment(), service = env.service(); let current = true; env.setOffer([1,2,4]);
  const result = service.receiveRemote(remote(1), () => current, tag); await drain(); current = false; env.advance(50); await drain();
  assert.equal(await result, false); assert.equal(env.released.length, 3);
  assert.ok(env.released.every(value => value.sessionId === 7 && value.generation === 11)); assert.equal(env.writes.length, 0);
});
test('native poll exceptions release every started request and cannot fabricate a delivery', async () => {
  const env = environment(), service = env.service(); env.setOffer([1,2,4]); env.failResult(true);
  assert.equal(await service.receiveRemote(remote(1), () => true, tag), false); assert.equal(env.released.length, 3); assert.equal(env.writes.length, 0);
});
test('HTML and RTF limits reject whole representations while retaining explicit valid text', async () => {
  const env = environment(), service = env.service(); env.setOffer([1,4,5]); env.result(1, { textUtf8: 'fallback' });
  env.result(4, { htmlUtf8: 'x'.repeat(1024*1024+1) }); env.result(5, { rtfBytes: rtf(1024*1024+1) });
  assert.equal(await service.receiveRemote(remote(1), () => true, tag), true); assert.deepEqual(Object.keys(env.writes[0].values), ['text/plain']);
});
test('HTML remains literal data and no implicit plaintext is fabricated', async () => {
  const env = environment(), service = env.service(); env.setOffer([4]); env.result(4, { htmlUtf8: '<img src="https://untrusted.invalid/x">' });
  assert.equal(await service.receiveRemote(remote(1), () => true, tag), true);
  assert.deepEqual(Object.keys(env.writes[0].values), ['text/html']); assert.equal(env.sources.length, 0);
});
test('system write failure still releases decoded image resources', async () => {
  const env = environment(), service = env.service(); env.setOffer([2]); env.result(2, { png: png() }); env.failWrite(true);
  assert.equal(await service.receiveRemote(remote(1), () => true, tag), false); assert.equal(env.allReleased(), true); assert.equal(env.writes.length, 0);
});
test('late local PixelMap retrieval after ownership loss releases the returned handle', async () => {
  const env = environment(), service = env.service(), gate = deferred(), pixel = env.pixel(); let current = true;
  env.gateRead(gate); const result = service.publishLocal(() => current, env.local({ pixelMap: pixel })); await drain(); current = false; gate.resolve();
  assert.equal(await result, false); assert.equal(pixel.released, true); assert.equal(env.published.length, 0);
});
test('Bridge and service cooperate on the exact tagged write without replay or echo', async () => {
  const env = environment(), service = env.service(), bridge = new env.Bridge(), sent = [];
  env.setOffer([2,4]); env.result(2, { png: png() }); env.result(4, { htmlUtf8: '<b>same event</b>' });
  bridge.startMonitoring(text => { sent.push(text); return true; }, undefined, true, true, 0, undefined,
    { ...env.authorize(lease()), readRemoteSnapshot: () => remote(1), onRemoteContent: (snapshot, guard, marker) => service.receiveRemote(snapshot, guard, marker) });
  await drain(); env.advance(500); await drain(); env.advance(500); await drain();
  assert.equal(env.writes.length, 1); assert.deepEqual(sent, []); assert.equal(env.allReleased(), true); bridge.stopMonitoring();
});

test('Bridge local rich callback reuses one PasteData and publishes all formats once', async () => {
  const env = environment(), service = env.service(), bridge = new env.Bridge(), sent = [];
  bridge.startMonitoring(text => { sent.push(text); return true; }, undefined, true, true, 0, undefined,
    { ...env.authorize(lease()), onLocalContent: (guard, data) => service.publishLocal(guard, data) });
  await drain(); const initialReads = env.reads.filter(value => value === 'PasteData').length;
  env.local({ 'image/png': png(), 'text/html': '<b>local</b>', 'text/plain': 'fallback' }); await drain();
  assert.equal(env.published.length, 1); assert.deepEqual(sent, []);
  assert.equal(env.reads.filter(value => value === 'PasteData').length, initialReads + 1);
  assert.equal(env.allReleased(), true); bridge.stopMonitoring();
});

test('atomic authority denial suppresses rich native publication after asynchronous decoding', async () => {
  const env = environment(), service = new env.Service(env.loader, lease(), () => false);
  assert.equal(await service.publishLocal(() => true, env.local({'text/html':'<b>blocked</b>'})), false);
  assert.equal(env.published.length, 0);
});
test('atomic authority denial suppresses system rich write and releases decoded resources', async () => {
  const env = environment(), service = new env.Service(env.loader, lease(), () => false);
  env.setOffer([2]); env.result(2, {png: png()});
  assert.equal(await service.receiveRemote(remote(1), () => true, tag), false);
  assert.equal(env.writes.length, 0); assert.equal(env.allReleased(), true);
});

(async () => { for (const { name, run } of tests) { await run(); console.log('PASS ' + name); }
  console.log(`PASS ${tests.length} RDP clipboard content service regressions`);
})().catch(error => { console.error(error); process.exitCode = 1; });
