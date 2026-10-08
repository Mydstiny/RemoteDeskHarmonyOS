import { RemoteHost } from '../../../model/RemoteHost';
import { HostSyncService } from '../../HostSyncService';
import { VncHostService, VncHostView } from '../../VncHostService';
import { projectVncHost } from '../../VncHostListProjectionPolicy';
import { AiHostService, projectAiHost } from '../../ai/AiHostService';
import { AiHost } from '../../ai/AiModels';
import { AiAccess } from '../../ai/AiAccess';
import { HostOrganizationHostView } from './HostOrganizationPolicy';

/** One host as the organization and workspace screens show it; `ref` is the cross-protocol reference. */
export interface OrgHostRow {
  ref: string;
  protocol: string;
  label: string;
  address: string;
  port: number;
  username: string;
  lastConnected: number;
}

export function orgProtocolLabel(protocol: string): string {
  if (protocol === 'rdp') { return 'RDP'; }
  if (protocol === 'ssh') { return 'SSH'; }
  if (protocol === 'vnc') { return 'VNC'; }
  if (protocol === 'rustdesk') { return 'RustDesk'; }
  if (protocol === 'moonlight') { return 'Moonlight'; }
  if (protocol === 'ai') { return 'AI'; }
  return protocol.toUpperCase();
}

/** The reference of a host card: every RemoteHost-shaped card already uses its reference as its id. */
export function orgRefForRemoteHost(host: RemoteHost): string { return host.id; }

export function orgRowForRemoteHost(host: RemoteHost): OrgHostRow {
  const address: string = host.protocol === 'rustdesk' && host.customHostname.trim() !== '' ?
    host.customHostname.trim() : host.host;
  return { ref: orgRefForRemoteHost(host), protocol: host.protocol, label: host.label || address, address,
    port: host.port, username: host.username, lastConnected: host.lastConnected };
}

export function orgRowDetail(row: OrgHostRow): string {
  const address: string = row.address.length > 0 ? row.address : '';
  return orgProtocolLabel(row.protocol) + (address.length > 0 ? ' · ' + address : '');
}

export function orgHostView(row: OrgHostRow, nowOnline: boolean | undefined): HostOrganizationHostView {
  const view: HostOrganizationHostView = { id: row.ref, protocol: row.protocol, host: row.address, port: row.port,
    username: row.username, label: row.label, lastConnected: row.lastConnected };
  if (nowOnline !== undefined) { view.nowOnline = nowOnline; }
  return view;
}

/**
 * Hosts of the current account that can be grouped or put into a workspace, read from each protocol's own store.
 * Moonlight hosts live behind an account lease, so the home page passes them in as `extra`.
 */
export function orgHostRows(extra: OrgHostRow[] = []): OrgHostRow[] {
  const rows: OrgHostRow[] = [];
  HostSyncService.getInstance().getAllHosts().forEach((host: RemoteHost): void => {
    if (host.protocol === 'rdp' || host.protocol === 'rustdesk' || host.protocol === 'ssh') {
      rows.push(orgRowForRemoteHost(host));
    }
  });
  VncHostService.getInstance().list().forEach((view: VncHostView): void => {
    rows.push(orgRowForRemoteHost(projectVncHost(view)));
  });
  let aiVisible: boolean = false;
  try { aiVisible = AiAccess.getInstance().proVisible(); } catch (_error) { aiVisible = false; }
  if (aiVisible) {
    AiHostService.getInstance().list().forEach((ai: AiHost): void => { rows.push(orgRowForRemoteHost(projectAiHost(ai))); });
  }
  extra.forEach((row: OrgHostRow): void => {
    if (!rows.some((item: OrgHostRow): boolean => item.ref === row.ref)) { rows.push(row); }
  });
  return rows.sort((left: OrgHostRow, right: OrgHostRow): number =>
    left.label.localeCompare(right.label) || left.ref.localeCompare(right.ref));
}

/** Chip text for a smart or tag filter key. */
export function hostFilterLabel(key: string): string {
  if (key === 'all') { return '全部'; }
  if (key === 'recent') { return '最近'; }
  if (key === 'online') { return '在线'; }
  if (key === 'offline') { return '离线'; }
  if (key === 'unassigned') { return '未分组'; }
  if (key.startsWith('protocol:')) { return orgProtocolLabel(key.substring(9)); }
  if (key.startsWith('subnet:')) { return key.substring(7); }
  if (key.startsWith('tag:')) { return '#' + key.substring(4); }
  return key;
}
