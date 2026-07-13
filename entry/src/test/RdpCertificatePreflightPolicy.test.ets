import { describe, it, expect } from '@ohos/hypium';
import {
  classifyRdpCertificateProbe,
  RDP_CERTIFICATE_EXPLICIT_TRUST_MODE,
  RdpCertificatePreflightDecision,
  RDP_CERTIFICATE_LEGACY_IMPLICIT_TRUST_MODE,
  RdpCertificatePreflightState,
  rdpCertificateRouteDelayMsAfterSheetClose,
  rdpCertificateWarningMessage,
  shouldRouteRdpCertificateAfterSheetDisappear,
  shouldShowRdpCertificateProbeSheetBeforeProbe,
  shouldPersistRdpCertificateTrust,
  shouldRequireRdpCertificateConfirmation
} from '../main/ets/services/RdpCertificatePreflightPolicy';

export default function rdpCertificatePreflightPolicyTest() {
  describe('RdpCertificatePreflightPolicy', (): void => {
    it('untrusted_first_time_should_require_confirmation', 0, (): void => {
      const state = classifyRdpCertificateProbe({
        ok: true,
        fingerprintSha256: 'SHA256:first',
        commonName: '47.116.203.64',
        subject: 'CN=47.116.203.64',
        issuer: 'CN=SelfSigned',
        flags: 0x00000001,
        rootTrusted: false,
        hostMismatch: false,
        errorMessage: ''
      }, { trustMode: 0, savedFingerprintSha256: '' });
      expect(state).assertEqual(RdpCertificatePreflightState.TRUST_FIRST_TIME);
      expect(shouldRequireRdpCertificateConfirmation(state)).assertTrue();
    });

    it('explicitly_trusted_same_fingerprint_should_match', 0, (): void => {
      const state = classifyRdpCertificateProbe({
        ok: true,
        fingerprintSha256: 'SHA256:same',
        commonName: 'server',
        subject: 'CN=server',
        issuer: 'CN=Root',
        flags: 0,
        rootTrusted: true,
        hostMismatch: false,
        errorMessage: ''
      }, { trustMode: RDP_CERTIFICATE_EXPLICIT_TRUST_MODE, savedFingerprintSha256: 'SHA256:same' });
      expect(state).assertEqual(RdpCertificatePreflightState.TRUSTED_MATCH);
      expect(shouldRequireRdpCertificateConfirmation(state)).assertFalse();
    });

    it('trusted_same_fingerprint_with_new_hostname_mismatch_should_require_confirmation', 0, (): void => {
      const state = classifyRdpCertificateProbe({
        ok: true,
        fingerprintSha256: 'SHA256:same',
        commonName: 'server',
        subject: 'CN=server',
        issuer: 'CN=Root',
        flags: 0x00000002,
        rootTrusted: true,
        hostMismatch: true,
        errorMessage: ''
      }, {
        trustMode: RDP_CERTIFICATE_EXPLICIT_TRUST_MODE,
        savedFingerprintSha256: 'SHA256:same',
        savedAllowHostMismatch: false
      });
      expect(state).assertEqual(RdpCertificatePreflightState.TRUST_FIRST_TIME);
      expect(shouldRequireRdpCertificateConfirmation(state)).assertTrue();
    });

    it('legacy_implicit_trust_should_require_confirmation_again', 0, (): void => {
      const state = classifyRdpCertificateProbe({
        ok: true,
        fingerprintSha256: 'SHA256:same',
        commonName: 'server',
        subject: 'CN=server',
        issuer: 'CN=Root',
        flags: 0,
        rootTrusted: true,
        hostMismatch: false,
        errorMessage: ''
      }, { trustMode: RDP_CERTIFICATE_LEGACY_IMPLICIT_TRUST_MODE, savedFingerprintSha256: 'SHA256:same' });
      expect(state).assertEqual(RdpCertificatePreflightState.TRUST_FIRST_TIME);
      expect(shouldRequireRdpCertificateConfirmation(state)).assertTrue();
    });

    it('trusted_changed_fingerprint_should_warn_changed', 0, (): void => {
      const state = classifyRdpCertificateProbe({
        ok: true,
        fingerprintSha256: 'SHA256:new',
        commonName: 'server',
        subject: 'CN=server',
        issuer: 'CN=Root',
        flags: 0,
        rootTrusted: true,
        hostMismatch: false,
        errorMessage: ''
      }, { trustMode: RDP_CERTIFICATE_EXPLICIT_TRUST_MODE, savedFingerprintSha256: 'SHA256:old' });
      expect(state).assertEqual(RdpCertificatePreflightState.CERTIFICATE_CHANGED);
      expect(shouldRequireRdpCertificateConfirmation(state)).assertTrue();
    });

    it('probe_error_should_be_error_state', 0, (): void => {
      const state = classifyRdpCertificateProbe({
        ok: false,
        fingerprintSha256: '',
        commonName: '',
        subject: '',
        issuer: '',
        flags: 0,
        rootTrusted: false,
        hostMismatch: false,
        errorMessage: 'connect failed'
      }, { trustMode: 0, savedFingerprintSha256: '' });
      expect(state).assertEqual(RdpCertificatePreflightState.ERROR);
    });

    it('warning_copy_should_match_requested_root_certificate_text', 0, (): void => {
      const msg = rdpCertificateWarningMessage('47.116.203.64', false, false);
      expect(msg).assertEqual('你正在连接到 RDP 主机 “47.116.203.64”。无法将证书反向验证到根证书。你的连接可能不安全。是否要继续？');
    });

    it('warning_copy_should_append_hostname_mismatch', 0, (): void => {
      const msg = rdpCertificateWarningMessage('47.116.203.64', false, true);
      expect(msg.indexOf('证书名称与当前主机不匹配。') >= 0).assertTrue();
    });

    it('continue_once_should_not_persist_certificate_trust', 0, (): void => {
      expect(shouldPersistRdpCertificateTrust(RdpCertificatePreflightDecision.CONTINUE_ONCE)).assertFalse();
    });

    it('trust_should_persist_certificate_trust', 0, (): void => {
      expect(shouldPersistRdpCertificateTrust(RdpCertificatePreflightDecision.TRUST)).assertTrue();
    });

    it('route_after_sheet_close_should_wait_for_disappear_instead_of_fixed_delay', 0, (): void => {
      expect(rdpCertificateRouteDelayMsAfterSheetClose()).assertEqual(0);
      expect(shouldRouteRdpCertificateAfterSheetDisappear(true)).assertTrue();
      expect(shouldRouteRdpCertificateAfterSheetDisappear(false)).assertFalse();
    });

    it('probe_sheet_should_show_for_untrusted_hosts_before_blocking_probe', 0, (): void => {
      expect(shouldShowRdpCertificateProbeSheetBeforeProbe(0, '')).assertTrue();
      expect(shouldShowRdpCertificateProbeSheetBeforeProbe(RDP_CERTIFICATE_LEGACY_IMPLICIT_TRUST_MODE,
        'SHA256:legacy')).assertTrue();
    });

    it('probe_sheet_should_not_flash_for_explicitly_trusted_hosts', 0, (): void => {
      expect(shouldShowRdpCertificateProbeSheetBeforeProbe(RDP_CERTIFICATE_EXPLICIT_TRUST_MODE,
        'SHA256:same')).assertFalse();
      expect(shouldShowRdpCertificateProbeSheetBeforeProbe(RDP_CERTIFICATE_EXPLICIT_TRUST_MODE, '')).assertTrue();
    });
  });
}
