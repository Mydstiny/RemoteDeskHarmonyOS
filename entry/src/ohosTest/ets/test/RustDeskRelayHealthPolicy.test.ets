import { describe, it, expect } from '@ohos/hypium';
import { RustDeskRelayConfig } from '../../../main/ets/model/RustDeskRelayConfig';
import { snapshotSelectedRelay } from '../../../main/ets/services/RustDeskRelayHealthPolicy';

function relayWithLatency(latency: number): RustDeskRelayConfig {
  const relay = new RustDeskRelayConfig();
  relay.id = 'relay-health-test';
  relay.idServer = 'id.example.com';
  relay.relayServer = 'relay.example.com';
  relay.healthStatus = 'online';
  relay.healthLatency = latency;
  relay.healthCheckedAt = Date.now();
  return relay;
}

export default function rustDeskRelayHealthPolicyTest(): void {
  describe('RustDeskRelayHealthPolicy', (): void => {
    it('selected_relay_snapshot_should_refresh_latest_latency', 0, (): void => {
      const source = relayWithLatency(120);
      const first = snapshotSelectedRelay([source], source.id);
      expect(first !== null).assertTrue();
      expect((first as RustDeskRelayConfig).healthLatency).assertEqual(120);

      source.healthLatency = 34;
      const refreshed = snapshotSelectedRelay([source], source.id);
      expect(refreshed !== null).assertTrue();
      expect((refreshed as RustDeskRelayConfig).healthLatency).assertEqual(34);
      expect((refreshed as RustDeskRelayConfig) === source).assertFalse();
    });

    it('missing_selected_relay_should_return_null', 0, (): void => {
      expect(snapshotSelectedRelay([relayWithLatency(20)], 'missing') === null).assertTrue();
    });
  });
}
