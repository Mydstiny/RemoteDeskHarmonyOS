'use strict';
/*
 * 多个画面会话同时存在 (2026-10-08): native media sinks keep one slot per picture session, every RDP/VNC/RustDesk
 * connection gets its own adapter, RDP sound is routed per connection, a second page renders to its own XComponent
 * surface and never touches the process one, sound follows the focused window, and the device caps how many picture
 * sessions may be open (PC 4, tablet 2, phone 1).
 */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.AI_TYPESCRIPT_PATH || 'typescript');

const ROOT = path.resolve(__dirname, '../..');
const ETS = path.join(ROOT, 'entry/src/main/ets');
const CPP = path.join(ROOT, 'entry/src/main/cpp');
const read = (file) => fs.readFileSync(path.join(ETS, file), 'utf8');
const readCpp = (file) => fs.readFileSync(path.join(CPP, file), 'utf8');
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
function methodBody(source, signature, last = false) {
  const start = last ? source.lastIndexOf(signature) : source.indexOf(signature);
  assert.ok(start >= 0, signature);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
}
let passed = 0;
function check(name, run) { run(); passed++; console.log('PASS ' + name); }

const surface = load('services/RemotePictureSurfacePolicy');
check('the first picture page uses the process surface; a page opened while it lives uses its own', () => {
  assert.equal(surface.pictureSurfaceModeForClaim(0, 7), 'process');
  assert.equal(surface.pictureSurfaceModeForClaim(7, 7), 'process');
  assert.equal(surface.pictureSurfaceModeForClaim(7, 8), 'own');
  // Page tokens are unique across windows (page numbers repeat per window), positive and safe integers.
  const a = surface.pictureSurfaceClaimToken(1791443339084, 0.5);
  const b = surface.pictureSurfaceClaimToken(1791443339084, 0.501);
  assert.ok(a > 0 && Number.isSafeInteger(a) && a !== b);
  assert.ok(Number.isSafeInteger(surface.pictureSurfaceClaimToken(Date.now(), 0.9999)));
  assert.equal(surface.rendererNeedsOwnSurfaceId(true, 'process'), true);
  assert.equal(surface.rendererNeedsOwnSurfaceId(false, 'own'), true);
  assert.equal(surface.rendererNeedsOwnSurfaceId(false, 'process'), false);
  assert.equal(surface.rendererNeedsOwnSurfaceId(false, 'unset'), false);
});

const limit = load('services/RemotePictureSessionLimitPolicy');
check('picture session limit: PC 4, tablet 2, phone 1; one-session phones keep the old wording', () => {
  assert.equal(limit.remotePictureSessionLimit('2in1'), 4);
  assert.equal(limit.remotePictureSessionLimit('pc'), 4);
  assert.equal(limit.remotePictureSessionLimit('tablet'), 2);
  assert.equal(limit.remotePictureSessionLimit('phone'), 1);
  assert.equal(limit.remotePictureSessionLimit(''), 1);
  assert.equal(limit.remotePictureSessionAllowed(3, 4), true);
  assert.equal(limit.remotePictureSessionAllowed(4, 4), false);
  assert.equal(limit.remotePictureSessionAllowed(1, 2), true);
  assert.equal(limit.remotePictureSessionAllowed(2, 2), false);
  assert.equal(limit.remotePictureSessionAllowed(0, 1), true);
  assert.equal(limit.remotePictureSessionAllowed(1, 1), false);
  assert.deepEqual(['rdp', 'rustdesk', 'vnc', 'ssh', 'moonlight'].map(limit.isRemotePictureProtocolName),
    [true, true, true, false, false]);
  assert.match(limit.remotePictureSessionLimitMessage(4, null, 'h', ''), /最多 4 个。请先关闭一个再连接/);
  assert.match(limit.remotePictureSessionLimitMessage(2, null, 'h', ''), /最多 2 个/);
  assert.match(limit.remotePictureSessionLimitMessage(1, null, 'h', ''), /同一时间只能打开一个/);
  assert.equal(limit.REMOTE_PICTURE_SESSION_LIMIT_CODE, -91);
});

