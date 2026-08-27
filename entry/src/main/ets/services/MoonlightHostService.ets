import rdpnapi from 'librdpnapi.so';
import { MoonlightAppCacheEntry, moonlightAppCacheIdentity } from '../model/MoonlightAppCache';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from './AccountScopePolicy';
import {
  MoonlightAppCacheCode,
  MoonlightAppCacheResult,
  MoonlightAppCacheService
} from './MoonlightAppCacheService';
import { CloudStore } from './CloudStore';
import { moonlightOwnerScopeFingerprint } from './MoonlightRuntimeSupport';
import {
  MoonlightRuntimeOwnerAdmissionPort,
  MoonlightRuntimeOwnerRegistry
} from './MoonlightRuntimeOwnerRegistry';
import { DiagnosticOutcome } from './DiagnosticCapturePolicy';
import { recordDiagnosticEvent } from './DiagnosticCaptureRuntime';

export type MoonlightNativeOperation =
  'pair' | 'catalog' | 'asset' | 'launch' | 'resume' | 'quit' | 'unpair' |
  'delete_identity';
export type MoonlightNativeCode =
  'ok' | 'invalid_argument' | 'busy' | 'runtime_proof_required' | 'unavailable' |
  'unpaired' | 'app_not_found' | 'invalid_catalog' | 'resume_required' |
  'host_busy' | 'confirmation_required' | 'action_rejected' | 'outcome_unknown' |
  'cancelled' | 'stale' | 'deadline_exceeded' | 'transport_failure' |
  'protocol_failure' | 'repair_required' | 'shutting_down';
export type MoonlightNativeTruth = 'not_attempted' | 'confirmed' | 'failed' | 'unknown';
export type MoonlightNativeTerminalStage = 'complete' | 'failed' | 'cancelled';

export interface MoonlightNativeRequestKey {
  requestId: number;
  generation: number;
  ownerToken: number;
}

export interface MoonlightNativeAddress {
  value: string;
  family: 'unspecified' | 'ipv4' | 'ipv6';
}

export interface MoonlightNativeEndpoint {
  serverName: string;
  addresses: MoonlightNativeAddress[];
  httpPort?: number;
  httpsPort?: number;
  pinnedTrustAvailable?: boolean;
  allowHttpPairingCandidate?: boolean;
}

export interface MoonlightNativeLaunchConfiguration {
  width?: number;
  height?: number;
  refreshRate?: number;
  additionalStates?: boolean;
  sops?: boolean;
  hdr?: boolean;
  playAudioOnHost?: boolean;
  surroundAudioInfo?: number;
  remoteControllersBitmap?: number;
  gamepadMask?: number;
  persistGamepads?: boolean;
  videoCodec?: 'h264' | 'hevc' | 'av1';
  resolutionPolicy?: 'exact' | 'hostCapability';
}

export interface MoonlightNativeRequest {
  operation: MoonlightNativeOperation;
  key: MoonlightNativeRequestKey;
  ownerScopeFingerprint: string;
  installationId?: string;
  hostId: string;
  serverUuid: string;
  pinnedCertificateSha256?: string;
  endpoint: MoonlightNativeEndpoint;
  timeoutMs?: number;
  appId?: number;
  catalogGeneration?: number;
  expectedCurrentAppId?: number;
  userConfirmedTermination?: boolean;
  allowLegacySha1?: boolean;
  pin?: Uint8Array;
  launchConfiguration?: MoonlightNativeLaunchConfiguration;
}

export interface MoonlightNativeApp {
  id: number;
  title: string;
  hdrSupported?: boolean;
}

export interface MoonlightNativeDiagnostic {
  stage: string;
  code: string;
  httpStatus: number;
  xmlStatus: number;
  transportAttempts: number;
  byteCount: number;
  appIdFingerprint: number;
}

export interface MoonlightNativeResult {
  operation: MoonlightNativeOperation;
  key: MoonlightNativeRequestKey;
  code: MoonlightNativeCode;
  terminalStage: MoonlightNativeTerminalStage;
  preflightTruth: MoonlightNativeTruth;
  actionTruth: MoonlightNativeTruth;
  postconditionTruth: MoonlightNativeTruth;
  partialAppCount: number;
  observedAtMs: number;
  idempotent: boolean;
  mutationMayHaveBeenSent: boolean;
  identityExistingCount: number;
  identityDeletedCount: number;
  identityRemainingCount: number;
  apps: MoonlightNativeApp[];
  asset: ArrayBuffer;
  certificateSha256?: string;
  rtspSessionUrl?: string;
  diagnostics: MoonlightNativeDiagnostic[];
}

