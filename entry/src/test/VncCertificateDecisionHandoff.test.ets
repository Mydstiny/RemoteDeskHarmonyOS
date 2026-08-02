import { describe, it, expect } from '@ohos/hypium';
import {
  VNC_CERTIFICATE_DECISION_HANDOFF_TTL_MS,
  VncCertificateDecisionHandoff
} from '../main/ets/services/VncCertificateDecisionHandoff';

const FINGERPRINT: string = 'c'.repeat(64);
const BINDING: string = 'd'.repeat(64);

export default function vncCertificateDecisionHandoffTest(): void {
  describe('VncCertificateDecisionHandoff', (): void => {
    it('is_one_shot_and_bound_to_attempt_generation', 0, (): void => {
      const handoff: VncCertificateDecisionHandoff = new VncCertificateDecisionHandoff();
      expect(handoff.put('user-1', 'attempt-1', 2, BINDING, FINGERPRINT, 100)).assertTrue();
      expect(handoff.take('user-1', 'attempt-1', 1, BINDING, 101)).assertEqual('');
      expect(handoff.take('user-1', 'attempt-1', 2, 'b'.repeat(64), 101)).assertEqual('');
      expect(handoff.take('user-1', 'attempt-1', 2, BINDING, 101)).assertEqual(FINGERPRINT);
      expect(handoff.take('user-1', 'attempt-1', 2, BINDING, 101)).assertEqual('');
    });

    it('expires_without_persisting_or_leaking_a_pin', 0, (): void => {
      const handoff: VncCertificateDecisionHandoff = new VncCertificateDecisionHandoff();
      expect(handoff.put('user-1', 'attempt-1', 1, BINDING, FINGERPRINT, 200)).assertTrue();
      expect(handoff.take('user-1', 'attempt-1', 1, BINDING,
        200 + VNC_CERTIFICATE_DECISION_HANDOFF_TTL_MS + 1)).assertEqual('');
      expect(handoff.put('user-1', 'attempt-2', 1, BINDING, 'bad', 300)).assertFalse();
    });
  });
}
