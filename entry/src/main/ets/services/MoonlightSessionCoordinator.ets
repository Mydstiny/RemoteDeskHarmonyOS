/**
 * MoonlightSessionCoordinator.ets — the single Moonlight product-session seam.
 *
 * The coordinator owns the shared remote-session reservation and delegates
 * transport/media/input work through the typed native runtime. It retains no
 * cloud state and rejects a start before registry admission when native
 * capability or the exact owner/account launch fence is unavailable.
 */
import {
  ActiveRemoteSessionRecord,
  ActiveRemoteSessionRegistry
} from './ActiveRemoteSessionRegistry';
import { RemoteProtocol } from './RemoteSessionState';
import {
  MoonlightSessionEventType,
  MoonlightSessionStateSnapshot,
  MoonlightSessionEvent,
  applyMoonlightSessionEvent,
  createMoonlightSessionState,
  rebaseMoonlightSessionForReconnect
} from './MoonlightSessionState';
import rdpnapi from 'librdpnapi.so';
import {
  MoonlightNativeRequestKey,
  MoonlightNativeStreamSnapshot
} from './MoonlightHostService';
import { MoonlightEffectiveSettings } from '../model/MoonlightModels';
import { decodeMoonlightEffectiveSettings } from './MoonlightSettingsPolicy';
import { MoonlightRuntimeOwnerRegistry } from './MoonlightRuntimeOwnerRegistry';
import {
  MoonlightSessionRecoveryRuntime,
  MoonlightSessionRecoveryRuntimePort
} from './MoonlightSessionRecoveryRuntime';
import { DiagnosticOutcome } from './DiagnosticCapturePolicy';
import { recordDiagnosticEvent } from './DiagnosticCaptureRuntime';
import { hilog } from '@kit.PerformanceAnalysisKit';

class MoonlightSessionReservationIdentity {
  ownerScopeId: string = '';
  accountGeneration: number = 0;
  hostId: string = '';
  appId: string = '';
  hostAddress: string = '';
  hostControlAlreadyLaunched: boolean = false;
  launchRequestId: number = 0;
  launchGeneration: number = 0;
  launchOwnerToken: number = 0;
  serverUuid: string = '';
  numericAppId: number = 0;
  configuredBitrateKbps: number = 20000;
  effectiveSettingsEncoded: string = '';
  resetRemoteInputBeforeAdmission: boolean = false;
}

export interface MoonlightSessionStartRequest {
  ownerScopeId: string;
  accountGeneration: number;
  hostId: string;
  appId: string;
  /** Transient transport input. It is never written to the shared registry. */
  hostAddress: string;
  runtimeAvailable: boolean;
  hostControlReady: boolean;
  streamingTransportReady: boolean;
  hostControlAlreadyLaunched?: boolean;
  launchKey?: MoonlightNativeRequestKey;
  serverUuid?: string;
  numericAppId?: number;
  configuredBitrateKbps?: number;
  effectiveSettingsEncoded?: string;
  resetRemoteInputBeforeAdmission?: boolean;
  rendererHandle?: number;
  surfaceWidth?: number;
  surfaceHeight?: number;
  surfaceId?: string;
}

export interface MoonlightRuntimePort {
  start(request: MoonlightSessionStartRequest, operationGeneration: number): boolean;
  cancel(operationGeneration: number, reason: string): boolean;
  stop(nativeSessionId: number, reason: string): boolean;
  nativeSessionId?(operationGeneration: number): number;
  snapshot?(operationGeneration: number): MoonlightNativeStreamSnapshot | null;
  suspendSurface?(operationGeneration: number): boolean;
  rebindSurface?(operationGeneration: number, rendererHandle: number): boolean;
  setAudioPaused?(operationGeneration: number, paused: boolean): boolean;
}

const MOONLIGHT_FIRST_FRAME_TIMEOUT_MS: number = 30000;
const MOONLIGHT_RUNTIME_POLL_MIN_MS: number = 100;
const MOONLIGHT_RUNTIME_POLL_MAX_MS: number = 5000;
const MOONLIGHT_RUNTIME_POLL_LOCK_MISSES: number = 64;

function diagnosticMoonlightSessionCode(type: MoonlightSessionEventType): number {
  switch (type) {
    case 'beginDiscovery': return 1;
    case 'beginVerification': return 2;
    case 'pairingRequired': return 3;
    case 'pairingAccepted': return 4;
    case 'catalogReady': return 5;
    case 'launchRequested': return 6;
    case 'launchAccepted': return 7;
    case 'videoReady': return 8;
    case 'audioReady': return 9;
    case 'inputReady': return 10;
    case 'firstFrameRendered': return 11;
    case 'streamStable': return 12;
    case 'transportLost': return 13;
    case 'reconnectNegotiating': return 14;
    case 'stopRequested': return 15;
    case 'stopped': return 16;
    case 'failed': return 17;
    case 'cancelled': return 18;
    case 'capabilityDegraded': return 19;
  }
}

function diagnosticMoonlightSessionOutcome(type: MoonlightSessionEventType): DiagnosticOutcome {
  if (type === 'failed') { return 'failed'; }
  if (type === 'cancelled') { return 'cancelled'; }
  if (type === 'transportLost' || type === 'reconnectNegotiating') { return 'retry'; }
  if (type === 'launchRequested' || type === 'stopRequested') { return 'started'; }
  if (type === 'stopped' || type === 'streamStable') { return 'succeeded'; }
  return 'state';
}

export interface MoonlightRuntimePollScheduler {
  nowMs(): number;
  schedule(callback: () => void, delayMs: number): number;
  cancel(timerId: number): void;
}

class MoonlightSystemRuntimePollScheduler implements MoonlightRuntimePollScheduler {
  nowMs(): number { return Date.now(); }

  schedule(callback: () => void, delayMs: number): number {
    return setTimeout(callback, delayMs);
  }

  cancel(timerId: number): void { clearTimeout(timerId); }
}

export function moonlightRuntimePollDelayMs(consecutiveMisses: number): number {
  if (!Number.isSafeInteger(consecutiveMisses) || consecutiveMisses < 0) {
    return MOONLIGHT_RUNTIME_POLL_MAX_MS;
  }
  let delayMs: number = MOONLIGHT_RUNTIME_POLL_MIN_MS;
  const steps: number = Math.min(consecutiveMisses, 6);
  for (let index: number = 0; index < steps; index++) {
    delayMs = Math.min(MOONLIGHT_RUNTIME_POLL_MAX_MS, delayMs * 2);
  }
  return delayMs;
}

export function moonlightRuntimePollShouldLock(consecutiveMisses: number): boolean {
  return !Number.isSafeInteger(consecutiveMisses) || consecutiveMisses < 0 ||
    consecutiveMisses >= MOONLIGHT_RUNTIME_POLL_LOCK_MISSES;
}

export function moonlightRuntimeNativeError(code: string): string {
  if (code === 'cancelled') { return 'CANCELLED'; }
  if (code === 'deadline_exceeded') { return 'STREAM_TIMEOUT'; }
  if (code === 'codec_unsupported') { return 'CODEC_UNSUPPORTED'; }
  if (code === 'decoder_failed') { return 'DECODER_FAILED'; }
  if (code === 'audio_failed') { return 'AUDIO_FAILED'; }
  if (code === 'input_failed') { return 'INPUT_FAILED'; }
  if (code === 'stale_owner') { return 'STALE_OWNER'; }
  if (code === 'connection_terminated' || code === 'connection_failed') {
    return 'NETWORK_UNREACHABLE';
  }
  return 'STREAM_FAILED';
}

/**
 * Plans readiness transitions from durable coordinator truth plus one native
 * snapshot. Stable streaming is deliberately independent from the first poll
 * that observes a frame because audio/input commonly become ready later.
 */
export function moonlightRuntimeReadinessEvents(
  state: MoonlightSessionStateSnapshot,
  source: MoonlightNativeStreamSnapshot
): MoonlightSessionEventType[] {
  const events: MoonlightSessionEventType[] = [];
  if (!source.matched || source.terminal || state.phase === 'stopping' ||
      state.phase === 'failed' || state.phase === 'disconnected') {
    return events;
  }
  // An exact native first-frame receipt has already crossed decoder and
  // renderer presentation ownership fences. It is therefore also positive
  // video readiness evidence, even if an API 23 media-lane flag was sampled
  // false in the same snapshot.
  const nativeVideoReady: boolean = source.videoReady || source.firstFrameReady;
  const videoReady: boolean = state.videoReady || nativeVideoReady;
  const audioReady: boolean = state.audioReady || source.audioReady;
  const inputReady: boolean = state.inputReady || source.inputReady;
  if (nativeVideoReady && !state.videoReady) { events.push('videoReady'); }
  if (source.audioReady && !state.audioReady) { events.push('audioReady'); }
  if (source.inputReady && !state.inputReady) { events.push('inputReady'); }
  const firstFrameReady: boolean = state.firstFrameSeen ||
    (source.firstFrameReady && videoReady);
  if (source.firstFrameReady && videoReady && !state.firstFrameSeen) {
    events.push('firstFrameRendered');
  }
  if (videoReady && audioReady && inputReady && firstFrameReady &&
      state.phase !== 'streaming') {
    events.push('streamStable');
  }
  return events;
}

