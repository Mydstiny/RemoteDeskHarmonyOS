import { describe, it, expect } from '@ohos/hypium';
import {
  classifyRdpCertificateProbe,
  RDP_CERTIFICATE_EXPLICIT_TRUST_MODE,
  RdpCertificatePreflightDecision,
  RDP_CERTIFICATE_LEGACY_IMPLICIT_TRUST_MODE,
  RdpCertificatePreflightState,
  rdpCertificateRouteDelayMsAfterSheetClose,
  rdpCertificateWarningMessage,
  rdpCertificateErrorTitle,
  rdpGatewayTransportSummary,
  rdpCertificateValidityState,
  rdpCertificateRiskLabel,
  rdpCertificateRiskSummary,
  rdpPreflightStatusLabel,
  RDP_PREFLIGHT_INCONCLUSIVE,
  RDP_PREFLIGHT_TRANSPORT_FAILED,
  RDP_PREFLIGHT_UNAVAILABLE,
  rdpCertificateRouteIsCurrent,
  rdpCertificateEffectiveRiskFlags,
  rdpCertificateLegacyProbeErrorCode,
  rdpCertificateLegacyProbeStage,
  rdpCertificatePreflightAllowsRealConnection,
  rdpCertificateRoutePreflightAllowsRealConnection,
  shouldRouteRdpCertificateAfterSheetDisappear,
  shouldShowRdpCertificateProbeSheetBeforeProbe,
  shouldEnableStandardRdpSecurityOnce,
  shouldUseRdpTlsWithoutNla,
  shouldPersistRdpCertificateTrust,
  shouldRequireRdpCertificateConfirmation,
  shouldFallbackToNativeRdpConnectionAfterResolverFailure
} from '../main/ets/services/RdpCertificatePreflightPolicy';

