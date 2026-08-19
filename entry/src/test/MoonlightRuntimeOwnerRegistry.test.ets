import { describe, expect, it } from '@ohos/hypium';
import { AccountSessionLease } from '../main/ets/services/AccountScopePolicy';
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

export default function moonlightRuntimeOwnerRegistryTest(): void {
  describe('MoonlightRuntimeOwnerRegistry', (): void => {
    it('admits_only_the_exact_open_account_lease', 0, (): void => {
      const registry = new MoonlightRuntimeOwnerRegistry();
      const current: AccountSessionLease = lease();
      expect(registry.bindScope(current)).assertTrue();
      expect(registry.allowsScope('owner-a', 1)).assertTrue();
      expect(registry.beginOwnerRequest(11, current)).assertTrue();
      expect(registry.beginOwnerRequest(12, lease('owner-a', 1, 2))).assertFalse();
      registry.closeGate();
      expect(registry.allowsScope('owner-a', 1)).assertFalse();
      expect(registry.beginOwnerRequest(13, current)).assertFalse();
    });

    it('refuses_cross_scope_rebind_until_pending_work_is_terminal', 0, (): void => {
      const registry = new MoonlightRuntimeOwnerRegistry();
      const previous: AccountSessionLease = lease();
      expect(registry.bindScope(previous)).assertTrue();
      expect(registry.beginOwnerRequest(21, previous)).assertTrue();
      registry.closeGate();
      expect(registry.bindScope(lease('owner-b', 2, 2))).assertFalse();
      expect(registry.clearDrainedOwners()).assertFalse();
      expect(registry.finishOwnerRequest(21, previous)).assertTrue();
      expect(registry.clearDrainedOwners()).assertTrue();
      expect(registry.bindScope(lease('owner-b', 2, 2))).assertTrue();
      expect(registry.allowsScope('owner-b', 2)).assertTrue();
    });

    it('keeps_a_retired_owner_tracked_until_its_late_completion', 0, (): void => {
      const registry = new MoonlightRuntimeOwnerRegistry();
      const current: AccountSessionLease = lease();
      registry.bindScope(current);
      registry.beginOwnerRequest(31, current);
      registry.retireOwner(31);
      expect(registry.ownerTokens().indexOf(31) >= 0).assertTrue();
      expect(registry.beginOwnerRequest(31, current)).assertFalse();
      expect(registry.finishOwnerRequest(31, current)).assertTrue();
      expect(registry.ownerTokens().indexOf(31)).assertEqual(-1);
    });

    it('waits_for_the_captured_owner_set_to_reach_idle', 0,
      async (): Promise<void> => {
        const registry = new MoonlightRuntimeOwnerRegistry();
        const current: AccountSessionLease = lease();
        registry.bindScope(current);
        registry.beginOwnerRequest(41, current);
        setTimeout((): void => {
          registry.finishOwnerRequest(41, current);
        }, 10);
        expect(await registry.waitForOwnersIdle([41], 500)).assertTrue();
      });

    it('admits_one_maintenance_owner_only_after_the_normal_gate_drains', 0,
      (): void => {
        const registry = new MoonlightRuntimeOwnerRegistry();
        const current: AccountSessionLease = lease();
        expect(registry.bindScope(current)).assertTrue();
        expect(registry.beginMaintenanceRequest(51, current)).assertFalse();
        const beforeClose: number = registry.currentGateRevision();
        expect(registry.closeGate()).assertTrue();
        expect(registry.currentGateRevision() > beforeClose).assertTrue();
        expect(registry.beginMaintenanceRequest(51, current)).assertTrue();
        expect(registry.beginMaintenanceRequest(52, current)).assertFalse();
        expect(registry.finishOwnerRequest(51, current)).assertTrue();
        registry.retireOwner(51);
        expect(registry.pendingRequestCount()).assertEqual(0);
        expect(registry.restoreBoundScopeGate()).assertTrue();
        expect(registry.isGateOpen()).assertTrue();
      });
  });
}
