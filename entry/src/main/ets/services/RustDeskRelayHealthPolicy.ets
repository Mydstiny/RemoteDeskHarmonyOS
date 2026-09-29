import { RustDeskRelayConfig } from '../model/RustDeskRelayConfig';
import { EndpointAddressResult, endpointTransportHost, parseEndpointFields } from './EndpointAddressPolicy';

/**
 * Return the socket families that a hostname health probe must try.
 *
 * HarmonyOS' NetAddress defaults to AF_INET when `family` is omitted. That
 * silently marks an AAAA-only relay as offline even though the native
 * RustDesk connection path supports both families. Hostnames therefore try
 * IPv6 first and fall back to IPv4; literals keep their declared family.
 */
export function rustDeskRelayHealthFamilies(host: string): number[] {
  const parsed: EndpointAddressResult = parseEndpointFields(host, 1);
  if (!parsed.ok) { return [2, 1]; }
  if (parsed.endpoint.family === 'ipv6') { return [2]; }
  if (parsed.endpoint.family === 'ipv4') { return [1]; }
  return [2, 1];
}

/** Socket address for a stored relay host: brackets removed, IPv6 scope kept. */
export function rustDeskRelayHealthAddress(host: string): string {
  const parsed: EndpointAddressResult = parseEndpointFields(host, 1);
  return parsed.ok ? endpointTransportHost(parsed.endpoint) : host;
}

/**
 * Create a fresh selected-relay object from the current list entry.
 *
 * Relay health is updated on the service-owned config object. The PC detail
 * panel keeps its own @State reference, so replacing that reference is
 * required for ArkUI to render the new latency and status immediately.
 */
export function snapshotSelectedRelay(
  relays: RustDeskRelayConfig[],
  selectedRelayId: string
): RustDeskRelayConfig | null {
  const source = relays.find((relay: RustDeskRelayConfig): boolean => relay.id === selectedRelayId);
  return source ? RustDeskRelayConfig.fromJSON(source.toJSON()) : null;
}
