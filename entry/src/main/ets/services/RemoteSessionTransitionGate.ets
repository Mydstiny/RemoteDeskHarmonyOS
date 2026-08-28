export interface RemoteSessionTransitionLease {
  epoch: number;
}

/** Native Connected(2) and Ready(3) sessions still block account repair. */
export function nativeSessionStateBlocksAutomaticTransition(
  state: number
): boolean {
  return state === 2 || state === 3;
}

/** A rejected native disconnect must retain every activity proof for retry. */
export function disconnectAllSubmissionMayReleaseTracking(
  submitted: boolean
): boolean {
  return submitted;
}

/**
 * Process-local exclusion between automatic account-store repair and new
 * native/window session admission. Acquisition and admission checks are
 * synchronous, so no session can enter between the idle proof and drain.
 */
export class RemoteSessionTransitionGate {
  private static instance: RemoteSessionTransitionGate | null = null;
  private epoch: number = 0;
  private activeEpoch: number = 0;

  static getInstance(): RemoteSessionTransitionGate {
    if (RemoteSessionTransitionGate.instance === null) {
      RemoteSessionTransitionGate.instance =
        new RemoteSessionTransitionGate();
    }
    return RemoteSessionTransitionGate.instance;
  }

  newSessionAllowed(): boolean {
    return this.activeEpoch === 0;
  }

  tryAcquire(): RemoteSessionTransitionLease | null {
    if (this.activeEpoch !== 0 ||
        this.epoch >= Number.MAX_SAFE_INTEGER) {
      return null;
    }
    this.epoch += 1;
    this.activeEpoch = this.epoch;
    return { epoch: this.activeEpoch };
  }

  release(lease: RemoteSessionTransitionLease | null): boolean {
    if (lease === null || lease.epoch <= 0 ||
        lease.epoch !== this.activeEpoch) {
      return false;
    }
    this.activeEpoch = 0;
    return true;
  }
}
