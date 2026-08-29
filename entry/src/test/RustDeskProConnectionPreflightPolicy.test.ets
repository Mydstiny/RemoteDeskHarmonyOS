import { describe, it, expect } from '@ohos/hypium';
import {
  RustDeskProPreflightState,
  canInvalidateRustDeskProSession,
  classifyRustDeskProNativeError,
  parseRustDeskNativeError,
  shouldRouteAfterRustDeskProPreflight,
  shouldKeepRustDeskProSheetOpen,
  rustDeskProPeerIdForConnection,
  shouldOpenRustDeskProPreflight,
  rustDeskNativeErrorDetail
} from '../main/ets/services/RustDeskProConnectionPreflightPolicy';
import { rustDeskProTokenMatchesConnection } from '../main/ets/model/RustDeskProModels';
import { RemoteHost } from '../main/ets/model/RemoteHost';
import {
  rustDeskCardEndpoint,
  rustDeskConnectionError,
  shouldBindLegacyRustDeskHostToRelay
} from '../main/ets/services/RustDeskHostConfigPolicy';

export default function rustDeskProConnectionPreflightPolicyTest(): void {
  describe('RustDeskProConnectionPreflightPolicy', (): void => {
    it('routes_only_after_real_authentication_succeeds', 0, (): void => {
      expect(shouldRouteAfterRustDeskProPreflight(RustDeskProPreflightState.IDLE)).assertFalse();
      expect(shouldRouteAfterRustDeskProPreflight(RustDeskProPreflightState.CONNECTING)).assertFalse();
      expect(shouldRouteAfterRustDeskProPreflight(RustDeskProPreflightState.ERROR)).assertFalse();
      expect(shouldRouteAfterRustDeskProPreflight(RustDeskProPreflightState.AUTHENTICATED)).assertTrue();
    });

    it('keeps_portrait_sheet_available_after_authentication_failure', 0, (): void => {
      expect(shouldKeepRustDeskProSheetOpen(RustDeskProPreflightState.CONNECTING)).assertTrue();
      expect(shouldKeepRustDeskProSheetOpen(RustDeskProPreflightState.ERROR)).assertTrue();
      expect(shouldKeepRustDeskProSheetOpen(RustDeskProPreflightState.AUTHENTICATED)).assertFalse();
    });

    it('passes_the_stable_pro_peer_id_to_native_connection', 0, (): void => {
      expect(rustDeskProPeerIdForConnection('123456789', '')).assertEqual('123456789');
      expect(rustDeskProPeerIdForConnection('', '987654321')).assertEqual('987654321');
    });

    it('opens_auth_preflight_for_all_rustdesk_hosts', 0, (): void => {
      expect(shouldOpenRustDeskProPreflight('rustdesk', 'manual', false)).assertTrue();
      expect(shouldOpenRustDeskProPreflight('rustdesk', 'rustdesk_pro', true)).assertTrue();
      expect(shouldOpenRustDeskProPreflight('rdp', 'rustdesk_pro', true)).assertFalse();
    });

    it('allows_blank_non_direct_password_for_connect_time_prompt', 0, (): void => {
      const host = new RemoteHost();
      host.protocol = 'rustdesk';
      host.label = 'ask-on-connect';
      host.customHostname = 'peer-456';
      host.host = 'relay.example.com';
      host.port = 21116;
      host.rustdeskRelayId = 'relay-1';
      host.rustdeskAuthMode = 'password';
      host.password = '';
      expect(host.getValidationErrors().length).assertEqual(0);
    });

    it('still_requires_a_password_for_direct_rustdesk_hosts', 0, (): void => {
      const host = new RemoteHost();
      host.protocol = 'rustdesk';
      host.label = 'direct-host';
      host.rustdeskDirectEnabled = true;
      host.rustdeskDirectHost = '192.168.1.20';
      host.rustdeskDirectPort = 21118;
      host.password = '';
      expect(host.getValidationErrors().indexOf('RustDesk 直连模式需要设备密码') >= 0).assertTrue();
    });

    it('rejects_a_non_direct_host_without_a_bound_relay', 0, (): void => {
      const host = new RemoteHost();
      host.protocol = 'rustdesk';
      host.label = 'relay-host';
      host.customHostname = 'peer-123';
      host.host = 'relay.example.com';
      host.port = 21116;
      host.password = 'device-password';
      expect(host.isValid()).assertFalse();
      expect(rustDeskConnectionError({
        directEnabled: false,
        directHost: '',
        directPort: 21118,
        relayId: '',
        relayExists: false,
        relayHost: '',
        relayPort: 0,
        relayKey: '',
        proManaged: false
      })).assertEqual('RustDesk 中继连接未绑定中继配置');
    });

    it('requires_a_server_key_only_for_managed_pro_relays', 0, (): void => {
      expect(rustDeskConnectionError({
        directEnabled: false,
        directHost: '',
        directPort: 21118,
        relayId: 'relay-1',
        relayExists: true,
        relayHost: 'relay.example.com',
        relayPort: 21116,
        relayKey: '',
        proManaged: true
      })).assertEqual('Server Pro 中继缺少服务器密钥');
      expect(rustDeskConnectionError({
        directEnabled: false,
        directHost: '',
        directPort: 21118,
        relayId: 'relay-1',
        relayExists: true,
        relayHost: 'relay.example.com',
        relayPort: 21116,
        relayKey: '',
        proManaged: false
      })).assertEqual('');
    });

    it('accepts_global_ipv6_but_rejects_noncanonical_or_scoped_direct_endpoints', 0, (): void => {
      expect(rustDeskConnectionError({
        directEnabled: true, directHost: '2001:db8::20', directPort: 21118,
        relayId: '', relayExists: false, relayHost: '', relayPort: 0,
        relayKey: '', proManaged: false
      })).assertEqual('');
      expect(rustDeskCardEndpoint(true, '2001:db8::20', 21118, '', 0))
        .assertEqual('[2001:db8::20]:21118');
      expect(rustDeskConnectionError({
        directEnabled: true, directHost: 'fe80::20%wlan0', directPort: 21118,
        relayId: '', relayExists: false, relayHost: '', relayPort: 0,
        relayKey: '', proManaged: false
      })).assertEqual('RustDesk 直连链路本地 IPv6 尚未支持');
      expect(rustDeskConnectionError({
        directEnabled: true, directHost: '2001:db8::20:21118junk', directPort: 21118,
        relayId: '', relayExists: false, relayHost: '', relayPort: 0,
        relayKey: '', proManaged: false
      })).assertEqual('RustDesk 直连地址无效');
    });

    it('binds_only_a_unique_legacy_endpoint_to_a_relay', 0, (): void => {
      expect(shouldBindLegacyRustDeskHostToRelay(
        'rustdesk', false, '', 'Relay.Example.com', 21116, 'relay.example.com', 21116
      )).assertTrue();
      expect(shouldBindLegacyRustDeskHostToRelay(
        'rustdesk', false, 'already-bound', 'relay.example.com', 21116, 'relay.example.com', 21116
      )).assertFalse();
      expect(shouldBindLegacyRustDeskHostToRelay(
        'rustdesk', true, '', 'relay.example.com', 21116, 'relay.example.com', 21116
      )).assertFalse();
    });

    it('does_not_treat_the_legacy_relay_phrase_as_a_verified_pro_expiry', 0, (): void => {
      const phrase = 'you have not logged in or your login session has expired';
      expect(classifyRustDeskProNativeError(phrase)).assertEqual('control_plane_incompatible');
      expect(canInvalidateRustDeskProSession(
        phrase, 'official_server_pro_token', true)).assertFalse();
      const relayError = 'RDERR|stage=relay|code=relay_request_failed|detail=' + phrase;
      expect(classifyRustDeskProNativeError(relayError)).assertEqual('control_plane_incompatible');
      expect(canInvalidateRustDeskProSession(
        relayError, 'official_server_pro_token', true)).assertFalse();
    });

    it('invalidates_only_an_explicit_official_control_plane_expiry', 0, (): void => {
      const error = 'RDERR|stage=control_plane|code=pro_session_expired|detail=session expired';
      const parsed = parseRustDeskNativeError(error);
      expect(parsed.structured).assertTrue();
      expect(parsed.stage).assertEqual('control_plane');
      expect(parsed.code).assertEqual('pro_session_expired');
      expect(parsed.attemptId).assertEqual('');
      expect(rustDeskNativeErrorDetail(error)).assertEqual('session expired');
      expect(classifyRustDeskProNativeError(error)).assertEqual('pro_session_expired');
      expect(canInvalidateRustDeskProSession(
        error, 'official_server_pro_token', true)).assertTrue();
      expect(canInvalidateRustDeskProSession(
        error, 'official_server_pro_token', false)).assertFalse();
      expect(canInvalidateRustDeskProSession(
        error, 'third_party_control_plane', true)).assertFalse();
      expect(canInvalidateRustDeskProSession(
        error, 'oss_key_only', true)).assertFalse();
    });

    it('keeps_http_session_for_api_only_fallback_even_on_structured_expiry',
      0, (): void => {
        const error =
          'RDERR|stage=control_plane|code=pro_session_expired|' +
          'detail=session expired';
        expect(canInvalidateRustDeskProSession(
          error, 'third_party_api_only', false)).assertFalse();
        expect(canInvalidateRustDeskProSession(
          error, 'official_server_pro_token', false)).assertFalse();
      });

    it('classifies_redacted_native_codes_and_preserves_attempt_identity', 0, (): void => {
      const error = 'RDERR|stage=relay|code=control_plane_login_required|' +
        'attempt=184|detail=control plane rejected the relay session as unauthenticated';
      const parsed = parseRustDeskNativeError(error);
      expect(parsed.attemptId).assertEqual('184');
      expect(classifyRustDeskProNativeError(error)).assertEqual('control_plane_incompatible');
      expect(canInvalidateRustDeskProSession(
        error, 'official_server_pro_token', true)).assertFalse();
      expect(classifyRustDeskProNativeError(
        'RDERR|stage=peer_login|code=peer_password_rejected|attempt=185|detail=rejected'))
        .assertEqual('device_password');
    });

    it('protects_a_new_token_generation_from_a_late_old_failure', 0, (): void => {
      expect(rustDeskProTokenMatchesConnection('old-fingerprint', 3,
        'new-fingerprint', 4)).assertFalse();
      expect(rustDeskProTokenMatchesConnection('new-fingerprint', 4,
        'new-fingerprint', 4)).assertTrue();
      expect(rustDeskProTokenMatchesConnection('', 0,
        'current-fingerprint', 9)).assertTrue();
    });
  });
}
