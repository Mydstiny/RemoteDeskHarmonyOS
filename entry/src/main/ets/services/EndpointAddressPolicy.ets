/**
 * Shared endpoint parsing and formatting policy.
 *
 * Persist canonicalHost without IPv6 brackets and keep port/scope separate.
 * Brackets belong only to display/authority formatting. Runtime DNS results
 * are intentionally outside this value object and must never be persisted.
 */

export type EndpointAddressFamily = 'hostname' | 'ipv4' | 'ipv6';

export type EndpointAddressError =
  'none' | 'empty' | 'invalid_syntax' | 'invalid_hostname' | 'invalid_ipv4' |
  'invalid_ipv6' | 'invalid_port' | 'scope_required' | 'scope_not_allowed' |
  'scope_not_portable' | 'address_not_connectable';

export const ENDPOINT_ADDRESS_VERSION: number = 2;

export class EndpointAddress {
  version: number = ENDPOINT_ADDRESS_VERSION;
  canonicalHost: string = '';
  family: EndpointAddressFamily = 'hostname';
  port: number = 0;
  scope: string = '';
}

export class EndpointAddressResult {
  ok: boolean = false;
  endpoint: EndpointAddress = new EndpointAddress();
  error: EndpointAddressError = 'invalid_syntax';
}

function failedEndpoint(error: EndpointAddressError): EndpointAddressResult {
  const result = new EndpointAddressResult();
  result.error = error;
  return result;
}

function successfulEndpoint(
  canonicalHost: string,
  family: EndpointAddressFamily,
  scope: string = ''
): EndpointAddressResult {
  const result = new EndpointAddressResult();
  result.ok = true;
  result.error = 'none';
  result.endpoint.canonicalHost = canonicalHost;
  result.endpoint.family = family;
  result.endpoint.scope = scope;
  return result;
}

function validPort(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 1 && value <= 65535;
}

function parsePort(value: string): number {
  if (!/^[0-9]{1,5}$/.test(value)) { return 0; }
  const parsed: number = Number(value);
  return validPort(parsed) ? parsed : 0;
}

function ipv4Octets(value: string): number[] | null {
  const parts: string[] = value.split('.');
  if (parts.length !== 4) { return null; }
  const octets: number[] = [];
  for (let index = 0; index < parts.length; index++) {
    if (!/^(0|[1-9][0-9]{0,2})$/.test(parts[index])) { return null; }
    const octet: number = Number(parts[index]);
    if (octet < 0 || octet > 255) { return null; }
    octets.push(octet);
  }
  return octets;
}

function canonicalIpv4(octets: number[]): string {
  return octets[0].toString() + '.' + octets[1].toString() + '.' +
    octets[2].toString() + '.' + octets[3].toString();
}

function expandEmbeddedIpv4(value: string): string {
  if (value.indexOf('.') < 0) { return value; }
  const lastColon: number = value.lastIndexOf(':');
  if (lastColon < 0) { return ''; }
  const octets: number[] | null = ipv4Octets(value.substring(lastColon + 1));
  if (octets === null) { return ''; }
  const high: number = octets[0] * 256 + octets[1];
  const low: number = octets[2] * 256 + octets[3];
  return value.substring(0, lastColon + 1) + high.toString(16) + ':' + low.toString(16);
}

function parseIpv6Words(value: string): number[] | null {
  if (value.length < 2 || value.length > 45 || value.indexOf(':') < 0 ||
      value.indexOf(':::') >= 0 || !/^[0-9a-fA-F:.]+$/.test(value)) {
    return null;
  }
  const expandedV4: string = expandEmbeddedIpv4(value);
  if (expandedV4 === '') { return null; }
  const doubleColon: number = expandedV4.indexOf('::');
  if (doubleColon >= 0 && expandedV4.indexOf('::', doubleColon + 2) >= 0) {
    return null;
  }
  const leftText: string = doubleColon >= 0 ? expandedV4.substring(0, doubleColon) : expandedV4;
  const rightText: string = doubleColon >= 0 ? expandedV4.substring(doubleColon + 2) : '';
  const left: string[] = leftText === '' ? [] : leftText.split(':');
  const right: string[] = rightText === '' ? [] : rightText.split(':');
  const words: number[] = [];
  for (let index = 0; index < left.length; index++) {
    if (!/^[0-9a-fA-F]{1,4}$/.test(left[index])) { return null; }
    words.push(parseInt(left[index], 16));
  }
  if (doubleColon >= 0) {
    const omitted: number = 8 - left.length - right.length;
    if (omitted < 1) { return null; }
    for (let index = 0; index < omitted; index++) { words.push(0); }
  }
  for (let index = 0; index < right.length; index++) {
    if (!/^[0-9a-fA-F]{1,4}$/.test(right[index])) { return null; }
    words.push(parseInt(right[index], 16));
  }
  if (doubleColon < 0 && left.length !== 8) { return null; }
  return words.length === 8 ? words : null;
}

