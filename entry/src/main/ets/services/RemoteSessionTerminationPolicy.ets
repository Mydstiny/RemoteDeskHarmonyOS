import { ActiveRemoteSessionRecord } from './ActiveRemoteSessionRegistry';

/** Only native Complete(3) proves that every teardown stage succeeded. */
export function nativeDisconnectStateIsSuccessful(state: number): boolean {
  return state === 3;
}

/** Native Failed(4) is terminal but keeps the owning registry fail closed. */
export function nativeDisconnectStateIsFailed(state: number): boolean {
  return state === 4;
}

export interface RemoteSessionNativeDisconnectOwner {
  sessionId: number;
  generation: number;
  ownerToken: number;
  facadeGeneration: number;
}

/** Immutable native/facade owner carried by delayed UI teardown callbacks. */
export interface RemoteSessionExactDisconnectIdentity extends
  RemoteSessionNativeDisconnectOwner {
  rendererHandle: number;
  decoderHandle: number;
  audioPlayerHandle: number;
}

export interface RemoteSessionExactDisconnectSubmission {
  accepted: boolean;
  requestId: number;
  terminal: boolean;
  successful: boolean;
  retryable: boolean;
}

export interface RemoteSessionExactDisconnectRetryPort {
  submit(identity: RemoteSessionExactDisconnectIdentity):
    RemoteSessionExactDisconnectSubmission;
  observe(identity: RemoteSessionExactDisconnectIdentity,
    submission: RemoteSessionExactDisconnectSubmission): void;
  schedule(task: () => void, delayMs: number): void;
}

/** ArkTS-safe named adapter; object-literal structural ports are forbidden. */
export class RemoteSessionExactDisconnectCallbackPort implements
  RemoteSessionExactDisconnectRetryPort {
  private submitter: (identity: RemoteSessionExactDisconnectIdentity) =>
    RemoteSessionExactDisconnectSubmission;
  private observer: (identity: RemoteSessionExactDisconnectIdentity,
    submission: RemoteSessionExactDisconnectSubmission) => void;
  private scheduler: (task: () => void, delayMs: number) => void;

  constructor(
    submitter: (identity: RemoteSessionExactDisconnectIdentity) =>
      RemoteSessionExactDisconnectSubmission,
    observer: (identity: RemoteSessionExactDisconnectIdentity,
      submission: RemoteSessionExactDisconnectSubmission) => void,
    scheduler: (task: () => void, delayMs: number) => void
  ) {
    this.submitter = submitter;
    this.observer = observer;
    this.scheduler = scheduler;
  }

  submit(identity: RemoteSessionExactDisconnectIdentity):
    RemoteSessionExactDisconnectSubmission {
    return this.submitter(identity);
  }

  observe(identity: RemoteSessionExactDisconnectIdentity,
    submission: RemoteSessionExactDisconnectSubmission): void {
    this.observer(identity, submission);
  }

  schedule(task: () => void, delayMs: number): void {
    this.scheduler(task, delayMs);
  }
}

export function remoteSessionExactDisconnectIdentityEquals(
  first: RemoteSessionExactDisconnectIdentity | null,
  second: RemoteSessionExactDisconnectIdentity | null
): boolean {
  return first !== null && second !== null &&
    first.sessionId === second.sessionId &&
    first.generation === second.generation &&
    first.ownerToken === second.ownerToken &&
    first.facadeGeneration === second.facadeGeneration &&
    first.rendererHandle === second.rendererHandle &&
    first.decoderHandle === second.decoderHandle &&
    first.audioPlayerHandle === second.audioPlayerHandle;
}

function cloneRemoteSessionExactDisconnectIdentity(
  identity: RemoteSessionExactDisconnectIdentity
): RemoteSessionExactDisconnectIdentity {
  return {
    sessionId: identity.sessionId,
    generation: identity.generation,
    ownerToken: identity.ownerToken,
    facadeGeneration: identity.facadeGeneration,
    rendererHandle: identity.rendererHandle,
    decoderHandle: identity.decoderHandle,
    audioPlayerHandle: identity.audioPlayerHandle
  };
}

function submitRemoteSessionExactDisconnectAttempt(
  identity: RemoteSessionExactDisconnectIdentity,
  port: RemoteSessionExactDisconnectRetryPort,
  attemptsRemaining: number,
  retryDelayMs: number
): void {
  let submission: RemoteSessionExactDisconnectSubmission;
  try {
    submission = port.submit(identity);
  } catch (_err) {
    // A NAPI boundary throw has not accepted teardown ownership. Retry only
    // this immutable identity; never recapture the facade from a later session.
    submission = {
      accepted: false,
      requestId: 0,
      terminal: false,
      successful: false,
      retryable: true
    };
  }
  port.observe(identity, submission);
  if (!submission.accepted && submission.retryable && attemptsRemaining > 0) {
    port.schedule((): void => {
      submitRemoteSessionExactDisconnectAttempt(
        identity, port, attemptsRemaining - 1, retryDelayMs);
    }, retryDelayMs);
  }
}

/**
 * Submit/retry teardown for the captured owner only. The identity is cloned
 * once before the first attempt so Sheet callbacks cannot later mutate it or
 * recapture whichever session currently owns the process facade.
 */
