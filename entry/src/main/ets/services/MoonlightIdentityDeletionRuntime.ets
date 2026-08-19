import rdpnapi from 'librdpnapi.so';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from './AccountScopePolicy';
import { CloudStore } from './CloudStore';
import {
  MoonlightIdentityDeletionPort
} from './MoonlightDeletionCommandService';
import {
  MoonlightNativeCode,
  MoonlightNativeRequestKey
} from './MoonlightHostService';
import {
  MoonlightRuntimeOwnerRegistry
} from './MoonlightRuntimeOwnerRegistry';
import {
  MoonlightRuntimeOwnerTokenAllocator
} from './MoonlightRuntimeContextFactory';
import { moonlightOwnerScopeFingerprint } from './MoonlightRuntimeSupport';
import { MoonlightSessionCoordinator } from './MoonlightSessionCoordinator';

const IDENTITY_DELETE_TIMEOUT_MS: number = 30000;
const OWNER_DRAIN_TIMEOUT_MS: number = 10000;

export interface MoonlightIdentityDeletionCapabilities {
  identityDeletionReady: boolean;
}

export interface MoonlightIdentityDeleteNativeRequest {
  operation: 'delete_identity';
  key: MoonlightNativeRequestKey;
  ownerScopeFingerprint: string;
  timeoutMs: number;
}

export interface MoonlightIdentityDeleteNativeResult {
  operation: 'delete_identity';
  key: MoonlightNativeRequestKey;
  code: MoonlightNativeCode;
  identityExistingCount: number;
  identityDeletedCount: number;
  identityRemainingCount: number;
}

export interface MoonlightIdentityDeletionNativePort {
  capabilities(): MoonlightIdentityDeletionCapabilities;
  cancelOwner(ownerToken: number): boolean;
  deleteOwnerIdentities(
    request: MoonlightIdentityDeleteNativeRequest
  ): Promise<MoonlightIdentityDeleteNativeResult>;
}

export interface MoonlightIdentityDeletionSessionPort {
  stopForLifecycle(reason: string, timeoutMs: number): Promise<boolean>;
}

export interface MoonlightIdentityDeletionLeasePort {
  currentAccountLease(): AccountSessionLease | null;
  isLeaseCurrent(lease: AccountSessionLease): boolean;
}

class MoonlightIdentityDeletionNapiPort
implements MoonlightIdentityDeletionNativePort {
  capabilities(): MoonlightIdentityDeletionCapabilities {
    const value = rdpnapi.moonlightGetBridgeCapabilities();
    return { identityDeletionReady: value.identityDeletionReady };
  }

  cancelOwner(ownerToken: number): boolean {
    try {
      rdpnapi.moonlightCancelOwner(ownerToken);
      return true;
    } catch (_error) {
      return false;
    }
  }

  async deleteOwnerIdentities(
    request: MoonlightIdentityDeleteNativeRequest
  ): Promise<MoonlightIdentityDeleteNativeResult> {
    return await rdpnapi.moonlightRequestAsync(request) as
      MoonlightIdentityDeleteNativeResult;
  }
}

class MoonlightIdentityDeletionSessionAdapter
implements MoonlightIdentityDeletionSessionPort {
  async stopForLifecycle(reason: string, timeoutMs: number): Promise<boolean> {
    return await MoonlightSessionCoordinator.getInstance()
      .stopForLifecycle(reason, timeoutMs);
  }
}

function keyEquals(
  left: MoonlightNativeRequestKey,
  right: MoonlightNativeRequestKey
): boolean {
  return left.requestId === right.requestId &&
    left.generation === right.generation &&
    left.ownerToken === right.ownerToken;
}

function boundedCount(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0 && value <= 256;
}

function recordIdsAreBounded(recordIds: string[]): boolean {
  const seen: string[] = [];
  for (let index: number = 0; index < recordIds.length; index++) {
    const id: string = recordIds[index];
    if (id.trim() !== id || id.length === 0 || id.length > 128 ||
        seen.indexOf(id) >= 0) {
      return false;
    }
    seen.push(id);
  }
  return true;
}

/**
 * Production owner-scoped adapter for destructive secure-identity cleanup.
 * It closes only the Moonlight admission gate, drains stream/host work, then
 * admits one cancellable native maintenance owner. No alias or certificate is
 * returned to ArkTS.
 */