class MoonlightNapiRuntimePort implements MoonlightRuntimePort {
  private operationGeneration: number = 0;
  private launchKey: MoonlightNativeRequestKey | null = null;
  private sessionId: number = -1;

  start(request: MoonlightSessionStartRequest, operationGeneration: number): boolean {
    if (request.launchKey === undefined || request.serverUuid === undefined ||
        request.numericAppId === undefined || request.rendererHandle === undefined ||
        request.surfaceWidth === undefined || request.surfaceHeight === undefined) {
      return false;
    }
    const snapshot: MoonlightEffectiveSettings | null = decodeMoonlightEffectiveSettings(
      request.effectiveSettingsEncoded === undefined ? '' : request.effectiveSettingsEncoded);
    if (snapshot === null) { return false; }
    const settings = snapshot.effective;
    try {
      const result = rdpnapi.moonlightStartStream({
        launchKey: {
          requestId: request.launchKey.requestId,
          generation: request.launchKey.generation,
          ownerToken: request.launchKey.ownerToken
        }, hostId: request.serverUuid,
        serverUuid: request.serverUuid, appId: request.numericAppId,
        rendererHandle: request.rendererHandle, surfaceWidth: request.surfaceWidth,
        surfaceHeight: request.surfaceHeight,
        configuredBitrateKbps: request.configuredBitrateKbps === undefined
          ? 20000 : request.configuredBitrateKbps,
        codecPreference: settings.video.codecPreference === 'hevc' ? 'hevc' :
          settings.video.codecPreference === 'av1' ? 'av1' : 'h264',
        hdr: settings.video.hdr,
        yuv444: settings.video.yuv444,
        latencyMode: settings.video.latencyMode,
        audioEnabled: settings.audio.enabled,
        audioChannels: settings.audio.channels,
        playAudioOnHost: settings.audio.playOnHost,
        resetRemoteInputBeforeAdmission:
          request.resetRemoteInputBeforeAdmission === true,
        streamEncryption: settings.network.streamEncryption
      });
      if (!result.accepted || result.sessionId <= 0) { return false; }
      this.operationGeneration = operationGeneration;
      this.launchKey = request.launchKey;
      this.sessionId = result.sessionId;
      return true;
    } catch (_) {
      return false;
    }
  }

  cancel(operationGeneration: number, _reason: string): boolean {
    return this.stopForGeneration(operationGeneration);
  }

  stop(_nativeSessionId: number, _reason: string): boolean {
    return this.stopForGeneration(this.operationGeneration);
  }

  nativeSessionId(operationGeneration: number): number {
    return operationGeneration === this.operationGeneration ? this.sessionId : -1;
  }

  snapshot(operationGeneration: number): MoonlightNativeStreamSnapshot | null {
    if (operationGeneration !== this.operationGeneration || this.launchKey === null) { return null; }
    try {
      const source = rdpnapi.moonlightGetStreamSnapshot({
        requestId: this.launchKey.requestId,
        generation: this.launchKey.generation,
        ownerToken: this.launchKey.ownerToken
      });
      // moonlightGetStreamSnapshot() performs the authoritative lookup with
      // the complete bridge launch key in native code. The returned common-C
      // session key intentionally owns a different, process-local owner token;
      // comparing that token with the account/launch owner rejects every real
      // device snapshot. Preserve the coordinator's launch identity after a
      // native matched receipt so event, terminal, and registry fences all use
      // one namespace.
      const snapshot: MoonlightNativeStreamSnapshot = {
        matched: source.matched,
        code: source.code,
        sessionId: source.matched ? this.sessionId : source.sessionId,
        generation: source.matched ? this.launchKey.generation : source.generation,
        ownerToken: source.matched ? this.launchKey.ownerToken : source.ownerToken,
        transportReady: source.transportReady,
        videoReady: source.videoReady,
        audioReady: source.audioReady,
        inputReady: source.inputReady,
        controllerReady: source.controllerReady,
        physicalControllerReady: source.physicalControllerReady,
        inputMayBeStuck: source.inputMayBeStuck,
        presentationFrameReady: source.presentationFrameReady,
        firstFrameReady: source.firstFrameReady,
        terminal: source.terminal,
        lastSequence: source.lastSequence,
        sampledAtMonotonicMs: source.sampledAtMonotonicMs,
        acceptedVideoFrames: source.acceptedVideoFrames,
        droppedVideoFrames: source.droppedVideoFrames,
        acceptedVideoBytes: source.acceptedVideoBytes,
        rendererPresentedFrames: source.rendererPresentedFrames,
        acceptedAudioPackets: source.acceptedAudioPackets,
        rejectedAudioPackets: source.rejectedAudioPackets,
        acceptedAudioBytes: source.acceptedAudioBytes,
        rejectedInputEvents: source.rejectedInputEvents,
        streamWidth: source.streamWidth,
        streamHeight: source.streamHeight,
        targetFps: source.targetFps,
        configuredBitrateKbps: source.configuredBitrateKbps,
        codec: source.codec
      };
      // moonlightStopStream() only acknowledges the cancellation request. Keep
      // the launch key alive so polling can observe the native terminal receipt;
      // release the local identity only after that receipt has been copied.
      if (source.terminal && source.matched) {
        this.launchKey = null;
        this.sessionId = -1;
      }
      return snapshot;
    } catch (_) { return null; }
  }

  suspendSurface(operationGeneration: number): boolean {
    if (operationGeneration !== this.operationGeneration || this.launchKey === null) { return false; }
    try {
      return rdpnapi.moonlightSuspendSurface({
        requestId: this.launchKey.requestId,
        generation: this.launchKey.generation,
        ownerToken: this.launchKey.ownerToken
      });
    } catch (_) { return false; }
  }

  rebindSurface(operationGeneration: number, rendererHandle: number): boolean {
    if (operationGeneration !== this.operationGeneration || this.launchKey === null ||
        !validSessionId(rendererHandle)) { return false; }
    try {
      return rdpnapi.moonlightRebindSurface({
        launchKey: {
          requestId: this.launchKey.requestId,
          generation: this.launchKey.generation,
          ownerToken: this.launchKey.ownerToken
        },
        rendererHandle: rendererHandle
      });
    } catch (_) { return false; }
  }

  setAudioPaused(operationGeneration: number, paused: boolean): boolean {
    if (operationGeneration !== this.operationGeneration || this.launchKey === null) { return false; }
    try {
      return rdpnapi.moonlightSetAudioPaused({
        launchKey: {
          requestId: this.launchKey.requestId,
          generation: this.launchKey.generation,
          ownerToken: this.launchKey.ownerToken
        },
        paused: paused
      });
    } catch (_) { return false; }
  }

  private stopForGeneration(operationGeneration: number): boolean {
    if (operationGeneration !== this.operationGeneration || this.launchKey === null) { return false; }
    try {
      return rdpnapi.moonlightStopStream({
        requestId: this.launchKey.requestId,
        generation: this.launchKey.generation,
        ownerToken: this.launchKey.ownerToken
      });
    } catch (_) { return false; }
  }
}

export interface MoonlightCoordinatorEvent {
  type: MoonlightSessionEventType;
  generation: number;
  sequence: number;
  nativeError: string;
  detailCode: string;
  /** Required only for launchAccepted; never persisted as a secret. */
  nativeSessionId: number;
  /** Required for firstFrameRendered before streaming can become true. */
  surfaceId: string;
}

export type MoonlightSessionSnapshotListener =
  (snapshot: MoonlightSessionStateSnapshot | null) => void;

interface MoonlightSessionSnapshotSubscription {
  ownerScopeId: string;
  accountGeneration: number;
  hostId: string;
  appId: string;
  listener: MoonlightSessionSnapshotListener;
}

export type MoonlightCoordinatorResultCode =
  'reserved' | 'started' | 'runtime_unavailable' | 'invalid_request' | 'active_session_busy' |
  'duplicate_start' | 'runtime_start_failed' | 'applied' | 'stale_generation' |
  'stale_sequence' | 'invalid_transition' | 'native_session_missing' |
  'native_session_mismatch' | 'stop_failed' | 'stop_timeout' |
  'first_frame_timeout' |
  'registry_rejected' | 'registry_lost' | 'surface_missing' | 'render_not_attached' |
  'not_active' | 'stop_requested' | 'already_stopping' | 'stopped' |
  'lifecycle_unsupported' | 'surface_detached' | 'surface_rebound' |
  'surface_frame_pending' | 'audio_paused' | 'audio_resumed' | 'reconnect_reserved' |
  'terminal_not_observed' | 'lifecycle_closed';

export interface MoonlightCoordinatorResult {
  accepted: boolean;
  code: MoonlightCoordinatorResultCode;
  state: MoonlightSessionStateSnapshot | null;
  nativeSessionId: number;
}

function boundedText(value: string, maximum: number): boolean {
  return typeof value === 'string' && value.trim().length > 0 && value.length <= maximum;
}

function validGeneration(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0;
}

function validSessionId(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0;
}

function cloneState(value: MoonlightSessionStateSnapshot | null): MoonlightSessionStateSnapshot | null {
  if (value === null) {
    return null;
  }
  return {
    sessionId: value.sessionId,
    ownerScopeId: value.ownerScopeId,
    hostId: value.hostId,
    appId: value.appId,
    generation: value.generation,
    phase: value.phase,
    lastEventSequence: value.lastEventSequence,
    videoReady: value.videoReady,
    audioReady: value.audioReady,
    inputReady: value.inputReady,
    firstFrameSeen: value.firstFrameSeen,
    reconnectAttempt: value.reconnectAttempt,
    errorCode: value.errorCode,
    degradationReasons: value.degradationReasons.slice()
  };
}

