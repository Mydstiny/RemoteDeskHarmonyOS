/**
 * Versioned, session-scoped envelope and queue rules for the future SSH
 * WebMessagePort transport. The current xterm proxy remains the default
 * until a device-capability gate enables this policy-backed channel.
 */

export type SshWebMessageKind =
  | 'hello'
  | 'hello_ack'
  | 'ready'
  | 'output'
  | 'input'
  | 'resize'
  | 'search'
  | 'ack'
  | 'error'
  | 'close';

export type SshWebMessagePhase = 'closed' | 'opening' | 'ready';

export type SshWebMessageDecisionCode =
  | 'ok'
  | 'closed'
  | 'not_ready'
  | 'invalid_identity'
  | 'invalid_message'
  | 'unsupported_version'
  | 'stale_generation'
  | 'stale_sequence'
  | 'duplicate_sequence'
  | 'out_of_order_sequence'
  | 'queue_full'
  | 'frame_too_large'
  | 'in_flight_full';

export interface SshWebMessageEnvelopeV1 {
  version: number;
  kind: SshWebMessageKind;
  sessionKey: string;
  generation: number;
  sequence: number;
  ackSequence: number;
  payload: string;
}

export interface SshWebMessageQueueItemV1 {
  envelope: SshWebMessageEnvelopeV1;
  bytes: number;
}

export interface SshWebMessageStateV1 {
  phase: SshWebMessagePhase;
  sessionKey: string;
  generation: number;
  nextSequence: number;
  lastReceivedSequence: number;
  lastAckedSequence: number;
  bufferedBytes: number;
  queue: Array<SshWebMessageQueueItemV1>;
  inFlight: Array<number>;
}

export interface SshWebMessageEnqueueResultV1 {
  accepted: boolean;
  code: SshWebMessageDecisionCode;
  state: SshWebMessageStateV1;
  envelope: SshWebMessageEnvelopeV1 | null;
}

export interface SshWebMessageReceiveResultV1 {
  accepted: boolean;
  code: SshWebMessageDecisionCode;
  state: SshWebMessageStateV1;
  envelope: SshWebMessageEnvelopeV1 | null;
}

export interface SshWebMessageDequeueResultV1 {
  state: SshWebMessageStateV1;
  envelope: SshWebMessageEnvelopeV1 | null;
}

export const SSH_WEB_MESSAGE_VERSION: number = 1;
export const SSH_WEB_MESSAGE_MAX_FRAME_CHARS: number = 65536;
export const SSH_WEB_MESSAGE_MAX_FRAME_BYTES: number = 64 * 1024;
export const SSH_WEB_MESSAGE_MAX_QUEUE_BYTES: number = 1024 * 1024;
export const SSH_WEB_MESSAGE_MAX_QUEUE_ITEMS: number = 64;
export const SSH_WEB_MESSAGE_MAX_IN_FLIGHT: number = 8;

function cloneState(state: SshWebMessageStateV1): SshWebMessageStateV1 {
  const queue: Array<SshWebMessageQueueItemV1> = [];
  for (let index: number = 0; index < state.queue.length; index++) {
    const item: SshWebMessageQueueItemV1 = state.queue[index];
    queue.push({
      envelope: {
        version: item.envelope.version,
        kind: item.envelope.kind,
        sessionKey: item.envelope.sessionKey,
        generation: item.envelope.generation,
        sequence: item.envelope.sequence,
        ackSequence: item.envelope.ackSequence,
        payload: item.envelope.payload
      },
      bytes: item.bytes
    });
  }
  return {
    phase: state.phase,
    sessionKey: state.sessionKey,
    generation: state.generation,
    nextSequence: state.nextSequence,
    lastReceivedSequence: state.lastReceivedSequence,
    lastAckedSequence: state.lastAckedSequence,
    bufferedBytes: state.bufferedBytes,
    queue,
    inFlight: state.inFlight.slice()
  };
}

function validIdentity(sessionKey: string, generation: number): boolean {
  return sessionKey.trim().length > 0 && Number.isFinite(generation) &&
    Math.floor(generation) === generation && generation > 0;
}

function validSequence(sequence: number): boolean {
  return Number.isFinite(sequence) && Math.floor(sequence) === sequence && sequence > 0;
}

function validAckSequence(sequence: number): boolean {
  return Number.isFinite(sequence) && Math.floor(sequence) === sequence && sequence >= 0;
}

