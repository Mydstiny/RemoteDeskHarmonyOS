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

export type MoonlightNativeOperation =
  'pair' | 'catalog' | 'asset' | 'launch' | 'resume' | 'quit';
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
  apps: MoonlightNativeApp[];
  asset: ArrayBuffer;
  certificateSha256?: string;
  rtspSessionUrl?: string;
  diagnostics: MoonlightNativeDiagnostic[];
}

export interface MoonlightBridgeCapabilities {
  bridgeCompiled: boolean;
  identityReady: boolean;
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
  firstFrameReady: boolean;
  terminal: boolean;
  lastSequence: number;
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
  hostId: string;
  serverUuid: string;
  installationId?: string;
  pinnedCertificateSha256?: string;
  endpoint: MoonlightNativeEndpoint;
  timeoutMs: number;
}

export type MoonlightHostServiceCode =
  MoonlightNativeCode | 'stale_lease' | 'invalid_context' | 'native_exception' |
  'cache_failed' | 'disposed';

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

function emptyCapabilities(): MoonlightBridgeCapabilities {
  return {
    bridgeCompiled: false,
    identityReady: false,
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

function serviceResult(code: MoonlightHostServiceCode,
  key: MoonlightNativeRequestKey = emptyKey(),
  nativeResult: MoonlightNativeResult | null = null,
  cacheCode: MoonlightAppCacheCode | '' = '',
  visibleApps: MoonlightAppCacheEntry[] = []): MoonlightHostServiceResult {
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
    Number.isSafeInteger(result.observedAtMs) && result.observedAtMs >= 0;
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
  private readonly pending: Map<string, PendingRequest> = new Map<string, PendingRequest>();
  private readonly disposedOwners: Set<number> = new Set<number>();
  private nextRequestId: number = 1;
  private staleCompletionCount: number = 0;
  private staleEventCount: number = 0;

  constructor(native: MoonlightNativePort = new MoonlightNapiPort(),
    leases: MoonlightAccountLeasePort = CloudStore.getInstance(),
    cache: MoonlightAppCacheService = new MoonlightAppCacheService(CloudStore.getInstance())) {
    this.native = native;
    this.leases = leases;
    this.cache = cache;
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
      timeoutMs: context.timeoutMs
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
    const identity: string = this.requestIdentity(request.key);
    this.pending.set(identity, { key: request.key, lease: captured });
    let nativePromise: Promise<MoonlightNativeResult>;
    try {
      nativePromise = this.native.requestAsync(request);
    } catch (_) {
      this.pending.delete(identity);
      this.releaseSafely(release);
      return serviceResult('native_exception', request.key);
    }
    this.releaseSafely(release);

    let nativeResult: MoonlightNativeResult;
    try {
      nativeResult = await nativePromise;
    } catch (_) {
      this.pending.delete(identity);
      return serviceResult('native_exception', request.key);
    }
    this.pending.delete(identity);
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

  private commitCatalog(context: MoonlightHostContext, captured: AccountSessionLease,
    nativeResult: MoonlightNativeResult): MoonlightHostServiceResult {
    if (nativeResult.terminalStage !== 'complete' ||
        nativeResult.preflightTruth !== 'confirmed' ||
        nativeResult.partialAppCount !== 0) {
      return serviceResult('invalid_catalog', nativeResult.key, nativeResult);
    }
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
      row.id = moonlightAppCacheIdentity(captured.ownerScopeId, context.hostId, appId);
      row.userId = captured.ownerScopeId;
      row.hostId = context.hostId;
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
      cacheResult = this.cache.refreshCatalog(captured, context.hostId, rows, true, nowMs);
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
