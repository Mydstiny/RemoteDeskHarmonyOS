/** Pure Moonlight control/media lifecycle. It owns no native handles or secrets. */

export type MoonlightSessionPhase =
  'disconnected' | 'discovering' | 'verifying' | 'pairing' | 'catalog' |
  'launching' | 'negotiating' | 'video' | 'audio' | 'input' | 'firstFrame' |
  'streaming' | 'reconnecting' | 'stopping' | 'failed';

export type MoonlightSessionEventType =
  'beginDiscovery' | 'beginVerification' | 'pairingRequired' | 'pairingAccepted' |
  'catalogReady' | 'launchRequested' | 'launchAccepted' | 'videoReady' |
  'audioReady' | 'inputReady' | 'firstFrameRendered' | 'streamStable' |
  'transportLost' | 'reconnectNegotiating' | 'stopRequested' | 'stopped' |
  'failed' | 'cancelled' | 'capabilityDegraded';

export type MoonlightSessionErrorCode =
  'none' | 'cancelled' | 'network_unreachable' | 'host_not_found' |
  'tls_failed' | 'certificate_changed' | 'pairing_pin_rejected' |
  'pairing_timeout' | 'host_busy' | 'app_not_found' | 'codec_unsupported' |
  'decoder_failed' | 'audio_failed' | 'input_failed' | 'stream_timeout' |
  'owner_changed' | 'internal';

export type MoonlightSessionTransitionReason =
  'applied' | 'stale_generation' | 'stale_sequence' | 'invalid_transition' |
  'video_not_ready' | 'media_not_ready' | 'already_terminal';

export interface MoonlightSessionStateSnapshot {
  sessionId: string;
  ownerScopeId: string;
  hostId: string;
  appId: string;
  generation: number;
  phase: MoonlightSessionPhase;
  lastEventSequence: number;
  videoReady: boolean;
  audioReady: boolean;
  inputReady: boolean;
  firstFrameSeen: boolean;
  reconnectAttempt: number;
  errorCode: MoonlightSessionErrorCode;
  degradationReasons: string[];
}

export interface MoonlightSessionEvent {
  type: MoonlightSessionEventType;
  generation: number;
  sequence: number;
  nativeError: string;
  detailCode: string;
}

export interface MoonlightSessionTransitionResult {
  applied: boolean;
  reason: MoonlightSessionTransitionReason;
  state: MoonlightSessionStateSnapshot;
}

function boundedText(value: string, maximum: number): boolean {
  return typeof value === 'string' && value.length > 0 && value.length <= maximum;
}

