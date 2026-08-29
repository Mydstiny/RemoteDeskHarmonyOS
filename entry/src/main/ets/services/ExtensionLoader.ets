/**
 * ExtensionLoader.ets — NAPI 桥接门面
 *
 * 对接 librdpnapi.so 的 C++ ExtensionSystem
 */
import rdpnapi from 'librdpnapi.so';
import {
  disconnectAllSubmissionMayReleaseTracking,
  nativeSessionStateBlocksAutomaticTransition,
  RemoteSessionTransitionGate
} from './RemoteSessionTransitionGate';
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
  SftpMutationAsyncResult,
  NativeSessionOwnerIdentity,
  NativeDisconnectReceipt
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
import { rdpRouteIdentityForValues } from '../model/RemoteHost';
import {
  nativeFacadeStateAfterDisconnectSubmission,
  nativeDisconnectOwnerMatchesFacade,
  nativeDisconnectReceiptCanReleaseRegistry,
  nativeDisconnectStateIsFailed,
  nativeDisconnectStateIsSuccessful,
  RemoteSessionExactDisconnectIdentity,
  RemoteSessionExactDisconnectSubmission,
  RemoteSessionNativeFacadeState,
  RemoteSessionNativeDisconnectOwner
} from './RemoteSessionTerminationPolicy';
import {
  DiagnosticOutcome,
  DiagnosticRuntimeFacts
} from './DiagnosticCapturePolicy';
import {
  diagnosticCaptureIdForModule,
  isDiagnosticModuleCapturing,
  recordDiagnosticEvent
} from './DiagnosticCaptureRuntime';
import {
  DiagnosticDesktopModule,
  DiagnosticRuntimeSamplingLoop,
  DiagnosticRuntimeSamplingScheduler,
  DiagnosticRuntimeSnapshotGate,
  diagnosticDesktopRuntimeEventCode,
  diagnosticDesktopRuntimeFacts,
  diagnosticSshRuntimeFacts
} from './DiagnosticRuntimeSnapshotPolicy';
import { sshDiagnosticErrorCode } from './ssh/observability/SshDiagnosticPolicy';

const TAG = 'ExtensionLoader';

class SystemDiagnosticRuntimeSamplingScheduler implements
  DiagnosticRuntimeSamplingScheduler {
  schedule(callback: () => void, delayMs: number): number {
    return setTimeout(callback, delayMs);
  }

  cancel(timerId: number): void {
    clearTimeout(timerId);
  }
}
const DOMAIN = 0x0013;

interface DetachedSshSession {
  sessionId: number;
  hostId: string;
  detachedAt: number;
}

type DiagnosticConnectionModule =
  'connection.rdp' | 'connection.rustdesk' | 'connection.ssh_sftp' | 'connection.vnc';

type DiagnosticConnectionEventKind = 'request' | 'state' | 'disconnect';

interface DiagnosticConnectionObservation {
  captureId: string;
  state: number;
}

function diagnosticConnectionModule(protocol: string): DiagnosticConnectionModule | null {
  switch (protocol.trim().toLowerCase()) {
    case 'rdp': return 'connection.rdp';
    case 'rustdesk': return 'connection.rustdesk';
    case 'ssh':
    case 'sftp': return 'connection.ssh_sftp';
    case 'vnc': return 'connection.vnc';
    default: return null;
  }
}

function diagnosticConnectionEventCode(moduleId: DiagnosticConnectionModule,
  kind: DiagnosticConnectionEventKind): string {
  if (moduleId === 'connection.rdp') {
    return kind === 'request' ? 'rdp_connection_request' :
      (kind === 'state' ? 'rdp_state_changed' : 'rdp_disconnect');
  }
  if (moduleId === 'connection.rustdesk') {
    return kind === 'request' ? 'rustdesk_connection_request' :
      (kind === 'state' ? 'rustdesk_state_changed' : 'rustdesk_disconnect');
  }
  if (moduleId === 'connection.vnc') {
    return kind === 'request' ? 'vnc_connection_request' :
      (kind === 'state' ? 'vnc_state_changed' : 'vnc_disconnect');
  }
  return kind === 'disconnect' ? 'ssh_disconnect' : 'ssh_session_event';
}

