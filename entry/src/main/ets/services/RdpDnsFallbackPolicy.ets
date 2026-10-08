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
 * Direct RDP routes use the HarmonyOS resolver as the connection route
 * authority whenever the configured target is a hostname.  This is broader
 * than rdpDnsFallbackEligible: the native probe may succeed while FreeRDP's
 * later resolver selects a different address family or DNS answer.  Keeping
 * the candidate enumeration in both cases makes the preflight and the live
 * socket use the same transport endpoint.
 */
export function rdpDnsFallbackShouldEnumerate(
  host: string,
  endpointMode: string
): boolean {
  if (endpointMode !== 'direct_rdp' && endpointMode !== 'transparent_tcp_rdp') {
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

/**
 * Names a Windows client resolves without DNS: a computer name (one label of
 * letters, digits and hyphens) through LLMNR / NetBIOS, or "<name>.local"
 * through multicast DNS. Only these are worth asking the local network.
 */
export function rdpLocalNameEligible(host: string): boolean {
  const name: string = host.trim().replace(/\.$/, '');
  if (name.length === 0 || name.length > 253) {
    return false;
  }
  const labels: string[] = name.split('.');
  const label = /^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/;
  if (!labels.every((part: string): boolean => label.test(part))) {
    return false;
  }
  if (labels.length === 1) {
    return !/^[0-9]+$/.test(name);
  }
  return labels[labels.length - 1].toLowerCase() === 'local';
}

/**
 * The DNS search suffixes a network hands out (DHCP option 15, e.g. "lan",
 * "corp.example.com"), applied to a computer name as mstsc does. At most
 * three, in order, without duplicates.
 */
export function rdpSearchDomainNames(host: string, domains: string): string[] {
  const name: string = host.trim().replace(/\.$/, '');
  if (name.length === 0 || name.indexOf('.') >= 0) {
    return [];
  }
  const result: string[] = [];
  const parts: string[] = domains.split(/[\s,;]+/);
  for (let index = 0; index < parts.length && result.length < 3; index++) {
    const suffix: string = parts[index].trim().replace(/^\.+|\.+$/g, '');
    if (suffix.length === 0 || !/^[A-Za-z0-9.-]+$/.test(suffix)) {
      continue;
    }
    const candidate: string = name + '.' + suffix;
    if (result.indexOf(candidate) < 0) {
      result.push(candidate);
    }
  }
  return result;
}

/**
 * A probe failure the name resolution fallback can help with: the name did
 * not resolve (-11) or no resolved address accepted the TCP connection (-12).
 * Anything later reached the RDP service and its address is already known.
 */
export function rdpDnsFallbackNeedsResolution(errorCode: number): boolean {
  return errorCode === -11 || errorCode === -12 || errorCode === -10;
}
