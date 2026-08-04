import { ConnectionHealth, RemoteHost } from '../model/RemoteHost';

export type HostGroupType = 'rdp' | 'rustdesk' | 'ssh' | 'vnc';
export type HostPresenceState = 'online' | 'recently_online' | 'offline' | 'unknown' | 'checking';

export interface HostPresenceSummary {
  online: number;
  recentlyOnline: number;
  offline: number;
  unknown: number;
  checking: number;
}

export interface HostGroupCardModel {
  type: HostGroupType;
  title: string;
  subtitle: string;
  hosts: RemoteHost[];
  summary: HostPresenceSummary;
}

export const HOST_PRESENCE_ONLINE_TTL_MS: number = 60 * 1000;
export const HOST_PRESENCE_RECENT_WINDOW_MS: number = 15 * 60 * 1000;
export const HOST_PRESENCE_PROBE_PENDING: string = 'probe_pending';
export const HOST_PRESENCE_PROBE_OFFLINE: string = 'probe_offline';
export const HOST_PRESENCE_PROBE_UNKNOWN: string = 'probe_unknown';

const HOST_GROUP_TYPES: HostGroupType[] = ['rdp', 'rustdesk', 'ssh', 'vnc'];

export function hostGroupTypes(): HostGroupType[] {
  return HOST_GROUP_TYPES.slice();
}

export function hostGroupTitle(type: HostGroupType): string {
  switch (type) {
    case 'rdp': return 'RDP';
    case 'rustdesk': return 'RustDesk';
    case 'ssh': return 'SSH';
    case 'vnc': return 'VNC';
    default: return '远程主机';
  }
}

export function hostGroupSubtitle(type: HostGroupType): string {
  switch (type) {
    case 'rdp': return 'Windows 远程桌面';
    case 'rustdesk': return '跨平台远程控制';
    case 'ssh': return '终端与服务器';
    case 'vnc': return '屏幕共享主机';
    default: return '远程主机';
  }
}

export function hostGroupTypeForHost(host: RemoteHost): HostGroupType | null {
  if (host.protocol === 'rdp' || host.protocol === 'rustdesk' ||
    host.protocol === 'ssh' || host.protocol === 'vnc') {
    return host.protocol as HostGroupType;
  }
  return null;
}

export function rustDeskHostId(host: RemoteHost): string {
  if (host.rustdeskProPeerId.trim() !== '') {
    return formatRustDeskId(host.rustdeskProPeerId);
  }
  return formatRustDeskId(host.customHostname);
}

export function formatRustDeskId(rawValue: string): string {
  const value: string = rawValue.trim();
  if (value.length === 0) {
    return '';
  }
  const digits: string = value.replace(/\s/g, '');
  if (!/^\d+$/.test(digits)) {
    return value;
  }
  let formatted: string = '';
  for (let i = 0; i < digits.length; i++) {
    if (i > 0 && i % 3 === 0) {
      formatted += ' ';
    }
    formatted += digits.charAt(i);
  }
  return formatted;
}

export function hostIdentifierLabel(host: RemoteHost): string {
  return host.protocol === 'rustdesk' ? 'ID' : '端点';
}

export function hostIdentifier(host: RemoteHost): string {
  if (host.protocol === 'rustdesk') {
    const peerId: string = rustDeskHostId(host);
    return peerId.length > 0 ? peerId : 'ID 未获取';
  }
  const address: string = host.host.trim();
  if (address.length === 0) {
    return '地址未获取';
  }
  return host.port > 0 ? address + ':' + host.port.toString() : address;
}

function validTimestamp(value: number): number {
  return Number.isFinite(value) && value > 0 ? value : 0;
}

function ageMs(timestamp: number, nowMs: number): number {
  return Math.max(0, nowMs - timestamp);
}

