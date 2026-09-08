import { RemoteHost, RdpEffectiveIdentity, normalizeRdpAuthMode,
  normalizeRdpEndpointMode, rdpRouteIdentity } from '../../model/RemoteHost';

/** Non-secret identity only. Construct from the actual native credential pair;
 * never read a password, hash, certificate trust decision or native handle. */
export interface ProRdpConnectionIdentity {
  route: string;
  authMode: string;
  username: string;
  domain: string;
}

function safeText(value: Object, limit: number, empty: boolean): boolean {
  return typeof value === 'string' && value.length <= limit &&
    (empty || value.trim().length > 0) &&
    !/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/.test(value);
}

export function validProRdpConnectionIdentity(value: Object): boolean {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) { return false; }
  const keys: string[] = Object.keys(value);
  if (keys.length !== 4 || keys.some((key: string): boolean =>
    ['route', 'authMode', 'username', 'domain'].indexOf(key) < 0)) { return false; }
  const identity = value as ProRdpConnectionIdentity;
  return safeText(identity.route, 4096, false) && identity.route.startsWith('rdp-route-v2|') &&
    ['password', 'blank_password', 'restricted_admin'].indexOf(identity.authMode) >= 0 &&
    safeText(identity.username, 256, false) && safeText(identity.domain, 256, true);
}

export function copyProRdpConnectionIdentity(value: ProRdpConnectionIdentity): ProRdpConnectionIdentity {
  return { route: value.route, authMode: value.authMode, username: value.username, domain: value.domain };
}

/** Match the canonical local transport before authentication, including TLS
 * server names and Gateway transport. Unknown/bastion routes do not fall back. */
export function proRdpContinuationRoute(host: RemoteHost): string | null {
  if (host.protocol !== 'rdp' || host.id.length === 0) { return null; }
  const mode = normalizeRdpEndpointMode(host.rdpEndpointMode, host.gatewayHost);
  if (['direct_rdp', 'transparent_tcp_rdp', 'microsoft_rd_gateway'].indexOf(mode) < 0) { return null; }
  const route = rdpRouteIdentity(host);
  return safeText(route, 4096, false) ? route : null;
}

export function describeProRdpConnectionIdentity(host: RemoteHost,
  credentials: RdpEffectiveIdentity): ProRdpConnectionIdentity | null {
  const route = proRdpContinuationRoute(host);
  if (route === null) { return null; }
  const result: ProRdpConnectionIdentity = { route, authMode: normalizeRdpAuthMode(host.rdpAuthMode),
    username: credentials.username, domain: credentials.domain };
  return validProRdpConnectionIdentity(result) ? result : null;
}

export function proRdpConnectionRouteMatches(host: RemoteHost, identity: ProRdpConnectionIdentity): boolean {
  return validProRdpConnectionIdentity(identity) && proRdpContinuationRoute(host) === identity.route &&
    normalizeRdpAuthMode(host.rdpAuthMode) === identity.authMode;
}

export function sameProRdpConnectionIdentity(a: ProRdpConnectionIdentity, b: ProRdpConnectionIdentity): boolean {
  return a.route === b.route && a.authMode === b.authMode && a.username === b.username && a.domain === b.domain;
}