function ipv6IsUnspecified(words: number[]): boolean {
  for (let index = 0; index < words.length; index++) {
    if (words[index] !== 0) { return false; }
  }
  return true;
}

function ipv6IsMappedIpv4(words: number[]): boolean {
  for (let index = 0; index < 5; index++) {
    if (words[index] !== 0) { return false; }
  }
  return words[5] === 0xffff;
}

function ipv6IsLinkLocal(words: number[]): boolean {
  return (words[0] & 0xffc0) === 0xfe80;
}

function ipv6IsMulticast(words: number[]): boolean {
  return (words[0] & 0xff00) === 0xff00;
}

function canonicalIpv6(words: number[]): string {
  let bestStart: number = -1;
  let bestLength: number = 0;
  let index: number = 0;
  while (index < words.length) {
    if (words[index] !== 0) {
      index += 1;
      continue;
    }
    const start: number = index;
    while (index < words.length && words[index] === 0) { index += 1; }
    const length: number = index - start;
    if (length >= 2 && length > bestLength) {
      bestStart = start;
      bestLength = length;
    }
  }
  if (bestStart < 0) {
    const plain: string[] = [];
    for (let word = 0; word < words.length; word++) {
      plain.push(words[word].toString(16));
    }
    return plain.join(':');
  }
  let canonical: string = '';
  index = 0;
  while (index < words.length) {
    if (index === bestStart) {
      canonical += '::';
      index += bestLength;
      continue;
    }
    if (canonical !== '' && !canonical.endsWith(':')) { canonical += ':'; }
    canonical += words[index].toString(16);
    index += 1;
  }
  return canonical;
}

function canonicalHostname(value: string): string {
  let hostname: string = value;
  if (hostname.endsWith('.')) { hostname = hostname.substring(0, hostname.length - 1); }
  if (hostname.length < 1 || hostname.length > 253 || hostname.startsWith('.') ||
      hostname.endsWith('.') || hostname.indexOf('..') >= 0 ||
      !/^[A-Za-z0-9.-]+$/.test(hostname)) {
    return '';
  }
  const labels: string[] = hostname.split('.');
  for (let index = 0; index < labels.length; index++) {
    const label: string = labels[index];
    if (label.length < 1 || label.length > 63 || label.startsWith('-') ||
        label.endsWith('-') || !/^[A-Za-z0-9-]+$/.test(label)) {
      return '';
    }
  }
  return hostname.toLowerCase();
}

function invalidEndpointCharacters(value: string): boolean {
  return value.indexOf('://') >= 0 || value.indexOf('/') >= 0 ||
    value.indexOf('\\') >= 0 || value.indexOf('@') >= 0 ||
    value.indexOf('?') >= 0 || value.indexOf('#') >= 0 || /\s/.test(value) ||
    /[\u0000-\u001F\u007F]/.test(value);
}

function parseScope(value: string): string {
  if (value === '' || /^[0-9]+$/.test(value) || value.length > 32 ||
      !/^[A-Za-z][A-Za-z0-9_.-]*$/.test(value)) {
    return '';
  }
  return value;
}

