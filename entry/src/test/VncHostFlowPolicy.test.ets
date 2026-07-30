import { describe, it, expect } from '@ohos/hypium';
import {
  VNC_GATEWAY_ADD_STEP_COUNT,
  VNC_HOST_ADD_STEP_COUNT,
  clampVncFlowStep,
  isVncGatewayTransportSelectable,
  nextVncFlowStep,
  previousVncFlowStep
} from '../main/ets/services/VncHostFlowPolicy';

export default function vncHostFlowPolicyTest(): void {
  describe('VncHostFlowPolicy', (): void => {
    it('keeps_host_and_gateway_addition_to_two_steps', 0, (): void => {
      expect(VNC_HOST_ADD_STEP_COUNT).assertEqual(2);
      expect(VNC_GATEWAY_ADD_STEP_COUNT).assertEqual(2);
      expect(nextVncFlowStep(0, VNC_HOST_ADD_STEP_COUNT)).assertEqual(1);
      expect(nextVncFlowStep(1, VNC_HOST_ADD_STEP_COUNT)).assertEqual(1);
      expect(previousVncFlowStep(1, VNC_HOST_ADD_STEP_COUNT)).assertEqual(0);
      expect(clampVncFlowStep(9, VNC_GATEWAY_ADD_STEP_COUNT)).assertEqual(1);
    });

    it('exposes_only_supported_mode12_gateway_transport', 0, (): void => {
      expect(isVncGatewayTransportSelectable('ultravnc_repeater')).assertTrue();
      expect(isVncGatewayTransportSelectable('websocket_gateway')).assertFalse();
      expect(isVncGatewayTransportSelectable('ssh_tunnel')).assertFalse();
    });
  });
}