export default function rdpCertificatePreflightPolicyTest() {
  describe('RdpCertificatePreflightPolicy', (): void => {
    const nowMs: number = Date.now();
    const validBeforeMs: number = nowMs - 60 * 1000;
    const validAfterMs: number = nowMs + 60 * 1000;

    it('untrusted_first_time_should_require_confirmation', 0, (): void => {
      const state = classifyRdpCertificateProbe({
        ok: true,
        fingerprintSha256: 'SHA256:first',
        commonName: '47.116.203.64',
        subject: 'CN=47.116.203.64',
        issuer: 'CN=SelfSigned',
        notBeforeMs: validBeforeMs,
        notAfterMs: validAfterMs,
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
        notBeforeMs: validBeforeMs,
        notAfterMs: validAfterMs,
        flags: 0,
        rootTrusted: true,
        hostMismatch: false,
        errorMessage: ''
      }, {
        trustMode: RDP_CERTIFICATE_EXPLICIT_TRUST_MODE,
        savedFingerprintSha256: 'SHA256:same', routeBound: true
      });
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
        notBeforeMs: validBeforeMs,
        notAfterMs: validAfterMs,
        flags: 0x00000002,
        rootTrusted: true,
        hostMismatch: true,
        errorMessage: ''
      }, {
        trustMode: RDP_CERTIFICATE_EXPLICIT_TRUST_MODE,
        savedFingerprintSha256: 'SHA256:same',
        routeBound: true,
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
        notBeforeMs: validBeforeMs,
        notAfterMs: validAfterMs,
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
        notBeforeMs: validBeforeMs,
        notAfterMs: validAfterMs,
        flags: 0,
        rootTrusted: true,
        hostMismatch: false,
        errorMessage: ''
      }, {
        trustMode: RDP_CERTIFICATE_EXPLICIT_TRUST_MODE,
        savedFingerprintSha256: 'SHA256:old', routeBound: true
      });
      expect(state).assertEqual(RdpCertificatePreflightState.CERTIFICATE_CHANGED);
      expect(shouldRequireRdpCertificateConfirmation(state)).assertTrue();
    });

    it('callback_changed_risk_should_not_auto_trust', 0, (): void => {
      const state = classifyRdpCertificateProbe({
        ok: true,
        fingerprintSha256: 'SHA256:same',
        commonName: 'server',
        subject: 'CN=server',
        issuer: 'CN=Root',
        notBeforeMs: validBeforeMs,
        notAfterMs: validAfterMs,
        flags: 0,
        rootTrusted: true,
        hostMismatch: false,
        errorMessage: '',
        riskFlags: ['CERTIFICATE_CHANGED']
      }, {
        trustMode: RDP_CERTIFICATE_EXPLICIT_TRUST_MODE,
        savedFingerprintSha256: 'SHA256:same', routeBound: true
      });
      expect(state).assertEqual(RdpCertificatePreflightState.CERTIFICATE_CHANGED);
    });

    it('probe_error_should_be_error_state', 0, (): void => {
      const state = classifyRdpCertificateProbe({
        ok: false,
        fingerprintSha256: '',
        commonName: '',
        subject: '',
        issuer: '',
        notBeforeMs: 0,
        notAfterMs: 0,
        flags: 0,
        rootTrusted: false,
        hostMismatch: false,
        errorMessage: 'connect failed'
      }, { trustMode: 0, savedFingerprintSha256: '' });
      expect(state).assertEqual(RdpCertificatePreflightState.ERROR);
    });

    it('stale_route_pin_should_require_confirmation_again', 0, (): void => {
      const state = classifyRdpCertificateProbe({
        ok: true,
        fingerprintSha256: 'SHA256:same',
        commonName: 'server',
        subject: 'CN=server',
        issuer: 'CN=Root',
        notBeforeMs: validBeforeMs,
        notAfterMs: validAfterMs,
        flags: 0,
        rootTrusted: true,
        hostMismatch: false,
        errorMessage: ''
      }, {
        trustMode: RDP_CERTIFICATE_EXPLICIT_TRUST_MODE,
        savedFingerprintSha256: 'SHA256:same',
        routeBound: false
      });
      expect(state).assertEqual(RdpCertificatePreflightState.TRUST_FIRST_TIME);
      expect(rdpCertificateRouteIsCurrent('route-old', 'route-new')).assertFalse();
      expect(rdpCertificateRouteIsCurrent('route-new', 'route-new')).assertTrue();
    });

    it('certificate_validity_state_rejects_expired_and_unknown_values', 0, (): void => {
      expect(rdpCertificateValidityState(validBeforeMs, validAfterMs, nowMs)).assertEqual('valid');
      expect(rdpCertificateValidityState(nowMs + 1, validAfterMs, nowMs)).assertEqual('invalid');
      expect(rdpCertificateValidityState(validBeforeMs, nowMs - 1, nowMs)).assertEqual('expired');
      expect(rdpCertificateValidityState(0, 0, nowMs)).assertEqual('unknown');
    });

    it('expired_certificate_should_remain_a_user_decidable_risk', 0, (): void => {
      const state = classifyRdpCertificateProbe({
        ok: true,
        fingerprintSha256: 'SHA256:same',
        commonName: 'server',
        subject: 'CN=server',
        issuer: 'CN=Root',
        notBeforeMs: nowMs - 120 * 1000,
        notAfterMs: nowMs - 60 * 1000,
        flags: 0,
        rootTrusted: false,
        hostMismatch: false,
        errorMessage: ''
      }, {
        trustMode: RDP_CERTIFICATE_EXPLICIT_TRUST_MODE,
        savedFingerprintSha256: 'SHA256:same',
        routeBound: true,
        savedAllowUntrustedRoot: true
      });
      expect(state).assertEqual(RdpCertificatePreflightState.TRUST_FIRST_TIME);
    });

    it('stage_error_title_should_identify_gateway_and_target_failures', 0, (): void => {
      expect(rdpCertificateErrorTitle('gateway', 'E-RDP-GATEWAY-TLS'))
        .assertEqual('堡垒机 TLS 检查失败');
      expect(rdpCertificateErrorTitle('tunnel', 'E-RDP-GATEWAY-TUNNEL'))
        .assertEqual('堡垒机隧道协商失败');
      expect(rdpCertificateErrorTitle('target', 'E-RDP-TARGET-CERT'))
        .assertEqual('目标 RDP 证书检查失败');
      expect(rdpCertificateErrorTitle('negotiation', 'E-RDP-NEGOTIATION'))
        .assertEqual('目标 RDP 协商失败');
      expect(rdpCertificateErrorTitle('gateway', 'E-RDP-CERT-PERSIST'))
        .assertEqual('RDP 证书信任保存失败');
    });

    it('inconclusive_probe_should_remain_user_decidable', 0, (): void => {
      const state = classifyRdpCertificateProbe({
        ok: false,
        fingerprintSha256: '',
        commonName: '',
        subject: '',
        issuer: '',
        notBeforeMs: 0,
        notAfterMs: 0,
        flags: 0,
        rootTrusted: false,
        hostMismatch: false,
        errorMessage: 'RDP TLS handshake reset',
        preflightStatus: RDP_PREFLIGHT_INCONCLUSIVE,
        riskFlags: ['TLS_PROBE_RESET']
      }, { trustMode: 0, savedFingerprintSha256: '' });
      expect(state).assertEqual(RdpCertificatePreflightState.TRUST_FIRST_TIME);
      expect(shouldRequireRdpCertificateConfirmation(state)).assertTrue();
      expect(rdpCertificateRiskLabel('STANDARD_RDP_SECURITY'))
        .assertEqual('服务器未提供 TLS 证书，连接安全性较低');
      expect(rdpCertificateRiskSummary(['TLS_PROBE_RESET', 'TLS_PROBE_RESET']))
        .assertEqual('预检无法完成，可能是服务端、网关或协议兼容性问题');
      expect(rdpPreflightStatusLabel(RDP_PREFLIGHT_INCONCLUSIVE)).assertEqual('预检结果不确定');
    });

    it('risk_flagged_unavailable_probe_should_remain_user_decidable', 0, (): void => {
      const state = classifyRdpCertificateProbe({
        ok: false,
        fingerprintSha256: '',
        commonName: '',
        subject: '',
        issuer: '',
        notBeforeMs: 0,
        notAfterMs: 0,
        flags: 0,
        rootTrusted: false,
        hostMismatch: false,
        errorMessage: 'Gateway protocol cannot be identified',
        preflightStatus: RDP_PREFLIGHT_UNAVAILABLE,
        riskFlags: ['UNKNOWN_GATEWAY_PROTOCOL']
      }, { trustMode: 0, savedFingerprintSha256: '' });
      expect(state).assertEqual(RdpCertificatePreflightState.TRUST_FIRST_TIME);
      expect(shouldRequireRdpCertificateConfirmation(state)).assertTrue();
    });

    it('only_transport_failures_stop_the_real_connection_attempt', 0, (): void => {
      expect(rdpCertificatePreflightAllowsRealConnection(
        RDP_PREFLIGHT_INCONCLUSIVE, -22)).assertTrue();
      expect(rdpCertificatePreflightAllowsRealConnection(
        RDP_PREFLIGHT_UNAVAILABLE, -15)).assertTrue();
      expect(rdpCertificatePreflightAllowsRealConnection(
        RDP_PREFLIGHT_TRANSPORT_FAILED, -11)).assertFalse();
      expect(rdpCertificatePreflightAllowsRealConnection(
        RDP_PREFLIGHT_TRANSPORT_FAILED, -13)).assertTrue();
      expect(rdpCertificatePreflightAllowsRealConnection(
        RDP_PREFLIGHT_TRANSPORT_FAILED, -22)).assertTrue();
      expect(rdpCertificatePreflightAllowsRealConnection(
        RDP_PREFLIGHT_UNAVAILABLE, -11)).assertFalse();
      expect(rdpCertificatePreflightAllowsRealConnection(
        RDP_PREFLIGHT_UNAVAILABLE, -13)).assertTrue();
      expect(rdpCertificatePreflightAllowsRealConnection(
        RDP_PREFLIGHT_UNAVAILABLE, -14)).assertFalse();
      expect(rdpCertificateLegacyProbeStage(-13)).assertEqual('negotiation');
      expect(rdpCertificateLegacyProbeErrorCode(-13)).assertEqual('E-RDP-NEGOTIATION');
      expect(rdpCertificateRoutePreflightAllowsRealConnection(
        RDP_PREFLIGHT_UNAVAILABLE, 'E-RDP-TARGET-TLS')).assertTrue();
      expect(rdpCertificateRoutePreflightAllowsRealConnection(
        RDP_PREFLIGHT_UNAVAILABLE, 'E-RDP-NEGOTIATION')).assertTrue();
      expect(rdpCertificateRoutePreflightAllowsRealConnection(
        RDP_PREFLIGHT_TRANSPORT_FAILED, 'E-RDP-TARGET-TLS')).assertTrue();
      expect(rdpCertificateRoutePreflightAllowsRealConnection(
        RDP_PREFLIGHT_TRANSPORT_FAILED, 'E-RDP-NEGOTIATION')).assertTrue();
      expect(rdpCertificateRoutePreflightAllowsRealConnection(
        RDP_PREFLIGHT_TRANSPORT_FAILED, 'E-RDP-GATEWAY-CERT')).assertTrue();
      expect(rdpCertificateRoutePreflightAllowsRealConnection(
        RDP_PREFLIGHT_UNAVAILABLE, 'E-RDP-BASTION-UNSUPPORTED')).assertTrue();
      expect(rdpCertificateRoutePreflightAllowsRealConnection(
        RDP_PREFLIGHT_INCONCLUSIVE, 'E-RDP-GATEWAY-AUTH-REQUIRED')).assertTrue();
      expect(rdpCertificateRoutePreflightAllowsRealConnection(
        RDP_PREFLIGHT_TRANSPORT_FAILED, 'E-RDP-GATEWAY-AUTH')).assertFalse();
      expect(rdpCertificateRoutePreflightAllowsRealConnection(
        RDP_PREFLIGHT_UNAVAILABLE, 'E-RDP-TARGET-TIMEOUT')).assertFalse();
      expect(rdpCertificateRoutePreflightAllowsRealConnection(
        RDP_PREFLIGHT_INCONCLUSIVE, 'E-RDP-TARGET-TIMEOUT')).assertTrue();
      expect(rdpCertificateRoutePreflightAllowsRealConnection(
        RDP_PREFLIGHT_TRANSPORT_FAILED, 'E-RDP-TARGET-TIMEOUT',
        ['TLS_PROBE_RESET'])).assertTrue();
      expect(rdpCertificateEffectiveRiskFlags([], ['TLS_PROBE_RESET']).indexOf(
        'TLS_PROBE_RESET')).assertEqual(0);
      expect(rdpCertificateEffectiveRiskFlags(
        ['TARGET_CERTIFICATE_RISK'], ['UNTRUSTED_ROOT']).length).assertEqual(2);
    });

    it('standard_security_requires_an_explicit_continue_once', 0, (): void => {
      expect(shouldEnableStandardRdpSecurityOnce(
        false, ['STANDARD_RDP_SECURITY'])).assertFalse();
      expect(shouldEnableStandardRdpSecurityOnce(
        true, [])).assertFalse();
      expect(shouldEnableStandardRdpSecurityOnce(
        true, ['STANDARD_RDP_SECURITY'])).assertTrue();
    });

    it('tls_without_nla_is_opt_in_direct_password_only', 0, (): void => {
      expect(shouldUseRdpTlsWithoutNla(false, 'direct_rdp', 'password')).assertFalse();
      expect(shouldUseRdpTlsWithoutNla(true, 'direct_rdp', 'password')).assertTrue();
      expect(shouldUseRdpTlsWithoutNla(true, 'microsoft_rd_gateway', 'password')).assertFalse();
      expect(shouldUseRdpTlsWithoutNla(true, 'direct_rdp', 'restricted_admin')).assertFalse();
      expect(shouldUseRdpTlsWithoutNla(true, 'direct_rdp', 'blank_password')).assertFalse();
    });

    it('gateway_transport_summary_should_not_infer_negotiated_mode', 0, (): void => {
      expect(rdpGatewayTransportSummary('auto', 'unknown'))
        .assertEqual('Gateway 传输策略: 请求 auto · 实际 未观测');
      expect(rdpGatewayTransportSummary('no-websockets', 'http'))
        .assertEqual('Gateway 传输策略: 请求 no-websockets · 实际 http');
      expect(rdpGatewayTransportSummary('rpc', 'invalid'))
        .assertEqual('Gateway 传输策略: 请求 rpc · 实际 未观测');
    });

    it('warning_copy_should_match_requested_root_certificate_text', 0, (): void => {
      const msg = rdpCertificateWarningMessage('47.116.203.64', false, false);
      expect(msg).assertEqual('你正在连接到 RDP 主机 “47.116.203.64”。无法将证书反向验证到根证书。你的连接可能不安全。是否要继续？');
    });

    it('warning_copy_should_append_hostname_mismatch', 0, (): void => {
      const msg = rdpCertificateWarningMessage('47.116.203.64', false, true);
      expect(msg.indexOf('证书名称与当前主机不匹配。') >= 0).assertTrue();
    });

    it('continue_once_should_leave_persisted_certificate_record_unchanged', 0, (): void => {
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
        'SHA256:same', true)).assertFalse();
      expect(shouldShowRdpCertificateProbeSheetBeforeProbe(RDP_CERTIFICATE_EXPLICIT_TRUST_MODE, '')).assertTrue();
      expect(shouldShowRdpCertificateProbeSheetBeforeProbe(RDP_CERTIFICATE_EXPLICIT_TRUST_MODE,
        'SHA256:same', false)).assertTrue();
    });

    it('dns_or_tcp_probe_failure_should_not_fallback_to_native_connection', 0, (): void => {
      expect(shouldFallbackToNativeRdpConnectionAfterResolverFailure(
        -11, RDP_CERTIFICATE_EXPLICIT_TRUST_MODE, 'SHA256:same',
        'route-current', 'route-current')).assertFalse();
      expect(shouldFallbackToNativeRdpConnectionAfterResolverFailure(
        -11, RDP_CERTIFICATE_UNKNOWN_TRUST_MODE, '',
        'route-current', 'route-current')).assertFalse();
      expect(shouldFallbackToNativeRdpConnectionAfterResolverFailure(
        -12, RDP_CERTIFICATE_EXPLICIT_TRUST_MODE, 'SHA256:same',
        'route-current', 'route-current')).assertFalse();
      expect(shouldFallbackToNativeRdpConnectionAfterResolverFailure(
        -11, RDP_CERTIFICATE_EXPLICIT_TRUST_MODE, 'SHA256:same',
        'route-old', 'route-current')).assertFalse();
    });
  });
}
