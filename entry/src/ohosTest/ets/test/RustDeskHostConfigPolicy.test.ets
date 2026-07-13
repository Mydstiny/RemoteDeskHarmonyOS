/**
 * RustDeskHostConfigPolicy.test.ets - RustDesk add-host endpoint resolution
 */
import { describe, it, expect } from '@ohos/hypium';
import { RustDeskRelayConfig } from '../../../main/ets/model/RustDeskRelayConfig';
import {
  resolveRustDeskHostEndpoint
} from '../../../main/ets/services/RustDeskHostConfigPolicy';

function makeRelay(): RustDeskRelayConfig {
  const relay = new RustDeskRelayConfig();
  relay.id = 'relay-1';
  relay.idServer = 'id.example.com';
  relay.idServerPort = 21117;
  return relay;
}

export default function rustDeskHostConfigPolicyTest(): void {
  describe('RustDeskHostConfigPolicy', (): void => {
    it('direct_mode_should_use_direct_host_and_port', 0, (): void => {
      const endpoint = resolveRustDeskHostEndpoint(null, '', true, '192.168.1.20', 21118);
      expect(endpoint.host).assertEqual('192.168.1.20');
      expect(endpoint.port).assertEqual(21118);
    });

    it('relay_mode_should_use_selected_id_server', 0, (): void => {
      const endpoint = resolveRustDeskHostEndpoint(makeRelay(), '', false, '', 21116);
      expect(endpoint.host).assertEqual('id.example.com');
      expect(endpoint.port).assertEqual(21117);
    });

    it('empty_fallback_should_stay_empty_for_validation', 0, (): void => {
      const endpoint = resolveRustDeskHostEndpoint(null, '', false, '', 21116);
      expect(endpoint.host).assertEqual('');
      expect(endpoint.port).assertEqual(21116);
    });
  });
}
