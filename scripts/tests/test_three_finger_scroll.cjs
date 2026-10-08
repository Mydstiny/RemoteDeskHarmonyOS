'use strict';
/*
 * 三指滚动 (2026-10-07): with 双指缩放 on, two fingers only zoom and pan (a scroll whose fingers drift apart used to
 * become a zoom halfway); scrolling is three fingers up or down in every touch mode; the three-finger tap no longer
 * opens the control panel; a one-time notice says so; the RDP, RustDesk and VNC session controls carry the wheel
 * direction and speed.
 */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.AI_TYPESCRIPT_PATH || 'typescript');

const ETS = path.resolve(__dirname, '../../entry/src/main/ets');
const read = (file) => fs.readFileSync(path.join(ETS, file), 'utf8');
function load(file, cache = new Map()) {
  if (cache.has(file)) { return cache.get(file).exports; }
  const output = ts.transpileModule(read(file + '.ets'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  cache.set(file, module);
  const req = (name) => {
    const child = path.posix.normalize(path.posix.join(path.posix.dirname(file), name));
    if (name.startsWith('@') || !fs.existsSync(path.join(ETS, child + '.ets'))) { return {}; }
    return load(child, cache);
  };
  vm.runInNewContext(output, { module, exports: module.exports, require: req, Math, Number, String, JSON, Set, Map,
    Array, Object, Error }, { filename: file });
  return module.exports;
}
let passed = 0;
function check(name, run) { run(); passed++; console.log('PASS ' + name); }

const gesture = load('services/RemoteCanvasGesturePolicy');
function slide(zoomEnabled, canPan, spanDrift = 0) {
  let state = gesture.beginCanvasTwoFingerCandidate(1, 100, 100, 0, zoomEnabled, canPan, 80);
  const actions = [];
  for (let i = 1; i <= 8; i++) {
    const r = gesture.advanceCanvasTwoFingerMove(state, 100, 100 + i * 4, 0, false, 80 + (i * spanDrift) / 8);
    state = r.state; actions.push(r.action);
  }
  return { state, actions };
}

check('zoom off: a two-finger slide still scrolls the remote', () => {
  const { state, actions } = slide(false, false);
  assert.equal(state.owner, 'touchpad-scroll');
  assert.ok(actions.includes('scroll'));
  assert.equal(gesture.shouldSendCanvasTwoFingerScroll(state), true);
});

check('zoom on: a two-finger slide never scrolls, and the span may still claim the zoom', () => {
  const { state, actions } = slide(true, false);
  assert.equal(state.owner, 'candidate');
  assert.equal(actions.includes('scroll'), false);
  assert.equal(state.moved, true);
  const pinched = gesture.advanceCanvasTwoFingerMove(state, 100, 132, 0, false, 120);
  assert.equal(pinched.state.owner, 'canvas-pinch');
});

check('zoom on: a slid two-finger stroke is no right-click; an unmoved one still is', () => {
  const { state } = slide(true, false);
  assert.equal(gesture.shouldPreserveCanvasTwoFingerRightClick(state), false);
  const tap = gesture.beginCanvasTwoFingerCandidate(1, 100, 100, 0, true, false, 80);
  assert.equal(gesture.shouldPreserveCanvasTwoFingerRightClick(tap), true);
  assert.equal(gesture.finishCanvasTwoFingerCandidate(tap, false).owner, 'touchpad-right-click');
});

check('zoomed in: two fingers pan the picture as before', () => {
  const { state, actions } = slide(true, true);
  assert.equal(state.owner, 'canvas-pan');
  assert.ok(actions.includes('pan'));
});

const page = read('pages/RemoteDesktop.ets');
function body(name) {
  const start = page.indexOf('  private ' + name);
  assert.ok(start >= 0, name);
  return page.slice(start, page.indexOf('\n  }', start) + 4);
}

check('three fingers scroll in every touch mode and the tap opens nothing', () => {
  assert.equal(page.includes('finishThreeFingerPanel'), false);
  const scroll = body('handleThreeFingerScrollMove');
  // A count change re-anchors (never scrolls by the centroid jump); fewer than three fingers never scroll.
  assert.match(scroll, /if \(count < 3 \|\| centroid === null\) \{\s*this\.threeFingerScrollCount = count;\s*return;/);
  assert.match(scroll, /if \(count !== this\.threeFingerScrollCount\) \{[\s\S]*?return;\s*\}/);
  assert.match(scroll, /shouldForwardContinuousRemoteWheelSample\(stepDy\)\) \{\s*this\.touchMoved = true;\s*this\.sendTouchPadWheel\(stepDy\);/);
  // 触控板 and 直接触控 route three-finger moves there; 键鼠 hands them to the touchpad handler.
  const touchpad = page.slice(page.indexOf('  private handleTouchPadInput'), page.indexOf('  private handleXComponentTouch'));
  assert.match(touchpad, /if \(this\.touchMaxFingers >= 3\) \{\s*this\.handleThreeFingerScrollMove\(event\);\s*return;/);
  const direct = page.slice(page.indexOf('  private handleXComponentTouch'), page.indexOf('  private handleConfiguredTouchInput'));
  assert.match(direct, /if \(this\.touchMaxFingers >= 3\) \{\s*this\.handleThreeFingerScrollMove\(event\);\s*return;/);
  const configured = page.slice(page.indexOf('  private handleConfiguredTouchInput'), page.indexOf('  // T-171-PH4'));
  assert.match(configured, /touchMaxFingers >= 3\) \{\s*\/\/[^\n]*\n\s*this\.handleTouchPadInput\(event\);/);
  assert.match(body('resetTouchGesture'), /this\.threeFingerScrollCount = 0;/);
  // Nothing toggles the control panel from a touch any more.
  assert.equal(/showControlPanel = !this\.showControlPanel/.test(page), false);
});

check('Moonlight: three fingers scroll the stream too', () => {
  const moonlight = read('pages/MoonlightStreamPage.ets');
  assert.match(moonlight, /\} else if \(this\.trackpadVisualTouches\.size >= 3\) \{[\s\S]{0,700}this\.sendTrackpadScroll\(dx, dy\);/);
});

const guides = load('services/RemoteVirtualTouchpadGuidePolicy');
const visibility = load('services/GuideVisibilityPolicy');
check('the change notice: once per device, touch modes only, never for a read-only VNC', () => {
  assert.equal(visibility.isAutomaticGuideMarkerKey(visibility.REMOTE_TOUCH_GESTURE_NOTICE_STORAGE_KEY), true);
  for (const protocol of ['rdp', 'rustdesk', 'vnc']) {
    assert.equal(guides.shouldShowRemoteTouchGestureNotice(protocol, true, 0, false, false, false), true);
    assert.equal(guides.shouldShowRemoteTouchGestureNotice(protocol, true, 1, false, false, false), true);
    assert.equal(guides.shouldShowRemoteTouchGestureNotice(protocol, true, 2, false, false, false), false);
    assert.equal(guides.shouldShowRemoteTouchGestureNotice(protocol, true, 0, false, false, true), false);
    assert.equal(guides.shouldShowRemoteTouchGestureNotice(protocol, true, 0, true, false, false), false);
    assert.equal(guides.shouldShowRemoteTouchGestureNotice(protocol, false, 0, false, false, false), false);
    const notice = guides.remoteTouchGestureNotice(protocol);
    assert.match(notice.message, /三指上下滑动/);
    assert.match(notice.message, /三指轻点不再打开控制面板/);
    assert.match(guides.remoteVirtualTouchpadKeyboardGuide(protocol).message, /三指上下滑动滚动/);
    assert.equal(/三指轻点打开/.test(guides.remoteVirtualTouchpadKeyboardGuide(protocol).message), false);
  }
  assert.equal(guides.shouldShowRemoteTouchGestureNotice('vnc', true, 0, false, true, false), false);
  assert.equal(guides.shouldShowRemoteTouchGestureNotice('ssh', true, 0, false, false, false), false);
  assert.match(guides.remoteTouchGestureNotice('rdp').message, /控制中心/);
  assert.match(guides.remoteTouchGestureNotice('rustdesk').message, /鼠标与触控/);
  assert.match(guides.remoteTouchGestureNotice('vnc').message, /「滚轮」/);
  // Shown after the first-run guide check; the first-run guide marks it shown (it already lists the gestures).
  const prompt = body('promptVirtualTouchpadKeyboardGuide');
  assert.match(prompt, /this\.promptRemoteTouchGestureNotice\(protocol\);\s*return;/);
  assert.match(prompt, /guideVisibility\.markShown\([\s\S]{0,80}REMOTE_TOUCH_GESTURE_NOTICE_STORAGE_KEY\)/);
});

const wheel = load('services/RemoteWheelPreferencePolicy');
check('session wheel controls: RDP control centre, RustDesk 鼠标与触控, VNC rail 滚轮', () => {
  assert.deepEqual(Array.from(wheel.remoteWheelSessionSpeedChoices('rdp')), [50, 75, 100, 150, 200, 300, 400]);
  assert.deepEqual(Array.from(wheel.remoteWheelSessionSpeedChoices('vnc')), [50, 100, 150, 200, 400, 600, 1000]);
  for (const protocol of ['rdp', 'rustdesk', 'vnc']) {
    for (const speed of wheel.remoteWheelSessionSpeedChoices(protocol)) {
      assert.equal(wheel.normalizeRemoteWheelSpeed(speed, protocol), speed);
    }
  }
  const setter = body('setCurrentProtocolWheelSpeed');
  assert.match(setter, /this\.persistSessionPref\(key, value\);/);
  assert.match(page, /onWheelSpeed: \(speed: number\): void => \{ this\.setCurrentProtocolWheelSpeed\(speed\); \}/);
  assert.match(page, /wheelSpeed: this\.rdpWheelSpeed,/);
  assert.match(page, /onSetWheelSpeed: \(speed: number\): void => \{\s*this\.setCurrentProtocolWheelSpeed\(speed\);/);
  assert.match(page, /wheelSpeed: this\.wheelSpeedForCurrentProtocol\(\),/);
  assert.match(page, /onOpenWheel: \(\): void => \{\s*this\.markVncToolbarInteraction\(\);\s*this\.showVncWheelSheet = true;/);
  assert.match(page, /RemoteSessionWheelPanel\(\{[\s\S]{0,400}onSpeed: \(speed: number\): void => \{ this\.setCurrentProtocolWheelSpeed\(speed\); \}/);
  assert.match(read('components/rdp/RdpControlCenter.ets'), /this\.wheelSpeedRow\(\)/);
  const bar = read('components/RemoteSessionTopBar.ets');
  assert.match(bar, /this\.subMenuItem\('滚轮速度'[\s\S]{0,200}'wheelSpeed'\)/);
  assert.match(bar, /this\.actions\.onSetWheelSpeed\(speed\);/);
  const vnc = load('services/VncSessionUiPolicy');
  assert.deepEqual(Array.from(vnc.vncToolbarPrimaryActionIds()),
    ['keyboard', 'controlMode', 'wheel', 'shortcuts', 'displayScale', 'diagnostics', 'disconnect']);
  assert.deepEqual(Array.from(vnc.vncToolbarPrimaryActionIds(2)).slice(0, 5),
    ['keyboard', 'controlMode', 'wheel', 'shortcuts', 'display']);
  assert.match(read('components/VncSessionToolbar.ets'), /actionId === 'wheel'[\s\S]{0,200}this\.actions\.onOpenWheel\(\)/);
});

console.log('PASS ' + passed + ' three-finger scroll checks');
