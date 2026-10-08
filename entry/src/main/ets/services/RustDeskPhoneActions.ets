/** Short phone button transactions owned by one native session generation. */
export interface RustDeskPhoneOwner {
  sessionId: number;
  generation: number;
  ownerToken: number;
  streamEpoch: number;
}

export function samePhoneOwner(a: RustDeskPhoneOwner, b: RustDeskPhoneOwner): boolean {
  return a.sessionId > 0 && a.generation > 0 && a.ownerToken > 0 &&
    a.sessionId === b.sessionId && a.generation === b.generation && a.ownerToken === b.ownerToken && a.streamEpoch > 0 && a.streamEpoch === b.streamEpoch;
}

export class RustDeskPhoneActions {
  private timer: number = -1;
  private epoch: number = 0;
  private heldOwner: RustDeskPhoneOwner | null = null;
  private releaseOperation: number = -1;
  private send: (owner: RustDeskPhoneOwner, operation: number) => number;

  constructor(send: (owner: RustDeskPhoneOwner, operation: number) => number) {
    this.send = send;
  }

  start(owner: RustDeskPhoneOwner, action: number, capabilities: number): boolean {
    if ((capabilities & 3) !== 3 || owner.sessionId <= 0 || owner.generation <= 0 ||
      owner.ownerToken <= 0 || owner.streamEpoch <= 0 || this.heldOwner !== null ||
      [0, 1, 2, 4, 6, 8].indexOf(action) < 0 || (action === 0 && (capabilities & 4) === 0)) {
      return false;
    }
    // Copy identity: asynchronous releases never consult the page's next session.
    const captured: RustDeskPhoneOwner = {
      sessionId: owner.sessionId, generation: owner.generation, ownerToken: owner.ownerToken, streamEpoch: owner.streamEpoch
    };
    if (this.send(captured, action) !== 1) { return false; }
    if (action <= 1) { return true; }
    this.heldOwner = captured;
    this.releaseOperation = action + 1;
    const epoch: number = ++this.epoch;
    this.timer = setTimeout((): void => {
      if (epoch !== this.epoch) { return; }
      this.cancel();
    }, action === 2 ? 500 : 100);
    return true;
  }

  /** Local cleanup is unconditional. Native input permission remains authoritative. */
  cancel(): void {
    ++this.epoch;
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
    const owner: RustDeskPhoneOwner | null = this.heldOwner;
    const operation: number = this.releaseOperation;
    this.heldOwner = null;
    this.releaseOperation = -1;
    if (owner !== null && operation >= 0) { this.send(owner, operation); }
  }
}