const loader = read('services/ExtensionLoader.ets');
check('ExtensionLoader: the limit is checked before any native connection; media calls name the session', () => {
  const connect = methodBody(loader, '  connect(config: SessionConfig): number {');
  assert.ok(connect.indexOf('remotePictureSessionAllowed(this.livePictureSessionCount()') <
    connect.indexOf('rdpnapi.connect(config)'));
  assert.match(connect, /return REMOTE_PICTURE_SESSION_LIMIT_CODE;/);
  assert.match(loader, /return this\.currentSessionId > 0 \? this\.currentSessionId : -1;/);
  assert.match(loader, /rdpnapi\.initRenderer\(xcId, w, h, ownerSessionId\)/);
  assert.match(loader, /w, h, c, rendererHandle, desktopSurfaceCompatibility, ownerSessionId\) as number/);
  assert.match(loader, /rdpnapi\.rebindActiveVideoPipeline\(this\.nativeOwnerSessionArg\(\)\)/);
  assert.match(loader, /rdpnapi\.requestFrameRefresh\(this\.nativeOwnerSessionArg\(\)\)/);
  assert.match(loader, /sr \?\? 48000, ch \?\? 2, this\.nativeOwnerSessionArg\(\)\)/);
  assert.match(loader, /rdpnapi\.setActiveAudioMute\(mute, this\.nativeOwnerSessionArg\(\)\)/);
  assert.match(loader, /rdpnapi\.isAudioPlaybackActive\(this\.nativeOwnerSessionArg\(\)\)/);
  assert.match(loader, /rdpnapi\.setAudioFocusSession\(sessionId > 0 \? sessionId : 0\)/);
  const reattach = methodBody(loader, '  reattachRenderForForeground(');
  assert.match(reattach, /if \(!bindProcessSurface && !\/\^\[0-9\]\+\$\/\.test\(surfaceId\.trim\(\)\)\)/);
  assert.match(reattach, /if \(bindProcessSurface\) \{\s*const surfaceBound = rdpnapi\.setXComponentSurfaceId/);
  for (const dts of [read('types/rdpnapi.d.ts'), readCpp('types/librdpnapi/index.d.ts')]) {
    assert.match(dts, /initRenderer\(xcId: string, width: number, height: number, ownerSessionId\?: number\)/);
    assert.match(dts, /export function setAudioFocusSession\(sessionId: number\): void;/);
    assert.match(dts, /export function markRendererSurfaceDestroyed\(handle: number\): void;/);
    assert.match(dts, /export function getLivePictureSessionCount\(\): number;/);
  }
});

