declare module 'librdpnapi.so' {
  export const VERSION: SessionVersionInfo;

  export function listProtocols(): ProtocolInfo[];

  export function connect(config: SessionConfig): number;
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
  export function sendFile(sessionId: number, remotePath: string, data: ArrayBuffer): number;
  export function writeRemoteFileChunk(sessionId: number, remotePath: string, data: ArrayBuffer, offset: number, truncate: boolean): number;
  export function listRemoteDir(sessionId: number, remotePath: string): SftpFileEntry[];
  export function readRemoteFile(sessionId: number, remotePath: string): ArrayBuffer;
  export function readRemoteFileChunk(sessionId: number, remotePath: string, offset: number, maxLen: number): ArrayBuffer;
  export function removeRemoteFile(sessionId: number, remotePath: string): number;
  export function removeRemoteDir(sessionId: number, remotePath: string): number;
  export function makeRemoteDir(sessionId: number, remotePath: string): number;
  export function renameRemotePath(sessionId: number, oldPath: string, newPath: string): number;
  export function sendClipboard(sessionId: number, data: ArrayBuffer): void;
  export function setSessionClipboardFiles(sessionId: number, paths: string[]): boolean;
  export function getSessionClipboardText(sessionId: number): string;
  export function isSessionClipboardReady(sessionId: number): boolean;

  export function getConnectionState(sessionId: number): number;
  export function getRemoteCursorSnapshot(sessionId: number, includePixels?: boolean): RemoteCursorSnapshot;
  export function getConnectionLastMessage(sessionId: number): string;
  export function getRustDeskLastError(): string;
  export function probeRdpCertificate(host: string, port: number, serverName: string): RdpCertificateInfo;
  export function probeRdpCertificateAsync(host: string, port: number,
    serverName: string): Promise<RdpCertificateInfo>;
  export function getRdpRenderStats(sessionId: number): RdpRenderStats;
  export function getSessionTransferStatus(sessionId: number): SessionTransferStatus;
  export function setRdpBackgroundVideoPrewarm(sessionId: number, enabled: boolean, intervalMs: number): boolean;
  export function presentRdpCachedFrame(sessionId: number): boolean;

  export function readData(sessionId: number): string;
  export function resizePty(sessionId: number, cols: number, rows: number): void;
  export function measureSshLatency(sessionId: number): number;
  export function setOnDataCallback(sessionId: number, cb: ((data: string) => void) | null): void;
  export function setHelperSocketPath(socketPath: string, binPath: string): void;

  // SSH 密钥工具 (函数声明)
  export function generateSshKeyPair(keyType: string, bits: number, comment: string, passphrase: string): GeneratedSshKeyPair;
  export function inspectSshPrivateKey(privateKeyPem: string, passphrase: string): SshPrivateKeyInfo;
  export function changeSshPrivateKeyPassphrase(privateKeyPem: string, oldPassphrase: string, newPassphrase: string): string;
  export function validatePublicKeyForAuthorizedKeys(publicKeyOpenSsh: string): boolean;
  export function installSshPublicKey(host: string, port: number, username: string, password: string, privateKeyPem: string, passphrase: string, publicKey: string): SshPublicKeyInstallResult;
  export function testSshKeyAuth(host: string, port: number, username: string, privateKeyPem: string, passphrase: string): SshAuthTestResult;
  export function probeSshHostKey(host: string, port: number): SshHostKeyInfo;

  export function initRenderer(xcId: string, width: number, height: number): number;
  export function destroyRenderer(handle: number): void;
  export function renderFrame(handle: number, textureId: number): void;
  export function renderRawBGRA(handle: number, data: ArrayBuffer, width: number, height: number, stride: number): void;
  export function resizeRenderer(handle: number, width: number, height: number): void;
  export function testRender(handle: number): void;
  export function registerNativeXComponent(): boolean;
  export function setXComponentSurfaceId(surfaceId: string, width: number, height: number): boolean;
  export function markXComponentSurfaceDestroyed(): void;
  export function requestFrameRefresh(): void;
  export function getRendererViewport(handle: number): RendererViewport | null;

  export function initDecoder(width: number, height: number, codecType: number): number;
  export function destroyDecoder(handle: number): void;
  export function decodeFrame(handle: number, data: ArrayBuffer, size: number, timestamp: number): number;
  export function getTextureId(handle: number): number;
  export function testDecoderH264(handle: number): number;
  export function bindVideoPipeline(decoderHandle: number, rendererHandle: number): boolean;
  export function detachVideoPipeline(decoderHandle: number): boolean;
  export function requestDecoderRecovery(decoderHandle: number): boolean;

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
  export function terminalCoreResize(handle: number, cols: number, rows: number): void;
  export function terminalCoreScrollView(handle: number, deltaLines: number): void;
  export function terminalCoreScrollToBottom(handle: number): void;
  export function terminalCoreSnapshot(handle: number): TerminalCoreSnapshot;
  export function terminalCoreDirtySnapshot(handle: number): TerminalCoreSnapshot;
}

interface SessionVersionInfo {
  moduleName: string;
  version: string;
  apiVersion: number;
  buildType: string;
}

interface ProtocolInfo {
  name: string;
  displayName: string;
  port: number;
  version: string;
}

export interface RendererViewport {
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

export interface RemoteCursorSnapshot {
  sessionId: number;
  protocol: string;
  shapeId: number;
  x: number;
  y: number;
  width: number;
  height: number;
  hotX: number;
  hotY: number;
  visible: boolean;
  shapeRevision: number;
  positionRevision: number;
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
  authMethod: string;
  privateKeyPem: string;
  privateKeyPassphrase: string;
  expectedHostKeyRawBase64?: string;
  expectedHostKeyFingerprintSha256?: string;
  expectedRdpCertificateFingerprintSha256?: string;
  rdpAllowUntrustedRoot?: boolean;
  rdpAllowHostMismatch?: boolean;
  // RustDesk 扩展字段
  rdImageQuality?: number;   // 0=fast, 1=balanced, 2=quality
  rdDirectIp?: boolean;      // 直连IP模式
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
  rdServerKey?: string;      // Rendezvous 服务器公钥
}

export interface SftpFileEntry {
  name: string;
  path: string;
  isDirectory: boolean;
  size: number;
  mtime: number;
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
  viewTop: number;
  screenTop: number;
  isAtBottom: boolean;
  dirtyRows: number[];
  cells: TerminalCoreCell[];
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
