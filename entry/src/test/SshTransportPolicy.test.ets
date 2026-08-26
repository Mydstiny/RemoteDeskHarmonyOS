import { describe, expect, it } from '@ohos/hypium';
import {
  isSshFrpControlPlaneTransport,
  normalizeSshEndpointTransport,
  sshEditorTransportForStoredHost,
  sshTransportHasNativeImplementation,
  shouldPollSshNativeConnectionState
} from '../main/ets/services/SshTransportPolicy';

export default function sshTransportPolicyTest(): void {
  describe('SshTransportPolicy', (): void => {
    it('preserves FRP TCP as a raw endpoint when saving', 0, (): void => {
      expect(normalizeSshEndpointTransport('frp_tcp')).assertEqual('frp_tcp');
      expect(normalizeSshEndpointTransport('frp_visitor')).assertEqual('frp_visitor');
      expect(normalizeSshEndpointTransport('frp_stcp')).assertEqual('frp_stcp');
      expect(normalizeSshEndpointTransport('frp_sudp')).assertEqual('frp_sudp');
      expect(normalizeSshEndpointTransport('frp_xtcp')).assertEqual('frp_xtcp');
      expect(normalizeSshEndpointTransport('socks5')).assertEqual('socks5');
      expect(normalizeSshEndpointTransport('ssh_jump')).assertEqual('ssh_jump');
      expect(normalizeSshEndpointTransport('unknown')).assertEqual('http_connect');
    });

    it('keeps FRP control-plane modes explicit until their engine exists', 0, (): void => {
      expect(isSshFrpControlPlaneTransport('frp_visitor')).assertTrue();
      expect(isSshFrpControlPlaneTransport('frp_stcp')).assertTrue();
      expect(isSshFrpControlPlaneTransport('frp_sudp')).assertTrue();
      expect(isSshFrpControlPlaneTransport('frp_xtcp')).assertTrue();
      expect(sshTransportHasNativeImplementation('frp_tcp')).assertTrue();
      expect(sshTransportHasNativeImplementation('frp_visitor')).assertFalse();
      expect(sshTransportHasNativeImplementation('frp_stcp')).assertFalse();
      expect(sshTransportHasNativeImplementation('frp_sudp')).assertFalse();
      expect(sshTransportHasNativeImplementation('frp_xtcp')).assertFalse();
    });

    it('does not turn a legacy direct gateway into a direct SSH route', 0, (): void => {
      expect(sshEditorTransportForStoredHost('gateway.example', 'direct'))
        .assertEqual('legacy_gateway');
      expect(sshEditorTransportForStoredHost('frp.example', 'frp_tcp'))
        .assertEqual('frp_tcp');
      expect(sshEditorTransportForStoredHost('', 'frp_tcp'))
        .assertEqual('http_connect');
      expect(sshEditorTransportForStoredHost('jump.example', 'ssh_jump'))
        .assertEqual('ssh_jump');
    });

    it('keeps polling a retained native session while the page waits for recovery', 0,
      (): void => {
        expect(shouldPollSshNativeConnectionState(7, false)).assertTrue();
        expect(shouldPollSshNativeConnectionState(0, false)).assertFalse();
        expect(shouldPollSshNativeConnectionState(-1, false)).assertFalse();
        expect(shouldPollSshNativeConnectionState(7, true)).assertFalse();
      });
  });
}
