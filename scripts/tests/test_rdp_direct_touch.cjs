// Run with RDP_TYPESCRIPT_PATH=<DevEco TypeScript module> node scripts/tests/test_rdp_direct_touch.cjs.
// Execute production page methods; only platform, timers and transport are stubbed.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.RDP_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/RemoteDesktop.ets'), 'utf8');
function method(name) {
  const start = source.indexOf('  private ' + name);
  assert(start >= 0, name);
  const end = source.indexOf('\n  }', start);
  assert(end > start, name);
  return source.slice(start, end + 4);
}
const methods = ['handleXComponentTouch', 'handleConfiguredTouchInput', 'handleXComponentMouse',
  'primaryTouchPoint', 'syncActiveTouchPoints', 'resetTouchGesture',
  'startDirectTouchRightClickTimer', 'clearTouchDirectRightClickTimer'];
const compiled = ts.transpileModule('class Page {\n' + methods.map(method).join('\n') +
  '\n}\nmodule.exports = Page;', { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText;
const TouchType = { Down: 0, Up: 1, Move: 2, Cancel: 3 };
const SourceTool = { Unknown: 0, Finger: 1, Pen: 2, MOUSE: 3, TOUCHPAD: 4 };
function fixture(protocol = 'rdp', scale = 4, mode = 1) {
  let timerId = 0;
  const timers = new Map(), events = [], mouseAdmissions = [];
  const context = { module: { exports: {} }, TouchType, SourceTool,
    TOUCH_CLICK_SLOP_PX: 18, TOUCH_DIRECT_RIGHT_CLICK_MS: 650,
    RD_DOMAIN: 0, RD_TAG: 'test', Date, Math,
    hilog: { info() {}, warn() {}, error(...args) { throw Error(args.join(' ')); } },
    shouldResetRemoteImeOnPointerDown: () => false,
    setTimeout: (fn) => { timers.set(++timerId, fn); return timerId; },
    clearTimeout: (id) => timers.delete(id) };
  vm.runInNewContext(compiled, context);
  const h = new context.module.exports();
  Object.assign(h, {
    // No AI orb on screen: nothing is shielded.
    aiTouchShield: { shields: () => false },
    connected: true, pendingHost: { protocol }, touchFingerCount: 0, touchMaxFingers: 0,
    touchLeftDown: false, touchMoved: false, touchDragActive: false, touchpadPointerDown: false,
    rdpTouchPressX: 0, rdpTouchPressY: 0, remoteCursorX: 0, remoteCursorY: 0,
    touchDirectRightClickTimer: -1, activeTouchPoints: new Map(),
    keyboardOpen: false, pendingMouseMoveValid: false, canvasTwoFingerSuppressedUntilRelease: false,
    canForwardInput: (kind) => {
      if (kind === 'mouse') { mouseAdmissions.push(kind); return false; }
      return true;
    },
    isRdpRemoteSession: () => protocol === 'rdp', isVncViewOnlySession: () => false,
    isRustDeskPhoneSession: () => protocol === 'rustdesk-phone',
    armRemotePointerFocusRecovery: () => false, currentControlMode: () => mode,
    consumeCanvasPinchTouch: () => false, canUseCanvasTwoFingerGesture: () => false,
    observeCanvasTwoFingerTouch() {}, observeVncExternalInputActivity() {}, hideTouchIndicator() {},
    trackedCanvasTouchCount: () => h.activeTouchPoints.size,
    remainingTouchCountAfterLift: () => h.activeTouchPoints.size,
    averageTouchPoint: (e) => e.touches[0] || e.changedTouches[0],
    mapInputPoint: (x, y) => ({ x: Math.round(x * scale), y: Math.round(y * scale), inside: x >= 0 && y >= 0 }),
    logMappedInput() {}, showRemoteCursorIndicator() {}, clearTouchRightClickTimer() {},
    recoverRemotePointerFocus() {}, resetTouchpadPointerCurve() {}, resetCanvasTwoFingerGesture() {},
    queueMouseMove(x, y, update = true) {
      h.pending = [x, y]; h.pendingMouseMoveValid = true;
      if (update) { h.remoteCursorX = x; h.remoteCursorY = y; }
    },
    flushMouseMove() {
      if (h.pendingMouseMoveValid) events.push(['move', ...h.pending]);
      h.pendingMouseMoveValid = false;
    },
    discardPendingMouseMove() { h.pendingMouseMoveValid = false; },
    sendMouseNow(x, y, button, pressed) {
      events.push([pressed ? 'down' : 'up', x, y, button]);
      h.remoteCursorX = x; h.remoteCursorY = y;
    }
  });
  function touch(type, x = 100, y = 100, tool = SourceTool.Finger) {
    const point = { x, y, id: 1 };
    h.handleConfiguredTouchInput({ type, sourceTool: tool,
      touches: type === TouchType.Up || type === TouchType.Cancel ? [] : [point],
      changedTouches: [point], stopPropagation() {} });
  }
  return { h, events, timers, mouseAdmissions, touch,
    down: (x = 100, y = 100) => touch(TouchType.Down, x, y),
    move: (x, y = 100) => touch(TouchType.Move, x, y),
    up: (x = 100, y = 100) => touch(TouchType.Up, x, y),
    fireTimers() { for (const [id, fn] of [...timers]) { timers.delete(id); fn(); } }
  };
}
let count = 0;
function test(name, body) { body(); count++; console.log('PASS ' + name); }
const buttons = (f) => f.events.filter(e => e[0] !== 'move');
for (const scale of [1, 4]) {
  test('sub-slop jitter remains anchored at scale ' + scale, () => {
    const f = fixture('rdp', scale); f.down(); f.move(103); f.h.flushMouseMove(); f.up(103);
    assert.deepEqual(f.events, [['move', 100 * scale, 100 * scale],
      ['down', 100 * scale, 100 * scale, 0], ['up', 100 * scale, 100 * scale, 0]]);
    assert.equal(f.h.touchLeftDown, false); assert.equal(f.timers.size, 0);
  });
}
test('release-only jitter and exact threshold retain the press target', () => {
  for (const x of [103, 118]) {
    const f = fixture(); f.down(); f.up(x);
    assert.deepEqual(buttons(f).at(-1), ['up', 400, 400, 0]);
  }
});
test('release-only displacement beyond threshold finishes the drag', () => {
  const f = fixture(); f.down(); f.up(120);
  assert.deepEqual(buttons(f).at(-1), ['up', 480, 400, 0]);
});
test('drag sends motion, remains a drag after returning within slop, and cancels long press', () => {
  const f = fixture(); f.down(); f.move(120); f.h.flushMouseMove(); f.move(102); f.up(103);
  assert(f.events.some(e => e[0] === 'move' && e[1] === 480));
  assert.deepEqual(buttons(f).at(-1), ['up', 412, 400, 0]);
  assert.equal(f.h.pendingMouseMoveValid, false); assert.equal(f.timers.size, 0);
});
test('tap cancellation releases at anchor despite unrelated terminal coordinates', () => {
  const f = fixture(); f.down(); f.move(103); f.touch(TouchType.Cancel, 0, 0);
  assert.deepEqual(buttons(f).at(-1), ['up', 400, 400, 0]);
  assert.equal(f.h.pendingMouseMoveValid, false); assert.equal(f.timers.size, 0);
});
test('empty cancel and repeated lifecycle reset release exactly once', () => {
  const f = fixture(); f.down(); f.move(103);
  f.h.handleConfiguredTouchInput({ type: TouchType.Cancel, sourceTool: SourceTool.Finger,
    touches: [], changedTouches: [], stopPropagation() {} });
  f.h.resetTouchGesture();
  assert.deepEqual(buttons(f), [['down', 400, 400, 0], ['up', 400, 400, 0]]);
  assert.equal(f.h.pendingMouseMoveValid, false); assert.equal(f.timers.size, 0);
});
test('mode/lifecycle reset discards pending drag and releases once', () => {
  const f = fixture(); f.down(); f.move(125); f.h.resetTouchGesture(); f.h.flushMouseMove();
  assert.deepEqual(buttons(f), [['down', 400, 400, 0], ['up', 500, 400, 0]]);
  assert.equal(f.events.length, 3); assert.equal(f.timers.size, 0);
});
test('long press keeps right click at anchor and consumes trailing motion/up', () => {
  const f = fixture(); f.down(); f.move(103);
  f.h.remoteCursorX = 900; f.fireTimers(); f.move(120); f.up(120);
  assert.deepEqual(buttons(f), [['down', 400, 400, 0], ['up', 400, 400, 0],
    ['down', 400, 400, 2], ['up', 400, 400, 2]]);
  assert.equal(f.h.pendingMouseMoveValid, false);
});
test('a second finger releases the held left button at its stable target', () => {
  const f = fixture(); f.down(); f.move(103);
  f.h.handleConfiguredTouchInput({ type: TouchType.Down, sourceTool: SourceTool.Finger,
    touches: [{ x: 103, y: 100, id: 1 }, { x: 140, y: 100, id: 2 }],
    changedTouches: [{ x: 140, y: 100, id: 2 }], stopPropagation() {} });
  assert.deepEqual(buttons(f), [['down', 400, 400, 0], ['up', 400, 400, 0]]);
  f.fireTimers(); assert.equal(buttons(f).length, 2);
});
for (const mode of [0, 1, 2]) {
  test('mouse-source touches never enter finger tracking in RDP mode ' + mode, () => {
    const f = fixture('rdp', 4, mode);
    f.touch(TouchType.Down, 100, 100, SourceTool.MOUSE);
    f.touch(TouchType.Up, 100, 100, SourceTool.MOUSE);
    assert.equal(f.events.length, 0); assert.equal(f.h.activeTouchPoints.size, 0);
    assert.equal(f.timers.size, 0);
  });
}
test('finger mouse events are rejected while real mouse/touchpad/unknown reach mouse input gate', () => {
  const f = fixture();
  for (const tool of [SourceTool.Finger, SourceTool.MOUSE, SourceTool.TOUCHPAD, SourceTool.Unknown]) {
    f.h.handleXComponentMouse({ sourceTool: tool });
  }
  assert.equal(f.mouseAdmissions.length, 3);
});
test('synthesized mouse touch cannot reset an active finger sequence', () => {
  const f = fixture(); f.down();
  f.touch(TouchType.Cancel, 0, 0, SourceTool.MOUSE);
  assert.equal(f.h.touchLeftDown, true); assert.equal(f.h.activeTouchPoints.size, 1);
  f.up(); assert.equal(buttons(f).length, 2);
});
for (const protocol of ['vnc', 'rustdesk', 'rustdesk-phone']) {
  test(protocol + ' retains existing immediate direct-touch movement', () => {
    const f = fixture(protocol); f.down(); f.move(103); f.h.flushMouseMove(); f.up(103);
    assert(f.events.some(e => e[0] === 'move' && e[1] === 412));
    assert.deepEqual(buttons(f).at(-1), ['up', 412, 400, 0]);
  });
}
console.log(count + ' RDP direct-touch checks PASS');
