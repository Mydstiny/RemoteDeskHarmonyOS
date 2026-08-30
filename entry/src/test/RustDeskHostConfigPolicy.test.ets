import { describe, it, expect } from '@ohos/hypium';
import { RustDeskRelayConfig } from '../main/ets/model/RustDeskRelayConfig';
import {
  resolveRustDeskHostEndpoint,
  RustDeskHostEndpoint
} from '../main/ets/services/RustDeskHostConfigPolicy';

export default function rustDeskHostConfigPolicyTest(): void {
  describe('RustDeskHostConfigPolicy', (): void => {
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
