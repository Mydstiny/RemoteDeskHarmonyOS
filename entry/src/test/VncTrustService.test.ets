import { describe, it, expect } from '@ohos/hypium';
import {
  VncTrustEndpoint,
  vncStoreIdentityFingerprint,
  vncTrustEndpointIsValid,
  vncTrustStoreMatchesCurrent,
  vncTrustViewStateForStore,
  VncTrustService
} from '../main/ets/services/VncTrustService';
import { AccountSessionCoordinator } from '../main/ets/services/AccountSessionCoordinator';

const STORE: string = 'a'.repeat(64);
const BINDING: string = 'b'.repeat(64);
const OTHER_STORE: string = 'c'.repeat(64);

function endpoint(ownerType: 'host' | 'gateway' = 'gateway'): VncTrustEndpoint {
  return {
    ownerType: ownerType,
    ownerId: ownerType === 'gateway' ? 'gateway-1' : 'host-1',
    userId: 'user-1',
    storeIdentityFingerprint: STORE,
    endpointBindingFingerprint: BINDING
  };
}

export default function vncTrustServiceTest(): void {
  describe('VncTrustService endpoint contract', (): void => {
    it('accepts_gateway_and_host_endpoint_owners', 0, (): void => {
      expect(vncTrustEndpointIsValid(endpoint('gateway'), 'user-1', STORE)).assertTrue();
      expect(vncTrustEndpointIsValid(endpoint('host'), 'user-1', STORE)).assertTrue();
    });

    it('rejects_scope_store_and_binding_mismatches', 0, (): void => {
      const wrongScope: VncTrustEndpoint = endpoint();
      wrongScope.userId = 'other-user';
      expect(vncTrustEndpointIsValid(wrongScope, 'user-1', STORE)).assertFalse();

      const missingStore: VncTrustEndpoint = endpoint();
      missingStore.storeIdentityFingerprint = '';
      expect(vncTrustEndpointIsValid(missingStore, 'user-1', STORE)).assertFalse();

      const missingBinding: VncTrustEndpoint = endpoint();
      missingBinding.endpointBindingFingerprint = 'not-a-fingerprint';
      expect(vncTrustEndpointIsValid(missingBinding, 'user-1', STORE)).assertFalse();

      const wrongPhysicalStore: VncTrustEndpoint = endpoint();
      expect(vncTrustEndpointIsValid(wrongPhysicalStore, 'user-1', OTHER_STORE)).assertFalse();
    });

    it('rejects_blank_owner_and_account_scope', 0, (): void => {
      const blankOwner: VncTrustEndpoint = endpoint();
      blankOwner.ownerId = ' ';
      expect(vncTrustEndpointIsValid(blankOwner, 'user-1', STORE)).assertFalse();
      expect(vncTrustEndpointIsValid(endpoint(), '', STORE)).assertFalse();
    });

    it('derives_a_stable_current_store_fingerprint_and_rejects_blank_store', 0, (): void => {
      expect(vncStoreIdentityFingerprint('store-a')).assertEqual(
        vncStoreIdentityFingerprint('store-a'));
      expect(vncStoreIdentityFingerprint('')).assertEqual('');
    });

    it('downgrades_old_store_rows_and_rejects_owner_only_queries', 0, (): void => {
      expect(vncTrustStoreMatchesCurrent(STORE, STORE)).assertTrue();
      expect(vncTrustStoreMatchesCurrent(STORE, OTHER_STORE)).assertFalse();
      expect(vncTrustStoreMatchesCurrent('not-a-fingerprint', STORE)).assertFalse();
      const staleView = vncTrustViewStateForStore(true, true, OTHER_STORE, STORE);
      expect(staleView.confirmed).assertFalse();
      expect(staleView.cloudCandidate).assertTrue();
      const currentView = vncTrustViewStateForStore(true, true, STORE, STORE);
      expect(currentView.confirmed).assertTrue();
      expect(currentView.cloudCandidate).assertFalse();

      const service: VncTrustService = VncTrustService.getInstance();
      const scope = AccountSessionCoordinator.getInstance().currentScope();
      const staleEndpoint: VncTrustEndpoint = {
        ownerType: 'gateway',
        ownerId: 'gateway-1',
        userId: scope.ownerScopeId,
        storeIdentityFingerprint: OTHER_STORE,
        endpointBindingFingerprint: BINDING
      };
      expect(service.trustForEndpoint(staleEndpoint) === null).assertTrue();
      expect(service.isTrusted(staleEndpoint, 'd'.repeat(64))).assertFalse();
      expect(service.trustedFingerprint(staleEndpoint)).assertEqual('');
    });
  });
}
