'use strict';
/*
 * RustDesk 连接中「显示」菜单 (2026-10-07): privacy mode really reaches modern peers (Misc.toggle_privacy_mode — they
 * ignore the login option), remote audio and codec change live, a Windows peer's virtual displays can be plugged in
 * and out, and the peer's answers come back to the user.
 */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.AI_TYPESCRIPT_PATH || 'typescript');

const ROOT = path.resolve(__dirname, '../..');
const ETS = path.join(ROOT, 'entry/src/main/ets');
const read = (file) => fs.readFileSync(path.join(ETS, file), 'utf8');
const readRoot = (file) => fs.readFileSync(path.join(ROOT, file), 'utf8');
function load(file) {
  const output = ts.transpileModule(read(file + '.ets'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(output, { module, exports: module.exports, require: () => ({}), Math, Number, String, JSON },
    { filename: file });
  return module.exports;
}
let passed = 0;
function check(name, run) { run(); passed++; console.log('PASS ' + name); }

check('the peer answers to a privacy-mode request are shown in plain words', () => {
  const p = load('services/RustDeskLiveOptionsPolicy');
  assert.match(p.rustDeskPrivacyStateMessage(4), /已开启/);
  assert.match(p.rustDeskPrivacyStateMessage(3), /不支持/);
  assert.match(p.rustDeskPrivacyStateMessage(5), /没有允许/);
  assert.equal(p.rustDeskPrivacyStateMessage(0), '');
  assert.equal(p.rustDeskPrivacyStateOn(4), true);
  assert.equal(p.rustDeskPrivacyStateOn(8), false);
  assert.equal(p.rustDeskCodecName(5), 'H265');
  assert.equal(p.rustDeskLiveAudioPossible(true, false), false, 'no local player: audio comes back after reconnecting');
  assert.equal(p.rustDeskLiveAudioPossible(false, false), true, 'muting always works live');
});

check('the Rust core asks for privacy mode the way modern peers act on, and adopts live options', () => {
  const connector = readRoot('rustdesk_ffi/src/connector.rs');
  assert.match(connector, /if privacy_mode && !privacy_impl_key\.is_empty\(\) \{[\s\S]{0,500}build_toggle_privacy_mode_message\(&impl_key, true\)/,
    'after login, privacy mode is requested with Misc.toggle_privacy_mode, only from peers that list an implementation');
  assert.match(connector, /Misc_oneof_union::back_notification\(ref note\)[\s\S]{0,300}display\.privacy_state = value;/);
  assert.match(connector, /if live_options\.pending \{[\s\S]{0,400}preferred_codec = live_options\.codec;\s*audio_enabled = live_options\.audio_enabled;/,
    'the loop adopts the live codec and audio so pressure resends keep them');
  assert.match(connector, /Misc_oneof_union::toggle_virtual_display\(toggle\)/);
  // A display update (no version) merges only the virtual-display keys and does not replace the login PeerInfo.
  assert.match(connector, /let full = !info\.get_version\(\)\.is_empty\(\) \|\| !info\.get_platform\(\)\.is_empty\(\);\s*crate::adopt_platform_additions\(state, info\.get_platform_additions\(\), full\);/);
  assert.match(connector, /if !info\.get_version\(\)\.is_empty\(\) \|\| !info\.get_platform\(\)\.is_empty\(\) \{\s*controls\.file_clipboard\.update_peer\(info\);/);
  // The live send carries the codec: no reassertion that would resend the configured fps.
  assert.match(connector, /audio_enabled = live_options\.audio_enabled;[\s\S]{0,200}stream_options_reasserted = true;/);
  const lib = readRoot('rustdesk_ffi/src/lib.rs');
  for (const fn of ['rustdesk_get_peer_features', 'rustdesk_toggle_privacy_mode', 'rustdesk_toggle_virtual_display',
    'rustdesk_set_stream_options']) {
    assert.ok(lib.includes('pub extern "C" fn ' + fn + '('), fn);
  }
});

check('the native bridge, NAPI and ExtensionLoader expose the live controls and the peer features', () => {
  const bridge = readRoot('entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp');
  assert.ok(bridge.includes('static_assert(sizeof(RustDeskFfiPeerFeatures) == 48'));
  assert.ok(bridge.includes('result.virtualDisplayImpl = peerFeatures.iddImpl;'));
  const napi = readRoot('entry/src/main/cpp/extensions/extension_loader_napi.cpp');
  for (const name of ['toggleRustDeskPrivacyMode', 'toggleRustDeskVirtualDisplay', 'setRustDeskStreamOptions']) {
    assert.ok(napi.includes('napi_set_named_property(env, exports, "' + name + '", fn);'), name);
    assert.ok(read('services/ExtensionLoader.ets').includes(name + '('), name);
  }
  assert.ok(napi.includes('SetObjectInt32(env, result, "privacyState", nativeStats.privacyState);'));
});

check('the 显示 menu: virtual displays for Windows peers, privacy / audio / codec live', () => {
  const bar = read('components/RemoteSessionTopBar.ets');
  assert.ok(!bar.includes('重连生效'), 'no option claims to need a reconnect any more');
  assert.ok(bar.includes("if (this.virtualDisplayImpl > 0) {\n        this.subMenuItem('虚拟显示器'"));
  assert.ok(bar.includes("this.actions.onToggleRustDeskVirtualDisplay(-1, false);"), '拔出全部');
  assert.ok(bar.includes("case 'session.codec': actions.onSetRustDeskCodec((s.codec + 1) % 6); return true;"));
  const page = read('pages/RemoteDesktop.ets');
  assert.ok(page.includes('this.loader.toggleRustDeskPrivacyMode(this.sessionId, on)'));
  assert.ok(page.includes('this.loader.setRustDeskStreamOptions(this.sessionId, next, this.rustDeskLiveAudio())'));
  assert.ok(page.includes('this.adoptRustDeskPeerFeatures(snapshot);'));
  assert.ok(page.includes('if (sessionId !== this.rustDeskFeaturesSessionId) {'), 'answers are announced once per session');
  assert.ok(page.includes('privacyMode: this.rustDeskPrivacyShown(),'), 'the menu tick follows the peer answer');
  assert.ok(page.includes('return RUSTDESK_SESSIONS_STARTED_WITH_AUDIO.get(this.sessionId) === true;'));
  assert.ok(page.includes('virtualDisplayImpl: this.rustDeskVirtualDisplayImpl,'));
  const policy = read('services/RemoteSessionTopBarPolicy.ets');
  assert.ok(policy.includes("'virtualDisplay': '虚拟显示器只支持已安装 RustDesk 且带虚拟显示驱动的 Windows 被控端'"));
  assert.ok(read('services/diagnosticAi/DiagnosticAiKnowledgeBase.ets').includes('RustDesk 连接中的「显示」菜单'));
});

console.log('rustdesk live options: ' + passed + ' checks passed');
