// Production policy, timer and page-handler tests. Device input/sign/render A/B is separate.
// RDP_TYPESCRIPT_PATH=<DevEco TypeScript module> node scripts/tests/test_rustdesk_explicit_phone.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.RDP_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
function compile(source, context = {}) {
  const js = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020,
    module: ts.ModuleKind.CommonJS } }).outputText;
  const box = { exports: {}, module: { exports: {} }, ...context };
  box.exports = box.module.exports;
  vm.runInNewContext(js, box);
  return box.module.exports;
}
const policySource = fs.readFileSync(path.join(root, 'entry/src/main/ets/services/RustDeskExplicitPhonePolicy.ets'), 'utf8');
const policy = compile(policySource);
const geometry = compile(fs.readFileSync(path.join(root, 'entry/src/main/ets/services/RemoteSurfaceTransformPolicy.ets'), 'utf8'));
const canvas = compile(fs.readFileSync(path.join(root, 'entry/src/main/ets/services/RemoteCanvasTransformPolicy.ets'), 'utf8'));
let count = 0;
function test(name, run) { run(); console.log('PASS ' + name); ++count; }
function host(overrides = {}) {
  return { protocol: 'rustdesk', rustdeskTargetDevice: 'phone', sourceType: 'manual',
    rustdeskProManaged: false, rustdeskProAccountId: '', rustdeskProPeerId: '',
    rustdeskProPlatform: '', ...overrides };
}
test('only saved manual phone choice enters; peer Android and controller type never grant scope', () => {
  assert(policy.hasExplicitRustDeskPhoneChoice(host()));
  for (const protocol of ['rdp', 'vnc', 'ssh', 'sftp', 'moonlight', '', 'RustDesk'])
    assert(!policy.hasExplicitRustDeskPhoneChoice(host({ protocol })));
  for (const target of ['computer', '', undefined, null, 'PHONE', 'tablet'])
    assert(!policy.hasExplicitRustDeskPhoneChoice(host({ rustdeskTargetDevice: target, peerPlatform: 'Android', controller: 'phone' })));
  for (const sourceType of ['', undefined, 'import', 'rustdesk_pro'])
    assert(!policy.hasExplicitRustDeskPhoneChoice(host({ sourceType })));
  for (const overrides of [{rustdeskProManaged: true}, {rustdeskProAccountId: 'account'},
    {rustdeskProPeerId: 'peer'}, {rustdeskProPlatform: 'Android'}])
    assert(!policy.hasExplicitRustDeskPhoneChoice(host(overrides)));
});
test('temporary phone mode preserves every saved mode and host field', () => {
  const selected = host(); const before = JSON.stringify(selected);
  for (const mode of [0, 1, 2]) {
    assert.equal(policy.explicitPhoneControlMode(true, mode), 1);
    assert.equal(policy.explicitPhoneControlMode(false, mode), mode);
  }
  assert.equal(JSON.stringify(selected), before);
});
const actionSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/services/RustDeskPhoneActions.ets'), 'utf8');
function actions() {
  const pending = new Map(), all = [], sent = [], rejected = []; let timer = 0;
  let current = { sessionId: 7, generation: 8, ownerToken: 9, streamEpoch: 10 };
  const { RustDeskPhoneActions, samePhoneOwner } = compile(actionSource, {
    setTimeout(fn, ms) { pending.set(++timer, {fn, ms}); all.push(fn); return timer; },
    clearTimeout(id) { pending.delete(id); }
  });
  const tx = new RustDeskPhoneActions((owner, operation) => {
    if (!samePhoneOwner(owner, current)) { rejected.push(operation); return 0; }
    sent.push(operation); return 1;
  });
  return { tx, pending, all, sent, rejected, owner: () => ({...current}),
    replace(changes) { current = {...current, ...changes}; },
    fire() { for (const [id, entry] of [...pending]) { pending.delete(id); entry.fn(); } } };
}
test('Android/version/action admission rejects hidden or unknown operations', () => {
  for (const caps of [0, 1, 2]) {
    const f = actions(); assert(!f.tx.start(f.owner(), 0, caps)); assert.deepEqual(f.sent, []);
  }
  const f = actions(); assert(!f.tx.start(f.owner(), 0, 3));
  for (const action of [-1, 3, 5, 7, 9, 10]) assert(!f.tx.start(f.owner(), action, 31));
  assert.deepEqual(f.sent, []);
});
test('recent-apps transaction holds 500 ms and prevents overlapping actions', () => {
  const f = actions(); assert(f.tx.start(f.owner(), 2, 31));
  assert.equal([...f.pending.values()][0].ms, 500);
  assert(!f.tx.start(f.owner(), 1, 31));
  f.fire(); assert.deepEqual(f.sent, [2,3]); assert.equal(f.pending.size, 0);
  assert(f.tx.start(f.owner(), 1, 31)); assert.deepEqual(f.sent, [2,3,1]);
});
test('volume and power have bounded 100 ms matching releases', () => {
  for (const action of [4,6,8]) {
    const f = actions(); assert(f.tx.start(f.owner(), action, 31));
    assert.equal([...f.pending.values()][0].ms, 100); f.fire();
    assert.deepEqual(f.sent, [action, action + 1]);
  }
});
test('cancel is idempotent; already queued timer callbacks cannot release again', () => {
  const f = actions(); f.tx.start(f.owner(), 2, 31); f.tx.cancel(); f.tx.cancel();
  f.all[0](); assert.deepEqual(f.sent, [2,3]); assert.equal(f.pending.size, 0);
});
test('session, owner, generation and same-session transport replacement reject stale releases', () => {
  for (const field of ['sessionId', 'generation', 'ownerToken', 'streamEpoch']) {
    const f = actions(); const owner = f.owner(); f.tx.start(owner, 2, 31);
    owner[field] = 900; // Mutation of caller object cannot redirect captured transaction.
    f.replace({[field]: 999}); f.fire();
    assert.deepEqual(f.sent, [2]); assert.deepEqual(f.rejected, [3]);
  }
});
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/RemoteDesktop.ets'), 'utf8');
function method(name) {
  const start = source.indexOf('  private ' + name + '('); assert(start >= 0, name);
  const end = source.indexOf('\n  }', start); return source.slice(start, end + 4);
}
const methods = ['isRustDeskSession', 'isExplicitPhoneSession', 'currentControlMode',
  'shouldUseRustDeskRemoteAppTouchScale', 'handleExplicitPhoneAxis', 'cancelExplicitPhoneInput',
  'isRustDeskPhysicalTouchpadAxis'];
