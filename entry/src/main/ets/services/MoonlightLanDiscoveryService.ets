/**
 * Moonlight LAN discovery through the API 23 mDNS/DNS-SD surface.
 *
 * This service owns only the short-lived discovery session.  It deliberately
 * does not write a Moonlight host, call CloudStore, or perform serverinfo or
 * pairing.  A caller must carry the returned candidate through its own
 * owner/generation contract before starting the next step.
 */
import { common } from '@kit.AbilityKit';
import { mdns } from '@kit.NetworkKit';
import {
  EndpointAddressResult,
  parseEndpointFields
} from './EndpointAddressPolicy';

export const MOONLIGHT_MDNS_SERVICE_TYPE: string = '_nvstream._tcp';
export const MOONLIGHT_LAN_DISCOVERY_DEFAULT_MAX_RESULTS: number = 32;
export const MOONLIGHT_LAN_DISCOVERY_MAX_RESULTS_LIMIT: number = 64;
const MAX_SERVICE_NAME_LENGTH: number = 255;
const MAX_OWNER_ID_LENGTH: number = 128;
const MAX_TXT_ATTRIBUTES: number = 32;
const MAX_TXT_KEY_LENGTH: number = 128;
const MAX_TXT_VALUE_LENGTH: number = 1024;
const MAX_RESOLVE_ATTEMPTS_PER_SERVICE: number = 2;

export type MoonlightLanAddressFamily = 'ipv4' | 'ipv6' | 'hostname';

export interface MoonlightLanDiscoveryFence {
  ownerId: string;
  generation: number;
}

export interface MoonlightLanServiceAttribute {
  key: string;
  value: Array<number>;
}

export interface MoonlightLanDiscoveryCandidate {
  ownerId: string;
  generation: number;
  serviceType: string;
  serviceName: string;
  serverUuid: string;
  host: string;
  family: MoonlightLanAddressFamily;
  scope: string;
  interfaceName: string;
  port: number;
  attributes: Array<MoonlightLanServiceAttribute>;
}

export interface MoonlightLanDiscoveryOptions {
  maxResults?: number;
}

export type MoonlightMdnsDiscoveryStartCallback =
  (event: mdns.DiscoveryEventInfo) => void;
export type MoonlightMdnsServiceCallback =
  (serviceInfo: mdns.LocalServiceInfo) => void;

/** A narrow adapter keeps unit tests independent from the system mDNS daemon. */
export interface MoonlightMdnsDiscovery {
  onDiscoveryStart(callback: MoonlightMdnsDiscoveryStartCallback): void;
  offDiscoveryStart(callback: MoonlightMdnsDiscoveryStartCallback): void;
  onServiceFound(callback: MoonlightMdnsServiceCallback): void;
  offServiceFound(callback: MoonlightMdnsServiceCallback): void;
  onServiceLost(callback: MoonlightMdnsServiceCallback): void;
  offServiceLost(callback: MoonlightMdnsServiceCallback): void;
  startSearching(): void;
  stopSearching(): void;
}

export interface MoonlightLanMdnsPort {
  createDiscoveryService(context: common.Context, serviceType: string): MoonlightMdnsDiscovery;
  resolveLocalService(context: common.Context,
    serviceInfo: mdns.LocalServiceInfo): Promise<mdns.LocalServiceInfo>;
}

class SystemMoonlightMdnsDiscovery implements MoonlightMdnsDiscovery {
  private readonly discovery: mdns.DiscoveryService;

  constructor(discovery: mdns.DiscoveryService) {
    this.discovery = discovery;
  }

  onDiscoveryStart(callback: MoonlightMdnsDiscoveryStartCallback): void {
    this.discovery.on('discoveryStart', callback);
  }

  offDiscoveryStart(callback: MoonlightMdnsDiscoveryStartCallback): void {
    this.discovery.off('discoveryStart', callback);
  }

  onServiceFound(callback: MoonlightMdnsServiceCallback): void {
    this.discovery.on('serviceFound', callback);
  }

  offServiceFound(callback: MoonlightMdnsServiceCallback): void {
    this.discovery.off('serviceFound', callback);
  }

