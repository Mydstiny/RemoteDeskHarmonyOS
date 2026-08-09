export type SshModalPhase = 'closed' | 'opening' | 'open' | 'closing';

export interface SshModalDecision {
  mount: boolean;
  dismiss: boolean;
  token: number;
}

/**
 * Serializes one native Sheet surface. A repeated open during the native exit
 * animation is replayed only after onDisappear, never mounted into the old
 * surface.
 */
export class SshModalCoordinator {
  private phase: SshModalPhase = 'closed';
  private token: number = 0;
  private pendingOpen: boolean = false;

  requestOpen(): SshModalDecision {
    if (this.phase === 'closing') {
      this.pendingOpen = true;
      return { mount: false, dismiss: false, token: this.token };
    }
    if (this.phase === 'open' || this.phase === 'opening') {
      return { mount: false, dismiss: false, token: this.token };
    }
    this.phase = 'opening';
    this.pendingOpen = false;
    this.token++;
    return { mount: true, dismiss: false, token: this.token };
  }

  noteAppeared(token: number): boolean {
    if (token !== this.token || this.phase !== 'opening') { return false; }
    this.phase = 'open';
    return true;
  }

  requestClose(): SshModalDecision {
    this.pendingOpen = false;
    if (this.phase === 'closed' || this.phase === 'closing') {
      return { mount: false, dismiss: false, token: this.token };
    }
    this.phase = 'closing';
    return { mount: false, dismiss: true, token: this.token };
  }

  noteDisappeared(token: number): SshModalDecision {
    if (token !== this.token) { return { mount: false, dismiss: false, token: this.token }; }
    const reopen: boolean = this.pendingOpen;
    this.pendingOpen = false;
    this.phase = 'closed';
    if (!reopen) { return { mount: false, dismiss: false, token: this.token }; }
    return this.requestOpen();
  }

  invalidate(): void {
    this.pendingOpen = false;
    this.phase = 'closed';
    this.token++;
  }

  currentToken(): number { return this.token; }
  currentPhase(): SshModalPhase { return this.phase; }
}
