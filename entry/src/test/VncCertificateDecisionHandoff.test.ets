import { describe, it, expect } from '@ohos/hypium';
import {
  VNC_CERTIFICATE_DECISION_HANDOFF_TTL_MS,
  VncCertificateDecisionHandoff
} from '../main/ets/services/VncCertificateDecisionHandoff';
import { VncPlaintextDecisionHandoff } from
  '../main/ets/services/VncPlaintextDecisionHandoff';

const FINGERPRINT: string = 'c'.repeat(64);
const BINDING: string = 'd'.repeat(64);
const STORE: string = 'e'.repeat(64);

export default function vncCertificateDecisionHandoffTest(): void {
  describe('VncCertificateDecisionHandoff', (): void => {
    it('is_one_shot_and_bound_to_attempt_generation', 0, (): void => {
      const handoff: VncCertificateDecisionHandoff = new VncCertificateDecisionHandoff();
      expect(handoff.put('user-1', 'attempt-1', 2, BINDING, FINGERPRINT,
        'user-1', STORE, 7, 100)).assertTrue();
      expect(handoff.take('user-1', 'attempt-1', 1, BINDING, 'user-1', STORE, 7, 101)).assertEqual('');
      expect(handoff.take('user-1', 'attempt-1', 2, 'b'.repeat(64), 'user-1', STORE, 7, 101)).assertEqual('');
      expect(handoff.take('user-1', 'attempt-1', 2, BINDING, 'user-1', STORE, 7, 101)).assertEqual(FINGERPRINT);
      expect(handoff.take('user-1', 'attempt-1', 2, BINDING, 'user-1', STORE, 7, 101)).assertEqual('');
    });

    it('expires_without_persisting_or_leaking_a_pin', 0, (): void => {
      const handoff: VncCertificateDecisionHandoff = new VncCertificateDecisionHandoff();
      expect(handoff.put('user-1', 'attempt-1', 1, BINDING, FINGERPRINT,
        'user-1', STORE, 1, 200)).assertTrue();
      expect(handoff.take('user-1', 'attempt-1', 1, BINDING, 'user-1', STORE, 1,
        200 + VNC_CERTIFICATE_DECISION_HANDOFF_TTL_MS + 1)).assertEqual('');
      expect(handoff.put('user-1', 'attempt-2', 1, BINDING, 'bad',
        'user-1', STORE, 1, 300)).assertFalse();
    });

    it('rejects_non_integer_or_non_positive_generations', 0, (): void => {
      const handoff: VncCertificateDecisionHandoff = new VncCertificateDecisionHandoff();
      expect(handoff.put('user-1', 'attempt-zero', 0, BINDING, FINGERPRINT,
        'user-1', STORE, 1, 400)).assertFalse();
      expect(handoff.put('user-1', 'attempt-negative', -1, BINDING, FINGERPRINT,
        'user-1', STORE, 1, 401)).assertFalse();
      expect(handoff.put('user-1', 'attempt-fraction', 1.5, BINDING, FINGERPRINT,
        'user-1', STORE, 1, 402)).assertFalse();
      expect(handoff.put('user-1', 'attempt-infinite', Number.POSITIVE_INFINITY,
        BINDING, FINGERPRINT, 'user-1', STORE, 1, 403)).assertFalse();
    });

    it('rejects_a_changed_account_session_or_store', 0, (): void => {
      const handoff: VncCertificateDecisionHandoff = new VncCertificateDecisionHandoff();
      expect(handoff.put('user-1', 'attempt-1', 1, BINDING, FINGERPRINT,
        'user-1', STORE, 4, 500)).assertTrue();
      expect(handoff.take('user-1', 'attempt-1', 1, BINDING,
        'user-1', STORE, 5, 501)).assertEqual('');
      expect(handoff.take('user-1', 'attempt-1', 1, BINDING,
        'user-1', 'f'.repeat(64), 4, 502)).assertEqual('');
    });
  });

  describe('VncPlaintextDecisionHandoff', (): void => {
    it('accepts_only_the_confirmed_endpoint_and_account_generation_once', 0, (): void => {
      const handoff: VncPlaintextDecisionHandoff = new VncPlaintextDecisionHandoff();
      expect(handoff.put(
        'user-1', 'attempt-plain', 3, BINDING, 'user-1', STORE, 9, 100)).assertTrue();
      expect(handoff.take(
        'user-1', 'attempt-plain', 3, 'a'.repeat(64), 'user-1', STORE, 9, 101)).assertFalse();
      expect(handoff.take(
        'user-1', 'attempt-plain', 3, BINDING, 'user-1', STORE, 9, 102)).assertFalse();

      expect(handoff.put(
        'user-1', 'attempt-plain', 4, BINDING, 'user-1', STORE, 10, 200)).assertTrue();
      expect(handoff.take(
        'user-1', 'attempt-plain', 4, BINDING, 'user-1', STORE, 10, 201)).assertTrue();
      expect(handoff.take(
        'user-1', 'attempt-plain', 4, BINDING, 'user-1', STORE, 10, 202)).assertFalse();
    });
  });
}