export interface MoonlightBridgeCapabilities {
  bridgeCompiled: boolean;
  identityReady: boolean;
  identityDeletionReady: boolean;
  transportReady: boolean;
  trustReady: boolean;
  commitReady: boolean;
  pairingReady: boolean;
  hostControlReady: boolean;
  blocker: string;
}

export interface MoonlightNativeEvent {
  sequence: number;
  monotonicTimestampMs: number;
  operation: MoonlightNativeOperation;
  key: MoonlightNativeRequestKey;
  code: MoonlightNativeCode;
  terminalStage: MoonlightNativeTerminalStage;
}

export interface MoonlightNativeStreamStartResult {
  accepted: boolean;
  code: string;
  sessionId: number;
  generation: number;
  ownerToken: number;
}

export interface MoonlightNativeStreamStartRequest {
  launchKey: MoonlightNativeRequestKey;
  hostId: string;
  serverUuid: string;
  appId: number;
  rendererHandle: number;
  surfaceWidth: number;
  surfaceHeight: number;
  configuredBitrateKbps: number;
  codecPreference: 'h264' | 'hevc' | 'av1';
  hdr: boolean;
  yuv444: boolean;
  latencyMode: 'lowLatency' | 'balanced' | 'smooth';
  audioEnabled: boolean;
  audioChannels: 'stereo' | 'surround51' | 'surround71';
  playAudioOnHost: boolean;
  resetRemoteInputBeforeAdmission: boolean;
  desktopSurfaceCompatibility: boolean;
  streamEncryption: 'auto' | 'required' | 'compatible';
}

export interface MoonlightNativeStreamSnapshot {
  matched: boolean;
  code: string;
  sessionId: number;
  generation: number;
  ownerToken: number;
  transportReady: boolean;
  videoReady: boolean;
  audioReady: boolean;
  inputReady: boolean;
  controllerReady: boolean;
  physicalControllerReady: boolean;
  inputMayBeStuck: boolean;
  presentationFrameReady?: boolean;
  firstFrameReady: boolean;
  terminal: boolean;
  lastSequence: number;
  sampledAtMonotonicMs?: number;
  acceptedVideoFrames?: number;
  droppedVideoFrames?: number;
  acceptedVideoBytes?: number;
  rendererPresentedFrames?: number;
  acceptedAudioPackets?: number;
  rejectedAudioPackets?: number;
  acceptedAudioBytes?: number;
  rejectedInputEvents?: number;
  streamWidth?: number;
  streamHeight?: number;
  targetFps?: number;
  configuredBitrateKbps?: number;
  codec?: 'h264' | 'hevc' | 'av1';
  decoderQueueDepth?: number;
  decoderCodecLatencyMs?: number;
  decoderSurfaceUpdateFailures?: number;
}

export interface MoonlightNativePort {
  getCapabilities(): MoonlightBridgeCapabilities;
  requestAsync(request: MoonlightNativeRequest): Promise<MoonlightNativeResult>;
  cancelRequest(key: MoonlightNativeRequestKey): boolean;
  cancelOwner(ownerToken: number): number;
  pollEvents(ownerToken: number, afterSequence: number, limit: number): MoonlightNativeEvent[];
}

export interface MoonlightAccountLeasePort {
  currentAccountLease(): AccountSessionLease | null;
  isLeaseCurrent(lease: AccountSessionLease): boolean;
}

export interface MoonlightHostContext {
  lease: AccountSessionLease;
  ownerScopeFingerprint: string;
  ownerToken: number;
  generation: number;
  /** Durable local record key used only for owner-scoped app-cache rows. */
  localHostId?: string;
  /** Native identity key. This must stay aligned with the pairing identity. */
  hostId: string;
  serverUuid: string;
  installationId?: string;
  pinnedCertificateSha256?: string;
  endpoint: MoonlightNativeEndpoint;
  timeoutMs: number;
}

export type MoonlightHostServiceCode =
  MoonlightNativeCode | 'stale_lease' | 'invalid_context' | 'native_exception' |
  'cache_failed' | 'disposed' | 'lifecycle_closed';