function validCounter(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

export function createMoonlightSessionState(sessionId: string, ownerScopeId: string,
  hostId: string, appId: string, generation: number): MoonlightSessionStateSnapshot | null {
  if (!boundedText(sessionId, 128) || !boundedText(ownerScopeId, 128) ||
      !boundedText(hostId, 128) || !boundedText(appId, 128) || !validCounter(generation)) {
    return null;
  }
  return {
    sessionId: sessionId,
    ownerScopeId: ownerScopeId,
    hostId: hostId,
    appId: appId,
    generation: generation,
    phase: 'disconnected',
    lastEventSequence: 0,
    videoReady: false,
    audioReady: false,
    inputReady: false,
    firstFrameSeen: false,
    reconnectAttempt: 0,
    errorCode: 'none',
    degradationReasons: []
  };
}

/**
 * Starts a new callback generation after the previous native connection has
 * reached a terminal receipt.  Reconnect deliberately keeps the logical route
 * and degradation history while clearing every media/input readiness bit.  A
 * late event from the retired common-c invocation therefore fails the normal
 * generation fence instead of being compared only by sequence number.
 */
export function rebaseMoonlightSessionForReconnect(
  source: MoonlightSessionStateSnapshot,
  sessionId: string,
  generation: number
): MoonlightSessionStateSnapshot | null {
  if (source.phase !== 'reconnecting' || !boundedText(sessionId, 128) ||
      !validCounter(generation) || generation <= source.generation) {
    return null;
  }
  return {
    sessionId: sessionId,
    ownerScopeId: source.ownerScopeId,
    hostId: source.hostId,
    appId: source.appId,
    generation: generation,
    phase: 'reconnecting',
    lastEventSequence: 0,
    videoReady: false,
    audioReady: false,
    inputReady: false,
    firstFrameSeen: false,
    reconnectAttempt: source.reconnectAttempt,
    errorCode: 'none',
    degradationReasons: source.degradationReasons.slice()
  };
}

function cloneState(source: MoonlightSessionStateSnapshot): MoonlightSessionStateSnapshot {
  return {
    sessionId: source.sessionId,
    ownerScopeId: source.ownerScopeId,
    hostId: source.hostId,
    appId: source.appId,
    generation: source.generation,
    phase: source.phase,
    lastEventSequence: source.lastEventSequence,
    videoReady: source.videoReady,
    audioReady: source.audioReady,
    inputReady: source.inputReady,
    firstFrameSeen: source.firstFrameSeen,
    reconnectAttempt: source.reconnectAttempt,
    errorCode: source.errorCode,
    degradationReasons: source.degradationReasons.slice()
  };
}

function result(applied: boolean, reason: MoonlightSessionTransitionReason,
  state: MoonlightSessionStateSnapshot): MoonlightSessionTransitionResult {
  return { applied: applied, reason: reason, state: state };
}

export function moonlightSessionTransitionIsAllowed(
  from: MoonlightSessionPhase, to: MoonlightSessionPhase
): boolean {
  if (from === to && (to === 'video' || to === 'audio' || to === 'input')) { return true; }
  if (to === 'stopping' && from !== 'disconnected') { return true; }
  if (to === 'failed' && from !== 'disconnected') { return true; }
  if (from === 'disconnected') { return to === 'discovering' || to === 'verifying'; }
  if (from === 'discovering') {
    return to === 'verifying' || to === 'pairing';
  }
  if (from === 'verifying') { return to === 'pairing' || to === 'catalog'; }
  if (from === 'pairing') { return to === 'verifying' || to === 'catalog'; }
  if (from === 'catalog') { return to === 'launching'; }
  if (from === 'launching') {
    return to === 'negotiating' || to === 'reconnecting';
  }
  if (from === 'negotiating') {
    return to === 'video' || to === 'audio' || to === 'input' || to === 'reconnecting';
  }
  if (from === 'video' || from === 'audio' || from === 'input') {
    return to === 'video' || to === 'audio' || to === 'input' || to === 'firstFrame' ||
      to === 'streaming' || to === 'reconnecting';
  }
  if (from === 'firstFrame') {
    return to === 'video' || to === 'audio' || to === 'input' ||
      to === 'streaming' || to === 'reconnecting';
  }
  if (from === 'streaming') { return to === 'reconnecting'; }
  if (from === 'reconnecting') {
    return to === 'verifying' || to === 'negotiating' || to === 'video' || to === 'audio' ||
      to === 'input' || to === 'firstFrame' || to === 'streaming';
  }
  if (from === 'stopping') { return to === 'disconnected'; }
  return from === 'failed' && (to === 'disconnected' || to === 'discovering' || to === 'verifying');
}

export function moonlightSessionErrorFromNative(nativeError: string): MoonlightSessionErrorCode {
  const normalized: string = nativeError.trim().toUpperCase();
  if (normalized === '' || normalized === 'NONE') { return 'none'; }
  if (normalized === 'CANCELLED' || normalized === 'ECANCELED') { return 'cancelled'; }
  if (normalized === 'NETWORK_UNREACHABLE' || normalized === 'ENETUNREACH') {
    return 'network_unreachable';
  }
  if (normalized === 'HOST_NOT_FOUND' || normalized === 'DNS_FAILED') { return 'host_not_found'; }
  if (normalized === 'TLS_FAILED' || normalized === 'CERTIFICATE_INVALID') { return 'tls_failed'; }
  if (normalized === 'CERTIFICATE_CHANGED' || normalized === 'TRUST_CONFLICT') {
    return 'certificate_changed';
  }
  if (normalized === 'PIN_REJECTED') { return 'pairing_pin_rejected'; }
  if (normalized === 'PAIRING_TIMEOUT') { return 'pairing_timeout'; }
  if (normalized === 'HOST_BUSY') { return 'host_busy'; }
  if (normalized === 'APP_NOT_FOUND') { return 'app_not_found'; }
  if (normalized === 'CODEC_UNSUPPORTED') { return 'codec_unsupported'; }
  if (normalized === 'DECODER_FAILED') { return 'decoder_failed'; }
  if (normalized === 'AUDIO_FAILED') { return 'audio_failed'; }
  if (normalized === 'INPUT_FAILED') { return 'input_failed'; }
  if (normalized === 'STREAM_TIMEOUT' || normalized === 'FIRST_FRAME_TIMEOUT') {
    return 'stream_timeout';
  }
  if (normalized === 'OWNER_CHANGED' || normalized === 'STALE_OWNER') { return 'owner_changed'; }
  return 'internal';
}

function phaseForEvent(type: MoonlightSessionEventType): MoonlightSessionPhase | null {
  if (type === 'beginDiscovery') { return 'discovering'; }
  if (type === 'beginVerification') { return 'verifying'; }
  if (type === 'pairingRequired') { return 'pairing'; }
  if (type === 'pairingAccepted' || type === 'catalogReady') { return 'catalog'; }
  if (type === 'launchRequested') { return 'launching'; }
  if (type === 'launchAccepted' || type === 'reconnectNegotiating') { return 'negotiating'; }
  if (type === 'videoReady') { return 'video'; }
  if (type === 'audioReady') { return 'audio'; }
  if (type === 'inputReady') { return 'input'; }
  if (type === 'firstFrameRendered') { return 'firstFrame'; }
  if (type === 'streamStable') { return 'streaming'; }
  if (type === 'transportLost') { return 'reconnecting'; }
  if (type === 'stopRequested' || type === 'cancelled') { return 'stopping'; }
  if (type === 'stopped') { return 'disconnected'; }
  if (type === 'failed') { return 'failed'; }
  return null;
}

export function applyMoonlightSessionEvent(state: MoonlightSessionStateSnapshot,
  event: MoonlightSessionEvent): MoonlightSessionTransitionResult {
  const next: MoonlightSessionStateSnapshot = cloneState(state);
  if (event.generation !== state.generation) {
    return result(false, 'stale_generation', next);
  }
  if (!validCounter(event.sequence) || event.sequence <= state.lastEventSequence) {
    return result(false, 'stale_sequence', next);
  }
  if (event.type === 'capabilityDegraded') {
    if (!boundedText(event.detailCode, 128) || state.phase === 'disconnected' ||
        state.phase === 'stopping' || state.phase === 'failed') {
      return result(false, 'invalid_transition', next);
    }
    if (next.degradationReasons.indexOf(event.detailCode) < 0) {
      next.degradationReasons.push(event.detailCode);
    }
    next.lastEventSequence = event.sequence;
    return result(true, 'applied', next);
  }
  const target: MoonlightSessionPhase | null = phaseForEvent(event.type);
  if (target === null) { return result(false, 'invalid_transition', next); }
  if (state.phase === 'disconnected' &&
      (event.type === 'cancelled' || event.type === 'stopped')) {
    return result(false, 'already_terminal', next);
  }
  if (!moonlightSessionTransitionIsAllowed(state.phase, target)) {
    return result(false, 'invalid_transition', next);
  }
  if (event.type === 'firstFrameRendered' && !state.videoReady) {
    return result(false, 'video_not_ready', next);
  }
  if (event.type === 'streamStable' &&
      (!state.videoReady || !state.audioReady || !state.inputReady || !state.firstFrameSeen)) {
    return result(false, 'media_not_ready', next);
  }
  next.phase = target;
  next.lastEventSequence = event.sequence;
  if (event.type === 'videoReady') { next.videoReady = true; }
  if (event.type === 'audioReady') { next.audioReady = true; }
  if (event.type === 'inputReady') { next.inputReady = true; }
  if (event.type === 'firstFrameRendered') { next.firstFrameSeen = true; }
  if (event.type === 'transportLost') {
    next.reconnectAttempt += 1;
    next.videoReady = false;
    next.audioReady = false;
    next.inputReady = false;
    next.firstFrameSeen = false;
  }
  if (event.type === 'failed') { next.errorCode = moonlightSessionErrorFromNative(event.nativeError); }
  if (event.type === 'cancelled') { next.errorCode = 'cancelled'; }
  if (event.type === 'stopped') {
    next.errorCode = state.errorCode;
    next.videoReady = false;
    next.audioReady = false;
    next.inputReady = false;
    next.firstFrameSeen = false;
  }
  return result(true, 'applied', next);
}
