/**
 * SshPreflightService.ets — SSH 连接前置校验安全 Token 服务
 *
 * 内存单例, 不持久化敏感信息.
 * Token TTL 60s, 消费后立即删除, 防止重放.
 * passphrase 不通过 router params 明文传递.
 */

import { SshJumpHopHandoff } from '../types/rdpnapi';

// Token 数据结构 (仅内存)
export interface SshPreflightTokenData {
  hostId: string;
  expectedHostKeyRawBase64: string;
  expectedHostKeyFingerprintSha256: string;
  targetRouteIdentity?: string;
  expectedJumpHostKeyRawBase64: string;
  expectedJumpHostKeyFingerprintSha256: string;
  privateKeyPassphrase: string;
  proxyPrivateKeyPassphrase?: string;
  /** Canonical route identity that owns the following one-shot credentials. */
  routeSecretsRouteIdentity?: string;
  proxyPassword?: string;
  jumpHandoffs?: SshJumpHopHandoff[];
  createdAt?: number; // 由服务内部设置
}

function cloneStringArray(values: string[] | undefined): string[] {
  return values === undefined ? [] : values.map((value: string): string => value);
}

function cloneJumpHandoff(value: SshJumpHopHandoff): SshJumpHopHandoff {
  return {
    password: value.password || '',
    privateKeyPem: value.privateKeyPem || '',
    privateKeyPassphrase: value.privateKeyPassphrase || '',
    keyboardInteractiveResponses: cloneStringArray(value.keyboardInteractiveResponses)
  };
}

function cloneTokenData(data: SshPreflightTokenData): SshPreflightTokenData {
  return {
    hostId: data.hostId,
    expectedHostKeyRawBase64: data.expectedHostKeyRawBase64,
    expectedHostKeyFingerprintSha256: data.expectedHostKeyFingerprintSha256,
    targetRouteIdentity: data.targetRouteIdentity,
    expectedJumpHostKeyRawBase64: data.expectedJumpHostKeyRawBase64,
    expectedJumpHostKeyFingerprintSha256: data.expectedJumpHostKeyFingerprintSha256,
    privateKeyPassphrase: data.privateKeyPassphrase,
    proxyPrivateKeyPassphrase: data.proxyPrivateKeyPassphrase,
    routeSecretsRouteIdentity: data.routeSecretsRouteIdentity,
    proxyPassword: data.proxyPassword,
    jumpHandoffs: data.jumpHandoffs === undefined ? undefined :
      data.jumpHandoffs.map((value: SshJumpHopHandoff): SshJumpHopHandoff => cloneJumpHandoff(value)),
    createdAt: data.createdAt
  };
}

export class SshPreflightService {
  private static instance: SshPreflightService;
  private tokens: Map<string, SshPreflightTokenData> = new Map();
  private readonly TTL_MS: number = 60000; // 60 秒

  static getInstance(): SshPreflightService {
    if (!SshPreflightService.instance) {
      SshPreflightService.instance = new SshPreflightService();
    }
    return SshPreflightService.instance;
  }

  /**
   * 创建一次性 token
   * @returns token ID (随机字符串)
   */
  createToken(data: SshPreflightTokenData): string {
    // 清理过期 token
    this.cleanup();
    const tokenId = 'spt_' + Date.now().toString(36) + '_' +
      Math.random().toString(36).substring(2, 10);
    const stored: SshPreflightTokenData = cloneTokenData(data);
    stored.createdAt = Date.now();
    this.tokens.set(tokenId, stored);
    return tokenId;
  }

  /**
   * 消费 token — 取出后立即删除
   * @returns token 数据, 或 null (不存在/过期)
   */
  consume(tokenId: string): SshPreflightTokenData | null {
    if (!tokenId || tokenId === '') { return null; }
    const data = this.tokens.get(tokenId);
    if (!data) { return null; }
    // 检查过期
    if (Date.now() - (data.createdAt || 0) > this.TTL_MS) {
      this.tokens.delete(tokenId);
      return null;
    }
    // 立即删除 (一次性消费)
    this.tokens.delete(tokenId);
    return cloneTokenData(data);
  }

  /**
   * 清理所有过期 token
   */
  cleanup(): void {
    const now = Date.now();
    const toDelete: string[] = [];
    this.tokens.forEach((data, id) => {
      if (now - (data.createdAt || 0) > this.TTL_MS) {
        toDelete.push(id);
      }
    });
    for (const id of toDelete) {
      this.tokens.delete(id);
    }
  }

  clearAll(): void {
    this.tokens.clear();
  }
}
