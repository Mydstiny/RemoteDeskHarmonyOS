import rdpnapi from 'librdpnapi.so';
import { AccountSessionLease } from './AccountScopePolicy';
import {
  MoonlightDataLifecyclePort
} from './MoonlightDataLifecycleBarrier';
import { CloudStore } from './CloudStore';
import {
  MoonlightRuntimeOwnerRegistry
} from './MoonlightRuntimeOwnerRegistry';
import { MoonlightSessionCoordinator } from './MoonlightSessionCoordinator';

export interface MoonlightLifecycleSessionPort {
  stopForLifecycle(reason: string, timeoutMs: number): Promise<boolean>;
  bindScope(ownerScopeId: string, accountGeneration: number): void;
}

export interface MoonlightLifecycleNativePort {
  cancelOwner(ownerToken: number): boolean;
}

export interface MoonlightLifecycleCloudPort {
  quiesceCurrentScope(timeoutMs: number): Promise<boolean>;
}

class MoonlightLifecycleNapiPort implements MoonlightLifecycleNativePort {
  cancelOwner(ownerToken: number): boolean {
    try {
      // A zero count is valid: the owner may have completed between the ArkTS
      // snapshot and native cancellation admission.
      rdpnapi.moonlightCancelOwner(ownerToken);
      return true;
    } catch (_error) {
      return false;
    }
  }
}

class MoonlightLifecycleSessionAdapter implements MoonlightLifecycleSessionPort {
  async stopForLifecycle(reason: string, timeoutMs: number): Promise<boolean> {
    return await MoonlightSessionCoordinator.getInstance()
      .stopForLifecycle(reason, timeoutMs);
  }

  bindScope(ownerScopeId: string, accountGeneration: number): void {
    MoonlightSessionCoordinator.getInstance()
      .bindScope(ownerScopeId, accountGeneration);
  }
}

class MoonlightLifecycleCloudAdapter implements MoonlightLifecycleCloudPort {
  async quiesceCurrentScope(timeoutMs: number): Promise<boolean> {
    return await CloudStore.getInstance().quiesceCurrentScope(timeoutMs);
  }
}

/**
 * The one production port behind MoonlightDataLifecycleBarrier. It is scoped
 * entirely to Moonlight and is invoked only for account/data transitions.
 */
export class MoonlightDataLifecycleRuntime implements MoonlightDataLifecyclePort {
  private static instance: MoonlightDataLifecycleRuntime | null = null;
  private readonly owners: MoonlightRuntimeOwnerRegistry;
  private readonly session: MoonlightLifecycleSessionPort;
  private readonly native: MoonlightLifecycleNativePort;
  private readonly cloud: MoonlightLifecycleCloudPort;
  private drainReason: string = '';
  private restoreGateAfterFailure: boolean = false;

  constructor(
    owners: MoonlightRuntimeOwnerRegistry = MoonlightRuntimeOwnerRegistry.getInstance(),
    session: MoonlightLifecycleSessionPort = new MoonlightLifecycleSessionAdapter(),
    native: MoonlightLifecycleNativePort = new MoonlightLifecycleNapiPort(),
    cloud: MoonlightLifecycleCloudPort = new MoonlightLifecycleCloudAdapter()
  ) {
    this.owners = owners;
    this.session = session;
    this.native = native;
    this.cloud = cloud;
  }

  static getInstance(): MoonlightDataLifecycleRuntime {
    if (MoonlightDataLifecycleRuntime.instance === null) {
      MoonlightDataLifecycleRuntime.instance =
        new MoonlightDataLifecycleRuntime();
    }
    return MoonlightDataLifecycleRuntime.instance;
  }

  closeMutationAndLaunchGate(reason: string): boolean {
    if (reason.trim().length === 0) { return false; }
    this.drainReason = reason;
    this.restoreGateAfterFailure = this.owners.isGateOpen();
    return this.owners.closeGate();
  }

  async stopSession(timeoutMs: number): Promise<boolean> {
    return await this.session.stopForLifecycle(
      'account-lifecycle:' + this.drainReason, timeoutMs);
  }

  async cancelPairing(timeoutMs: number): Promise<boolean> {
    const ownerTokens: number[] = this.owners.ownerTokens();
    let cancellationAccepted: boolean = true;
    for (let index: number = 0; index < ownerTokens.length; index++) {
      if (!this.native.cancelOwner(ownerTokens[index])) {
        cancellationAccepted = false;
      }
    }
    const idle: boolean = await this.owners.waitForOwnersIdle(
      ownerTokens, timeoutMs);
    return cancellationAccepted && idle;
  }

  async cancelIdentityRestore(_timeoutMs: number): Promise<boolean> {
    // Moonlight identity/pairing work is executed by the same owner-token
    // native pipeline drained above; there is no independent restore worker.
    return this.owners.pendingRequestCount() === 0;
  }

  async drainCloudAndJournal(timeoutMs: number): Promise<boolean> {
    // AccountSessionCoordinator also quiesces the store immediately after the
    // sensitive-data barrier. Repeating the same lease-fenced quiesce here is
    // intentional: this port must uphold its standalone lifecycle contract.
    return await this.cloud.quiesceCurrentScope(timeoutMs);
  }

  clearRuntimeSecrets(): boolean {
    // Pair PIN copies are zeroed by MoonlightHostService before a request can
    // finish. Native stream/input keys are released by the terminal receipts
    // awaited above. Clearing owner identities removes the final ArkTS seam.
    return this.owners.clearDrainedOwners();
  }

  restorePreviousScopeGate(): boolean {
    const shouldRestore: boolean = this.restoreGateAfterFailure;
    this.restoreGateAfterFailure = false;
    this.drainReason = '';
    return !shouldRestore || this.owners.restoreBoundScopeGate();
  }

  bindScope(lease: AccountSessionLease): boolean {
    if (!this.owners.bindScope(lease)) { return false; }
    try {
      this.session.bindScope(lease.ownerScopeId, lease.generation);
      this.restoreGateAfterFailure = false;
      this.drainReason = '';
      return true;
    } catch (_error) {
      this.owners.closeGate();
      return false;
    }
  }
}
