import {
  VncGatewayValues,
  VncHostValues,
  VncSecurityPolicy,
  VncTransport,
  VncRepeaterMode,
  validVncPort
} from './VncModelPolicy';
import { vncCanonicalJson, vncPayloadHashSha256 } from './VncRecordPolicy';
import {
  EndpointAddressResult,
  endpointTransportHost,
  parseEndpointFields
} from './EndpointAddressPolicy';

export type VncTlsEndpointOwnerType = 'host' | 'gateway';

/** Host input used by the resolver. targetId is intentionally host-owned. */
export interface VncTlsHostInput {
  id: string;
  userId: string;
  storeIdentityFingerprint: string;
  label: string;
  host: string;
  port: number;
  username: string;
  gatewayId: string;
  transport: VncTransport;
  repeaterMode: VncRepeaterMode;
  targetId: string;
  securityPolicy: VncSecurityPolicy;
  tls: boolean;
}

/** Gateway input keeps targetId only as a legacy migration field. */
export interface VncTlsGatewayInput {
  id: string;
  userId: string;
  storeIdentityFingerprint: string;
  label: string;
  transport: VncTransport;
  host: string;
  port: number;
  repeaterMode: VncRepeaterMode;
  legacyTargetId: string;
  tls: boolean;
  enabled: boolean;
}

export interface VncTrustOwner {
  ownerType: VncTlsEndpointOwnerType;
  ownerId: string;
  userId: string;
  storeIdentityFingerprint: string;
  endpointBindingFingerprint: string;
  localOnly: boolean;
}

export interface VncTlsEndpointResolution {
  ok: boolean;
  errorCode: string;
  endpointOwnerType: VncTlsEndpointOwnerType | '';
  endpointOwnerId: string;
  transport: VncTransport;
  connectHost: string;
  connectPort: number;
  serverName: string;
  tlsRequired: boolean;
  securityPolicy: VncSecurityPolicy;
  repeaterTarget: string;
  usedLegacyTargetFallback: boolean;
  endpointBindingFingerprint: string;
  trustOwner: VncTrustOwner | null;
}

function emptyResolution(host: VncTlsHostInput): VncTlsEndpointResolution {
  return {
    ok: false,
    errorCode: '',
    endpointOwnerType: '',
    endpointOwnerId: '',
    transport: host.transport,
    connectHost: '',
    connectPort: 0,
    serverName: '',
    tlsRequired: false,
    securityPolicy: host.securityPolicy,
    repeaterTarget: '',
    usedLegacyTargetFallback: false,
    endpointBindingFingerprint: '',
    trustOwner: null
  };
}

function failure(host: VncTlsHostInput, errorCode: string): VncTlsEndpointResolution {
  const result: VncTlsEndpointResolution = emptyResolution(host);
  result.errorCode = errorCode;
  return result;
}

function normalizedHost(value: string): string {
  return value.trim().toLowerCase();
}

function isSha256Fingerprint(value: string): boolean {
  return /^[0-9a-f]{64}$/.test(value.trim().toLowerCase());
}

function safeRepeaterTarget(value: string): boolean {
  const target: string = value.trim();
  if (target.length === 0 || target.length > 250) { return false; }
  for (let i = 0; i < target.length; i++) {
    const code: number = target.charCodeAt(i);
    if (code < 0x20 || code > 0x7e) { return false; }
  }
  return true;
}

function bindingFingerprint(ownerType: VncTlsEndpointOwnerType, ownerId: string,
  userId: string, storeIdentityFingerprint: string, transport: VncTransport,
  connectHost: string, connectPort: number,
  serverName: string, tlsRequired: boolean): string {
  const seed: Record<string, Object> = {};
  seed['ownerType'] = ownerType;
  seed['ownerId'] = ownerId;
  seed['userId'] = userId;
  seed['storeIdentityFingerprint'] = storeIdentityFingerprint;
  seed['transport'] = transport;
  seed['connectHost'] = normalizedHost(connectHost);
  seed['connectPort'] = connectPort;
  seed['serverName'] = normalizedHost(serverName);
  // TLS mode is part of the endpoint identity. A certificate preflight for a
  // secure endpoint must never authorize a later plaintext downgrade.
  seed['tlsRequired'] = tlsRequired;
  return vncPayloadHashSha256(vncCanonicalJson(seed));
}

