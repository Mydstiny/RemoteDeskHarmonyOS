import { NativeVideoDiagnosticEvidence } from './VideoDiagnosticEvidence';
declare module 'librdpnapi.so' {

  export interface ProFidoNativePoll {
    status: number;
    requestId: number;
    timeoutMs: number;
    write: boolean;
    data: Uint8Array;
  }
  /** Debug-only capability probe. Release returns false/zero/invalid and has no worker. */
  export function proFidoProbeAvailable(): boolean;
  export function proFidoProbeStart(): number;
  export function proFidoProbePoll(operationId: number): ProFidoNativePoll;
  export function proFidoProbeReply(operationId: number, requestId: number, data: Uint8Array, success: boolean): boolean;
  export function proFidoProbeCancel(operationId: number): void;

  /** RDP security-key redirection (MS-RDPEWA) request from the session broker. */
  export interface RdpSecurityKeyRequest {
    id: number;
    /** 1 confirm, 2 select key, 3 PIN, 4 touch prompt, 5 write report, 6 read report, 7 release key,
     *  8 dismiss: id names a prompt that ended unanswered, 9 passkey for the phone */
    kind: number;
    /** Confirm: relying party ID. */
    text: string;
    /** Confirm: 1 register, 2 sign in. Touch: 1 show, 0 hide. */
    operation: number;
    /** PIN: remaining attempts, or -1 when unknown. */
    retries: number;
    timeoutMs: number;
    /** Write: the 64-byte output report. */
    report: Uint8Array;
    /** Passkey (kind 9): the CTAP command byte and CBOR request for the paired phone. */
    payload: Uint8Array;
  }
  /** Debug-only; Release returns false and links no FIDO code. */
  export function rdpSecurityKeyAvailable(): boolean;
  /** Watches a session across reconnects; returns the watch ID, or 0 when the session has no broker. */
  export function rdpSecurityKeyWatch(sessionId: number, onRequest: () => void): number;
  /** True when watchId was still the session's watcher (a newer page may have taken over). */
  export function rdpSecurityKeyUnwatch(sessionId: number, watchId: number): boolean;
  export function rdpSecurityKeyPoll(sessionId: number): RdpSecurityKeyRequest | null;
  export function rdpSecurityKeyRespond(sessionId: number, id: number, ok: boolean,
    report: Uint8Array | null, text: string | null): boolean;
  export function rdpSecurityKeyCancel(sessionId: number): void;
  /** ArkTS released the session's key on its own; the next request asks for a key again. */
  export function rdpSecurityKeyReleased(sessionId: number): void;
  /** Passkey replies carry the phone's CTAP response; Select replies name the authenticator (1 USB key, 2 phone). */
  export function rdpSecurityKeyRespondEx(sessionId: number, id: number, ok: boolean, payload: Uint8Array | null,
    authenticator: number): boolean;

  export interface AiTlsRequestOptions {
    id: string;
    address: string;
    serverName: string;
    port: number;
    ca: string;
    caSha256?: string;
    certificate?: string;
    privateKey?: string;
    path: string;
    body?: string;
    timeoutMs: number;
  }
  export interface AiTlsResponse { status: number; body: ArrayBuffer; }
  export interface AiGeneratedIdentity { csr: string; privateKey: string; }
  export function aiTlsRequest(options: AiTlsRequestOptions, onChunk?: (data: ArrayBuffer) => void): Promise<AiTlsResponse>;
  export function aiGenerateIdentity(request: { id: string }): Promise<AiGeneratedIdentity>;
  export function aiCancelRequest(request: { id: string }): void;
  export const VERSION: SessionVersionInfo;

  export function listProtocols(): ProtocolInfo[];

  export function connect(config: SessionConfig): number;
  /** The native Promise carries the reserved session identity before it settles. */
  export function connectSshAsync(config: SessionConfig, foreground?: boolean): Promise<number> & {
    sessionId: number;
    generation: number;
  };
  export function getPendingSshConnectId(): number;
  export function getPendingSshConnectIds(): number[];
  export function disconnect(sessionId: number, rendererHandle?: number,
    decoderHandle?: number, audioHandle?: number): number;
  export function beginDisconnect(sessionId: number, rendererHandle: number,
    decoderHandle: number, audioHandle: number): number;
  export function getSessionOwnerIdentity(sessionId: number): NativeSessionOwnerIdentity | null;
  export function beginDisconnectWithReceipt(sessionId: number, generation: number,
    ownerToken: number, rendererHandle: number, decoderHandle: number,
    audioHandle: number): NativeDisconnectReceipt;
  export function disconnectAll(rendererHandle?: number, decoderHandle?: number,
    audioHandle?: number): number;
  export function getDisconnectState(requestId: number): number;

  export function sendKey(sessionId: number, scancode: number, pressed: boolean): void;
  export function sendKeySequence(sessionId: number, keyCodes: number[]): boolean;
  export function sendKeyEvents(sessionId: number, keyCodes: number[], pressed: boolean[]): boolean;
  export function sendMouse(sessionId: number, x: number, y: number, button: number, pressed: boolean): void;
  export function sendMouseWheel(sessionId: number, x: number, y: number, delta: number): void;
  export function sendRustDeskTouchpadWheel(sessionId: number, x: number, y: number): boolean;
  export function setRustDeskImageQuality(sessionId: number, quality: number): boolean;
  export function toggleRustDeskPrivacyMode(sessionId: number, on: boolean): boolean;
  export function toggleRustDeskVirtualDisplay(sessionId: number, display: number, on: boolean): boolean;
  export function setRustDeskStreamOptions(sessionId: number, codec: number, audioEnabled: boolean): boolean;
  export function sendText(sessionId: number, text: string): void;
  export function enqueueSshTerminalInput(sessionId: number, text: string,
    expectedGeneration?: number, control?: boolean, ordered?: boolean,
    orderedEnd?: boolean): SshTerminalInputEnqueueResult;
  export function sendFile(sessionId: number, remotePath: string, data: ArrayBuffer): number;
  export function writeRemoteFileChunk(sessionId: number, remotePath: string, data: ArrayBuffer, offset: number, truncate: boolean): number;
  export function writeRemoteFileChunkAsync(sessionId: number, remotePath: string, data: ArrayBuffer,
    offset: number, truncate: boolean, expectedGeneration?: number): Promise<SftpWriteAsyncResult>;
  export function listRemoteDir(sessionId: number, remotePath: string): SftpFileEntry[];
  export function listRemoteDirAsync(sessionId: number, remotePath: string,
    expectedGeneration?: number): Promise<SftpListAsyncResult>;
  export function readRemoteFile(sessionId: number, remotePath: string): ArrayBuffer;
  export function readRemoteFileChunk(sessionId: number, remotePath: string, offset: number, maxLen: number): ArrayBuffer;
  export function readRemoteFileChunkAsync(sessionId: number, remotePath: string, offset: number,
    maxLen: number, expectedGeneration?: number): Promise<SftpReadAsyncResult>;
  export function removeRemoteFile(sessionId: number, remotePath: string): number;
  export function removeRemoteFileAsync(sessionId: number, remotePath: string,
    expectedGeneration?: number): Promise<SftpMutationAsyncResult>;
  export function removeRemoteDir(sessionId: number, remotePath: string): number;
  export function removeRemoteDirAsync(sessionId: number, remotePath: string,
    expectedGeneration?: number): Promise<SftpMutationAsyncResult>;
  export function makeRemoteDir(sessionId: number, remotePath: string): number;
  export function makeRemoteDirAsync(sessionId: number, remotePath: string,
    expectedGeneration?: number): Promise<SftpMutationAsyncResult>;
  export function renameRemotePath(sessionId: number, oldPath: string, newPath: string): number;
  export function renameRemotePathAsync(sessionId: number, oldPath: string,
    newPath: string, atomic?: boolean, expectedGeneration?: number): Promise<SftpMutationAsyncResult>;
  export function sendClipboard(sessionId: number, data: ArrayBuffer): boolean;
  export function setSessionClipboardFiles(sessionId: number, paths: string[]): boolean;
  export function getSessionClipboardText(sessionId: number): string;
  export function isSessionClipboardReady(sessionId: number): boolean;
  export function setSessionClipboardEnabled(sessionId: number, enabled: boolean): boolean;
  /** Returns a fresh positive safe-integer token, or 0. Automatic claims never replace a live owner. */
  export function claimSessionClipboardAuthority(sessionId: number, nativeGeneration: number,
    replaceExisting?: boolean): number;
  export function ownsSessionClipboardAuthority(sessionId: number, nativeGeneration: number, token: number): boolean;
  export function revokeSessionClipboardAuthority(sessionId: number, nativeGeneration: number, token: number): boolean;
  /** Final synchronous write only; Promise/async callbacks are not supported. */
  export function withSessionClipboardAuthority(sessionId: number, nativeGeneration: number,
    token: number, commit: () => boolean): boolean;

