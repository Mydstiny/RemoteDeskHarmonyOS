import { describe, it, expect } from '@ohos/hypium';
import { ProFeature, ProVerifiedGrant, proFeatureAccess, resolveProFeatureAccess } from '../main/ets/services/pro/ProAccessPolicy';

export default function proAccessPolicyTest(): void {
  describe('ProAccessPolicy', (): void => {
    const feature: ProFeature = { id: 'future.shipped', title: '', description: '', requiresPro: true, availability: 'available' };
    const grant: ProVerifiedGrant = { owner: 'account-a', environment: 'sandbox', productId: 'test', active: true,
      validUntil: 2000, featureIds: ['future.shipped'] };
    it('keeps_core_free_without_identity_or_purchase', 0, (): void => {
      expect(proFeatureAccess('core.connection', null, '', 'production', 1000)).assertEqual('allowed');
    });
    it('does_not_sell_or_unlock_planned_or_unknown_features', 0, (): void => {
      expect(proFeatureAccess('pro.workspaces', grant, 'account-a', 'sandbox', 1000)).assertEqual('planned');
      expect(proFeatureAccess('missing', grant, 'account-a', 'sandbox', 1000)).assertEqual('unknown');
    });
    it('requires_verified_current_owner_and_environment', 0, (): void => {
      expect(resolveProFeatureAccess(feature, grant, 'account-a', 'sandbox', 1000)).assertEqual('allowed');
      expect(resolveProFeatureAccess(feature, grant, 'account-b', 'sandbox', 1000)).assertEqual('purchaseRequired');
      expect(resolveProFeatureAccess(feature, grant, 'account-a', 'production', 1000)).assertEqual('purchaseRequired');
      expect(resolveProFeatureAccess(feature, null, 'account-a', 'sandbox', 1000)).assertEqual('purchaseRequired');
    });
    it('rejects_expired_and_invalid_clock_grants', 0, (): void => {
      expect(resolveProFeatureAccess(feature, grant, 'account-a', 'sandbox', 2000)).assertEqual('purchaseRequired');
      expect(resolveProFeatureAccess(feature, grant, 'account-a', 'sandbox', Number.NaN)).assertEqual('purchaseRequired');
    });
  });
}