const page = read('pages/RemoteDesktop.ets');
check('RemoteDesktop: a page on its own surface never binds or detaches the process surface', () => {
  // The page's own handler (the XComponent controller classes above it share the name).
  const created = methodBody(page, '  onSurfaceCreated(surfaceId: string): void {', true);
  assert.ok(created.indexOf('if (this.usesOwnPictureSurface()) {') <
    created.indexOf('rdpnapi.setXComponentSurfaceId('));
  const detached = methodBody(page, '  private markXComponentSurfaceDetached(source: string): void {');
  assert.ok(detached.indexOf("this.pictureSurfaceMode !== 'process'") < detached.indexOf('markXComponentSurfaceDestroyed()'));
  assert.ok(detached.indexOf('this.loader.markRendererSurfaceDestroyed(this.rendererHandle);') <
    detached.indexOf("this.pictureSurfaceMode !== 'process'"));
  assert.match(page, /if \(!ownPictureSurface && this\.latestSurfaceId\.trim\(\)\.length > 0\) \{/);
  assert.match(page, /rendererOnOwnSurfaceId && this\.latestSurfaceId\.trim\(\)\.length > 0 \? this\.latestSurfaceId\.trim\(\) : this\.xcId;\s*const rHandle: number = this\.loader\.initRenderer\(\s*rendererSurface, pageSurface\.width, pageSurface\.height, -1\);/);
  assert.equal((page.match(/this\.sessionId, !this\.usesOwnPictureSurface\(\)\);/g) || []).length, 2);
  assert.match(page, /this\.sessionId,\s*!this\.usesOwnPictureSurface\(\)\);/);
  assert.match(page, /this\.usesOwnPictureSurface\(\) \|\| rdpnapi\.setXComponentSurfaceId\(/);
  assert.match(methodBody(page, '  aboutToDisappear(): void {'), /this\.loader\.releaseProcessSurface\(this\.pictureSurfaceToken\);/);
  // The holder is process-wide (native): every session window has its own ArkTS module instances.
  assert.match(page, /this\.pictureSurfaceMode = this\.loader\.claimProcessSurface\(this\.pictureSurfaceToken\) \? 'process' : 'own';/);
  const gl = readCpp('render/gl_renderer.cpp');
  assert.match(gl, /napi_value NapiClaimProcessSurface\(/);
  assert.match(gl, /if \(token > 0 && \(g_processSurfaceHolder <= 0 \|\| g_processSurfaceHolder == token\)\) \{/);
  // A resized window's buffers follow the rendered size (a split window going full screen was stretched).
  assert.match(gl, /CommitRendererResizeGeometry\(\s*width_, height_, width, height\)\) \{\s*return false;\s*\}\s*\/\/[^\n]*\n[^\n]*\n\s*ApplyBufferGeometryLocked\(width_, height_\);/);
  assert.match(gl, /OH_NativeWindow_NativeWindowHandleOpt\(\s*static_cast<OHNativeWindow\*>\(eglNativeWindow_\), SET_BUFFER_GEOMETRY, width, height\);/);
});

check('RemoteDesktop: sound follows the focused window; limit errors are explained', () => {
  assert.match(page, /this\.sessionId = sid;\s*this\.claimAudioFocus\('connect'\);/);
  assert.match(page, /this\.restartClipboardBridgeIfActiveForeground\(\);\s*this\.claimAudioFocus\('window-active'\);/);
  assert.match(page, /this\.claimAudioFocus\('restore'\);/);
  assert.match(page, /if \(sid === REMOTE_PICTURE_SESSION_LIMIT_CODE\) \{\s*errMsg = remotePictureSessionLimitMessage\(/);
  assert.match(read('pages/HostListPage.ets'), /this\.videoSessionBusyMessage\(host\.id, sid\)/);
});

const ext = readCpp('extensions/extension_loader_napi.cpp');
check('native: every picture connection gets its own adapter; teardown and input never pick another session', () => {
  const factory = ext.slice(ext.indexOf('static std::shared_ptr<ProtocolAdapter> CreateAdapterForSession('),
    ext.indexOf('static void SetObjectString('));
  for (const made of ['std::make_shared<SshAdapter>()', 'std::make_shared<FreeRdpAdapter>()',
    'std::make_shared<VncAdapter>()', 'std::make_shared<RustDeskBridge>(RustDeskMode::FFI)']) {
    assert.ok(factory.includes(made), made);
  }
  assert.match(ext, /static std::vector<LiveConnection> g_liveConnections;/);
  const deactivate = ext.slice(ext.indexOf('static bool DeactivateSessionContextIfActive('),
    ext.indexOf('static void DeactivateAllSessionContexts()'));
  assert.match(deactivate, /EraseLiveConnectionLocked\(owner\.sessionId\);\s*PublishLatestLiveConnectionLocked\(\);/);
  assert.match(ext, /resources\.owner = Render::SharedSessionSinkOwnerLease\(\)\.ownerForSession\(\s*static_cast<uint64_t>\(sessionId\)\);/);
  assert.match(ext, /resources\.owner = DecoderNapi::BoundOwnerForDecoderHandle\(resources\.decoderHandle\);/);
  assert.match(ext, /Render::SharedSessionSinkOwnerLease\(\)\.ownerForSession\(identity\.sessionId\);/);
  assert.match(ext, /static napi_value NapiGetLivePictureSessionCount\(/);
  const refresh = ext.slice(ext.indexOf('napi_value NapiRequestFrameRefresh('));
  assert.ok(refresh.indexOf('g_sessionRegistry.find(sessionId)') < refresh.indexOf('GetActiveSessionAdapter()'));
});

check('native: sinks keep one slot per session; a new generation of a live session is refused', () => {
  const lease = readCpp('render/video_perf_counters.h');
  assert.match(lease, /std::vector<Entry> entries_;/);
  assert.match(lease, /static constexpr size_t kMaxOwners = 8;/);
  assert.match(lease, /hasOtherGenerationLocked\(owner\)/);
  assert.match(lease, /DecoderSessionIdentity ownerForSession\(uint64_t sessionId\) const/);
  const decoder = readCpp('render/hw_decoder.cpp');
  assert.match(decoder, /std::vector<ActiveDecoderSlot> g_activeDecoders;/);
  assert.match(decoder, /\(ownerSessionId < 0 \? DecoderSessionIdentity \{\} : Render::SharedSessionSinkOwnerLease\(\)\.snapshot\(\)\);\s*if \(!requestedOwner\.valid\(\)\) \{/);
  const audio = readCpp('audio/audio_player.cpp');
  assert.match(audio, /static bool AudioFocusAllows\(/);
  assert.match(audio, /Render::DecoderSessionIdentity \{\};/);
});

check('native: RDP sound is routed per connection through the wrapped fake rdpsnd backend', () => {
  const rdp = readCpp('rdp/freerdp_adapter.cpp');
  assert.equal(/g_rdpAudioCallback\b|g_rdpAudioCallbackOwner|g_rdpAudioAdmission/.test(rdp), false);
  assert.match(rdp, /static std::unordered_map<const void\*, RdpAudioRoute> g_rdpAudioRoutes;/);
  assert.match(rdp, /static thread_local rdpContext\* t_rdpsndPlayContext = nullptr;/);
  assert.match(rdp, /freerdp_rdpsnd_get_context\(device->rdpsnd\)/);
  assert.match(rdp, /std::strcmp\(name, RDPSND_CHANNEL_NAME\) == 0 && std::strcmp\(subsystem, "fake"\) == 0/);
  assert.match(rdp, /0, t_rdpsndPlayContext, data, size, sampleRate, channels, bitsPerSample\);/);
  // A connection that is no longer registered plays nowhere, never through another route.
  assert.match(rdp, /if \(it == g_rdpCallbackRegistry\.end\(\) \|\| it->second\.adapter == nullptr\) \{\s*return 0;/);
});

check('native: a renderer on its own surface follows only its own surface state', () => {
  const header = readCpp('render/gl_renderer.h');
  assert.match(header, /bool FollowsProcessSurface\(\) const \{ return usesProcessSurface_ \|\| followsProcessSurface_; \}/);
  const gl = readCpp('render/gl_renderer.cpp');
  assert.match(gl, /followsProcessSurface_ =\s*static_cast<uint64_t>\(parsedSurfaceId\) == g_surfaceId\.load/);
  assert.match(gl, /const bool followsProcessSurface = FollowsProcessSurface\(\);\s*if \(followsProcessSurface && generation != 0 &&/);
  assert.match(gl, /napi_value NapiMarkRendererSurfaceDestroyed\(/);
  assert.match(gl, /"markRendererSurfaceDestroyed"/);
});

check('review fixes: private epochs, owner-named software fallback, exclusive owners, renderer binding', () => {
  const gl = readCpp('render/gl_renderer.cpp');
  // A renderer on its own surface never advances the process epoch another session's renderer depends on.
  assert.match(gl, /static uint64_t NextPresentationGenerationFor\(const RendererContext& ctx\) \{\s*if \(ctx\.renderer && !ctx\.renderer->FollowsProcessSurface\(\)\) \{\s*return NextAuxRendererGeneration\(\);/);
  assert.equal((gl.match(/ctx->generation = NextPresentationGenerationFor\(\*ctx\);/g) || []).length, 4);
  assert.equal(/ctx->generation = AdvanceRendererGeneration\(\);/.test(gl), false);
  const clear = gl.slice(gl.indexOf('void RendererNapi::ClearActiveSessionOwner('),
    gl.indexOf('RdpPresentationMetricsSnapshot RendererNapi::GetActivePresentationStats()'));
  assert.match(clear, /InvalidateRendererPresentationLocked\(handle\);/);
  assert.equal(/AdvanceRendererGeneration\(\)/.test(clear), false);
  const redraw = gl.slice(gl.lastIndexOf('uint64_t RendererNapi::RegisterActiveRedrawCallback('));
  assert.match(redraw, /auto sinkLease = Render::SharedSessionSinkOwnerLease\(\)\.acquire\(owner\);\s*if \(!sinkLease\) \{\s*return 0;/);
  const decoder = readCpp('render/hw_decoder.cpp');
  assert.equal(/RegisterDecoderContext\(/.test(decoder), false);
  assert.match(decoder, /RegisterDecoderContextForOwner\(softwareCtx, requestedOwner\)/);
  assert.match(decoder, /\(sessionId < 0 \? DecoderSessionIdentity \{\} : Render::SharedSessionSinkOwnerLease\(\)\.snapshot\(\)\)/);
  assert.match(ext, /if \(sessionId < 0\) \{\s*activeConnection = nullptr;/);
  // Moonlight and a foreground SSH page keep the single-owner rule.
  assert.match(readCpp('moonlight/media/MoonlightProductSessionMediaPort.cpp'),
    /Render::ActivateSharedSessionSinks\(owner, true\)/);
  assert.match(ext, /const bool exclusive = dynamic_cast<SshAdapter\*>\(adapter\.get\(\)\) != nullptr;\s*if \(!Render::ActivateSharedSessionSinks\(owner, exclusive\)\)/);
  assert.match(readCpp('render/video_perf_counters.h'), /if \(exclusive\) \{\s*return entries_\.empty\(\);/);
  // The page holds its own renderer after connect; a window hand-off gives the process surface to the target.
  assert.match(page, /if \(this\.rendererHandle > 0 && !this\.loader\.bindRendererToSession\(this\.rendererHandle, sid\)\) \{/);
  assert.match(page, /rendererSurface, pageSurface\.width, pageSurface\.height, sid\);\s*if \(ownRenderer <= 0 \|\| !this\.loader\.bindRendererToSession\(ownRenderer, sid\)\) \{/);
  assert.match(page, /if \(!ownPictureSurface && this\.latestSurfaceId\.trim\(\)\.length > 0\) \{\s*rdpnapi\.setXComponentSurfaceId\(this\.latestSurfaceId\.trim\(\), pageSurface\.width, pageSurface\.height\);/);
  assert.equal((page.match(/this\.loader\.releaseProcessSurface\(this\.pictureSurfaceToken\);\s*this\.pictureSurfaceMode = 'own';/g) || []).length, 2);
  assert.match(page, /if \(!this\.pcWindowHandoffComplete\) \{\s*this\.pictureSurfaceMode = 'unset';/);
});

check('an RDP window handed off beside another session admits input on its own window state', () => {
  // The main window goes to the background when the session window takes its split side; the stability gate of the
  // window page must not read the main window's flag (the hand-off then timed out and the session was dropped).
  const gate = methodBody(page, '  private armRdpInputStabilityGate(');
  assert.match(gate, /this\.currentAbilityBackgroundState\(\)\) \{\s*return;\s*\}\s*this\.rdpInputStabilityGateReady = true;/);
  assert.equal(/this\.remoteDesktopBgFlag \|\| this\.sessionWindowBackground/.test(gate), false);
  assert.match(page, /this\.syncHarmonyShortcutCapture\('ability-foreground'\);\s*this\.rearmRdpInputStabilityAfterForeground\(\);/);
});

console.log('PASS ' + passed + ' multi picture session checks');
