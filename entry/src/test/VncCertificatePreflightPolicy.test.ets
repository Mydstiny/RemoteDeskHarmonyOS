import { describe, it, expect } from '@ohos/hypium';
import {
  classifyVncCertificateProbe,
  classifyVncCertificateProbeForOwner,
  VncCertificatePreflightDecision,
  VncCertificatePreflightState,
  VncCertificateProbeView,
  VncCertificateTrustView,
  shouldPersistVncCertificateTrust,
  shouldRequireVncCertificateConfirmation,
  shouldUseVncCertificateOnce,
  vncCertificateDecisionAllowed
} from '../main/ets/services/VncCertificatePreflightPolicy';

const FINGERPRINT_A: string = 'a'.repeat(64);
const FINGERPRINT_B: string = 'b'.repeat(64);
const STORE_FINGERPRINT: string = 'e'.repeat(64);
const BINDING_FINGERPRINT: string = 'd'.repeat(64);

function probe(fingerprint: string = FINGERPRINT_A): VncCertificateProbeView {
  return {
    ok: true, fingerprintSha256: fingerprint, commonName: 'vnc.example', subject: 'CN=vnc.example',
    issuer: 'CN=Test CA', notBeforeMs: 1, notAfterMs: 2, rootTrusted: false,
    hostMismatch: false, errorCode: '', errorMessage: ''
  };
}

function trust(fingerprint: string, confirmed: boolean): VncCertificateTrustView {
  return {
    ownerType: 'host', ownerId: 'host-1', userId: 'user-1', storeIdentityFingerprint: STORE_FINGERPRINT,
    endpointBindingFingerprint: BINDING_FINGERPRINT,
    fingerprintSha256: fingerprint, confirmed: confirmed, confirmedAt: confirmed ? 2 : 0,
    cloudCandidate: !confirmed
  };
}