export interface MoonlightHostServiceResult {
  ok: boolean;
  code: MoonlightHostServiceCode;
  nativeCode: MoonlightNativeCode | '';
  key: MoonlightNativeRequestKey;
  stale: boolean;
  cacheCode: MoonlightAppCacheCode | '';
  visibleApps: MoonlightAppCacheEntry[];
  nativeResult: MoonlightNativeResult | null;
}

const MAX_SAFE_INTEGER: number = 9007199254740991;
const APP_CACHE_TTL_MS: number = 24 * 60 * 60 * 1000;
const MAX_STANDARD_OPERATION_TIMEOUT_MS: number = 30000;

function emptyCapabilities(): MoonlightBridgeCapabilities {
  return {
    bridgeCompiled: false,
    identityReady: false,
    identityDeletionReady: false,
    transportReady: false,
    trustReady: false,
    commitReady: false,
    pairingReady: false,
    hostControlReady: false,
    blocker: 'runtime_proof_required'
  };
}

function emptyKey(): MoonlightNativeRequestKey {
  return { requestId: 0, generation: 0, ownerToken: 0 };
}

function keysEqual(left: MoonlightNativeRequestKey,
  right: MoonlightNativeRequestKey): boolean {
  return left.requestId === right.requestId &&
    left.generation === right.generation &&
    left.ownerToken === right.ownerToken;
}

function diagnosticMoonlightHostEvent(operation: MoonlightNativeOperation): string {
  if (operation === 'pair' || operation === 'unpair' || operation === 'delete_identity') {
    return 'moonlight_pair';
  }
  if (operation === 'catalog' || operation === 'asset') { return 'moonlight_catalog'; }
  return 'moonlight_launch';
}

function diagnosticMoonlightHostOutcome(code: MoonlightHostServiceCode): DiagnosticOutcome {
  if (code === 'ok') { return 'succeeded'; }
  if (code === 'cancelled') { return 'cancelled'; }
  if (code === 'deadline_exceeded') { return 'timeout'; }
  if (code === 'stale' || code === 'stale_lease' || code === 'disposed' ||
      code === 'lifecycle_closed') { return 'skipped'; }
  return 'failed';
}

function diagnosticMoonlightHostCode(code: MoonlightHostServiceCode): number {
  switch (code) {
    case 'ok': return 0;
    case 'invalid_argument':
    case 'invalid_context': return 1;
    case 'busy': return 2;
    case 'runtime_proof_required': return 3;
    case 'unavailable': return 4;
    case 'unpaired': return 5;
    case 'app_not_found': return 6;
    case 'invalid_catalog': return 7;
    case 'resume_required': return 8;
    case 'host_busy': return 9;
    case 'confirmation_required': return 10;
    case 'action_rejected': return 11;
    case 'outcome_unknown': return 12;
    case 'cancelled': return 13;
    case 'stale':
    case 'stale_lease': return 14;
    case 'deadline_exceeded': return 15;
    case 'transport_failure': return 16;
    case 'protocol_failure': return 17;
    case 'repair_required': return 18;
    case 'shutting_down': return 19;
    case 'native_exception': return 20;
    case 'cache_failed': return 21;
    case 'disposed': return 22;
    case 'lifecycle_closed': return 23;
  }
}

function serviceResult(code: MoonlightHostServiceCode,
  key: MoonlightNativeRequestKey = emptyKey(),
  nativeResult: MoonlightNativeResult | null = null,
  cacheCode: MoonlightAppCacheCode | '' = '',
  visibleApps: MoonlightAppCacheEntry[] = []): MoonlightHostServiceResult {
  if (nativeResult !== null) {
    recordDiagnosticEvent('connection.moonlight',
      diagnosticMoonlightHostEvent(nativeResult.operation),
      diagnosticMoonlightHostOutcome(code), key.requestId, key.generation,
      diagnosticMoonlightHostCode(code), 0,
      nativeResult.partialAppCount > 0 ? nativeResult.partialAppCount : 0);
  }
  return {
    ok: code === 'ok',
    code: code,
    nativeCode: nativeResult === null ? '' : nativeResult.code,
    key: key,
    stale: code === 'stale' || code === 'stale_lease' || code === 'disposed',
    cacheCode: cacheCode,
    visibleApps: visibleApps,
    nativeResult: nativeResult
  };
}

function safePositiveInteger(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0;
}

