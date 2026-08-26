export type RemoteSessionServiceProtocol = 'rdp' | 'rustdesk' | 'vnc' | 'moonlight';

export interface RemoteSessionServiceLease {
  protocol: RemoteSessionServiceProtocol;
  hostId: string;
  sessionId: number;
  generation: number;
  ownerToken: number;
}

const REMOTE_SESSION_LEASE_TEXT_LIMIT: number = 256;
const MAX_SAFE_INTEGER: number = 9007199254740991;

export function remoteSessionServiceLeaseIsValid(
  lease: RemoteSessionServiceLease | null | undefined): boolean {
  if (lease === null || lease === undefined) { return false; }
  return (lease.protocol === 'rdp' || lease.protocol === 'rustdesk' ||
    lease.protocol === 'vnc' || lease.protocol === 'moonlight') &&
    lease.hostId.trim().length > 0 &&
    lease.hostId.length <= REMOTE_SESSION_LEASE_TEXT_LIMIT &&
    Number.isSafeInteger(lease.sessionId) && lease.sessionId > 0 &&
    Number.isSafeInteger(lease.generation) && lease.generation > 0 &&
    Number.isSafeInteger(lease.ownerToken) && lease.ownerToken > 0;
}

export function remoteSessionServiceLeaseEquals(
  left: RemoteSessionServiceLease | null | undefined,
  right: RemoteSessionServiceLease | null | undefined): boolean {
  return remoteSessionServiceLeaseIsValid(left) &&
    remoteSessionServiceLeaseIsValid(right) &&
    (left as RemoteSessionServiceLease).protocol ===
      (right as RemoteSessionServiceLease).protocol &&
    (left as RemoteSessionServiceLease).hostId ===
      (right as RemoteSessionServiceLease).hostId &&
    (left as RemoteSessionServiceLease).sessionId ===
      (right as RemoteSessionServiceLease).sessionId &&
    (left as RemoteSessionServiceLease).generation ===
      (right as RemoteSessionServiceLease).generation &&
    (left as RemoteSessionServiceLease).ownerToken ===
      (right as RemoteSessionServiceLease).ownerToken;
}

export function cloneRemoteSessionServiceLease(
  lease: RemoteSessionServiceLease): RemoteSessionServiceLease {
  return {
    protocol: lease.protocol,
    hostId: lease.hostId,
    sessionId: lease.sessionId,
    generation: lease.generation,
    ownerToken: lease.ownerToken
  };
}

export function remoteSessionServiceLeaseCanClaim(
  current: RemoteSessionServiceLease | null,
  requested: RemoteSessionServiceLease): boolean {
  return remoteSessionServiceLeaseIsValid(requested) &&
    (current === null || remoteSessionServiceLeaseEquals(current, requested));
}

export function remoteSessionServiceLeaseMatchesSession(
  lease: RemoteSessionServiceLease | null | undefined,
  protocol: RemoteSessionServiceProtocol,
  hostId: string,
  sessionId: number): boolean {
  return remoteSessionServiceLeaseIsValid(lease) &&
    (lease as RemoteSessionServiceLease).protocol === protocol &&
    (lease as RemoteSessionServiceLease).hostId === hostId &&
    (lease as RemoteSessionServiceLease).sessionId === sessionId;
}

/**
 * A reconstructed page must have a positive local generation even though it
 * did not create the native transport. Re-entering the same page/session keeps
 * its generation; adopting a different registered session advances it.
 */
export function remoteSessionServiceRestoreGeneration(
  currentGeneration: number,
  currentSessionId: number,
  restoredSessionId: number): number {
  if (!Number.isSafeInteger(restoredSessionId) || restoredSessionId <= 0) { return 0; }
  const normalizedCurrent: number = Number.isSafeInteger(currentGeneration) &&
    currentGeneration > 0 ? currentGeneration : 0;
  if (currentSessionId === restoredSessionId && normalizedCurrent > 0) {
    return normalizedCurrent;
  }
  if (normalizedCurrent >= MAX_SAFE_INTEGER) { return 0; }
  return normalizedCurrent + 1;
}

/**
 * Process-wide tokens prevent two ArkUI page instances from producing the
 * same lease when native session identifiers are recycled.
 */
export class RemoteSessionServiceOwnerTokenAllocator {
  private static instance: RemoteSessionServiceOwnerTokenAllocator | null = null;
  private lastToken: number = 0;
  private sequence: number = 0;

  static getInstance(): RemoteSessionServiceOwnerTokenAllocator {
    if (RemoteSessionServiceOwnerTokenAllocator.instance === null) {
      RemoteSessionServiceOwnerTokenAllocator.instance =
        new RemoteSessionServiceOwnerTokenAllocator();
    }
    return RemoteSessionServiceOwnerTokenAllocator.instance;
  }

  next(nowMs: number = Date.now()): number {
    const safeNow: number = Number.isSafeInteger(nowMs) && nowMs > 0 ? nowMs : Date.now();
    this.sequence = this.sequence >= 999 ? 1 : this.sequence + 1;
    let candidate: number = Math.min(MAX_SAFE_INTEGER, safeNow * 1000 + this.sequence);
    if (candidate <= this.lastToken) {
      candidate = Math.min(MAX_SAFE_INTEGER, this.lastToken + 1);
    }
    if (candidate <= this.lastToken || candidate <= 0) { return 0; }
    this.lastToken = candidate;
    return candidate;
  }

  resetForTest(): void {
    this.lastToken = 0;
    this.sequence = 0;
  }
}
