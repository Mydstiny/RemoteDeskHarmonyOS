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
  createMoonlightSessionState
} from './MoonlightSessionState';
import rdpnapi from 'librdpnapi.so';
import {
  MoonlightNativeRequestKey,
  MoonlightNativeStreamSnapshot
} from './MoonlightHostService';
import { MoonlightEffectiveSettings } from '../model/MoonlightModels';
import { decodeMoonlightEffectiveSettings } from './MoonlightSettingsPolicy';

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
      const snapshot: MoonlightNativeStreamSnapshot = {
        matched: source.matched,
        code: source.code,
        sessionId: source.sessionId,
        generation: source.generation,
        ownerToken: source.ownerToken,
        transportReady: source.transportReady,
        videoReady: source.videoReady,
        audioReady: source.audioReady,
        inputReady: source.inputReady,
        controllerReady: source.controllerReady,
        physicalControllerReady: source.physicalControllerReady,
        firstFrameReady: source.firstFrameReady,
        terminal: source.terminal,
        lastSequence: source.lastSequence
      };
      // moonlightStopStream() only acknowledges the cancellation request. Keep
      // the launch key alive so polling can observe the native terminal receipt;
      // release the local identity only after that receipt has been copied.
      if (source.terminal) {
        this.launchKey = null;
        this.sessionId = -1;
      }
      return snapshot;
    } catch (_) { return null; }
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
  'registry_rejected' | 'registry_lost' | 'surface_missing' | 'render_not_attached' |
  'not_active' | 'stop_requested' | 'already_stopping' | 'stopped';

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
  private state: MoonlightSessionStateSnapshot | null = null;
  private nativeSessionId: number = -1;
  private reservationSessionId: number = -1;
  private reservationIdentity: MoonlightSessionReservationIdentity | null = null;
  private runtimeStartIssued: boolean = false;
  private operationGeneration: number = 0;
  private boundOwnerScopeId: string = '';
  private boundAccountGeneration: number = 0;
  private stopDeadlineAtMs: number = 0;
  private stopTimer: number = -1;
  private runtimePollTimer: number = -1;
  private runtimeVideoReady: boolean = false;
  private runtimeAudioReady: boolean = false;
  private runtimeInputReady: boolean = false;
  private readonly snapshotSubscriptions: MoonlightSessionSnapshotSubscription[] = [];

  constructor(runtime: MoonlightRuntimePort | null = null,
    registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance()) {
    this.runtime = runtime;
    this.registry = registry;
  }

  static getInstance(): MoonlightSessionCoordinator {
    if (MoonlightSessionCoordinator.instance === null) {
      MoonlightSessionCoordinator.instance = new MoonlightSessionCoordinator(
        new MoonlightNapiRuntimePort());
    }
    return MoonlightSessionCoordinator.instance;
  }

  bindScope(ownerScopeId: string, accountGeneration: number): void {
    const nextOwner: string = ownerScopeId.trim();
    const changed: boolean = nextOwner !== this.boundOwnerScopeId ||
      accountGeneration !== this.boundAccountGeneration;
    if (changed && this.state !== null) {
      this.invalidate('owner_changed');
    }
    this.boundOwnerScopeId = nextOwner;
    this.boundAccountGeneration = validGeneration(accountGeneration) ? accountGeneration : 0;
  }

  reserve(request: MoonlightSessionStartRequest): MoonlightCoordinatorResult {
    this.expireStopIfNeeded(Date.now());
    if (!this.validReservationRequest(request)) {
      return this.result(false, 'invalid_request');
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
    this.state = firstTransition.state;
    this.notifySnapshotSubscribers();
    return this.result(true, 'reserved');
  }

  start(request: MoonlightSessionStartRequest): MoonlightCoordinatorResult {
    this.expireStopIfNeeded(Date.now());
    if (!this.validRequest(request)) {
      return this.result(false, 'invalid_request');
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
    if (request.hostControlAlreadyLaunched === true) {
      const runtimeSessionId: number = this.runtime.nativeSessionId === undefined
        ? -1 : this.runtime.nativeSessionId(this.operationGeneration);
      const accepted = this.handleRuntimeEvent({
        type: 'launchAccepted', generation: this.operationGeneration,
        sequence: this.state.lastEventSequence + 1, nativeError: '', detailCode: '',
        nativeSessionId: runtimeSessionId, surfaceId: ''
      });
      if (!accepted.accepted) { return accepted; }
      this.runtimeVideoReady = false;
      this.runtimeAudioReady = false;
      this.runtimeInputReady = false;
      this.scheduleRuntimePoll(request.surfaceId === undefined ? '' : request.surfaceId);
    }
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
      this.reservationIdentity = null;
    }

    if (event.type === 'firstFrameRendered') {
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
      this.clearStopTimer();
      this.clearOwnedRegistry();
      this.nativeSessionId = -1;
      this.reservationSessionId = -1;
      this.reservationIdentity = null;
      this.runtimeStartIssued = false;
      this.stopDeadlineAtMs = 0;
    }
    this.notifySnapshotSubscribers();
    return this.result(true, event.type === 'stopped' ? 'stopped' : 'applied');
  }

  requestStop(reason: string = 'user-stop'): MoonlightCoordinatorResult {
    this.expireStopIfNeeded(Date.now());
    if (this.state === null || this.state.phase === 'disconnected' || this.state.phase === 'failed') {
      return this.result(false, 'not_active');
    }
    if (this.state.phase === 'stopping') {
      return this.result(false, 'already_stopping');
    }
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
    if (this.reservationSessionId > 0 && !this.runtimeStartIssued) {
      const stopped = applyMoonlightSessionEvent(this.state, {
        type: 'stopped', generation: this.state.generation,
        sequence: this.state.lastEventSequence + 1, nativeError: '', detailCode: reason
      });
      if (stopped.applied) { this.state = stopped.state; }
      this.clearOwnedRegistry();
      this.reservationSessionId = -1;
      this.reservationIdentity = null;
      this.runtimeStartIssued = false;
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

  cancel(reason: string = 'user-cancel'): MoonlightCoordinatorResult {
    this.expireStopIfNeeded(Date.now());
    if (this.state === null || this.state.phase === 'disconnected' || this.state.phase === 'failed') {
      return this.result(false, 'not_active');
    }
    if (this.state.phase === 'stopping') {
      return this.result(false, 'already_stopping');
    }
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
    if (this.reservationSessionId > 0 && !this.runtimeStartIssued) {
      const stopped = applyMoonlightSessionEvent(this.state, {
        type: 'stopped', generation: this.state.generation,
        sequence: this.state.lastEventSequence + 1, nativeError: '', detailCode: reason
      });
      if (stopped.applied) { this.state = stopped.state; }
      this.clearOwnedRegistry();
      this.reservationSessionId = -1;
      this.reservationIdentity = null;
      this.runtimeStartIssued = false;
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
    this.invalidate('test-reset');
    this.state = null;
    this.nativeSessionId = -1;
    this.reservationSessionId = -1;
    this.reservationIdentity = null;
    this.runtimeStartIssued = false;
    this.stopDeadlineAtMs = 0;
    this.clearRuntimePoll();
    this.snapshotSubscriptions.splice(0, this.snapshotSubscriptions.length);
  }

  expireStop(nowMs: number = Date.now()): MoonlightCoordinatorResult {
    if (this.expireStopIfNeeded(nowMs)) {
      return this.result(false, 'stop_timeout');
    }
    return this.result(false, 'not_active');
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
        '' : request.effectiveSettingsEncoded);
  }

  private scheduleRuntimePoll(surfaceId: string): void {
    this.clearRuntimePoll();
    const generation: number = this.operationGeneration;
    this.runtimePollTimer = setTimeout((): void => {
      this.runtimePollTimer = -1;
      if (this.state === null || this.state.generation !== generation ||
          this.runtime === null || this.runtime.snapshot === undefined) { return; }
      const source: MoonlightNativeStreamSnapshot | null = this.runtime.snapshot(generation);
      if (source === null || !source.matched) {
        this.scheduleRuntimePoll(surfaceId); return;
      }
      if (source.terminal) {
        this.handleRuntimeEvent({ type: this.state.phase === 'stopping' ? 'stopped' : 'failed',
          generation: generation, sequence: this.state.lastEventSequence + 1,
          nativeError: this.state.phase === 'stopping' ? '' : 'STREAM_TIMEOUT',
          detailCode: source.code, nativeSessionId: this.nativeSessionId, surfaceId: '' });
        return;
      }
      if (source.videoReady && !this.runtimeVideoReady) {
        this.runtimeVideoReady = true;
        if (!this.emitRuntimeEvent('videoReady', generation, '', '', '')) { return; }
      }
      if (source.audioReady && !this.runtimeAudioReady) {
        this.runtimeAudioReady = true;
        if (!this.emitRuntimeEvent('audioReady', generation, '', '', '')) { return; }
      }
      if (source.inputReady && !this.runtimeInputReady) {
        this.runtimeInputReady = true;
        if (!this.emitRuntimeEvent('inputReady', generation, '', '', '')) { return; }
      }
      const current: MoonlightSessionStateSnapshot | null = this.state;
      if (source.firstFrameReady && current !== null && !current.firstFrameSeen) {
        if (!this.emitRuntimeEvent('firstFrameRendered', generation, '', '', surfaceId)) { return; }
        if (this.state !== null && this.state.firstFrameSeen &&
            this.state.videoReady && this.state.audioReady && this.state.inputReady) {
          if (!this.emitRuntimeEvent('streamStable', generation, '', '', surfaceId)) { return; }
        }
      }
      if (this.state !== null && this.state.generation === generation) {
        this.scheduleRuntimePoll(surfaceId);
      }
    }, 100);
  }

  private emitRuntimeEvent(type: MoonlightSessionEventType, generation: number,
    nativeError: string, detailCode: string, surfaceId: string): boolean {
    const current: MoonlightSessionStateSnapshot | null = this.state;
    if (current === null || current.generation !== generation) { return false; }
    const result: MoonlightCoordinatorResult = this.handleRuntimeEvent({
      type: type,
      generation: generation,
      sequence: current.lastEventSequence + 1,
      nativeError: nativeError,
      detailCode: detailCode,
      nativeSessionId: this.nativeSessionId,
      surfaceId: surfaceId
    });
    return result.accepted && this.state !== null && this.state.generation === generation;
  }

  private clearRuntimePoll(): void {
    if (this.runtimePollTimer >= 0) {
      clearTimeout(this.runtimePollTimer);
      this.runtimePollTimer = -1;
    }
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
    const subscriptions: MoonlightSessionSnapshotSubscription[] =
      this.snapshotSubscriptions.slice();
    for (let i = 0; i < subscriptions.length; i++) {
      this.notifySnapshotSubscription(subscriptions[i]);
    }
  }

  private invalidate(reason: string): void {
    this.clearRuntimePoll();
    if (this.nativeSessionId > 0) {
      if (this.runtime !== null) {
        this.runtime.stop(this.nativeSessionId, reason);
      }
    } else if (this.reservationSessionId > 0 && this.runtime !== null &&
      this.runtimeStartIssued) {
      this.runtime.cancel(this.operationGeneration, reason);
    }
    this.clearOwnedRegistry();
    this.state = null;
    this.nativeSessionId = -1;
    this.reservationSessionId = -1;
    this.reservationIdentity = null;
    this.runtimeStartIssued = false;
    this.stopDeadlineAtMs = 0;
    this.clearStopTimer();
    this.notifySnapshotSubscribers();
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

  private forceLocalTerminal(nativeError: string): void {
    this.clearRuntimePoll();
    if (this.state !== null && this.state.phase === 'stopping') {
      const terminalEvent: MoonlightSessionEvent = {
        type: 'failed', generation: this.state.generation,
        sequence: this.state.lastEventSequence + 1,
        nativeError: nativeError, detailCode: 'local_terminal'
      };
      const transition = applyMoonlightSessionEvent(this.state, terminalEvent);
      if (transition.applied) {
        this.state = transition.state;
      }
    }
    this.clearOwnedRegistry();
    this.state = null;
    this.nativeSessionId = -1;
    this.reservationSessionId = -1;
    this.reservationIdentity = null;
    this.runtimeStartIssued = false;
    this.stopDeadlineAtMs = 0;
    this.clearStopTimer();
    this.notifySnapshotSubscribers();
  }

  private expireStopIfNeeded(nowMs: number): boolean {
    if (this.state === null || this.state.phase !== 'stopping' ||
      this.stopDeadlineAtMs <= 0 || nowMs < this.stopDeadlineAtMs) {
      return false;
    }
    this.forceLocalTerminal('STOP_TIMEOUT');
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
