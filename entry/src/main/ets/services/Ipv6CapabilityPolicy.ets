/**
 * Product-facing IPv6 capability declarations.
 *
 * Parser or transport support alone must never turn one of these claims on.
 * Each protocol capability remains false until its milestone-specific
 * automated, independent-review and real-device acceptance evidence exists.
 * SFTP intentionally inherits the SSH transport declaration.
 */

export type Ipv6Protocol = 'rdp' | 'rustdesk' | 'ssh' | 'vnc' | 'moonlight';
export type Ipv6Capability =
  'configured_endpoint_ipv6' | 'dual_stack_racing' | 'discovery_ipv6' |
  'protocol_control_data_ipv6' | 'nat_traversal_ipv6';

export interface Ipv6ProtocolCapabilities {
  configuredEndpointIpv6: boolean;
  dualStackRacing: boolean;
  discoveryIpv6: boolean;
  protocolControlDataIpv6: boolean;
  natTraversalIpv6: boolean;
}

function disabledCapabilities(): Ipv6ProtocolCapabilities {
  return {
    configuredEndpointIpv6: false,
    dualStackRacing: false,
    discoveryIpv6: false,
    protocolControlDataIpv6: false,
    natTraversalIpv6: false
  };
}

export function ipv6CapabilitiesForProtocol(
  _protocol: Ipv6Protocol
): Ipv6ProtocolCapabilities {
  return disabledCapabilities();
}

export function ipv6CapabilityIsEnabled(
  protocol: Ipv6Protocol,
  capability: Ipv6Capability
): boolean {
  const value: Ipv6ProtocolCapabilities = ipv6CapabilitiesForProtocol(protocol);
  if (capability === 'configured_endpoint_ipv6') { return value.configuredEndpointIpv6; }
  if (capability === 'dual_stack_racing') { return value.dualStackRacing; }
  if (capability === 'discovery_ipv6') { return value.discoveryIpv6; }
  if (capability === 'protocol_control_data_ipv6') { return value.protocolControlDataIpv6; }
  return value.natTraversalIpv6;
}

export function sftpIpv6Capabilities(): Ipv6ProtocolCapabilities {
  return ipv6CapabilitiesForProtocol('ssh');
}
