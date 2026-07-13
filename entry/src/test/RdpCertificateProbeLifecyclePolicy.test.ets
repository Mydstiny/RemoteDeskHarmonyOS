import { describe, it, expect } from '@ohos/hypium';
import {
  nextRdpCertificateProbeGeneration,
  shouldApplyRdpCertificateProbeResult
} from '../main/ets/services/RdpCertificateProbeLifecyclePolicy';

export default function rdpCertificateProbeLifecyclePolicyTest(): void {
  describe('RdpCertificateProbeLifecyclePolicy', (): void => {
    it('increments_probe_generation_without_reusing_current_token', 0, (): void => {
      expect(nextRdpCertificateProbeGeneration(0)).assertEqual(1);
      expect(nextRdpCertificateProbeGeneration(41)).assertEqual(42);
    });

    it('accepts_only_the_current_host_and_generation', 0, (): void => {
      expect(shouldApplyRdpCertificateProbeResult(4, 4, 'host-a', 'host-a')).assertTrue();
      expect(shouldApplyRdpCertificateProbeResult(4, 3, 'host-a', 'host-a')).assertFalse();
      expect(shouldApplyRdpCertificateProbeResult(4, 4, 'host-a', 'host-b')).assertFalse();
    });
  });
}
