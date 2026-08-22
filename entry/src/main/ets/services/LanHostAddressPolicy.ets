/** Address provenance and refresh rules shared by RDP and RustDesk LAN add flows. */
export type LanHostAddressMode = 'manual' | 'static' | 'dynamic';

export interface LanHostAddressView {
  protocol: string;
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

export function lanHostUsesLocalOnlyStorage(host: LanHostAddressView): boolean {
  return normalizeLanHostAddressMode(host.lanAddressMode) === 'dynamic';
}

export function lanHostCanSelectDynamic(protocol: string, identity: string): boolean {
  return (protocol === 'rdp' || protocol === 'rustdesk') &&
    normalizeLanDiscoveryIdentity(identity) !== '';
}

export function lanHostNeedsAddressRefresh(
  host: LanHostAddressView,
  nowMs: number,
  freshnessMs: number
): boolean {
  if (!lanHostUsesLocalOnlyStorage(host) ||
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
  return lanHostUsesLocalOnlyStorage(host) &&
    host.protocol === candidate.protocol &&
    lanHostCanSelectDynamic(candidate.protocol, candidate.identity) &&
    normalizeLanDiscoveryIdentity(host.lanDiscoveryIdentity) ===
      normalizeLanDiscoveryIdentity(candidate.identity) &&
    candidate.host.trim() !== '' && candidate.port > 0 && candidate.port <= 65535 &&
    Number.isFinite(candidate.observedAt) && candidate.observedAt > 0;
}

/** Manual entry and LAN-static records remain ordinary cloud-eligible host rows. */
export function lanHostMayUseRemoteHostsCloudTable(host: LanHostAddressView): boolean {
  return !lanHostUsesLocalOnlyStorage(host);
}