  onServiceLost(callback: MoonlightMdnsServiceCallback): void {
    this.discovery.on('serviceLost', callback);
  }

  offServiceLost(callback: MoonlightMdnsServiceCallback): void {
    this.discovery.off('serviceLost', callback);
  }

  startSearching(): void {
    this.discovery.startSearchingMDNS();
  }

  stopSearching(): void {
    this.discovery.stopSearchingMDNS();
  }
}

class SystemMoonlightLanMdnsPort implements MoonlightLanMdnsPort {
  createDiscoveryService(context: common.Context, serviceType: string): MoonlightMdnsDiscovery {
    return new SystemMoonlightMdnsDiscovery(mdns.createDiscoveryService(context, serviceType));
  }

  resolveLocalService(context: common.Context,
    serviceInfo: mdns.LocalServiceInfo): Promise<mdns.LocalServiceInfo> {
    return mdns.resolveLocalService(context, serviceInfo);
  }
}

const SYSTEM_MOONLIGHT_MDNS_PORT: MoonlightLanMdnsPort =
  new SystemMoonlightLanMdnsPort();

function hasControlCharacter(value: string): boolean {
  for (let index = 0; index < value.length; index++) {
    const code: number = value.charCodeAt(index);
    if (code < 0x20 || code === 0x7f) {
      return true;
    }
  }
  return false;
}

function normalizeBoundedText(value: string, maximum: number): string {
  if (typeof value !== 'string') {
    return '';
  }
  const normalized: string = value.trim();
  if (normalized.length < 1 || normalized.length > maximum || hasControlCharacter(normalized)) {
    return '';
  }
  return normalized;
}

function normalizeServiceType(value: string): string {
  const normalized: string = normalizeBoundedText(value, MAX_SERVICE_NAME_LENGTH);
  return normalized.toLowerCase();
}

function normalizeServiceName(value: string): string {
  return normalizeBoundedText(value, MAX_SERVICE_NAME_LENGTH);
}

function validOwnerId(value: string): boolean {
  return normalizeBoundedText(value, MAX_OWNER_ID_LENGTH) === value;
}

