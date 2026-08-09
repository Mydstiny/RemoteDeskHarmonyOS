import { describe, it, expect } from '@ohos/hypium';
import {
  classifyVncGatewayHealth,
  classifyVncGatewayTcpHealth,
  isSafeVncRepeaterTarget,
  untestedVncGatewayHealth,
  VncGatewayHealthInput,
  VncGatewayTcpHealthInput
} from '../main/ets/services/VncGatewayHealthPolicy';

function input(): VncGatewayHealthInput {
  return {
    transport: 'ultravnc_repeater', enabled: true, repeaterMode: 'mode12', target: 'office-1',
    tcpReachable: true, tlsRequired: false, certificateConfirmed: false, pinMatched: false,
    repeaterBannerOk: true, targetPaired: true, rfbBannerReady: true,
    deepCheckAttempted: true, errorCode: ''
  };
}

function tcpInput(): VncGatewayTcpHealthInput {
  return { transport: 'ultravnc_repeater', enabled: true, repeaterMode: 'mode12',
    tcpReachable: true, errorCode: '' };
}

export default function vncGatewayHealthPolicyTest(): void {
  describe('VncGatewayHealthPolicy', (): void => {
    it('starts_unverified_and_never_confuses_tcp_with_protocol_ready', 0, (): void => {
      expect(untestedVncGatewayHealth().stage).assertEqual('UNTESTED');
      const tcp = classifyVncGatewayTcpHealth(tcpInput());
      expect(tcp.stage).assertEqual('TCP_REACHABLE');
      expect(tcp.protocolReady).assertFalse();
      expect(tcp.message.indexOf('不代表') >= 0).assertTrue();
      const value: VncGatewayHealthInput = input();
      value.deepCheckAttempted = false;
      const result = classifyVncGatewayHealth(value);
      expect(result.stage).assertEqual('TCP_REACHABLE');
      expect(result.protocolReady).assertFalse();
      value.deepCheckAttempted = true;
      value.repeaterBannerOk = false;
      expect(classifyVncGatewayHealth(value).stage).assertEqual('FAILED');
    });

    it('requires_tls_confirmation_and_pin_before_deep_handoff', 0, (): void => {
      const value: VncGatewayHealthInput = input();
      value.tlsRequired = true;
      expect(classifyVncGatewayHealth(value).stage).assertEqual('TLS_CERT_CONFIRMATION_REQUIRED');
      value.certificateConfirmed = true;
      expect(classifyVncGatewayHealth(value).stage).assertEqual('FAILED');
      value.pinMatched = true;
      expect(classifyVncGatewayHealth(value).stage).assertEqual('RFB_BANNER_READY');
    });

    it('keeps_mode2_disabled_and_missing_target_fail_closed', 0, (): void => {
      const value: VncGatewayHealthInput = input();
      value.repeaterMode = 'mode2';
      expect(classifyVncGatewayHealth(value).code).assertEqual('E-VNC-REPEATER-MODE2-ROLE');
      value.repeaterMode = 'mode12';
      value.target = '';
      expect(classifyVncGatewayHealth(value).code).assertEqual('E-VNC-REPEATER-TARGET');
      value.target = 'office-1';
      value.enabled = false;
      expect(classifyVncGatewayHealth(value).code).assertEqual('E-VNC-GATEWAY-DISABLED');
      const tcp = tcpInput();
      tcp.repeaterMode = 'mode2';
      expect(classifyVncGatewayTcpHealth(tcp).code).assertEqual('E-VNC-REPEATER-MODE2-ROLE');
    });

    it('applies_the_native_250_byte_target_contract_before_deep_testing', 0, (): void => {
      expect(isSafeVncRepeaterTarget('office-1')).assertTrue();
      expect(isSafeVncRepeaterTarget('')).assertFalse();
      expect(isSafeVncRepeaterTarget('bad\nID')).assertFalse();
      expect(isSafeVncRepeaterTarget('x'.repeat(247))).assertTrue();
      expect(isSafeVncRepeaterTarget('x'.repeat(248))).assertFalse();
    });

    it('exposes_intermediate_pairing_stages_without_claiming_ready', 0, (): void => {
      const value: VncGatewayHealthInput = input();
      value.targetPaired = false;
      const pairing = classifyVncGatewayHealth(value);
      expect(pairing.stage).assertEqual('REPEATER_BANNER_OK');
      expect(pairing.protocolReady).assertFalse();
      value.targetPaired = true;
      value.rfbBannerReady = false;
      const rfb = classifyVncGatewayHealth(value);
      expect(rfb.stage).assertEqual('TARGET_PAIRED');
      expect(rfb.protocolReady).assertFalse();
    });
  });
}