export default function vncCertificatePreflightPolicyTest(): void {
  describe('VncCertificatePreflightPolicy', (): void => {
    it('classifies_first_time_and_probe_errors', 0, (): void => {
      expect(classifyVncCertificateProbe(probe(), null))
        .assertEqual(VncCertificatePreflightState.TRUST_FIRST_TIME);
      const failed: VncCertificateProbeView = probe('bad');
      failed.ok = false;
      failed.errorCode = 'E-VNC-CERT-PROBE-TLS';
      expect(classifyVncCertificateProbe(failed, null)).assertEqual(VncCertificatePreflightState.ERROR);
    });

    it('requires_local_confirmation_even_for_a_cloud_candidate', 0, (): void => {
      const candidate: VncCertificateTrustView = trust(FINGERPRINT_A, false);
      expect(classifyVncCertificateProbe(probe(), candidate))
        .assertEqual(VncCertificatePreflightState.TRUST_FIRST_TIME);
    });

    it('classifies_matching_and_changed_pins', 0, (): void => {
      expect(classifyVncCertificateProbe(probe(), trust(FINGERPRINT_A, true)))
        .assertEqual(VncCertificatePreflightState.TRUSTED_MATCH);
      expect(classifyVncCertificateProbe(probe(FINGERPRINT_B), trust(FINGERPRINT_A, true)))
        .assertEqual(VncCertificatePreflightState.CERTIFICATE_CHANGED);
    });

    it('rejects_cloud_candidates_and_invalid_local_markers', 0, (): void => {
      const candidate: VncCertificateTrustView = trust(FINGERPRINT_A, true);
      candidate.cloudCandidate = true;
      expect(classifyVncCertificateProbe(probe(), candidate))
        .assertEqual(VncCertificatePreflightState.TRUST_FIRST_TIME);
      const malformedMarker: VncCertificateTrustView = trust(FINGERPRINT_A, true);
      malformedMarker.confirmedAt = 0;
      expect(classifyVncCertificateProbe(probe(), malformedMarker))
        .assertEqual(VncCertificatePreflightState.TRUST_FIRST_TIME);
    });

    it('invalidates_a_saved_pin_when_owner_or_binding_changes', 0, (): void => {
      const changedOwner: VncCertificateTrustView = trust(FINGERPRINT_A, true);
      changedOwner.ownerType = 'gateway';
      expect(classifyVncCertificateProbeForOwner(
        probe(), changedOwner, 'host', 'host-1', 'user-1', STORE_FINGERPRINT, BINDING_FINGERPRINT))
        .assertEqual(VncCertificatePreflightState.TRUST_FIRST_TIME);
      const changedBinding: VncCertificateTrustView = trust(FINGERPRINT_A, true);
      expect(classifyVncCertificateProbeForOwner(
        probe(), changedBinding, 'host', 'host-1', 'user-1', STORE_FINGERPRINT, 'f'.repeat(64)))
        .assertEqual(VncCertificatePreflightState.TRUST_FIRST_TIME);
      const changedUser: VncCertificateTrustView = trust(FINGERPRINT_A, true);
      expect(classifyVncCertificateProbeForOwner(
        probe(), changedUser, 'host', 'host-1', 'other-user', STORE_FINGERPRINT, BINDING_FINGERPRINT))
        .assertEqual(VncCertificatePreflightState.TRUST_FIRST_TIME);
      const changedStore: VncCertificateTrustView = trust(FINGERPRINT_A, true);
      expect(classifyVncCertificateProbeForOwner(
        probe(), changedStore, 'host', 'host-1', 'user-1', 'f'.repeat(64), BINDING_FINGERPRINT))
        .assertEqual(VncCertificatePreflightState.TRUST_FIRST_TIME);
      const changedHost: VncCertificateTrustView = trust(FINGERPRINT_A, true);
      expect(classifyVncCertificateProbeForOwner(
        probe(), changedHost, 'host', 'other-host', 'user-1', STORE_FINGERPRINT, BINDING_FINGERPRINT))
        .assertEqual(VncCertificatePreflightState.TRUST_FIRST_TIME);
      expect(classifyVncCertificateProbeForOwner(
        probe(), trust(FINGERPRINT_A, true), 'host', 'host-1', 'user-1', STORE_FINGERPRINT, 'invalid'))
        .assertEqual(VncCertificatePreflightState.TRUST_FIRST_TIME);
    });

    it('keeps_once_and_persistent_decisions_distinct', 0, (): void => {
      expect(shouldUseVncCertificateOnce(VncCertificatePreflightDecision.CONTINUE_ONCE)).assertTrue();
      expect(shouldPersistVncCertificateTrust(VncCertificatePreflightDecision.CONTINUE_ONCE)).assertFalse();
      expect(shouldPersistVncCertificateTrust(VncCertificatePreflightDecision.TRUST)).assertTrue();
      expect(shouldPersistVncCertificateTrust(VncCertificatePreflightDecision.UPDATE_TRUST)).assertTrue();
      expect(vncCertificateDecisionAllowed(
        VncCertificatePreflightState.CERTIFICATE_CHANGED,
        VncCertificatePreflightDecision.TRUST)).assertFalse();
      expect(vncCertificateDecisionAllowed(
        VncCertificatePreflightState.CERTIFICATE_CHANGED,
        VncCertificatePreflightDecision.UPDATE_TRUST)).assertTrue();
      expect(shouldRequireVncCertificateConfirmation(
        VncCertificatePreflightState.CERTIFICATE_CHANGED)).assertTrue();
    });

    it('requires_an_explicit_decision_for_plaintext_endpoints', 0, (): void => {
      expect(vncCertificateDecisionAllowed(
        VncCertificatePreflightState.PLAINTEXT_WARNING,
        VncCertificatePreflightDecision.CONTINUE_PLAINTEXT)).assertTrue();
      expect(vncCertificateDecisionAllowed(
        VncCertificatePreflightState.PLAINTEXT_WARNING,
        VncCertificatePreflightDecision.CONTINUE_ONCE)).assertFalse();
      expect(vncCertificateDecisionAllowed(
        VncCertificatePreflightState.PLAINTEXT_WARNING,
        VncCertificatePreflightDecision.TRUST)).assertFalse();
    });
  });
}