function validGeneration(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

function validPort(value: number | undefined): boolean {
  return value !== undefined && Number.isSafeInteger(value) && value >= 1 && value <= 65535;
}

function resolvePort(serviceInfo: mdns.LocalServiceInfo,
  fallback: mdns.LocalServiceInfo | null = null): number | undefined {
  if (validPort(serviceInfo.port)) {
    return serviceInfo.port;
  }
  if (serviceInfo.host !== undefined && validPort(serviceInfo.host.port)) {
    return serviceInfo.host.port;
  }
  if (fallback !== null) {
    if (validPort(fallback.port)) {
      return fallback.port;
    }
    if (fallback.host !== undefined && validPort(fallback.host.port)) {
      return fallback.host.port;
    }
  }
  return undefined;
}

function resolveHost(serviceInfo: mdns.LocalServiceInfo,
  fallback: mdns.LocalServiceInfo | null = null): mdns.NetAddress | undefined {
  if (serviceInfo.host !== undefined &&
      normalizeBoundedText(serviceInfo.host.address, MAX_SERVICE_NAME_LENGTH) !== '') {
    return serviceInfo.host;
  }
  if (fallback !== null && fallback.host !== undefined &&
      normalizeBoundedText(fallback.host.address, MAX_SERVICE_NAME_LENGTH) !== '') {
    return fallback.host;
  }
  return undefined;
}

function resolveFamily(host: mdns.NetAddress): MoonlightLanAddressFamily {
  if (host.family === 2) {
    return 'ipv6';
  }
  if (host.family === 1) {
    return 'ipv4';
  }
  return host.address.indexOf(':') >= 0 ? 'ipv6' :
    (host.address.indexOf('.') >= 0 ? 'ipv4' : 'hostname');
}

function copyAttributes(serviceInfo: mdns.LocalServiceInfo): Array<MoonlightLanServiceAttribute> {
  const attributes: Array<MoonlightLanServiceAttribute> = [];
  if (serviceInfo.serviceAttribute === undefined) {
    return attributes;
  }
  const limit: number = Math.min(serviceInfo.serviceAttribute.length, MAX_TXT_ATTRIBUTES);
  for (let index = 0; index < limit; index++) {
    const attribute: mdns.ServiceAttribute = serviceInfo.serviceAttribute[index];
    const key: string = normalizeBoundedText(attribute.key, MAX_TXT_KEY_LENGTH);
    if (key === '') {
      continue;
    }
    const value: Array<number> = [];
    const valueLimit: number = Math.min(attribute.value.length, MAX_TXT_VALUE_LENGTH);
    for (let valueIndex = 0; valueIndex < valueLimit; valueIndex++) {
      const byte: number = attribute.value[valueIndex];
      if (Number.isSafeInteger(byte) && byte >= 0 && byte <= 255) {
        value.push(byte);
      }
    }
    attributes.push({ key: key, value: value });
  }
  return attributes;
}

function printableTxtValue(value: Array<number>): string {
  let result: string = '';
  for (let index = 0; index < value.length; index++) {
    const byte: number = value[index];
    if (byte < 0x20 || byte > 0x7e) {
      return '';
    }
    result += String.fromCharCode(byte);
  }
  return normalizeBoundedText(result, MAX_SERVICE_NAME_LENGTH);
}

function readServerUuid(attributes: Array<MoonlightLanServiceAttribute>): string {
  const acceptedKeys: Array<string> = ['uuid', 'serveruuid', 'server_uuid', 'server-id', 'id'];
  for (let index = 0; index < attributes.length; index++) {
    const key: string = attributes[index].key.toLowerCase();
    if (acceptedKeys.indexOf(key) >= 0) {
      const value: string = printableTxtValue(attributes[index].value);
      if (value !== '') {
        return value;
      }
    }
  }
  return '';
}

/**
 * Returns the stable per-scan identity for an mDNS service instance.
 * Service names are the DNS-SD instance identity; the service type is kept in
 * the key so an accidental callback from another discovery cannot collide.
 */
export function moonlightLanServiceKey(serviceInfo: mdns.LocalServiceInfo): string {
  if (serviceInfo === undefined || serviceInfo === null ||
      normalizeServiceType(serviceInfo.serviceType) !== MOONLIGHT_MDNS_SERVICE_TYPE) {
    return '';
  }
  const serviceName: string = normalizeServiceName(serviceInfo.serviceName);
  if (serviceName === '') {
    return '';
  }
  return MOONLIGHT_MDNS_SERVICE_TYPE + '|' + serviceName.toLowerCase();
}

function moonlightLanKeyPart(value: string): string {
  return value.length.toString() + ':' + value;
}

/**
 * Returns the bounded resolver-admission identity for one advertised route.
 * A DNS-SD instance can be reported once per address family or interface, so
 * the instance name alone must not tombstone its remaining IPv4/IPv6 routes.
 * Missing host/port data intentionally collapses to one instance-level key
 * until the daemon supplies enough route information to distinguish it.
 */
export function moonlightLanResolveKey(serviceInfo: mdns.LocalServiceInfo): string {
  const serviceKey: string = moonlightLanServiceKey(serviceInfo);
  if (serviceKey === '') {
    return '';
  }
  const host: mdns.NetAddress | undefined = resolveHost(serviceInfo);
  const port: number | undefined = resolvePort(serviceInfo);
  if (host === undefined) {
    return moonlightLanKeyPart(serviceKey) + '|' + moonlightLanKeyPart('') + '|' +
      moonlightLanKeyPart('') + '|' + moonlightLanKeyPart('') + '|' +
      moonlightLanKeyPart(port === undefined ? '' : port.toString());
  }
  const rawHost: string = normalizeBoundedText(host.address, MAX_SERVICE_NAME_LENGTH);
  const advertisedFamily: MoonlightLanAddressFamily = resolveFamily(host);
  let canonicalHost: string = rawHost.toLowerCase();
  let scope: string = '';
  if (rawHost !== '') {
    const parsed: EndpointAddressResult = parseEndpointFields(
      rawHost, port === undefined ? 1 : port);
    if (parsed.ok) {
      canonicalHost = parsed.endpoint.canonicalHost;
      scope = parsed.endpoint.scope;
    }
  }
  return moonlightLanKeyPart(serviceKey) + '|' +
    moonlightLanKeyPart(advertisedFamily) + '|' +
    moonlightLanKeyPart(canonicalHost) + '|' +
    moonlightLanKeyPart(scope) + '|' +
    moonlightLanKeyPart(port === undefined ? '' : port.toString());
}

export function moonlightLanDiscoveryFenceEquals(
  first: MoonlightLanDiscoveryFence | null,
  second: MoonlightLanDiscoveryFence | null
): boolean {
  return first !== null && second !== null && first.ownerId === second.ownerId &&
    first.generation === second.generation;
}

/**
 * Converts a discovered and resolved mDNS record into a bounded candidate.
 * A resolve response may omit fields already present in the found event, so
 * those fields are used as a same-instance fallback.  A non-empty mismatched
 * type/name is rejected to prevent a late or cross-service response from being
 * attached to the wrong host.
 */
export function resolveMoonlightLanCandidate(
  fence: MoonlightLanDiscoveryFence,
  discovered: mdns.LocalServiceInfo,
  resolved: mdns.LocalServiceInfo
): MoonlightLanDiscoveryCandidate | null {
  if (!validOwnerId(fence.ownerId) || !validGeneration(fence.generation)) {
    return null;
  }
  if (moonlightLanServiceKey(discovered) === '') {
    return null;
  }
  const resolvedType: string = normalizeBoundedText(resolved.serviceType, MAX_SERVICE_NAME_LENGTH);
  if (resolvedType !== '' && normalizeServiceType(resolvedType) !== MOONLIGHT_MDNS_SERVICE_TYPE) {
    return null;
  }
  const discoveredName: string = normalizeServiceName(discovered.serviceName);
  const resolvedName: string = normalizeServiceName(resolved.serviceName);
  if (resolvedName !== '' && resolvedName.toLowerCase() !== discoveredName.toLowerCase()) {
    return null;
  }
  const host: mdns.NetAddress | undefined = resolveHost(resolved, discovered);
  const port: number | undefined = resolvePort(resolved, discovered);
  if (host === undefined || !validPort(port)) {
    return null;
  }
  const rawHost: string = normalizeBoundedText(host.address, MAX_SERVICE_NAME_LENGTH);
  const parsed: EndpointAddressResult = parseEndpointFields(rawHost, port as number);
  if (!parsed.ok || parsed.endpoint.scopeKind === 'numeric') {
    return null;
  }
  const advertisedFamily: MoonlightLanAddressFamily = resolveFamily(host);
  if (advertisedFamily !== 'hostname' && parsed.endpoint.family !== advertisedFamily) {
    return null;
  }
  const attributes: Array<MoonlightLanServiceAttribute> =
    resolved.serviceAttribute === undefined ? copyAttributes(discovered) : copyAttributes(resolved);
  return {
    ownerId: fence.ownerId,
    generation: fence.generation,
    serviceType: MOONLIGHT_MDNS_SERVICE_TYPE,
    serviceName: discoveredName,
    serverUuid: readServerUuid(attributes),
    host: parsed.endpoint.canonicalHost,
    family: parsed.endpoint.family,
    scope: parsed.endpoint.scope,
    interfaceName: parsed.endpoint.scopeKind === 'interface' ? parsed.endpoint.scope : '',
    port: port as number,
    attributes: attributes
  };
}

function normalizedMaxResults(options: MoonlightLanDiscoveryOptions): number {
  const requested: number | undefined = options.maxResults;
  if (requested === undefined || !Number.isSafeInteger(requested) || requested < 1) {
    return MOONLIGHT_LAN_DISCOVERY_DEFAULT_MAX_RESULTS;
  }
  return Math.min(requested, MOONLIGHT_LAN_DISCOVERY_MAX_RESULTS_LIMIT);
}

export class MoonlightLanDiscoveryService {
  private readonly context: common.Context;
  private readonly mdnsPort: MoonlightLanMdnsPort;
  private readonly maxResults: number;
  private discovery: MoonlightMdnsDiscovery | null = null;
  private discoveryStartHandler: MoonlightMdnsDiscoveryStartCallback | null = null;
  private serviceFoundHandler: MoonlightMdnsServiceCallback | null = null;
  private serviceLostHandler: MoonlightMdnsServiceCallback | null = null;
  private activeFence: MoonlightLanDiscoveryFence | null = null;
  private runToken: number = 0;
  private running: boolean = false;
  private acceptedKeys: Set<string> = new Set<string>();
  private attemptedRouteKeys: Set<string> = new Set<string>();
  private resolvingRouteKeys: Set<string> = new Set<string>();

  constructor(context: common.Context, mdnsPort: MoonlightLanMdnsPort = SYSTEM_MOONLIGHT_MDNS_PORT,
    options: MoonlightLanDiscoveryOptions = {}) {
    this.context = context;
    this.mdnsPort = mdnsPort;
    this.maxResults = normalizedMaxResults(options);
  }

  /** Starts one bounded scan. Starting again fences and cleans the old scan first. */
  start(ownerId: string, generation: number,
    onCandidate: (candidate: MoonlightLanDiscoveryCandidate) => void): boolean {
    this.stop();
    if (!validOwnerId(ownerId) || !validGeneration(generation) || onCandidate === undefined) {
      return false;
    }

    this.activeFence = { ownerId: ownerId, generation: generation };
    this.running = true;
    const runToken: number = this.runToken;
    const fence: MoonlightLanDiscoveryFence = { ownerId: ownerId, generation: generation };
    const candidateCallback: (candidate: MoonlightLanDiscoveryCandidate) => void = onCandidate;
    try {
      const discovery: MoonlightMdnsDiscovery =
        this.mdnsPort.createDiscoveryService(this.context, MOONLIGHT_MDNS_SERVICE_TYPE);
      this.discovery = discovery;
      this.discoveryStartHandler = (_event: mdns.DiscoveryEventInfo): void => {
        // The system callback is intentionally informational.  Results are
        // accepted only after serviceFound + resolve pass the exact fence.
      };
      this.serviceFoundHandler = (serviceInfo: mdns.LocalServiceInfo): void => {
        this.handleServiceFound(serviceInfo, fence, runToken, candidateCallback);
      };
      this.serviceLostHandler = (_serviceInfo: mdns.LocalServiceInfo): void => {
        // A scan is a snapshot.  Lost callbacks do not mutate a candidate
        // already handed to the owner and are still unregistered on stop.
      };
      discovery.onDiscoveryStart(this.discoveryStartHandler);
      discovery.onServiceFound(this.serviceFoundHandler);
      discovery.onServiceLost(this.serviceLostHandler);
      discovery.startSearching();
      return true;
    } catch (_error) {
      this.stop();
      return false;
    }
  }

  /** Stops searching, unregisters every callback, and fences all late resolves. */
  stop(): void {
    const discovery: MoonlightMdnsDiscovery | null = this.discovery;
    const startHandler: MoonlightMdnsDiscoveryStartCallback | null = this.discoveryStartHandler;
    const foundHandler: MoonlightMdnsServiceCallback | null = this.serviceFoundHandler;
    const lostHandler: MoonlightMdnsServiceCallback | null = this.serviceLostHandler;

    this.running = false;
    this.activeFence = null;
    this.runToken++;
    this.discovery = null;
    this.discoveryStartHandler = null;
    this.serviceFoundHandler = null;
    this.serviceLostHandler = null;
    this.acceptedKeys.clear();
    this.attemptedRouteKeys.clear();
    this.resolvingRouteKeys.clear();

    if (discovery === null) {
      return;
    }
    try {
      if (startHandler !== null) {
        discovery.offDiscoveryStart(startHandler);
      }
    } catch (_error) {
      // Continue unregistering the remaining callbacks.
    }
    try {
      if (foundHandler !== null) {
        discovery.offServiceFound(foundHandler);
      }
    } catch (_error) {
      // Continue unregistering the remaining callbacks.
    }
    try {
      if (lostHandler !== null) {
        discovery.offServiceLost(lostHandler);
      }
    } catch (_error) {
      // Continue to stop the daemon even when an individual off call fails.
    }
    try {
      discovery.stopSearching();
    } catch (_error) {
      // Best effort cleanup; the fence above still blocks late callbacks.
    }
  }

  isRunning(): boolean {
    return this.running;
  }

  currentFence(): MoonlightLanDiscoveryFence | null {
    if (this.activeFence === null) {
      return null;
    }
    return { ownerId: this.activeFence.ownerId, generation: this.activeFence.generation };
  }

  acceptedResultCount(): number {
    return this.acceptedKeys.size;
  }

  private isCurrent(fence: MoonlightLanDiscoveryFence, runToken: number): boolean {
    return this.running && this.runToken === runToken &&
      moonlightLanDiscoveryFenceEquals(this.activeFence, fence);
  }

  private handleServiceFound(serviceInfo: mdns.LocalServiceInfo,
    fence: MoonlightLanDiscoveryFence, runToken: number,
    candidateCallback: (candidate: MoonlightLanDiscoveryCandidate) => void): void {
    if (!this.isCurrent(fence, runToken)) {
      return;
    }
    const routeKey: string = moonlightLanResolveKey(serviceInfo);
    if (routeKey === '' || this.resolvingRouteKeys.has(routeKey) ||
        this.attemptedRouteKeys.has(routeKey) ||
        this.acceptedKeys.size >= this.maxResults ||
        this.attemptedRouteKeys.size >= this.maxResults) {
      return;
    }
    // A scan spends its bounded route budget on first admission. Failed
    // resolves remain tombstoned so repeated daemon events cannot create an
    // unbounded sequence of system resolver requests.
    this.attemptedRouteKeys.add(routeKey);
    this.resolvingRouteKeys.add(routeKey);
    this.resolveService(serviceInfo, routeKey, fence, runToken, candidateCallback, 1);
  }

  private resolveService(serviceInfo: mdns.LocalServiceInfo, routeKey: string,
    fence: MoonlightLanDiscoveryFence, runToken: number,
    candidateCallback: (candidate: MoonlightLanDiscoveryCandidate) => void,
    attempt: number): void {
    if (!this.isCurrent(fence, runToken)) {
      return;
    }
    let resolvePromise: Promise<mdns.LocalServiceInfo>;
    try {
      resolvePromise = this.mdnsPort.resolveLocalService(this.context, serviceInfo);
    } catch (_error) {
      if (attempt < MAX_RESOLVE_ATTEMPTS_PER_SERVICE) {
        this.resolveService(serviceInfo, routeKey, fence, runToken,
          candidateCallback, attempt + 1);
      } else {
        this.resolvingRouteKeys.delete(routeKey);
      }
      return;
    }
    resolvePromise.then((resolved: mdns.LocalServiceInfo): void => {
      if (!this.isCurrent(fence, runToken)) {
        return;
      }
      const candidate: MoonlightLanDiscoveryCandidate | null =
        resolveMoonlightLanCandidate(fence, serviceInfo, resolved);
      if (candidate === null) {
        this.resolvingRouteKeys.delete(routeKey);
        return;
      }
      const scope: string = candidate.scope === '' ? '' : '%' + candidate.scope;
      const candidateKey: string = (candidate.serverUuid === '' ? candidate.serviceName :
        candidate.serverUuid) + '|' + candidate.family + '|' +
        candidate.host + scope + '|' + candidate.port.toString();
      this.resolvingRouteKeys.delete(routeKey);
      if (this.acceptedKeys.has(candidateKey) || this.acceptedKeys.size >= this.maxResults) {
        return;
      }
      this.acceptedKeys.add(candidateKey);
      try {
        candidateCallback(candidate);
      } catch (_error) {
        // A consumer callback cannot break mDNS cleanup or the active scan.
      }
    }).catch((_error: Error): void => {
      if (!this.isCurrent(fence, runToken)) {
        return;
      }
      if (attempt >= MAX_RESOLVE_ATTEMPTS_PER_SERVICE) {
        this.resolvingRouteKeys.delete(routeKey);
      }
      if (attempt < MAX_RESOLVE_ATTEMPTS_PER_SERVICE) {
        this.resolveService(serviceInfo, routeKey, fence, runToken,
          candidateCallback, attempt + 1);
      }
    });
  }
}
