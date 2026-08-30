/** Address provenance and refresh rules shared by RDP and RustDesk LAN add flows. */
import { EndpointAddressResult, parseEndpointHost } from './EndpointAddressPolicy';

export type LanHostAddressMode = 'manual' | 'static' | 'dynamic';

/** Device-local namespace for complete dynamic LAN host records. */
export const DYNAMIC_LAN_HOST_EXTENSION_TABLE: string = 'dynamiclanhosts';

export interface LanHostAddressView {
  protocol: string;
  host?: string;
  lanAddressMode: string;
  lanDiscoveryIdentity: string;
  lanLastResolvedAt: number;
}

export interface LanHostRefreshCandidate {
  protocol: string;
  identity: string;
  host: string;
  port: number;
  observedAt: number;
}

export function normalizeLanHostAddressMode(value: string | undefined): LanHostAddressMode {
  if (value === 'static' || value === 'dynamic') { return value; }
  return 'manual';
}

export function normalizeLanDiscoveryIdentity(value: string): string {
  return value.trim().toLowerCase();
}

/** Interface names are device routing state and cannot leave this device. */
export function sshEndpointUsesDeviceLocalScope(protocol: string,
  host: string | undefined): boolean {
  if (protocol !== 'ssh' || host === undefined || host.trim() === '') { return false; }
  const endpoint: EndpointAddressResult = parseEndpointHost(host.trim());
  return endpoint.ok && endpoint.endpoint.family === 'ipv6' &&
    endpoint.endpoint.scopeKind === 'interface' && endpoint.endpoint.scope !== '';
}

/** Fail closed when inspecting an untrusted cloud/backup row before parsing. */
export function remoteHostEndpointIsDevicePrivateForTransfer(protocol: string,
  host: string | undefined): boolean {
  return (protocol === 'rdp' || protocol === 'ssh' || protocol === 'rustdesk') &&
    host !== undefined && host.indexOf('%') >= 0;
}

function lanDiscoveryIdentityKey(protocol: string, value: string): string {
  const trimmed: string = value.trim();
  // RDP SHA-256 fingerprints are hexadecimal and case-insensitive. RustDesk
  // peer IDs are opaque identities and must remain an exact, case-sensitive
  // match (custom IDs are not guaranteed to be numeric).
  return protocol === 'rdp' ? trimmed.toLowerCase() : trimmed;
}

export function lanHostUsesDynamicAddressStorage(host: LanHostAddressView): boolean {
  return normalizeLanHostAddressMode(host.lanAddressMode) === 'dynamic';
}

export function lanHostUsesLocalOnlyStorage(host: LanHostAddressView): boolean {
  return lanHostUsesDynamicAddressStorage(host) ||
    sshEndpointUsesDeviceLocalScope(host.protocol, host.host);
}

export function lanHostLocalOnlyStorageIsValid(host: LanHostAddressView): boolean {
  if (lanHostUsesDynamicAddressStorage(host)) {
    return lanHostCanSelectDynamic(host.protocol, host.lanDiscoveryIdentity);
  }
  return sshEndpointUsesDeviceLocalScope(host.protocol, host.host);
}

export function lanHostCanSelectDynamic(protocol: string, identity: string): boolean {
  return (protocol === 'rdp' || protocol === 'rustdesk') &&
    identity.trim() !== '';
}

export function lanHostNeedsAddressRefresh(
  host: LanHostAddressView,
  nowMs: number,
  freshnessMs: number
): boolean {
  if (!lanHostUsesDynamicAddressStorage(host) ||
    !lanHostCanSelectDynamic(host.protocol, host.lanDiscoveryIdentity)) {
    return false;
  }
  if (!Number.isFinite(nowMs) || !Number.isFinite(freshnessMs) ||
    nowMs < 0 || freshnessMs < 0) {
    return false;
  }
  return !Number.isFinite(host.lanLastResolvedAt) || host.lanLastResolvedAt <= 0 ||
    nowMs - host.lanLastResolvedAt >= freshnessMs;
}

export function lanHostRefreshCandidateMatches(
  host: LanHostAddressView,
  candidate: LanHostRefreshCandidate
): boolean {
  return lanHostUsesDynamicAddressStorage(host) &&
    host.protocol === candidate.protocol &&
    lanHostCanSelectDynamic(candidate.protocol, candidate.identity) &&
    lanDiscoveryIdentityKey(host.protocol, host.lanDiscoveryIdentity) ===
      lanDiscoveryIdentityKey(candidate.protocol, candidate.identity) &&
    candidate.host.trim() !== '' && candidate.port > 0 && candidate.port <= 65535 &&
    Number.isFinite(candidate.observedAt) && candidate.observedAt > 0;
}

/** Manual entry and LAN-static records remain ordinary cloud-eligible host rows. */
export function lanHostMayUseRemoteHostsCloudTable(host: LanHostAddressView): boolean {
  return !lanHostUsesLocalOnlyStorage(host);
}

/** Dynamic LAN hosts are device-local and therefore excluded from portable backup too. */
export function lanLocalExtensionMayEnterPortableBackup(table: string): boolean {
  return table !== DYNAMIC_LAN_HOST_EXTENSION_TABLE;
}

/** Restricted Admin secrets may belong to either a cloud/static or local/dynamic host. */
export function lanRestrictedAdminSecretOwnedByScope(
  remoteHostOwned: boolean,
  dynamicHostOwnerId: string,
  currentOwnerId: string
): boolean {
  return remoteHostOwned ||
    (currentOwnerId !== '' && dynamicHostOwnerId === currentOwnerId);
}
