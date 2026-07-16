import { RemoteHost } from '../model/RemoteHost';
import { RustDeskProPeer } from '../model/RustDeskProModels';

export interface RustDeskProReconcileResult {
  hosts: RemoteHost[]
  addedIds: string[]
  updatedIds: string[]
  missingIds: string[]
}

export function rustDeskProHostId(relayId: string, accountId: string, peerId: string): string {
  return 'rdpro_' + encodeURIComponent(relayId + ':' + accountId + ':' + peerId);
}

function peerLabel(peer: RustDeskProPeer): string {
  if (peer.alias.length > 0) { return peer.alias; }
  if (peer.hostname.length > 0) { return peer.hostname; }
  return peer.id;
}

function isManagedByAccount(host: RemoteHost, relayId: string, accountId: string): boolean {
  return host.protocol === 'rustdesk' && host.sourceType === 'rustdesk_pro' &&
    host.rustdeskRelayId === relayId && host.rustdeskProAccountId === accountId && host.rustdeskProManaged;
}

export function reconcileRustDeskProHosts(existing: RemoteHost[], relayId: string, accountId: string,
  peers: RustDeskProPeer[], syncedAt: number): RustDeskProReconcileResult {
  const hosts: RemoteHost[] = existing.map((host: RemoteHost): RemoteHost => RemoteHost.fromJSON(host.toJSON()));
  const byPeer: Map<string, RemoteHost> = new Map();
  for (let i = 0; i < hosts.length; i++) {
    if (isManagedByAccount(hosts[i], relayId, accountId)) {
      const peerId = hosts[i].rustdeskProPeerId.length > 0 ? hosts[i].rustdeskProPeerId : hosts[i].customHostname;
      if (peerId.length > 0) { byPeer.set(peerId, hosts[i]); }
    }
  }

  const seen: Set<string> = new Set();
  const addedIds: string[] = [];
  const updatedIds: string[] = [];
  for (let i = 0; i < peers.length; i++) {
    const peer = peers[i];
    const peerId = peer.id.trim();
    if (peerId.length === 0 || seen.has(peerId)) { continue; }
    seen.add(peerId);
    let host = byPeer.get(peerId);
    if (!host) {
      host = new RemoteHost();
      host.id = rustDeskProHostId(relayId, accountId, peerId);
      host.label = peerLabel(peer);
      host.host = '';
      host.port = 21116;
      host.protocol = 'rustdesk';
      host.password = '';
      host.rustdeskPasswordMode = 0;
      host.sourceType = 'rustdesk_pro';
      host.rustdeskProManaged = true;
      host.rustdeskProAccountId = accountId;
      host.rustdeskProPeerId = peerId;
      host.createdAt = syncedAt;
      hosts.push(host);
      byPeer.set(peerId, host);
      addedIds.push(host.id);
    } else {
      updatedIds.push(host.id);
    }
    // Server-owned routing identity only. Local label/group/password/display settings stay intact.
    host.customHostname = peerId;
    host.rustdeskRelayId = relayId;
    host.rustdeskAccountId = accountId;
    host.sourceType = 'rustdesk_pro';
    host.rustdeskProManaged = true;
    host.rustdeskProAccountId = accountId;
    host.rustdeskProPeerId = peerId;
    host.rustdeskProLastSeenAt = syncedAt;
    host.rustdeskProSyncError = '';
  }

  const missingIds: string[] = [];
  byPeer.forEach((host: RemoteHost, peerId: string): void => {
    if (!seen.has(peerId)) {
      host.rustdeskProSyncError = 'not_seen';
      missingIds.push(host.id);
    }
  });
  return { hosts, addedIds, updatedIds, missingIds };
}