export function submitRemoteSessionExactDisconnectWithRetry(
  identity: RemoteSessionExactDisconnectIdentity,
  port: RemoteSessionExactDisconnectRetryPort,
  attemptsRemaining: number = 40,
  retryDelayMs: number = 250
): void {
  const exact: RemoteSessionExactDisconnectIdentity =
    cloneRemoteSessionExactDisconnectIdentity(identity);
  const safeAttempts: number = Number.isSafeInteger(attemptsRemaining) &&
    attemptsRemaining > 0 ? attemptsRemaining : 0;
  const safeDelayMs: number = Number.isSafeInteger(retryDelayMs) &&
    retryDelayMs >= 0 ? retryDelayMs : 250;
  submitRemoteSessionExactDisconnectAttempt(
    exact, port, safeAttempts, safeDelayMs);
}

export interface RemoteSessionNativeFacadeState {
  sessionId: number;
  facadeGeneration: number;
  rendererHandle: number;
  decoderHandle: number;
  audioPlayerHandle: number;
}

/**
 * Submission-time CAS for one ArkTS facade owner.  The native layer repeats
 * the session/generation/owner-token comparison before mutating its registry.
 */
export function nativeDisconnectOwnerMatchesFacade(
  expected: RemoteSessionNativeDisconnectOwner,
  current: RemoteSessionNativeDisconnectOwner
): boolean {
  return expected.sessionId > 0 && expected.generation > 0 &&
    expected.ownerToken > 0 && expected.facadeGeneration > 0 &&
    expected.sessionId === current.sessionId &&
    expected.generation === current.generation &&
    expected.ownerToken === current.ownerToken &&
    expected.facadeGeneration === current.facadeGeneration;
}

/** Registry ownership is released only after explicit native Complete(3). */
export function nativeDisconnectReceiptCanReleaseRegistry(
  accepted: boolean, terminalState: number
): boolean {
  return accepted && nativeDisconnectStateIsSuccessful(terminalState);
}

/**
 * A rejected/throwing native submission has made no ArkTS ownership commit.
 * Preserve every facade field so the exact same owner can retry; clear the
 * facade only after native explicitly accepts responsibility for teardown.
 */
export function nativeFacadeStateAfterDisconnectSubmission(
  current: RemoteSessionNativeFacadeState,
  accepted: boolean
): RemoteSessionNativeFacadeState {
  if (!accepted) {
    return {
      sessionId: current.sessionId,
      facadeGeneration: current.facadeGeneration,
      rendererHandle: current.rendererHandle,
      decoderHandle: current.decoderHandle,
      audioPlayerHandle: current.audioPlayerHandle
    };
  }
  return {
    sessionId: -1,
    facadeGeneration: 0,
    rendererHandle: -1,
    decoderHandle: -1,
    audioPlayerHandle: -1
  };
}

/** Monotonic page-local token for one independent-window handoff attempt. */
export function nextRemoteSessionHandoffGeneration(current: number): number {
  if (!Number.isSafeInteger(current) || current < 0 ||
      current >= Number.MAX_SAFE_INTEGER) {
    return 1;
  }
  return current + 1;
}

export interface RemoteSessionLocalHandoffIdentity {
  pageGeneration: number;
  bindingGeneration: number;
  sessionId: number;
  sessionGeneration: number;
  hostId: string;
  operationGeneration: number;
}

/**
 * Page-local half of a handoff failure fence. This is checked before a global
 * registry termination so a stale page callback cannot close a newer SSH
 * binding even when the native layer eventually recycles a numeric session id.
 */
export function remoteSessionLocalHandoffFailureOwnsSession(
  expected: RemoteSessionLocalHandoffIdentity,
  current: RemoteSessionLocalHandoffIdentity,
  loaderSessionId: number
): boolean {
  return expected.pageGeneration > 0 &&
    expected.pageGeneration === current.pageGeneration &&
    expected.bindingGeneration > 0 &&
    expected.bindingGeneration === current.bindingGeneration &&
    expected.sessionId > 0 && expected.sessionId === current.sessionId &&
    expected.sessionGeneration > 0 &&
    expected.sessionGeneration === current.sessionGeneration &&
    expected.hostId.trim().length > 0 && expected.hostId === current.hostId &&
    expected.operationGeneration > 0 &&
    expected.operationGeneration === current.operationGeneration &&
    loaderSessionId === expected.sessionId;
}

/**
 * A delayed handoff failure may tear down only the exact session and operation
 * that started it. Matching only the host would let an old callback disconnect
 * a newer session to the same machine.
 */
export function remoteSessionHandoffFailureOwnsSession(
  expected: ActiveRemoteSessionRecord,
  active: ActiveRemoteSessionRecord | null,
  loaderSessionId: number,
  operationGeneration: number,
  currentOperationGeneration: number
): boolean {
  return active !== null && operationGeneration > 0 &&
    operationGeneration === currentOperationGeneration &&
    expected.ownerScopeId !== '' &&
    active.ownerScopeId === expected.ownerScopeId &&
    active.accountGeneration === expected.accountGeneration &&
    active.sessionId === expected.sessionId &&
    active.hostId === expected.hostId && active.protocol === expected.protocol &&
    active.protocolConnected && expected.protocolConnected &&
    loaderSessionId === expected.sessionId;
}
