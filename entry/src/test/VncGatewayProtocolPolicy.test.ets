import { describe, it, expect } from '@ohos/hypium';
import { vncGatewayAvailability, VNC_GATEWAY_PROTOCOL_VERSION } from
  '../main/ets/services/VncGatewayProtocolPolicy';

export default function vncGatewayProtocolPolicyTest(): void {
  describe('VncGatewayProtocolPolicy', (): void => {
    it('keeps_ultravnc_repeater_available_as_the_byte_pairing_transport', 0, (): void => {
      const result = vncGatewayAvailability('ultravnc_repeater', false, false);
      expect(result.enabled).assertTrue();
      expect(result.code).assertEqual('');
    });

    it('rejects_mode2_for_the_viewer_only_harmony_client', 0, (): void => {
      const result = vncGatewayAvailability('ultravnc_repeater', false, false, 'mode2');
      expect(result.enabled).assertFalse();
      expect(result.code).assertEqual('E-VNC-REPEATER-MODE2-ROLE');
    });

    it('fails_closed_for_unconfirmed_websocket_contract', 0, (): void => {
      const result = vncGatewayAvailability('websocket_gateway', true, true);
      expect(result.enabled).assertFalse();
      expect(result.code).assertEqual('E-VNC-GATEWAY-CONTRACT-DRAFT');
      expect(result.message.indexOf(VNC_GATEWAY_PROTOCOL_VERSION) >= 0).assertTrue();
    });

    it('requires_a_separate_contract_for_public_and_ssh_transports', 0, (): void => {
      expect(vncGatewayAvailability('public_relay', true, true).enabled).assertFalse();
      expect(vncGatewayAvailability('ssh_tunnel', true, true).enabled).assertFalse();
    });
  });
}