function hostContextShapeValid(context: MoonlightHostContext): boolean {
  return context !== undefined && context !== null &&
    /^[0-9a-f]{64}$/.test(context.ownerScopeFingerprint) &&
    safePositiveInteger(context.ownerToken) &&
    safePositiveInteger(context.generation) &&
    context.hostId.trim().length > 0 && context.hostId.length <= 256 &&
    (context.localHostId === undefined ||
      (context.localHostId.trim().length > 0 && context.localHostId.length <= 256)) &&
    context.serverUuid.trim().length > 0 && context.serverUuid.length <= 256 &&
    (context.installationId === undefined ||
      (context.installationId.trim().length > 0 && context.installationId.length <= 256)) &&
    (context.pinnedCertificateSha256 === undefined ||
      /^[0-9a-f]{64}$/.test(context.pinnedCertificateSha256)) &&
    Number.isSafeInteger(context.timeoutMs) && context.timeoutMs >= 100 &&
    context.timeoutMs <= 120000 && context.endpoint !== undefined &&
    context.endpoint !== null;
}

function nativeResultShapeMatches(result: MoonlightNativeResult,
  request: MoonlightNativeRequest): boolean {
  return result !== undefined && result !== null &&
    result.key !== undefined && result.key !== null &&
    result.operation === request.operation && keysEqual(result.key, request.key) &&
    Number.isSafeInteger(result.partialAppCount) && result.partialAppCount >= 0 &&
    Number.isSafeInteger(result.observedAtMs) && result.observedAtMs >= 0 &&
    result.identityExistingCount === 0 &&
    result.identityDeletedCount === 0 &&
    result.identityRemainingCount === 0;
}

class MoonlightNapiPort implements MoonlightNativePort {
  getCapabilities(): MoonlightBridgeCapabilities {
    return rdpnapi.moonlightGetBridgeCapabilities();
  }

  requestAsync(request: MoonlightNativeRequest): Promise<MoonlightNativeResult> {
    return rdpnapi.moonlightRequestAsync(request);
  }

  cancelRequest(key: MoonlightNativeRequestKey): boolean {
    return rdpnapi.moonlightCancelRequest(key);
  }

  cancelOwner(ownerToken: number): number {
    return rdpnapi.moonlightCancelOwner(ownerToken);
  }

  pollEvents(ownerToken: number, afterSequence: number,
    limit: number): MoonlightNativeEvent[] {
    return rdpnapi.moonlightPollEvents(ownerToken, afterSequence, limit);
  }
}

interface PendingRequest {
  key: MoonlightNativeRequestKey;
  lease: AccountSessionLease;
}

export class MoonlightHostService {
  private readonly native: MoonlightNativePort;
  private readonly leases: MoonlightAccountLeasePort;
  private readonly cache: MoonlightAppCacheService;
  private readonly ownerAdmission: MoonlightRuntimeOwnerAdmissionPort | null;
  private readonly pending: Map<string, PendingRequest> = new Map<string, PendingRequest>();
  private readonly disposedOwners: Set<number> = new Set<number>();
  private nextRequestId: number = 1;
  private staleCompletionCount: number = 0;
  private staleEventCount: number = 0;

  constructor(native: MoonlightNativePort = new MoonlightNapiPort(),
    leases: MoonlightAccountLeasePort = CloudStore.getInstance(),
    cache: MoonlightAppCacheService = new MoonlightAppCacheService(CloudStore.getInstance()),
    ownerAdmission: MoonlightRuntimeOwnerAdmissionPort | null =
      MoonlightRuntimeOwnerRegistry.getInstance()) {
    this.native = native;
    this.leases = leases;
    this.cache = cache;
    this.ownerAdmission = ownerAdmission;
  }

  capabilities(): MoonlightBridgeCapabilities {
    try {
      return this.native.getCapabilities();
    } catch (_) {
      return emptyCapabilities();
    }
  }

  async pair(context: MoonlightHostContext, installationId: string,
    pin: Uint8Array, allowLegacySha1: boolean = false): Promise<MoonlightHostServiceResult> {
    const pinCopy: Uint8Array = new Uint8Array(pin);
    const request: MoonlightNativeRequest = this.baseRequest('pair', context);
    request.installationId = installationId;
    request.allowLegacySha1 = allowLegacySha1;
    request.pin = pinCopy;
    return this.execute(context, request, (): void => { pinCopy.fill(0); });
  }

