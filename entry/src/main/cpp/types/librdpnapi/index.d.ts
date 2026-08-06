export const VERSION: SessionVersionInfo;

  export function listProtocols(): ProtocolInfo[];

  export function connect(config: SessionConfig): number;
  export function connectSshAsync(config: SessionConfig): Promise<number>;
  export function getPendingSshConnectId(): number;
  export function disconnect(sessionId: number, rendererHandle?: number,
    decoderHandle?: number, audioHandle?: number): number;
  export function beginDisconnect(sessionId: number, rendererHandle: number,
    decoderHandle: number, audioHandle: number): number;
  export function disconnectAll(rendererHandle?: number, decoderHandle?: number,
    audioHandle?: number): number;
  export function getDisconnectState(requestId: number): number;

  export function sendKey(sessionId: number, scancode: number, pressed: boolean): void;
  export function sendMouse(sessionId: number, x: number, y: number, button: number, pressed: boolean): void;
  export function sendMouseWheel(sessionId: number, x: number, y: number, delta: number): void;
  export function sendText(sessionId: number, text: string): void;
  export function enqueueSshTerminalInput(sessionId: number, text: string,
    expectedGeneration?: number, control?: boolean, ordered?: boolean,
    orderedEnd?: boolean): SshTerminalInputEnqueueResult;
  export function sendFile(sessionId: number, remotePath: string, data: ArrayBuffer): number;
  export function writeRemoteFileChunk(sessionId: number, remotePath: string, data: ArrayBuffer, offset: number, truncate: boolean): number;
  export function writeRemoteFileChunkAsync(sessionId: number, remotePath: string, data: ArrayBuffer,
    offset: number, truncate: boolean): Promise<SftpWriteAsyncResult>;
  export function listRemoteDir(sessionId: number, remotePath: string): SftpFileEntry[];
  export function listRemoteDirAsync(sessionId: number, remotePath: string): Promise<SftpListAsyncResult>;
  export function readRemoteFile(sessionId: number, remotePath: string): ArrayBuffer;
  export function readRemoteFileChunk(sessionId: number, remotePath: string, offset: number, maxLen: number): ArrayBuffer;
  export function readRemoteFileChunkAsync(sessionId: number, remotePath: string, offset: number,
    maxLen: number): Promise<SftpReadAsyncResult>;
  export function removeRemoteFile(sessionId: number, remotePath: string): number;
  export function removeRemoteFileAsync(sessionId: number, remotePath: string): Promise<SftpMutationAsyncResult>;
  export function removeRemoteDir(sessionId: number, remotePath: string): number;
  export function removeRemoteDirAsync(sessionId: number, remotePath: string): Promise<SftpMutationAsyncResult>;
  export function makeRemoteDir(sessionId: number, remotePath: string): number;
  export function makeRemoteDirAsync(sessionId: number, remotePath: string): Promise<SftpMutationAsyncResult>;
  export function renameRemotePath(sessionId: number, oldPath: string, newPath: string): number;
  export function renameRemotePathAsync(sessionId: number, oldPath: string,
    newPath: string, atomic?: boolean): Promise<SftpMutationAsyncResult>;
  export function sendClipboard(sessionId: number, data: ArrayBuffer): void;
  export function setSessionClipboardFiles(sessionId: number, paths: string[]): boolean;
  export function getSessionClipboardText(sessionId: number): string;
  export function isSessionClipboardReady(sessionId: number): boolean;

  export function getConnectionState(sessionId: number): number;
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
  export function getRemoteCursorSnapshot(sessionId: number, includePixels?: boolean): RemoteCursorSnapshot;
  export function getRemoteCursorSnapshotPixelsAsync(sessionId: number): Promise<RemoteCursorSnapshot>;
  export function getConnectionLastMessage(sessionId: number): string;
  export function submitRustDesk2FA(sessionId: number, code: string): boolean;
  export function getRustDeskLastError(): string;
  export function probeRdpCertificate(host: string, port: number, serverName: string): RdpCertificateInfo;
  export function probeRdpCertificateAsync(host: string, port: number,
    serverName: string): Promise<RdpCertificateInfo>;
  export function probeRustDeskPresenceAsync(host: string, port: number, serverKey: string,
    peerId: string, token: string, direct: boolean, keyMode: number): Promise<RustDeskPresenceResult>;
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
  export function getSessionDiagnostics(sessionId: number): RustDeskDiagnosticsSnapshot;
  export function getRustDeskDiagnostics(sessionId: number): RustDeskDiagnosticsSnapshot;
  export function replayPendingRustDeskFrame(sessionId: number): boolean;
  export function getRustDeskDisplayCapabilities(sessionId: number): RustDeskDisplayCapabilities;
  export function beginRustDeskDisplaySwitch(sessionId: number,
    display: number): RustDeskDisplaySwitchRequest;
  export function switchRustDeskDisplay(sessionId: number, display: number): boolean;
  export function changeRustDeskDisplayResolution(sessionId: number, display: number,
    width: number, height: number): boolean;
  export function sendRustDeskTouchScale(sessionId: number, scale: number): boolean;
  export function sendRustDeskTouchPan(sessionId: number, phase: number, x: number, y: number): boolean;
  export function getLocalResourceStats(includePro?: boolean): LocalResourceStats;
  export function getSessionTransferStatus(sessionId: number): SessionTransferStatus;
  export function setRdpBackgroundVideoPrewarm(sessionId: number, enabled: boolean, intervalMs: number): boolean;
  export function presentRdpCachedFrame(sessionId: number): boolean;

  export function readData(sessionId: number): string;
  export function getSshTerminalDiagnostics(sessionId: number): SshTerminalDiagnosticsSnapshot;
  export interface SshCommandResult {
    errorCode: number;
    exitCode: number;
    signaled: boolean;
    signal: string;
    stdout: ArrayBuffer;
    stderr: ArrayBuffer;
  }
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
  export function installSshPublicKey(host: string, port: number, username: string, password: string, privateKeyPem: string, passphrase: string, publicKey: string): SshPublicKeyInstallResult;
  export function testSshKeyAuth(host: string, port: number, username: string, privateKeyPem: string,
    passphrase: string, proxy?: SshProxyConfig): SshAuthTestResult;
  export function probeSshHostKey(host: string, port: number, proxy?: SshProxyConfig): SshHostKeyInfo;

  export function initRenderer(xcId: string, width: number, height: number): number;
  export function destroyRenderer(handle: number): void;
  export function renderFrame(handle: number, textureId: number): void;
  export function renderRawBGRA(handle: number, data: ArrayBuffer, width: number, height: number, stride: number): void;
  export function resizeRenderer(handle: number, width: number, height: number): void;
  export function setRendererCanvasTransform(handle: number, scale: number, panX: number, panY: number): number;
  export function testRender(handle: number): void;
  export function registerNativeXComponent(): boolean;
  export function setXComponentSurfaceId(surfaceId: string, width: number, height: number): boolean;
  export function markXComponentSurfaceDestroyed(): void;
  export function requestFrameRefresh(): void;
  export function getRendererViewport(handle: number): RendererViewport | null;
  export function bindRendererToSession(rendererHandle: number, sessionId: number): boolean;

  export function initDecoder(width: number, height: number, codecType: number,
    rendererHandle?: number): number;
  export function destroyDecoder(handle: number): void;
  export function decodeFrame(handle: number, data: ArrayBuffer, size: number, timestamp: number): number;
  export function getTextureId(handle: number): number;
  export function testDecoderH264(handle: number): number;
  export function bindVideoPipeline(decoderHandle: number, rendererHandle: number): boolean;
  export function detachVideoPipeline(decoderHandle: number): boolean;
  export function requestDecoderRecovery(decoderHandle: number): boolean;
  export function rebindActiveVideoPipeline(): boolean;

  export function initAudioPlayer(sampleRate?: number, channels?: number): number;
  export function destroyAudioPlayer(handle: number): void;
  export function setAudioMute(handle: number, mute: boolean): void;
  export function setActiveAudioMute(mute: boolean): void;
  export function isAudioPlaybackActive(): boolean;
  export function isVideoPlaybackActive(): boolean;

  export function handleKeyEvent(scancode: number, pressed: boolean, keyCode: number, modifiers: number): void;
  export function handleMouseEvent(x: number, y: number, button: number, pressed: boolean, wheelDelta: number): void;
  export function handleTouchEvent(data: object): void;

  export function getClipboardText(): string;
  export function setClipboardText(text: string): void;

  export function terminalCoreCreate(cols: number, rows: number): number;
  export function terminalCoreDestroy(handle: number): void;
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
  commonName: string;
  subject: string;
  issuer: string;
  fingerprintSha256: string;
  flags: number;
  rootTrusted: boolean;
  hostMismatch: boolean;
  errorCode: number;
  errorMessage: string;
}

