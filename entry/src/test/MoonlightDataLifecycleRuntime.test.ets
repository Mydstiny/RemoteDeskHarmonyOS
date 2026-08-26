import { describe, expect, it } from '@ohos/hypium';
import { AccountSessionLease } from '../main/ets/services/AccountScopePolicy';
import {
  executeMoonlightDataLifecycleDrain
} from '../main/ets/services/MoonlightDataLifecycleBarrier';
import {
  MoonlightDataLifecycleRuntime,
  MoonlightLifecycleCloudPort,
  MoonlightLifecycleNativePort,
  MoonlightLifecycleSessionPort
} from '../main/ets/services/MoonlightDataLifecycleRuntime';
import {
  MoonlightRuntimeOwnerRegistry
} from '../main/ets/services/MoonlightRuntimeOwnerRegistry';

function lease(owner: string = 'owner-a', generation: number = 1,
  storeInstanceId: number = 1): AccountSessionLease {
  return {
    ownerScopeId: owner,
    storeIdentity: 'store-' + owner,
    generation: generation,
    storeInstanceId: storeInstanceId
  };
}

class MemoryLifecycleSession implements MoonlightLifecycleSessionPort {
  stopped: boolean = true;
  stopCalls: number = 0;
  boundOwner: string = '';
  boundGeneration: number = 0;

  async stopForLifecycle(_reason: string, _timeoutMs: number): Promise<boolean> {
    this.stopCalls += 1;
    return this.stopped;
  }

  bindScope(ownerScopeId: string, accountGeneration: number): void {
    this.boundOwner = ownerScopeId;
    this.boundGeneration = accountGeneration;
  }
}

class MemoryLifecycleNative implements MoonlightLifecycleNativePort {
  readonly cancelled: number[] = [];
  accepted: boolean = true;
  registry: MoonlightRuntimeOwnerRegistry | null = null;
  requestLease: AccountSessionLease | null = null;

  cancelOwner(ownerToken: number): boolean {
    this.cancelled.push(ownerToken);
    if (this.registry !== null && this.requestLease !== null) {
      this.registry.finishOwnerRequest(ownerToken, this.requestLease);
    }
    return this.accepted;
  }
}

class MemoryLifecycleCloud implements MoonlightLifecycleCloudPort {
  quiesced: boolean = true;
  calls: number = 0;

  async quiesceCurrentScope(_timeoutMs: number): Promise<boolean> {
    this.calls += 1;
    return this.quiesced;
  }
}

export default function moonlightDataLifecycleRuntimeTest(): void {
  describe('MoonlightDataLifecycleRuntime', (): void => {
    it('drains_native_owner_cloud_and_reopens_only_on_new_scope_bind', 0,
      async (): Promise<void> => {
        const owners = new MoonlightRuntimeOwnerRegistry();
        const previous: AccountSessionLease = lease();
        owners.bindScope(previous);
        owners.beginOwnerRequest(51, previous);
        const session = new MemoryLifecycleSession();
        const native = new MemoryLifecycleNative();
        native.registry = owners;
        native.requestLease = previous;
        const cloud = new MemoryLifecycleCloud();
        const runtime = new MoonlightDataLifecycleRuntime(
          owners, session, native, cloud);
        const outcome = await executeMoonlightDataLifecycleDrain(
          runtime, 'account-switch', 1000);
        expect(outcome.ok).assertTrue();
        expect(session.stopCalls).assertEqual(1);
        expect(native.cancelled.join(',')).assertEqual('51');
        expect(cloud.calls).assertEqual(1);
        expect(owners.allowsScope('owner-a', 1)).assertFalse();
        const next: AccountSessionLease = lease('owner-b', 2, 2);
        expect(runtime.bindScope(next)).assertTrue();
        expect(owners.allowsScope('owner-b', 2)).assertTrue();
        expect(session.boundOwner).assertEqual('owner-b');
        expect(session.boundGeneration).assertEqual(2);
      });

    it('restores_the_previous_moonlight_gate_when_cloud_drain_fails', 0,
      async (): Promise<void> => {
        const owners = new MoonlightRuntimeOwnerRegistry();
        const previous: AccountSessionLease = lease();
        owners.bindScope(previous);
        const session = new MemoryLifecycleSession();
        const native = new MemoryLifecycleNative();
        const cloud = new MemoryLifecycleCloud();
        cloud.quiesced = false;
        const runtime = new MoonlightDataLifecycleRuntime(
          owners, session, native, cloud);
        const outcome = await executeMoonlightDataLifecycleDrain(
          runtime, 'logout', 1000);
        expect(outcome.ok).assertFalse();
        expect(outcome.failedStep).assertEqual('cloud_and_journal');
        expect(owners.allowsScope('owner-a', 1)).assertTrue();
      });
  });
}