  async unpair(context: MoonlightHostContext): Promise<MoonlightHostServiceResult> {
    return this.execute(context, this.baseRequest('unpair', context));
  }

  async catalog(context: MoonlightHostContext): Promise<MoonlightHostServiceResult> {
    return this.execute(context, this.baseRequest('catalog', context), undefined, true);
  }

  /** Runtime probe variant: returns the native catalog without touching any
   * app-cache or synchronization table. The local-only Moonlight add flow
   * uses this until catalog persistence is explicitly enabled. */
  async catalogRuntime(context: MoonlightHostContext): Promise<MoonlightHostServiceResult> {
    return this.execute(context, this.baseRequest('catalog', context));
  }

  async asset(context: MoonlightHostContext, appId: number,
    catalogGeneration: number): Promise<MoonlightHostServiceResult> {
    const request: MoonlightNativeRequest = this.baseRequest('asset', context);
    request.appId = appId;
    request.catalogGeneration = catalogGeneration;
    return this.execute(context, request);
  }

  async launch(context: MoonlightHostContext, appId: number,
    configuration: MoonlightNativeLaunchConfiguration): Promise<MoonlightHostServiceResult> {
    return this.launchOrResume('launch', context, appId, configuration);
  }

  async resume(context: MoonlightHostContext, appId: number,
    configuration: MoonlightNativeLaunchConfiguration): Promise<MoonlightHostServiceResult> {
    return this.launchOrResume('resume', context, appId, configuration);
  }

  async quit(context: MoonlightHostContext, expectedCurrentAppId: number,
    userConfirmedTermination: boolean): Promise<MoonlightHostServiceResult> {
    const request: MoonlightNativeRequest = this.baseRequest('quit', context);
    request.expectedCurrentAppId = expectedCurrentAppId;
    request.userConfirmedTermination = userConfirmedTermination;
    return this.execute(context, request);
  }

  cancel(key: MoonlightNativeRequestKey): boolean {
    if (!safePositiveInteger(key.requestId) || !safePositiveInteger(key.generation) ||
        !safePositiveInteger(key.ownerToken)) {
      return false;
    }
    try {
      return this.native.cancelRequest(key);
    } catch (_) {
      return false;
    }
  }

  disposeOwner(ownerToken: number): number {
    if (!safePositiveInteger(ownerToken)) { return 0; }
    this.disposedOwners.add(ownerToken);
    if (this.ownerAdmission !== null) {
      this.ownerAdmission.retireOwner(ownerToken);
    }
    try {
      return this.native.cancelOwner(ownerToken);
    } catch (_) {
      return 0;
    }
  }

  cancelOwner(ownerToken: number): number {
    if (!safePositiveInteger(ownerToken)) { return 0; }
    try {
      return this.native.cancelOwner(ownerToken);
    } catch (_) {
      return 0;
    }
  }

  pollEvents(context: MoonlightHostContext, afterSequence: number = 0,
    limit: number = 64): MoonlightNativeEvent[] {
    let captured: AccountSessionLease;
    try {
      captured = cloneAccountSessionLease(context.lease);
    } catch (_) {
      return [];
    }
    if (!this.contextCurrent(context, captured) ||
        this.disposedOwners.has(context.ownerToken) ||
        !Number.isSafeInteger(afterSequence) || afterSequence < 0 ||
        !Number.isSafeInteger(limit) || limit < 1 || limit > 128) {
      return [];
    }
    let source: MoonlightNativeEvent[];
    try {
      source = this.native.pollEvents(context.ownerToken, afterSequence, limit);
    } catch (_) {
      return [];
    }
    const accepted: MoonlightNativeEvent[] = [];
    for (let i = 0; i < source.length; i++) {
      const event: MoonlightNativeEvent = source[i];
      if (event.key.ownerToken === context.ownerToken &&
          event.key.generation === context.generation &&
          this.contextCurrent(context, captured) &&
          !this.disposedOwners.has(context.ownerToken)) {
        accepted.push(event);
      } else {
        this.staleEventCount++;
      }
    }
    return accepted;
  }

  staleCompletions(): number { return this.staleCompletionCount; }
  staleEvents(): number { return this.staleEventCount; }

