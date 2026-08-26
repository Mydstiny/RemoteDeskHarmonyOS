import { describe, expect, it } from '@ohos/hypium';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from '../main/ets/services/AccountScopePolicy';
import {
  MoonlightIdentityDeleteNativeRequest,
  MoonlightIdentityDeleteNativeResult,
  MoonlightIdentityDeletionCapabilities,
  MoonlightIdentityDeletionLeasePort,
  MoonlightIdentityDeletionNativePort,
  MoonlightIdentityDeletionRuntime,
  MoonlightIdentityDeletionSessionPort
} from '../main/ets/services/MoonlightIdentityDeletionRuntime';
import {
  MoonlightRuntimeOwnerRegistry
} from '../main/ets/services/MoonlightRuntimeOwnerRegistry';
import {
  MoonlightRuntimeOwnerTokenAllocator
} from '../main/ets/services/MoonlightRuntimeContextFactory';

function lease(owner: string = 'owner-a', generation: number = 1,
  storeInstanceId: number = 1): AccountSessionLease {
  return {
    ownerScopeId: owner,
    storeIdentity: 'store-' + owner,
    generation,
    storeInstanceId
  };
}

class MemoryLeasePort implements MoonlightIdentityDeletionLeasePort {
  active: AccountSessionLease | null = lease();

  currentAccountLease(): AccountSessionLease | null {
    return this.active === null ? null : cloneAccountSessionLease(this.active);
  }

  isLeaseCurrent(candidate: AccountSessionLease): boolean {
    return accountSessionLeaseEquals(this.active, candidate);
  }
}

class DeferredResult {
  readonly promise: Promise<MoonlightIdentityDeleteNativeResult>;
  private resolveValue: (value: MoonlightIdentityDeleteNativeResult) => void =
    (_value: MoonlightIdentityDeleteNativeResult): void => {};

  constructor() {
    this.promise = new Promise<MoonlightIdentityDeleteNativeResult>(
      (resolve: (value: MoonlightIdentityDeleteNativeResult) => void): void => {
        this.resolveValue = resolve;
      });
  }

  resolve(value: MoonlightIdentityDeleteNativeResult): void {
    this.resolveValue(value);
  }
}

class MemoryNativePort implements MoonlightIdentityDeletionNativePort {
  ready: boolean = true;
  remainingCount: number = 0;
  cancelledOwners: number[] = [];
  request: MoonlightIdentityDeleteNativeRequest | null = null;
  deferred: DeferredResult | null = null;

  capabilities(): MoonlightIdentityDeletionCapabilities {
    return { identityDeletionReady: this.ready };
  }

  cancelOwner(ownerToken: number): boolean {
    this.cancelledOwners.push(ownerToken);
    return true;
  }

  async deleteOwnerIdentities(
    request: MoonlightIdentityDeleteNativeRequest
  ): Promise<MoonlightIdentityDeleteNativeResult> {
    this.request = request;
    if (this.deferred !== null) { return await this.deferred.promise; }
    return resultFor(request, this.remainingCount);
  }
}

class MemorySessionPort implements MoonlightIdentityDeletionSessionPort {
  succeed: boolean = true;
  calls: number = 0;

  async stopForLifecycle(_reason: string, _timeoutMs: number): Promise<boolean> {
    this.calls++;
    return this.succeed;
  }
}

function resultFor(request: MoonlightIdentityDeleteNativeRequest,
  remainingCount: number): MoonlightIdentityDeleteNativeResult {
  return {
    operation: 'delete_identity',
    key: request.key,
    code: remainingCount === 0 ? 'ok' : 'repair_required',
    identityExistingCount: 1,
    identityDeletedCount: remainingCount === 0 ? 1 : 0,
    identityRemainingCount: remainingCount
  };
}

export default function moonlightIdentityDeletionRuntimeTest(): void {
  describe('MoonlightIdentityDeletionRuntime', (): void => {
    it('drains_and_deletes_with_a_count_only_native_contract', 0,
      async (): Promise<void> => {
        MoonlightRuntimeOwnerTokenAllocator.getInstance().resetForTest();
        const leases = new MemoryLeasePort();
        const owners = new MoonlightRuntimeOwnerRegistry();
        const native = new MemoryNativePort();
        const session = new MemorySessionPort();
        const current: AccountSessionLease = lease();
        expect(owners.bindScope(current)).assertTrue();
        const runtime = new MoonlightIdentityDeletionRuntime(
          leases, owners, native, session);
        expect(runtime.localIdentityCount(current)).assertEqual(1);
        expect(runtime.isIdentityDeletionReady(current, ['identity-1']))
          .assertTrue();
        expect(await runtime.deleteLocalIdentities(
          current, ['identity-1'], true)).assertTrue();
        expect(session.calls).assertEqual(1);
        expect(native.request?.operation).assertEqual('delete_identity');
        expect(native.request?.ownerScopeFingerprint.length).assertEqual(64);
        expect(owners.pendingRequestCount()).assertEqual(0);
        expect(owners.isGateOpen()).assertTrue();
        expect(runtime.localIdentityCount(current)).assertEqual(0);
        // A reopened store for the same account is a new capability lease.
        // The old zero inventory must not hide identities created after the
        // previous store instance was retired.
        leases.active = lease('owner-a', 2, 2);
        expect(runtime.localIdentityCount(
          leases.active as AccountSessionLease)).assertEqual(1);
      });

    it('restores_the_gate_after_a_verified_remaining_identity', 0,
      async (): Promise<void> => {
        MoonlightRuntimeOwnerTokenAllocator.getInstance().resetForTest();
        const leases = new MemoryLeasePort();
        const owners = new MoonlightRuntimeOwnerRegistry();
        const native = new MemoryNativePort();
        native.remainingCount = 1;
        const current: AccountSessionLease = lease();
        owners.bindScope(current);
        const runtime = new MoonlightIdentityDeletionRuntime(
          leases, owners, native, new MemorySessionPort());
        expect(await runtime.deleteLocalIdentities(
          current, [], true)).assertFalse();
        expect(owners.isGateOpen()).assertTrue();
        expect(runtime.localIdentityCount(current)).assertEqual(1);
      });

    it('does_not_reopen_a_gate_taken_over_by_account_lifecycle', 0,
      async (): Promise<void> => {
        MoonlightRuntimeOwnerTokenAllocator.getInstance().resetForTest();
        const leases = new MemoryLeasePort();
        const owners = new MoonlightRuntimeOwnerRegistry();
        const native = new MemoryNativePort();
        native.deferred = new DeferredResult();
        const current: AccountSessionLease = lease();
        owners.bindScope(current);
        const runtime = new MoonlightIdentityDeletionRuntime(
          leases, owners, native, new MemorySessionPort());
        const pending: Promise<boolean> = runtime.deleteLocalIdentities(
          current, [], true);
        await Promise.resolve();
        await Promise.resolve();
        expect(native.request !== null).assertTrue();
        owners.closeGate();
        native.deferred.resolve(resultFor(
          native.request as MoonlightIdentityDeleteNativeRequest, 0));
        expect(await pending).assertFalse();
        expect(owners.isGateOpen()).assertFalse();
      });
  });
}