function hostInputFromValues(id: string, userId: string, values: VncHostValues,
  targetId: string, storeIdentityFingerprint: string): VncTlsHostInput {
  return {
    id: id,
    userId: userId,
    storeIdentityFingerprint: storeIdentityFingerprint,
    label: values.label,
    host: values.host,
    port: values.port,
    username: values.username,
    gatewayId: values.gatewayId,
    transport: values.transport,
    repeaterMode: values.repeaterMode,
    targetId: targetId,
    securityPolicy: values.securityPolicy,
    tls: values.tls
  };
}

function gatewayInputFromValues(id: string, userId: string,
  values: VncGatewayValues, storeIdentityFingerprint: string): VncTlsGatewayInput {
  return {
    id: id,
    userId: userId,
    storeIdentityFingerprint: storeIdentityFingerprint,
    label: values.label,
    transport: values.transport,
    host: values.host,
    port: values.port,
    repeaterMode: values.repeaterMode,
    legacyTargetId: values.targetId,
    tls: values.tls,
    enabled: values.enabled
  };
}

export function vncTlsHostInput(id: string, userId: string, values: VncHostValues,
  targetId: string = '', storeIdentityFingerprint: string = ''): VncTlsHostInput {
  return hostInputFromValues(id, userId, values, targetId, storeIdentityFingerprint);
}

export function vncTlsGatewayInput(id: string, userId: string,
  values: VncGatewayValues, storeIdentityFingerprint: string = ''): VncTlsGatewayInput {
  return gatewayInputFromValues(id, userId, values, storeIdentityFingerprint);
}

/**
 * Resolve the one TLS endpoint used by preflight, trust lookup and native
 * connection. Unsupported or inconsistent combinations fail closed.
 */