  export function getConnectionState(sessionId: number): number;
  export function getSshAuthPrompt(sessionId: number, sessionGeneration: number): SshAuthPromptRequest | null;
  export function respondSshAuthPrompt(response: SshAuthPromptResponse): boolean;
  export function cancelSshAuthPrompt(sessionId: number, sessionGeneration: number,
    requestId: number): boolean;
  export function getSshSessionSnapshot(sessionId: number,
    sessionGeneration: number): SshSessionSnapshot;
  export function getSshSessionEvents(sessionId: number, channelId: string,
    sessionGeneration: number, afterSequence?: number): SshSessionEventsResult;
  export function configureSshForwarding(sessionId: number, sessionGeneration: number,
    config: SshForwardingConfig): number;
  export function removeSshForwarding(sessionId: number, sessionGeneration: number,
    id: string): number;
  export function startSshForwarding(sessionId: number, sessionGeneration: number,
    id: string): number;
  export function markSshForwardingListening(sessionId: number, sessionGeneration: number,
    id: string): number;
  export function failSshForwarding(sessionId: number, sessionGeneration: number,
    id: string, error: number): number;
  export function stopSshForwarding(sessionId: number, sessionGeneration: number,
    id: string): number;
  export function completeSshForwardingStop(sessionId: number, sessionGeneration: number,
    id: string): number;
  export function acquireSshForwardingConnection(sessionId: number, sessionGeneration: number,
    id: string): number;
  export function releaseSshForwardingConnection(sessionId: number, sessionGeneration: number,
    id: string): number;
  export function getSshForwardingSnapshots(sessionId: number,
    sessionGeneration: number): SshForwardingSnapshotsResult;
  export function onRustDeskNetworkChanged(sessionId: number, sessionGeneration: number,
    available: boolean, networkGeneration: number): boolean;
  export function submitRustDesk2FA(sessionId: number, code: string): boolean;
  export function getRemoteCursorSnapshot(sessionId: number, includePixels?: boolean): RemoteCursorSnapshot;
  export function getRemoteCursorSnapshotPixelsAsync(sessionId: number): Promise<RemoteCursorSnapshot>;
  export function getConnectionLastMessage(sessionId: number): string;
  export function getRustDeskLastError(): string;
  export function probeRdpCertificate(host: string, port: number, serverName: string): RdpCertificateInfo;
  export function probeRdpCertificateAsync(host: string, port: number,
    serverName: string): Promise<RdpCertificateInfo>;
  export function probeRdpCertificateRouteAsync(
    request: RdpPreflightRequest): Promise<RdpPreflightResult>;
  export function cancelAllRdpPreflightProbes(): number;
  export function getPendingRdpPreflightProbeCount(): number;
  export function beginRdpPreflightScopeTransition(): number;
  export function endRdpPreflightScopeTransition(): boolean;
  export function probeRustDeskPresenceAsync(host: string, port: number, serverKey: string,
    peerId: string, token: string, direct: boolean, keyMode: number,
    timeoutMs?: number): RustDeskPresenceProbePromise;
  export function cancelRustDeskPresenceProbe(requestId: number): boolean;
  export function probeVncCertificateAsync(host: string, port: number,
    serverName: string, timeoutMs?: number): VncCertificateProbePromise;
  export function cancelVncCertificateProbe(requestId: number): boolean;
  export function probeVncGatewayDeepAsync(host: string, port: number, transport: string,
    repeaterMode: string, target: string, tls: boolean, expectedFingerprint: string,
    timeoutMs: number, ownerType: string, ownerId: string, userId: string,
    storeIdentityFingerprint: string, endpointBindingFingerprint: string,
    accountGeneration: number, enabled: boolean): VncGatewayDeepHealthPromise;
  export function cancelVncGatewayDeep(requestId: number): boolean;
  export function getRdpRenderStats(sessionId: number): RdpRenderStats;
  export function acknowledgeRdpInputGeometry(sessionId: number, epoch: number,
    width: number, height: number): boolean;
  export function synchronizeRdpRendererGeometry(sessionId: number): boolean;
  export function requestRdpDisplayLayout(sessionId: number,
    request: RdpDisplayLayoutRequest): RdpDisplayLayoutResult;
  export function cancelRdpDisplayLayout(sessionId: number): boolean;
  export function getSessionDiagnostics(sessionId: number): RustDeskDiagnosticsSnapshot;
  export function getRustDeskDiagnostics(sessionId: number): RustDeskDiagnosticsSnapshot;
  export function replayPendingRustDeskFrame(sessionId: number): boolean;
  export function getRustDeskDisplayCapabilities(sessionId: number): RustDeskDisplayCapabilities;
  export function getVncDisplayCapabilities(sessionId: number): VncDisplayCapabilities;
  export function switchVncDisplay(sessionId: number, monitor: number): boolean;
  export function attachRustDeskMultiCanvasPreview(sessionId: number, display: number,
    surfaceId: string, surfaceWidth: number, surfaceHeight: number, sourceWidth: number,
    sourceHeight: number, codec: number, visualFlipX?: boolean,
    visualFlipY?: boolean): RustDeskMultiCanvasPreviewSnapshot;
  export function setRustDeskMultiCanvasPreviewTransform(sessionId: number, display: number,
    visualFlipX: boolean, visualFlipY: boolean): boolean;
  export function detachRustDeskMultiCanvasPreview(sessionId: number, display: number): boolean;
  export function getRustDeskMultiCanvasPreview(sessionId: number,
    display: number): RustDeskMultiCanvasPreviewSnapshot;
  export function beginRustDeskDisplaySwitch(sessionId: number,
    display: number): RustDeskDisplaySwitchRequest;
  export function switchRustDeskDisplay(sessionId: number, display: number): boolean;
  export function changeRustDeskDisplayResolution(sessionId: number, display: number,
    width: number, height: number): boolean;
  export function sendRustDeskTouchScale(sessionId: number, scale: number): boolean;
  export function rustDeskPhoneControl(sessionId: number, generation: number, ownerToken: number, operation: number, x: number, y: number, streamEpoch: number): number;
  export function sendRustDeskTouchPan(sessionId: number, phase: number, x: number, y: number): boolean;
  export function getLocalResourceStats(includePro?: boolean): LocalResourceStats;
  export function getSessionTransferStatus(sessionId: number): SessionTransferStatus;
  export function getSessionClipboardSnapshot(sessionId: number): SessionClipboardSnapshot;
  export function sendSessionFileFromFd(sessionId: number, generation: number, remotePath: string, fd: number, conflictPolicy: number): number;
  export function getSessionFileTransfer(sessionId: number, generation: number, transferId: number): SessionTransferStatus;
  export function cancelSessionFileTransfer(sessionId: number, generation: number, transferId: number): boolean;
  export function releaseSessionFileTransfer(sessionId: number, generation: number, transferId: number): boolean;
  export function publishSessionClipboard(sessionId: number, generation: number, data: ArrayBuffer): ClipboardPublicationResult;
  export function getSessionClipboardPublicationState(sessionId: number, generation: number, publicationId: number): number;
  export function setRdpBackgroundVideoPrewarm(sessionId: number, enabled: boolean, intervalMs: number): boolean;
  export function presentRdpCachedFrame(sessionId: number): boolean;