function terminal(value: MoonlightSessionStateSnapshot | null): boolean {
  return value === null || value.phase === 'disconnected' || value.phase === 'failed';
}

function sessionEvent(value: MoonlightCoordinatorEvent): MoonlightSessionEvent {
  return {
    type: value.type,
    generation: value.generation,
    sequence: value.sequence,
    nativeError: value.nativeError,
    detailCode: value.detailCode
  };
}

export class MoonlightSessionCoordinator {
  private static instance: MoonlightSessionCoordinator | null = null;
  private readonly registry: ActiveRemoteSessionRegistry;
  private readonly runtime: MoonlightRuntimePort | null;
  private readonly admission: MoonlightRuntimeOwnerRegistry | null;
  private readonly recoveryRuntime: MoonlightSessionRecoveryRuntimePort | null;
  private readonly runtimePollScheduler: MoonlightRuntimePollScheduler;
  private state: MoonlightSessionStateSnapshot | null = null;
  private nativeSessionId: number = -1;
  private reservationSessionId: number = -1;
  private reservationIdentity: MoonlightSessionReservationIdentity | null = null;
  private runtimeStartIssued: boolean = false;
  private operationGeneration: number = 0;
  private boundOwnerScopeId: string = '';
  private boundAccountGeneration: number = 0;
  private pendingBoundOwnerScopeId: string = '';
  private pendingBoundAccountGeneration: number = 0;
  private pendingScopeChange: boolean = false;
  private stopDeadlineAtMs: number = 0;
  private firstFrameDeadlineAtMs: number = 0;
  private reconnectEnabled: boolean = false;
  private nativeRuntimeMayBeActive: boolean = false;
  private pendingTeardownNativeError: string = '';
  private pendingTeardownDetailCode: string = '';
  private stopTimer: number = -1;
  private runtimePollTimer: number = -1;
  private runtimePollMisses: number = 0;
  private runtimePollLocked: boolean = false;
  private readonly snapshotSubscriptions: MoonlightSessionSnapshotSubscription[] = [];

  constructor(runtime: MoonlightRuntimePort | null = null,
    registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance(),
    admission: MoonlightRuntimeOwnerRegistry | null = null,
    recoveryRuntime: MoonlightSessionRecoveryRuntimePort | null = null,
    runtimePollScheduler: MoonlightRuntimePollScheduler =
      new MoonlightSystemRuntimePollScheduler()) {
    this.runtime = runtime;
    this.registry = registry;
    this.admission = admission;
    this.recoveryRuntime = recoveryRuntime;
    this.runtimePollScheduler = runtimePollScheduler;
  }

  static getInstance(): MoonlightSessionCoordinator {
    if (MoonlightSessionCoordinator.instance === null) {
      MoonlightSessionCoordinator.instance = new MoonlightSessionCoordinator(
        new MoonlightNapiRuntimePort(), ActiveRemoteSessionRegistry.getInstance(),
        MoonlightRuntimeOwnerRegistry.getInstance(),
        MoonlightSessionRecoveryRuntime.getInstance());
    }
    return MoonlightSessionCoordinator.instance;
  }

  bindScope(ownerScopeId: string, accountGeneration: number): void {
    const nextOwner: string = ownerScopeId.trim();
    const nextGeneration: number = validGeneration(accountGeneration) ? accountGeneration : 0;
    const matchesBound: boolean = nextOwner === this.boundOwnerScopeId &&
      nextGeneration === this.boundAccountGeneration;
    if (matchesBound) {
      // A transition may be rolled back while native teardown is still in
      // flight. Keep draining the old runtime, but do not later bind the
      // abandoned target scope.
      this.pendingScopeChange = false;
      this.pendingBoundOwnerScopeId = '';
      this.pendingBoundAccountGeneration = 0;
      return;
    }
    if (this.nativeRuntimeMayBeActive) {
      // Do not publish the next account over the old native/runtime identity.
      // The exact old registry marker remains occupied until common-c emits
      // the typed terminal snapshot for this launch.
      this.pendingScopeChange = true;
      this.pendingBoundOwnerScopeId = nextOwner;
      this.pendingBoundAccountGeneration = nextGeneration;
      this.invalidate('owner_changed');
      return;
    }
    if (this.state !== null) { this.invalidate('owner_changed'); }
    this.applyBoundScope(nextOwner, nextGeneration);
  }

  reserve(request: MoonlightSessionStartRequest): MoonlightCoordinatorResult {
    this.expireStopIfNeeded(Date.now());
    if (!this.validReservationRequest(request)) {
      return this.result(false, 'invalid_request');
    }
    if (this.admission !== null &&
        !this.admission.allowsScope(request.ownerScopeId, request.accountGeneration)) {
      return this.result(false, 'lifecycle_closed');
    }
    if (!request.runtimeAvailable || !request.hostControlReady ||
      !request.streamingTransportReady || this.runtime === null) {
      return this.result(false, 'runtime_unavailable');
    }
    if (!terminal(this.state)) {
      if (this.reservationMatches(request) && !this.runtimeStartIssued) {
        return this.result(true, 'reserved');
      }
      return this.result(false, 'duplicate_start');
    }
    // A locally failed/timed-out route is not a native terminal receipt. Keep
    // both Moonlight and the shared protocol registry closed until common-c
    // confirms teardown; otherwise another protocol could acquire the
    // process-global media/input owners while the old stream is still alive.
    if (this.nativeRuntimeMayBeActive) {
      return this.result(false, 'active_session_busy');
    }
    if (this.boundOwnerScopeId !== request.ownerScopeId ||
      this.boundAccountGeneration !== request.accountGeneration) {
      this.bindScope(request.ownerScopeId, request.accountGeneration);
    }
    this.operationGeneration += 1;
    const created: MoonlightSessionStateSnapshot | null = createMoonlightSessionState(
      'moonlight-' + this.operationGeneration.toString(), request.ownerScopeId,
      request.hostId, request.appId, this.operationGeneration);
    if (created === null) {
      return this.result(false, 'invalid_request');
    }
    const firstEvent: MoonlightSessionEvent = {
      type: 'beginDiscovery', generation: this.operationGeneration, sequence: 1,
      nativeError: '', detailCode: ''
    };
    const firstTransition = applyMoonlightSessionEvent(created, firstEvent);
    if (!firstTransition.applied) {
      return this.result(false, 'invalid_transition');
    }
    const reservationSessionId: number = this.operationGeneration;
    const reserved: boolean = this.registry.reserveActive({
      ownerScopeId: request.ownerScopeId,
      accountGeneration: request.accountGeneration,
      sessionId: reservationSessionId,
      hostId: request.hostId,
      protocol: RemoteProtocol.moonlight,
      hostAddress: '',
      protocolConnected: false,
      renderAttached: false,
      restoreNeeded: false,
      latestSurfaceId: '',
      createdAtMs: Date.now(),
      updatedAtMs: Date.now()
    });
    if (!reserved) {
      return this.result(false, 'active_session_busy');
    }
    this.reservationSessionId = reservationSessionId;
    this.reservationIdentity = this.createReservationIdentity(request);
    this.runtimeStartIssued = false;
    this.reconnectEnabled = false;
    this.pendingTeardownNativeError = '';
    this.pendingTeardownDetailCode = '';
    this.state = firstTransition.state;
    this.notifySnapshotSubscribers();
    return this.result(true, 'reserved');
  }

  start(request: MoonlightSessionStartRequest): MoonlightCoordinatorResult {
    this.expireStopIfNeeded(Date.now());
    if (!this.validRequest(request)) {
      return this.result(false, 'invalid_request');
    }
    if (this.admission !== null &&
        !this.admission.allowsScope(request.ownerScopeId, request.accountGeneration)) {
      return this.result(false, 'lifecycle_closed');
    }
    if (!request.runtimeAvailable || !request.hostControlReady ||
      !request.streamingTransportReady || this.runtime === null) {
      return this.result(false, 'runtime_unavailable');
    }
    if (!this.reservationMatches(request)) {
      const reservation: MoonlightCoordinatorResult = this.reserve(request);
      if (!reservation.accepted) { return reservation; }
    }
    if (this.runtimeStartIssued || this.state === null || this.reservationSessionId <= 0) {
      return this.result(false, 'duplicate_start');
    }
    if (request.hostControlAlreadyLaunched === true) {
      const stagedEvents: MoonlightSessionEvent[] = [
        { type: 'beginVerification', generation: this.operationGeneration, sequence: 2,
          nativeError: '', detailCode: '' },
        { type: 'catalogReady', generation: this.operationGeneration, sequence: 3,
          nativeError: '', detailCode: '' },
        { type: 'launchRequested', generation: this.operationGeneration, sequence: 4,
          nativeError: '', detailCode: '' }
      ];
      for (let index = 0; index < stagedEvents.length; index++) {
        const staged = applyMoonlightSessionEvent(this.state, stagedEvents[index]);
        if (!staged.applied) {
          this.clearOwnedRegistry();
          this.state = null;
          this.reservationSessionId = -1;
          this.reservationIdentity = null;
          return this.result(false, 'invalid_transition');
        }
        this.state = staged.state;
      }
    }
    this.notifySnapshotSubscribers();
    this.runtimeStartIssued = true;
    this.resetRuntimePollBackoff();
    const started: boolean = this.runtime.start(request, this.operationGeneration);
    if (!started) {
      const failedEvent: MoonlightSessionEvent = {
        type: 'failed', generation: this.operationGeneration,
        sequence: this.state.lastEventSequence + 1,
        nativeError: 'RUNTIME_START_FAILED', detailCode: ''
      };
      const failed = applyMoonlightSessionEvent(this.state, failedEvent);
      this.state = failed.applied ? failed.state : this.state;
      this.clearOwnedRegistry();
      this.reservationSessionId = -1;
      this.reservationIdentity = null;
      this.runtimeStartIssued = false;
      this.notifySnapshotSubscribers();
      return this.result(false, 'runtime_start_failed');
    }
    this.nativeRuntimeMayBeActive = true;
    if (request.hostControlAlreadyLaunched === true) {
      const runtimeSessionId: number = this.runtime.nativeSessionId === undefined
        ? -1 : this.runtime.nativeSessionId(this.operationGeneration);
      const accepted = this.handleRuntimeEvent({
        type: 'launchAccepted', generation: this.operationGeneration,
        sequence: this.state.lastEventSequence + 1, nativeError: '', detailCode: '',
        nativeSessionId: runtimeSessionId, surfaceId: ''
      });
      if (!accepted.accepted) { return accepted; }
      this.scheduleRuntimePoll(request.surfaceId === undefined ? '' : request.surfaceId);
    }
    return this.result(true, 'started');
  }

