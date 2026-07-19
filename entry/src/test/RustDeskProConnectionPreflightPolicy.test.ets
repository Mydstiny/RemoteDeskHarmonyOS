import { describe, it, expect } from '@ohos/hypium';
import {
  RustDeskProPreflightState,
  shouldRouteAfterRustDeskProPreflight,
  shouldKeepRustDeskProSheetOpen,
  rustDeskProPeerIdForConnection,
  shouldOpenRustDeskProPreflight
} from '../main/ets/services/RustDeskProConnectionPreflightPolicy';
import { RemoteHost } from '../main/ets/model/RemoteHost';
import {
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
  });
}
