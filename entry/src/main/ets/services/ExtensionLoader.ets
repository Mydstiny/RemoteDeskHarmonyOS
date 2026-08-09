/**
 * ExtensionLoader.ets — NAPI 桥接门面
 *
 * 对接 librdpnapi.so 的 C++ ExtensionSystem
 */
import rdpnapi from 'librdpnapi.so';
import {
  SessionConfig,
  SftpFileEntry,
  GeneratedSshKeyPair,
  SshPrivateKeyInfo,
  SshPublicKeyInstallResult,
  SshAuthTestResult,
  SshHostKeyInfo,
  SshProxyConfig,
  RdpCertificateInfo,
  RdpCertificateRecord,
  RdpPreflightRequest,
  RdpPreflightResult,
  RustDeskPresenceResult,
  VncCertificateProbePromise,
  VncGatewayDeepHealthPromise,
  VncGatewayDeepHealthResult,
  RdpRenderStats,
  RendererViewport,
  RustDeskDisplayCapabilities,
  RustDeskDisplaySwitchRequest,
  RustDeskDiagnosticsSnapshot,
  LocalResourceStats,
  RemoteCursorSnapshot,
  SessionTransferStatus,
  SshCommandResult,
  SshTerminalDiagnosticsSnapshot,
  SshTerminalInputEnqueueResult,
  SshAuthPromptRequest,
  SshAuthPromptResponse,
  SshSessionSnapshot,
  SshSessionEventsResult,
  SshForwardingConfig,
  SshForwardingSnapshotsResult,
  SftpListAsyncResult,
  SftpReadAsyncResult,
  SftpWriteAsyncResult,
  SftpMutationAsyncResult
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

interface DetachedSshSession {
  sessionId: number;
  hostId: string;
  detachedAt: number;
}

export interface SshNativeConnectPromise extends Promise<number> {
  sessionId: number;
  generation: number;
}

export interface SshPendingConnectIdentity {
  sessionId: number;
  generation: number;
  foreground: boolean;
}

export class ExtensionLoader {
  private static instance: ExtensionLoader;
  private currentSessionId: number = -1;
  private sshConnectGeneration: number = 0;
  private pendingSshConnects: Map<number, SshPendingConnectIdentity> =
    new Map<number, SshPendingConnectIdentity>();
  private rendererHandle: number = -1;
  private decoderHandle: number = -1;
  private audioPlayerHandle: number = -1;
  private teardownRequestId: number = 0;
  private diagnosticsLastErrorAtMs: number = 0;
  private detachedSshSessions: DetachedSshSession[] = [];

  static getInstance(): ExtensionLoader {
    if (!ExtensionLoader.instance) { ExtensionLoader.instance = new ExtensionLoader(); }
    return ExtensionLoader.instance;
  }

  // ====== 协议连接 ======

  connect(config: SessionConfig): number {
    this.sshConnectGeneration++;
    try {
      this.currentSessionId = rdpnapi.connect(config) as number;
      return this.currentSessionId;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] connect: code=' + ((err as Record<string, Object>)['code'] || 'ERR') + ' msg=' + JSON.stringify(err));
      return -1;
    }
  }

  connectSshAsync(config: SessionConfig, foreground: boolean = true): SshNativeConnectPromise {
    try {
      const nativePromise: SshNativeConnectPromise =
        rdpnapi.connectSshAsync(config, foreground) as SshNativeConnectPromise;
      const identity: SshPendingConnectIdentity = {
        sessionId: nativePromise.sessionId,
        generation: nativePromise.generation,
        foreground
      };
      if (identity.sessionId <= 0 || identity.generation <= 0) {
        hilog.error(DOMAIN, TAG, '[ExtensionLoader] connectSshAsync: native identity missing');
        const rejected: SshNativeConnectPromise = Promise.resolve(-1) as SshNativeConnectPromise;
        rejected.sessionId = -1;
        rejected.generation = 0;
        return rejected;
      }
      this.pendingSshConnects.set(identity.sessionId, identity);
      // Only the foreground owner updates the legacy facade target. Detached
      // SFTP sessions remain addressable through their explicit session id.
      if (foreground) {
        this.currentSessionId = identity.sessionId;
      }
      const settled: SshNativeConnectPromise = nativePromise.then(
        (result: number): number => {
          this.pendingSshConnects.delete(identity.sessionId);
          if (foreground && this.currentSessionId === identity.sessionId) {
            this.currentSessionId = result > 0 ? result : -1;
          }
          return result;
        },
        (err: Object): number => {
          this.pendingSshConnects.delete(identity.sessionId);
          if (foreground && this.currentSessionId === identity.sessionId) {
            this.currentSessionId = -1;
          }
          hilog.error(DOMAIN, TAG, '[ExtensionLoader] connectSshAsync: ' + JSON.stringify(err));
          return -1;
        }) as SshNativeConnectPromise;
      settled.sessionId = identity.sessionId;
      settled.generation = identity.generation;
      return settled;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] connectSshAsync: ' + JSON.stringify(err));
      const rejected: SshNativeConnectPromise = Promise.resolve(-1) as SshNativeConnectPromise;
      rejected.sessionId = -1;
      rejected.generation = 0;
      return rejected;
    }
  }

  getSshPendingConnects(): SshPendingConnectIdentity[] {
    const result: SshPendingConnectIdentity[] = [];
    this.pendingSshConnects.forEach((identity: SshPendingConnectIdentity): void => {
      result.push({
        sessionId: identity.sessionId,
        generation: identity.generation,
        foreground: identity.foreground
      });
    });
    return result;
  }

  /** Detach only the SSH view consumer; the native session remains live. */
  detachSshSession(sessionId: number, hostId: string): boolean {
    const normalizedHostId: string = hostId.trim();
    if (sessionId <= 0 || normalizedHostId.length === 0) { return false; }
    try {
      const detached: boolean = rdpnapi.detachSshSession(sessionId) as boolean;
      if (!detached) { return false; }
      let replaced: boolean = false;
      for (let index = 0; index < this.detachedSshSessions.length; index++) {
        if (this.detachedSshSessions[index].sessionId === sessionId) {
          this.detachedSshSessions[index] = {
            sessionId, hostId: normalizedHostId, detachedAt: Date.now()
          };
          replaced = true;
          break;
        }
      }
      if (!replaced) {
        this.detachedSshSessions.push({ sessionId, hostId: normalizedHostId, detachedAt: Date.now() });
      }
      if (this.currentSessionId === sessionId) { this.currentSessionId = -1; }
      return true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[ExtensionLoader] detachSshSession: ' + JSON.stringify(err));
      return false;
    }
  }

  /** Find a live detached SSH session for the host and make it the facade target. */
  adoptDetachedSshSession(hostId: string): number {
    const normalizedHostId: string = hostId.trim();
    if (normalizedHostId.length === 0) { return -1; }
    for (let index = this.detachedSshSessions.length - 1; index >= 0; index--) {
      const candidate: DetachedSshSession = this.detachedSshSessions[index];
      if (candidate.hostId !== normalizedHostId) { continue; }
      let state: number = 0;
      try { state = rdpnapi.getConnectionState(candidate.sessionId) as number; } catch (_err) { state = 0; }
      if (state !== 2 && state !== 3) {
        this.detachedSshSessions.splice(index, 1);
        continue;
      }
      this.detachedSshSessions.splice(index, 1);
      this.currentSessionId = candidate.sessionId;
      return candidate.sessionId;
    }
    return -1;
  }

  /**
   * Inspect a retained SSH session without adopting it or changing the
   * foreground facade owner. The terminal tab bar uses this to reconcile a
   * handshake that completed while another host was visible.
   */
  peekDetachedSshSession(hostId: string): number {
    const normalizedHostId: string = hostId.trim();
    if (normalizedHostId.length === 0) { return -1; }
    for (let index = this.detachedSshSessions.length - 1; index >= 0; index--) {
      const candidate: DetachedSshSession = this.detachedSshSessions[index];
      if (candidate.hostId !== normalizedHostId) { continue; }
      let state: number = 0;
      try { state = rdpnapi.getConnectionState(candidate.sessionId) as number; } catch (_err) { state = 0; }
      if (state === 2 || state === 3) {
        return candidate.sessionId;
      }
      this.detachedSshSessions.splice(index, 1);
    }
    return -1;
  }

  /** Re-enable input after a detached SSH view has installed its callback. */
  resumeSshSession(sessionId: number): boolean {
    if (sessionId <= 0) { return false; }
    try { return rdpnapi.resumeSshSession(sessionId) as boolean; } catch (_err) { return false; }
  }

  /** Explicitly close one SSH session, including a detached session. */
  disconnectSshSession(sessionId: number): number {
    if (sessionId <= 0) { return 0; }
    this.pendingSshConnects.delete(sessionId);
    this.detachedSshSessions = this.detachedSshSessions.filter(
      (candidate: DetachedSshSession): boolean => candidate.sessionId !== sessionId);
    let requestId: number = 0;
    try { requestId = rdpnapi.disconnect(sessionId, -1, -1, -1) as number; } catch (err) {
      hilog.warn(DOMAIN, TAG, '[ExtensionLoader] disconnectSshSession: ' + JSON.stringify(err));
    }
    if (this.currentSessionId === sessionId) { this.currentSessionId = -1; }
    if (requestId > 0) { this.teardownRequestId = requestId; }
    return requestId;
  }

  disconnect(): number {
    if (this.currentSessionId > 0) { this.pendingSshConnects.delete(this.currentSessionId); }
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
    this.pendingSshConnects.clear();
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
        serverName,
        commonName: '',
        subject: '',
        issuer: '',
        fingerprintSha256: '',
        notBeforeMs: 0,
        notAfterMs: 0,
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
        serverName,
        commonName: '',
        subject: '',
        issuer: '',
        fingerprintSha256: '',
        notBeforeMs: 0,
        notAfterMs: 0,
        flags: 0,
        rootTrusted: false,
        hostMismatch: false,
        errorCode: -1,
        errorMessage: 'RDP 证书探测异常 [E-RDP-CERT-ASYNC]'
      };
    }
  }

  async probeRdpCertificateRouteAsync(
    request: RdpPreflightRequest): Promise<RdpPreflightResult> {
    try {
      return await rdpnapi.probeRdpCertificateRouteAsync(request) as RdpPreflightResult;
    } catch (err) {
      hilog.error(DOMAIN, TAG,
        '[ExtensionLoader] probeRdpCertificateRouteAsync: ' + JSON.stringify(err));
      const route = request.route;
      const emptyCertificate: RdpCertificateRecord = {
        present: false, rootTrusted: false, hostMismatch: false, flags: 0,
        host: route.targetHost, port: route.targetPort ?? 3389,
        stage: 'target', serverName: route.targetServerName ?? route.targetHost,
        commonName: '', subject: '', issuer: '', fingerprintSha256: '',
        notBeforeMs: 0, notAfterMs: 0
      };
      return {
        ok: false,
        endpointMode: route.endpointMode ?? (route.gatewayHost ? 'microsoft_rd_gateway' : 'direct_rdp'),
        routeIdentity: '',
        generation: request.generation ?? 0,
        requestId: request.requestId ?? '',
        stage: 'endpoint',
        errorCode: 'E-RDP-PREFLIGHT-NAPI',
        errorMessage: 'RDP 路由证书预检异常',
        gatewayTransportRequested: route.gatewayTransport ?? 'auto',
        gatewayTransportNegotiated: 'unknown',
        gatewayTransportSelected: route.gatewayTransport ?? 'auto',
        requiresGatewayAuth: false,
        requiresUserDecision: false,
        gatewayCertificate: {
          present: false, rootTrusted: false, hostMismatch: false, flags: 0,
          host: route.gatewayHost ?? '', port: route.gatewayPort ?? 443,
          stage: 'gateway', serverName: route.gatewayServerName ?? route.gatewayHost ?? '',
          commonName: '', subject: '', issuer: '', fingerprintSha256: '',
          notBeforeMs: 0, notAfterMs: 0
        },
        targetCertificate: emptyCertificate
      } as RdpPreflightResult;
    }
  }

  async probeRustDeskPresenceAsync(host: string, port: number, serverKey: string,
    peerId: string, token: string, direct: boolean, keyMode: number): Promise<RustDeskPresenceResult> {
    try {
      return await rdpnapi.probeRustDeskPresenceAsync(host, port, serverKey, peerId, token,
        direct, keyMode) as RustDeskPresenceResult;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] probeRustDeskPresenceAsync: ' + JSON.stringify(err));
      return { state: 0, latencyMs: -1, errorCode: 5 };
    }
  }

  probeVncCertificateAsync(host: string, port: number, serverName: string,
    timeoutMs: number = 10000): VncCertificateProbePromise {
    try {
      return rdpnapi.probeVncCertificateAsync(host, port, serverName, timeoutMs) as VncCertificateProbePromise;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] probeVncCertificateAsync: ' + JSON.stringify(err));
      // A synchronous NAPI failure cannot provide a cancellable request id;
      // propagate it so callers fail closed instead of receiving an
      // un-cancellable promise with a fabricated token.
      throw new Error(JSON.stringify(err));
    }
  }

  cancelVncCertificateProbe(requestId: number): boolean {
    try {
      return rdpnapi.cancelVncCertificateProbe(requestId) as boolean;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] cancelVncCertificateProbe: ' + JSON.stringify(err));
      return false;
    }
  }

  probeVncGatewayDeepAsync(host: string, port: number, transport: string,
    repeaterMode: string, target: string, tls: boolean, expectedFingerprint: string,
    timeoutMs: number, ownerType: string, ownerId: string, userId: string,
    storeIdentityFingerprint: string, endpointBindingFingerprint: string,
    accountGeneration: number, enabled: boolean): VncGatewayDeepHealthPromise {
    try {
      return rdpnapi.probeVncGatewayDeepAsync(host, port, transport, repeaterMode, target,
        tls, expectedFingerprint, timeoutMs, ownerType, ownerId, userId,
        storeIdentityFingerprint, endpointBindingFingerprint, accountGeneration,
        enabled) as VncGatewayDeepHealthPromise;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] probeVncGatewayDeepAsync: ' + JSON.stringify(err));
      const failure: VncGatewayDeepHealthResult = {
        stage: 'FAILED', code: 'E-VNC-GATEWAY-DEEP', message: 'Gateway 深度检查失败', protocolReady: false,
        certificateFingerprintSha256: '', ownerType: '', ownerId: '', userId: '',
        storeIdentityFingerprint: '', endpointBindingFingerprint: '', accountGeneration: 0
      };
      const promise: VncGatewayDeepHealthPromise = Promise.resolve(failure) as VncGatewayDeepHealthPromise;
      promise.requestId = 0;
      return promise;
    }
  }

  cancelVncGatewayDeep(requestId: number): boolean {
    try {
      return rdpnapi.cancelVncGatewayDeep(requestId) as boolean;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] cancelVncGatewayDeep: ' + JSON.stringify(err));
      return false;
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
        lastRemoteUpdateAgeMs: -1,
        eventLoopAgeMs: -1,
        eventLoopBlockMaxUs: 0,
        lastInputPostAgeMs: -1,
        eventLoopTicks: 0,
        networkCheckCount: 0,
        networkCheckFailures: 0,
        inputPostFailures: 0,
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
        graphicsMode: 'unknown'
      };
    }
  }

  getSessionDiagnostics(sessionId: number): RustDeskDiagnosticsSnapshot {
    try {
      return rdpnapi.getSessionDiagnostics(sessionId) as RustDeskDiagnosticsSnapshot;
    } catch (err) {
      const nowMs: number = Date.now();
      if (nowMs - this.diagnosticsLastErrorAtMs >= 5000) {
        this.diagnosticsLastErrorAtMs = nowMs;
        hilog.warn(DOMAIN, TAG, '[ExtensionLoader] getSessionDiagnostics unavailable: ' + JSON.stringify(err));
      }
      return {
        supported: false, sessionActive: false, protocolSnapshotAvailable: false,
        videoSeen: false, receivedRateAvailable: false, presentedRateAvailable: false,
        decodeRateAvailable: false, sessionId, latencyMs: -1, targetBitrateKbps: 0,
        videoMessages: 0, receivedFrames: 0, keyframes: 0, receivedBytes: 0,
        audioFrames: 0, cadenceGaps: 0, maxCadenceGapMs: 0, testDelayCount: 0,
        receivedFps: 0, displayFps: 0, decodeFps: 0, bitrateKbps: 0,
        codec: -1, width: 0, height: 0, connectionPath: 'unknown', lastFrameAtMs: 0,
        lastFrameAgeMs: -1, lastPresentedAtMs: 0, lastPresentedFrameAgeMs: -1,
        decodeOk: 0, decodeErrors: 0, decodeP50Us: 0, decodeP95Us: 0, decodeMaxUs: 0,
        presentedFrames: 0, presentationRejected: 0,
        lastDirtyX: -1, lastDirtyY: -1, lastDirtyWidth: 0, lastDirtyHeight: 0,
        requestedColorDepth: '', effectiveColorDepth: 0,
        inputEventsSent: 0, inputEventsDropped: 0,
        presentationWindowSamples: 0, presentationWindowMs: 0,
        renderP50Us: 0, renderP95Us: 0, renderMaxUs: 0,
        queueDepth: 0, queueMax: 0, droppedFrames: 0, decoderBackend: 'unknown'
      };
    }
  }

  /** Compatibility facade retained for RustDesk-specific callers. */
  getRustDeskDiagnostics(sessionId: number): RustDeskDiagnosticsSnapshot {
    return this.getSessionDiagnostics(sessionId);
  }

  getLocalResourceStats(includePro: boolean = true): LocalResourceStats {
    try {
      return rdpnapi.getLocalResourceStats(includePro) as LocalResourceStats;
    } catch (err) {
      const nowMs: number = Date.now();
      if (nowMs - this.diagnosticsLastErrorAtMs >= 5000) {
        this.diagnosticsLastErrorAtMs = nowMs;
        hilog.warn(DOMAIN, TAG, '[ExtensionLoader] getLocalResourceStats unavailable: ' + JSON.stringify(err));
      }
      return {
        supported: false, cpuAvailable: false, cpuPercent: -1, memoryBytes: 0,
        memoryAvailable: false, gpuAvailable: false, gpuPercent: -1, sampledAtMs: 0
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

  /**
   * Destroy a renderer owned by an older surface transfer without changing
   * the current loader handle. This is required when a stale PIP callback
   * arrives after a foreground renderer has already been installed.
   */
  destroyRendererHandle(handle: number): void {
    if (handle <= 0) {
      return;
    }
    try {
      rdpnapi.destroyRenderer(handle);
      if (this.rendererHandle === handle) {
        this.rendererHandle = -1;
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] destroyRendererHandle: ' + JSON.stringify(err));
    }
  }

  initDecoder(w: number, h: number, c: number, rendererHandle: number = -1,
    desktopSurfaceCompatibility: boolean = false): number {
    try {
      this.decoderHandle = rdpnapi.initDecoder(
        w, h, c, rendererHandle, desktopSurfaceCompatibility) as number;
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

  getRendererHandle(): number { return this.rendererHandle; }
  getDecoderHandle(): number { return this.decoderHandle; }

  bindRendererToSession(rendererHandle: number, sessionId: number): boolean {
    if (rendererHandle <= 0 || sessionId <= 0) {
      return false;
    }
    try {
      const bound: boolean = rdpnapi.bindRendererToSession(rendererHandle, sessionId) as boolean;
      hilog.info(DOMAIN, TAG, '[ExtensionLoader] bindRendererToSession renderer=' +
        rendererHandle.toString() + ' session=' + sessionId.toString() +
        ' bound=' + bound.toString());
      return bound;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] bindRendererToSession: ' + JSON.stringify(err));
      return false;
    }
  }

  // ====== 渲染管线操作 ======

  bindVideoPipeline(decoderHandle: number, rendererHandle: number): boolean {
    try {
      const bound: boolean = rdpnapi.bindVideoPipeline(decoderHandle, rendererHandle) as boolean;
      if (bound && this.currentSessionId > 0) {
        // RustDesk may deliver its first keyframe while connect() is
        // publishing the session but before ArkTS can bind the decoder. The
        // native loader retains that keyframe and replays it at this barrier.
        const replayed: boolean = rdpnapi.replayPendingRustDeskFrame(
          this.currentSessionId) as boolean;
        hilog.info(DOMAIN, TAG, '[ExtensionLoader] replayPendingRustDeskFrame: ' +
          replayed.toString());
      }
      return bound;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] bindVideoPipeline: ' + JSON.stringify(err));
      return false;
    }
  }

  /**
   * Re-activate the surviving decoder and bind it to the current renderer
   * after a background/PIP surface transfer. A plain bind cannot acquire a
   * decoder that was intentionally deactivated during the transfer.
   */
  rebindActiveVideoPipeline(): boolean {
    try {
      const rebound: boolean = rdpnapi.rebindActiveVideoPipeline() as boolean;
      if (rebound && this.currentSessionId > 0) {
        const replayed: boolean = rdpnapi.replayPendingRustDeskFrame(
          this.currentSessionId) as boolean;
        hilog.info(DOMAIN, TAG, '[ExtensionLoader] rebindActiveVideoPipeline: ' +
          rebound.toString() + ' replayed=' + replayed.toString());
      } else {
        hilog.info(DOMAIN, TAG, '[ExtensionLoader] rebindActiveVideoPipeline: ' +
          rebound.toString());
      }
      return rebound;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] rebindActiveVideoPipeline: ' +
        JSON.stringify(err));
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

  getRustDeskDisplayCapabilities(sessionId: number): RustDeskDisplayCapabilities {
    try {
      return rdpnapi.getRustDeskDisplayCapabilities(sessionId) as RustDeskDisplayCapabilities;
    } catch (err) {
      hilog.warn(DOMAIN, TAG,
        '[ExtensionLoader] getRustDeskDisplayCapabilities unavailable: ' + JSON.stringify(err));
      return {
        supported: false,
        currentDisplay: 0,
        switchGeneration: 0,
        readySwitchGeneration: 0,
        pendingDisplay: -1,
        inputBlocked: false,
        width: 0,
        height: 0,
        originalWidth: 0,
        originalHeight: 0,
        scaleMilli: 1000,
        geometryEpoch: 0,
        resolutions: [],
        displays: []
      };
    }
  }

  beginRustDeskDisplaySwitch(sessionId: number, display: number): RustDeskDisplaySwitchRequest {
    try {
      return rdpnapi.beginRustDeskDisplaySwitch(sessionId, display) as RustDeskDisplaySwitchRequest;
    } catch (err) {
      hilog.warn(DOMAIN, TAG,
        '[ExtensionLoader] beginRustDeskDisplaySwitch unavailable: ' + JSON.stringify(err));
      return { accepted: false, generation: 0 };
    }
  }

  switchRustDeskDisplay(sessionId: number, display: number): boolean {
    try {
      return rdpnapi.switchRustDeskDisplay(sessionId, display) as boolean;
    } catch (err) {
      hilog.warn(DOMAIN, TAG,
        '[ExtensionLoader] switchRustDeskDisplay unavailable: ' + JSON.stringify(err));
      return false;
    }
  }

  changeRustDeskDisplayResolution(sessionId: number, display: number, width: number,
    height: number): boolean {
    try {
      return rdpnapi.changeRustDeskDisplayResolution(sessionId, display, width, height) as boolean;
    } catch (err) {
      hilog.warn(DOMAIN, TAG,
        '[ExtensionLoader] changeRustDeskDisplayResolution unavailable: ' + JSON.stringify(err));
      return false;
    }
  }

  sendRustDeskTouchScale(sessionId: number, scale: number): boolean {
    try {
      return rdpnapi.sendRustDeskTouchScale(sessionId, scale) as boolean;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[ExtensionLoader] sendRustDeskTouchScale unavailable: ' + JSON.stringify(err));
      return false;
    }
  }

  sendRustDeskTouchPan(sessionId: number, phase: number, x: number, y: number): boolean {
    try {
      return rdpnapi.sendRustDeskTouchPan(sessionId, phase, x, y) as boolean;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[ExtensionLoader] sendRustDeskTouchPan unavailable: ' + JSON.stringify(err));
      return false;
    }
  }

  setRendererCanvasTransform(handle: number, scale: number, panX: number, panY: number): number {
    try {
      return rdpnapi.setRendererCanvasTransform(handle, scale, panX, panY) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] setRendererCanvasTransform: ' + JSON.stringify(err));
      return 0;
    }
  }

  getRendererViewport(handle: number): RendererViewport | null {
    try {
      return rdpnapi.getRendererViewport(handle);
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

  sendRustDeskTouchpadWheel(sessionId: number, x: number, y: number): boolean {
    try {
      return rdpnapi.sendRustDeskTouchpadWheel(sessionId, x, y) as boolean;
    } catch (err) {
      hilog.warn(DOMAIN, TAG,
        '[ExtensionLoader] sendRustDeskTouchpadWheel unavailable: ' + JSON.stringify(err));
      return false;
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

  enqueueTerminalInput(sessionId: number, data: string, expectedGeneration: number = 0,
    control: boolean = false, ordered: boolean = false, orderedEnd: boolean = false): SshTerminalInputEnqueueResult {
    try {
      return rdpnapi.enqueueSshTerminalInput(
        sessionId, data, expectedGeneration, control, ordered, orderedEnd) as SshTerminalInputEnqueueResult;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] enqueueTerminalInput: ' + JSON.stringify(err));
      return {
        accepted: false,
        status: 'sessionClosed',
        sequence: 0,
        generation: 0,
        queueDepth: 0,
        queueBytes: 0
      };
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

  async writeRemoteFileChunkAsync(sessionId: number, remotePath: string, data: ArrayBuffer,
    offset: number, truncate: boolean, expectedGeneration: number = 0): Promise<SftpWriteAsyncResult> {
    try {
      return await (rdpnapi.writeRemoteFileChunkAsync(
        sessionId, remotePath, data, offset, truncate, expectedGeneration) as Promise<SftpWriteAsyncResult>);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] writeRemoteFileChunkAsync: ' + JSON.stringify(err));
      return { errorCode: -1, bytesWritten: -1 };
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

  async listRemoteDirAsync(sessionId: number, remotePath: string,
    expectedGeneration: number = 0): Promise<SftpListAsyncResult> {
    try {
      return await (rdpnapi.listRemoteDirAsync(
        sessionId, remotePath, expectedGeneration) as Promise<SftpListAsyncResult>);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] listRemoteDirAsync: ' + JSON.stringify(err));
      return { errorCode: -1, entries: [] };
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

  async readRemoteFileChunkAsync(sessionId: number, remotePath: string, offset: number,
    maxLen: number, expectedGeneration: number = 0): Promise<SftpReadAsyncResult> {
    try {
      return await (rdpnapi.readRemoteFileChunkAsync(
        sessionId, remotePath, offset, maxLen, expectedGeneration) as Promise<SftpReadAsyncResult>);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] readRemoteFileChunkAsync: ' + JSON.stringify(err));
      return { errorCode: -1, data: new ArrayBuffer(0) };
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

  async removeRemoteFileAsync(sessionId: number, remotePath: string,
    expectedGeneration: number = 0): Promise<SftpMutationAsyncResult> {
    try {
      return await (rdpnapi.removeRemoteFileAsync(
        sessionId, remotePath, expectedGeneration) as Promise<SftpMutationAsyncResult>);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] removeRemoteFileAsync: ' + JSON.stringify(err));
      return { errorCode: -1 };
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

  async removeRemoteDirAsync(sessionId: number, remotePath: string,
    expectedGeneration: number = 0): Promise<SftpMutationAsyncResult> {
    try {
      return await (rdpnapi.removeRemoteDirAsync(
        sessionId, remotePath, expectedGeneration) as Promise<SftpMutationAsyncResult>);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] removeRemoteDirAsync: ' + JSON.stringify(err));
      return { errorCode: -1 };
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

  async makeRemoteDirAsync(sessionId: number, remotePath: string,
    expectedGeneration: number = 0): Promise<SftpMutationAsyncResult> {
    try {
      return await (rdpnapi.makeRemoteDirAsync(
        sessionId, remotePath, expectedGeneration) as Promise<SftpMutationAsyncResult>);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] makeRemoteDirAsync: ' + JSON.stringify(err));
      return { errorCode: -1 };
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

  async renameRemotePathAsync(sessionId: number, oldPath: string,
    newPath: string, atomic: boolean = false,
    expectedGeneration: number = 0): Promise<SftpMutationAsyncResult> {
    try {
      return await (rdpnapi.renameRemotePathAsync(
        sessionId, oldPath, newPath, atomic, expectedGeneration) as Promise<SftpMutationAsyncResult>);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] renameRemotePathAsync: ' + JSON.stringify(err));
      return { errorCode: -1 };
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

  setSessionClipboardEnabled(sessionId: number, enabled: boolean): boolean {
    try {
      return rdpnapi.setSessionClipboardEnabled(sessionId, enabled) as boolean;
    } catch (err) {
      hilog.error(DOMAIN, TAG,
        '[ExtensionLoader] setSessionClipboardEnabled: ' + JSON.stringify(err));
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

  getSshTerminalDiagnostics(sessionId: number): SshTerminalDiagnosticsSnapshot {
    try {
      return rdpnapi.getSshTerminalDiagnostics(sessionId) as SshTerminalDiagnosticsSnapshot;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[ExtensionLoader] getSshTerminalDiagnostics: ' + JSON.stringify(err));
      return {
        supported: false,
        sessionActive: false,
        schemaVersion: 2,
        sessionId,
        sessionGeneration: 0,
        channelId: 'pty',
        inputEvents: 0,
        inputBytes: 0,
        nativeEnqueueEvents: 0,
        writeAttempts: 0,
        writeCompleteEvents: 0,
        writeBytes: 0,
        writeEagain: 0,
        remoteReadEvents: 0,
        remoteReadBytes: 0,
        callbackAcceptedEvents: 0,
        callbackAcceptedBytes: 0,
        callbackQueueFull: 0,
        callbackDeliveryErrors: 0,
        callbackClosed: 0,
        inputDuplicate: 0,
        inputLoss: 0,
        inputReorder: 0,
        ownerStallEvents: 0,
        coverageMask: 0,
        coverageComplete: false,
        inputQueueDepth: 0,
        inputQueueBytes: 0,
        inputQueueMaxDepth: 0,
        inputQueueMaxBytes: 0,
        lastInputSequence: 0,
        lastInputCapturedAtNs: 0,
        lastNativeEnqueueAtNs: 0,
        lastWriteAttemptAtNs: 0,
        lastWriteCompleteAtNs: 0,
        lastRemoteReadAtNs: 0,
        maxInputToWriteAttemptNs: 0,
        maxInputToWriteCompleteNs: 0
      };
    }
  }

  execSshCommand(sessionId: number, command: string, timeoutMs: number = 30000): SshCommandResult {
    try {
      return rdpnapi.execSshCommand(sessionId, command, timeoutMs) as SshCommandResult;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] execSshCommand: ' + JSON.stringify(err));
      return {
        errorCode: -53,
        exitCode: -1,
        signaled: false,
        signal: '',
        stdout: new ArrayBuffer(0),
        stderr: new ArrayBuffer(0)
      };
    }
  }

  async execSshCommandAsync(sessionId: number, command: string,
    timeoutMs: number = 30000): Promise<SshCommandResult> {
    try {
      return await rdpnapi.execSshCommandAsync(sessionId, command, timeoutMs) as SshCommandResult;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] execSshCommandAsync: ' + JSON.stringify(err));
      return {
        errorCode: -53, exitCode: -1, signaled: false, signal: '',
        stdout: new ArrayBuffer(0), stderr: new ArrayBuffer(0)
      };
    }
  }

  execSshSubsystem(sessionId: number, subsystem: string, timeoutMs: number = 30000): SshCommandResult {
    try {
      return rdpnapi.execSshSubsystem(sessionId, subsystem, timeoutMs) as SshCommandResult;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] execSshSubsystem: ' + JSON.stringify(err));
      return { errorCode: -46, exitCode: -1, signaled: false, signal: '',
        stdout: new ArrayBuffer(0), stderr: new ArrayBuffer(0) };
    }
  }

  async execSshSubsystemAsync(sessionId: number, subsystem: string,
    timeoutMs: number = 30000): Promise<SshCommandResult> {
    try {
      return await rdpnapi.execSshSubsystemAsync(sessionId, subsystem, timeoutMs) as SshCommandResult;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] execSshSubsystemAsync: ' + JSON.stringify(err));
      return {
        errorCode: -46, exitCode: -1, signaled: false, signal: '',
        stdout: new ArrayBuffer(0), stderr: new ArrayBuffer(0)
      };
    }
  }

  sendSshSignal(sessionId: number, signal: string): number {
    try {
      return rdpnapi.sendSshSignal(sessionId, signal) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] sendSshSignal: ' + JSON.stringify(err));
      return -53;
    }
  }

  sendSshEof(sessionId: number): number {
    try {
      return rdpnapi.sendSshEof(sessionId) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] sendSshEof: ' + JSON.stringify(err));
      return -53;
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

  getSshAuthPrompt(sessionId: number, sessionGeneration: number): SshAuthPromptRequest | null {
    try {
      return rdpnapi.getSshAuthPrompt(sessionId, sessionGeneration) as SshAuthPromptRequest | null;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[ExtensionLoader] getSshAuthPrompt: ' + JSON.stringify(err));
      return null;
    }
  }

  respondSshAuthPrompt(response: SshAuthPromptResponse): boolean {
    try {
      return rdpnapi.respondSshAuthPrompt(response) as boolean;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[ExtensionLoader] respondSshAuthPrompt: ' + JSON.stringify(err));
      return false;
    }
  }

  cancelSshAuthPrompt(sessionId: number, sessionGeneration: number, requestId: number): boolean {
    try {
      return rdpnapi.cancelSshAuthPrompt(
        sessionId, sessionGeneration, requestId) as boolean;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[ExtensionLoader] cancelSshAuthPrompt: ' + JSON.stringify(err));
      return false;
    }
  }

  getSshSessionSnapshot(sessionId: number, sessionGeneration: number): SshSessionSnapshot {
    try {
      return rdpnapi.getSshSessionSnapshot(
        sessionId, sessionGeneration) as SshSessionSnapshot;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[ExtensionLoader] getSshSessionSnapshot: ' + JSON.stringify(err));
      return {
        schemaVersion: 1,
        errorCode: -72,
        sessionId,
        generation: 0,
        channelId: 'shell',
        state: 0,
        stateName: 'Created',
        eventSequence: 0,
        host: '',
        port: 22,
        backgroundLimited: false,
        lastEventType: ''
      };
    }
  }

  getSshSessionEvents(sessionId: number, channelId: string, sessionGeneration: number,
    afterSequence: number = 0): SshSessionEventsResult {
    const normalizedChannelId: string = channelId.trim();
    const normalizedAfterSequence: number = Number.isFinite(afterSequence) && afterSequence >= 0
      ? Math.floor(afterSequence) : 0;
    try {
      return rdpnapi.getSshSessionEvents(
        sessionId, normalizedChannelId, sessionGeneration, normalizedAfterSequence) as SshSessionEventsResult;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[ExtensionLoader] getSshSessionEvents: ' + JSON.stringify(err));
      return {
        schemaVersion: 1,
        errorCode: -81,
        sessionId,
        channelId: normalizedChannelId,
        generation: 0,
        afterSequence: normalizedAfterSequence,
        events: []
      };
    }
  }

  configureSshForwarding(sessionId: number, sessionGeneration: number,
    config: SshForwardingConfig): number {
    try {
      return rdpnapi.configureSshForwarding(sessionId, sessionGeneration, config) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] configureSshForwarding: ' + JSON.stringify(err));
      return -74;
    }
  }

  removeSshForwarding(sessionId: number, sessionGeneration: number, id: string): number {
    try {
      return rdpnapi.removeSshForwarding(sessionId, sessionGeneration, id) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] removeSshForwarding: ' + JSON.stringify(err));
      return -74;
    }
  }

  startSshForwarding(sessionId: number, sessionGeneration: number, id: string): number {
    try {
      return rdpnapi.startSshForwarding(sessionId, sessionGeneration, id) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] startSshForwarding: ' + JSON.stringify(err));
      return -74;
    }
  }

  markSshForwardingListening(sessionId: number, sessionGeneration: number, id: string): number {
    try {
      return rdpnapi.markSshForwardingListening(sessionId, sessionGeneration, id) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG,
        '[ExtensionLoader] markSshForwardingListening: ' + JSON.stringify(err));
      return -74;
    }
  }

  failSshForwarding(sessionId: number, sessionGeneration: number,
    id: string, error: number): number {
    try {
      return rdpnapi.failSshForwarding(sessionId, sessionGeneration, id, error) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] failSshForwarding: ' + JSON.stringify(err));
      return -74;
    }
  }

  stopSshForwarding(sessionId: number, sessionGeneration: number, id: string): number {
    try {
      return rdpnapi.stopSshForwarding(sessionId, sessionGeneration, id) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] stopSshForwarding: ' + JSON.stringify(err));
      return -74;
    }
  }

  completeSshForwardingStop(sessionId: number, sessionGeneration: number, id: string): number {
    try {
      return rdpnapi.completeSshForwardingStop(sessionId, sessionGeneration, id) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG,
        '[ExtensionLoader] completeSshForwardingStop: ' + JSON.stringify(err));
      return -74;
    }
  }

  acquireSshForwardingConnection(sessionId: number, sessionGeneration: number, id: string): number {
    try {
      return rdpnapi.acquireSshForwardingConnection(sessionId, sessionGeneration, id) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG,
        '[ExtensionLoader] acquireSshForwardingConnection: ' + JSON.stringify(err));
      return -74;
    }
  }

  releaseSshForwardingConnection(sessionId: number, sessionGeneration: number, id: string): number {
    try {
      return rdpnapi.releaseSshForwardingConnection(sessionId, sessionGeneration, id) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG,
        '[ExtensionLoader] releaseSshForwardingConnection: ' + JSON.stringify(err));
      return -74;
    }
  }

  getSshForwardingSnapshots(sessionId: number,
    sessionGeneration: number): SshForwardingSnapshotsResult {
    try {
      return rdpnapi.getSshForwardingSnapshots(
        sessionId, sessionGeneration) as SshForwardingSnapshotsResult;
    } catch (err) {
      hilog.error(DOMAIN, TAG,
        '[ExtensionLoader] getSshForwardingSnapshots: ' + JSON.stringify(err));
      return { errorCode: -74, sessionId, sessionGeneration: 0, snapshots: [] };
    }
  }

  getRemoteCursorSnapshot(sessionId: number, includePixels: boolean = false): RemoteCursorSnapshot | null {
    try {
      return rdpnapi.getRemoteCursorSnapshot(sessionId, includePixels) as RemoteCursorSnapshot;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] getRemoteCursorSnapshot: ' + JSON.stringify(err));
      return null;
    }
  }

  async getRemoteCursorSnapshotPixelsAsync(sessionId: number): Promise<RemoteCursorSnapshot | null> {
    try {
      return await rdpnapi.getRemoteCursorSnapshotPixelsAsync(sessionId) as RemoteCursorSnapshot;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[ExtensionLoader] getRemoteCursorSnapshotPixelsAsync: ' +
        JSON.stringify(err));
      return null;
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

  submitRustDesk2FA(sessionId: number, code: string): boolean {
    try {
      return rdpnapi.submitRustDesk2FA(sessionId, code) as boolean;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] submitRustDesk2FA: ' + JSON.stringify(err));
      return false;
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

  async measureSshLatencyAsync(sessionId: number): Promise<number> {
    try {
      return await rdpnapi.measureSshLatencyAsync(sessionId) as number;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] measureSshLatencyAsync: ' + JSON.stringify(err));
      return -1;
    }
  }

  /**
   * 注册推送式 SSH 数据回调.
   * 后台 reader 线程读到数据后立即触发 cb(data).
   * 传 null 卸载.
   */
  setOnDataCallback(sessionId: number, cb: ((data: ArrayBuffer) => void) | null): void {
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
                 privateKeyPem: string, passphrase: string,
                 proxy?: SshProxyConfig): SshAuthTestResult {
    try {
      return rdpnapi.testSshKeyAuth(host, port, username, privateKeyPem, passphrase, proxy) as SshAuthTestResult;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] testSshKeyAuth: ' + JSON.stringify(err));
      return { ok: false, code: -99,
               message: '[CC-SSHKEY-08] testSshKeyAuth NAPI error: ' + JSON.stringify(err) };
    }
  }

  /** 测试 SSH 密钥认证；native 网络工作在线程池执行，不阻塞 ArkTS/UI 线程。 */
  async testSshKeyAuthAsync(host: string, port: number, username: string,
                            privateKeyPem: string, passphrase: string,
                            proxy?: SshProxyConfig): Promise<SshAuthTestResult> {
    try {
      return await rdpnapi.testSshKeyAuthAsync(
        host, port, username, privateKeyPem, passphrase, proxy) as SshAuthTestResult;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] testSshKeyAuthAsync: ' + JSON.stringify(err));
      return { ok: false, code: -99,
               message: '[CC-SSHKEY-08] testSshKeyAuthAsync NAPI error: ' + JSON.stringify(err) };
    }
  }

  /**
   * 探测 SSH 主机公钥 (仅 TCP + KEX, 不做用户认证)
   * 同步阻塞 1-5s, 调用方应显示 loading 状态
   */
  probeSshHostKey(host: string, port: number, proxy?: SshProxyConfig): SshHostKeyInfo {
    try {
      return rdpnapi.probeSshHostKey(host, port, proxy) as SshHostKeyInfo;
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

  /** 探测 SSH 主机公钥；native DNS/TCP/KEX 在线程池执行。 */
  async probeSshHostKeyAsync(host: string, port: number,
                             proxy?: SshProxyConfig): Promise<SshHostKeyInfo> {
    try {
      return await rdpnapi.probeSshHostKeyAsync(host, port, proxy) as SshHostKeyInfo;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] probeSshHostKeyAsync: ' + JSON.stringify(err));
      return {
        ok: false, host: host, port: port, algorithm: '',
        fingerprintSha256: '', rawBase64: '', serverBanner: '',
        errorCode: -99,
        errorMessage: '[CC-SSH-09] probeSshHostKeyAsync NAPI error: ' + JSON.stringify(err)
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
    height: number, sessionId: number = this.currentSessionId): ExtensionResult<number> {
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
      const rendererHandle: number = rdpnapi.initRenderer(surfaceId, width, height) as number;
      if (rendererHandle <= 0) {
        return errResult(ExtensionErrorCode.ERR_SURFACE_INVALID,
          'initRenderer 失败', 'surfaceId=' + surfaceId);
      }
      if (sessionId > 0 && !this.bindRendererToSession(rendererHandle, sessionId)) {
        // The protocol session is still alive, so a renderer that could not be
        // admitted to its owner must not remain as an unowned active target.
        try { rdpnapi.destroyRenderer(rendererHandle); } catch (_e) { /* best effort */ }
        return errResult(ExtensionErrorCode.ERR_NATIVE_CALL_FAILED,
          'renderer owner 绑定失败', 'renderer=' + rendererHandle.toString() +
          ' session=' + sessionId.toString());
      }
      this.rendererHandle = rendererHandle;
      hilog.info(DOMAIN, TAG, '[ExtensionLoader] reattachRenderForForeground: handle=' +
        rendererHandle.toString() + ' session=' + sessionId.toString());
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