  restartAfterTransportLoss(request: MoonlightSessionStartRequest): MoonlightCoordinatorResult {
    this.expireStopIfNeeded(Date.now());
    if (this.state === null || this.state.phase !== 'reconnecting' ||
        this.reservationSessionId <= 0 || this.runtimeStartIssued ||
        !this.validRequest(request) || request.hostControlAlreadyLaunched !== true ||
        request.ownerScopeId !== this.state.ownerScopeId ||
        request.accountGeneration !== this.boundAccountGeneration ||
        request.hostId !== this.state.hostId || request.appId !== this.state.appId) {
      return this.result(false, 'invalid_request');
    }
    if (this.admission !== null &&
        !this.admission.allowsScope(request.ownerScopeId, request.accountGeneration)) {
      return this.result(false, 'lifecycle_closed');
    }
    if (!request.runtimeAvailable || !request.hostControlReady ||
        !request.streamingTransportReady || this.runtime === null) {
      return this.result(false, 'runtime_unavailable');
    }
    this.reservationIdentity = this.createReservationIdentity(request);
    this.runtimeStartIssued = true;
    this.resetRuntimePollBackoff();
    if (!this.runtime.start(request, this.operationGeneration)) {
      this.runtimeStartIssued = false;
      this.reservationIdentity = null;
      return this.result(false, 'runtime_start_failed');
    }
    this.nativeRuntimeMayBeActive = true;
    const runtimeSessionId: number = this.runtime.nativeSessionId === undefined
      ? -1 : this.runtime.nativeSessionId(this.operationGeneration);
    const accepted: MoonlightCoordinatorResult = this.handleRuntimeEvent({
      type: 'launchAccepted', generation: this.operationGeneration,
      sequence: this.state.lastEventSequence + 1, nativeError: '', detailCode: 'reconnect',
      nativeSessionId: runtimeSessionId, surfaceId: ''
    });
    if (!accepted.accepted) {
      this.runtime.stop(runtimeSessionId, 'reconnect-admission-failed');
      return accepted;
    }
    this.scheduleRuntimePoll(request.surfaceId === undefined ? '' : request.surfaceId);
    return this.result(true, 'started');
  }

  handleRuntimeEvent(event: MoonlightCoordinatorEvent): MoonlightCoordinatorResult {
    this.expireStopIfNeeded(Date.now());
    if (this.state === null) {
      return this.result(false, 'not_active');
    }
    if (event.generation !== this.state.generation) {
      return this.result(false, 'stale_generation');
    }
    if (event.type === 'launchAccepted' && !validSessionId(event.nativeSessionId)) {
      return this.result(false, 'native_session_missing');
    }
    if (this.nativeSessionId > 0 && event.type !== 'launchAccepted' &&
      event.nativeSessionId !== this.nativeSessionId) {
      return this.result(false, 'native_session_mismatch');
    }
    if (event.type === 'firstFrameRendered' && !boundedText(event.surfaceId, 256)) {
      return this.result(false, 'surface_missing');
    }
    if (event.type === 'streamStable') {
      const active: ActiveRemoteSessionRecord | null = this.registry.getActive();
      if (active === null || active.protocol !== RemoteProtocol.moonlight ||
        active.sessionId !== this.nativeSessionId || !active.renderAttached) {
        return this.result(false, 'render_not_attached');
      }
    }

    const transition = applyMoonlightSessionEvent(this.state, sessionEvent(event));
    if (!transition.applied) {
      if (transition.reason === 'stale_generation') {
        return this.result(false, 'stale_generation');
      }
      if (transition.reason === 'stale_sequence') {
        return this.result(false, 'stale_sequence');
      }
      return this.result(false, 'invalid_transition');
    }
    this.state = transition.state;

    if (event.type === 'launchAccepted') {
      const now: number = Date.now();
      const registered: boolean = this.reservationSessionId > 0 &&
        this.registry.promoteReserved(this.state.ownerScopeId, this.boundAccountGeneration,
          this.reservationSessionId, {
        ownerScopeId: this.state.ownerScopeId,
        accountGeneration: this.boundAccountGeneration,
        sessionId: event.nativeSessionId,
        hostId: this.state.hostId,
        protocol: RemoteProtocol.moonlight,
        hostAddress: '',
        protocolConnected: true,
        renderAttached: false,
        restoreNeeded: true,
        latestSurfaceId: '',
        createdAtMs: now,
        updatedAtMs: now
      });
      if (!registered) {
        this.invalidate('registry_rejected');
        return this.result(false, 'registry_rejected');
      }
      this.nativeSessionId = event.nativeSessionId;
      this.reservationSessionId = -1;
      // Keep the exact launch key until native terminal truth. It is required
      // to prove that a reconnect request belongs to this stream rather than a
      // stale callback or caller-provided error string.
      this.firstFrameDeadlineAtMs = Date.now() + MOONLIGHT_FIRST_FRAME_TIMEOUT_MS;
    }

    if (event.type === 'firstFrameRendered') {
      this.firstFrameDeadlineAtMs = 0;
      if (!this.registry.markRenderAttached(event.surfaceId)) {
        this.invalidate('registry_lost');
        return this.result(false, 'registry_lost');
      }
    }
    if (event.type === 'transportLost' && !this.registry.markRenderDetached()) {
      this.invalidate('registry_lost');
      return this.result(false, 'registry_lost');
    }
    if (event.type === 'failed' || event.type === 'stopped') {
      this.nativeRuntimeMayBeActive = false;
      this.clearRuntimePoll();
      this.resetRuntimePollBackoff();
      this.clearStopTimer();
      this.clearOwnedRegistry();
      this.nativeSessionId = -1;
      this.reservationSessionId = -1;
      this.reservationIdentity = null;
      this.runtimeStartIssued = false;
      this.stopDeadlineAtMs = 0;
      this.firstFrameDeadlineAtMs = 0;
      this.reconnectEnabled = false;
      this.pendingTeardownNativeError = '';
      this.pendingTeardownDetailCode = '';
    }
    recordDiagnosticEvent('connection.moonlight', 'moonlight_state_changed',
      diagnosticMoonlightSessionOutcome(event.type),
      event.nativeSessionId > 0 ? event.nativeSessionId : 0,
      event.generation, diagnosticMoonlightSessionCode(event.type));
    this.notifySnapshotSubscribers();
    if ((event.type === 'failed' || event.type === 'stopped') &&
        this.applyPendingBoundScopeIfIdle()) {
      this.notifySnapshotSubscribers();
    }
    return this.result(true, event.type === 'stopped' ? 'stopped' : 'applied');
  }

  setReconnectEnabledForRoute(hostId: string, appId: string, enabled: boolean): boolean {
    if (!this.activeRouteMatches(hostId, appId)) { return false; }
    this.reconnectEnabled = enabled;
    return true;
  }

  acceptRecoverableTerminalForRoute(hostId: string,
    appId: string): MoonlightCoordinatorResult {
    if (!this.activeRouteMatches(hostId, appId) || !this.reconnectEnabled ||
        this.runtime === null ||
        this.runtime.snapshot === undefined) {
      return this.result(false, 'not_active');
    }
    const source: MoonlightNativeStreamSnapshot | null =
      this.runtime.snapshot(this.operationGeneration);
    if (!this.reconnectTerminalSnapshotMatchesActive(source)) {
      return this.result(false, 'terminal_not_observed');
    }
    const exact: MoonlightNativeStreamSnapshot = source as MoonlightNativeStreamSnapshot;
    if (!this.runtimeCodeAllowsReconnect(exact.code)) {
      this.acceptNativeTerminalReceipt(exact);
      return this.result(false, 'not_active');
    }
    if (this.enterReconnectReservation(exact)) {
      return this.result(true, 'reconnect_reserved');
    }
    // snapshot() may consume the one terminal receipt. If registry rotation
    // fails, still retire the exact old native identity instead of leaving the
    // process-global media/input owners permanently occupied.
    this.acceptNativeTerminalReceipt(exact);
    return this.result(false, 'registry_lost');
  }

