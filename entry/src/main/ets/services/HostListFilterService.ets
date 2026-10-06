/**
 * HostListFilterService.ets - Pure host list filtering helpers (T-200)
 */
import { RemoteHost } from '../model/RemoteHost';
import { searchHosts as searchHostsByWorkspace } from './HostWorkspacePolicy';

/**
 * `relayNames` (relay id → name) also matches RustDesk hosts by the relay they use, which is how 中继 → 查看主机
 * lists a relay's hosts. A locked host is not matched by its relay.
 */
export function searchHosts(hosts: RemoteHost[], query: string, relayNames?: Map<string, string>): RemoteHost[] {
  const matched: RemoteHost[] = searchHostsByWorkspace(hosts, query);
  const normalized: string = query.trim().toLowerCase();
  if (relayNames === undefined || normalized === '') { return matched; }
  const matchedIds: Set<string> = new Set<string>(matched.map((host: RemoteHost): string => host.id));
  return hosts.filter((host: RemoteHost): boolean => matchedIds.has(host.id) ||
    (host.protocol === 'rustdesk' && !host.locked && host.rustdeskRelayId !== '' &&
      (relayNames.get(host.rustdeskRelayId) ?? '').toLowerCase().includes(normalized)));
}

export function filterHostsByProtocol(hosts: RemoteHost[], protocol: string): RemoteHost[] {
  if (protocol === '') { return hosts; }
  return hosts.filter((host: RemoteHost): boolean => host.protocol === protocol);
}

export function hostListProtocolForTab(tabIndex: number): string {
  if (tabIndex === 8) { return 'ai'; }
  const protocols: string[] = ['rdp', 'rustdesk', 'ssh', 'vnc'];
  return protocols[tabIndex] ?? '';
}

export function visibleHostsForHostListMode(hosts: RemoteHost[], query: string, isDesktopDevice: boolean,
  breakpoint: string, activeProtocol: string, tabIndex: number, relayNames?: Map<string, string>): RemoteHost[] {
  let visible: RemoteHost[] = hosts;
  if (isDesktopDevice && breakpoint === 'xl') {
    const protocol: string = activeProtocol !== '' ? activeProtocol : hostListProtocolForTab(tabIndex);
    visible = filterHostsByProtocol(visible, protocol);
  }
  return searchHosts(visible, query, relayNames);
}
