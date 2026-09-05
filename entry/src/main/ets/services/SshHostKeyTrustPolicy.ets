import { RemoteHost } from '../model/RemoteHost';
import { SshJumpHop } from '../types/rdpnapi';
import {
  EndpointAddressResult,
  EndpointIdentityResult,
  endpointIdentityV2,
  parseEndpointFields
} from './EndpointAddressPolicy';
import { SshProxyRuntimePlan } from './SshProxyRuntimePolicy';

export const SSH_HOST_KEY_ROUTE_IDENTITY_VERSION: number = 1;

export class SshHostKeyRouteBinding {
  ok: boolean = false;
  identity: string = '';
  code: string = 'E-SSH-HOSTKEY-ROUTE';
}

export class SshHostKeyPins {
  trusted: boolean = false;
  rawBase64: string = '';
  fingerprintSha256: string = '';
  routeIdentity: string = '';
}

class SshEndpointBinding {
  ok: boolean = false;
  identity: string = '';
}

function field(value: string): string {
  return value.length.toString() + ':' + value;
}

function endpointBinding(host: string, port: number): SshEndpointBinding {
  const result: SshEndpointBinding = new SshEndpointBinding();
  const parsed: EndpointAddressResult = parseEndpointFields(host, port, 'persisted');
  if (!parsed.ok) { return result; }
  const identity: EndpointIdentityResult = endpointIdentityV2(parsed.endpoint);
  if (!identity.ok || identity.identity.length === 0) { return result; }
  result.ok = true;
  result.identity = identity.identity;
  return result;
}

function invalidBinding(code: string): SshHostKeyRouteBinding {
  const result: SshHostKeyRouteBinding = new SshHostKeyRouteBinding();
  result.code = code;
  return result;
}

/**
 * Bind target host-key trust to the canonical endpoint and complete network
 * path. Credentials, private keys, host-key pins, and timeout tuning are not
 * route identity: they have their own lifecycle and must never enter this
 * durable, non-secret value.
 */
export function sshHostKeyRouteBinding(
  host: RemoteHost,
  plan: SshProxyRuntimePlan
): SshHostKeyRouteBinding {
  if (host.protocol !== 'ssh' || !plan.valid || plan.route.schemaVersion !== 1) {
    return invalidBinding('E-SSH-HOSTKEY-ROUTE-INVALID');
  }
  const hostEndpoint: SshEndpointBinding = endpointBinding(host.host, host.port);
  const targetEndpoint: SshEndpointBinding = endpointBinding(
    plan.route.endpointHost, plan.route.endpointPort);
  if (!hostEndpoint.ok || !targetEndpoint.ok ||
    hostEndpoint.identity !== targetEndpoint.identity) {
    return invalidBinding('E-SSH-HOSTKEY-TARGET');
  }

  let identity: string = 'ssh-hostkey-route-v' +
    SSH_HOST_KEY_ROUTE_IDENTITY_VERSION.toString() +
    '|target=' + field(targetEndpoint.identity) +
    '|type=' + field(plan.route.type) +
    '|control=' + field(plan.route.controlId || '');

  if (plan.route.type === 'http_connect' || plan.route.type === 'socks5' ||
    plan.route.type === 'frp_tcp') {
    const proxyEndpoint: SshEndpointBinding = endpointBinding(
      plan.proxyHost, plan.proxyPort);
    if (!proxyEndpoint.ok) { return invalidBinding('E-SSH-HOSTKEY-PROXY'); }
    identity += '|proxy=' + field(proxyEndpoint.identity) +
      '|proxy-user=' + field(plan.proxyUsername) +
      '|proxy-auth=' + field(plan.proxyAuthRequired ? 'required' : 'none');
  } else if (plan.route.type === 'ssh_jump') {
    if (plan.route.hops.length < 1 || plan.route.hops.length > 3) {
      return invalidBinding('E-SSH-HOSTKEY-HOPS');
    }
    identity += '|hop-count=' + plan.route.hops.length.toString();
    for (let index: number = 0; index < plan.route.hops.length; index++) {
      const hop: SshJumpHop = plan.route.hops[index];
      const hopEndpoint: SshEndpointBinding = endpointBinding(hop.host, hop.port);
      if (!hopEndpoint.ok) { return invalidBinding('E-SSH-HOSTKEY-HOP'); }
      identity += '|hop-' + index.toString() + '=' + field(hopEndpoint.identity) +
        field(hop.username) + field(hop.authMethod);
    }
  } else if (plan.route.type !== 'direct') {
    return invalidBinding('E-SSH-HOSTKEY-ROUTE-TYPE');
  }

  const result: SshHostKeyRouteBinding = new SshHostKeyRouteBinding();
  result.ok = true;
  result.identity = identity;
  result.code = '';
  return result;
}

/** Return strict target pins only when the saved decision belongs to this route. */
export function sshHostKeyPinsForRoute(
  host: RemoteHost,
  plan: SshProxyRuntimePlan
): SshHostKeyPins {
  const result: SshHostKeyPins = new SshHostKeyPins();
  const binding: SshHostKeyRouteBinding = sshHostKeyRouteBinding(host, plan);
  const rawBase64: string = host.sshHostKeyRawBase64.trim();
  const fingerprint: string = host.sshHostKeyFingerprintSha256.trim();
  if (!binding.ok || host.sshHostKeyTrustMode !== 1 || rawBase64.length === 0 ||
    fingerprint.indexOf('SHA256:') !== 0 ||
    host.sshHostKeyRouteIdentity.trim() !== binding.identity) {
    return result;
  }
  result.trusted = true;
  result.rawBase64 = rawBase64;
  result.fingerprintSha256 = fingerprint;
  result.routeIdentity = binding.identity;
  return result;
}

export function sshHostKeyTrustIsCurrent(
  host: RemoteHost,
  plan: SshProxyRuntimePlan
): boolean {
  return sshHostKeyPinsForRoute(host, plan).trusted;
}
