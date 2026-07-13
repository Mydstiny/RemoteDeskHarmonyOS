/**
 * HostListFilterService.ets - Pure host list filtering helpers (T-200)
 */
import { RemoteHost } from '../model/RemoteHost';
import { searchHosts as searchHostsByWorkspace } from './HostWorkspacePolicy';

export function searchHosts(hosts: RemoteHost[], query: string): RemoteHost[] {
  return searchHostsByWorkspace(hosts, query);
}

export function filterHostsByProtocol(hosts: RemoteHost[], protocol: string): RemoteHost[] {
  if (protocol === '') { return hosts; }
  return hosts.filter((host: RemoteHost): boolean => host.protocol === protocol);
}

export function hostListProtocolForTab(tabIndex: number): string {
  const protocols: string[] = ['rdp', 'rustdesk', 'ssh'];
  return protocols[tabIndex] ?? '';
}

export function visibleHostsForHostListMode(hosts: RemoteHost[], query: string, isDesktopDevice: boolean,
  breakpoint: string, activeProtocol: string, tabIndex: number): RemoteHost[] {
  let visible: RemoteHost[] = hosts;
  if (isDesktopDevice && breakpoint === 'xl') {
    const protocol: string = activeProtocol !== '' ? activeProtocol : hostListProtocolForTab(tabIndex);
    visible = filterHostsByProtocol(visible, protocol);
  }
  return searchHosts(visible, query);
}
