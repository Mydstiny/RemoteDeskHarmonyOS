import { buffer, util } from '@kit.ArkTS';

/**
 * RustDesk Server Pro 账号与地址簿模型。
 *
 * 这些模型只描述 Pro API 响应和设备端凭据状态；账户的非敏感元数据通过
 * rustdeskrelays.accountsjson 复用旧云表保存，access token 永不进入云表或 RemoteHost。
 */

export interface RustDeskProPeerJSON {
  id?: string
  alias?: string
  username?: string
  hostname?: string
  platform?: string
  tags?: Object[]
  note?: string
}

export class RustDeskProPeer {
  id: string = '';
  alias: string = '';
  username: string = '';
  hostname: string = '';
  platform: string = '';
  tags: string[] = [];
  note: string = '';

  /**
   * RustDesk personal address books return the remembered password as a
   * base64-encoded `hash` field. Shared address books may return `password`.
   * Keep the decoded value in memory only; RemoteHost/CloudStore encrypt it
   * when it is persisted locally.
   */
  password: string = '';

  static fromJSON(json: Record<string, Object>): RustDeskProPeer {
    const peer = new RustDeskProPeer();
    peer.id = typeof json['id'] === 'string' ? json['id'] as string : '';
    peer.alias = typeof json['alias'] === 'string' ? json['alias'] as string : '';
    peer.username = typeof json['username'] === 'string' ? json['username'] as string : '';
    peer.hostname = typeof json['hostname'] === 'string' ? json['hostname'] as string : '';
    peer.platform = typeof json['platform'] === 'string' ? json['platform'] as string : '';
    peer.note = typeof json['note'] === 'string' ? json['note'] as string : '';
    if (typeof json['password'] === 'string') {
      peer.password = json['password'] as string;
    }
    if (peer.password.length === 0 && typeof json['hash'] === 'string') {
      try {
        const bytes: Uint8Array = new util.Base64Helper().decodeSync(json['hash'] as string);
        peer.password = buffer.from(bytes).toString('utf-8');
      } catch (_err) {
        // A malformed/unsupported hash must not make the whole address book fail.
      }
    }
    const rawTags: Object | undefined = json['tags'];
    if (Array.isArray(rawTags)) {
      const tags: string[] = [];
      const values: Object[] = rawTags as Object[];
      for (let i = 0; i < values.length; i++) {
        if (typeof values[i] === 'string') { tags.push(values[i] as string); }
      }
      peer.tags = tags;
    }
    return peer;
  }
}

export class RustDeskProAddressBook {
  updatedAt: number = 0;
  peers: RustDeskProPeer[] = [];
  tags: string[] = [];

  static fromResponse(payload: Object): RustDeskProAddressBook {
    const result = new RustDeskProAddressBook();
    const root = payload as Record<string, Object>;
    const rawUpdated = root['updated_at'] ?? root['updatedAt'];
    if (typeof rawUpdated === 'number') { result.updatedAt = rawUpdated as number; }

    let data: Object = root['data'] ?? payload;
    if (typeof data === 'string') {
      data = JSON.parse(data as string) as Object;
    }
    if (!data || typeof data !== 'object') { return result; }
    const body = data as Record<string, Object>;
    const rawPeers: Object | undefined = Array.isArray(data) ? data : body['peers'];
    if (Array.isArray(rawPeers)) {
      const values: Object[] = rawPeers as Object[];
      for (let i = 0; i < values.length; i++) {
        if (values[i] && typeof values[i] === 'object') {
          result.peers.push(RustDeskProPeer.fromJSON(values[i] as Record<string, Object>));
        }
      }
    }
    const rawTags: Object | undefined = body['tags'];
    if (Array.isArray(rawTags)) {
      const values: Object[] = rawTags as Object[];
      for (let i = 0; i < values.length; i++) {
        if (typeof values[i] === 'string') { result.tags.push(values[i] as string); }
      }
    }
    return result;
  }
}

export interface RustDeskProAccountState {
  id: string
  relayId: string
  serverUrl: string
  username: string
  displayName: string
  userId: string
  accessToken: string
  deviceId: string
  deviceUuid: string
  loginStatus: string
  lastLoginAt: number
  lastSyncAt: number
  lastSyncError: string
}