export function parseEndpointHost(input: string): EndpointAddressResult {
  const source: string = input.trim();
  if (source === '') { return failedEndpoint('empty'); }
  if (invalidEndpointCharacters(source)) { return failedEndpoint('invalid_syntax'); }

  let host: string = source;
  if (source.startsWith('[')) {
    if (!source.endsWith(']') || source.indexOf(']') !== source.length - 1) {
      return failedEndpoint('invalid_syntax');
    }
    host = source.substring(1, source.length - 1);
  } else if (source.indexOf('[') >= 0 || source.indexOf(']') >= 0) {
    return failedEndpoint('invalid_syntax');
  }

  let scope: string = '';
  const percent: number = host.indexOf('%');
  if (percent >= 0) {
    if (host.indexOf('%', percent + 1) >= 0) { return failedEndpoint('invalid_syntax'); }
    scope = parseScope(host.substring(percent + 1));
    if (scope === '') { return failedEndpoint('scope_not_portable'); }
    host = host.substring(0, percent);
  }

  const octets: number[] | null = ipv4Octets(host);
  if (octets !== null) {
    if (scope !== '') { return failedEndpoint('scope_not_allowed'); }
    return successfulEndpoint(canonicalIpv4(octets), 'ipv4');
  }

  const words: number[] | null = parseIpv6Words(host);
  if (words !== null) {
    if (ipv6IsUnspecified(words) || ipv6IsMappedIpv4(words) || ipv6IsMulticast(words)) {
      return failedEndpoint('address_not_connectable');
    }
    if (ipv6IsLinkLocal(words) && scope === '') { return failedEndpoint('scope_required'); }
    if (!ipv6IsLinkLocal(words) && scope !== '') { return failedEndpoint('scope_not_allowed'); }
    return successfulEndpoint(canonicalIpv6(words), 'ipv6', scope);
  }

  if (host.indexOf(':') >= 0) { return failedEndpoint('invalid_ipv6'); }
  if (/^[0-9.]+$/.test(host) && host.indexOf('.') >= 0) {
    return failedEndpoint('invalid_ipv4');
  }
  if (scope !== '') { return failedEndpoint('scope_not_allowed'); }
  const hostname: string = canonicalHostname(host);
  return hostname === '' ? failedEndpoint('invalid_hostname') :
    successfulEndpoint(hostname, 'hostname');
}

export function parseEndpointAuthority(
  input: string,
  defaultPort: number
): EndpointAddressResult {
  if (!validPort(defaultPort)) { return failedEndpoint('invalid_port'); }
  const source: string = input.trim();
  if (source === '') { return failedEndpoint('empty'); }
  let hostText: string = source;
  let port: number = defaultPort;
  if (source.startsWith('[')) {
    const close: number = source.indexOf(']');
    if (close <= 1) { return failedEndpoint('invalid_syntax'); }
    hostText = source.substring(0, close + 1);
    const suffix: string = source.substring(close + 1);
    if (suffix !== '') {
      if (!suffix.startsWith(':')) { return failedEndpoint('invalid_syntax'); }
      port = parsePort(suffix.substring(1));
      if (port === 0) { return failedEndpoint('invalid_port'); }
    }
  } else {
    const firstColon: number = source.indexOf(':');
    const lastColon: number = source.lastIndexOf(':');
    if (firstColon > 0 && firstColon === lastColon) {
      hostText = source.substring(0, firstColon);
      port = parsePort(source.substring(firstColon + 1));
      if (port === 0) { return failedEndpoint('invalid_port'); }
    }
  }
  const parsed: EndpointAddressResult = parseEndpointHost(hostText);
  if (!parsed.ok) { return parsed; }
  parsed.endpoint.port = port;
  return parsed;
}

export function endpointTransportHost(endpoint: EndpointAddress): string {
  if (endpoint.family !== 'ipv6' || endpoint.scope === '') {
    return endpoint.canonicalHost;
  }
  return endpoint.canonicalHost + '%' + endpoint.scope;
}

export function formatEndpointHostPort(endpoint: EndpointAddress): string {
  const host: string = endpointTransportHost(endpoint);
  if (endpoint.port <= 0) { return host; }
  return endpoint.family === 'ipv6' ? '[' + host + ']:' + endpoint.port.toString() :
    host + ':' + endpoint.port.toString();
}

function lengthPrefixed(value: string): string {
  return value.length.toString() + ':' + value;
}

/** The caller supplies an already validated canonical TLS/host-key name. */
export function endpointIdentityV2(
  endpoint: EndpointAddress,
  canonicalServerName: string = ''
): string {
  return 'endpoint-v2|family=' + lengthPrefixed(endpoint.family) +
    '|host=' + lengthPrefixed(endpoint.canonicalHost) +
    '|scope=' + lengthPrefixed(endpoint.scope) +
    '|port=' + endpoint.port.toString() +
    '|server=' + lengthPrefixed(canonicalServerName);
}