export function resolveVncTlsEndpoint(host: VncTlsHostInput,
  gateway: VncTlsGatewayInput | null): VncTlsEndpointResolution {
  const hostId: string = host.id.trim();
  const userId: string = host.userId.trim();
  const hostAddress: string = host.host.trim();
  const storeIdentityFingerprint: string = host.storeIdentityFingerprint.trim().toLowerCase();
  if (hostId === '' || userId === '' || !isSha256Fingerprint(storeIdentityFingerprint)) {
    return failure(host, 'E-VNC-ENDPOINT-OWNER');
  }
  if (hostAddress === '' || !validVncPort(host.port)) {
    return failure(host, 'E-VNC-ENDPOINT-BINDING');
  }

  if (host.transport === 'direct_tcp') {
    const endpoint: EndpointAddressResult = parseEndpointFields(hostAddress, host.port);
    if (!endpoint.ok) { return failure(host, 'E-VNC-ENDPOINT-BINDING'); }
    const connectHost: string = endpointTransportHost(endpoint.endpoint);
    const serverName: string = endpoint.endpoint.canonicalHost;
    if (host.gatewayId.trim() !== '' || gateway !== null) {
      return failure(host, 'E-VNC-ENDPOINT-OWNER');
    }
    if (host.securityPolicy === 'secure_only' && !host.tls) {
      return failure(host, 'E-VNC-TLS-REQUIRED');
    }
    const ownerType: VncTlsEndpointOwnerType = 'host';
    const endpointBindingFingerprint: string = bindingFingerprint(
      ownerType, hostId, userId, storeIdentityFingerprint, host.transport,
      connectHost, host.port, serverName, host.tls);
    const result: VncTlsEndpointResolution = emptyResolution(host);
    result.ok = true;
    result.endpointOwnerType = ownerType;
    result.endpointOwnerId = hostId;
    result.connectHost = connectHost;
    result.connectPort = host.port;
    result.serverName = serverName;
    result.tlsRequired = host.tls;
    result.endpointBindingFingerprint = endpointBindingFingerprint;
    result.trustOwner = {
      ownerType: ownerType,
      ownerId: hostId,
      userId: userId,
      storeIdentityFingerprint: storeIdentityFingerprint,
      endpointBindingFingerprint: endpointBindingFingerprint,
      localOnly: endpoint.endpoint.scopeKind === 'interface'
    };
    return result;
  }

  if (host.transport !== 'ultravnc_repeater') {
    return failure(host, 'E-VNC-ENDPOINT-TRANSPORT');
  }
  if (host.gatewayId.trim() === '' || gateway === null) {
    return failure(host, 'E-VNC-ENDPOINT-OWNER');
  }
  if (gateway.id.trim() === '' || gateway.id.trim() !== host.gatewayId.trim() ||
    gateway.userId.trim() !== userId ||
    !isSha256Fingerprint(gateway.storeIdentityFingerprint) ||
    gateway.storeIdentityFingerprint.trim().toLowerCase() !== storeIdentityFingerprint) {
    return failure(host, 'E-VNC-ENDPOINT-OWNER');
  }
  if (gateway.transport !== 'ultravnc_repeater' || host.repeaterMode !== 'mode12' ||
    gateway.repeaterMode !== 'mode12') {
    return failure(host, 'E-VNC-GATEWAY-TRANSPORT');
  }
  if (!gateway.enabled) { return failure(host, 'E-VNC-GATEWAY-DISABLED'); }
  if (gateway.host.trim() === '' || !validVncPort(gateway.port)) {
    return failure(host, 'E-VNC-ENDPOINT-BINDING');
  }
  const gatewayEndpoint: EndpointAddressResult =
    parseEndpointFields(gateway.host.trim(), gateway.port);
  if (!gatewayEndpoint.ok) { return failure(host, 'E-VNC-ENDPOINT-BINDING'); }
  const gatewayConnectHost: string = endpointTransportHost(gatewayEndpoint.endpoint);
  const gatewayServerName: string = gatewayEndpoint.endpoint.canonicalHost;
  if (host.securityPolicy === 'secure_only' && !gateway.tls) {
    return failure(host, 'E-VNC-TLS-REQUIRED');
  }
  let target: string = host.targetId.trim();
  let usedLegacyTargetFallback: boolean = false;
  if (target === '') {
    target = gateway.legacyTargetId.trim();
    usedLegacyTargetFallback = target !== '';
  }
  if (!safeRepeaterTarget(target)) { return failure(host, 'E-VNC-REPEATER-TARGET'); }
  const ownerType: VncTlsEndpointOwnerType = 'gateway';
  const endpointBindingFingerprint: string = bindingFingerprint(
    ownerType, gateway.id.trim(), userId, storeIdentityFingerprint, gateway.transport,
    gatewayConnectHost,
    gateway.port, gatewayServerName, gateway.tls);
  const result: VncTlsEndpointResolution = emptyResolution(host);
  result.ok = true;
  result.endpointOwnerType = ownerType;
  result.endpointOwnerId = gateway.id.trim();
  result.connectHost = gatewayConnectHost;
  result.connectPort = gateway.port;
  result.serverName = gatewayServerName;
  result.tlsRequired = gateway.tls;
  result.repeaterTarget = target;
  result.usedLegacyTargetFallback = usedLegacyTargetFallback;
  result.endpointBindingFingerprint = endpointBindingFingerprint;
  result.trustOwner = {
    ownerType: ownerType,
    ownerId: gateway.id.trim(),
    userId: userId,
    storeIdentityFingerprint: storeIdentityFingerprint,
    endpointBindingFingerprint: endpointBindingFingerprint,
    localOnly: gatewayEndpoint.endpoint.scopeKind === 'interface'
  };
  return result;
}

export function vncTrustOwnerForEndpoint(
  endpoint: VncTlsEndpointResolution): VncTrustOwner | null {
  return endpoint.ok && endpoint.trustOwner !== null ? endpoint.trustOwner : null;
}