  export function readData(sessionId: number): string;
  export function getSshTerminalDiagnostics(sessionId: number): SshTerminalDiagnosticsSnapshot;
  export function execSshCommand(sessionId: number, command: string,
    timeoutMs?: number): SshCommandResult;
  export function execSshCommandAsync(sessionId: number, command: string,
    timeoutMs?: number): Promise<SshCommandResult>;
  export function execSshSubsystem(sessionId: number, subsystem: string,
    timeoutMs?: number): SshCommandResult;
  export function execSshSubsystemAsync(sessionId: number, subsystem: string,
    timeoutMs?: number): Promise<SshCommandResult>;
  export function sendSshSignal(sessionId: number, signal: string): number;
  export function sendSshEof(sessionId: number): number;
  export function resizePty(sessionId: number, cols: number, rows: number): void;
  export function measureSshLatency(sessionId: number): number;
  export function measureSshLatencyAsync(sessionId: number): Promise<number>;
  export function setOnDataCallback(sessionId: number, cb: ((data: ArrayBuffer) => void) | null): void;
  export function detachSshSession(sessionId: number): boolean;
  export function resumeSshSession(sessionId: number): boolean;
  export function setHelperSocketPath(socketPath: string, binPath: string): void;

  // SSH 密钥工具 (函数声明)
  export function generateSshKeyPair(keyType: string, bits: number, comment: string, passphrase: string): GeneratedSshKeyPair;
  export function inspectSshPrivateKey(privateKeyPem: string, passphrase: string): SshPrivateKeyInfo;
  export function changeSshPrivateKeyPassphrase(privateKeyPem: string, oldPassphrase: string, newPassphrase: string): string;
  export function validatePublicKeyForAuthorizedKeys(publicKeyOpenSsh: string): boolean;
  export function probeSshHostKeyOperationAsync(config: SessionConfig, operationId: number,
    timeoutMs: number): Promise<SshHostKeyInfo> & { operationId: number };
  export function testSshKeyAuthOperationAsync(config: SessionConfig, operationId: number,
    timeoutMs: number): Promise<SshAuthTestResult> & { operationId: number };
  export function installSshPublicKeyOperationAsync(config: SessionConfig, publicKey: string,
    operationId: number, timeoutMs: number): Promise<SshPublicKeyInstallResult> & { operationId: number };
  export function cancelSshOperation(operationId: number): boolean;

  // ownerSessionId: > 0 the page's live session; < 0 a session not live yet (pending renderer).
  export function initRenderer(xcId: string, width: number, height: number, ownerSessionId?: number): number;
  export function destroyRenderer(handle: number): void;
  export function renderFrame(handle: number, textureId: number): void;
  export function renderRawBGRA(handle: number, data: ArrayBuffer, width: number, height: number, stride: number): void;
  export function resizeRenderer(handle: number, width: number, height: number): void;
  export function setRendererCanvasTransform(handle: number, scale: number, panX: number, panY: number,
    rotationQuarterTurns?: number, flipX?: boolean, flipY?: boolean): number;
  export function testRender(handle: number): void;
  export function registerNativeXComponent(): boolean;
  export function setXComponentSurfaceId(surfaceId: string, width: number, height: number): boolean;
  export function markXComponentSurfaceDestroyed(): void;
  export function markRendererSurfaceDestroyed(handle: number): void;
  // The process XComponent surface belongs to one picture page at a time (process-wide, every window).
  export function claimProcessSurface(pageToken: number): boolean;
  export function releaseProcessSurface(pageToken: number): void;
  export function requestFrameRefresh(sessionId?: number): void;
  export function getRendererViewport(handle: number): RendererViewport | null;

  export function initDecoder(width: number, height: number, codecType: number,
    rendererHandle?: number, desktopSurfaceCompatibility?: boolean, ownerSessionId?: number): number;
  export function destroyDecoder(handle: number): void;
  export function decodeFrame(handle: number, data: ArrayBuffer, size: number, timestamp: number): number;
  export function getTextureId(handle: number): number;
  export function testDecoderH264(handle: number): number;
  export function bindVideoPipeline(decoderHandle: number, rendererHandle: number): boolean;
  export function detachVideoPipeline(decoderHandle: number): boolean;
  export function requestDecoderRecovery(decoderHandle: number): boolean;
  export function rebindActiveVideoPipeline(sessionId?: number): boolean;
  export interface HardwareVideoDecoderCapability {
    available: boolean;
    name: string;
    minWidth: number;
    maxWidth: number;
    minHeight: number;
    maxHeight: number;
    minFps: number;
    maxFps: number;
    widthAlignment: number;
    heightAlignment: number;
    lowLatency: boolean;
  }
  export interface HardwareVideoDecoderCapabilities {
    h264: HardwareVideoDecoderCapability;
    hevc: HardwareVideoDecoderCapability;
    av1: HardwareVideoDecoderCapability;
  }
  export function getHardwareVideoDecoderCapabilities(): HardwareVideoDecoderCapabilities;
  /**
   * Decode a known four-colour H.264 (0) / H.265 (1) picture through this
   * device's hardware decoder → NativeImage → GPU path in the background and
   * keep how it lands on screen; once per codec and mode per process.
   */
  export function ensureVideoOrientationSelfTest(codec: number, desktop: boolean): void;

  export function initAudioPlayer(sampleRate?: number, channels?: number, sessionId?: number): number;
  export function destroyAudioPlayer(handle: number): void;
  export function setAudioMute(handle: number, mute: boolean): void;
  export function setActiveAudioMute(mute: boolean, sessionId?: number): void;
  export function isAudioPlaybackActive(sessionId?: number): boolean;
  // Only the focused window's picture session plays sound while several are live; 0 lets every session play.
  export function setAudioFocusSession(sessionId: number): void;
  export function isVideoPlaybackActive(): boolean;
  // Live RDP, RustDesk and VNC sessions in this process (every window).
  export function getLivePictureSessionCount(): number;

  export function handleKeyEvent(scancode: number, pressed: boolean, keyCode: number, modifiers: number): void;
  export function handleMouseEvent(x: number, y: number, button: number, pressed: boolean, wheelDelta: number): void;
  export function handleTouchEvent(data: object): void;

  export function getClipboardText(): string;
  export function setClipboardText(text: string): void;

  export function terminalCoreCreate(cols: number, rows: number): number;
  export function terminalCoreDestroy(handle: number): void;
  export function terminalCoreSetDefaultForeground(handle: number, foreground: number): void;
  export function terminalCoreWrite(handle: number, data: string): void;
  export function terminalCoreWriteBytes(handle: number, data: ArrayBuffer): void;
  export function terminalCoreResize(handle: number, cols: number, rows: number): void;
  export function terminalCoreScrollView(handle: number, deltaLines: number): void;
  export function terminalCoreScrollToBottom(handle: number): void;
  export function terminalCoreSnapshot(handle: number): TerminalCoreSnapshot;
  export function terminalCoreDirtySnapshot(handle: number): TerminalCoreSnapshot;

  export function sshTerminalRendererCreate(surfaceId: string, widthPx: number,
    heightPx: number, cols: number, rows: number, cellWidthPx: number,
    cellHeightPx: number, fontSizePx: number, foreground: number, background: number,
    viewportHeightPx: number, visibleHeightPx: number, bottomAlign: boolean): number;
  export function sshTerminalRendererDestroy(handle: number): void;
  export function sshTerminalRendererBindSurface(handle: number, surfaceId: string,
    widthPx: number, heightPx: number): number;
  export function sshTerminalRendererHasSurfaceFlushFailure(handle: number): boolean;
  export function sshTerminalRendererWriteBytes(handle: number, data: ArrayBuffer): void;
  export function sshTerminalRendererRefresh(handle: number): boolean;
  export function sshTerminalRendererResize(handle: number, cols: number, rows: number,
    cellWidthPx: number, cellHeightPx: number, fontSizePx: number): void;
  export function sshTerminalRendererSetAppearance(handle: number, fontSizePx: number,
    foreground: number, background: number): void;
  export function sshTerminalRendererSetViewport(handle: number, viewportHeightPx: number,
    visibleHeightPx: number, bottomAlign: boolean): void;
  export function sshTerminalRendererScrollView(handle: number, deltaLines: number): void;
  export function sshTerminalRendererScrollToBottom(handle: number): void;
  export function sshTerminalRendererContent(handle: number): string;
  export function sshTerminalRendererMode(handle: number): TerminalCoreMode;
}

export interface VncDisplayCapabilities {
  supported: boolean;
  mode: 'serverSelection' | 'unsupported';
  monitorCount: number;
  currentMonitor: number;
  pendingMonitor: number;
  switchGeneration: number;
  inputBlocked: boolean;
  lastResult: string;
}