  private async launchOrResume(operation: 'launch' | 'resume',
    context: MoonlightHostContext, appId: number,
    configuration: MoonlightNativeLaunchConfiguration): Promise<MoonlightHostServiceResult> {
    if (configuration === undefined || configuration === null) {
      return serviceResult('invalid_context');
    }
    // Native Host Control deliberately launches only from an authenticated
    // catalog snapshot owned by this exact lifecycle fence. Refresh it here so
    // a valid locally cached catalog remains launchable after process/page
    // recreation and cannot authorize an app removed from the host.
    const catalogRequest: MoonlightNativeRequest = this.baseRequest('catalog', context);
    const catalogResult: MoonlightHostServiceResult =
      await this.execute(context, catalogRequest);
    if (!catalogResult.ok) { return catalogResult; }
    const request: MoonlightNativeRequest = this.baseRequest(operation, context);
    request.appId = appId;
    request.catalogGeneration = context.generation;
    request.launchConfiguration = configuration;
    return this.execute(context, request);
  }

  private baseRequest(operation: MoonlightNativeOperation,
    context: MoonlightHostContext): MoonlightNativeRequest {
    const request: MoonlightNativeRequest = {
      operation: operation,
      key: {
        requestId: this.allocateRequestId(),
        generation: context.generation,
        ownerToken: context.ownerToken
      },
      ownerScopeFingerprint: context.ownerScopeFingerprint,
      hostId: context.hostId,
      serverUuid: context.serverUuid,
      endpoint: context.endpoint,
      timeoutMs: operation === 'pair' ? context.timeoutMs :
        Math.min(context.timeoutMs, MAX_STANDARD_OPERATION_TIMEOUT_MS)
    };
    if (context.installationId !== undefined) {
      request.installationId = context.installationId;
    }
    if (context.pinnedCertificateSha256 !== undefined) {
      request.pinnedCertificateSha256 = context.pinnedCertificateSha256;
    }
    return request;
  }

  private allocateRequestId(): number {
    for (let attempts = 0; attempts < 1024; attempts++) {
      const candidate: number = this.nextRequestId;
      this.nextRequestId = candidate >= MAX_SAFE_INTEGER ? 1 : candidate + 1;
      let inUse: boolean = false;
      this.pending.forEach((pending: PendingRequest): void => {
        if (pending.key.requestId === candidate) { inUse = true; }
      });
      if (!inUse) { return candidate; }
    }
    return 0;
  }

  private requestIdentity(key: MoonlightNativeRequestKey): string {
    return key.requestId.toString() + ':' + key.generation.toString() + ':' +
      key.ownerToken.toString();
  }

  private contextCurrent(context: MoonlightHostContext,
    captured: AccountSessionLease): boolean {
    try {
      return hostContextShapeValid(context) &&
        context.ownerScopeFingerprint ===
          moonlightOwnerScopeFingerprint(captured.ownerScopeId) &&
        accountSessionLeaseEquals(context.lease, captured) &&
        accountSessionLeaseEquals(this.leases.currentAccountLease(), captured) &&
        this.leases.isLeaseCurrent(captured);
    } catch (_) {
      return false;
    }
  }

  private releaseSafely(release: (() => void) | undefined): void {
    if (release === undefined) { return; }
    try { release(); } catch (_) {}
  }

  private async execute(context: MoonlightHostContext,
    request: MoonlightNativeRequest, release: (() => void) | undefined = undefined,
    commitCatalog: boolean = false): Promise<MoonlightHostServiceResult> {
    let captured: AccountSessionLease;
    try {
      captured = cloneAccountSessionLease(context.lease);
    } catch (_) {
      this.releaseSafely(release);
      return serviceResult('invalid_context', request.key);
    }
    if (!this.contextCurrent(context, captured) || request.key.requestId === 0) {
      this.releaseSafely(release);
      return serviceResult('invalid_context', request.key);
    }
    if (this.disposedOwners.has(context.ownerToken)) {
      this.releaseSafely(release);
      return serviceResult('disposed', request.key);
    }
    if (this.ownerAdmission !== null &&
        !this.ownerAdmission.beginOwnerRequest(context.ownerToken, captured)) {
      this.releaseSafely(release);
      return serviceResult('lifecycle_closed', request.key);
    }
    const identity: string = this.requestIdentity(request.key);
    this.pending.set(identity, { key: request.key, lease: captured });
    let nativePromise: Promise<MoonlightNativeResult>;
    try {
      nativePromise = this.native.requestAsync(request);
    } catch (_) {
      this.pending.delete(identity);
      this.finishOwnerRequest(context.ownerToken, captured);
      this.releaseSafely(release);
      return serviceResult('native_exception', request.key);
    }
    this.releaseSafely(release);

    let nativeResult: MoonlightNativeResult;
    try {
      nativeResult = await nativePromise;
    } catch (_) {
      this.pending.delete(identity);
      this.finishOwnerRequest(context.ownerToken, captured);
      return serviceResult('native_exception', request.key);
    }
    this.pending.delete(identity);
    this.finishOwnerRequest(context.ownerToken, captured);
    if (!nativeResultShapeMatches(nativeResult, request)) {
      return serviceResult('protocol_failure', request.key, nativeResult);
    }
    if (!this.contextCurrent(context, captured) ||
        this.disposedOwners.has(context.ownerToken)) {
      this.staleCompletionCount++;
      return serviceResult(this.disposedOwners.has(context.ownerToken) ?
        'disposed' : 'stale_lease', request.key, nativeResult);
    }
    if (commitCatalog && nativeResult.code === 'ok') {
      return this.commitCatalog(context, captured, nativeResult);
    }
    return serviceResult(nativeResult.code, request.key, nativeResult);
  }

