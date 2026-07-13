import { ConnectionHealth, RemoteHost } from '../model/RemoteHost';

export function normalizeGroupId(value: string): string {
  return value.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
}

export function groupIdsForHosts(hosts: RemoteHost[]): string[] {
  const unique = new Set<string>();
  hosts.forEach((host: RemoteHost): void => {
    const groupId = normalizeGroupId(host.groupId);
    if (groupId.length > 0) {
      unique.add(groupId);
    }
  });
  return Array.from(unique).sort();
}

export function filterHostsByWorkspace(hosts: RemoteHost[], groupId: string): RemoteHost[] {
  const normalized = normalizeGroupId(groupId);
  if (normalized.length === 0) {
    return hosts;
  }
  return hosts.filter((host: RemoteHost): boolean => normalizeGroupId(host.groupId) === normalized);
}

export function nextWorkspaceGroupId(currentGroupId: string, tappedGroupId: string): string {
  const current = normalizeGroupId(currentGroupId);
  const tapped = normalizeGroupId(tappedGroupId);
  return current === tapped ? '' : tapped;
}

export function searchHosts(hosts: RemoteHost[], query: string): RemoteHost[] {
  const normalized = query.trim().toLowerCase();
  if (normalized.length === 0) {
    return hosts;
  }
  return hosts.filter((host: RemoteHost): boolean => {
    return host.label.toLowerCase().includes(normalized) ||
      host.host.toLowerCase().includes(normalized) ||
      host.username.toLowerCase().includes(normalized) ||
      host.protocol.toLowerCase().includes(normalized) ||
      normalizeGroupId(host.groupId).includes(normalized);
  });
}

export function displayConnectionHealth(health: ConnectionHealth, latencyMs: number): string {
  if (health === ConnectionHealth.UNKNOWN) {
    return '';
  }
  let label = '';
  if (health === ConnectionHealth.EXCELLENT || health === ConnectionHealth.GOOD) {
    label = '连接正常';
  } else if (health === ConnectionHealth.FAIR) {
    label = '连接较慢';
  } else if (health === ConnectionHealth.POOR) {
    label = '连接不稳定';
  } else if (health === ConnectionHealth.BAD) {
    label = '连接失败';
  }
  return latencyMs > 0 ? label + ' · ' + latencyMs.toString() + ' ms' : label;
}