function allowedKind(kind: string): boolean {
  switch (kind) {
    case 'hello':
    case 'hello_ack':
    case 'ready':
    case 'output':
    case 'input':
    case 'resize':
    case 'search':
    case 'ack':
    case 'error':
    case 'close':
      return true;
    default:
      return false;
  }
}

function isControlKind(kind: SshWebMessageKind): boolean {
  return kind !== 'output' && kind !== 'input';
}

function envelopeBytes(envelope: SshWebMessageEnvelopeV1): number {
  return sshUtf8ByteLength(envelope.payload);
}

/**
 * Queue limits are byte budgets, not UTF-16 code-unit budgets.  ArkTS API 23
 * does not expose TextEncoder in the application runtime, so keep this small
 * deterministic counter local to the transport policy.  A surrogate pair is
 * counted as one UTF-8 scalar (four bytes); an unpaired surrogate is encoded
 * as the replacement-width three bytes, matching JSON/WebView replacement
 * behavior rather than allowing a cheap queue-budget bypass.
 */
export function sshUtf8ByteLength(value: string): number {
  let bytes: number = 0;
  for (let index: number = 0; index < value.length; index++) {
    const code: number = value.charCodeAt(index);
    if (code <= 0x7f) {
      bytes += 1;
    } else if (code <= 0x7ff) {
      bytes += 2;
    } else if (code >= 0xd800 && code <= 0xdbff && index + 1 < value.length) {
      const next: number = value.charCodeAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        bytes += 4;
        index++;
      } else {
        bytes += 3;
      }
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

function makeEnvelope(state: SshWebMessageStateV1, kind: SshWebMessageKind,
  payload: string, sequence: number): SshWebMessageEnvelopeV1 {
  return {
    version: SSH_WEB_MESSAGE_VERSION,
    kind,
    sessionKey: state.sessionKey,
    generation: state.generation,
    sequence,
    ackSequence: state.lastReceivedSequence,
    payload
  };
}

function result(state: SshWebMessageStateV1, code: SshWebMessageDecisionCode,
  envelope: SshWebMessageEnvelopeV1 | null = null): SshWebMessageEnqueueResultV1 {
  return { accepted: code === 'ok', code, state, envelope };
}

export function createSshWebMessageState(sessionKey: string,
  generation: number): SshWebMessageStateV1 {
  return {
    phase: validIdentity(sessionKey, generation) ? 'closed' : 'closed',
    sessionKey: sessionKey.trim(),
    generation: Number.isFinite(generation) && Math.floor(generation) === generation
      ? generation : 0,
    nextSequence: 1,
    lastReceivedSequence: 0,
    lastAckedSequence: 0,
    bufferedBytes: 0,
    queue: [],
    inFlight: []
  };
}

export function startSshWebMessageHandshake(state: SshWebMessageStateV1):
  SshWebMessageEnqueueResultV1 {
  const next: SshWebMessageStateV1 = cloneState(state);
  if (!validIdentity(next.sessionKey, next.generation)) {
    return result(next, 'invalid_identity');
  }
  if (next.phase !== 'closed') { return result(next, 'not_ready'); }
  next.phase = 'opening';
  const envelope: SshWebMessageEnvelopeV1 = makeEnvelope(next, 'hello', '', next.nextSequence);
  next.nextSequence++;
  next.queue.push({ envelope, bytes: envelopeBytes(envelope) });
  next.bufferedBytes += envelopeBytes(envelope);
  return result(next, 'ok', envelope);
}

export function markSshWebMessageClosed(state: SshWebMessageStateV1): SshWebMessageStateV1 {
  const next: SshWebMessageStateV1 = cloneState(state);
  next.phase = 'closed';
  next.queue = [];
  next.inFlight = [];
  next.bufferedBytes = 0;
  return next;
}

export function enqueueSshWebMessage(state: SshWebMessageStateV1,
  kind: SshWebMessageKind, payload: string): SshWebMessageEnqueueResultV1 {
  const next: SshWebMessageStateV1 = cloneState(state);
  if (!validIdentity(next.sessionKey, next.generation)) {
    return result(next, 'invalid_identity');
  }
  if (!allowedKind(kind) || typeof payload !== 'string') {
    return result(next, 'invalid_message');
  }
  if (next.phase !== 'ready' && kind !== 'hello' && kind !== 'hello_ack') {
    return result(next, 'not_ready');
  }
  if (!validSequence(next.nextSequence)) { return result(next, 'invalid_message'); }
  const payloadBytes: number = sshUtf8ByteLength(payload);
  if (payload.length > SSH_WEB_MESSAGE_MAX_FRAME_CHARS ||
    payloadBytes > SSH_WEB_MESSAGE_MAX_FRAME_BYTES) {
    return result(next, 'frame_too_large');
  }
  if (next.queue.length >= SSH_WEB_MESSAGE_MAX_QUEUE_ITEMS ||
    next.bufferedBytes + payloadBytes > SSH_WEB_MESSAGE_MAX_QUEUE_BYTES) {
    return result(next, 'queue_full');
  }
  // Allocate the wire sequence when dequeued. This preserves monotonic wire
  // order while allowing control frames to jump ahead of queued output.
  const envelope: SshWebMessageEnvelopeV1 = makeEnvelope(next, kind, payload, 0);
  next.queue.push({ envelope, bytes: payloadBytes });
  next.bufferedBytes += payloadBytes;
  return result(next, 'ok', envelope);
}

export function dequeueSshWebMessage(state: SshWebMessageStateV1): SshWebMessageDequeueResultV1 {
  const next: SshWebMessageStateV1 = cloneState(state);
  if (next.inFlight.length >= SSH_WEB_MESSAGE_MAX_IN_FLIGHT) {
    return { state: next, envelope: null };
  }
  let selectedIndex: number = -1;
  for (let index: number = 0; index < next.queue.length; index++) {
    const sequence: number = next.queue[index].envelope.sequence;
    if (next.inFlight.indexOf(sequence) >= 0) { continue; }
    if (selectedIndex < 0 || isControlKind(next.queue[index].envelope.kind)) {
      selectedIndex = index;
      if (isControlKind(next.queue[index].envelope.kind)) { break; }
    }
  }
  if (selectedIndex < 0) { return { state: next, envelope: null }; }
  const item: SshWebMessageQueueItemV1 = next.queue[selectedIndex];
  let envelope: SshWebMessageEnvelopeV1 = item.envelope;
  if (envelope.sequence === 0) {
    if (!validSequence(next.nextSequence)) {
      return { state: next, envelope: null };
    }
    envelope = {
      version: envelope.version,
      kind: envelope.kind,
      sessionKey: envelope.sessionKey,
      generation: envelope.generation,
      sequence: next.nextSequence,
      ackSequence: next.lastReceivedSequence,
      payload: envelope.payload
    };
    next.nextSequence++;
    next.queue[selectedIndex] = { envelope, bytes: item.bytes };
  }
  next.inFlight.push(envelope.sequence);
  return { state: next, envelope };
}

export function acknowledgeSshWebMessage(state: SshWebMessageStateV1,
  sequence: number): SshWebMessageStateV1 {
  const next: SshWebMessageStateV1 = cloneState(state);
  if (!validSequence(sequence) || sequence <= next.lastAckedSequence ||
    sequence >= next.nextSequence) { return next; }
  next.lastAckedSequence = sequence;
  const retained: Array<SshWebMessageQueueItemV1> = [];
  let removedBytes: number = 0;
  for (let index: number = 0; index < next.queue.length; index++) {
    const item: SshWebMessageQueueItemV1 = next.queue[index];
    if (item.envelope.sequence > 0 && item.envelope.sequence <= sequence) {
      removedBytes += item.bytes;
    } else {
      retained.push(item);
    }
  }
  next.queue = retained;
  next.bufferedBytes = Math.max(0, next.bufferedBytes - removedBytes);
  const retainedInFlight: Array<number> = [];
  for (let index: number = 0; index < next.inFlight.length; index++) {
    if (next.inFlight[index] > sequence) { retainedInFlight.push(next.inFlight[index]); }
  }
  next.inFlight = retainedInFlight;
  return next;
}

export function acceptSshWebMessage(state: SshWebMessageStateV1,
  envelope: SshWebMessageEnvelopeV1): SshWebMessageReceiveResultV1 {
  const next: SshWebMessageStateV1 = cloneState(state);
  if (typeof envelope.sessionKey !== 'string' || typeof envelope.generation !== 'number' ||
    typeof envelope.sequence !== 'number' || typeof envelope.ackSequence !== 'number' ||
    typeof envelope.payload !== 'string' || typeof envelope.kind !== 'string' ||
    typeof envelope.version !== 'number') {
    return { accepted: false, code: 'invalid_message', state: next, envelope: null };
  }
  if (!validIdentity(next.sessionKey, next.generation) ||
    envelope.sessionKey.trim() !== next.sessionKey || envelope.generation !== next.generation) {
    return { accepted: false, code: 'stale_generation', state: next, envelope: null };
  }
  if (envelope.version !== SSH_WEB_MESSAGE_VERSION) {
    return { accepted: false, code: 'unsupported_version', state: next, envelope: null };
  }
  if (!allowedKind(envelope.kind) || !validSequence(envelope.sequence) ||
    !validAckSequence(envelope.ackSequence)) {
    return { accepted: false, code: 'invalid_message', state: next, envelope: null };
  }
  if (envelope.payload.length > SSH_WEB_MESSAGE_MAX_FRAME_CHARS ||
    sshUtf8ByteLength(envelope.payload) > SSH_WEB_MESSAGE_MAX_FRAME_BYTES) {
    return { accepted: false, code: 'frame_too_large', state: next, envelope: null };
  }
  if (envelope.ackSequence >= next.nextSequence) {
    return { accepted: false, code: 'invalid_message', state: next, envelope: null };
  }
  if (envelope.sequence <= next.lastReceivedSequence) {
    const duplicateCode: SshWebMessageDecisionCode = envelope.sequence === next.lastReceivedSequence
      ? 'duplicate_sequence' : 'stale_sequence';
    return { accepted: false, code: duplicateCode, state: next, envelope: null };
  }
  if (envelope.sequence !== next.lastReceivedSequence + 1) {
    return { accepted: false, code: 'out_of_order_sequence', state: next, envelope: null };
  }
  if (envelope.kind !== 'hello_ack' && envelope.kind !== 'hello' &&
    envelope.kind !== 'close' && next.phase !== 'ready') {
    return { accepted: false, code: 'not_ready', state: next, envelope: null };
  }
  if (envelope.ackSequence > 0) {
    const acked: SshWebMessageStateV1 = acknowledgeSshWebMessage(next, envelope.ackSequence);
    next.queue = acked.queue;
    next.inFlight = acked.inFlight;
    next.bufferedBytes = acked.bufferedBytes;
    next.lastAckedSequence = acked.lastAckedSequence;
  }
  next.lastReceivedSequence = envelope.sequence;
  if (envelope.kind === 'hello_ack' && next.phase === 'opening') {
    next.phase = 'ready';
  } else if (envelope.kind === 'close') {
    next.phase = 'closed';
  }
  return { accepted: true, code: 'ok', state: next, envelope };
}

export function encodeSshWebMessage(envelope: SshWebMessageEnvelopeV1): string {
  return JSON.stringify({
    version: envelope.version,
    kind: envelope.kind,
    sessionKey: envelope.sessionKey,
    generation: envelope.generation,
    sequence: envelope.sequence,
    ackSequence: envelope.ackSequence,
    payload: envelope.payload
  });
}

export function decodeSshWebMessage(encoded: string): SshWebMessageEnvelopeV1 | null {
  if (encoded.length === 0 || encoded.length > SSH_WEB_MESSAGE_MAX_FRAME_CHARS * 2) {
    return null;
  }
  try {
    const parsed: Object = JSON.parse(encoded) as Object;
    const source: Record<string, Object> = parsed as Record<string, Object>;
    if (typeof source['version'] !== 'number' || typeof source['kind'] !== 'string' ||
      typeof source['sessionKey'] !== 'string' || typeof source['generation'] !== 'number' ||
      typeof source['sequence'] !== 'number' || typeof source['ackSequence'] !== 'number' ||
      typeof source['payload'] !== 'string') {
      return null;
    }
    const version: number = source['version'] as number;
    const kind: string = source['kind'] as string;
    const sessionKey: string = (source['sessionKey'] as string).trim();
    const generation: number = source['generation'] as number;
    const sequence: number = source['sequence'] as number;
    const ackSequence: number = source['ackSequence'] as number;
    const payload: string = source['payload'] as string;
    if (version !== SSH_WEB_MESSAGE_VERSION || !Number.isFinite(version) || !allowedKind(kind) ||
      !validIdentity(sessionKey, generation) || !validSequence(sequence) ||
      !validAckSequence(ackSequence) || payload.length > SSH_WEB_MESSAGE_MAX_FRAME_CHARS ||
      sshUtf8ByteLength(payload) > SSH_WEB_MESSAGE_MAX_FRAME_BYTES) {
      return null;
    }
    return { version, kind: kind as SshWebMessageKind, sessionKey, generation, sequence, ackSequence, payload };
  } catch (_err) {
    return null;
  }
}