  suspendSurfaceForRoute(hostId: string, appId: string): MoonlightCoordinatorResult {
    this.expireStopIfNeeded(Date.now());
    if (!this.ownedNativeRouteMatches(hostId, appId)) {
      return this.result(false, 'not_active');
    }
    if (this.runtime === null || this.runtime.suspendSurface === undefined) {
      return this.result(false, 'lifecycle_unsupported');
    }
    if (!this.runtime.suspendSurface(this.operationGeneration)) {
      return this.result(false, 'registry_lost');
    }
    if (!this.registry.markRenderDetached()) {
      this.invalidate('registry_lost');
      return this.result(false, 'registry_lost');
    }
    return this.result(true, 'surface_detached');
  }

  rebindSurfaceForRoute(hostId: string, appId: string, rendererHandle: number,
    surfaceId: string): MoonlightCoordinatorResult {
    this.expireStopIfNeeded(Date.now());
    if (!this.activeRouteMatches(hostId, appId) || !validSessionId(rendererHandle) ||
        !boundedText(surfaceId, 256)) {
      return this.result(false, 'not_active');
    }
    if (this.runtime === null || this.runtime.rebindSurface === undefined) {
      return this.result(false, 'lifecycle_unsupported');
    }
    if (!this.runtime.rebindSurface(this.operationGeneration, rendererHandle)) {
      return this.result(false, 'registry_lost');
    }
    // A rebound decoder must present a fresh IDR before registry/render
    // admission is reopened. confirmSurfaceFrameForRoute() performs that
    // barrier from the exact native snapshot.
    if (!this.registry.markRenderDetached()) {
      this.invalidate('registry_lost');
      return this.result(false, 'registry_lost');
    }
    return this.result(true, 'surface_rebound');
  }

  confirmSurfaceFrameForRoute(hostId: string, appId: string,
    surfaceId: string): MoonlightCoordinatorResult {
    this.expireStopIfNeeded(Date.now());
    if (!this.activeRouteMatches(hostId, appId) || !boundedText(surfaceId, 256)) {
      return this.result(false, 'not_active');
    }
    if (this.runtime === null || this.runtime.snapshot === undefined) {
      return this.result(false, 'lifecycle_unsupported');
    }
    const source: MoonlightNativeStreamSnapshot | null =
      this.runtime.snapshot(this.operationGeneration);
    if (source === null || !source.matched || source.terminal ||
        source.sessionId !== this.nativeSessionId) {
      return this.result(false, 'registry_lost');
    }
    const presentationFrameReady: boolean =
      source.presentationFrameReady === undefined ?
        source.firstFrameReady : source.presentationFrameReady;
    if (!presentationFrameReady) {
      return this.result(false, 'surface_frame_pending');
    }
    if (!this.registry.markRenderAttached(surfaceId)) {
      this.invalidate('registry_lost');
      return this.result(false, 'registry_lost');
    }
    return this.result(true, 'surface_rebound');
  }

  setAudioPausedForRoute(hostId: string, appId: string,
    paused: boolean): MoonlightCoordinatorResult {
    this.expireStopIfNeeded(Date.now());
    if (!this.activeRouteMatches(hostId, appId)) {
      return this.result(false, 'not_active');
    }
    if (this.runtime === null || this.runtime.setAudioPaused === undefined) {
      return this.result(false, 'lifecycle_unsupported');
    }
    if (!this.runtime.setAudioPaused(this.operationGeneration, paused)) {
      return this.result(false, 'registry_lost');
    }
    return this.result(true, paused ? 'audio_paused' : 'audio_resumed');
  }

  requestStop(reason: string = 'user-stop'): MoonlightCoordinatorResult {
    this.expireStopIfNeeded(Date.now());
    if (this.state === null || this.state.phase === 'disconnected' || this.state.phase === 'failed') {
      return this.result(false, 'not_active');
    }
    if (this.state.phase === 'stopping') {
      return this.result(false, 'already_stopping');
    }
    this.reconnectEnabled = false;
    const event: MoonlightCoordinatorEvent = {
      type: 'stopRequested', generation: this.state.generation,
      sequence: this.state.lastEventSequence + 1, nativeError: '', detailCode: reason,
      nativeSessionId: this.nativeSessionId, surfaceId: ''
    };
    const transition = applyMoonlightSessionEvent(this.state, sessionEvent(event));
    if (!transition.applied) {
      return this.result(false, 'invalid_transition');
    }
    this.state = transition.state;
    this.firstFrameDeadlineAtMs = 0;
    if (this.reservationSessionId > 0 && !this.runtimeStartIssued) {
      const terminalOwnerScopeId: string = this.state.ownerScopeId;
      const terminalHostId: string = this.state.hostId;
      const terminalAppId: string = this.state.appId;
      const stopped = applyMoonlightSessionEvent(this.state, {
        type: 'stopped', generation: this.state.generation,
        sequence: this.state.lastEventSequence + 1, nativeError: '', detailCode: reason
      });
      if (stopped.applied) { this.state = stopped.state; }
      this.clearOwnedRegistry();
      this.reservationSessionId = -1;
      this.reservationIdentity = null;
      this.runtimeStartIssued = false;
      if (this.recoveryRuntime !== null) {
        this.recoveryRuntime.acceptNoRuntimeTerminal(
          terminalOwnerScopeId, this.boundAccountGeneration,
          terminalHostId, terminalAppId, Date.now());
      }
      this.notifySnapshotSubscribers();
      return this.result(true, 'stopped');
    }
    if (!this.requestRuntimeStop(reason)) {
      this.forceLocalTerminal('STOP_FAILED');
      return this.result(false, 'stop_failed');
    }
    this.stopDeadlineAtMs = Date.now() + 5000;
    this.scheduleStopTimer();
    this.notifySnapshotSubscribers();
    return this.result(true, 'stop_requested');
  }

