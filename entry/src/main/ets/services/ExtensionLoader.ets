/**
 * ExtensionLoader.ets — NAPI 桥接门面
 *
 * 对接 librdpnapi.so 的 C++ ExtensionSystem
 */
import rdpnapi from 'librdpnapi.so';
import {
  Avc420DecoderProbeResult,
  SessionConfig,
  SftpFileEntry,
  GeneratedSshKeyPair,
  SshPrivateKeyInfo,
  SshPublicKeyInstallResult,
  SshAuthTestResult,
  SshHostKeyInfo,
  RdpCertificateInfo,
  RdpRenderStats,
  SessionTransferStatus
} from '../types/rdpnapi';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ExtensionResult,
  ExtensionErrorCode,
  NativeSessionSnapshot,
  okResult,
  okVoid,
  errResult
} from './ExtensionResult';
import { shouldBindSurfaceBeforeForegroundRenderer } from './RemoteForegroundRestorePolicy';

const TAG = 'ExtensionLoader';
const DOMAIN = 0x0013;

export class ExtensionLoader {
  private static instance: ExtensionLoader;
  private currentSessionId: number = -1;
  private rendererHandle: number = -1;
  private decoderHandle: number = -1;
  private audioPlayerHandle: number = -1;
  private teardownRequestId: number = 0;

  static getInstance(): ExtensionLoader {
    if (!ExtensionLoader.instance) { ExtensionLoader.instance = new ExtensionLoader(); }
    return ExtensionLoader.instance;
  }

  // ====== 协议连接 ======

