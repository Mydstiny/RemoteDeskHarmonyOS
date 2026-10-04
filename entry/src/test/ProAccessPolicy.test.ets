import { runCurrentProPurchase, ProPurchaseLifecycle } from '../main/ets/services/pro/ProPurchaseLifecycle';
import { describe, it, expect } from '@ohos/hypium';
import { ProFeature, PRO_LIFETIME } from '../main/ets/services/pro/ProFeatureCatalog';
import { ProAccessContext, ProVerifiedGrant, proFeatureAccess, resolveProFeatureAccess, proGrantState } from '../main/ets/services/pro/ProAccessPolicy';
import { ProEntitlementService, ProOrderVerifier, ProVerificationResult } from '../main/ets/services/pro/ProEntitlementService';
import { ProEnvironment } from '../main/ets/services/pro/ProAccessPolicy';

class TestVerifier implements ProOrderVerifier {
  result: ProVerificationResult = { status: 'unavailable', owner: 'account-a', environment: 'sandbox' };
  async verify(_records: string[], _owner: string, _environment: ProEnvironment): Promise<ProVerificationResult> {
    return this.result;
  }
}
function context(): ProAccessContext {
  return { appVersionCode: 100, apiVersion: 26, device: 'pc', protocol: 'rdp',
    capabilities: [], grantedPermissions: [], requestablePermissions: [] };
}
function feature(id: string = 'future.shipped'): ProFeature {
  return { id, title: '', description: '', requiredEntitlementId: PRO_LIFETIME, availability: 'available',
    minAppVersionCode: 100, minApiVersion: 23, devices: ['pc'], protocols: [], capabilities: [],
    permissions: [], serverAuthorized: false };
}
function grant(): ProVerifiedGrant {
  return { owner: 'account-a', environment: 'sandbox', productId: 'test',
    verifiedAt: 500, revalidateAfter: 1500, usableUntil: 2000, entitlementIds: [PRO_LIFETIME] };
}
export default function proAccessPolicyTest(): void {
  describe('ProAccessPolicy', (): void => {
    it('dismiss_during_preflight_prevents_checkout', 0, async (): Promise<void> => {
      const epoch = ProPurchaseLifecycle.capture();
      let calls = 0;
      await runCurrentProPurchase(async (): Promise<void> => { ProPurchaseLifecycle.dismiss(); },
        (): boolean => ProPurchaseLifecycle.current(epoch), async (): Promise<void> => { calls++; });
      expect(calls).assertEqual(0);
    });
    it('current_preflight_allows_exactly_one_checkout', 0, async (): Promise<void> => {
      const epoch = ProPurchaseLifecycle.capture();
      let calls = 0;
      await runCurrentProPurchase(async (): Promise<void> => {},
        (): boolean => ProPurchaseLifecycle.current(epoch), async (): Promise<void> => { calls++; });
      expect(calls).assertEqual(1);
    });
    it('keeps_core_free_and_denies_unknown_or_planned', 0, (): void => {
      expect(proFeatureAccess('core.connection', context(), 'free', []).executable).assertTrue();
      expect(proFeatureAccess('missing', context(), 'active', [PRO_LIFETIME]).visible).assertFalse();
      expect(proFeatureAccess('pro.security.phonePasskey', context(), 'active', [PRO_LIFETIME]).reason).assertEqual('planned');
    });
    it('lifetime_covers_new_features_but_not_old_feature_lists', 0, (): void => {
      expect(resolveProFeatureAccess(feature('version.one'), context(), 'active', grant().entitlementIds).executable).assertTrue();
      expect(resolveProFeatureAccess(feature('version.two'), context(), 'active', grant().entitlementIds).executable).assertTrue();
      expect(resolveProFeatureAccess(feature(), context(), 'active', ['future.shipped']).executable).assertFalse();
    });
    it('checks_owner_environment_clock_and_revalidation_boundary', 0, (): void => {
      expect(proGrantState(grant(), 'account-a', 'sandbox', 1000)).assertEqual('active');
      expect(proGrantState(grant(), 'account-b', 'sandbox', 1000)).assertEqual('verificationRequired');
      expect(proGrantState(grant(), 'account-a', 'production', 1000)).assertEqual('verificationRequired');
      expect(proGrantState(grant(), 'account-a', 'sandbox', 2000)).assertEqual('verificationRequired');
      expect(proGrantState(grant(), 'account-a', 'sandbox', Number.NaN)).assertEqual('verificationRequired');
      expect(proGrantState(grant(), 'account-a', 'sandbox', 400)).assertEqual('verificationRequired');
    });
    it('unpublished_version_device_protocol_capability_remain_gated', 0, (): void => {
      const f = feature(); const c = context();
      f.availability = 'experimental';
      expect(resolveProFeatureAccess(f, c, 'active', [PRO_LIFETIME]).visible).assertFalse();
      f.availability = 'disabled';
      expect(resolveProFeatureAccess(f, c, 'active', [PRO_LIFETIME]).visible).assertFalse();
      f.availability = 'available'; c.appVersionCode = 99;
      expect(resolveProFeatureAccess(f, c, 'active', [PRO_LIFETIME]).reason).assertEqual('versionUnsupported');
      c.appVersionCode = 100; c.apiVersion = 22;
      expect(resolveProFeatureAccess(f, c, 'active', [PRO_LIFETIME]).reason).assertEqual('versionUnsupported');
      c.apiVersion = 26; c.device = 'unknown';
      expect(resolveProFeatureAccess(f, c, 'active', [PRO_LIFETIME]).reason).assertEqual('deviceUnsupported');
      c.device = 'pc'; f.protocols = ['ssh'];
      expect(resolveProFeatureAccess(f, c, 'active', [PRO_LIFETIME]).reason).assertEqual('protocolUnsupported');
      f.protocols = ['rdp']; f.capabilities = ['file'];
      expect(resolveProFeatureAccess(f, c, 'active', [PRO_LIFETIME]).reason).assertEqual('capabilityUnsupported');
    });
    it('requestable_permission_visible_but_not_executable_and_server_not_locally_granted', 0, (): void => {
      const f = feature(); const c = context(); f.permissions = ['permission']; c.requestablePermissions = ['permission'];
      expect(resolveProFeatureAccess(f, c, 'active', [PRO_LIFETIME]).visible).assertTrue();
      expect(resolveProFeatureAccess(f, c, 'active', [PRO_LIFETIME]).reason).assertEqual('permissionRequired');
      expect(resolveProFeatureAccess(f, c, 'free', []).visible).assertFalse();
      c.grantedPermissions = ['permission']; f.serverAuthorized = true;
      expect(resolveProFeatureAccess(f, c, 'active', [PRO_LIFETIME]).reason).assertEqual('serverAuthorizationRequired');
    });
    it('unavailable_preserves_usable_grant_but_revocation_clears_it', 0, async (): Promise<void> => {
      const verifier = new TestVerifier(); let now = 1000;
      const service = new ProEntitlementService(verifier, (): number => now);
      service.bindAccount('account-a', 'sandbox');
      verifier.result = { status: 'verified', owner: 'account-a', environment: 'sandbox', grant: grant() };
      await service.reconcile([]);
      verifier.result = { status: 'unavailable', owner: 'account-a', environment: 'sandbox' };
      await service.reconcile([]);
      expect(service.snapshot().state).assertEqual('active');
      expect(service.snapshot().needsRevalidation).assertTrue();
      now = 2000;
      expect(service.snapshot().state).assertEqual('verificationRequired');
      verifier.result = { status: 'revoked', owner: 'account-a', environment: 'sandbox' };
      await service.reconcile([]);
      expect(service.snapshot().state).assertEqual('revoked');
    });
    it('expired_or_rolled_back_clock_cannot_reactivate_cached_grant', 0, async (): Promise<void> => {
      const verifier = new TestVerifier(); let now = 1000;
      const service = new ProEntitlementService(verifier, (): number => now);
      service.bindAccount('account-a', 'sandbox');
      verifier.result = { status: 'verified', owner: 'account-a', environment: 'sandbox', grant: grant() };
      await service.reconcile([]);
      now = 2000;
      expect(service.snapshot().state).assertEqual('verificationRequired');
      now = 1200;
      expect(service.snapshot().state).assertEqual('verificationRequired');
      expect(service.nextChangeAt()).assertEqual(0);
      await service.reconcile([]);
      expect(service.snapshot().state).assertEqual('active');
      now = 1100;
      expect(service.snapshot().state).assertEqual('verificationRequired');
    });
    it('snapshots_do_not_mutate_grants_and_same_binding_does_not_clear', 0, async (): Promise<void> => {
      const verifier = new TestVerifier(); const service = new ProEntitlementService(verifier, (): number => 1000);
      service.bindAccount('account-a', 'sandbox', 1);
      verifier.result = { status: 'verified', owner: 'account-a', environment: 'sandbox', grant: grant() };
      await service.reconcile([]);
      service.snapshot().entitlementIds.length = 0;
      service.bindAccount('account-a', 'sandbox', 1);
      expect(service.snapshot().state).assertEqual('active');
      service.bindAccount('account-b', 'sandbox', 2);
      expect(service.snapshot().state).assertEqual('free');
    });
  });
}