interface SessionVersionInfo {
  moduleName: string;
  version: string;
  apiVersion: number;
  buildType: string;
  appVersion: string;
  gitShortSha: string;
  buildTimeUtc: string;
  rustDeskFfiAbiVersion: number;
  rustDeskProtocolFixture: string;
}

interface ProtocolInfo {
  name: string;
  displayName: string;
  port: number;
  version: string;
}

export interface RendererViewport {
  transformVersion: number;
  /** EGL swap succeeded for this exact geometry/version; zero while pending. */
  presentedTransformVersion: number;
  sourceWidth: number;
  sourceHeight: number;
  surfaceWidth: number;
  surfaceHeight: number;
  viewportX: number;
  viewportY: number;
  viewportW: number;
  viewportH: number;
}

export interface RdpCertificateInfo {
  ok: boolean;
  host: string;
  port: number;
  serverName: string;
  commonName: string;
  subject: string;
  issuer: string;
  fingerprintSha256: string;
  notBeforeMs: number;
  notAfterMs: number;
  flags: number;
  rootTrusted: boolean;
  hostMismatch: boolean;
  errorCode: number;
  errorMessage: string;
  preflightStatus: RdpPreflightStatus;
  riskFlags: string[];
}

export type RdpPreflightStatus = 'completed' | 'inconclusive' | 'unavailable' | 'transportFailed';

export type RdpEndpointMode = 'direct_rdp' | 'transparent_tcp_rdp' |
  'microsoft_rd_gateway' | 'vendor_https_bastion' | 'azure_bastion' | 'unknown_gateway';
export type RdpGatewayTransport = 'auto' | 'http' | 'rpc' | 'websocket' | 'no-websockets';

export interface RdpPreflightRoute {
  endpointMode?: RdpEndpointMode;
  targetHost: string;
  targetPort?: number;
  targetServerName?: string;
  gatewayHost?: string;
  gatewayPort?: number;
  gatewayServerName?: string;
  gatewayTransport?: RdpGatewayTransport;
}

export interface NativeSessionOwnerIdentity {
  sessionId: number;
  generation: number;
  ownerToken: number;
}

export interface NativeDisconnectReceipt {
  accepted: boolean;
  requestId: number;
  terminalState: number;
}

export interface RdpPreflightRequest {
  route: RdpPreflightRoute;
  username?: string;
  password?: string;
  domain?: string;
  targetRestrictedAdmin?: boolean;
  expectedTargetFingerprintSha256?: string;
  expectedGatewayFingerprintSha256?: string;
  targetAllowUntrustedRoot?: boolean;
  targetAllowHostMismatch?: boolean;
  targetAllowTimeAnomaly?: boolean;
  gatewayAllowUntrustedRoot?: boolean;
  gatewayAllowHostMismatch?: boolean;
  gatewayAllowTimeAnomaly?: boolean;
  generation?: number;
  requestId?: string;
}

export interface RdpCertificateRecord {
  present: boolean;
  rootTrusted: boolean;
  hostMismatch: boolean;
  flags: number;
  host: string;
  port: number;
  stage: 'gateway' | 'target' | string;
  serverName: string;
  commonName: string;
  subject: string;
  issuer: string;
  fingerprintSha256: string;
  notBeforeMs: number;
  notAfterMs: number;
  riskFlags: string[];
}

export interface RdpPreflightResult {
  ok: boolean;
  preflightStatus: RdpPreflightStatus;
  riskFlags: string[];
  gatewayRiskFlags: string[];
  targetRiskFlags: string[];
  endpointMode: RdpEndpointMode | string;
  routeIdentity: string;
  generation: number;
  requestId: string;
  stage: 'endpoint' | 'gateway' | 'tunnel' | 'negotiation' | 'target' | string;
  errorCode: string;
  errorMessage: string;
  /** Requested Gateway policy; does not prove the wire transport. */
  gatewayTransportRequested: string;
  /** Final transport branch, or 'unknown' when no observation exists. */
  gatewayTransportNegotiated: string;
  /** @deprecated Compatibility alias for gatewayTransportRequested. */
  gatewayTransportSelected: string;
  requiresGatewayAuth: boolean;
  requiresUserDecision: boolean;
  /**
   * Runtime-only numeric transport override from the direct DNS fallback.
   * The configured hostname remains the RDP/TLS identity and this value is
   * never persisted in RemoteHost or sent through cloud sync.
   */
  transportHost?: string;
  gatewayCertificate: RdpCertificateRecord;
  targetCertificate: RdpCertificateRecord;
}

export interface RustDeskPresenceResult {
  state: number;
  latencyMs: number;
  errorCode: number;
}

export interface RustDeskPresenceProbePromise extends Promise<RustDeskPresenceResult> {
  requestId: number;
}

export interface VncCertificateInfo {
  ok: boolean;
  host: string;
  port: number;
  serverName: string;
  fingerprintSha256: string;
  commonName: string;
  subject: string;
  issuer: string;
  notBeforeMs: number;
  notAfterMs: number;
  rootTrusted: boolean;
  hostMismatch: boolean;
  tlsVersion: string;
  cipherCategory: string;
  errorCode: number;
  errorMessageCategory: string;
  errorMessage: string;
}

export interface VncCertificateProbePromise extends Promise<VncCertificateInfo> {
  requestId: number;
}

export interface VncGatewayDeepHealthResult {
  stage: string;
  code: string;
  message: string;
  protocolReady: boolean;
  certificateFingerprintSha256: string;
  ownerType: string;
  ownerId: string;
  userId: string;
  storeIdentityFingerprint: string;
  endpointBindingFingerprint: string;
  accountGeneration: number;
}

export interface VncGatewayDeepHealthPromise extends Promise<VncGatewayDeepHealthResult> {
  requestId: number;
}

export interface RdpRenderStats {
  paintCount: number;
  renderedPaintCount: number;
  firstPaintMs: number;
  lastPaintMs: number;
  lastRemoteUpdateAgeMs: number;
  eventLoopAgeMs: number;
  eventLoopBlockMaxUs: number;
  lastInputPostAgeMs: number;
  eventLoopTicks: number;
  networkCheckCount: number;
  networkCheckFailures: number;
  inputPostFailures: number;
  lastRenderResult: number;
  skippedPaintCount: number;
  slowRenderCount: number;
  minRenderIntervalUs: number;
  lastRenderCostUs: number;
  lastRenderBytes: number;
  pumpSubmitted: number;
  pumpRendered: number;
  pumpReplaced: number;
  pumpRejected: number;
  invalidEvents: number;
  invalidPixels: number;
  copiedBytes: number;
  presentationRejected: number;
  surfaceDetachedRejections: number;
  generationRejections: number;
  presentationWindowSamples: number;
  callbackP50Us: number;
  callbackP95Us: number;
  callbackMaxUs: number;
  copyP50Us: number;
  copyP95Us: number;
  copyMaxUs: number;
  queueP50Us: number;
  queueP95Us: number;
  queueMaxUs: number;
  uploadP50Us: number;
  uploadP95Us: number;
  uploadMaxUs: number;
  drawP50Us: number;
  drawP95Us: number;
  drawMaxUs: number;
  swapP50Us: number;
  swapP95Us: number;
  swapMaxUs: number;
  workerP50Us: number;
  workerP95Us: number;
  workerMaxUs: number;
  glUploadGateDecision: number;
  glUploadEvaluatedSamples: number;
  glUploadSwapP95Us: number;
  glUploadSharePermille: number;
  desktopWidth: number;
  desktopHeight: number;
  graphicsEpoch: number;
  desktopResizeCount: number;
  desktopResizeFailures: number;
  desktopResizeInProgress: boolean;
  gfxChannelConnected: boolean;
  displayControlReady: boolean;
  displayControlDisabled: boolean;
  displayRequestedWidth: number;
  displayRequestedHeight: number;
  displayEffectiveWidth: number;
  displayEffectiveHeight: number;
  displayScaleFactor: number;
  displayRequestCount: number;
  displayChannelRequestCount: number;
  displayFailureCount: number;
  displayLayoutPending: boolean;
  displayLayoutInFlight: boolean;
  displayLastResult: string;
  inputGeometryReady: boolean;
  inputGeometryAcknowledgedEpoch: number;
  inputGeometryFenceDrops: number;
  inputQueueDepth: number;
  inputQueueMax: number;
  inputTextUnits: number;
  inputDroppedMouseMoves: number;
  inputNonDisposableOverflow: number;
  graphicsMode: string;
  /** Absent on native builds that predate graphics evidence. */
  gfxEvidence?: RdpGfxEvidenceStats;
}