  connect(config: SessionConfig): number {
    try {
      this.currentSessionId = rdpnapi.connect(config) as number;
      return this.currentSessionId;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] connect: code=' + ((err as Record<string, Object>)['code'] || 'ERR') + ' msg=' + JSON.stringify(err));
      return -1;
    }
  }

  disconnect(): number {
    let requestId: number = 0;
    try {
      if (this.currentSessionId > 0 || this.rendererHandle > 0 ||
        this.decoderHandle > 0 || this.audioPlayerHandle > 0) {
        requestId = rdpnapi.beginDisconnect(this.currentSessionId, this.rendererHandle,
          this.decoderHandle, this.audioPlayerHandle) as number;
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] disconnect: ' + JSON.stringify(err));
    }
    this.currentSessionId = -1;
    this.rendererHandle = -1;
    this.decoderHandle = -1;
    this.audioPlayerHandle = -1;
    if (requestId > 0) {
      this.teardownRequestId = requestId;
    }
    return requestId;
  }

  disconnectAll(): number {
    let requestId: number = 0;
    try {
      requestId = rdpnapi.disconnectAll(
        this.rendererHandle, this.decoderHandle, this.audioPlayerHandle) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] disconnectAll: ' + JSON.stringify(err));
    }
    this.currentSessionId = -1;
    this.rendererHandle = -1;
    this.decoderHandle = -1;
    this.audioPlayerHandle = -1;
    if (requestId > 0) {
      this.teardownRequestId = requestId;
    }
    return requestId;
  }

  getDisconnectState(requestId: number): number {
    try {
      return rdpnapi.getDisconnectState(requestId) as number;
    } catch (_err) {
      return 0;
    }
  }

  async waitForPendingTeardown(timeoutMs: number = 10000): Promise<boolean> {
    if (this.teardownRequestId <= 0) {
      return true;
    }
    const startedAtMs: number = Date.now();
    while (Date.now() - startedAtMs < timeoutMs) {
      const state: number = this.getDisconnectState(this.teardownRequestId);
      if (state === 3 || state === 0) {
        this.teardownRequestId = 0;
        return true;
      }
      if (state === 4) {
        return false;
      }
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 20);
      });
    }
    return false;
  }

  isConnected(): boolean { return this.currentSessionId > 0; }

  getSessionTransferStatus(sessionId: number): SessionTransferStatus {
    try {
      return rdpnapi.getSessionTransferStatus(sessionId) as SessionTransferStatus;
    } catch (_err) {
      return { rdpDriveMounted: false, rustdeskTransferState: 0, transferId: 0,
        transferredBytes: 0, totalBytes: 0, diagnosticCode: 'status_unavailable' };
    }
  }

  getSessionId(): number { return this.currentSessionId; }

  probeRdpCertificate(host: string, port: number, serverName: string): RdpCertificateInfo {
    try {
      return rdpnapi.probeRdpCertificate(host, port, serverName) as RdpCertificateInfo;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] probeRdpCertificate: ' + JSON.stringify(err));
      return {
        ok: false,
        host,
        port,
        commonName: '',
        subject: '',
        issuer: '',
        fingerprintSha256: '',
        flags: 0,
        rootTrusted: false,
        hostMismatch: false,
        errorCode: -1,
        errorMessage: 'RDP 证书探测异常'
      };
    }
  }

  async probeRdpCertificateAsync(host: string, port: number, serverName: string): Promise<RdpCertificateInfo> {
    try {
      return await rdpnapi.probeRdpCertificateAsync(host, port, serverName) as RdpCertificateInfo;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] probeRdpCertificateAsync: ' + JSON.stringify(err));
      return {
        ok: false,
        host,
        port,
        commonName: '',
        subject: '',
        issuer: '',
        fingerprintSha256: '',
        flags: 0,
        rootTrusted: false,
        hostMismatch: false,
        errorCode: -1,
        errorMessage: 'RDP 证书探测异常 [E-RDP-CERT-ASYNC]'
      };
    }
  }

  getRdpRenderStats(sessionId: number): RdpRenderStats {
    try {
      return rdpnapi.getRdpRenderStats(sessionId) as RdpRenderStats;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] getRdpRenderStats: ' + JSON.stringify(err));
      return {
        paintCount: 0,
        renderedPaintCount: 0,
        firstPaintMs: 0,
        lastPaintMs: 0,
        lastRenderResult: -1,
        skippedPaintCount: 0,
        slowRenderCount: 0,
        minRenderIntervalUs: 0,
        lastRenderCostUs: 0,
        lastRenderBytes: 0,
        pumpSubmitted: 0,
        pumpRendered: 0,
        pumpReplaced: 0,
        pumpRejected: 0,
        invalidEvents: 0,
        invalidPixels: 0,
        copiedBytes: 0,
        presentationRejected: 0,
        surfaceDetachedRejections: 0,
        generationRejections: 0,
        presentationWindowSamples: 0,
        callbackP50Us: 0,
        callbackP95Us: 0,
        callbackMaxUs: 0,
        copyP50Us: 0,
        copyP95Us: 0,
        copyMaxUs: 0,
        queueP50Us: 0,
        queueP95Us: 0,
        queueMaxUs: 0,
        uploadP50Us: 0,
        uploadP95Us: 0,
        uploadMaxUs: 0,
        drawP50Us: 0,
        drawP95Us: 0,
        drawMaxUs: 0,
        swapP50Us: 0,
        swapP95Us: 0,
        swapMaxUs: 0,
        workerP50Us: 0,
        workerP95Us: 0,
        workerMaxUs: 0,
        glUploadGateDecision: 0,
        glUploadEvaluatedSamples: 0,
        glUploadSwapP95Us: 0,
        glUploadSharePermille: 0,
        desktopWidth: 0,
        desktopHeight: 0,
        graphicsEpoch: 0,
        desktopResizeCount: 0,
        desktopResizeFailures: 0,
        gfxChannelConnected: false,
        inputQueueDepth: 0,
        inputQueueMax: 0,
        inputTextUnits: 0,
        inputDroppedMouseMoves: 0,
        inputNonDisposableOverflow: 0,
        graphicsMode: 'unknown',
        h264Avc420Enabled: false,
        h264Avc444Enabled: false,
        h264DirectTextureEnabled: false,
        h264PerformanceGainPermille: 0,
        h264Avc420Reason: 'stats-unavailable',
        h264Avc444Reason: 'stats-unavailable',
        h264DirectTextureReason: 'stats-unavailable'
      };
    }
  }

  // ====== 渲染管线 ======

  initRenderer(xcId: string, w: number, h: number): number {
    try {
      this.rendererHandle = rdpnapi.initRenderer(xcId, w, h) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] initRenderer: ' + JSON.stringify(err));
      this.rendererHandle = -1;
    }
    return this.rendererHandle;
  }

  destroyRenderer(): void {
    try { rdpnapi.destroyRenderer(this.rendererHandle); } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] destroyRenderer: ' + JSON.stringify(err));
    }
    this.rendererHandle = -1;
  }

  initDecoder(w: number, h: number, c: number, rendererHandle: number): number {
    try {
      this.decoderHandle = rdpnapi.initDecoder(w, h, c, rendererHandle) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] initDecoder: ' + JSON.stringify(err));
      this.decoderHandle = -1;
    }
    return this.decoderHandle;
  }

  destroyDecoder(): void {
    try { rdpnapi.destroyDecoder(this.decoderHandle); } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] destroyDecoder: ' + JSON.stringify(err));
    }
    this.decoderHandle = -1;
  }

  decodeFrame(handle: number, data: ArrayBuffer, size: number, timestamp: number): number {
    try {
      return rdpnapi.decodeFrame(handle, data, size, timestamp) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] decodeFrame: ' + JSON.stringify(err));
      return -1;
    }
  }

  getTextureId(handle: number): number {
    try {
      return rdpnapi.getTextureId(handle) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] getTextureId: ' + JSON.stringify(err));
      return 0;
    }
  }

  probeAvc420Decoder(rendererHandle: number): Avc420DecoderProbeResult {
    return rdpnapi.probeAvc420Decoder(rendererHandle) as Avc420DecoderProbeResult;
  }

  getRendererHandle(): number { return this.rendererHandle; }
  getDecoderHandle(): number { return this.decoderHandle; }

  // ====== 渲染管线操作 ======

  bindVideoPipeline(decoderHandle: number, rendererHandle: number): boolean {
    try {
      return rdpnapi.bindVideoPipeline(decoderHandle, rendererHandle) as boolean;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] bindVideoPipeline: ' + JSON.stringify(err));
      return false;
    }
  }

  detachVideoPipelineForBackground(): boolean {
    if (this.decoderHandle <= 0) {
      return false;
    }
    try {
      const ok = rdpnapi.detachVideoPipeline(this.decoderHandle) as boolean;
      hilog.info(DOMAIN, TAG, '[ExtensionLoader] detachVideoPipelineForBackground: ' + ok.toString());
      return ok;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] detachVideoPipelineForBackground: ' + JSON.stringify(err));
      return false;
    }
  }

  requestDecoderRecovery(): boolean {
    if (this.decoderHandle <= 0) {
      return false;
    }
    try {
      const ok = rdpnapi.requestDecoderRecovery(this.decoderHandle) as boolean;
      hilog.info(DOMAIN, TAG, '[ExtensionLoader] requestDecoderRecovery: ' + ok.toString());
      return ok;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] requestDecoderRecovery: ' + JSON.stringify(err));
      return false;
    }
  }

  renderFrame(handle: number, textureId: number): void {
    try {
      rdpnapi.renderFrame(handle, textureId);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] renderFrame: ' + JSON.stringify(err));
    }
  }

  resizeRenderer(handle: number, width: number, height: number): void {
    try {
      rdpnapi.resizeRenderer(handle, width, height);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] resizeRenderer: ' + JSON.stringify(err));
    }
  }

  getRendererViewport(handle: number): Record<string, number> | null {
    try {
      return rdpnapi.getRendererViewport(handle) as Record<string, number> | null;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] getRendererViewport: ' + JSON.stringify(err));
      return null;
    }
  }

  // ====== 统一输入处理 ======

  handleKeyEvent(scancode: number, pressed: boolean, keyCode: number, modifiers: number): void {
    try {
      rdpnapi.handleKeyEvent(scancode, pressed, keyCode, modifiers);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] handleKeyEvent: ' + JSON.stringify(err));
    }
  }

  handleMouseEvent(x: number, y: number, button: number, pressed: boolean, wheelDelta: number): void {
    try {
      rdpnapi.handleMouseEvent(x, y, button, pressed, wheelDelta);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] handleMouseEvent: ' + JSON.stringify(err));
    }
  }

  handleTouchEvent(data: object): void {
    try {
      rdpnapi.handleTouchEvent(data);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] handleTouchEvent: ' + JSON.stringify(err));
    }
  }

  // ====== 音频 ======

  sendKey(sessionId: number, scancode: number, pressed: boolean): void {
    try {
      rdpnapi.sendKey(sessionId, scancode, pressed);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] sendKey: ' + JSON.stringify(err));
    }
  }

  sendMouse(sessionId: number, x: number, y: number, button: number, pressed: boolean): void {
    try {
      rdpnapi.sendMouse(sessionId, x, y, button, pressed);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] sendMouse: ' + JSON.stringify(err));
    }
  }

  sendMouseWheel(sessionId: number, x: number, y: number, delta: number): void {
    try {
      rdpnapi.sendMouseWheel(sessionId, x, y, delta);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] sendMouseWheel: ' + JSON.stringify(err));
    }
  }

  initAudioPlayer(sr?: number, ch?: number): number {
    try {
      this.audioPlayerHandle = rdpnapi.initAudioPlayer(sr ?? 48000, ch ?? 2) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] initAudioPlayer: ' + JSON.stringify(err));
      this.audioPlayerHandle = -1;
    }
    return this.audioPlayerHandle;
  }

  destroyAudioPlayer(): void {
    if (this.audioPlayerHandle <= 0) {
      this.audioPlayerHandle = -1;
      return;
    }
    try { rdpnapi.destroyAudioPlayer(this.audioPlayerHandle); } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] destroyAudioPlayer: ' + JSON.stringify(err));
    }
    this.audioPlayerHandle = -1;
  }

  /**
   * 获取当前音频播放器句柄。
   * @returns audioPlayerHandle, 未初始化时返回 -1
   */
  getAudioPlayerHandle(): number {
    return this.audioPlayerHandle;
  }

  /**
   * 设置远端音频静音状态。
   * 由实况窗播控中心 play/pause 命令触发。
   * @param handle audioPlayer 句柄
   * @param mute true=静音, false=取消静音
   */
  setAudioMute(handle: number, mute: boolean): void {
    try {
      if (handle > 0) {
        rdpnapi.setAudioMute(handle, mute);
      } else {
        rdpnapi.setActiveAudioMute(mute);
      }
      hilog.info(DOMAIN, TAG, '[ExtensionLoader] setAudioMute: handle=' +
        handle.toString() + ' mute=' + (mute ? 'true' : 'false'));
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] setAudioMute: ' + JSON.stringify(err));
    }
  }

  // ====== 剪贴板 ======

  getClipboardText(): string {
    try { return rdpnapi.getClipboardText() as string; } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] getClipboardText: ' + JSON.stringify(err));
      return '';
    }
  }

  setClipboardText(text: string): void {
    try { rdpnapi.setClipboardText(text); } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] setClipboardText: ' + JSON.stringify(err));
    }
  }

  getSessionClipboardText(sessionId: number): string {
    try { return rdpnapi.getSessionClipboardText(sessionId) as string; } catch (_err) { return ''; }
  }
  isSessionClipboardReady(sessionId: number): boolean {
    try { return rdpnapi.isSessionClipboardReady(sessionId) as boolean; } catch (_err) { return false; }
  }

  // ====== SSH 终端专用 ======

  sendData(sessionId: number, data: string): void {
    try {
      rdpnapi.sendText(sessionId, data);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] sendData: ' + JSON.stringify(err));
    }
  }

  sendText(sessionId: number, text: string): void {
    try {
      rdpnapi.sendText(sessionId, text);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] sendText: ' + JSON.stringify(err));
    }
  }

  sendFile(sessionId: number, remotePath: string, data: ArrayBuffer): number {
    try {
      return rdpnapi.sendFile(sessionId, remotePath, data) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] sendFile: ' + JSON.stringify(err));
      return -1;
    }
  }

  writeRemoteFileChunk(sessionId: number, remotePath: string, data: ArrayBuffer, offset: number, truncate: boolean): number {
    try {
      return rdpnapi.writeRemoteFileChunk(sessionId, remotePath, data, offset, truncate) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] writeRemoteFileChunk: ' + JSON.stringify(err));
      return -1;
    }
  }

  listRemoteDir(sessionId: number, remotePath: string): SftpFileEntry[] {
    try {
      return rdpnapi.listRemoteDir(sessionId, remotePath) as SftpFileEntry[];
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] listRemoteDir: ' + JSON.stringify(err));
      return [];
    }
  }

  readRemoteFile(sessionId: number, remotePath: string): ArrayBuffer {
    try {
      return rdpnapi.readRemoteFile(sessionId, remotePath) as ArrayBuffer;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] readRemoteFile: ' + JSON.stringify(err));
      return new ArrayBuffer(0);
    }
  }

  readRemoteFileChunk(sessionId: number, remotePath: string, offset: number, maxLen: number): ArrayBuffer {
    try {
      return rdpnapi.readRemoteFileChunk(sessionId, remotePath, offset, maxLen) as ArrayBuffer;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] readRemoteFileChunk: ' + JSON.stringify(err));
      return new ArrayBuffer(0);
    }
  }

  removeRemoteFile(sessionId: number, remotePath: string): number {
    try {
      return rdpnapi.removeRemoteFile(sessionId, remotePath) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] removeRemoteFile: ' + JSON.stringify(err));
      return -1;
    }
  }

  removeRemoteDir(sessionId: number, remotePath: string): number {
    try {
      return rdpnapi.removeRemoteDir(sessionId, remotePath) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] removeRemoteDir: ' + JSON.stringify(err));
      return -1;
    }
  }

  makeRemoteDir(sessionId: number, remotePath: string): number {
    try {
      return rdpnapi.makeRemoteDir(sessionId, remotePath) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] makeRemoteDir: ' + JSON.stringify(err));
      return -1;
    }
  }

  renameRemotePath(sessionId: number, oldPath: string, newPath: string): number {
    try {
      return rdpnapi.renameRemotePath(sessionId, oldPath, newPath) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] renameRemotePath: ' + JSON.stringify(err));
      return -1;
    }
  }

  sendClipboard(sessionId: number, data: ArrayBuffer): void {
    try {
      rdpnapi.sendClipboard(sessionId, data);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] sendClipboard: ' + JSON.stringify(err));
    }
  }

  setSessionClipboardFiles(sessionId: number, paths: string[]): boolean {
    try {
      return rdpnapi.setSessionClipboardFiles(sessionId, paths) as boolean;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] setSessionClipboardFiles: ' + JSON.stringify(err));
      return false;
    }
  }

  readData(sessionId: number): string {
    try {
      const result: string = rdpnapi.readData(sessionId) as string;
      return result || '';
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] readData: ' + JSON.stringify(err));
      return '';
    }
  }

  getConnectionState(sessionId: number): number {
    try {
      return rdpnapi.getConnectionState(sessionId) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] getConnectionState: ' + JSON.stringify(err));
      return 0;
    }
  }

  getConnectionLastMessage(sessionId: number): string {
    try {
      const result: string = rdpnapi.getConnectionLastMessage(sessionId) as string;
      return result || '';
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] getConnectionLastMessage: ' + JSON.stringify(err));
      return '';
    }
  }

  getRustDeskLastError(): string {
    try {
      const result: string = rdpnapi.getRustDeskLastError() as string;
      return result || '';
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] getRustDeskLastError: ' + JSON.stringify(err));
      return '';
    }
  }

  resizePty(sessionId: number, cols: number, rows: number): void {
    try {
      rdpnapi.resizePty(sessionId, cols, rows);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] resizePty: ' + JSON.stringify(err));
    }
  }

  measureSshLatency(sessionId: number): number {
    try {
      return rdpnapi.measureSshLatency(sessionId) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] measureSshLatency: ' + JSON.stringify(err));
      return -1;
    }
  }

  /**
   * 注册推送式 SSH 数据回调.
   * 后台 reader 线程读到数据后立即触发 cb(data).
   * 传 null 卸载.
   */
  setOnDataCallback(sessionId: number, cb: ((data: string) => void) | null): void {
    try {
      rdpnapi.setOnDataCallback(sessionId, cb);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] setOnDataCallback: ' + JSON.stringify(err));
    }
  }

  setHelperSocketPath(socketPath: string, binPath: string): void {
    try {
      rdpnapi.setHelperSocketPath(socketPath, binPath);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] setHelperSocketPath: ' + JSON.stringify(err));
    }
  }

  // ====== SSH 密钥工具 ======

  /**
   * 生成标准 SSH 密钥对 (Ed25519 / RSA 4096)
   * @param keyType "ed25519" | "rsa"
   * @param bits 256 (ed25519) | 4096 (rsa)
   * @param comment 公钥注释
   * @param passphrase 私钥加密密码 (""=无密码)
   */
  generateSshKeyPair(keyType: string, bits: number, comment: string, passphrase: string): GeneratedSshKeyPair {
    try {
      return rdpnapi.generateSshKeyPair(keyType, bits, comment, passphrase) as GeneratedSshKeyPair;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] generateSshKeyPair: ' + JSON.stringify(err));
      return { ok: false, privateKeyPem: '', publicKeyOpenSsh: '', fingerprintSha256: '',
                keyType: '', keyBits: 0, error: '[CC-SSHKEYTOOL-01] generateSshKeyPair NAPI error: ' + JSON.stringify(err) };
    }
  }

  /**
   * 解析/检测 OpenSSH 私钥
   * @param privateKeyPem PEM 格式私钥
   * @param passphrase 解密密码 (""=尝试无密码)
   */
  inspectSshPrivateKey(privateKeyPem: string, passphrase: string): SshPrivateKeyInfo {
    try {
      return rdpnapi.inspectSshPrivateKey(privateKeyPem, passphrase) as SshPrivateKeyInfo;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] inspectSshPrivateKey: ' + JSON.stringify(err));
      return { ok: false, keyType: '', publicKeyOpenSsh: '', fingerprintSha256: '',
                encrypted: false, error: '[CC-SSHKEYTOOL-02] inspectSshPrivateKey NAPI error: ' + JSON.stringify(err) };
    }
  }

  /**
   * 修改或移除私钥 passphrase
   * @return 新 PEM; 失败返回 ""
   */
  changeSshPrivateKeyPassphrase(privateKeyPem: string, oldPassphrase: string, newPassphrase: string): string {
    try {
      return rdpnapi.changeSshPrivateKeyPassphrase(privateKeyPem, oldPassphrase, newPassphrase) as string;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] changeSshPrivateKeyPassphrase: ' + JSON.stringify(err));
      return '';
    }
  }

  /**
   * 校验 authorized_keys 公钥行安全性
   */
  validatePublicKeyForAuthorizedKeys(publicKeyOpenSsh: string): boolean {
    try {
      return rdpnapi.validatePublicKeyForAuthorizedKeys(publicKeyOpenSsh) as boolean;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] validatePublicKeyForAuthorizedKeys: ' + JSON.stringify(err));
      return false;
    }
  }

  /**
   * 安装公钥到远端服务器 (同步阻塞, 2-5秒, 调用方应显示 loading)
   */
  installSshPublicKey(host: string, port: number, username: string, password: string,
                      privateKeyPem: string, passphrase: string,
                      publicKey: string): SshPublicKeyInstallResult {
    try {
      return rdpnapi.installSshPublicKey(host, port, username, password,
                                          privateKeyPem, passphrase, publicKey) as SshPublicKeyInstallResult;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] installSshPublicKey: ' + JSON.stringify(err));
      return { ok: false, alreadyInstalled: false, verified: false, code: -99,
               message: '[CC-SSHKEY-07] installSshPublicKey NAPI error: ' + JSON.stringify(err) };
    }
  }

  /**
   * 测试 SSH 密钥认证是否可用 (同步阻塞)
   */
  testSshKeyAuth(host: string, port: number, username: string,
                 privateKeyPem: string, passphrase: string): SshAuthTestResult {
    try {
      return rdpnapi.testSshKeyAuth(host, port, username, privateKeyPem, passphrase) as SshAuthTestResult;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] testSshKeyAuth: ' + JSON.stringify(err));
      return { ok: false, code: -99,
               message: '[CC-SSHKEY-08] testSshKeyAuth NAPI error: ' + JSON.stringify(err) };
    }
  }

  /**
   * 探测 SSH 主机公钥 (仅 TCP + KEX, 不做用户认证)
   * 同步阻塞 1-5s, 调用方应显示 loading 状态
   */
  probeSshHostKey(host: string, port: number): SshHostKeyInfo {
    try {
      return rdpnapi.probeSshHostKey(host, port) as SshHostKeyInfo;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] probeSshHostKey: ' + JSON.stringify(err));
      return {
        ok: false, host: host, port: port, algorithm: '',
        fingerprintSha256: '', rawBase64: '', serverBanner: '',
        errorCode: -99,
        errorMessage: '[CC-SSH-09] probeSshHostKey NAPI error: ' + JSON.stringify(err)
      };
    }
  }

  // ====== 后台连续性 API (T-234) ======

  /**
   * 获取当前会话快照。
   * 纯 ArkTS 侧查询, 不走 NAPI。
   */
  getSessionSnapshot(): ExtensionResult<NativeSessionSnapshot> {
    if (this.currentSessionId <= 0) {
      return errResult(ExtensionErrorCode.ERR_NO_ACTIVE_SESSION, '无活跃会话');
    }
    const snapshot: NativeSessionSnapshot = {
      sessionId: this.currentSessionId,
      rendererReady: this.rendererHandle > 0,
      decoderReady: this.decoderHandle > 0,
      audioActive: this.audioPlayerHandle > 0,
      protocolConnected: true,
      connectionState: 0,
      lastMessage: ''
    };
    // 尝试获取 native 侧额外状态 (best-effort)
    try {
      snapshot.connectionState = rdpnapi.getConnectionState(this.currentSessionId) as number;
      snapshot.lastMessage = rdpnapi.getConnectionLastMessage(this.currentSessionId) as string;
    } catch (_e) {
      // native 状态查询失败不影响主结果
    }
    return okResult(snapshot);
  }

  /**
   * 后台脱附渲染 (不触碰协议连接和音频)。
   * Home 后台时 XComponent surface 可能仍然存活，只释放 renderer/EGL 资源。
   */
  detachRenderForBackground(): ExtensionResult<void> {
    if (this.rendererHandle <= 0) {
      return errResult(ExtensionErrorCode.ERR_RENDER_NOT_ATTACHED,
        '渲染器未附加, 无法脱附', 'rendererHandle=' + this.rendererHandle.toString());
    }
    try {
      rdpnapi.destroyRenderer(this.rendererHandle);
      this.rendererHandle = -1;
      hilog.info(DOMAIN, TAG, '[ExtensionLoader] detachRenderForBackground: OK');
      return okVoid();
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] detachRenderForBackground: ' + JSON.stringify(err));
      return errResult(ExtensionErrorCode.ERR_NATIVE_CALL_FAILED,
        '脱附渲染失败', JSON.stringify(err));
    }
  }

  /**
   * 前台恢复渲染。
   * 重新初始化 renderer 并绑定 surface。
   */
  reattachRenderForForeground(surfaceId: string, width: number,
    height: number): ExtensionResult<number> {
    try {
      if (!shouldBindSurfaceBeforeForegroundRenderer(surfaceId, width, height)) {
        return errResult(ExtensionErrorCode.ERR_SURFACE_INVALID,
          '前台恢复 Surface 无效', 'surfaceId=' + surfaceId + ' size=' + width.toString() + 'x' + height.toString());
      }
      const surfaceBound = rdpnapi.setXComponentSurfaceId(surfaceId, width, height) as boolean;
      if (!surfaceBound) {
        return errResult(ExtensionErrorCode.ERR_SURFACE_INVALID,
          'setXComponentSurfaceId 失败', 'surfaceId=' + surfaceId);
      }
      hilog.info(DOMAIN, TAG, '[ExtensionLoader] reattachRenderForForeground: surface rebound id=' + surfaceId);
      this.rendererHandle = rdpnapi.initRenderer(surfaceId, width, height) as number;
      if (this.rendererHandle <= 0) {
        return errResult(ExtensionErrorCode.ERR_SURFACE_INVALID,
          'initRenderer 失败', 'surfaceId=' + surfaceId);
      }
      hilog.info(DOMAIN, TAG, '[ExtensionLoader] reattachRenderForForeground: handle=' +
        this.rendererHandle.toString());
      return okResult(this.rendererHandle);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] reattachRenderForForeground: ' + JSON.stringify(err));
      this.rendererHandle = -1;
      return errResult(ExtensionErrorCode.ERR_NATIVE_CALL_FAILED,
        'reattachRenderForForeground 失败', JSON.stringify(err));
    }
  }

  /**
   * 请求关键帧刷新 (前台恢复后触发画面更新)。
   * RDP: 发送 Refresh Rect PDU。RustDesk: 发送 refresh_video_display。
   */
  requestFrameRefresh(): ExtensionResult<void> {
    try {
      rdpnapi.requestFrameRefresh();
      return okVoid();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[ExtensionLoader] requestFrameRefresh: ' + JSON.stringify(err));
      // 关键帧刷新失败不阻塞前台恢复 — best-effort
      return errResult(ExtensionErrorCode.ERR_NATIVE_CALL_FAILED,
        'requestFrameRefresh failed (not critical)', JSON.stringify(err));
    }
  }

  setRdpBackgroundVideoPrewarm(sessionId: number, enabled: boolean, intervalMs: number): boolean {
    try {
      const ok = rdpnapi.setRdpBackgroundVideoPrewarm(sessionId, enabled, intervalMs) as boolean;
      hilog.info(DOMAIN, TAG, '[ExtensionLoader] setRdpBackgroundVideoPrewarm ok=' +
        ok.toString() + ' enabled=' + enabled.toString() + ' interval=' + intervalMs.toString());
      return ok;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[ExtensionLoader] setRdpBackgroundVideoPrewarm failed: ' +
        JSON.stringify(err));
      return false;
    }
  }

  presentRdpCachedFrame(sessionId: number): boolean {
    try {
      const ok = rdpnapi.presentRdpCachedFrame(sessionId) as boolean;
      hilog.info(DOMAIN, TAG, '[ExtensionLoader] presentRdpCachedFrame ok=' + ok.toString());
      return ok;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[ExtensionLoader] presentRdpCachedFrame failed: ' + JSON.stringify(err));
      return false;
    }
  }

  /**
   * 完全断连 (用于 explicit back / disconnect button / recent task clear)。
   * 与 disconnect() 不同, 此方法传递退出原因到 native 层以便日志诊断。
   */
  disconnectForExit(reason: string): ExtensionResult<void> {
    try {
      const sessionId: number = this.currentSessionId;
      const requestId: number = this.disconnect();
      if (requestId > 0) {
        hilog.info(DOMAIN, TAG, '[ExtensionLoader] disconnectForExit: reason=' + reason +
          ' sessionId=' + sessionId.toString() + ' requestId=' + requestId.toString());
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] disconnectForExit: ' + JSON.stringify(err));
    }
    this.currentSessionId = -1;
    this.rendererHandle = -1;
    this.decoderHandle = -1;
    this.audioPlayerHandle = -1;
    return okVoid();
  }

  /**
   * 标记 XComponent surface 已销毁 (公开给 NativeSessionHandles 适配器)。
   */
  markXComponentSurfaceDestroyed(): void {
    try {
      rdpnapi.markXComponentSurfaceDestroyed();
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] markXComponentSurfaceDestroyed: ' + JSON.stringify(err));
    }
  }

  /**
   * 检查渲染器是否已附加。
   */
  isRendererAttached(): boolean {
    return this.rendererHandle > 0;
  }

  /**
   * 检查音频是否活跃。
   */
  isAudioActive(): boolean {
    try {
      return rdpnapi.isAudioPlaybackActive() as boolean;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[ExtensionLoader] isAudioActive fallback: ' + JSON.stringify(err));
      return false;
    }
  }

  isVideoActive(): boolean {
    try {
      return rdpnapi.isVideoPlaybackActive() as boolean;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[ExtensionLoader] isVideoActive fallback: ' + JSON.stringify(err));
      return false;
    }
  }
}
