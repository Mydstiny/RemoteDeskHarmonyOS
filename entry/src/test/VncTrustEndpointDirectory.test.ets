import { describe, it, expect } from '@ohos/hypium';
import { VncTrustView } from '../main/ets/services/VncTrustService';
import {
  VncTrustBindingCandidate,
  selectVncTrustRecheckHost
} from '../main/ets/services/VncTrustEndpointDirectory';

function trust(binding: string, endpointLabel: string = ''): VncTrustView {
  return {
    id: 'trust-1', userId: 'user-1', ownerId: 'gateway-1', ownerType: 'gateway',
    storeIdentityFingerprint: 'a'.repeat(64), endpointBindingFingerprint: binding,
    fingerprintSha256: 'b'.repeat(64), confirmed: false, cloudCandidate: true,
    confirmedAt: 1, endpointLabel, commonName: '', subject: '', issuer: '',
    notBeforeMs: 0, notAfterMs: 0, rootTrusted: false, hostMismatch: false,
    createdAt: 1, syncVersion: 1
  };
}

export default function vncTrustEndpointDirectoryTest(): void {
  describe('VncTrustEndpointDirectory', (): void => {
    it('selects_the_exact_binding_for_a_gateway_target', 0, (): void => {
      const candidates: VncTrustBindingCandidate[] = [
        { hostId: 'target-a', label: 'A', endpointBindingFingerprint: '1'.repeat(64) },
        { hostId: 'target-b', label: 'B', endpointBindingFingerprint: '2'.repeat(64) }
      ];
      const selected = selectVncTrustRecheckHost(trust('2'.repeat(64)), candidates);
      expect(selected.status).assertEqual('current');
      expect(selected.selectedHostId).assertEqual('target-b');
    });

    it('refuses_ambiguous_shared_gateway_targets_without_a_unique_label', 0, (): void => {
      const candidates: VncTrustBindingCandidate[] = [
        { hostId: 'target-a', label: 'A', endpointBindingFingerprint: '1'.repeat(64) },
        { hostId: 'target-b', label: 'B', endpointBindingFingerprint: '1'.repeat(64) }
      ];
      const selected = selectVncTrustRecheckHost(trust('1'.repeat(64)), candidates);
      expect(selected.status).assertEqual('ambiguous');
      expect(selected.selectedHostId).assertEqual('');
      expect(selected.matchingHostCount).assertEqual(2);
    });

    it('uses_saved_endpoint_label_to_disambiguate_shared_gateway_targets', 0, (): void => {
      const candidates: VncTrustBindingCandidate[] = [
        { hostId: 'target-a', label: 'A', endpointBindingFingerprint: '1'.repeat(64) },
        { hostId: 'target-b', label: 'B', endpointBindingFingerprint: '1'.repeat(64) }
      ];
      const selected = selectVncTrustRecheckHost(trust('1'.repeat(64), 'B'), candidates);
      expect(selected.status).assertEqual('current');
      expect(selected.selectedHostId).assertEqual('target-b');
    });

    it('reports_missing_target_and_changed_endpoint_fail_closed', 0, (): void => {
      const missing = selectVncTrustRecheckHost(trust('1'.repeat(64)), []);
      expect(missing.status).assertEqual('target_missing');
      const changed = selectVncTrustRecheckHost(trust('1'.repeat(64)), [
        { hostId: 'target-a', label: 'A', endpointBindingFingerprint: '2'.repeat(64) }
      ]);
      expect(changed.status).assertEqual('changed');
    });
  });
}