/**
 * Observed RDP graphics negotiation. `requested*`/`h264Advertised` describe
 * what the client offered; `capsConfirmed*` and `wireCodec` are what the
 * server actually confirmed and sent. `wireCodec` is 'none' until the first
 * RDPGFX surface command arrives.
 */
export interface RdpGfxEvidenceStats {
  requestedApplied: boolean;
  compiledGfx: boolean;
  compiledH264: boolean;
  h264PathSafe: boolean;
  supportGraphicsPipeline: boolean;
  remoteFxCodec: boolean;
  h264Advertised: boolean;
  fallbackConsumed: boolean;
  fallbackReason: string;
  capsAdvertisedCount: number;
  capsAdvertisedMaxVersion: string;
  capsAdvertisedAvc: boolean;
  capsConfirmed: boolean;
  capsConfirmedVersion: string;
  capsConfirmedFlags: number;
  capsConfirmedAvc: boolean;
  surfaceCommands: number;
  surfaceCommandBytes: number;
  avcSurfaceCommands: number;
  unknownCodecCommands: number;
  wireCodecMask: number;
  wireCodec: string;
}

export interface RdpDisplayLayoutRequest {
  width: number;
  height: number;
  physicalWidthMm: number;
  physicalHeightMm: number;
  orientation: number;
  desktopScaleFactor: number;
  deviceScaleFactor: number;
}

export interface RdpDisplayLayoutResult {
  accepted: boolean;
  code: string;
  message: string;
}

export interface RustDeskDiagnosticsSnapshot extends NativeVideoDiagnosticEvidence {
  supported: boolean;
  sessionActive: boolean;
  protocolSnapshotAvailable: boolean;
  videoSeen: boolean;
  receivedRateAvailable: boolean;
  presentedRateAvailable: boolean;
  decodeRateAvailable: boolean;
  remoteInputPermissionKnown: boolean;
  remoteInputAllowed: boolean;
  remoteClipboardPermissionKnown: boolean;
  remoteClipboardAllowed: boolean;
  remoteFilePermissionKnown: boolean;
  remoteFileAllowed: boolean;
  sessionId: number;
  latencyMs: number;
  targetBitrateKbps: number;
  requestedImageQuality: number;
  effectiveImageQuality: number;
  sentImageQuality: number;
  qualityProfile: number;
  qualityFps: number;
  qualityRequestedGeneration: number;
  qualityAppliedGeneration: number;
  qualityUpdateStatus: number;
  /** RustDesk peer extras (PeerInfo.platform_additions) and the last privacy-mode answer. */
  peerInstalled?: boolean;
  /** Virtual display driver on a Windows peer: 0 none, 1 rustdesk_idd, 2 amyuni_idd. */
  virtualDisplayImpl?: number;
  /** rustdesk_idd: bit n set = virtual display n (1..4) plugged in. */
  rustdeskVirtualDisplayMask?: number;
  amyuniVirtualDisplayCount?: number;
  privacySupported?: boolean;
  /** BackNotification.PrivacyModeState (0 unknown, 4 on, 8 off, 3 unsupported, 5 denied …) and its counter. */
  privacyState?: number;
  privacyGeneration?: number;
  videoMessages: number;
  receivedFrames: number;
  keyframes: number;
  receivedBytes: number;
  audioFrames: number;
  cadenceGaps: number;
  maxCadenceGapMs: number;
  testDelayCount: number;
  receivedFps: number;
  displayFps: number;
  decodeFps: number;
  bitrateKbps: number;
  codec: number;
  width: number;
  height: number;
  connectionPath: string;
  peerPlatform?: string;
  desktopSurfaceCompatibility?: boolean;
  nativeImagePresentation?: string;
  producerTransform?: string;
  appliedTransform?: string;
  producerTransformSampled?: boolean;
  producerTransformReadResult?: number;
  producerTransformSamples?: number;
  producerTransformChanges?: number;
  producerTransformReadFailures?: number;
  producerTransformClassMask?: number;
  producerTransformMatrix?: number[];
  appliedTextureTransform?: number[];
  rendererTransformValid?: boolean;
  rendererTransformVersion?: number;
  rendererRotationQuarterTurns?: number;
  rendererFlipX?: boolean;
  rendererFlipY?: boolean;
  decoderGeneration?: number;
  rendererGeneration?: number;
  lastFrameAtMs: number;
  lastFrameAgeMs: number;
  lastPresentedAtMs: number;
  lastPresentedFrameAgeMs: number;
  decodeOk: number;
  decodeErrors: number;
  decodeP50Us: number;
  decodeP95Us: number;
  decodeMaxUs: number;
  presentedFrames: number;
  presentationRejected: number;
  lastDirtyX: number;
  lastDirtyY: number;
  lastDirtyWidth: number;
  lastDirtyHeight: number;
  requestedColorDepth: string;
  effectiveColorDepth: number;
  inputEventsSent: number;
  inputEventsDropped: number;
  presentationWindowSamples: number;
  presentationWindowMs: number;
  renderP50Us: number;
  renderP95Us: number;
  renderMaxUs: number;
  queueDepth: number;
  queueMax: number;
  droppedFrames: number;
  decoderBackend: string;
}

export interface RustDeskDisplayResolution {
  width: number;
  height: number;
}

export interface RustDeskDisplayInfo {
  display: number;
  x: number;
  y: number;
  width: number;
  height: number;
  originalWidth: number;
  originalHeight: number;
  scaleMilli: number;
  online: boolean;
  cursorEmbedded: boolean;
  name: string;
  resolutions: RustDeskDisplayResolution[];
}

export interface RustDeskDisplayCapabilities {
  supported: boolean;
  currentDisplay: number;
  switchGeneration: number;
  readySwitchGeneration: number;
  pendingDisplay: number;
  confirmedDisplay: number;
  inputBlocked: boolean;
  multiCanvasPreviewSupported: boolean;
  multiCanvasPreviewMaxDisplays: number;
  multiCanvasPreviewActive: boolean;
  multiCanvasPreviewDisplay: number;
  width: number;
  height: number;
  originalWidth: number;
  originalHeight: number;
  scaleMilli: number;
  geometryEpoch: number;
  peerVersion?: string;
  peerPlatform?: string;
  hasDisplayIndex?: boolean;
  hasPermission?: boolean;
  hasVirtualDisplay?: boolean;
  resolutions: RustDeskDisplayResolution[];
  displays: RustDeskDisplayInfo[];
}

export interface RustDeskDisplaySwitchRequest {
  accepted: boolean;
  generation: number;
}

export interface RustDeskMultiCanvasPreviewSnapshot {
  supported: boolean;
  active: boolean;
  display: number;
  status: string;
  reason: string;
  decoderBackend: string;
  sourceWidth: number;
  sourceHeight: number;
  codec: number;
  lastDecodeResult: number;
  receivedFrames: number;
  acceptedFrames: number;
  droppedFrames: number;
  presentedFrames: number;
  queueDepth: number;
  inputDroppedFrames: number;
}

export interface LocalResourceStats {
  supported: boolean;
  cpuAvailable: boolean;
  cpuPercent: number;
  memoryBytes: number;
  memoryAvailable: boolean;
  gpuAvailable: boolean;
  gpuPercent: number;
  sampledAtMs: number;
}

export interface RemoteCursorSnapshot {
  sessionId: number;
  protocol: string;
  generation: number;
  shapeId: string;
  shapeSource: string;
  x: number;
  y: number;
  width: number;
  height: number;
  hotX: number;
  hotY: number;
  fallbackShape: boolean;
  protocolShapeAvailable: boolean;
  legacyVncCursorBootstrap: boolean;
  positionAvailable: boolean;
  visible: boolean;
  shapeRevision: number;
  positionRevision: number;
  visibilityRevision: number;
  rgba: ArrayBuffer;
}

