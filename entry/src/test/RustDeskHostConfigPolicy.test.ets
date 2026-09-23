import { describe, it, expect } from '@ohos/hypium';
import { RustDeskRelayConfig } from '../main/ets/model/RustDeskRelayConfig';
import {
  resolveRustDeskHostEndpoint,
  rustDeskCardEndpoint,
  RustDeskHostEndpoint
} from '../main/ets/services/RustDeskHostConfigPolicy';

export default function rustDeskHostConfigPolicyTest(): void {
  describe('RustDeskHostConfigPolicy', (): void => {
    it('card_follows_current_relay_instead_of_the_host_snapshot', 0, (): void => {
      const relay: RustDeskRelayConfig = new RustDeskRelayConfig();
      relay.idServer = '192.0.2.2';
      relay.idServerPort = 21116;
      expect(rustDeskCardEndpoint(false, '', 0, '192.0.2.1', 21116, relay)).assertEqual('192.0.2.2:21116');
      relay.idServer = '192.0.2.3';
      relay.idServerPort = 21126;
      expect(rustDeskCardEndpoint(false, '', 0, '192.0.2.1', 21116, relay)).assertEqual('192.0.2.3:21126');
      expect(rustDeskCardEndpoint(true, '192.0.2.9', 21118, '192.0.2.1', 21116, relay)).assertEqual('192.0.2.9:21118');
      expect(rustDeskCardEndpoint(false, '', 0, '192.0.2.1', 21126)).assertEqual('192.0.2.1:21126');
    });
    it('canonicalizes_the_same_bracketed_ipv6_relay_for_presence_and_sessions', 0, (): void => {
      const relay: RustDeskRelayConfig = new RustDeskRelayConfig();
      relay.idServer = '[2001:0DB8:0:0:0:0:0:20]';
      relay.idServerPort = 21126;
      const endpoint: RustDeskHostEndpoint = resolveRustDeskHostEndpoint(
        relay, 'legacy.invalid', false, '', 0);
      expect(endpoint.host).assertEqual('2001:db8::20');
      expect(endpoint.port).assertEqual(21126);
    });

    it('canonicalizes_a_bracketed_ipv6_direct_endpoint', 0, (): void => {
      const endpoint: RustDeskHostEndpoint = resolveRustDeskHostEndpoint(
        null, 'legacy.invalid', true, '[2001:db8::21]', 21128);
      expect(endpoint.host).assertEqual('2001:db8::21');
      expect(endpoint.port).assertEqual(21128);
    });
  });
}
