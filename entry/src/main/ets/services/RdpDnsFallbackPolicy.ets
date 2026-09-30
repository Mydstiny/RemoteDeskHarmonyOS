import {
  endpointTransportHost,
  parseEndpointHost
} from './EndpointAddressPolicy';

/**
 * Runtime-only DNS candidates used when the native resolver and NetworkKit
 * disagree.  These values are never persisted as part of RemoteHost.
 */
export const RDP_DNS_FALLBACK_MAX_ADDRESSES: number = 8;

export function normalizeRdpDnsCandidate(value: string): string {
  const parsed = parseEndpointHost(value.trim(), 'runtime');
  if (!parsed.ok || parsed.endpoint.family === 'hostname') {
    return '';
  }
  return endpointTransportHost(parsed.endpoint);
}

export function rdpDnsFallbackCandidates(
  values: string[],
  maxAddresses: number = RDP_DNS_FALLBACK_MAX_ADDRESSES
): string[] {
  if (maxAddresses <= 0) {
    return [];
  }
  const candidates: string[] = [];
  for (let index = 0; index < values.length && candidates.length < maxAddresses; index++) {
    const candidate = normalizeRdpDnsCandidate(values[index]);
    if (candidate !== '' && candidates.indexOf(candidate) < 0) {
      candidates.push(candidate);
    }
  }
  return candidates;
}

export function rdpDnsFallbackEligible(
  host: string,
  errorCode: number,
  endpointMode: string
): boolean {
  if (errorCode !== -11 ||
      (endpointMode !== 'direct_rdp' && endpointMode !== 'transparent_tcp_rdp')) {
    return false;
  }
  const parsed = parseEndpointHost(host.trim(), 'runtime');
  return parsed.ok && parsed.endpoint.family === 'hostname';
}

/**
 * A non-DNS preflight result proves that the numeric candidate reached the
 * RDP service. Keep that candidate for an advisory Continue Once decision;
 * resolver and TCP-connect failures do not prove a reusable transport.
 */
export function rdpDnsFallbackProbeCanReuseTransport(errorCode: number): boolean {
  switch (errorCode) {
    case -13:
    case -14:
    case -15:
    case -16:
    case -17:
    case -18:
    case -19:
    case -20:
    case -21:
    case -22:
    case -23:
    case -24:
    case -25:
    case -36:
    case -37:
    case -38:
      return true;
    default:
      return false;
  }
}
