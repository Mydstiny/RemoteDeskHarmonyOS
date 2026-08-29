import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  Ipv6Capability,
  Ipv6Protocol,
  ipv6CapabilityIsEnabled,
  sftpIpv6Capabilities
} from '../main/ets/services/Ipv6CapabilityPolicy';

export default function ipv6CapabilityPolicyTest(): void {
  describe('Ipv6CapabilityPolicy', (): void => {
    it('keeps_every_protocol_claim_closed_until_acceptance', 0, (): void => {
      const protocols: Ipv6Protocol[] = ['rdp', 'rustdesk', 'ssh', 'vnc', 'moonlight'];
      const capabilities: Ipv6Capability[] = [
        'configured_endpoint_ipv6', 'dual_stack_racing', 'discovery_ipv6',
        'protocol_control_data_ipv6', 'nat_traversal_ipv6'
      ];
      for (let protocolIndex = 0; protocolIndex < protocols.length; protocolIndex++) {
        for (let capabilityIndex = 0; capabilityIndex < capabilities.length; capabilityIndex++) {
          expect(ipv6CapabilityIsEnabled(
            protocols[protocolIndex], capabilities[capabilityIndex])).assertFalse();
        }
      }
      expect(sftpIpv6Capabilities().configuredEndpointIpv6).assertFalse();
      expect(sftpIpv6Capabilities().dualStackRacing).assertFalse();
    });
  });
}