export interface SessionRdpClipboardFileEntry {
  index: number;
  relativeName: string;
  directory: boolean;
  sizeKnown: boolean;
  size: number;
}
export interface SessionRdpClipboardContent {
  textUtf8?: string;
  png?: ArrayBuffer;
  htmlUtf8?: string;
  rtfBytes?: ArrayBuffer;
  rgbaStraight?: ArrayBuffer;
  width?: number;
  height?: number;
}
export interface SessionRdpClipboardFormats { sequence: number; formats: number[]; }
export interface SessionRdpClipboardFormatResult {
  requestId: number;
  sequence: number;
  format: number;
  state: string;
  diagnosticCode: string;
  content: SessionRdpClipboardContent;
}
export const publishSessionRdpClipboardContent: (sessionId: number, generation: number, content: SessionRdpClipboardContent) => ClipboardPublicationResult;
export const getSessionRdpClipboardFormats: (sessionId: number, generation: number) => SessionRdpClipboardFormats;
export const requestSessionRdpClipboardFormat: (sessionId: number, generation: number, sequence: number, format: number) => number;
export const getSessionRdpClipboardFormatResult: (sessionId: number, generation: number, requestId: number) => SessionRdpClipboardFormatResult;
export const releaseSessionRdpClipboardFormat: (sessionId: number, generation: number, requestId: number) => boolean;

export interface SessionRdpClipboardFiles {
  sequence: number;
  state: string;
  streamSupported: boolean;
  lockSupported: boolean;
  totalKnown: boolean;
  totalBytes: number;
  diagnosticCode: string;
  entries: SessionRdpClipboardFileEntry[];
}
export interface SessionRdpClipboardArtifact {
  index: number;
  relativeName: string;
  directory: boolean;
  size: number;
}
export interface SessionRdpClipboardReceive {
  taskId: number;
  sequence: number;
  phase: string;
  transferredBytes: number;
  totalBytes: number;
  totalKnown: boolean;
  diagnosticCode: string;
  artifacts: SessionRdpClipboardArtifact[];
}
export const getSessionRdpClipboardFiles: (sessionId: number, generation: number) => SessionRdpClipboardFiles;
export const requestSessionRdpClipboardFiles: (sessionId: number, generation: number, sequence: number) => boolean;
export const startSessionRdpClipboardReceive: (sessionId: number, generation: number, sequence: number, selectedIndices: number[], directoryFd: number) => number;
export const getSessionRdpClipboardReceive: (sessionId: number, generation: number, id: number) => SessionRdpClipboardReceive;
export const cancelSessionRdpClipboardReceive: (sessionId: number, generation: number, id: number) => boolean;
export const releaseSessionRdpClipboardReceive: (sessionId: number, generation: number, id: number) => boolean;
export const publishSessionClipboardFiles: (sessionId: number, generation: number, paths: string[]) => ClipboardPublicationResult;

export interface SessionRdpReceivedFileFact {
  relativePath: string;
  writeGeneration: number;
  writtenBytes: number;
  activeHandles: number;
  remoteClosed: boolean;
  uncertain: boolean;
}
/** How far the remote has read the files offered on its clipboard (requestedBytes may pass a file's end). */
export interface SessionRdpFileOfferProgress {
  generation: number;
  requestedBytes: number;
  requests: number;
  lastRequestAgoMs: number;
}
export interface SessionRdpDrive {
  phase: string;
  generation: number;
  evidenceComplete: boolean;
  diagnosticCode: string;
  entries: SessionRdpReceivedFileFact[];
}
export const getSessionRdpDrive: (sessionId: number, generation: number) => SessionRdpDrive;
export const getSessionRdpFileOfferProgress: (sessionId: number, generation: number) => SessionRdpFileOfferProgress;
export const disableSessionRdpDrive: (sessionId: number, generation: number) => boolean;

/** Only accepts a directory FD already opened through the authorized local provider. */
export const openExclusiveTransferDirectory: (parentFd: number, leaf: string) => number;
export const openExclusiveTransferFile: (rootFd: number, relativePath: string) => number;
export const ensureTransferExportDirectory: (rootFd: number, relativePath: string) => boolean;

export interface RustDeskClipboardSnapshot {
  revision: number; state: number; capable: boolean; enabled: boolean; entryCount: number; diagnosticCode: number;
}
export interface RustDeskClipboardEntry {
  index: number; name: string; isDirectory: boolean; size: number; modifiedTime: number;
}
export interface RustDeskClipboardSource { name: string; fd: number; isDirectory: boolean; }
export interface RustDeskClipboardPublication {
  publicationId: number; state: number; diagnosticCode: number; requestedBytes: number; drained: boolean;
}
export const configureSessionRustDeskFileClipboard: (sid: number, generation: number, enabled: boolean) => boolean;
export const getSessionRustDeskFileClipboard: (sid: number, generation: number) => RustDeskClipboardSnapshot;
export const getSessionRustDeskClipboardEntries: (sid: number, generation: number, revision: number) => RustDeskClipboardEntry[];
export const publishSessionRustDeskClipboardFiles: (sid: number, generation: number, sources: RustDeskClipboardSource[]) => number;
export const getSessionRustDeskClipboardPublication: (sid: number, generation: number, id: number) => RustDeskClipboardPublication;
export const revokeSessionRustDeskClipboardPublication: (sid: number, generation: number, id: number) => boolean;
export const receiveSessionRustDeskClipboardFile: (sid: number, generation: number, revision: number, index: number, fd: number) => number;

export interface SessionTransferAuthentication {
  transferId: number;
  challengeId: number;
  kind: number;
  state: number;
  expiresInMs: number;
  attemptsRemaining: number;
  diagnosticCode: number;
}
export interface SessionTransferResult {
  operationKind: number;
  sourceMetadataAvailable: boolean;
  sourceSize: number;
  sourceModifiedTime: number;
  remoteOperationAcknowledged: boolean;
}
export const createSessionRemoteDirectory: (sessionId: number, generation: number, path: string) => number;
export const getSessionTransferAuthentication: (sessionId: number, generation: number, transferId: number) => SessionTransferAuthentication;
export const submitSessionTransferAuthentication: (sessionId: number, generation: number, transferId: number, challengeId: number, kind: number, secret: string) => boolean;
export const getSessionTransferResult: (sessionId: number, generation: number, transferId: number) => SessionTransferResult;

export interface SessionRemoteFileEntry {
  name: string;
  type: number;
  size: number;
  modifiedTime: number;
}
export interface SessionRemoteDirectory {
  path: string;
  entries: SessionRemoteFileEntry[];
}
export const requestSessionRemoteDirectory: (sessionId: number, generation: number, path: string) => number;
/** A folder listing, optionally with hidden entries; read with getSessionRemoteDirectory. */
export const requestSessionRemoteListing: (sessionId: number, generation: number, path: string,
  includeHidden: boolean) => number;
/** Every file below a folder (names relative to it, '/' separated); read with getSessionRemoteDirectory. */
export const requestSessionRemoteTree: (sessionId: number, generation: number, path: string,
  includeHidden: boolean) => number;
/** Removes a file, or a folder with everything in it. */
export const removeSessionRemotePath: (sessionId: number, generation: number, path: string,
  directory: boolean) => number;
/** Renames a file or folder within its folder. */
export const renameSessionRemotePath: (sessionId: number, generation: number, path: string,
  newName: string) => number;
export const getSessionRemoteDirectory: (sessionId: number, generation: number, transferId: number) => SessionRemoteDirectory;
export const downloadSessionFileToFd: (sessionId: number, generation: number, path: string, fd: number, size: number, modifiedTime: number) => number;

export interface SessionTransferPermissions {
  available: boolean;
  knownMask: number;
  enabledMask: number;
}
export const getSessionTransferPermissions: (sessionId: number, generation: number) => SessionTransferPermissions;

export interface ClipboardPublicationResult {
  publicationId: number;
  state: number;
}

export interface SessionClipboardSnapshot {
  sequence: number;
  kind: string;
  text: string;
  ready: boolean;
}

export interface SessionTransferStatus {
  rdpDriveMounted: boolean;
  rustdeskTransferState: number;
  transferId: number;
  transferredBytes: number;
  totalBytes: number;
  diagnosticCode: string;
}

