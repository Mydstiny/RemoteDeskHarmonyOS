/**
 * ActiveRemoteSessionRegistry.ets — 后台保活会话注册表 (T-256)
 *
 * 通过 AppStorage 保存当前仍由 native 持有的远程协议会话。
 * 页面实例重建后可用它判断应恢复渲染，而不是新建协议连接。
 */
import { RemoteProtocol } from './RemoteSessionState';

const ACTIVE_REMOTE_SESSION_KEY = 'activeRemoteSessionRecord';

export interface ActiveRemoteSessionRecord {
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

  static getInstance(): ActiveRemoteSessionRegistry {
    if (ActiveRemoteSessionRegistry.instance === null) {
      ActiveRemoteSessionRegistry.instance = new ActiveRemoteSessionRegistry();
    }
    return ActiveRemoteSessionRegistry.instance;
  }

  setActive(record: ActiveRemoteSessionRecord): void {
    const now: number = Date.now();
    const next: ActiveRemoteSessionRecord = {
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
  }

  getActive(): ActiveRemoteSessionRecord | null {
    const raw: ActiveRemoteSessionRecord | null =
      AppStorage.get<ActiveRemoteSessionRecord>(ACTIVE_REMOTE_SESSION_KEY) ?? null;
    if (raw === null || raw.sessionId <= 0 || raw.hostId.length === 0) {
      return null;
    }
    return {
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

  hasRestorePending(hostId: string, sessionId: number): boolean {
    const active = this.getActive();
    return active !== null &&
      active.hostId === hostId &&
      active.sessionId === sessionId &&
      active.protocolConnected &&
      active.restoreNeeded;
  }

  markRenderDetached(): void {
    const active = this.getActive();
    if (active === null) {
      return;
    }
    active.renderAttached = false;
    active.restoreNeeded = true;
    active.updatedAtMs = Date.now();
    this.write(active);
  }

  markRenderAttached(surfaceId: string): void {
    const active = this.getActive();
    if (active === null) {
      return;
    }
    active.renderAttached = true;
    active.restoreNeeded = false;
    active.latestSurfaceId = surfaceId;
    active.updatedAtMs = Date.now();
    this.write(active);
  }

  markRestoreNeeded(value: boolean): void {
    const active = this.getActive();
    if (active === null) {
      return;
    }
    active.restoreNeeded = value;
    active.updatedAtMs = Date.now();
    this.write(active);
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
