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
   * 只接受服务器明确返回的明文 `password` 字段。
   *
   * 地址簿里的 `hash` **不是密码**，是 `SHA256(password + salt)` 的 32 字节
   * 二进制摘要（base64 编码）。以前这里把它解码后按 UTF-8 转成字符串当密码用，
   * 结果有两个问题：
   *   1. 随机二进制按 UTF-8 解码得到的是乱码，而且是有损转换；
   *   2. 就算原样保留字节也没用 —— FFI 的认证只接受明文口令，
   *      protocol/session.rs 会无条件做 SHA256(password+salt) 再
   *      SHA256(..+challenge) 两轮，喂哈希进去必然认证失败。
   * 所以 hash 一律忽略，让主机回落到点击批准或用户自己保存的密码。
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