export interface SessionConfig {
  protocol: string;
  host: string;
  port: number;
  username: string;
  password: string;
  width: number;
  height: number;
  customHostname: string;
  gatewayHost: string;
  gatewayPort: number;
  rdpEndpointMode?: RdpEndpointMode;
  rdpGatewayTransport?: RdpGatewayTransport;
  rdpGatewayServerName?: string;
  domain: string;
  codec: string;
  multiMonitor: boolean;
  monitorCount: number;
  colorDepth: number;
  /** RDP TLS/NLA identity; legacy customHostname remains a migration fallback. */
  targetServerName?: string;
  /** RDP /client-hostname:, never used as a transport or certificate identity. */
  clientHostname?: string;
  rdpDesktopScaleFactor?: number;
  /** Debug + Pro only: load the MS-RDPEWA channel so the remote session can use a local USB security key. */
  rdpSecurityKeyRedirect?: boolean;
  rdpDeviceScaleFactor?: number;
  rdpDesktopPhysicalWidthMm?: number;
  rdpDesktopPhysicalHeightMm?: number;
  rdpDesktopOrientation?: number;
  rdpAuthIdentityMode?: number; // 0=MicrosoftAccount\email, 1=domain MicrosoftAccount, 2=bare email, 3=.\AzureAD\email, 4=domain AzureAD
  rdpAuthMode?: 'password' | 'blank_password' | 'restricted_admin';
  rdpRestrictedAdminSecretSource?: 'ntlm_hash';
  // Transient only. Never persist this value in RemoteHost or a cloud payload.
  rdpRestrictedAdminHash?: string;
  authMethod: string;
  privateKeyPem: string;
  privateKeyPassphrase: string;
  keyboardInteractiveResponses?: string[];
  /** Optional LANG sent as an SSH channel environment request before PTY/shell startup. */
  sshLocale?: string;
  sshProxyType?: 'direct' | 'http_connect' | 'socks5' | 'frp_tcp' | 'frp_visitor' |
    'frp_stcp' | 'frp_sudp' | 'frp_xtcp' | 'ssh_jump' | 'legacy_gateway';
  sshProxyHost?: string;
  sshProxyPort?: number;
  sshProxyUsername?: string;
  sshProxyPassword?: string;
  sshProxyAuthMethod?: 'password' | 'publickey' | 'kbd-interactive';
  sshProxyPrivateKeyPem?: string;
  sshProxyPrivateKeyPassphrase?: string;
  sshProxyKeyboardInteractiveResponses?: string[];
  sshRoute?: SshRoute;
  sshJumpHopHandoffs?: SshJumpHopHandoff[];
  expectedHostKeyRawBase64?: string;
  expectedHostKeyFingerprintSha256?: string;
  sshHostKeyPromptEnabled?: boolean;
  sshTrustHostId?: string;
  sshHostKeyRouteIdentity?: string;
  sshJumpHostKeyRawBase64?: string;
  sshJumpHostKeyFingerprintSha256?: string;
  expectedRdpCertificateFingerprintSha256?: string;
  expectedRdpGatewayCertificateFingerprintSha256?: string;
  rdpAllowUntrustedRoot?: boolean;
  rdpAllowHostMismatch?: boolean;
  rdpCertificateAllowUnpinnedOnce?: boolean;
  /** Skip independent preflight; live callback accepts an unpinned peer only via strict PKI validation. */
  rdpVerifyCertificateOnConnect?: boolean;
  rdpAllowStandardSecurityOnce?: boolean;
  /** Explicit direct TLS compatibility mode. Default false; never enables Standard RDP Security. */
  rdpTlsWithoutNla?: boolean;
  rdpCertificateAllowTimeAnomalyOnce?: boolean;
  rdpGatewayAllowUntrustedRoot?: boolean;
  rdpGatewayAllowHostMismatch?: boolean;
  rdpGatewayCertificateAllowUnpinnedOnce?: boolean;
  rdpGatewayCertificateAllowTimeAnomalyOnce?: boolean;
  // RustDesk 扩展字段
  rdImageQuality?: number;   // 0=fast, 1=balanced, 2=quality
  rdDirectIp?: boolean;      // 直连IP模式
  rdExplicitPhone?: boolean; // session-only verified manual target choice
  rdConnectionStrategy?: 'force_relay' | 'direct_ip' | 'auto';
  rdDirectPort?: number;     // 直连端口
  rdLanDiscovery?: boolean;  // LAN发现
  rdPrivacyMode?: boolean;   // 隐私模式
  rdAudioEnabled?: boolean;   // 远端音频
  rdClipboardEnabled?: boolean; // RDP 剪贴板重定向
  rdDriveName?: string;       // RDP Windows 侧共享盘名称
  rdDrivePath?: string;       // RDP 本地重定向盘路径
  rdPasswordMode?: number;   // 0=一次性, 1=永久
  rdAuthMode?: number;       // 0=设备密码, 1=请求被控端点击批准
  rdPasswordLength?: number; // 临时密码长度 (6/8/10)
  rdRelayId?: string;        // 中继配置ID
  rdAccountId?: string;      // API账户ID
  rdServerKey?: string;      // Rendezvous 公钥或共享准入 Key
  rdServerKeyMode?: number;  // 0=legacy/auto, 1=server public key, 2=shared access key
  // Configured hbbr fallback port. hbbs-provided relay_server:port remains authoritative.
  rdRelayPort?: number;
  // Server Pro control-plane token; transient only, never persist in RemoteHost/cloud.
  rdAccessToken?: string;
  vncTransport?: string;
  vncGatewayHost?: string;
  vncGatewayPort?: number;
  vncServerName?: string;
  vncGatewayPath?: string;
  vncRepeaterMode?: string;
  vncRepeaterTarget?: string;
  vncTls?: boolean;
  vncViewOnly?: boolean;
  vncClipboardEnabled?: boolean;
  vncSecurityPolicy?: string;
  vncConnectTimeoutMs?: number;
  vncAuthTimeoutMs?: number;
  vncFirstFrameTimeoutMs?: number;
  vncImageQualityPreset?: string;
  vncPreferredEncoding?: string;
  vncColorDepth?: string;
  vncFrameRateLimit?: number;
  vncExpectedCertificateFingerprintSha256?: string;
}

export type SshRouteType = 'direct' | 'http_connect' | 'socks5' | 'frp_tcp' |
  'ssh_jump' | 'frp_visitor' | 'frp_stcp' | 'frp_sudp' | 'frp_xtcp';

export interface SshJumpHop {
  host: string;
  port: number;
  username: string;
  authMethod: 'password' | 'publickey' | 'kbd-interactive';
  expectedHostKeyRawBase64?: string;
  expectedHostKeyFingerprintSha256?: string;
  connectTimeoutMs: number;
}

/** Secrets are supplied only in the one-shot SSH session handoff. */
export interface SshJumpHopHandoff {
  password?: string;
  privateKeyPem?: string;
  privateKeyPassphrase?: string;
  keyboardInteractiveResponses?: string[];
}

/** Route metadata is durable; credentials remain in the one-shot handoff. */
export interface SshRoute {
  schemaVersion: number;
  type: SshRouteType;
  endpointHost: string;
  endpointPort: number;
  hops: SshJumpHop[];
  controlId?: string;
  connectTimeoutMs: number;
}

export interface SftpFileEntry {
  name: string;
  path: string;
  isDirectory: boolean;
  isSymbolicLink: boolean;
  isSpecialFile: boolean;
  size: number;
  mode: number;
  uid: number;
  gid: number;
  atime: number;
  mtime: number;
}

export interface SftpListAsyncResult {
  errorCode: number;
  transportLost?: boolean;
  entries: SftpFileEntry[];
}

export interface SftpReadAsyncResult {
  errorCode: number;
  transportLost?: boolean;
  data: ArrayBuffer;
}

export interface SftpWriteAsyncResult {
  errorCode: number;
  transportLost?: boolean;
  bytesWritten: number;
  durability?: 'durable' | 'unsupported' | 'failed';
}

export interface SftpMutationAsyncResult {
  errorCode: number;
  transportLost?: boolean;
  atomic?: boolean;
}