  private finishOwnerRequest(ownerToken: number, lease: AccountSessionLease): void {
    if (this.ownerAdmission === null) { return; }
    this.ownerAdmission.finishOwnerRequest(ownerToken, lease);
  }

  private commitCatalog(context: MoonlightHostContext, captured: AccountSessionLease,
    nativeResult: MoonlightNativeResult): MoonlightHostServiceResult {
    if (nativeResult.terminalStage !== 'complete' ||
        nativeResult.preflightTruth !== 'confirmed' ||
        nativeResult.partialAppCount !== 0) {
      return serviceResult('invalid_catalog', nativeResult.key, nativeResult);
    }
    if (context.localHostId === undefined || context.localHostId.trim().length === 0) {
      return serviceResult('invalid_context', nativeResult.key, nativeResult);
    }
    const cacheHostId: string = context.localHostId.trim();
    const nowMs: number = nativeResult.observedAtMs > 0 ?
      nativeResult.observedAtMs : Date.now();
    const expiresAt: number = Math.min(MAX_SAFE_INTEGER, nowMs + APP_CACHE_TTL_MS);
    const rows: MoonlightAppCacheEntry[] = [];
    const appIds: string[] = [];
    for (let i = 0; i < nativeResult.apps.length; i++) {
      const app: MoonlightNativeApp = nativeResult.apps[i];
      const appId: string = app.id.toString();
      if (!safePositiveInteger(app.id) || app.title.trim().length === 0 ||
          app.title.length > 256 || appIds.indexOf(appId) >= 0) {
        return serviceResult('invalid_catalog', nativeResult.key, nativeResult);
      }
      appIds.push(appId);
      const row = new MoonlightAppCacheEntry();
      row.id = moonlightAppCacheIdentity(captured.ownerScopeId, cacheHostId, appId);
      row.userId = captured.ownerScopeId;
      row.hostId = cacheHostId;
      row.appId = appId;
      row.title = app.title;
      row.available = true;
      row.sortOrder = i;
      row.lastCatalogAt = nowMs;
      row.expiresAt = expiresAt;
      row.lastAccessedAt = nowMs;
      row.sizeBytes = 0;
      rows.push(row);
    }
    if (!this.contextCurrent(context, captured)) {
      this.staleCompletionCount++;
      return serviceResult('stale_lease', nativeResult.key, nativeResult);
    }
    let cacheResult: MoonlightAppCacheResult;
    try {
      cacheResult = this.cache.refreshCatalog(captured, cacheHostId, rows, true, nowMs);
    } catch (_) {
      return serviceResult('cache_failed', nativeResult.key, nativeResult);
    }
    if (!this.contextCurrent(context, captured)) {
      this.staleCompletionCount++;
      return serviceResult('stale_lease', nativeResult.key, nativeResult,
        cacheResult.code);
    }
    if (!cacheResult.ok) {
      return serviceResult(cacheResult.code === 'stale_lease' ?
        'stale_lease' : 'cache_failed', nativeResult.key, nativeResult,
        cacheResult.code);
    }
    return serviceResult('ok', nativeResult.key, nativeResult, cacheResult.code,
      cacheResult.visibleEntries);
  }
}