export function hostPresenceState(host: RemoteHost, nowMs: number = Date.now(), active: boolean = false): HostPresenceState {
  if (active) {
    return 'online';
  }

  // Address-book synchronization is metadata, not peer presence. Only a
  // successful rendezvous/direct probe may write rustdeskProLastSeenAt.
  if (host.protocol === 'rustdesk') {
    const probeState: string = host.rustdeskProSyncError.trim();
    if (probeState === HOST_PRESENCE_PROBE_PENDING) {
      return 'checking';
    }
    if (probeState === HOST_PRESENCE_PROBE_OFFLINE) {
      return 'offline';
    }
    if (probeState === HOST_PRESENCE_PROBE_UNKNOWN) {
      return 'unknown';
    }
    const lastPeerSeenAt: number = validTimestamp(host.rustdeskProLastSeenAt);
    if (lastPeerSeenAt > 0) {
      const peerAge: number = ageMs(lastPeerSeenAt, nowMs);
      if (peerAge <= HOST_PRESENCE_ONLINE_TTL_MS) {
        return 'online';
      }
      if (peerAge <= HOST_PRESENCE_RECENT_WINDOW_MS) {
        return 'recently_online';
      }
    }
    // A peer missing from an address-book response is not evidence that the
    // device is offline. It may be a server-side permission or sync issue.
  }

  // Other protocols and manual RustDesk hosts only have a successful local
  // connection observation. It is useful history, but not proof of current
  // presence, so it remains "recently online" for the short history window.
  const lastConnectedAt: number = validTimestamp(host.lastConnected);
  if (lastConnectedAt > 0 && host.lastHealth !== ConnectionHealth.UNKNOWN &&
    ageMs(lastConnectedAt, nowMs) <= HOST_PRESENCE_RECENT_WINDOW_MS) {
    return 'recently_online';
  }
  return 'unknown';
}

export function hostPresenceLabel(state: HostPresenceState): string {
  switch (state) {
    case 'online': return '在线';
    case 'recently_online': return '最近在线';
    case 'offline': return '离线';
    case 'checking': return '检测中';
    case 'unknown': return '未知';
    default: return '未知';
  }
}

export function hostPresenceLastSeenAt(host: RemoteHost): number {
  if (host.protocol === 'rustdesk' && validTimestamp(host.rustdeskProLastSeenAt) > 0) {
    return host.rustdeskProLastSeenAt;
  }
  if (host.lastHealth !== ConnectionHealth.UNKNOWN && validTimestamp(host.lastConnected) > 0) {
    return host.lastConnected;
  }
  return 0;
}

export function emptyHostPresenceSummary(): HostPresenceSummary {
  return { online: 0, recentlyOnline: 0, offline: 0, unknown: 0, checking: 0 };
}

export function summarizeHostPresence(hosts: RemoteHost[], nowMs: number = Date.now(), activeHostId: string = ''):
  HostPresenceSummary {
  const summary: HostPresenceSummary = emptyHostPresenceSummary();
  for (let i = 0; i < hosts.length; i++) {
    const state: HostPresenceState = hostPresenceState(hosts[i], nowMs, hosts[i].id === activeHostId);
    if (state === 'online') {
      summary.online++;
    } else if (state === 'recently_online') {
      summary.recentlyOnline++;
    } else if (state === 'offline') {
      summary.offline++;
    } else if (state === 'checking') {
      summary.checking++;
    } else {
      summary.unknown++;
    }
  }
  return summary;
}

export function buildHostGroupCards(hosts: RemoteHost[], nowMs: number = Date.now(), activeHostId: string = ''):
  HostGroupCardModel[] {
  const cards: HostGroupCardModel[] = [];
  const types: HostGroupType[] = hostGroupTypes();
  for (let i = 0; i < types.length; i++) {
    const type: HostGroupType = types[i];
    const groupHosts: RemoteHost[] = hosts.filter((host: RemoteHost): boolean => hostGroupTypeForHost(host) === type);
    cards.push({
      type: type,
      title: hostGroupTitle(type),
      subtitle: hostGroupSubtitle(type),
      hosts: groupHosts,
      summary: summarizeHostPresence(groupHosts, nowMs, activeHostId)
    });
  }
  return cards;
}

export function hostGroupColumns(isPhone: boolean): number {
  return isPhone ? 1 : 2;
}

export function shouldUseGroupedHostCards(enabled: boolean, isDesktopDevice: boolean,
  breakpoint: string): boolean {
  return enabled && !(isDesktopDevice && breakpoint === 'xl');
}

export function hostGroupColumnsForBreakpoint(breakpoint: string): number {
  return hostGroupColumns(breakpoint === 'sm');
}

export function hostGroupRowForType(type: HostGroupType, columns: number): number {
  const safeColumns: number = Math.max(1, Math.floor(columns));
  const index: number = HOST_GROUP_TYPES.indexOf(type);
  return index < 0 ? 0 : Math.floor(index / safeColumns);
}

export function hostGroupDetailInsertionRow(type: HostGroupType, columns: number): number {
  return hostGroupRowForType(type, columns);
}
