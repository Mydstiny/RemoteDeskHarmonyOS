/**
 * ActiveRemoteSessionRegistry.ets — 后台保活会话注册表 (T-256)
 *
 * 通过 AppStorage 保存当前仍由 native 持有的远程协议会话。
 * 页面实例重建后可用它判断应恢复渲染，而不是新建协议连接。
 */
import { RemoteProtocol } from './RemoteSessionState';

const ACTIVE_REMOTE_SESSION_KEY = 'activeRemoteSessionRecord';

export interface ActiveRemoteSessionRecord {
  ownerScopeId: string;
  accountGeneration: number;
  sessionId: number;
  hostId: string;
  protocol: RemoteProtocol;
  hostAddress: string;
  protocolConnected: boolean;
  renderAttached: boolean;
  restoreNeeded: boolean;
  latestSurfaceId: string;
  createdAtMs: number;
  updatedAtMs: number;
}

export class ActiveRemoteSessionRegistry {
  private static instance: ActiveRemoteSessionRegistry | null = null;
  private ownerScopeId: string = '';
  private accountGeneration: number = 0;

  static getInstance(): ActiveRemoteSessionRegistry {
    if (ActiveRemoteSessionRegistry.instance === null) {
      ActiveRemoteSessionRegistry.instance = new ActiveRemoteSessionRegistry();
    }
    return ActiveRemoteSessionRegistry.instance;
  }

  bindScope(ownerScopeId: string, accountGeneration: number): void {
    const nextOwnerScopeId: string = ownerScopeId.trim();
    const nextAccountGeneration: number = Math.max(0, Math.floor(accountGeneration));
    const scopeChanged: boolean = this.ownerScopeId !== nextOwnerScopeId ||
      this.accountGeneration !== nextAccountGeneration;
    this.ownerScopeId = nextOwnerScopeId;
    this.accountGeneration = nextAccountGeneration;
    if (scopeChanged) {
      // AppStorage survives page reconstruction inside the same process. A
      // record owned by the previous account must be removed before any
      // consumer can observe the newly bound account.
      this.clear('scope-bind-changed');
    }
  }

  setActive(record: ActiveRemoteSessionRecord): boolean {
    if (record.ownerScopeId !== this.ownerScopeId ||
      record.accountGeneration !== this.accountGeneration ||
      this.ownerScopeId.length === 0 || this.accountGeneration <= 0) {
      return false;
    }
    const now: number = Date.now();
    const next: ActiveRemoteSessionRecord = {
      ownerScopeId: record.ownerScopeId,
      accountGeneration: record.accountGeneration,
      sessionId: record.sessionId,
      hostId: record.hostId,
      protocol: record.protocol,
      hostAddress: record.hostAddress,
      protocolConnected: record.protocolConnected,
      renderAttached: record.renderAttached,
      restoreNeeded: record.restoreNeeded,
      latestSurfaceId: record.latestSurfaceId,
      createdAtMs: record.createdAtMs > 0 ? record.createdAtMs : now,
      updatedAtMs: now
    };
    this.write(next);
    return true;
  }

  getActive(): ActiveRemoteSessionRecord | null {
    const raw: ActiveRemoteSessionRecord | null =
      AppStorage.get<ActiveRemoteSessionRecord>(ACTIVE_REMOTE_SESSION_KEY) ?? null;
    if (raw === null || raw.sessionId <= 0 || raw.hostId.length === 0) {
      return null;
    }
    if (raw.ownerScopeId !== this.ownerScopeId ||
      raw.accountGeneration !== this.accountGeneration) {
      return null;
    }
    return {
      ownerScopeId: raw.ownerScopeId,
      accountGeneration: raw.accountGeneration,
      sessionId: raw.sessionId,
      hostId: raw.hostId,
      protocol: raw.protocol,
      hostAddress: raw.hostAddress,
      protocolConnected: raw.protocolConnected,
      renderAttached: raw.renderAttached,
      restoreNeeded: raw.restoreNeeded,
      latestSurfaceId: raw.latestSurfaceId,
      createdAtMs: raw.createdAtMs,
      updatedAtMs: raw.updatedAtMs
    };
  }

  hasRestorePending(ownerScopeId: string, accountGeneration: number,
    hostId: string, sessionId: number): boolean {
    const active = this.getActive();
    return active !== null &&
      active.ownerScopeId === ownerScopeId &&
      active.accountGeneration === accountGeneration &&
      active.hostId === hostId &&
      active.sessionId === sessionId &&
      active.protocolConnected &&
      active.restoreNeeded;
  }

  markRenderDetached(): boolean {
    const active = this.getActive();
    if (active === null) {
      return false;
    }
    active.renderAttached = false;
    active.restoreNeeded = true;
    active.updatedAtMs = Date.now();
    this.write(active);
    return true;
  }

  markRenderAttached(surfaceId: string): boolean {
    const active = this.getActive();
    if (active === null) {
      return false;
    }
    active.renderAttached = true;
    active.restoreNeeded = false;
    active.latestSurfaceId = surfaceId;
    active.updatedAtMs = Date.now();
    this.write(active);
    return true;
  }

  markRestoreNeeded(value: boolean): boolean {
    const active = this.getActive();
    if (active === null) {
      return false;
    }
    active.restoreNeeded = value;
    active.updatedAtMs = Date.now();
    this.write(active);
    return true;
  }

  clear(_reason: string): void {
    AppStorage.setOrCreate<ActiveRemoteSessionRecord | null>(ACTIVE_REMOTE_SESSION_KEY, null);
  }

  resetForTest(): void {
    this.clear('test-reset');
  }

  private write(record: ActiveRemoteSessionRecord): void {
    AppStorage.setOrCreate<ActiveRemoteSessionRecord>(ACTIVE_REMOTE_SESSION_KEY, record);
  }
}