export class MoonlightIdentityDeletionRuntime
implements MoonlightIdentityDeletionPort {
  private static instance: MoonlightIdentityDeletionRuntime | null = null;
  private readonly leases: MoonlightIdentityDeletionLeasePort;
  private readonly owners: MoonlightRuntimeOwnerRegistry;
  private readonly native: MoonlightIdentityDeletionNativePort;
  private readonly session: MoonlightIdentityDeletionSessionPort;
  private active: boolean = false;
  private lastKnownLease: AccountSessionLease | null = null;
  private lastKnownCount: number = -1;

  constructor(
    leases: MoonlightIdentityDeletionLeasePort = CloudStore.getInstance(),
    owners: MoonlightRuntimeOwnerRegistry =
      MoonlightRuntimeOwnerRegistry.getInstance(),
    native: MoonlightIdentityDeletionNativePort =
      new MoonlightIdentityDeletionNapiPort(),
    session: MoonlightIdentityDeletionSessionPort =
      new MoonlightIdentityDeletionSessionAdapter()
  ) {
    this.leases = leases;
    this.owners = owners;
    this.native = native;
    this.session = session;
  }

  static getInstance(): MoonlightIdentityDeletionRuntime {
    if (MoonlightIdentityDeletionRuntime.instance === null) {
      MoonlightIdentityDeletionRuntime.instance =
        new MoonlightIdentityDeletionRuntime();
    }
    return MoonlightIdentityDeletionRuntime.instance;
  }

  localIdentityCount(lease: AccountSessionLease): number {
    if (!this.leaseIsCurrent(lease)) { return -1; }
    if (accountSessionLeaseEquals(this.lastKnownLease, lease) &&
        this.lastKnownCount >= 0) {
      return this.lastKnownCount;
    }
    // Inventory is intentionally asynchronous and native-only. Before the
    // first destructive request, one means “owner identity cleanup required
    // if present”, not an exposed secure-store row count.
    return this.capabilityReady() ? 1 : 0;
  }

  isIdentityDeletionReady(
    lease: AccountSessionLease, identityRecordIds: string[]
  ): boolean {
    return !this.active && this.leaseIsCurrent(lease) &&
      this.owners.allowsScope(lease.ownerScopeId, lease.generation) &&
      recordIdsAreBounded(identityRecordIds) && this.capabilityReady();
  }

  async deleteLocalIdentities(
    lease: AccountSessionLease, identityRecordIds: string[],
    clearAllForOwner: boolean
  ): Promise<boolean> {
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    if (!clearAllForOwner ||
        !this.isIdentityDeletionReady(captured, identityRecordIds)) {
      return false;
    }
    this.active = true;
    let gateRevision: number = -1;
    let maintenanceAdmitted: boolean = false;
    let maintenanceKey: MoonlightNativeRequestKey | null = null;
    try {
      if (!this.owners.closeGate()) { return false; }
      gateRevision = this.owners.currentGateRevision();
      if (!await this.session.stopForLifecycle(
        'delete-local-moonlight-identity', OWNER_DRAIN_TIMEOUT_MS)) {
        return false;
      }
      const currentOwners: number[] = this.owners.ownerTokens();
      let cancellationAccepted: boolean = true;
      for (let index: number = 0; index < currentOwners.length; index++) {
        if (!this.native.cancelOwner(currentOwners[index])) {
          cancellationAccepted = false;
        }
      }
      if (!cancellationAccepted ||
          !await this.owners.waitForOwnersIdle(
            currentOwners, OWNER_DRAIN_TIMEOUT_MS) ||
          !this.leaseIsCurrent(captured) ||
          this.owners.currentGateRevision() !== gateRevision) {
        return false;
      }
      const ownerToken: number =
        MoonlightRuntimeOwnerTokenAllocator.getInstance().next();
      if (ownerToken <= 0 ||
          !this.owners.beginMaintenanceRequest(ownerToken, captured)) {
        return false;
      }
      maintenanceAdmitted = true;
      maintenanceKey = {
        requestId: ownerToken,
        generation: captured.generation,
        ownerToken: ownerToken
      };
      const result: MoonlightIdentityDeleteNativeResult =
        await this.native.deleteOwnerIdentities({
          operation: 'delete_identity',
          key: maintenanceKey,
          ownerScopeFingerprint:
            moonlightOwnerScopeFingerprint(captured.ownerScopeId),
          timeoutMs: IDENTITY_DELETE_TIMEOUT_MS
        });
      const resultShapeValid: boolean = result !== null &&
        result !== undefined && result.operation === 'delete_identity' &&
        result.key !== null && result.key !== undefined &&
        keyEquals(result.key, maintenanceKey) &&
        boundedCount(result.identityExistingCount) &&
        boundedCount(result.identityDeletedCount) &&
        boundedCount(result.identityRemainingCount) &&
        result.identityDeletedCount <= result.identityExistingCount;
      if (resultShapeValid) {
        this.lastKnownLease = cloneAccountSessionLease(captured);
        this.lastKnownCount = result.identityRemainingCount;
      }
      return resultShapeValid && result.code === 'ok' &&
        result.identityRemainingCount === 0 &&
        this.leaseIsCurrent(captured) &&
        this.owners.currentGateRevision() === gateRevision;
    } catch (_error) {
      return false;
    } finally {
      if (maintenanceAdmitted && maintenanceKey !== null) {
        this.owners.finishOwnerRequest(
          maintenanceKey.ownerToken, captured);
        this.owners.retireOwner(maintenanceKey.ownerToken);
      }
      this.active = false;
      if (gateRevision >= 0 &&
          this.owners.currentGateRevision() === gateRevision &&
          this.owners.pendingRequestCount() === 0 &&
          this.leaseIsCurrent(captured)) {
        this.owners.restoreBoundScopeGate();
      }
    }
  }

  private leaseIsCurrent(lease: AccountSessionLease): boolean {
    return accountSessionLeaseEquals(
      this.leases.currentAccountLease(), lease) &&
      this.leases.isLeaseCurrent(lease);
  }

  private capabilityReady(): boolean {
    try {
      return this.native.capabilities().identityDeletionReady;
    } catch (_error) {
      return false;
    }
  }
}
