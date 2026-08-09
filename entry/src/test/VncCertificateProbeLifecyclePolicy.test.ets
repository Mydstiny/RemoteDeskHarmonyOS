import { describe, it, expect } from '@ohos/hypium';
import {
  nextVncCertificateProbeGeneration,
  nextVncConnectionAttemptGeneration,
  shouldApplyVncCertificateProbeResult,
  shouldRouteVncAfterCertificateSheetDisappear,
  VncCertificateProbeIdentity
} from '../main/ets/services/VncCertificateProbeLifecyclePolicy';

function identity(): VncCertificateProbeIdentity {
  return {
    userId: 'user-1', accountOwnerScopeId: 'user-1', hostId: 'host-1', gatewayId: 'gateway-1',
    endpointBindingFingerprint: 'a'.repeat(64), storeIdentityFingerprint: 'b'.repeat(64), storeGeneration: 3
  };
}

export default function vncCertificateProbeLifecyclePolicyTest(): void {
  describe('VncCertificateProbeLifecyclePolicy', (): void => {
    it('increments_generations_without_reusing_max_value', 0, (): void => {
      expect(nextVncCertificateProbeGeneration(0)).assertEqual(1);
      expect(nextVncCertificateProbeGeneration(-1)).assertEqual(1);
      expect(nextVncConnectionAttemptGeneration(1.5)).assertEqual(1);
      expect(nextVncConnectionAttemptGeneration(Number.MAX_SAFE_INTEGER)).assertEqual(1);
    });

    it('drops_stale_probe_results_after_retry_or_endpoint_change', 0, (): void => {
      const current: VncCertificateProbeIdentity = identity();
      const same: VncCertificateProbeIdentity = identity();
      expect(shouldApplyVncCertificateProbeResult(4, 4, 9, 9, current, same)).assertTrue();
      expect(shouldApplyVncCertificateProbeResult(5, 4, 9, 9, current, same)).assertFalse();
      expect(shouldApplyVncCertificateProbeResult(4, 4, 10, 9, current, same)).assertFalse();
      same.endpointBindingFingerprint = 'binding-b';
      expect(shouldApplyVncCertificateProbeResult(4, 4, 9, 9, current, same)).assertFalse();
      same.endpointBindingFingerprint = 'a'.repeat(64);
      same.storeGeneration = 4;
      expect(shouldApplyVncCertificateProbeResult(4, 4, 9, 9, current, same)).assertFalse();
      same.storeGeneration = 3;
      same.accountOwnerScopeId = 'other-user';
      expect(shouldApplyVncCertificateProbeResult(4, 4, 9, 9, current, same)).assertFalse();
    });

    it('rejects_invalid_generations_and_noncanonical_bindings', 0, (): void => {
      const current: VncCertificateProbeIdentity = identity();
      expect(shouldApplyVncCertificateProbeResult(0, 0, 1, 1, current, current)).assertFalse();
      expect(shouldApplyVncCertificateProbeResult(1, 1, 0, 0, current, current)).assertFalse();
      const uppercase: VncCertificateProbeIdentity = identity();
      uppercase.endpointBindingFingerprint = 'A'.repeat(64);
      expect(shouldApplyVncCertificateProbeResult(1, 1, 1, 1, current, uppercase)).assertFalse();
    });

    it('routes_only_after_the_sheet_is_fully_gone', 0, (): void => {
      expect(shouldRouteVncAfterCertificateSheetDisappear(false, false)).assertTrue();
      expect(shouldRouteVncAfterCertificateSheetDisappear(true, false)).assertFalse();
      expect(shouldRouteVncAfterCertificateSheetDisappear(false, true)).assertFalse();
    });
  });
}
