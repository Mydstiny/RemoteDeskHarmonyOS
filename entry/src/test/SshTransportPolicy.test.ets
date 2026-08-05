import { describe, expect, it } from '@ohos/hypium';
import {
  normalizeSshEndpointTransport,
  sshEditorTransportForStoredHost
} from '../main/ets/services/SshTransportPolicy';

export default function sshTransportPolicyTest(): void {
  describe('SshTransportPolicy', (): void => {
    it('preserves FRP TCP as a raw endpoint when saving', 0, (): void => {
      expect(normalizeSshEndpointTransport('frp_tcp')).assertEqual('frp_tcp');
      expect(normalizeSshEndpointTransport('socks5')).assertEqual('socks5');
      expect(normalizeSshEndpointTransport('unknown')).assertEqual('http_connect');
    });

    it('does not turn a legacy direct gateway into a direct SSH route', 0, (): void => {
      expect(sshEditorTransportForStoredHost('gateway.example', 'direct'))
        .assertEqual('legacy_gateway');
      expect(sshEditorTransportForStoredHost('frp.example', 'frp_tcp'))
        .assertEqual('frp_tcp');
      expect(sshEditorTransportForStoredHost('', 'frp_tcp'))
        .assertEqual('http_connect');
    });
  });
}