export interface RustDeskPresenceResult {
  state: number;
  latencyMs: number;
  errorCode: number;
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

export interface RdpRenderStats {
  paintCount: number;
  renderedPaintCount: number;
  firstPaintMs: number;
  lastPaintMs: number;
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
  gfxChannelConnected: boolean;
  inputQueueDepth: number;
  inputQueueMax: number;
  inputTextUnits: number;
  inputDroppedMouseMoves: number;
  inputNonDisposableOverflow: number;
  graphicsMode: string;
}

export interface RustDeskDiagnosticsSnapshot {
  supported: boolean;
  sessionActive: boolean;
  protocolSnapshotAvailable: boolean;
  videoSeen: boolean;
  receivedRateAvailable: boolean;
  presentedRateAvailable: boolean;
  decodeRateAvailable: boolean;
  sessionId: number;
  latencyMs: number;
  targetBitrateKbps: number;
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
  inputBlocked: boolean;
  width: number;
  height: number;
  originalWidth: number;
  originalHeight: number;
  scaleMilli: number;
  geometryEpoch: number;
  resolutions: RustDeskDisplayResolution[];
  displays: RustDeskDisplayInfo[];
}

export interface RustDeskDisplaySwitchRequest {
  accepted: boolean;
  generation: number;
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
  /** True only for the RustDesk controller-side bootstrap arrow. */
  fallbackShape: boolean;
  protocolShapeAvailable: boolean;
  positionAvailable: boolean;
  visible: boolean;
  shapeRevision: number;
  positionRevision: number;
  visibilityRevision: number;
  rgba: ArrayBuffer;
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
  domain: string;
  codec: string;
  multiMonitor: boolean;
  monitorCount: number;
  colorDepth: number;
  rdpAuthIdentityMode?: number; // 0=MicrosoftAccount\email, 1=domain MicrosoftAccount, 2=bare email, 3=.\AzureAD\email, 4=domain AzureAD
  rdpAuthMode?: 'password' | 'blank_password' | 'restricted_admin';
  rdpRestrictedAdminSecretSource?: 'ntlm_hash';
  // Transient only. Never persist this value in RemoteHost or a cloud payload.
  rdpRestrictedAdminHash?: string;
  authMethod: string;
  privateKeyPem: string;
  privateKeyPassphrase: string;
  keyboardInteractiveResponses?: string[];
  sshProxyType?: 'direct' | 'http_connect' | 'socks5' | 'frp_tcp' | 'frp_visitor' |
    'frp_stcp' | 'frp_sudp' | 'frp_xtcp' | 'ssh_jump' | 'legacy_gateway';
  sshProxyHost?: string;
  sshProxyPort?: number;
  sshProxyUsername?: string;
  sshProxyPassword?: string;
  expectedHostKeyRawBase64?: string;
  expectedHostKeyFingerprintSha256?: string;
  sshJumpHostKeyRawBase64?: string;
  sshJumpHostKeyFingerprintSha256?: string;
  expectedRdpCertificateFingerprintSha256?: string;
  rdpAllowUntrustedRoot?: boolean;
  rdpAllowHostMismatch?: boolean;
  // RustDesk 扩展字段
  rdImageQuality?: number;   // 0=fast, 1=balanced, 2=quality
  rdDirectIp?: boolean;      // 直连IP模式
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
  entries: SftpFileEntry[];
}

export interface SftpReadAsyncResult {
  errorCode: number;
  data: ArrayBuffer;
}

export interface SftpWriteAsyncResult {
  errorCode: number;
  bytesWritten: number;
  durability?: 'durable' | 'unsupported' | 'failed';
}

export interface SftpMutationAsyncResult {
  errorCode: number;
  atomic?: boolean;
}

export interface SshForwardingConfig {
  id: string;
  mode: number; // 0=local, 1=remote, 2=dynamic
  bindHost?: string;
  bindPort: number;
  targetHost?: string;
  targetPort?: number;
  maxConnections?: number;
  enabled?: boolean;
  allowPublicBind?: boolean;
}

export interface SshForwardingSnapshot {
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

export enum ConnectionState {
  DISCONNECTED = 0,
  CONNECTING = 1,
  CONNECTED = 2,
  RECONNECTING = 3,
  ERROR = 4
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
