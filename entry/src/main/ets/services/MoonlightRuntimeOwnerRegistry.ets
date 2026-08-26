import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from './AccountScopePolicy';

interface MoonlightRuntimeOwnerState {
  ownerToken: number;
  lease: AccountSessionLease;
  pendingRequests: number;
  retired: boolean;
}

export interface MoonlightRuntimeOwnerAdmissionPort {
  beginOwnerRequest(ownerToken: number, lease: AccountSessionLease): boolean;
  finishOwnerRequest(ownerToken: number, lease: AccountSessionLease): boolean;
  retireOwner(ownerToken: number): void;
}

function validLease(lease: AccountSessionLease | null): boolean {
  return lease !== null && lease.ownerScopeId.trim().length > 0 &&
    lease.storeIdentity.trim().length > 0 &&
    Number.isSafeInteger(lease.generation) && lease.generation > 0 &&
    Number.isSafeInteger(lease.storeInstanceId) && lease.storeInstanceId > 0;
}

function validOwnerToken(ownerToken: number): boolean {
  return Number.isSafeInteger(ownerToken) && ownerToken > 0;
}

/**
 * Process-local admission and drain accounting for every Moonlight host-control
 * owner. The registry deliberately contains no RDB/cloud state and is never
 * shared with RDP, SSH, VNC or RustDesk.
 */
export class MoonlightRuntimeOwnerRegistry
implements MoonlightRuntimeOwnerAdmissionPort {
  private static instance: MoonlightRuntimeOwnerRegistry | null = null;
  private boundLease: AccountSessionLease | null = null;
  private gateOpen: boolean = false;
  private gateRevision: number = 0;
  private readonly owners: Map<number, MoonlightRuntimeOwnerState> =
    new Map<number, MoonlightRuntimeOwnerState>();

  static getInstance(): MoonlightRuntimeOwnerRegistry {
    if (MoonlightRuntimeOwnerRegistry.instance === null) {
      MoonlightRuntimeOwnerRegistry.instance =
        new MoonlightRuntimeOwnerRegistry();
    }
    return MoonlightRuntimeOwnerRegistry.instance;
  }

  bindScope(lease: AccountSessionLease): boolean {
    if (!validLease(lease) || this.pendingRequestCount() !== 0) { return false; }
    this.boundLease = cloneAccountSessionLease(lease);
    // A successful lifecycle drain has already cancelled native work owned by
    // the old scope. Completed owner identities must never cross the rebind.
    this.owners.clear();
    this.gateOpen = true;
    this.gateRevision++;
    return true;
  }

  closeGate(): boolean {
    this.gateOpen = false;
    this.gateRevision++;
    return true;
  }

  restoreBoundScopeGate(): boolean {
    if (!validLease(this.boundLease)) { return false; }
    this.gateOpen = true;
    this.gateRevision++;
    return true;
  }

  isGateOpen(): boolean { return this.gateOpen; }

  currentGateRevision(): number { return this.gateRevision; }

  allowsScope(ownerScopeId: string, accountGeneration: number): boolean {
    return this.gateOpen && this.boundLease !== null &&
      this.boundLease.ownerScopeId === ownerScopeId.trim() &&
      this.boundLease.generation === accountGeneration;
  }

  beginOwnerRequest(ownerToken: number, lease: AccountSessionLease): boolean {
    if (!validOwnerToken(ownerToken) || !validLease(lease) || !this.gateOpen ||
        !accountSessionLeaseEquals(this.boundLease, lease)) {
      return false;
    }
    const existing: MoonlightRuntimeOwnerState | undefined =
      this.owners.get(ownerToken);
    if (existing !== undefined) {
      if (existing.retired || !accountSessionLeaseEquals(existing.lease, lease)) {
        return false;
      }
      existing.pendingRequests += 1;
      return true;
    }
    this.owners.set(ownerToken, {
      ownerToken: ownerToken,
      lease: cloneAccountSessionLease(lease),
      pendingRequests: 1,
      retired: false
    });
    return true;
  }

  /**
   * Admits one owner-scoped maintenance request only after the normal gate is
   * closed and every user operation has drained. Account lifecycle can still
   * observe/cancel this owner through the ordinary ownerTokens() path.
   */
  beginMaintenanceRequest(
    ownerToken: number, lease: AccountSessionLease
  ): boolean {
    if (!validOwnerToken(ownerToken) || !validLease(lease) || this.gateOpen ||
        !accountSessionLeaseEquals(this.boundLease, lease) ||
        this.pendingRequestCount() !== 0 || this.owners.has(ownerToken)) {
      return false;
    }
    this.owners.set(ownerToken, {
      ownerToken: ownerToken,
      lease: cloneAccountSessionLease(lease),
      pendingRequests: 1,
      retired: false
    });
    return true;
  }

  finishOwnerRequest(ownerToken: number, lease: AccountSessionLease): boolean {
    const existing: MoonlightRuntimeOwnerState | undefined =
      this.owners.get(ownerToken);
    if (existing === undefined || existing.pendingRequests <= 0 ||
        !accountSessionLeaseEquals(existing.lease, lease)) {
      return false;
    }
    existing.pendingRequests -= 1;
    if (existing.retired && existing.pendingRequests === 0) {
      this.owners.delete(ownerToken);
    }
    return true;
  }

  retireOwner(ownerToken: number): void {
    const existing: MoonlightRuntimeOwnerState | undefined =
      this.owners.get(ownerToken);
    if (existing === undefined) { return; }
    existing.retired = true;
    if (existing.pendingRequests === 0) { this.owners.delete(ownerToken); }
  }

  ownerTokens(): number[] {
    const result: number[] = [];
    this.owners.forEach((state: MoonlightRuntimeOwnerState): void => {
      result.push(state.ownerToken);
    });
    return result;
  }

  pendingRequestCount(ownerTokens: number[] | null = null): number {
    let result: number = 0;
    this.owners.forEach((state: MoonlightRuntimeOwnerState): void => {
      if (ownerTokens === null || ownerTokens.indexOf(state.ownerToken) >= 0) {
        result += state.pendingRequests;
      }
    });
    return result;
  }

  async waitForOwnersIdle(ownerTokens: number[], timeoutMs: number): Promise<boolean> {
    if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0) { return false; }
    if (this.pendingRequestCount(ownerTokens) === 0) { return true; }
    const deadlineAtMs: number = Date.now() + timeoutMs;
    return await new Promise<boolean>((resolve: (value: boolean) => void): void => {
      const poll = (): void => {
        if (this.pendingRequestCount(ownerTokens) === 0) {
          resolve(true);
          return;
        }
        if (Date.now() >= deadlineAtMs) {
          resolve(false);
          return;
        }
        setTimeout(poll, 25);
      };
      poll();
    });
  }

  clearDrainedOwners(): boolean {
    if (this.gateOpen || this.pendingRequestCount() !== 0) { return false; }
    this.owners.clear();
    return true;
  }

  resetForTest(): void {
    this.boundLease = null;
    this.gateOpen = false;
    this.gateRevision = 0;
    this.owners.clear();
  }
}
