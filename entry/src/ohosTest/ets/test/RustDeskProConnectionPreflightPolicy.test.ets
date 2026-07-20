import { describe, it, expect } from '@ohos/hypium';
import {
  RustDeskProPreflightState,
  shouldRouteAfterRustDeskProPreflight,
  shouldKeepRustDeskProSheetOpen,
  rustDeskProPeerIdForConnection,
  shouldOpenRustDeskProPreflight
} from '../../../main/ets/services/RustDeskProConnectionPreflightPolicy';
import { RemoteHost } from '../../../main/ets/model/RemoteHost';

export default function rustDeskProConnectionPreflightPolicyTest(): void {
  describe('RustDeskProConnectionPreflightPolicy', (): void => {
    it('routes_only_after_real_authentication_succeeds', 0, (): void => {
      expect(shouldRouteAfterRustDeskProPreflight(RustDeskProPreflightState.CONNECTING)).assertFalse();
      expect(shouldRouteAfterRustDeskProPreflight(RustDeskProPreflightState.ERROR)).assertFalse();
      expect(shouldRouteAfterRustDeskProPreflight(RustDeskProPreflightState.AUTHENTICATED)).assertTrue();
    });

    it('keeps_portrait_sheet_available_after_authentication_failure', 0, (): void => {
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
  });
}
