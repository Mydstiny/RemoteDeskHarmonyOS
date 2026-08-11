/**
 * MoonlightSessionCoordinator.ets — the single dormant Moonlight session seam.
 *
 * This coordinator owns no sockets, native handles, media queues, secrets or
 * cloud state. A real common-c/native implementation must be injected through
 * MoonlightRuntimePort later. With no port, start is rejected before the
 * shared ActiveRemoteSessionRegistry is touched.
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
}

export interface MoonlightRuntimePort {
  start(request: MoonlightSessionStartRequest, operationGeneration: number): boolean;
  cancel(operationGeneration: number, reason: string): boolean;
  stop(nativeSessionId: number, reason: string): boolean;
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

export type MoonlightCoordinatorResultCode =
  'started' | 'runtime_unavailable' | 'invalid_request' | 'active_session_busy' |
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
  private operationGeneration: number = 0;
  private boundOwnerScopeId: string = '';
  private boundAccountGeneration: number = 0;
  private stopDeadlineAtMs: number = 0;
  private stopTimer: number = -1;

  constructor(runtime: MoonlightRuntimePort | null = null,
    registry: ActiveRemoteSessionRegistry = ActiveRemoteSessionRegistry.getInstance()) {
    this.runtime = runtime;
    this.registry = registry;
  }

  static getInstance(): MoonlightSessionCoordinator {
    if (MoonlightSessionCoordinator.instance === null) {
      MoonlightSessionCoordinator.instance = new MoonlightSessionCoordinator();
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

  start(request: MoonlightSessionStartRequest): MoonlightCoordinatorResult {
    this.expireStopIfNeeded(Date.now());
    if (!this.validRequest(request)) {
      return this.result(false, 'invalid_request');
    }
    if (!request.runtimeAvailable || !request.hostControlReady ||
      !request.streamingTransportReady || this.runtime === null) {
      return this.result(false, 'runtime_unavailable');
    }
    if (!terminal(this.state)) {
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
    this.state = firstTransition.state;
    const started: boolean = this.runtime.start(request, this.operationGeneration);
    if (!started) {
      const failedEvent: MoonlightSessionEvent = {
        type: 'failed', generation: this.operationGeneration, sequence: 2,
        nativeError: 'RUNTIME_START_FAILED', detailCode: ''
      };
      const failed = applyMoonlightSessionEvent(this.state, failedEvent);
      this.state = failed.applied ? failed.state : this.state;
      this.clearOwnedRegistry();
      this.reservationSessionId = -1;
      return this.result(false, 'runtime_start_failed');
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
      this.stopDeadlineAtMs = 0;
    }
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
    if (!this.requestRuntimeStop(reason)) {
      this.forceLocalTerminal('STOP_FAILED');
      return this.result(false, 'stop_failed');
    }
    this.stopDeadlineAtMs = Date.now() + 5000;
    this.scheduleStopTimer();
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
    if (!this.requestRuntimeStop(reason)) {
      this.forceLocalTerminal('STOP_FAILED');
      return this.result(false, 'stop_failed');
    }
    this.stopDeadlineAtMs = Date.now() + 5000;
    this.scheduleStopTimer();
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

  resetForTest(): void {
    this.invalidate('test-reset');
    this.state = null;
    this.nativeSessionId = -1;
    this.reservationSessionId = -1;
    this.stopDeadlineAtMs = 0;
  }

  expireStop(nowMs: number = Date.now()): MoonlightCoordinatorResult {
    if (this.expireStopIfNeeded(nowMs)) {
      return this.result(false, 'stop_timeout');
    }
    return this.result(false, 'not_active');
  }

  private validRequest(request: MoonlightSessionStartRequest): boolean {
    return boundedText(request.ownerScopeId, 128) && validGeneration(request.accountGeneration) &&
      boundedText(request.hostId, 128) && boundedText(request.appId, 128) &&
      boundedText(request.hostAddress, 255);
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

  private invalidate(reason: string): void {
    if (this.nativeSessionId > 0) {
      if (this.runtime !== null) {
        this.runtime.stop(this.nativeSessionId, reason);
      }
    } else if (this.reservationSessionId > 0 && this.runtime !== null) {
      this.runtime.cancel(this.operationGeneration, reason);
    }
    this.clearOwnedRegistry();
    this.state = null;
    this.nativeSessionId = -1;
    this.reservationSessionId = -1;
    this.stopDeadlineAtMs = 0;
    this.clearStopTimer();
  }

  private requestRuntimeStop(reason: string): boolean {
    if (this.runtime === null) {
      return false;
    }
    if (this.nativeSessionId > 0) {
      return this.runtime.stop(this.nativeSessionId, reason);
    }
    if (this.reservationSessionId > 0) {
      return this.runtime.cancel(this.operationGeneration, reason);
    }
    return true;
  }

  private forceLocalTerminal(nativeError: string): void {
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
    this.stopDeadlineAtMs = 0;
    this.clearStopTimer();
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
