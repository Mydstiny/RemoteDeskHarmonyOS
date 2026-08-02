import { describe, it, expect } from '@ohos/hypium';
import { VncTrustEndpoint, vncTrustEndpointIsValid } from '../main/ets/services/VncTrustService';

const STORE: string = 'a'.repeat(64);
const BINDING: string = 'b'.repeat(64);

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
      expect(vncTrustEndpointIsValid(endpoint('gateway'), 'user-1')).assertTrue();
      expect(vncTrustEndpointIsValid(endpoint('host'), 'user-1')).assertTrue();
    });

    it('rejects_scope_store_and_binding_mismatches', 0, (): void => {
      const wrongScope: VncTrustEndpoint = endpoint();
      wrongScope.userId = 'other-user';
      expect(vncTrustEndpointIsValid(wrongScope, 'user-1')).assertFalse();

      const missingStore: VncTrustEndpoint = endpoint();
      missingStore.storeIdentityFingerprint = '';
      expect(vncTrustEndpointIsValid(missingStore, 'user-1')).assertFalse();

      const missingBinding: VncTrustEndpoint = endpoint();
      missingBinding.endpointBindingFingerprint = 'not-a-fingerprint';
      expect(vncTrustEndpointIsValid(missingBinding, 'user-1')).assertFalse();
    });

    it('rejects_blank_owner_and_account_scope', 0, (): void => {
      const blankOwner: VncTrustEndpoint = endpoint();
      blankOwner.ownerId = ' ';
      expect(vncTrustEndpointIsValid(blankOwner, 'user-1')).assertFalse();
      expect(vncTrustEndpointIsValid(endpoint(), '')).assertFalse();
    });
  });
}