const AxisAction = { BEGIN: 0, UPDATE: 1, END: 2, CANCEL: 3 };
const SourceTool = { TOUCHPAD: 4, MOUSE: 3 };
const Page = compile('class Page {\n' + methods.map(method).join('\n') + '\n}\nmodule.exports = Page;', {
  ...policy, pinchCanvasTransform: canvas.pinchCanvasTransform, AxisAction, AxisType: { PINCH_AXIS: 3 }, SourceTool,
  shouldUseRustDeskPhysicalTouchpad: (p, desktop, mode, pad) => p === 'rustdesk' && desktop && mode === 2 && pad
});
function page(rotation = 0) {
  const h = new Page(), events = [], accepted = [], owner = { sessionId: 7, generation: 8, ownerToken: 9, streamEpoch: 10 };
  const transform = { remoteWidth: 1080, remoteHeight: 2400, rotation,
    viewportX: 0, viewportY: 0, viewportW: rotation % 2 ? 2400 : 1080,
    viewportH: rotation % 2 ? 1080 : 2400,
    surfaceWidthPx: rotation % 2 ? 2400 : 1080, surfaceHeightPx: rotation % 2 ? 1080 : 2400,
    surfaceWidthVp: rotation % 2 ? 2400 : 1080, surfaceHeightVp: rotation % 2 ? 1080 : 2400 };
  Object.assign(h, { pendingHost: host(), sessionId: 7, explicitPhoneSessionId: 7,
    explicitPhoneCapabilities: 31, connected: true, rustdeskControlMode: 0, rustdeskTouchpadSpeed: 1,
    rustdeskRemoteAppTouchScaleEnabled: true, phonePanStarted: false, phonePanOwner: null,
    phoneAxisPinching: false, phoneAxisPinchScale: 1, canvasTransformInitialized: true,
    canvasTransform: {scale:1, panX:0, panY:0, rotation:0}, allowed: true, localZooms: 0,
    phoneActions: {cancel() {}}, currentExplicitPhoneOwner: () => ({...owner}),
    currentProtocolName: () => h.pendingHost.protocol,
    canForwardInput: () => h.allowed, currentRemoteSurfaceTransform: () => transform,
    mapInputPointWithTransform: (x,y,t) => geometry.surfacePointToRemote(t,x,y),
    canvasGestureZoomEnabledForCurrentProtocol: () => true,
    currentCanvasViewport: () => ({surfaceWidth: transform.surfaceWidthPx, surfaceHeight: transform.surfaceHeightPx, sourceWidth:1080, sourceHeight:2400}),
    captureCanvasGestureDensity() {}, canvasGestureVpToPx: x => x,
    refreshCanvasTransformModified() {}, applyCanvasTransform() { ++h.localZooms; },
    loader: {rustDeskPhoneControl(o, op, x=0, y=0) {
      events.push([op,x,y]); if (!h.allowed || o.streamEpoch !== owner.streamEpoch) return 0;
      accepted.push([op,x,y]); return 1;
    }}
  });
  function axis(action, dx=0, dy=0, scale=1) {
    h.handleExplicitPhoneAxis({action, x: transform.surfaceWidthVp/2, y: transform.surfaceHeightVp/2,
      getHorizontalAxisValue: () => dx, getVerticalAxisValue: () => dy,
      hasAxis: () => scale !== 1, getPinchAxisScaleValue: () => scale});
  }
  return { h, events, accepted, owner, axis };
}
test('explicit session remains fixed while pending host metadata changes', () => {
  const f = page(); f.h.pendingHost.rustdeskTargetDevice = 'computer';
  assert.equal(f.h.currentControlMode(), 1);
  f.h.sessionId = 10; assert.equal(f.h.currentControlMode(), 0);
});
test('non-target Android, desktop RustDesk and other protocols preserve effective mode and zoom', () => {
  for (const protocol of ['rustdesk','rdp','vnc','ssh','moonlight']) {
    const f = page(); f.h.explicitPhoneSessionId = 0; f.h.pendingHost.protocol = protocol;
    f.h.rdpControlMode = 2; f.h.vncControlMode = 2; f.h.rustdeskControlMode = 2;
    assert(!f.h.isExplicitPhoneSession());
    f.axis(AxisAction.BEGIN); f.axis(AxisAction.UPDATE,0,20); assert.deepEqual(f.events, []);
    assert.equal(f.h.shouldUseRustDeskRemoteAppTouchScale(), protocol === 'rustdesk');
  }
  const f = page(); assert.equal(f.h.shouldUseRustDeskRemoteAppTouchScale(), false);
});
test('phone physical touchpad routing does not require changing the saved keyboard mode', () => {
  const f = page(); f.h.isDesktopDevice = false;
  assert(f.h.isRustDeskPhysicalTouchpadAxis({sourceTool: SourceTool.TOUCHPAD}));
  assert(!f.h.isRustDeskPhysicalTouchpadAxis({sourceTool: SourceTool.MOUSE}));
});
test('phone pan starts only after motion; endpoint delta matches Android subtraction', () => {
  const f = page(); f.axis(AxisAction.BEGIN); assert.deepEqual(f.events, []);
  f.axis(AxisAction.UPDATE,0,20); f.axis(AxisAction.END);
  assert.deepEqual(f.accepted, [[10,540,1200],[11,0,20],[12,540,1180]]);
  assert.equal(f.h.phonePanOwner, null);
});
test('canvas rotation transforms phone pan vectors without global wheel inversion', () => {
  const expected = [[20,0],[0,-20],[-20,0],[0,20]];
  for (let rotation=0; rotation<4; rotation++) {
    const f = page(rotation); f.axis(AxisAction.BEGIN); f.axis(AxisAction.UPDATE,20,0);
    assert.deepEqual(f.accepted[1], [11,...expected[rotation]]); f.axis(AxisAction.CANCEL);
  }
});
test('physical pinch changes only local canvas; no desktop shortcut, TouchScale or false tap', () => {
  const f = page(); f.axis(AxisAction.BEGIN); f.axis(AxisAction.UPDATE,15,10,1.2);
  assert.equal(f.h.localZooms, 1); assert.equal(f.h.canvasTransform.scale, 1.2);
  assert.deepEqual(f.accepted, []); f.axis(AxisAction.END); assert.deepEqual(f.accepted, []);
  const pan = page(); pan.axis(AxisAction.BEGIN); pan.axis(AxisAction.UPDATE,0,20);
  pan.axis(AxisAction.UPDATE,0,20,1.2); pan.axis(AxisAction.UPDATE,0,20,1.3); pan.axis(AxisAction.END);
  assert.deepEqual(pan.accepted.map(x=>x[0]), [10,11,12]);
});
test('unknown peer, permission loss, cancel and transport replacement clear phone gesture locally', () => {
  const unknown = page(); unknown.h.explicitPhoneCapabilities = 1;
  unknown.axis(AxisAction.BEGIN); unknown.axis(AxisAction.UPDATE,0,20); assert.deepEqual(unknown.accepted, []);
  for (const terminal of ['permission','epoch','cancel']) {
    const f = page(); f.axis(AxisAction.BEGIN); f.axis(AxisAction.UPDATE,0,20);
    if (terminal === 'permission') f.h.allowed = false;
    if (terminal === 'epoch') f.owner.streamEpoch++;
    f.axis(terminal === 'cancel' ? AxisAction.CANCEL : AxisAction.UPDATE,0,20);
    assert.equal(f.h.phonePanOwner, null); assert.equal(f.h.phonePanStarted, false);
    assert.equal(f.accepted.length, terminal === 'cancel' ? 3 : 2);
  }
});
console.log('RustDesk explicit-phone host tests passed: ' + count);
