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

/** Managed rendezvous routes stay server-owned; a LAN direct endpoint is local and editable. */
export function shouldPreserveManagedRustDeskRoute(managed: boolean, directEnabled: boolean): boolean {
  return managed && !directEnabled;
}

/**
 * 识别历史版本把地址簿 `hash` 摘要按 UTF-8 解码后写进来的坏密码。
 *
 * 32 字节随机摘要几乎不可能是合法 UTF-8，解码结果里必定含有替换字符
 * U+FFFD；真实设备密码不会包含它。这类值对 FFI 永远认证不过，留着只会让
 * 用户以为"密码记住了"，所以同步时直接清掉，让主机回落到点击批准。
 */
export function isCorruptedAddressBookPassword(value: string): boolean {
  return value.indexOf('�') >= 0;
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
  peers: RustDeskProPeer[], syncedAt: number, relayHost: string = '', relayPort: number = 21116): RustDeskProReconcileResult {
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
      host.host = relayHost;
      host.port = relayPort > 0 ? relayPort : 21116;
      host.protocol = 'rustdesk';
      host.password = peer.password;
      host.rustdeskPasswordMode = 0;
      // Server Pro 地址簿经常不返回远端密码；新导入主机默认走官方的点击批准路径。
      host.rustdeskAuthMode = peer.password.length > 0 ? 'password' : 'request_approval';
      host.sourceType = 'rustdesk_pro';
      host.rustdeskProManaged = true;
      host.rustdeskProAccountId = accountId;
      host.rustdeskProPeerId = peerId;
      host.rustdeskProPlatform = peer.platform;
      host.createdAt = syncedAt;
      hosts.push(host);
      byPeer.set(peerId, host);
      addedIds.push(host.id);
    } else {
      updatedIds.push(host.id);
    }
    // Server-owned routing identity only. Local label/group/password/display settings stay intact.
    host.customHostname = peerId;
    // The peer API returns the remote ID, not the rendezvous endpoint. Keep
    // the endpoint on every managed record so an imported host can connect
    // without requiring a manual edit first.
    if (relayHost.length > 0) { host.host = relayHost; }
    if (relayPort > 0) { host.port = relayPort; }
    host.rustdeskRelayId = relayId;
    host.rustdeskAccountId = accountId;
    host.sourceType = 'rustdesk_pro';
    host.rustdeskProManaged = true;
    host.rustdeskProAccountId = accountId;
    host.rustdeskProPeerId = peerId;
    host.rustdeskProPlatform = peer.platform;
    host.rustdeskProLastSeenAt = syncedAt;
    host.rustdeskProSyncError = '';
    // 清掉历史版本用地址簿 hash 摘要写进来的坏密码（对 FFI 永远认证不过）。
    if (isCorruptedAddressBookPassword(host.password)) { host.password = ''; }
    // 地址簿密码只用来补空位，绝不覆盖用户手动保存的、已经能用的密码 ——
    // 以前这里是无条件赋值，每次同步都会把正确密码冲掉。
    if (peer.password.length > 0 && host.password.length === 0) { host.password = peer.password; }
    if (peer.password.length === 0 && host.password.length === 0) {
      // 空密码没有可用的设备凭据；只要用户没有保存密码，就使用官方点击批准闭环。
      host.rustdeskAuthMode = 'request_approval';
    } else if (peer.password.length > 0 && host.rustdeskAuthMode !== 'request_approval') {
      host.rustdeskAuthMode = 'password';
    }
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