  /**
   * Account/data lifecycle stop that does not confuse the coordinator's local
   * timeout with native teardown. Success requires a typed runtime terminal
   * receipt, unless no native session was ever started.
   */
  async stopForLifecycle(reason: string, timeoutMs: number): Promise<boolean> {
    if (reason.trim().length === 0 || !Number.isSafeInteger(timeoutMs) || timeoutMs <= 0) {
      return false;
    }
    const requested: MoonlightCoordinatorResult = this.requestStop(reason);
    if (requested.code === 'stop_failed') { return false; }
    if (requested.code === 'not_active' && !this.nativeRuntimeMayBeActive) { return true; }
    if (requested.code !== 'stop_requested' && requested.code !== 'already_stopping' &&
        requested.code !== 'stopped' && requested.code !== 'not_active') {
      return false;
    }
    if (!this.nativeRuntimeMayBeActive) { return true; }
    if (requested.code === 'not_active' && this.runtime !== null) {
      // A previous UI stop may have reached the local timeout while common-c
      // is still unwinding. Reassert cancellation and wait for native truth.
      this.runtime.cancel(this.operationGeneration, reason);
    }
    const deadlineAtMs: number = Date.now() + timeoutMs;
    while (Date.now() < deadlineAtMs) {
      if (!this.nativeRuntimeMayBeActive) { return true; }
      if (this.runtime !== null && this.runtime.snapshot !== undefined) {
        const source: MoonlightNativeStreamSnapshot | null =
          this.runtime.snapshot(this.operationGeneration);
        if (this.nativeTerminalSnapshotMatchesActive(source)) {
          this.acceptNativeTerminalReceipt(source as MoonlightNativeStreamSnapshot);
          return true;
        }
      }
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 25);
      });
    }
    return false;
  }

  /**
   * Synchronously reconcile the process-wide Moonlight owner before another
   * protocol or a new catalog launch performs admission. Local UI failure is
   * never treated as teardown proof; only the exact native terminal snapshot
   * can release the shared registry marker.
   */
  reconcileNativeTerminalReceipt(): boolean {
    this.expireStopIfNeeded(Date.now());
    if (!this.nativeRuntimeMayBeActive) { return true; }
    if (this.runtime === null || this.runtime.snapshot === undefined) { return false; }
    const source: MoonlightNativeStreamSnapshot | null =
      this.runtime.snapshot(this.operationGeneration);
    if (!this.nativeTerminalSnapshotMatchesActive(source)) { return false; }
    this.acceptNativeTerminalReceipt(source as MoonlightNativeStreamSnapshot);
    return !this.nativeRuntimeMayBeActive;
  }

  cancel(reason: string = 'user-cancel'): MoonlightCoordinatorResult {
    this.expireStopIfNeeded(Date.now());
    if (this.state === null || this.state.phase === 'disconnected' || this.state.phase === 'failed') {
      return this.result(false, 'not_active');
    }
    if (this.state.phase === 'stopping') {
      return this.result(false, 'already_stopping');
    }
    this.reconnectEnabled = false;
    const event: MoonlightCoordinatorEvent = {
      type: 'cancelled', generation: this.state.generation,
      sequence: this.state.lastEventSequence + 1, nativeError: 'CANCELLED', detailCode: reason,
      nativeSessionId: this.nativeSessionId, surfaceId: ''
    };
    const transition = applyMoonlightSessionEvent(this.state, sessionEvent(event));
    if (!transition.applied) {
      return this.result(false, 'invalid_transition');
    }
    this.state = transition.state;
    this.firstFrameDeadlineAtMs = 0;
    if (this.reservationSessionId > 0 && !this.runtimeStartIssued) {
      const terminalOwnerScopeId: string = this.state.ownerScopeId;
      const terminalHostId: string = this.state.hostId;
      const terminalAppId: string = this.state.appId;
      const stopped = applyMoonlightSessionEvent(this.state, {
        type: 'stopped', generation: this.state.generation,
        sequence: this.state.lastEventSequence + 1, nativeError: '', detailCode: reason
      });
      if (stopped.applied) { this.state = stopped.state; }
      this.clearOwnedRegistry();
      this.reservationSessionId = -1;
      this.reservationIdentity = null;
      this.runtimeStartIssued = false;
      if (this.recoveryRuntime !== null) {
        this.recoveryRuntime.acceptNoRuntimeTerminal(
          terminalOwnerScopeId, this.boundAccountGeneration,
          terminalHostId, terminalAppId, Date.now());
      }
      this.notifySnapshotSubscribers();
      return this.result(true, 'stopped');
    }
    if (!this.requestRuntimeStop(reason)) {
      this.forceLocalTerminal('STOP_FAILED');
      return this.result(false, 'stop_failed');
    }
    this.stopDeadlineAtMs = Date.now() + 5000;
    this.scheduleStopTimer();
    this.notifySnapshotSubscribers();
    return this.result(true, 'stop_requested');
  }

  cancelForRoute(hostId: string, appId: string, reason: string): MoonlightCoordinatorResult {
    if (this.state === null || this.state.hostId !== hostId || this.state.appId !== appId) {
      return this.result(false, 'not_active');
    }
    return this.cancel(reason);
  }

  snapshotForRoute(hostId: string, appId: string): MoonlightSessionStateSnapshot | null {
    this.expireStopIfNeeded(Date.now());
    if (this.state === null || this.state.hostId !== hostId || this.state.appId !== appId) {
      return null;
    }
    return cloneState(this.state);
  }

  subscribeForRoute(ownerScopeId: string, accountGeneration: number, hostId: string,
    appId: string, listener: MoonlightSessionSnapshotListener): () => void {
    const subscription: MoonlightSessionSnapshotSubscription = {
      ownerScopeId: ownerScopeId.trim(), accountGeneration: accountGeneration,
      hostId: hostId.trim(), appId: appId.trim(), listener: listener
    };
    if (!boundedText(subscription.ownerScopeId, 128) ||
      !validGeneration(subscription.accountGeneration) ||
      !boundedText(subscription.hostId, 128) || !boundedText(subscription.appId, 128)) {
      return (): void => {};
    }
    this.snapshotSubscriptions.push(subscription);
    this.notifySnapshotSubscription(subscription);
    return (): void => {
      const index: number = this.snapshotSubscriptions.indexOf(subscription);
      if (index >= 0) { this.snapshotSubscriptions.splice(index, 1); }
    };
  }

  resetForTest(): void {
    this.clearRuntimePoll();
    this.resetRuntimePollBackoff();
    this.requestRuntimeStop('test-reset');
    this.clearOwnedRegistry();
    this.state = null;
    this.nativeSessionId = -1;
    this.reservationSessionId = -1;
    this.reservationIdentity = null;
    this.runtimeStartIssued = false;
    this.stopDeadlineAtMs = 0;
    this.firstFrameDeadlineAtMs = 0;
    this.reconnectEnabled = false;
    this.nativeRuntimeMayBeActive = false;
    this.pendingTeardownNativeError = '';
    this.pendingTeardownDetailCode = '';
    this.pendingBoundOwnerScopeId = '';
    this.pendingBoundAccountGeneration = 0;
    this.pendingScopeChange = false;
    this.clearStopTimer();
    this.snapshotSubscriptions.splice(0, this.snapshotSubscriptions.length);
  }

  expireStop(nowMs: number = Date.now()): MoonlightCoordinatorResult {
    if (this.expireStopIfNeeded(nowMs)) {
      return this.result(false, 'stop_timeout');
    }
    return this.result(false, 'not_active');
  }

  expireFirstFrame(nowMs: number = Date.now()): MoonlightCoordinatorResult {
    if (this.expireFirstFrameIfNeeded(nowMs)) {
      return this.result(false, 'first_frame_timeout');
    }
    return this.result(false, 'not_active');
  }

  private activeRouteMatches(hostId: string, appId: string): boolean {
    return this.state !== null && this.nativeSessionId > 0 &&
      this.runtimeStartIssued && this.state.hostId === hostId &&
      this.state.appId === appId && this.state.phase !== 'stopping' &&
      this.state.phase !== 'failed' && this.state.phase !== 'disconnected';
  }

  private ownedNativeRouteMatches(hostId: string, appId: string): boolean {
    return this.state !== null && this.nativeSessionId > 0 &&
      this.runtimeStartIssued && this.nativeRuntimeMayBeActive &&
      this.state.hostId === hostId && this.state.appId === appId &&
      this.state.phase !== 'disconnected';
  }

  private validRequest(request: MoonlightSessionStartRequest): boolean {
    if (!this.validReservationRequest(request) || request.hostControlAlreadyLaunched !== true) {
      return this.validReservationRequest(request);
    }
    return request.rendererHandle !== undefined && validSessionId(request.rendererHandle) &&
      request.surfaceWidth !== undefined && validSessionId(request.surfaceWidth) &&
      request.surfaceHeight !== undefined && validSessionId(request.surfaceHeight) &&
      request.surfaceId !== undefined && boundedText(request.surfaceId, 256);
  }

  private validReservationRequest(request: MoonlightSessionStartRequest): boolean {
    const baseValid: boolean = boundedText(request.ownerScopeId, 128) &&
      validGeneration(request.accountGeneration) &&
      boundedText(request.hostId, 128) && boundedText(request.appId, 128) &&
      boundedText(request.hostAddress, 255);
    if (!baseValid || request.hostControlAlreadyLaunched !== true) { return baseValid; }
    return request.launchKey !== undefined && validSessionId(request.launchKey.requestId) &&
      validSessionId(request.launchKey.generation) && validSessionId(request.launchKey.ownerToken) &&
      request.serverUuid !== undefined && boundedText(request.serverUuid, 256) &&
      request.numericAppId !== undefined && validSessionId(request.numericAppId) &&
      request.effectiveSettingsEncoded !== undefined &&
      decodeMoonlightEffectiveSettings(request.effectiveSettingsEncoded) !== null &&
      (request.configuredBitrateKbps === undefined ||
        (Number.isSafeInteger(request.configuredBitrateKbps) &&
          request.configuredBitrateKbps >= 1000 && request.configuredBitrateKbps <= 200000));
  }

  private createReservationIdentity(
    request: MoonlightSessionStartRequest
  ): MoonlightSessionReservationIdentity {
    const identity: MoonlightSessionReservationIdentity = new MoonlightSessionReservationIdentity();
    identity.ownerScopeId = request.ownerScopeId;
    identity.accountGeneration = request.accountGeneration;
    identity.hostId = request.hostId;
    identity.appId = request.appId;
    identity.hostAddress = request.hostAddress;
    identity.hostControlAlreadyLaunched = request.hostControlAlreadyLaunched === true;
    if (request.launchKey !== undefined) {
      identity.launchRequestId = request.launchKey.requestId;
      identity.launchGeneration = request.launchKey.generation;
      identity.launchOwnerToken = request.launchKey.ownerToken;
    }
    identity.serverUuid = request.serverUuid === undefined ? '' : request.serverUuid;
    identity.numericAppId = request.numericAppId === undefined ? 0 : request.numericAppId;
    identity.configuredBitrateKbps = request.configuredBitrateKbps === undefined
      ? 20000 : request.configuredBitrateKbps;
    identity.effectiveSettingsEncoded = request.effectiveSettingsEncoded === undefined ?
      '' : request.effectiveSettingsEncoded;
    identity.resetRemoteInputBeforeAdmission =
      request.resetRemoteInputBeforeAdmission === true;
    return identity;
  }

  private reservationMatches(request: MoonlightSessionStartRequest): boolean {
    const identity: MoonlightSessionReservationIdentity | null = this.reservationIdentity;
    if (identity === null || this.state === null || this.reservationSessionId <= 0) {
      return false;
    }
    const launchKey: MoonlightNativeRequestKey | undefined = request.launchKey;
    return identity.ownerScopeId === request.ownerScopeId &&
      identity.accountGeneration === request.accountGeneration &&
      identity.hostId === request.hostId && identity.appId === request.appId &&
      identity.hostAddress === request.hostAddress &&
      identity.hostControlAlreadyLaunched === (request.hostControlAlreadyLaunched === true) &&
      identity.launchRequestId === (launchKey === undefined ? 0 : launchKey.requestId) &&
      identity.launchGeneration === (launchKey === undefined ? 0 : launchKey.generation) &&
      identity.launchOwnerToken === (launchKey === undefined ? 0 : launchKey.ownerToken) &&
      identity.serverUuid === (request.serverUuid === undefined ? '' : request.serverUuid) &&
      identity.numericAppId === (request.numericAppId === undefined ? 0 : request.numericAppId) &&
      identity.configuredBitrateKbps === (request.configuredBitrateKbps === undefined
        ? 20000 : request.configuredBitrateKbps) &&
      identity.effectiveSettingsEncoded === (request.effectiveSettingsEncoded === undefined ?
        '' : request.effectiveSettingsEncoded) &&
      identity.resetRemoteInputBeforeAdmission ===
        (request.resetRemoteInputBeforeAdmission === true);
  }

  private scheduleRuntimePoll(surfaceId: string): void {
    if (this.runtimePollLocked) { return; }
    this.clearRuntimePoll();
    const generation: number = this.operationGeneration;
    const delayMs: number = moonlightRuntimePollDelayMs(this.runtimePollMisses);
    this.runtimePollTimer = this.runtimePollScheduler.schedule((): void => {
      this.runtimePollTimer = -1;
      this.processRuntimePoll(surfaceId, generation,
        this.runtimePollScheduler.nowMs());
    }, delayMs);
  }

  private processRuntimePoll(surfaceId: string, generation: number,
    nowMs: number): void {
    if (this.runtimePollLocked || this.state === null ||
        this.state.generation !== generation || this.runtime === null ||
        this.runtime.snapshot === undefined) { return; }
    const source: MoonlightNativeStreamSnapshot | null = this.runtime.snapshot(generation);
    if (source === null || !source.matched) {
      if (this.runtimePollMisses < Number.MAX_SAFE_INTEGER) {
        this.runtimePollMisses += 1;
      }
      if (moonlightRuntimePollShouldLock(this.runtimePollMisses)) {
        // Keep the exact native/shared registry identity occupied. A missing
        // terminal receipt is not permission to admit another protocol or
        // account; after bounded backoff, process restart is the only safe
        // recovery instead of an endless 100 ms wakeup loop.
        this.runtimePollLocked = true;
      }
      if (this.expireFirstFrameIfNeeded(nowMs)) { return; }
      if (!this.runtimePollLocked) {
        this.scheduleRuntimePoll(surfaceId);
      }
      return;
    }
    this.resetRuntimePollBackoff();
    if (this.recoveryRuntime !== null && this.state !== null) {
      this.recoveryRuntime.observeNativeSnapshot(
        this.state.ownerScopeId, this.boundAccountGeneration,
        this.state.hostId, this.state.appId, source, nowMs);
    }
    if (source.terminal) {
      if (this.pendingTeardownNativeError.length === 0 &&
          this.state.phase !== 'stopping' && this.reconnectEnabled &&
          this.runtimeCodeAllowsReconnect(source.code) &&
          this.enterReconnectReservation(source)) {
        return;
      }
      this.acceptNativeTerminalReceipt(source);
      return;
    }
    const planned: MoonlightSessionEventType[] =
      moonlightRuntimeReadinessEvents(this.state, source);
    if (source.firstFrameReady && !this.state.firstFrameSeen) {
      hilog.info(0x0014, 'MoonlightCoordinator',
        'native first-frame snapshot session=' + source.sessionId.toString() +
        ' generation=' + generation.toString() + ' phase=' + this.state.phase +
        ' video=' + (source.videoReady ? '1' : '0') +
        ' audio=' + (source.audioReady ? '1' : '0') +
        ' input=' + (source.inputReady ? '1' : '0') +
        ' surface=' + (surfaceId.trim() === '' ? 'missing' : 'ready') +
        ' events=' + planned.join(','));
    }
    for (let index: number = 0; index < planned.length; index++) {
      const type: MoonlightSessionEventType = planned[index];
      const eventSurfaceId: string = type === 'firstFrameRendered' ? surfaceId : '';
      const emitted: MoonlightCoordinatorResult =
        this.emitRuntimeEvent(type, generation, '', '', eventSurfaceId);
      if (!emitted.accepted) {
        hilog.error(0x0014, 'MoonlightCoordinator',
          'runtime readiness rejected event=' + type + ' code=' + emitted.code +
          ' generation=' + generation.toString() +
          ' phase=' + (emitted.state === null ? 'none' : emitted.state.phase));
        return;
      }
    }
    if (this.expireFirstFrameIfNeeded(nowMs)) { return; }
    if (this.state !== null && this.state.generation === generation) {
      this.scheduleRuntimePoll(surfaceId);
    }
  }

  private emitRuntimeEvent(type: MoonlightSessionEventType, generation: number,
    nativeError: string, detailCode: string, surfaceId: string): MoonlightCoordinatorResult {
    const current: MoonlightSessionStateSnapshot | null = this.state;
    if (current === null || current.generation !== generation) {
      return this.result(false, current === null ? 'not_active' : 'stale_generation');
    }
    const result: MoonlightCoordinatorResult = this.handleRuntimeEvent({
      type: type,
      generation: generation,
      sequence: current.lastEventSequence + 1,
      nativeError: nativeError,
      detailCode: detailCode,
      nativeSessionId: this.nativeSessionId,
      surfaceId: surfaceId
    });
    if (result.accepted && (this.state === null || this.state.generation !== generation)) {
      return this.result(false, 'stale_generation');
    }
    return result;
  }

  private clearRuntimePoll(): void {
    if (this.runtimePollTimer >= 0) {
      this.runtimePollScheduler.cancel(this.runtimePollTimer);
      this.runtimePollTimer = -1;
    }
  }

  private resetRuntimePollBackoff(): void {
    this.runtimePollMisses = 0;
    this.runtimePollLocked = false;
  }

  private runtimeCodeAllowsReconnect(code: string): boolean {
    return code === 'connection_terminated' || code === 'connection_failed' ||
      code === 'deadline_exceeded';
  }

  private nativeTerminalSnapshotMatchesActive(
    source: MoonlightNativeStreamSnapshot | null
  ): boolean {
    if (source === null || !this.nativeRuntimeMayBeActive ||
        !source.matched || !source.terminal || source.sessionId <= 0) {
      return false;
    }
    if (this.nativeSessionId > 0 && source.sessionId !== this.nativeSessionId) {
      return false;
    }
    const identity: MoonlightSessionReservationIdentity | null = this.reservationIdentity;
    if (identity !== null && identity.launchGeneration > 0 &&
        (source.generation !== identity.launchGeneration ||
          source.ownerToken !== identity.launchOwnerToken)) {
      return false;
    }
    return true;
  }

  private reconnectTerminalSnapshotMatchesActive(
    source: MoonlightNativeStreamSnapshot | null
  ): boolean {
    const identity: MoonlightSessionReservationIdentity | null = this.reservationIdentity;
    return identity !== null && identity.launchGeneration > 0 &&
      identity.launchOwnerToken > 0 && this.nativeSessionId > 0 &&
      this.nativeTerminalSnapshotMatchesActive(source);
  }

  private enterReconnectReservation(source: MoonlightNativeStreamSnapshot): boolean {
    const current: MoonlightSessionStateSnapshot | null = this.state;
    const oldNativeSessionId: number = this.nativeSessionId;
    if (!this.reconnectTerminalSnapshotMatchesActive(source) ||
        !this.runtimeCodeAllowsReconnect(source.code) ||
        current === null || oldNativeSessionId <= 0 ||
        current.phase === 'stopping' || current.phase === 'failed' ||
        current.phase === 'disconnected') {
      return false;
    }
    const transition = applyMoonlightSessionEvent(current, {
      type: 'transportLost', generation: current.generation,
      sequence: current.lastEventSequence + 1,
      nativeError: 'NETWORK_UNREACHABLE', detailCode: source.code
    });
    if (!transition.applied) { return false; }
    if (!Number.isSafeInteger(this.operationGeneration) ||
        this.operationGeneration >= Number.MAX_SAFE_INTEGER) {
      return false;
    }
    const nextGeneration: number = this.operationGeneration + 1;
    const rebound: MoonlightSessionStateSnapshot | null =
      rebaseMoonlightSessionForReconnect(
        transition.state, 'moonlight-' + nextGeneration.toString(), nextGeneration);
    if (rebound === null) { return false; }
    const reservationSessionId: number = nextGeneration;
    if (!this.registry.rotateMoonlightToReconnectReservation(
      current.ownerScopeId, this.boundAccountGeneration, oldNativeSessionId,
      reservationSessionId, current.hostId)) {
      return false;
    }
    this.clearRuntimePoll();
    this.resetRuntimePollBackoff();
    this.clearStopTimer();
    this.operationGeneration = nextGeneration;
    this.state = rebound;
    this.nativeSessionId = -1;
    this.reservationSessionId = reservationSessionId;
    this.reservationIdentity = null;
    this.runtimeStartIssued = false;
    this.nativeRuntimeMayBeActive = false;
    this.stopDeadlineAtMs = 0;
    this.firstFrameDeadlineAtMs = 0;
    this.pendingTeardownNativeError = '';
    this.pendingTeardownDetailCode = '';
    this.notifySnapshotSubscribers();
    return true;
  }

  private clearOwnedRegistry(): void {
    if (this.state !== null && this.nativeSessionId > 0) {
      this.registry.clearIfMatches(this.state.ownerScopeId, this.boundAccountGeneration,
        this.nativeSessionId, RemoteProtocol.moonlight);
    }
    if (this.state !== null && this.reservationSessionId > 0) {
      this.registry.clearIfMatches(this.state.ownerScopeId, this.boundAccountGeneration,
        this.reservationSessionId, RemoteProtocol.moonlight);
    }
  }

  private notifySnapshotSubscription(subscription: MoonlightSessionSnapshotSubscription): void {
    const snapshot: MoonlightSessionStateSnapshot | null = cloneState(this.state);
    const visible: MoonlightSessionStateSnapshot | null = snapshot !== null &&
      snapshot.ownerScopeId === subscription.ownerScopeId &&
      !this.pendingScopeChange &&
      this.boundOwnerScopeId === subscription.ownerScopeId &&
      this.boundAccountGeneration === subscription.accountGeneration &&
      snapshot.hostId === subscription.hostId && snapshot.appId === subscription.appId
      ? snapshot : null;
    try {
      subscription.listener(visible);
    } catch (_error) {
      // A stale page must not interrupt session lifecycle delivery.
    }
  }

  private notifySnapshotSubscribers(): void {
    if (this.recoveryRuntime !== null && this.state !== null) {
      this.recoveryRuntime.observeState(
        this.state.ownerScopeId, this.boundAccountGeneration,
        this.state.hostId, this.state.appId, this.state.phase, Date.now());
    }
    const subscriptions: MoonlightSessionSnapshotSubscription[] =
      this.snapshotSubscriptions.slice();
    for (let i = 0; i < subscriptions.length; i++) {
      this.notifySnapshotSubscription(subscriptions[i]);
    }
  }

  private invalidate(reason: string): void {
    this.reconnectEnabled = false;
    if (this.nativeRuntimeMayBeActive) {
      this.requestRuntimeStop(reason);
      this.forceLocalTerminal('INVALIDATED', reason);
      return;
    }
    this.clearRuntimePoll();
    this.resetRuntimePollBackoff();
    this.clearOwnedRegistry();
    this.state = null;
    this.nativeSessionId = -1;
    this.reservationSessionId = -1;
    this.reservationIdentity = null;
    this.runtimeStartIssued = false;
    this.stopDeadlineAtMs = 0;
    this.firstFrameDeadlineAtMs = 0;
    this.reconnectEnabled = false;
    this.pendingTeardownNativeError = '';
    this.pendingTeardownDetailCode = '';
    this.clearStopTimer();
    this.notifySnapshotSubscribers();
    if (this.applyPendingBoundScopeIfIdle()) { this.notifySnapshotSubscribers(); }
  }

  private applyBoundScope(ownerScopeId: string, accountGeneration: number): void {
    this.boundOwnerScopeId = ownerScopeId;
    this.boundAccountGeneration = accountGeneration;
  }

  private applyPendingBoundScopeIfIdle(): boolean {
    if (!this.pendingScopeChange || this.nativeRuntimeMayBeActive) { return false; }
    this.applyBoundScope(this.pendingBoundOwnerScopeId,
      this.pendingBoundAccountGeneration);
    this.pendingBoundOwnerScopeId = '';
    this.pendingBoundAccountGeneration = 0;
    this.pendingScopeChange = false;
    return true;
  }

  private requestRuntimeStop(reason: string): boolean {
    if (this.runtime === null) {
      return false;
    }
    if (this.nativeSessionId > 0) {
      return this.runtime.stop(this.nativeSessionId, reason);
    }
    if (this.reservationSessionId > 0 && this.runtimeStartIssued) {
      return this.runtime.cancel(this.operationGeneration, reason);
    }
    return true;
  }

  private forceLocalTerminal(nativeError: string, detailCode: string = 'local_terminal'): void {
    if (this.state !== null && this.state.phase !== 'disconnected' &&
        this.state.phase !== 'failed') {
      const terminalEvent: MoonlightSessionEvent = {
        type: 'failed', generation: this.state.generation,
        sequence: this.state.lastEventSequence + 1,
        nativeError: nativeError, detailCode: detailCode
      };
      const transition = applyMoonlightSessionEvent(this.state, terminalEvent);
      if (transition.applied) {
        this.state = transition.state;
      }
    }
    this.pendingTeardownNativeError = nativeError;
    this.pendingTeardownDetailCode = detailCode;
    this.stopDeadlineAtMs = 0;
    this.firstFrameDeadlineAtMs = 0;
    this.reconnectEnabled = false;
    this.clearStopTimer();

    if (this.nativeRuntimeMayBeActive) {
      // Local timeout/failure is UI truth only. Preserve the shared registry
      // marker and runtime identity until a typed native terminal receipt is
      // observed. Continue polling even after the page has gone away.
      if (this.runtimePollTimer < 0 && this.runtime !== null &&
          this.runtime.snapshot !== undefined) {
        this.scheduleRuntimePoll('');
      }
      this.notifySnapshotSubscribers();
      return;
    }

    this.clearRuntimePoll();
    this.resetRuntimePollBackoff();
    this.clearOwnedRegistry();
    this.state = null;
    this.nativeSessionId = -1;
    this.reservationSessionId = -1;
    this.reservationIdentity = null;
    this.runtimeStartIssued = false;
    this.pendingTeardownNativeError = '';
    this.pendingTeardownDetailCode = '';
    this.notifySnapshotSubscribers();
    if (this.applyPendingBoundScopeIfIdle()) { this.notifySnapshotSubscribers(); }
  }

  private acceptNativeTerminalReceipt(source: MoonlightNativeStreamSnapshot): void {
    if (!this.nativeTerminalSnapshotMatchesActive(source)) { return; }
    const sourceCode: string = source.code;
    const current: MoonlightSessionStateSnapshot | null = this.state;
    const terminalOwnerScopeId: string = current === null ? '' : current.ownerScopeId;
    const terminalAccountGeneration: number = this.boundAccountGeneration;
    const terminalHostId: string = current === null ? '' : current.hostId;
    const terminalAppId: string = current === null ? '' : current.appId;
    if (current !== null) {
      const hasLocalFailure: boolean = this.pendingTeardownNativeError.length > 0;
      const terminalType: MoonlightSessionEventType =
        hasLocalFailure || current.phase !== 'stopping' ? 'failed' : 'stopped';
      const accepted: MoonlightCoordinatorResult = this.handleRuntimeEvent({
        type: terminalType,
        generation: current.generation,
        sequence: current.lastEventSequence + 1,
        nativeError: terminalType === 'failed'
          ? (hasLocalFailure ? this.pendingTeardownNativeError :
            moonlightRuntimeNativeError(sourceCode)) : '',
        detailCode: hasLocalFailure ? this.pendingTeardownDetailCode : sourceCode,
        nativeSessionId: this.nativeSessionId,
        surfaceId: ''
      });
      if (accepted.accepted) {
        if (this.recoveryRuntime !== null) {
          this.recoveryRuntime.acceptNativeTerminal(
            terminalOwnerScopeId, terminalAccountGeneration,
            terminalHostId, terminalAppId, source, Date.now());
        }
        return;
      }
    }

    // A terminal native receipt is authoritative even if a stale local state
    // transition cannot be represented. Release only our exact registry
    // marker, then close all local runtime identities.
    this.nativeRuntimeMayBeActive = false;
    this.clearRuntimePoll();
    this.resetRuntimePollBackoff();
    this.clearStopTimer();
    this.clearOwnedRegistry();
    this.nativeSessionId = -1;
    this.reservationSessionId = -1;
    this.reservationIdentity = null;
    this.runtimeStartIssued = false;
    this.stopDeadlineAtMs = 0;
    this.firstFrameDeadlineAtMs = 0;
    this.reconnectEnabled = false;
    this.pendingTeardownNativeError = '';
    this.pendingTeardownDetailCode = '';
    this.notifySnapshotSubscribers();
    if (this.recoveryRuntime !== null) {
      this.recoveryRuntime.acceptNativeTerminal(
        terminalOwnerScopeId, terminalAccountGeneration,
        terminalHostId, terminalAppId, source, Date.now());
    }
    if (this.applyPendingBoundScopeIfIdle()) { this.notifySnapshotSubscribers(); }
  }

  private expireStopIfNeeded(nowMs: number): boolean {
    if (this.state === null || this.state.phase !== 'stopping' ||
      this.stopDeadlineAtMs <= 0 || nowMs < this.stopDeadlineAtMs) {
      return false;
    }
    this.forceLocalTerminal('STOP_TIMEOUT');
    return true;
  }

  private expireFirstFrameIfNeeded(nowMs: number): boolean {
    if (this.state === null || this.state.phase === 'stopping' ||
        this.state.phase === 'failed' || this.state.phase === 'disconnected' ||
        this.state.firstFrameSeen || this.firstFrameDeadlineAtMs <= 0 ||
        nowMs < this.firstFrameDeadlineAtMs) {
      return false;
    }
    this.requestRuntimeStop('first-frame-timeout');
    this.forceLocalTerminal('FIRST_FRAME_TIMEOUT', 'first_frame_timeout');
    return true;
  }

  private scheduleStopTimer(): void {
    this.clearStopTimer();
    this.stopTimer = setTimeout((): void => {
      this.stopTimer = -1;
      this.expireStopIfNeeded(Date.now());
    }, 5000);
  }

  private clearStopTimer(): void {
    if (this.stopTimer >= 0) {
      clearTimeout(this.stopTimer);
      this.stopTimer = -1;
    }
  }

  private result(accepted: boolean, code: MoonlightCoordinatorResultCode): MoonlightCoordinatorResult {
    return {
      accepted: accepted,
      code: code,
      state: cloneState(this.state),
      nativeSessionId: this.nativeSessionId
    };
  }
}