export interface SshForwardingConfig {
  schemaVersion?: number;
  id: string;
  mode: number; // 0=local, 1=remote, 2=dynamic
  bindHost?: string;
  bindPort: number;
  targetHost?: string;
  targetPort?: number;
  maxConnections?: number;
  enabled?: boolean;
  allowPublicBind?: boolean;
  minBindPort?: number;
  maxBindPort?: number;
  maxBytes?: number;
  expiresAtMs?: number;
}

export interface SshAuthPrompt {
  text: string;
  echo: boolean;
}

export interface SshAuthPromptRequest {
  schemaVersion: number;
  requestId: number;
  sessionId: number;
  generation: number;
  targetHost: string;
  hop: string;
  round: number;
  name: string;
  instruction: string;
  prompts: SshAuthPrompt[];
  expiresAtMs: number;
  kind: 'keyboard_interactive' | 'host_key';
  trustHostId: string;
  routeIdentity: string;
  endpointHost: string;
  endpointPort: number;
  hostKeyHopIndex: number;
  hostKeyAlgorithm: string;
  hostKeyFingerprintSha256: string;
  /** Internal persistence payload; never display or log this raw key blob. */
  hostKeyRawBase64: string;
  expectedHostKeyFingerprintSha256: string;
  hostKeyChanged: boolean;
}

export interface SshAuthPromptResponse {
  schemaVersion?: number;
  requestId: number;
  sessionId: number;
  generation: number;
  responses: string[];
  cancelled?: boolean;
}

export interface SshSessionSnapshot {
  schemaVersion: number;
  errorCode: number;
  sessionId: number;
  generation: number;
  channelId: string;
  state: number;
  stateName: string;
  eventSequence: number;
  host: string;
  port: number;
  backgroundLimited: boolean;
  lastEventType: string;
}

export interface SshEventEnvelope {
  schemaVersion: number;
  sessionId: number;
  generation: number;
  channelId: string;
  taskId: string;
  requestId: string;
  sequence: number;
  timestampMs: number;
  priority: number;
  type: string;
  payloadJson?: string;
}

export interface SshSessionEventsResult {
  schemaVersion: number;
  errorCode: number;
  sessionId: number;
  channelId: string;
  generation: number;
  afterSequence: number;
  events: SshEventEnvelope[];
}

export interface SshForwardingSnapshot {
  schemaVersion: number;
  id: string;
  mode: number;
  bindHost: string;
  bindPort: number;
  targetHost: string;
  targetPort: number;
  maxConnections: number;
  enabled: boolean;
  allowPublicBind: boolean;
  state: number; // 0=stopped, 1=starting, 2=listening, 3=stopping, 4=failed
  sessionGeneration: number;
  activeConnections: number;
  lastError: number;
  minBindPort: number;
  maxBindPort: number;
  maxBytes: number;
  ownerSessionId: number;
  ownerChannelId: string;
  ownerGeneration: number;
  transferredBytes: number;
  expiresAtMs: number;
  actualBindHost: string;
  actualBindPort: number;
  actualBindFamily: number; // 0=unknown, 2=IPv4, 10=IPv6 on OHOS/POSIX
}

export interface SshForwardingProfile {
  schemaVersion: number;
  id: string;
  mode: number;
  bindHost: string;
  bindPort: number;
  targetHost: string;
  targetPort: number;
  maxConnections: number;
  enabled: boolean;
  allowPublicBind: boolean;
  minBindPort?: number;
  maxBindPort?: number;
  maxBytes?: number;
  expiresAtMs?: number;
}

export interface SshForwardingRuntime {
  schemaVersion: number;
  id: string;
  state: number;
  sessionId: number;
  channelId: string;
  generation: number;
  activeConnections: number;
  transferredBytes: number;
  lastError: number;
}

export interface SshForwardingSnapshotsResult {
  errorCode: number;
  sessionId: number;
  sessionGeneration: number;
  snapshots: SshForwardingSnapshot[];
}

export interface SshTerminalDiagnosticsSnapshot {
  supported: boolean;
  sessionActive: boolean;
  schemaVersion: number;
  sessionId: number;
  sessionGeneration: number;
  channelId: string;
  inputEvents: number;
  inputBytes: number;
  nativeEnqueueEvents: number;
  writeAttempts: number;
  writeCompleteEvents: number;
  writeBytes: number;
  writeEagain: number;
  remoteReadEvents: number;
  remoteReadBytes: number;
  callbackAcceptedEvents: number;
  callbackAcceptedBytes: number;
  callbackQueueFull: number;
  callbackDeliveryErrors: number;
  callbackClosed: number;
  inputDuplicate: number;
  inputLoss: number;
  inputReorder: number;
  ownerStallEvents: number;
  coverageMask: number;
  coverageComplete: boolean;
  inputQueueDepth: number;
  inputQueueBytes: number;
  inputQueueMaxDepth: number;
  inputQueueMaxBytes: number;
  lastInputSequence: number;
  lastInputCapturedAtNs: number;
  lastNativeEnqueueAtNs: number;
  lastWriteAttemptAtNs: number;
  lastWriteCompleteAtNs: number;
  lastRemoteReadAtNs: number;
  maxInputToWriteAttemptNs: number;
  maxInputToWriteCompleteNs: number;
}

export interface SshTerminalInputEnqueueResult {
  accepted: boolean;
  status: 'accepted' | 'queueFull' | 'sessionClosed' | 'staleGeneration' | 'invalid';
  sequence: number;
  generation: number;
  queueDepth: number;
  queueBytes: number;
}

export interface SshCommandResult {
  errorCode: number;
  exitCode: number;
  signaled: boolean;
  signal: string;
  stdout: ArrayBuffer;
  stderr: ArrayBuffer;
}

export enum ConnectionState {
  DISCONNECTED = 0,
  CONNECTING = 1,
  CONNECTED = 2,
  RECONNECTING = 3,
  ERROR = 4,
  AUTHENTICATING = 5
}

export enum MouseButton {
  LEFT = 0,
  MIDDLE = 1,
  RIGHT = 2
}

export interface TerminalCoreCell {
  ch: string;
  fg: number;
  bg: number;
  bold: boolean;
  italic: boolean;
  underline: boolean;
  inverse: boolean;
  wide: boolean;
  wideContinuation: boolean;
}

export interface TerminalCoreSnapshot {
  cols: number;
  rows: number;
  cursorX: number;
  cursorY: number;
  cursorVisible: boolean;
  bracketedPaste: boolean;
  mouseTracking: number;
  sgrMouse: boolean;
  applicationCursorKeys: boolean;
  applicationKeypad: boolean;
  autoWrap: boolean;
  viewTop: number;
  screenTop: number;
  isAtBottom: boolean;
  dirtyRows: number[];
  cells: TerminalCoreCell[];
}

export interface TerminalCoreMode {
  bracketedPaste: boolean;
  mouseTracking: number;
  sgrMouse: boolean;
  applicationCursorKeys: boolean;
  applicationKeypad: boolean;
  autoWrap: boolean;
}

// SSH 密钥工具 (top-level 类型导出, 供 ArkTS import)
export interface GeneratedSshKeyPair {
  ok: boolean;
  privateKeyPem: string;
  publicKeyOpenSsh: string;
  fingerprintSha256: string;
  keyType: string;
  keyBits: number;
  error: string;
}

export interface SshPrivateKeyInfo {
  ok: boolean;
  keyType: string;
  publicKeyOpenSsh: string;
  fingerprintSha256: string;
  encrypted: boolean;
  error: string;
}

export interface SshPublicKeyInstallResult {
  ok: boolean;
  alreadyInstalled: boolean;
  verified: boolean;
  code: number;
  message: string;
}

export interface SshAuthTestResult {
  ok: boolean;
  code: number;
  message: string;
}

export interface SshProxyConfig {
  type?: string;
  host?: string;
  port?: number;
  username?: string;
  password?: string;
  privateKeyPem?: string;
  privateKeyPassphrase?: string;
  authMethod?: 'password' | 'publickey' | 'kbd-interactive';
  keyboardInteractiveResponses?: string[];
  expectedHostKeyRawBase64?: string;
  expectedHostKeyFingerprintSha256?: string;
}

export interface SshHostKeyInfo {
  ok: boolean;
  host: string;
  port: number;
  algorithm: string;
  fingerprintSha256: string;
  rawBase64: string;
  serverBanner: string;
  errorCode: number;
  errorMessage: string;
}
