/* Executes production HID parsing and the USBManager probe with controlled USB
 * callbacks. This is transport logic coverage, not hardware/RDP acceptance. */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const tests = [];
function test(name, body) { tests.push({ name, body }); }
function deferred() { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; }
async function settle() { for (let i = 0; i < 35; i++) await Promise.resolve(); }
const descriptor = Uint8Array.from([0x06, 0xd0, 0xf1, 0x09, 0x01, 0xa1, 0x01, 0x09, 0x20,
  0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x40, 0x81, 0x02, 0x09, 0x21,
  0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x40, 0x91, 0x02, 0xc0]);
function fixture(debug = true) {
  const state = { mode: 'pro', deviceType: 'pc', api: 26, capability: true, allowed: true,
    timers: new Map(), intervals: new Map(), listeners: [], transitions: [], nextTimer: 0, now: 100000,
    operations: [], descriptors: descriptor, input: [], grants: [], pipes: [], transfers: [],
    claims: [], releases: [], closes: [], cancels: [], pending: null, hold: '', permissionWait: null,
    currentConfig: 1, claimResult: 0, transferStatus: 0, short: false, wrongNonce: false, cbor: true, extension: 0,
    nativeAvailable: false, nativeStarts: [], nativeCancels: [], nativeReplies: [], nativeId: 0, nativeStep: 0,
    nativeBusy: false, nativeRejectReply: false, nativeStatus: 0, nativeRequest: null, nativeOnPoll: null,
    delayCancelCallback: false };
  const output = { address: 1, attributes: 3, interval: 5, maxPacketSize: 64, direction: 0, number: 1, type: 3, interfaceId: 2 };
  const input = { ...output, address: 0x81, direction: 0x80 };
  const iface = { id: 2, protocol: 0, clazz: 3, subClass: 0, alternateSetting: 0, name: 'FIDO', endpoints: [output, input] };
  const config = { id: 1, attributes: 0x80, maxPower: 100, name: '', isRemoteWakeup: false, isSelfPowered: false, interfaces: [iface] };
  state.devices = [{ busNum: 1, devAddress: 2, name: 'opaque-device', serial: 'NEVER_DISPLAY',
    manufacturerName: 'Device\u202e', productName: 'Key\n', vendorId: 0x1234, productId: 0x5678,
    clazz: 0, subClass: 0, protocol: 0, configs: [config] }];
  let codec;
  const usbManager = {
    USBRequestDirection: { USB_REQUEST_DIR_TO_DEVICE: 0, USB_REQUEST_DIR_FROM_DEVICE: 0x80 },
    UsbTransferFlags: { USB_TRANSFER_SHORT_NOT_OK: 0 },
    UsbEndpointTransferType: { TRANSFER_TYPE_INTERRUPT: 3 },
    UsbTransferStatus: { TRANSFER_COMPLETED: 0 },
    getDevices() { state.operations.push('enumerate'); return state.devices; },
    async requestRight(name) {
      state.grants.push(name); if (state.permissionWait) await state.permissionWait.promise; return state.allowed;
    },
    connectDevice(device) {
      const pipe = { busNum: device.busNum, devAddress: device.devAddress, testId: state.pipes.length };
      state.pipes.push(pipe); return pipe;
    },
    async usbControlTransfer(pipe, params, timeout) {
      assert.equal(timeout, 1500); assert.ok(state.pipes.includes(pipe));
      state.operations.push(params.bRequest === 8 ? 'configuration' : 'descriptor');
      if (params.bRequest === 8) {
        assert.equal(params.bmRequestType, 0x80); params.data[0] = state.currentConfig; return 1;
      }
      assert.equal(params.bRequest, 6); assert.equal(params.bmRequestType, 0x81);
      assert.equal(params.wValue, 0x2200); assert.equal(params.wIndex, 2); assert.equal(params.wLength, 4096);
      params.data.set(state.descriptors); return state.descriptors.length;
    },
    claimInterface(pipe, target, force) {
      assert.equal(force, false); assert.equal(target.id, 2); state.claims.push(pipe); return state.claimResult;
    },
    releaseInterface(pipe, target) { assert.equal(target.id, 2); state.releases.push(pipe); return 0; },
    closePipe(pipe) { state.closes.push(pipe); return 0; },
    usbSubmitTransfer(request) {
      assert.equal(request.type, 3);
      if (state.nativeAvailable) assert.equal(request.timeout, 421);
      else assert.equal(request.timeout, 1500);
      assert.equal(request.length, 64); state.transfers.push(request);
      const direction = (request.endpoint & 0x80) ? 'in' : 'out';
      if (direction === 'out') {
        if (request.buffer[4] === 0x90 && state.nativeAvailable) {
          assert.equal(request.buffer[5] * 256 + request.buffer[6], 1);
          assert.equal(request.buffer[7], 4);
          state.input.push(...codec.proFidoPackets(0x10203040, 0x10, Uint8Array.from([0, 0xa0])));
        } else {
          assert.equal(request.buffer[4], 0x86, 'probe may issue only INIT or library GetInfo');
          assert.equal(request.buffer[5] * 256 + request.buffer[6], 8);
          const data = new Uint8Array(17 + state.extension); data.set(request.buffer.subarray(7, 15));
          if (state.wrongNonce) data[0] ^= 1;
          data.set([0x10, 0x20, 0x30, 0x40, 2, 1, 0, 0, state.cbor ? 4 : 0], 8);
          state.input.push(...codec.proFidoPackets(0xffffffff, 6, data));
        }
      }
      if (state.hold === direction) { state.pending = request; return; }
      if (direction === 'in') request.buffer.set(state.input.shift() || new Uint8Array(64));
      queueMicrotask(() => request.callback(undefined, { status: state.transferStatus, isoPacketDescs: [], actualLength: state.short ? 63 : 64 }));
    },
    usbCancelTransfer(request) {
      assert.ok(state.transfers.includes(request)); state.cancels.push(request);
      if (state.delayCancelCallback) return;
      queueMicrotask(() => request.callback(undefined, { status: 3, isoPacketDescs: [], actualLength: 0 }));
    }
  };
  const runtime = { snapshot: () => ({ mode: state.mode }), subscribe(callback) {
    state.listeners.push(callback); callback(); return () => { state.listeners = state.listeners.filter(f => f !== callback); };
  } };
  const native = {
    proFidoProbeAvailable: () => state.nativeAvailable,
    proFidoProbeStart() {
      assert.equal(state.claims.length, state.releases.length + 1, 'native start must follow the owned claim');
      assert.equal(state.operations.at(-1), 'descriptor');
      state.nativeStarts.push(state.nativeId + 1);
      if (state.nativeBusy) return 0;
      state.nativeStep = 0; return ++state.nativeId;
    },
    proFidoProbePoll(id) {
      assert.equal(id, state.nativeId);
      if (state.nativeOnPoll) state.nativeOnPoll();
      if (state.nativeRequest) return state.nativeRequest;
      if (state.nativeStatus || state.nativeStep === 6) return { status: state.nativeStatus || 1, requestId: 0 };
      const write = state.nativeStep % 2 === 0;
      const data = !write ? new Uint8Array(64) : state.nativeStep === 0 ?
        codec.proFidoPackets(0xffffffff, 6, new Uint8Array(8))[0] :
        codec.proFidoPackets(0x10203040, 0x10, Uint8Array.from([4]))[0];
      return { status: 0, requestId: state.nativeStep + 1, timeoutMs: 421, write, data };
    },
    proFidoProbeReply(id, request, data, success) {
      assert.equal(id, state.nativeId); assert.equal(request, state.nativeStep + 1);
      assert.equal(data.length, 64); assert.equal(success, true);
      state.nativeReplies.push({ id, request }); state.nativeStep++;
      return !state.nativeRejectReply;
    },
    proFidoProbeCancel(id) { state.nativeCancels.push(id); }
  };
  const mocks = { BuildProfile: { DEBUG: debug }, 'librdpnapi.so': { default: native }, '@kit.BasicServicesKit': { usbManager,
    deviceInfo: { get sdkApiVersion() { return state.api; }, get deviceType() { return state.deviceType; } } },
    '@kit.CryptoArchitectureKit': { cryptoFramework: { createRandom: () => ({ generateRandomSync: n => ({ data: new Uint8Array(crypto.randomBytes(n)) }) }) } },
    './ProAppRuntime': { ProAppRuntime: { getInstance: () => ({ runtime }) } }
    , '../AccountSessionCoordinator': { AccountSessionCoordinator: { getInstance: () => ({ onTransitionActivity(callback) {
      state.transitions.push(callback); callback(false); return () => {};
    } }) } }
  };
  const cache = new Map();
  function load(file) {
    file = path.resolve(root, file); if (cache.has(file)) return cache.get(file).exports;
    const module = { exports: {} }; cache.set(file, module);
    const source = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
    }).outputText;
    vm.runInNewContext(source, { module, exports: module.exports,
      Date: class extends Date { static now() { return state.now; } }, canIUse: () => state.capability,
      setTimeout(callback, delay) { const id = ++state.nextTimer; state.timers.set(id, { callback, delay }); return id; },
      clearTimeout(id) { state.timers.delete(id); },
      setInterval(callback, delay) { const id = ++state.nextTimer; state.intervals.set(id, { callback, delay }); return id; },
      clearInterval(id) { state.intervals.delete(id); },
      require(id) {
        if (mocks[id]) return mocks[id];
        if (id.startsWith('.')) return load(path.resolve(path.dirname(file), id + '.ets'));
        throw new Error('unexpected module ' + id);
      }
    }, { filename: file });
    return module.exports;
  }
  codec = load('entry/src/main/ets/services/pro/ProFidoHidCodec.ets');
  const { ProUsbFidoProbe } = load('entry/src/main/ets/services/pro/ProUsbFidoProbe.ets');
  const probe = ProUsbFidoProbe.getInstance();
  const owner = () => true;
  const select = () => probe.list()[0].key;
  return { state, codec, probe, owner, select, iface, config };
}
test('FIDO discovery requires the whole supported collection and rejects keyboard, mixed and malformed HID layouts', () => {
  const { codec } = fixture(); assert.equal(codec.isProFidoReportDescriptor(descriptor), true);
  const keyboard = descriptor.slice(); keyboard[1] = 1; keyboard[2] = 0;
  const duplicateInput = descriptor.slice(); duplicateInput[31] = 0x81;
  const shortReport = descriptor.slice(); shortReport[17] = 32;
  const mismatchedOutput = descriptor.slice(); mismatchedOutput[21] = 0x20;
  for (const data of [new Uint8Array(), descriptor.subarray(0, 32), keyboard, duplicateInput, shortReport,
    mismatchedOutput, Uint8Array.from([...descriptor, ...descriptor]),
    Uint8Array.from([...descriptor.subarray(0, 7), 0x85, 1, ...descriptor.subarray(7)]),
    Uint8Array.from([...descriptor, 0xfe, 0, 0]), new Uint8Array(4097)]) {
    assert.equal(codec.isProFidoReportDescriptor(data), false);
  }
});
test('local Usage lists cannot conceal mixed or duplicate fields before any FIDO Main item', async () => {
  for (const [offset, expected] of [[3, 1], [7, 0x20], [20, 0x21]]) {
    for (const extra of [[0x0b, 0x04, 0x00, 0x07, 0x00], [0x09, expected]]) {
      const f = fixture();
      f.state.descriptors = Uint8Array.from([...descriptor.subarray(0, offset), ...extra, ...descriptor.subarray(offset)]);
      assert.equal(f.codec.isProFidoReportDescriptor(f.state.descriptors), false);
      await assert.rejects(() => f.probe.probe(f.select(), f.owner));
      assert.equal(f.state.claims.length, 0); assert.equal(f.state.transfers.length, 0);
      assert.equal(f.state.closes.length, 1);
    }
  }
  const { codec } = fixture();
  assert.equal(codec.isProFidoReportDescriptor(Uint8Array.from([...descriptor, 0x09, 0x20])), false);
  assert.equal(codec.isProFidoReportDescriptor(Uint8Array.from([...descriptor.subarray(0, 33), 0x09, 0x20, 0xc0])), false);
});
test('CTAPHID framing preserves payload at first/continuation boundaries and maximum size', () => {
  const { codec } = fixture();
  for (const size of [0, 8, 17, 57, 58, 116, 117, 7609]) {
    const data = crypto.randomBytes(size); const frames = codec.proFidoPackets(0x10203040, 6, data);
    const reader = new codec.ProFidoHidResponse(0x10203040, 6); let result;
    frames.forEach(packet => { result = reader.accept(packet); });
    assert.deepEqual(Buffer.from(result), data); assert.ok(frames.length <= 129);
  }
  assert.throws(() => codec.proFidoPackets(1, 6, new Uint8Array(7610)));
  assert.throws(() => codec.proFidoPackets(0, 6, new Uint8Array(8)));
});
test('CTAPHID ignores other channels but rejects own out-of-order, duplicate, wrong-command and oversized frames', () => {
  const { codec } = fixture(); const frames = codec.proFidoPackets(1, 6, new Uint8Array(120));
  const reader = new codec.ProFidoHidResponse(1, 6);
  assert.equal(reader.accept(codec.proFidoPackets(2, 6, new Uint8Array(8))[0]), null);
  assert.equal(reader.accept(frames[0]), null); assert.throws(() => reader.accept(frames[2]));
  assert.throws(() => new codec.ProFidoHidResponse(1, 6).accept(frames[1]));
  assert.throws(() => new codec.ProFidoHidResponse(1, 6).accept(codec.proFidoPackets(1, 3, new Uint8Array(1))[0]));
  const oversized = frames[0].slice(); oversized[5] = 255; oversized[6] = 255;
  assert.throws(() => new codec.ProFidoHidResponse(1, 6).accept(oversized));
  const duplicate = new codec.ProFidoHidResponse(1, 6); duplicate.accept(frames[0]); assert.throws(() => duplicate.accept(frames[0]));
});
test('INIT verifies nonce, allocated channel and protocol; extension bytes and CBOR flag are handled', () => {
  const { codec } = fixture(); const nonce = crypto.randomBytes(8); const response = new Uint8Array(100);
  response.set(nonce); response.set([1, 2, 3, 4, 2, 1, 0, 0, 4], 8);
  assert.equal(codec.parseProFidoInit(response, nonce).cbor, true);
  response[16] = 0; assert.equal(codec.parseProFidoInit(response, nonce).cbor, false);
  assert.throws(() => codec.parseProFidoInit(response, crypto.randomBytes(8)));
  response[12] = 1; assert.throws(() => codec.parseProFidoInit(response, nonce));
  response[12] = 2; response.fill(255, 8, 12); assert.throws(() => codec.parseProFidoInit(response, nonce));
  assert.throws(() => codec.parseProFidoInit(response.subarray(0, 16), nonce));
});
test('Release, free mode, unsupported device/API and missing capability never enumerate or authorize USB', async () => {
  for (const condition of ['release', 'free', 'phone', 'api', 'capability']) {
    const f = fixture(condition !== 'release');
    if (condition === 'free') f.state.mode = 'free';
    if (condition === 'phone') f.state.deviceType = 'phone';
    if (condition === 'api') f.state.api = 22;
    if (condition === 'capability') f.state.capability = false;
    assert.equal(f.probe.list().length, 0); await assert.rejects(() => f.probe.probe('guess', f.owner));
    assert.equal(f.state.operations.length, 0); assert.equal(f.state.grants.length, 0);
  }
});
test('enumeration excludes Boot HID and unsupported endpoints and returns only sanitized labels', () => {
  const f = fixture(); let items = f.probe.list(); assert.equal(items.length, 1);
  assert.equal(/[\u202e\n]/.test(items[0].label), false); assert.equal(items[0].label.includes('NEVER_DISPLAY'), false);
  for (const mutation of [() => { f.iface.protocol = 1; }, () => { f.iface.subClass = 1; },
    () => { f.iface.endpoints[0].maxPacketSize = 32; }]) {
    f.iface.protocol = 0; f.iface.subClass = 0; f.iface.endpoints[0].maxPacketSize = 64;
    mutation(); assert.equal(f.probe.list().length, 0);
  }
});
test('actual USB probe performs read-only descriptor validation before non-forced claim and INIT', async () => {
  const f = fixture(); f.state.extension = 120; const result = await f.probe.probe(f.select(), f.owner);
  assert.ok(result.includes('FIDO2 USB 初始化成功')); assert.equal(f.state.grants.length, 1);
  assert.equal(f.state.claims.length, 1); assert.equal(f.state.releases.length, 1); assert.equal(f.state.closes.length, 1);
  assert.equal(f.state.closes[0], f.state.pipes[0]); assert.equal(f.state.releases[0], f.state.pipes[0]);
  assert.equal(f.probe.busy(), false); assert.equal(f.state.intervals.size, 0); assert.equal(f.state.listeners.length, 0);
  assert.deepEqual(f.state.operations, ['enumerate', 'enumerate', 'configuration', 'descriptor']);
});
test('bad descriptor/configuration and denied claim never send INIT or force/reset the device', async () => {
  for (const issue of ['descriptor', 'config', 'claim']) {
    const f = fixture();
    if (issue === 'descriptor') f.state.descriptors = new Uint8Array(32);
    if (issue === 'config') f.state.currentConfig = 2;
    if (issue === 'claim') f.state.claimResult = -1;
    await assert.rejects(() => f.probe.probe(f.select(), f.owner));
    assert.equal(f.state.transfers.length, 0); assert.equal(f.state.closes.length, 1);
    assert.equal(f.state.releases.length, 0); assert.equal(f.state.claims.length, issue === 'claim' ? 1 : 0);
  }
});
test('temporary permission denial and authorization-time device changes cannot open a pipe', async () => {
  for (const issue of ['denied', 'removed', 'interface']) {
    const f = fixture(); const key = f.select(); const wait = deferred(); f.state.permissionWait = wait;
    const pending = f.probe.probe(key, f.owner); await settle();
    if (issue === 'denied') f.state.allowed = false;
    if (issue === 'removed') f.state.devices = [];
    if (issue === 'interface') { f.state.devices = JSON.parse(JSON.stringify(f.state.devices)); f.state.devices[0].configs[0].interfaces[0].protocol = 1; }
    wait.resolve(); await assert.rejects(() => pending); assert.equal(f.state.pipes.length, 0);
  }
});
test('cancelled late permission cannot open a device or cancel a later successful operation', async () => {
  const f = fixture(); const key = f.select(); const wait = deferred(); f.state.permissionWait = wait;
  const old = f.probe.probe(key, f.owner); await settle(); f.probe.cancel(f.owner); await assert.rejects(() => old);
  f.state.permissionWait = null; const result = await f.probe.probe(key, () => true); assert.ok(result.includes('成功'));
  wait.resolve(); await settle(); assert.equal(f.state.pipes.length, 1); assert.equal(f.state.closes.length, 1);
});
test('runtime changes and inactive owner fence permission callbacks even while mode remains Pro', async () => {
  for (const issue of ['runtime', 'owner', 'transition']) {
    const f = fixture(); const wait = deferred(); f.state.permissionWait = wait; let live = true;
    const owner = () => live; const pending = f.probe.probe(f.select(), owner); await settle();
    if (issue === 'runtime') f.state.listeners.slice().forEach(fn => fn());
    else if (issue === 'transition') f.state.transitions.forEach(fn => fn(true));
    else { live = false; [...f.state.intervals.values()][0].callback(); }
    await assert.rejects(() => pending); wait.resolve(); await settle(); assert.equal(f.state.pipes.length, 0);
  }
});
test('an account transition already in progress cannot start USB detection under simulated Pro', async () => {
  const f = fixture(); const key = f.select(); f.state.transitions.forEach(fn => fn(true));
  assert.equal(f.probe.debugAllowed(), false); assert.equal(f.probe.list().length, 0);
  await assert.rejects(() => f.probe.probe(key, f.owner)); assert.equal(f.state.grants.length, 0);
  f.state.transitions.forEach(fn => fn(false)); assert.equal(f.probe.debugAllowed(), true);
});
test('in-flight cancel/timeout/disconnect release only the owned interface and ignore unrelated panel cancellation', async () => {
  for (const issue of ['cancel', 'timeout', 'disconnect', 'short', 'nonce']) {
    const f = fixture();
    if (issue === 'cancel' || issue === 'timeout') f.state.hold = 'in';
    if (issue === 'disconnect') f.state.transferStatus = 5;
    if (issue === 'short') f.state.short = true;
    if (issue === 'nonce') f.state.wrongNonce = true;
    const pending = f.probe.probe(f.select(), f.owner); await settle();
    if (issue === 'cancel' || issue === 'timeout') {
      assert.ok(f.state.pending); f.probe.cancel(() => true); assert.equal(f.probe.busy(), true);
      if (issue === 'cancel') f.probe.cancel(f.owner);
      else [...f.state.timers.values()].find(timer => timer.delay === 2200).callback();
    }
    await assert.rejects(() => pending); assert.equal(f.state.releases.length, 1); assert.equal(f.state.closes.length, 1);
    assert.equal(f.state.releases[0], f.state.pipes[0]); assert.equal(f.probe.busy(), false);
    if (issue === 'cancel' || issue === 'timeout') assert.equal(f.state.cancels.length, 1);
  }
});