function diagnosticRouteTypeCode(value: string): number {
  switch (value.trim().toLowerCase()) {
    case 'direct':
    case 'direct_rdp':
    case 'direct_ip': return 1;
    case 'http':
    case 'http_connect': return 2;
    case 'rpc': return 3;
    case 'websocket': return 4;
    case 'socks5': return 5;
    case 'ssh_jump': return 6;
    case 'force_relay': return 7;
    case 'auto': return 8;
    case 'frp_tcp': return 9;
    case 'frp_visitor': return 10;
    case 'frp_stcp': return 11;
    case 'frp_sudp': return 12;
    case 'frp_xtcp': return 13;
    case 'legacy_gateway': return 14;
    default: return 0;
  }
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

export interface NativeDisconnectSubmission extends
  RemoteSessionExactDisconnectSubmission {}

export interface NativeDisconnectIdentity extends
  RemoteSessionExactDisconnectIdentity {}

export class ExtensionLoader {
  private static instance: ExtensionLoader;
  private static nextFacadeGeneration: number = 1;
  private currentSessionId: number = -1;
  private facadeGeneration: number = 0;
  private sshConnectGeneration: number = 0;
  private pendingSshConnects: Map<number, SshPendingConnectIdentity> =
    new Map<number, SshPendingConnectIdentity>();
  private rendererHandle: number = -1;
  private decoderHandle: number = -1;
  private audioPlayerHandle: number = -1;
  private teardownRequestId: number = 0;
  private diagnosticsLastErrorAtMs: number = 0;
  private detachedSshSessions: DetachedSshSession[] = [];
  private diagnosticSessionModules: Map<number, DiagnosticConnectionModule> =
    new Map<number, DiagnosticConnectionModule>();
  private diagnosticConnectionStates: Map<number, DiagnosticConnectionObservation> =
    new Map<number, DiagnosticConnectionObservation>();
  private diagnosticRuntimeSnapshots: DiagnosticRuntimeSnapshotGate =
    new DiagnosticRuntimeSnapshotGate();
  private readonly diagnosticRuntimeSamplingLoop: DiagnosticRuntimeSamplingLoop;

  constructor(diagnosticRuntimeScheduler: DiagnosticRuntimeSamplingScheduler =
    new SystemDiagnosticRuntimeSamplingScheduler()) {
    this.diagnosticRuntimeSamplingLoop = new DiagnosticRuntimeSamplingLoop(
      diagnosticRuntimeScheduler, (sessionId: number): void => {
        this.sampleDiagnosticRuntimeForSession(sessionId);
      });
  }

  private recordDiagnosticDesktopRuntime(sessionId: number,
    source: RustDeskDiagnosticsSnapshot): void {
    try {
      const moduleId: DiagnosticConnectionModule | null =
        this.diagnosticModuleForSession(sessionId);
      if (moduleId !== 'connection.rdp' && moduleId !== 'connection.rustdesk' &&
        moduleId !== 'connection.vnc') { return; }
      const desktopModule: DiagnosticDesktopModule = moduleId as DiagnosticDesktopModule;
      const captureId: string = diagnosticCaptureIdForModule(desktopModule);
      const facts: DiagnosticRuntimeFacts =
        diagnosticDesktopRuntimeFacts(desktopModule, source);
      if (!this.diagnosticRuntimeSnapshots.shouldRecord(
        desktopModule, sessionId, captureId, facts, Date.now())) { return; }
      recordDiagnosticEvent(desktopModule,
        diagnosticDesktopRuntimeEventCode(desktopModule), 'state', sessionId, 0,
        source.codec, facts.latencyMs, facts.frames,
        Number.isSafeInteger(source.receivedBytes) && source.receivedBytes > 0 ?
          source.receivedBytes : 0, facts);
    } catch (_err) {
      // Runtime capture must never affect a diagnostics HUD or session poll.
    }
  }

  private recordDiagnosticSshRuntime(sessionId: number,
    source: SshTerminalDiagnosticsSnapshot): void {
    try {
      const moduleId: DiagnosticConnectionModule | null =
        this.diagnosticModuleForSession(sessionId);
      if (moduleId !== 'connection.ssh_sftp') { return; }
      const captureId: string = diagnosticCaptureIdForModule(moduleId);
      const facts: DiagnosticRuntimeFacts = diagnosticSshRuntimeFacts(source);
      if (!this.diagnosticRuntimeSnapshots.shouldRecord(
        moduleId, sessionId, captureId, facts, Date.now())) { return; }
      recordDiagnosticEvent(moduleId, 'ssh_runtime_snapshot', 'state', sessionId,
        source.sessionGeneration > 0 ? source.sessionGeneration : 0, 0,
        facts.latencyMs, facts.frames,
        Number.isSafeInteger(source.remoteReadBytes) && source.remoteReadBytes > 0 ?
          source.remoteReadBytes : 0, facts);
    } catch (_err) {
      // Runtime capture must never affect terminal diagnostics.
    }
  }

  private sampleDiagnosticRuntimeForSession(sessionId: number): void {
    try {
      const moduleId: DiagnosticConnectionModule | null =
        this.diagnosticModuleForSession(sessionId);
      if (moduleId === null || !isDiagnosticModuleCapturing(moduleId)) { return; }
      if (moduleId === 'connection.ssh_sftp') {
        const sshSnapshot: SshTerminalDiagnosticsSnapshot =
          rdpnapi.getSshTerminalDiagnostics(sessionId) as SshTerminalDiagnosticsSnapshot;
        this.recordDiagnosticSshRuntime(sessionId, sshSnapshot);
        return;
      }
      const desktopSnapshot: RustDeskDiagnosticsSnapshot =
        rdpnapi.getSessionDiagnostics(sessionId) as RustDeskDiagnosticsSnapshot;
      this.recordDiagnosticDesktopRuntime(sessionId, desktopSnapshot);
    } catch (_err) {
      // A capture sample cannot alter connection-state polling.
    }
  }

  private recordDiagnosticConnection(moduleId: DiagnosticConnectionModule | null,
    kind: DiagnosticConnectionEventKind, outcome: DiagnosticOutcome,
    sessionId: number = 0, generation: number = 0, code: number = 0): void {
    try {
      if (moduleId === null) { return; }
      recordDiagnosticEvent(moduleId, diagnosticConnectionEventCode(moduleId, kind), outcome,
        sessionId > 0 ? sessionId : 0, generation > 0 ? generation : 0, code);
    } catch (_err) {
      // Diagnostic side effects can never participate in a business transaction.
    }
  }

  private trackDiagnosticSession(sessionId: number,
    moduleId: DiagnosticConnectionModule | null): void {
    try {
      if (moduleId === null || sessionId <= 0) { return; }
      // Keep only protocol identity outside a capture so a later capture can
      // observe an already-live connection. No host or credential is retained.
      this.diagnosticSessionModules.set(sessionId, moduleId);
      this.diagnosticConnectionStates.delete(sessionId);
      this.diagnosticRuntimeSamplingLoop.track(sessionId);
    } catch (_err) {
      // Losing diagnostic identity must not change connection success.
    }
  }

  private forgetDiagnosticSession(sessionId: number): void {
    try {
      if (sessionId <= 0) { return; }
      const moduleId: DiagnosticConnectionModule | undefined =
        this.diagnosticSessionModules.get(sessionId);
      if (moduleId !== undefined) {
        this.diagnosticRuntimeSnapshots.forget(moduleId, sessionId);
      }
      this.diagnosticSessionModules.delete(sessionId);
      this.diagnosticConnectionStates.delete(sessionId);
      this.diagnosticRuntimeSamplingLoop.forget(sessionId);
    } catch (_err) {
      // Best effort only; stale diagnostic identity cannot own native state.
    }
  }

  private diagnosticModuleForSession(sessionId: number): DiagnosticConnectionModule | null {
    try {
      if (sessionId <= 0) { return null; }
      return this.diagnosticSessionModules.get(sessionId) ?? null;
    } catch (_err) {
      return null;
    }
  }

  private recordDiagnosticConnectionState(sessionId: number, state: number): void {
    try {
      const moduleId: DiagnosticConnectionModule | null =
        this.diagnosticModuleForSession(sessionId);
      if (moduleId === null) { return; }
      const captureId: string = diagnosticCaptureIdForModule(moduleId);
      if (captureId.length === 0) {
        this.diagnosticConnectionStates.delete(sessionId);
        return;
      }
      const previous: DiagnosticConnectionObservation | undefined =
        this.diagnosticConnectionStates.get(sessionId);
      if (previous !== undefined && previous.captureId === captureId &&
        previous.state === state) { return; }
      this.diagnosticConnectionStates.set(sessionId, { captureId, state });
      this.recordDiagnosticConnection(moduleId, 'state', 'state', sessionId, 0, state);
    } catch (_err) {
      // A failed diagnostic update must not replace the native state result.
    }
  }

  private recordDiagnosticConnectionStateFailure(sessionId: number): void {
    try {
      const moduleId: DiagnosticConnectionModule | null =
        this.diagnosticModuleForSession(sessionId);
      this.recordDiagnosticConnection(moduleId, 'state', 'failed', sessionId, 0, -1);
    } catch (_err) {
      // Best effort only.
    }
  }

  private transferDiagnosticSessionTo(target: ExtensionLoader, sessionId: number): void {
    let moduleId: DiagnosticConnectionModule | undefined;
    let observation: DiagnosticConnectionObservation | undefined;
    try { moduleId = this.diagnosticSessionModules.get(sessionId); } catch (_err) {}
    try { observation = this.diagnosticConnectionStates.get(sessionId); } catch (_err) {}
    target.forgetDiagnosticSession(sessionId);
    if (moduleId !== undefined) { target.trackDiagnosticSession(sessionId, moduleId); }
    if (observation !== undefined) {
      try {
        target.diagnosticConnectionStates.set(sessionId, {
          captureId: observation.captureId,
          state: observation.state
        });
      } catch (_err) {}
    }
    if (moduleId !== undefined) {
      try { this.diagnosticRuntimeSnapshots.forget(moduleId, sessionId); } catch (_err) {}
    }
    try { this.diagnosticSessionModules.delete(sessionId); } catch (_err) {}
    try { this.diagnosticConnectionStates.delete(sessionId); } catch (_err) {}
    this.diagnosticRuntimeSamplingLoop.forget(sessionId);
  }

  private recordAndForgetAllDiagnosticSessions(submitted: boolean, requestId: number): void {
    try {
      this.diagnosticSessionModules.forEach(
        (moduleId: DiagnosticConnectionModule, sessionId: number): void => {
          this.recordDiagnosticConnection(moduleId, 'disconnect',
            submitted ? (requestId > 0 ? 'started' : 'succeeded') : 'failed', sessionId, 0,
            submitted ? (requestId > 0 ? 1 : 0) : -1);
        });
    } catch (_err) {}
    if (!disconnectAllSubmissionMayReleaseTracking(
      submitted)) { return; }
    this.diagnosticRuntimeSamplingLoop.clear();
    this.diagnosticRuntimeSnapshots.clear();
    try { this.diagnosticSessionModules.clear(); } catch (_err) {}
    try { this.diagnosticConnectionStates.clear(); } catch (_err) {}
  }

  private recordDiagnosticDisconnectSubmission(moduleId: DiagnosticConnectionModule | null,
    sessionId: number, generation: number,
    submission: NativeDisconnectSubmission): void {
    try {
      const outcome: DiagnosticOutcome = !submission.accepted ? 'failed' :
        (submission.terminal ? (submission.successful ? 'succeeded' : 'failed') : 'started');
      // Export a stable status category, never the process-local teardown request id.
      const code: number = submission.successful ? 0 :
        (!submission.accepted ? -1 : (submission.terminal ? -2 : 1));
      this.recordDiagnosticConnection(moduleId, 'disconnect', outcome,
        sessionId, generation, code);
    } catch (_err) {
      // Best effort only.
    }
  }

  private recordDiagnosticRoutes(config: SessionConfig, outcome: DiagnosticOutcome,
    sessionId: number = 0, generation: number = 0, code: number = 0): void {
    try {
      if (!isDiagnosticModuleCapturing('network.routing')) { return; }
      const protocol: string = config.protocol.trim().toLowerCase();
      if (protocol === 'rdp' &&
        (config.rdpEndpointMode === 'microsoft_rd_gateway' ||
          (config.gatewayHost ?? '').trim().length > 0)) {
        recordDiagnosticEvent('network.routing', 'routing_rdp_gateway', outcome,
          sessionId > 0 ? sessionId : 0, generation > 0 ? generation : 0,
          code !== 0 ? code : diagnosticRouteTypeCode(config.rdpGatewayTransport ?? 'auto'));
      }
      if (protocol === 'rustdesk') {
        const strategy: string = config.rdConnectionStrategy ?? 'auto';
        if (strategy !== 'direct_ip' || (config.rdRelayId ?? '').trim().length > 0) {
          recordDiagnosticEvent('network.routing', 'routing_rustdesk_relay', outcome,
            sessionId > 0 ? sessionId : 0, generation > 0 ? generation : 0,
            code !== 0 ? code : diagnosticRouteTypeCode(strategy));
        }
        if ((config.rdAccessToken ?? '').length > 0) {
          recordDiagnosticEvent('network.routing', 'routing_rustdesk_pro', outcome,
            sessionId > 0 ? sessionId : 0, generation > 0 ? generation : 0, code);
        }
      }
      if (protocol === 'vnc' && (config.vncGatewayHost ?? '').trim().length > 0) {
        recordDiagnosticEvent('network.routing', 'routing_vnc_gateway', outcome,
          sessionId > 0 ? sessionId : 0, generation > 0 ? generation : 0, code);
      }
      if ((protocol === 'ssh' || protocol === 'sftp')) {
        const proxyType: string = config.sshProxyType ?? config.sshRoute?.type ?? 'direct';
        if (proxyType !== 'direct') {
          recordDiagnosticEvent('network.routing', 'routing_ssh_proxy', outcome,
            sessionId > 0 ? sessionId : 0, generation > 0 ? generation : 0,
            code !== 0 ? code : diagnosticRouteTypeCode(proxyType));
        }
      }
    } catch (_err) {
      // Reading optional routing metadata is never part of connection success.
    }
  }

  static getInstance(): ExtensionLoader {
    if (!ExtensionLoader.instance) { ExtensionLoader.instance = new ExtensionLoader(); }
    return ExtensionLoader.instance;
  }

  // ====== 协议连接 ======

  connect(config: SessionConfig): number {
    if (!RemoteSessionTransitionGate.getInstance()
      .newSessionAllowed()) {
      return -90;
    }
    const diagnosticModule: DiagnosticConnectionModule | null =
      diagnosticConnectionModule(config.protocol);
    this.recordDiagnosticConnection(diagnosticModule, 'request', 'started');
    this.recordDiagnosticRoutes(config, 'started');
    this.sshConnectGeneration++;
    try {
      const sessionId: number = rdpnapi.connect(config) as number;
      this.currentSessionId = sessionId;
      this.facadeGeneration = sessionId > 0 ? this.allocateFacadeGeneration() : 0;
      this.trackDiagnosticSession(sessionId, diagnosticModule);
      this.recordDiagnosticConnection(diagnosticModule, 'request',
        sessionId > 0 ? 'succeeded' : 'failed', sessionId,
        this.facadeGeneration, sessionId > 0 ? 0 : sessionId);
      this.recordDiagnosticRoutes(config, sessionId > 0 ? 'succeeded' : 'failed',
        sessionId, this.facadeGeneration, sessionId > 0 ? 0 : sessionId);
      return this.currentSessionId;
    } catch (err) {
      this.currentSessionId = -1;
      this.facadeGeneration = 0;
      this.recordDiagnosticConnection(diagnosticModule, 'request', 'failed', 0, 0, -1);
      this.recordDiagnosticRoutes(config, 'failed', 0, 0, -1);
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] connect: code=' + ((err as Record<string, Object>)['code'] || 'ERR') + ' msg=' + JSON.stringify(err));
      return -1;
    }
  }

  connectSshAsync(config: SessionConfig, foreground: boolean = true): SshNativeConnectPromise {
    if (!RemoteSessionTransitionGate.getInstance()
      .newSessionAllowed()) {
      const blocked: SshNativeConnectPromise =
        Promise.resolve(-90) as SshNativeConnectPromise;
      blocked.sessionId = -1;
      blocked.generation = 0;
      return blocked;
    }
    const diagnosticModule: DiagnosticConnectionModule = 'connection.ssh_sftp';
    this.recordDiagnosticConnection(diagnosticModule, 'request', 'started');
    this.recordDiagnosticRoutes(config, 'started');
    try {
      const nativePromise: SshNativeConnectPromise =
        rdpnapi.connectSshAsync(config, foreground) as SshNativeConnectPromise;
      const identity: SshPendingConnectIdentity = {
        sessionId: nativePromise.sessionId,
        generation: nativePromise.generation,
        foreground
      };
      if (identity.sessionId <= 0 || identity.generation <= 0) {
        this.recordDiagnosticConnection(diagnosticModule, 'request', 'failed', 0, 0, -2);
        this.recordDiagnosticRoutes(config, 'failed', 0, 0, -2);
        hilog.error(DOMAIN, TAG, '[ExtensionLoader] connectSshAsync: native identity missing');
        const rejected: SshNativeConnectPromise = Promise.resolve(-1) as SshNativeConnectPromise;
        rejected.sessionId = -1;
        rejected.generation = 0;
        return rejected;
      }
      this.trackDiagnosticSession(identity.sessionId, diagnosticModule);
      this.pendingSshConnects.set(identity.sessionId, identity);
      // Only the foreground owner updates the legacy facade target. Detached
      // SFTP sessions remain addressable through their explicit session id.
      if (foreground) {
        this.currentSessionId = identity.sessionId;
        this.facadeGeneration = this.allocateFacadeGeneration();
      }
      const settled: SshNativeConnectPromise = nativePromise.then(
        (result: number): number => {
          this.pendingSshConnects.delete(identity.sessionId);
          if (foreground && this.currentSessionId === identity.sessionId) {
            this.currentSessionId = result > 0 ? result : -1;
            if (result <= 0) { this.facadeGeneration = 0; }
          }
          this.recordDiagnosticConnection(diagnosticModule, 'request',
            result > 0 ? 'succeeded' : 'failed', identity.sessionId,
            identity.generation, result > 0 ? 0 : result);
          this.recordDiagnosticRoutes(config, result > 0 ? 'succeeded' : 'failed',
            identity.sessionId, identity.generation, result > 0 ? 0 : result);
          if (result <= 0) { this.forgetDiagnosticSession(identity.sessionId); }
          return result;
        },
        (err: Object): number => {
          this.pendingSshConnects.delete(identity.sessionId);
          if (foreground && this.currentSessionId === identity.sessionId) {
            this.currentSessionId = -1;
            this.facadeGeneration = 0;
          }
          this.recordDiagnosticConnection(diagnosticModule, 'request', 'failed',
            identity.sessionId, identity.generation, -1);
          this.recordDiagnosticRoutes(config, 'failed', identity.sessionId,
            identity.generation, -1);
          this.forgetDiagnosticSession(identity.sessionId);
          hilog.error(DOMAIN, TAG, '[ExtensionLoader] connectSshAsync: ' + JSON.stringify(err));
          return -1;
        }) as SshNativeConnectPromise;
      settled.sessionId = identity.sessionId;
      settled.generation = identity.generation;
      return settled;
    } catch (err) {
      this.recordDiagnosticConnection(diagnosticModule, 'request', 'failed', 0, 0, -1);
      this.recordDiagnosticRoutes(config, 'failed', 0, 0, -1);
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
      if (this.currentSessionId === sessionId) {
        this.currentSessionId = -1;
        this.facadeGeneration = 0;
      }
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
      this.facadeGeneration = this.allocateFacadeGeneration();
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
    const identity: NativeDisconnectIdentity | null =
      this.captureExplicitDisconnectIdentity(sessionId);
    return this.disconnectSshSessionWithReceipt(sessionId, identity).requestId;
  }

  /**
   * Submit teardown for one exact SSH session. Facade ownership is retained
   * when the NAPI boundary rejects the request so the caller can retry without
   * making a still-live native session look disconnected.
   */
  disconnectSshSessionWithReceipt(sessionId: number,
    identity: NativeDisconnectIdentity | null = null): NativeDisconnectSubmission {
    if (sessionId <= 0) {
      return this.completedDisconnectSubmission();
    }
    const expected: NativeDisconnectIdentity | null = identity ??
      this.captureExplicitDisconnectIdentity(sessionId);
    if (expected === null || expected.sessionId !== sessionId ||
        !this.explicitDisconnectIdentityIsCurrent(expected)) {
      const rejected: NativeDisconnectSubmission = this.rejectedDisconnectSubmission(false);
      this.recordDiagnosticDisconnectSubmission('connection.ssh_sftp', sessionId, 0, rejected);
      return rejected;
    }
    let receipt: NativeDisconnectReceipt;
    try {
      receipt = rdpnapi.beginDisconnectWithReceipt(
        expected.sessionId, expected.generation, expected.ownerToken,
        -1, -1, -1) as NativeDisconnectReceipt;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[ExtensionLoader] disconnectSshSession: ' + JSON.stringify(err));
      const rejected: NativeDisconnectSubmission = this.rejectedDisconnectSubmission(true);
      this.recordDiagnosticDisconnectSubmission(
        'connection.ssh_sftp', sessionId, expected.generation, rejected);
      return rejected;
    }
    const submission: NativeDisconnectSubmission =
      this.disconnectSubmissionFromNativeReceipt(receipt);
    this.recordDiagnosticDisconnectSubmission(
      'connection.ssh_sftp', sessionId, expected.generation, submission);
    if (!submission.accepted) {
      return submission;
    }
    this.pendingSshConnects.delete(sessionId);
    this.detachedSshSessions = this.detachedSshSessions.filter(
      (candidate: DetachedSshSession): boolean => candidate.sessionId !== sessionId);
    if (this.currentSessionId === sessionId &&
        this.facadeGeneration === expected.facadeGeneration) {
      this.currentSessionId = -1;
      this.facadeGeneration = 0;
    }
    if (submission.requestId > 0) {
      this.teardownRequestId = submission.requestId;
    }
    this.forgetDiagnosticSession(sessionId);
    return submission;
  }

  disconnect(): number {
    return this.disconnectWithReceipt(this.captureDisconnectIdentity()).requestId;
  }

  /**
   * Submit one exact native teardown without erasing the facade handles when
   * the NAPI boundary rejects the request. A zero request id is terminal only
   * when the native call itself returned successfully (synchronous fallback or
  * no remaining native resources).
  */
  disconnectWithReceipt(
    identity: RemoteSessionExactDisconnectIdentity | null = null
  ): NativeDisconnectSubmission {
    const diagnosticSessionId: number = identity === null ? this.currentSessionId : identity.sessionId;
    const diagnosticModule: DiagnosticConnectionModule | null =
      this.diagnosticModuleForSession(diagnosticSessionId);
    const hasNativeOwner: boolean = this.currentSessionId > 0 || this.rendererHandle > 0 ||
      this.decoderHandle > 0 || this.audioPlayerHandle > 0;
    if (!hasNativeOwner) {
      return this.completedDisconnectSubmission();
    }
    const expected: RemoteSessionExactDisconnectIdentity | null = identity ??
      this.captureDisconnectIdentity();
    if (expected === null || !this.disconnectIdentityIsCurrent(expected)) {
      const rejected: NativeDisconnectSubmission = this.rejectedDisconnectSubmission(false);
      this.recordDiagnosticDisconnectSubmission(
        diagnosticModule, diagnosticSessionId, 0, rejected);
      return rejected;
    }
    let submission: NativeDisconnectSubmission;
    try {
      const receipt: NativeDisconnectReceipt = rdpnapi.beginDisconnectWithReceipt(
        expected.sessionId, expected.generation, expected.ownerToken,
        this.rendererHandle, this.decoderHandle,
        this.audioPlayerHandle) as NativeDisconnectReceipt;
      submission = this.disconnectSubmissionFromNativeReceipt(receipt);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] disconnect: ' + JSON.stringify(err));
      submission = this.rejectedDisconnectSubmission(true);
    }
    const nextFacade: RemoteSessionNativeFacadeState =
      nativeFacadeStateAfterDisconnectSubmission({
        sessionId: this.currentSessionId,
        facadeGeneration: this.facadeGeneration,
        rendererHandle: this.rendererHandle,
        decoderHandle: this.decoderHandle,
        audioPlayerHandle: this.audioPlayerHandle
      }, submission.accepted);
    this.currentSessionId = nextFacade.sessionId;
    this.facadeGeneration = nextFacade.facadeGeneration;
    this.rendererHandle = nextFacade.rendererHandle;
    this.decoderHandle = nextFacade.decoderHandle;
    this.audioPlayerHandle = nextFacade.audioPlayerHandle;
    this.recordDiagnosticDisconnectSubmission(
      diagnosticModule, expected.sessionId, expected.generation, submission);
    if (!submission.accepted) {
      return submission;
    }
    if (expected.sessionId > 0) {
      this.pendingSshConnects.delete(expected.sessionId);
    }
    if (submission.requestId > 0) {
      this.teardownRequestId = submission.requestId;
    }
    this.forgetDiagnosticSession(expected.sessionId);
    return submission;
  }

  disconnectAll(): number {
    let requestId: number = 0;
    let submitted: boolean = true;
    let failureDetail: string = '';
    try {
      requestId = rdpnapi.disconnectAll(
        this.rendererHandle, this.decoderHandle, this.audioPlayerHandle) as number;
    } catch (err) {
      submitted = false;
      failureDetail = JSON.stringify(err);
      hilog.error(DOMAIN, TAG,
        '[ExtensionLoader] disconnectAll: ' + failureDetail);
    }
    this.recordAndForgetAllDiagnosticSessions(submitted, requestId);
    if (!disconnectAllSubmissionMayReleaseTracking(submitted)) {
      // Keep current, pending and detached activity visible so account repair
      // cannot prove a false idle state after a rejected native teardown.
      throw new Error(
        'native disconnect-all submission failed: ' + failureDetail);
    }
    this.pendingSshConnects.clear();
    this.currentSessionId = -1;
    this.facadeGeneration = 0;
    this.rendererHandle = -1;
    this.decoderHandle = -1;
    this.audioPlayerHandle = -1;
    // The native boundary synchronously claims/deactivates every active
    // session before returning, even when teardown continues asynchronously.
    this.detachedSshSessions = [];
    if (requestId > 0) {
      this.teardownRequestId = requestId;
    }
    return requestId;
  }

  getDisconnectState(requestId: number): number {
    try {
      return rdpnapi.getDisconnectState(requestId) as number;
    } catch (_err) {
      // Keep a NAPI query failure distinct from native Unknown(0). Neither is
      // proof that the exact request completed successfully.
      return -1;
    }
  }

  async waitForPendingTeardown(timeoutMs: number = 10000): Promise<boolean> {
    const requestId: number = this.teardownRequestId;
    if (requestId <= 0) { return true; }
    return await this.waitForTeardownRequest(requestId, timeoutMs);
  }

  /** Wait only for the supplied disconnect receipt; a later request cannot satisfy it. */
  async waitForTeardownRequest(requestId: number,
    timeoutMs: number = 10000): Promise<boolean> {
    if (!Number.isSafeInteger(requestId) || requestId <= 0 ||
        !Number.isSafeInteger(timeoutMs) || timeoutMs <= 0) {
      return false;
    }
    const startedAtMs: number = Date.now();
    while (Date.now() - startedAtMs < timeoutMs) {
      const state: number = this.getDisconnectState(requestId);
      if (nativeDisconnectStateIsSuccessful(state)) {
        if (this.teardownRequestId === requestId) { this.teardownRequestId = 0; }
        return true;
      }
      if (nativeDisconnectStateIsFailed(state)) {
        return false;
      }
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 20);
      });
    }
    return false;
  }

  isConnected(): boolean { return this.currentSessionId > 0; }

  hasSessionActivity(): boolean {
    if (this.currentSessionId > 0 ||
        this.pendingSshConnects.size > 0) {
      return true;
    }
    for (let index: number = this.detachedSshSessions.length - 1;
      index >= 0; index--) {
      const candidate: DetachedSshSession = this.detachedSshSessions[index];
      let state: number = 0;
      try {
        state = rdpnapi.getConnectionState(candidate.sessionId) as number;
      } catch (_err) {
        state = 0;
      }
      if (nativeSessionStateBlocksAutomaticTransition(state)) {
        return true;
      }
      this.detachedSshSessions.splice(index, 1);
    }
    return false;
  }

  getSessionTransferStatus(sessionId: number): SessionTransferStatus {
    try {
      return rdpnapi.getSessionTransferStatus(sessionId) as SessionTransferStatus;
    } catch (_err) {
      return { rdpDriveMounted: false, rustdeskTransferState: 0, transferId: 0,
        transferredBytes: 0, totalBytes: 0, diagnosticCode: 'status_unavailable' };
    }
  }

  getSessionId(): number { return this.currentSessionId; }

  /** Capture the exact facade/native owner for a later asynchronous teardown. */
  captureDisconnectIdentity(
    expectedSessionId: number = this.currentSessionId
  ): NativeDisconnectIdentity | null {
    if (expectedSessionId !== this.currentSessionId) { return null; }
    if (expectedSessionId > 0) {
      const owner: NativeSessionOwnerIdentity | null =
        this.readNativeSessionOwner(expectedSessionId);
      if (owner === null || this.facadeGeneration <= 0) { return null; }
      return {
        sessionId: owner.sessionId,
        generation: owner.generation,
        ownerToken: owner.ownerToken,
        facadeGeneration: this.facadeGeneration,
        rendererHandle: this.rendererHandle,
        decoderHandle: this.decoderHandle,
        audioPlayerHandle: this.audioPlayerHandle
      };
    }
    if (this.rendererHandle <= 0 && this.decoderHandle <= 0 &&
        this.audioPlayerHandle <= 0) {
      return null;
    }
    if (this.facadeGeneration <= 0) {
      this.facadeGeneration = this.allocateFacadeGeneration();
    }
    return {
      sessionId: -1,
      generation: 0,
      ownerToken: 0,
      facadeGeneration: this.facadeGeneration,
      rendererHandle: this.rendererHandle,
      decoderHandle: this.decoderHandle,
      audioPlayerHandle: this.audioPlayerHandle
    };
  }

  /** Capture an exact native session even when it is currently detached. */
  captureExplicitDisconnectIdentity(sessionId: number,
    expectedGeneration: number = 0): NativeDisconnectIdentity | null {
    if (sessionId <= 0) { return null; }
    const owner: NativeSessionOwnerIdentity | null =
      this.readNativeSessionOwner(sessionId);
    if (owner === null || (expectedGeneration > 0 &&
        owner.generation !== expectedGeneration)) {
      return null;
    }
    return {
      sessionId: owner.sessionId,
      generation: owner.generation,
      ownerToken: owner.ownerToken,
      facadeGeneration: this.currentSessionId === sessionId ?
        this.facadeGeneration : 0,
      rendererHandle: this.currentSessionId === sessionId ? this.rendererHandle : -1,
      decoderHandle: this.currentSessionId === sessionId ? this.decoderHandle : -1,
      audioPlayerHandle: this.currentSessionId === sessionId ? this.audioPlayerHandle : -1
    };
  }

  ownsDisconnectIdentity(identity: NativeDisconnectIdentity | null): boolean {
    return identity !== null && this.disconnectIdentityIsCurrent(identity);
  }

  /**
   * Move the ArkTS facade ownership of one live native session to another
   * window-local loader without reconnecting or copying credentials.
   *
   * The native session and media handles remain unchanged. The source is
   * cleared only after the target has passed every ownership precondition, so
   * an independent-window launch can roll the move back transactionally.
   */
  transferActiveSessionTo(target: ExtensionLoader, expectedSessionId: number): boolean {
    if (target === this || expectedSessionId <= 0 ||
      this.currentSessionId !== expectedSessionId ||
      target.currentSessionId > 0 || target.rendererHandle > 0 ||
      target.decoderHandle > 0 || target.audioPlayerHandle > 0) {
      return false;
    }
    target.currentSessionId = this.currentSessionId;
    target.facadeGeneration = this.facadeGeneration;
    target.rendererHandle = this.rendererHandle;
    target.decoderHandle = this.decoderHandle;
    target.audioPlayerHandle = this.audioPlayerHandle;
    target.sshConnectGeneration = Math.max(
      target.sshConnectGeneration, this.sshConnectGeneration);
    const pending: SshPendingConnectIdentity | undefined =
      this.pendingSshConnects.get(expectedSessionId);
    if (pending !== undefined) {
      target.pendingSshConnects.set(expectedSessionId, pending);
      this.pendingSshConnects.delete(expectedSessionId);
    }
    this.currentSessionId = -1;
    this.facadeGeneration = 0;
    this.rendererHandle = -1;
    this.decoderHandle = -1;
    this.audioPlayerHandle = -1;
    this.transferDiagnosticSessionTo(target, expectedSessionId);
    hilog.info(DOMAIN, TAG, '[ExtensionLoader] session facade transferred session=' +
      expectedSessionId.toString());
    return true;
  }

  private readNativeSessionOwner(sessionId: number): NativeSessionOwnerIdentity | null {
    try {
      const owner: NativeSessionOwnerIdentity | null =
        rdpnapi.getSessionOwnerIdentity(sessionId) as NativeSessionOwnerIdentity | null;
      if (owner === null || owner.sessionId !== sessionId ||
          !Number.isSafeInteger(owner.generation) || owner.generation <= 0 ||
          !Number.isSafeInteger(owner.ownerToken) || owner.ownerToken <= 0) {
        return null;
      }
      return owner;
    } catch (_err) {
      return null;
    }
  }

  private disconnectIdentityIsCurrent(
    identity: RemoteSessionExactDisconnectIdentity
  ): boolean {
    if (identity.sessionId <= 0) {
      return this.currentSessionId <= 0 && identity.generation === 0 &&
        identity.ownerToken === 0 && identity.facadeGeneration > 0 &&
        identity.facadeGeneration === this.facadeGeneration &&
        identity.rendererHandle === this.rendererHandle &&
        identity.decoderHandle === this.decoderHandle &&
        identity.audioPlayerHandle === this.audioPlayerHandle;
    }
    const owner: NativeSessionOwnerIdentity | null =
      this.readNativeSessionOwner(identity.sessionId);
    if (owner === null) { return false; }
    const current: RemoteSessionNativeDisconnectOwner = {
      sessionId: owner.sessionId,
      generation: owner.generation,
      ownerToken: owner.ownerToken,
      facadeGeneration: this.facadeGeneration
    };
    return this.currentSessionId === identity.sessionId &&
      nativeDisconnectOwnerMatchesFacade(identity, current);
  }

  private explicitDisconnectIdentityIsCurrent(identity: NativeDisconnectIdentity): boolean {
    const owner: NativeSessionOwnerIdentity | null =
      this.readNativeSessionOwner(identity.sessionId);
    if (owner === null || owner.generation !== identity.generation ||
        owner.ownerToken !== identity.ownerToken) {
      return false;
    }
    if (this.currentSessionId === identity.sessionId) {
      return identity.facadeGeneration > 0 &&
        identity.facadeGeneration === this.facadeGeneration;
    }
    return identity.facadeGeneration === 0;
  }

  private allocateFacadeGeneration(): number {
    const value: number = ExtensionLoader.nextFacadeGeneration;
    ExtensionLoader.nextFacadeGeneration =
      value >= Number.MAX_SAFE_INTEGER ? 1 : value + 1;
    return value;
  }

  private completedDisconnectSubmission(): NativeDisconnectSubmission {
    return {
      accepted: true, requestId: 0, terminal: true,
      successful: true, retryable: false
    };
  }

  private rejectedDisconnectSubmission(retryable: boolean): NativeDisconnectSubmission {
    return {
      accepted: false, requestId: 0, terminal: false,
      successful: false, retryable
    };
  }

  private disconnectSubmissionFromNativeReceipt(
    receipt: NativeDisconnectReceipt
  ): NativeDisconnectSubmission {
    if (receipt === null || receipt.accepted !== true ||
        !Number.isSafeInteger(receipt.requestId) || receipt.requestId < 0 ||
        !Number.isSafeInteger(receipt.terminalState)) {
      return this.rejectedDisconnectSubmission(false);
    }
    const successful: boolean = nativeDisconnectReceiptCanReleaseRegistry(
      true, receipt.terminalState);
    const failed: boolean = nativeDisconnectStateIsFailed(receipt.terminalState);
    const malformedTerminal: boolean = receipt.requestId <= 0 &&
      !successful && !failed;
    return {
      accepted: true,
      requestId: receipt.requestId,
      terminal: successful || failed || malformedTerminal,
      successful,
      retryable: false
    };
  }

  probeRdpCertificate(host: string, port: number, serverName: string): RdpCertificateInfo {
    recordDiagnosticEvent('connection.rdp', 'rdp_preflight', 'started');
    try {
      const result: RdpCertificateInfo =
        rdpnapi.probeRdpCertificate(host, port, serverName) as RdpCertificateInfo;
      recordDiagnosticEvent('connection.rdp', 'rdp_preflight',
        result.ok ? 'succeeded' : 'failed', 0, 0, result.errorCode);
      return result;
    } catch (err) {
      recordDiagnosticEvent('connection.rdp', 'rdp_preflight', 'failed', 0, 0, -1);
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
        errorMessage: 'RDP 证书探测异常',
        preflightStatus: 'unavailable',
        riskFlags: []
      };
    }
  }

  async probeRdpCertificateAsync(host: string, port: number, serverName: string): Promise<RdpCertificateInfo> {
    recordDiagnosticEvent('connection.rdp', 'rdp_preflight', 'started');
    try {
      const result: RdpCertificateInfo =
        await rdpnapi.probeRdpCertificateAsync(host, port, serverName) as RdpCertificateInfo;
      recordDiagnosticEvent('connection.rdp', 'rdp_preflight',
        result.ok ? 'succeeded' : 'failed', 0, 0, result.errorCode);
      return result;
    } catch (err) {
      recordDiagnosticEvent('connection.rdp', 'rdp_preflight', 'failed', 0, 0, -1);
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
        errorMessage: 'RDP 证书探测异常 [E-RDP-CERT-ASYNC]',
        preflightStatus: 'unavailable',
        riskFlags: []
      };
    }
  }

  async probeRdpCertificateRouteAsync(
    request: RdpPreflightRequest): Promise<RdpPreflightResult> {
    recordDiagnosticEvent('connection.rdp', 'rdp_preflight', 'started',
      0, request.generation ?? 0);
    const gatewayRoute: boolean = (request.route.gatewayHost ?? '').trim().length > 0 ||
      request.route.endpointMode === 'microsoft_rd_gateway';
    if (gatewayRoute) {
      recordDiagnosticEvent('network.routing', 'routing_rdp_gateway', 'started',
        0, request.generation ?? 0,
        diagnosticRouteTypeCode(request.route.gatewayTransport ?? 'auto'));
    }
    try {
      const result: RdpPreflightResult =
        await rdpnapi.probeRdpCertificateRouteAsync(request) as RdpPreflightResult;
      recordDiagnosticEvent('connection.rdp', 'rdp_preflight',
        result.ok ? 'succeeded' : 'failed', 0, result.generation, result.ok ? 0 : -1);
      if (gatewayRoute) {
        recordDiagnosticEvent('network.routing', 'routing_rdp_gateway',
          result.ok ? 'succeeded' : 'failed', 0, result.generation,
          result.ok ? diagnosticRouteTypeCode(result.gatewayTransportNegotiated) : -1);
      }
      return result;
    } catch (err) {
      recordDiagnosticEvent('connection.rdp', 'rdp_preflight', 'failed',
        0, request.generation ?? 0, -1);
      if (gatewayRoute) {
        recordDiagnosticEvent('network.routing', 'routing_rdp_gateway', 'failed',
          0, request.generation ?? 0, -1);
      }
      hilog.error(DOMAIN, TAG,
        '[ExtensionLoader] probeRdpCertificateRouteAsync: ' + JSON.stringify(err));
      const route = request.route;
      const endpointMode: string = route.endpointMode ??
        (route.gatewayHost ? 'microsoft_rd_gateway' : 'direct_rdp');
      const routeIdentity: string = rdpRouteIdentityForValues(
        endpointMode,
        route.targetHost,
        route.targetPort ?? 3389,
        route.targetServerName ?? route.targetHost,
        route.gatewayHost ?? '',
        route.gatewayPort ?? 443,
        route.gatewayServerName ?? route.gatewayHost ?? '',
        route.gatewayTransport ?? 'auto');
      const gatewayRisk: string[] = endpointMode === 'microsoft_rd_gateway'
        ? ['GATEWAY_CERTIFICATE_RISK'] : [];
      const targetRisk: string[] = ['TARGET_CERTIFICATE_RISK'];
      const emptyCertificate: RdpCertificateRecord = {
        present: false, rootTrusted: false, hostMismatch: false, flags: 0,
        host: route.targetHost, port: route.targetPort ?? 3389,
        stage: 'target', serverName: route.targetServerName ?? route.targetHost,
        commonName: '', subject: '', issuer: '', fingerprintSha256: '',
        notBeforeMs: 0, notAfterMs: 0,
        riskFlags: ['CERTIFICATE_METADATA_UNAVAILABLE']
      };
      return {
        ok: false,
        preflightStatus: 'unavailable',
        riskFlags: gatewayRisk.concat(targetRisk),
        gatewayRiskFlags: gatewayRisk,
        targetRiskFlags: targetRisk,
        endpointMode,
        routeIdentity,
        generation: request.generation ?? 0,
        requestId: request.requestId ?? '',
        stage: 'endpoint',
        errorCode: 'E-RDP-PREFLIGHT-NAPI',
        errorMessage: 'RDP 路由证书预检异常',
        gatewayTransportRequested: route.gatewayTransport ?? 'auto',
        gatewayTransportNegotiated: 'unknown',
        gatewayTransportSelected: route.gatewayTransport ?? 'auto',
        requiresGatewayAuth: false,
        requiresUserDecision: true,
        gatewayCertificate: {
          present: false, rootTrusted: false, hostMismatch: false, flags: 0,
          host: route.gatewayHost ?? '', port: route.gatewayPort ?? 443,
          stage: 'gateway', serverName: route.gatewayServerName ?? route.gatewayHost ?? '',
          commonName: '', subject: '', issuer: '', fingerprintSha256: '',
          notBeforeMs: 0, notAfterMs: 0,
          riskFlags: ['CERTIFICATE_METADATA_UNAVAILABLE']
        },
        targetCertificate: emptyCertificate
      } as RdpPreflightResult;
    }
  }

  async probeRustDeskPresenceAsync(host: string, port: number, serverKey: string,
    peerId: string, token: string, direct: boolean, keyMode: number): Promise<RustDeskPresenceResult> {
    recordDiagnosticEvent('connection.rustdesk', 'rustdesk_presence', 'started');
    try {
      const result: RustDeskPresenceResult =
        await rdpnapi.probeRustDeskPresenceAsync(host, port, serverKey, peerId, token,
          direct, keyMode) as RustDeskPresenceResult;
      recordDiagnosticEvent('connection.rustdesk', 'rustdesk_presence',
        result.errorCode === 0 ? 'succeeded' : 'failed', 0, 0,
        result.errorCode, result.latencyMs > 0 ? result.latencyMs : 0);
      return result;
    } catch (err) {
      recordDiagnosticEvent('connection.rustdesk', 'rustdesk_presence', 'failed', 0, 0, -1);
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] probeRustDeskPresenceAsync: ' + JSON.stringify(err));
      return { state: 0, latencyMs: -1, errorCode: 5 };
    }
  }

  probeVncCertificateAsync(host: string, port: number, serverName: string,
    timeoutMs: number = 10000): VncCertificateProbePromise {
    recordDiagnosticEvent('connection.vnc', 'vnc_preflight', 'started');
    try {
      const probe: VncCertificateProbePromise =
        rdpnapi.probeVncCertificateAsync(host, port, serverName, timeoutMs) as VncCertificateProbePromise;
      void probe.then((result): void => {
        recordDiagnosticEvent('connection.vnc', 'vnc_preflight',
          result.ok ? 'succeeded' : 'failed', probe.requestId > 0 ? probe.requestId : 0,
          0, result.errorCode);
      }, (): void => {
        recordDiagnosticEvent('connection.vnc', 'vnc_preflight', 'failed',
          probe.requestId > 0 ? probe.requestId : 0, 0, -1);
      });
      return probe;
    } catch (err) {
      recordDiagnosticEvent('connection.vnc', 'vnc_preflight', 'failed', 0, 0, -1);
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
    recordDiagnosticEvent('network.routing', 'routing_vnc_gateway', 'started',
      0, accountGeneration, diagnosticRouteTypeCode(transport));
    try {
      const probe: VncGatewayDeepHealthPromise =
        rdpnapi.probeVncGatewayDeepAsync(host, port, transport, repeaterMode, target,
        tls, expectedFingerprint, timeoutMs, ownerType, ownerId, userId,
        storeIdentityFingerprint, endpointBindingFingerprint, accountGeneration,
        enabled) as VncGatewayDeepHealthPromise;
      void probe.then((result): void => {
        recordDiagnosticEvent('network.routing', 'routing_vnc_gateway',
          result.protocolReady ? 'succeeded' : 'failed',
          probe.requestId > 0 ? probe.requestId : 0, accountGeneration,
          result.protocolReady ? diagnosticRouteTypeCode(transport) : -1);
      }, (): void => {
        recordDiagnosticEvent('network.routing', 'routing_vnc_gateway', 'failed',
          probe.requestId > 0 ? probe.requestId : 0, accountGeneration, -1);
      });
      return probe;
    } catch (err) {
      recordDiagnosticEvent('network.routing', 'routing_vnc_gateway', 'failed',
        0, accountGeneration, -1);
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
      const snapshot: RustDeskDiagnosticsSnapshot =
        rdpnapi.getSessionDiagnostics(sessionId) as RustDeskDiagnosticsSnapshot;
      this.recordDiagnosticDesktopRuntime(sessionId, snapshot);
      return snapshot;
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
        remoteInputPermissionKnown: false, remoteInputAllowed: true,
        remoteClipboardPermissionKnown: false, remoteClipboardAllowed: true,
        remoteFilePermissionKnown: false, remoteFileAllowed: true,
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

  setRendererCanvasTransform(handle: number, scale: number, panX: number, panY: number,
    rotationQuarterTurns: number = 0): number {
    try {
      return rdpnapi.setRendererCanvasTransform(handle, scale, panX, panY,
        rotationQuarterTurns) as number;
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

  sendKeySequence(sessionId: number, keyCodes: Array<number>): boolean {
    try {
      return rdpnapi.sendKeySequence(sessionId, keyCodes);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] sendKeySequence: ' + JSON.stringify(err));
      return false;
    }
  }

  sendKeyEvents(sessionId: number, keyCodes: Array<number>, pressed: Array<boolean>): boolean {
    try {
      return rdpnapi.sendKeyEvents(sessionId, keyCodes, pressed);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] sendKeyEvents: ' + JSON.stringify(err));
      return false;
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
      const snapshot: SshTerminalDiagnosticsSnapshot =
        rdpnapi.getSshTerminalDiagnostics(sessionId) as SshTerminalDiagnosticsSnapshot;
      this.recordDiagnosticSshRuntime(sessionId, snapshot);
      return snapshot;
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
      const state: number = rdpnapi.getConnectionState(sessionId) as number;
      this.recordDiagnosticConnectionState(sessionId, state);
      this.sampleDiagnosticRuntimeForSession(sessionId);
      return state;
    } catch (err) {
      this.recordDiagnosticConnectionStateFailure(sessionId);
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] getConnectionState: ' + JSON.stringify(err));
      return 0;
    }
  }

  getSshAuthPrompt(sessionId: number, sessionGeneration: number): SshAuthPromptRequest | null {
    try {
      return rdpnapi.getSshAuthPrompt(sessionId, sessionGeneration) as SshAuthPromptRequest | null;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[ExtensionLoader] getSshAuthPrompt code=' +
        sshDiagnosticErrorCode(err));
      return null;
    }
  }

  respondSshAuthPrompt(response: SshAuthPromptResponse): boolean {
    try {
      return rdpnapi.respondSshAuthPrompt(response) as boolean;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[ExtensionLoader] respondSshAuthPrompt code=' +
        sshDiagnosticErrorCode(err));
      return false;
    }
  }

  cancelSshAuthPrompt(sessionId: number, sessionGeneration: number, requestId: number): boolean {
    try {
      return rdpnapi.cancelSshAuthPrompt(
        sessionId, sessionGeneration, requestId) as boolean;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '[ExtensionLoader] cancelSshAuthPrompt code=' +
        sshDiagnosticErrorCode(err));
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
      const accepted: boolean = rdpnapi.submitRustDesk2FA(sessionId, code) as boolean;
      recordDiagnosticEvent('connection.rustdesk', 'rustdesk_two_factor',
        accepted ? 'succeeded' : 'failed', sessionId > 0 ? sessionId : 0, 0,
        accepted ? 0 : -1);
      return accepted;
    } catch (err) {
      recordDiagnosticEvent('connection.rustdesk', 'rustdesk_two_factor',
        'failed', sessionId > 0 ? sessionId : 0, 0, -1);
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
    recordDiagnosticEvent('security.ssh_key', 'ssh_key_generate', 'started');
    try {
      const result: GeneratedSshKeyPair =
        rdpnapi.generateSshKeyPair(keyType, bits, comment, passphrase) as GeneratedSshKeyPair;
      recordDiagnosticEvent('security.ssh_key', 'ssh_key_generate',
        result.ok ? 'succeeded' : 'failed', 0, 0, result.ok ? 0 : -1,
        0, result.keyBits > 0 ? result.keyBits : 0);
      return result;
    } catch (err) {
      recordDiagnosticEvent('security.ssh_key', 'ssh_key_generate', 'failed', 0, 0, -1);
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
    recordDiagnosticEvent('security.ssh_key', 'ssh_key_inspect', 'started');
    try {
      const result: SshPrivateKeyInfo =
        rdpnapi.inspectSshPrivateKey(privateKeyPem, passphrase) as SshPrivateKeyInfo;
      recordDiagnosticEvent('security.ssh_key', 'ssh_key_inspect',
        result.ok || result.encrypted ? 'succeeded' : 'failed',
        0, 0, result.encrypted ? 1 : 0);
      return result;
    } catch (err) {
      recordDiagnosticEvent('security.ssh_key', 'ssh_key_inspect', 'failed', 0, 0, -1);
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
    recordDiagnosticEvent('security.ssh_key', 'ssh_key_passphrase', 'started');
    try {
      const result: string =
        rdpnapi.changeSshPrivateKeyPassphrase(privateKeyPem, oldPassphrase, newPassphrase) as string;
      recordDiagnosticEvent('security.ssh_key', 'ssh_key_passphrase',
        result.length > 0 ? 'succeeded' : 'failed', 0, 0, result.length > 0 ? 0 : -1);
      return result;
    } catch (err) {
      recordDiagnosticEvent('security.ssh_key', 'ssh_key_passphrase', 'failed', 0, 0, -1);
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
    recordDiagnosticEvent('security.ssh_key', 'ssh_key_install', 'started');
    try {
      const result: SshPublicKeyInstallResult =
        rdpnapi.installSshPublicKey(host, port, username, password,
          privateKeyPem, passphrase, publicKey) as SshPublicKeyInstallResult;
      recordDiagnosticEvent('security.ssh_key', 'ssh_key_install',
        result.ok ? 'succeeded' : 'failed', 0, 0, result.code,
        0, result.alreadyInstalled ? 1 : 0);
      return result;
    } catch (err) {
      recordDiagnosticEvent('security.ssh_key', 'ssh_key_install', 'failed', 0, 0, -99);
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
    recordDiagnosticEvent('security.ssh_key', 'ssh_key_auth_test', 'started');
    try {
      const result: SshAuthTestResult =
        rdpnapi.testSshKeyAuth(host, port, username, privateKeyPem, passphrase, proxy) as SshAuthTestResult;
      recordDiagnosticEvent('security.ssh_key', 'ssh_key_auth_test',
        result.ok ? 'succeeded' : 'failed', 0, 0, result.code);
      return result;
    } catch (err) {
      recordDiagnosticEvent('security.ssh_key', 'ssh_key_auth_test', 'failed', 0, 0, -99);
      hilog.error(DOMAIN, TAG, '[ExtensionLoader] testSshKeyAuth: ' + JSON.stringify(err));
      return { ok: false, code: -99,
               message: '[CC-SSHKEY-08] testSshKeyAuth NAPI error: ' + JSON.stringify(err) };
    }
  }

  /** 测试 SSH 密钥认证；native 网络工作在线程池执行，不阻塞 ArkTS/UI 线程。 */
  async testSshKeyAuthAsync(host: string, port: number, username: string,
                            privateKeyPem: string, passphrase: string,
                            proxy?: SshProxyConfig): Promise<SshAuthTestResult> {
    recordDiagnosticEvent('security.ssh_key', 'ssh_key_auth_test', 'started');
    try {
      const result: SshAuthTestResult = await rdpnapi.testSshKeyAuthAsync(
        host, port, username, privateKeyPem, passphrase, proxy) as SshAuthTestResult;
      recordDiagnosticEvent('security.ssh_key', 'ssh_key_auth_test',
        result.ok ? 'succeeded' : 'failed', 0, 0, result.code);
      return result;
    } catch (err) {
      recordDiagnosticEvent('security.ssh_key', 'ssh_key_auth_test', 'failed', 0, 0, -99);
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
    recordDiagnosticEvent('connection.ssh_sftp', 'ssh_preflight', 'started');
    if ((proxy?.type ?? 'direct') !== 'direct') {
      recordDiagnosticEvent('network.routing', 'routing_ssh_proxy', 'started',
        0, 0, diagnosticRouteTypeCode(proxy?.type ?? ''));
    }
    try {
      const result: SshHostKeyInfo =
        rdpnapi.probeSshHostKey(host, port, proxy) as SshHostKeyInfo;
      recordDiagnosticEvent('connection.ssh_sftp', 'ssh_preflight',
        result.ok ? 'succeeded' : 'failed', 0, 0, result.errorCode);
      if ((proxy?.type ?? 'direct') !== 'direct') {
        recordDiagnosticEvent('network.routing', 'routing_ssh_proxy',
          result.ok ? 'succeeded' : 'failed', 0, 0,
          result.ok ? diagnosticRouteTypeCode(proxy?.type ?? '') : result.errorCode);
      }
      return result;
    } catch (err) {
      recordDiagnosticEvent('connection.ssh_sftp', 'ssh_preflight', 'failed', 0, 0, -99);
      if ((proxy?.type ?? 'direct') !== 'direct') {
        recordDiagnosticEvent('network.routing', 'routing_ssh_proxy', 'failed', 0, 0, -99);
      }
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
    recordDiagnosticEvent('connection.ssh_sftp', 'ssh_preflight', 'started');
    if ((proxy?.type ?? 'direct') !== 'direct') {
      recordDiagnosticEvent('network.routing', 'routing_ssh_proxy', 'started',
        0, 0, diagnosticRouteTypeCode(proxy?.type ?? ''));
    }
    try {
      const result: SshHostKeyInfo =
        await rdpnapi.probeSshHostKeyAsync(host, port, proxy) as SshHostKeyInfo;
      recordDiagnosticEvent('connection.ssh_sftp', 'ssh_preflight',
        result.ok ? 'succeeded' : 'failed', 0, 0, result.errorCode);
      if ((proxy?.type ?? 'direct') !== 'direct') {
        recordDiagnosticEvent('network.routing', 'routing_ssh_proxy',
          result.ok ? 'succeeded' : 'failed', 0, 0,
          result.ok ? diagnosticRouteTypeCode(proxy?.type ?? '') : result.errorCode);
      }
      return result;
    } catch (err) {
      recordDiagnosticEvent('connection.ssh_sftp', 'ssh_preflight', 'failed', 0, 0, -99);
      if ((proxy?.type ?? 'direct') !== 'direct') {
        recordDiagnosticEvent('network.routing', 'routing_ssh_proxy', 'failed', 0, 0, -99);
      }
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
    this.facadeGeneration = 0;
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