test('library mode is gated before permission, then forwards only bounded requests after a validated claim', async () => {
  const denied = fixture(); const key = denied.select();
  await assert.rejects(() => denied.probe.probe(key, denied.owner, true));
  assert.equal(denied.state.grants.length, 0); assert.equal(denied.state.nativeStarts.length, 0);
  const release = fixture(false); release.state.nativeAvailable = true;
  assert.equal(release.probe.libraryAvailable(), false);
  const f = fixture(); f.state.nativeAvailable = true;
  const result = await f.probe.probe(f.select(), f.owner, true);
  assert.ok(result.includes('库通信与能力读取成功'));
  assert.equal(f.state.nativeStarts.length, 1); assert.equal(f.state.nativeReplies.length, 6);
  assert.deepEqual(f.state.nativeCancels, [1]); assert.equal(f.state.transfers.length, 6);
  assert.equal(f.state.releases.length, 1); assert.equal(f.state.closes.length, 1);
  assert.equal(f.state.timers.size, 0); assert.equal(f.state.intervals.size, 0);
});
test('library mode cannot bypass denied permission, descriptor/configuration validation or an occupied interface', async () => {
  for (const issue of ['permission', 'descriptor', 'configuration', 'claim']) {
    const f = fixture(); f.state.nativeAvailable = true;
    if (issue === 'permission') f.state.allowed = false;
    if (issue === 'descriptor') f.state.descriptors = new Uint8Array(32);
    if (issue === 'configuration') f.state.currentConfig = 2;
    if (issue === 'claim') f.state.claimResult = -1;
    await assert.rejects(() => f.probe.probe(f.select(), f.owner, true));
    assert.equal(f.state.nativeStarts.length, 0); assert.equal(f.state.transfers.length, 0);
  }
});
test('busy native worker, malformed native requests, failure and rejected replies release the selected pipe', async () => {
  for (const issue of ['busy', 'request', 'timeout', 'length', 'failed', 'reply', 'short', 'usb']) {
    const f = fixture(); f.state.nativeAvailable = true;
    if (issue === 'busy') f.state.nativeBusy = true;
    if (['request', 'timeout', 'length'].includes(issue)) {
      f.state.nativeRequest = { status: 0, requestId: issue === 'request' ? 305 : 1,
        timeoutMs: issue === 'timeout' ? 1501 : 421, data: new Uint8Array(issue === 'length' ? 65 : 64), write: true };
    }
    if (issue === 'failed') f.state.nativeStatus = 2;
    if (issue === 'reply') f.state.nativeRejectReply = true;
    if (issue === 'short') f.state.short = true;
    if (issue === 'usb') f.state.transferStatus = 5;
    await assert.rejects(() => f.probe.probe(f.select(), f.owner, true));
    assert.equal(f.state.closes.length, 1); assert.equal(f.state.releases.length, 1);
    assert.deepEqual(f.state.nativeCancels, issue === 'busy' ? [] : [1]);
    assert.equal(f.state.nativeReplies.length, issue === 'reply' ? 1 : 0);
  }
});
test('account transition, owner departure and USB timeout cancel the exact native generation before late callbacks', async () => {
  for (const issue of ['transition', 'owner', 'cancel', 'timeout']) {
    const f = fixture(); f.state.nativeAvailable = true; f.state.hold = 'in'; f.state.delayCancelCallback = true;
    let live = true; const owner = () => live;
    const pending = f.probe.probe(f.select(), owner, true); await settle();
    const oldTransfer = f.state.pending; assert.ok(oldTransfer);
    if (issue === 'transition') f.state.transitions.forEach(fn => fn(true));
    if (issue === 'owner') { live = false; [...f.state.intervals.values()][0].callback(); }
    if (issue === 'cancel') f.probe.cancel(owner);
    if (issue === 'timeout') [...f.state.timers.values()].find(t => t.delay === 1121).callback();
    await assert.rejects(() => pending);
    assert.deepEqual(f.state.nativeCancels, [1]); assert.equal(f.state.nativeReplies.length, 1);
    f.state.transitions.forEach(fn => fn(false)); f.state.hold = ''; f.state.input = [];
    const result = await f.probe.probe(f.select(), () => true, true); assert.ok(result.includes('成功'));
    const replyCount = f.state.nativeReplies.length;
    oldTransfer.callback(undefined, { status: 0, isoPacketDescs: [], actualLength: 64 }); await settle();
    assert.equal(f.state.nativeReplies.length, replyCount); assert.deepEqual(f.state.nativeCancels, [1, 2]);
    assert.equal(f.state.closes.length, 2); assert.equal(f.state.releases.length, 2);
  }
});
test('synchronous native completion cannot escape a transition triggered while polling', async () => {
  const f = fixture(); f.state.nativeAvailable = true; f.state.nativeStatus = 1;
  f.state.nativeOnPoll = () => f.state.transitions.forEach(fn => fn(true));
  await assert.rejects(() => f.probe.probe(f.select(), f.owner, true));
  assert.deepEqual(f.state.nativeCancels, [1]); assert.equal(f.state.transfers.length, 0);
  assert.equal(f.state.closes.length, 1);
});

(async () => {
  for (const { name, body } of tests) { await body(); process.stdout.write('PASS ' + name + '\n'); }
  process.stdout.write(`${tests.length} production USB/FIDO checks passed\n`);
})().catch(error => { process.stderr.write(error.stack + '\n'); process.exitCode = 1; });
