import { SshForwardingProfile } from './SshForwardingPolicy';
import { SshSessionHandle } from './SshSessionStore';

export type SshForwardingRuntimeState = 'configured' | 'starting' | 'listening' |
  'stopping' | 'stopped' | 'failed' | 'stale' | 'needsRebind';

export interface SshForwardingRuntimeRecord {
  schemaVersion: 1;
  profileId: string;
  sessionId: number;
  channelId: string;
  generation: number;
  profile: SshForwardingProfile;
  state: SshForwardingRuntimeState;
  activeConnections: number;
  transferredBytes: number;
  lastError: number;
  actualBindHost: string;
  actualBindPort: number;
  actualBindFamily: number;
  updatedAtMs: number;
}

export const SSH_FORWARDING_RUNTIME_LIMIT: number = 256;

function cloneProfile(profile: SshForwardingProfile): SshForwardingProfile {
  return {
    id: profile.id, mode: profile.mode, bindHost: profile.bindHost, bindPort: profile.bindPort,
    targetHost: profile.targetHost, targetPort: profile.targetPort,
    maxConnections: profile.maxConnections, enabled: profile.enabled,
    startPolicy: profile.startPolicy, allowPublicBind: profile.allowPublicBind,
    minBindPort: profile.minBindPort, maxBindPort: profile.maxBindPort,
    maxBytes: profile.maxBytes, expiresAtMs: profile.expiresAtMs
  };
}

function cloneRuntime(runtime: SshForwardingRuntimeRecord): SshForwardingRuntimeRecord {
  return {
    schemaVersion: 1, profileId: runtime.profileId, sessionId: runtime.sessionId,
    channelId: runtime.channelId, generation: runtime.generation,
    profile: cloneProfile(runtime.profile), state: runtime.state,
    activeConnections: runtime.activeConnections, transferredBytes: runtime.transferredBytes,
    lastError: runtime.lastError, actualBindHost: runtime.actualBindHost,
    actualBindPort: runtime.actualBindPort, actualBindFamily: runtime.actualBindFamily,
    updatedAtMs: runtime.updatedAtMs
  };
}

function runtimeKey(handle: SshSessionHandle, profileId: string): string {
  return handle.sessionId.toString() + '|' + handle.channelId + '|' +
    handle.generation.toString() + '|' + profileId;
}

export class SshForwardingRuntimeStore {
  private readonly records: Map<string, SshForwardingRuntimeRecord> =
    new Map<string, SshForwardingRuntimeRecord>();
  private readonly maxEntries: number;

  constructor(maxEntries: number = SSH_FORWARDING_RUNTIME_LIMIT) {
    this.maxEntries = Math.max(1, Math.floor(maxEntries));
  }

  /**
   * Check admission before a native rule is configured. The native side has
   * no notion of this ArkTS runtime ledger, so configuring first would leave
   * an untracked listener when the bounded ledger is full.
   */
  canUpsert(handle: SshSessionHandle, profileId: string): boolean {
    const key: string = runtimeKey(handle, profileId);
    return this.records.has(key) || this.records.size < this.maxEntries;
  }

  upsert(handle: SshSessionHandle, profile: SshForwardingProfile,
    state: SshForwardingRuntimeState, error: number = 0): SshForwardingRuntimeRecord | null {
    const key: string = runtimeKey(handle, profile.id);
    const existing: SshForwardingRuntimeRecord | undefined = this.records.get(key);
    if (existing === undefined && this.records.size >= this.maxEntries) { return null; }
    const runtime: SshForwardingRuntimeRecord = existing === undefined ? {
      schemaVersion: 1,
      profileId: profile.id,
      sessionId: handle.sessionId,
      channelId: handle.channelId,
      generation: handle.generation,
      profile: cloneProfile(profile),
      state,
      activeConnections: 0,
      transferredBytes: 0,
      lastError: error,
      actualBindHost: profile.bindHost,
      actualBindPort: profile.bindPort,
      actualBindFamily: 0,
      updatedAtMs: Date.now()
    } : cloneRuntime(existing);
    if (existing !== undefined) {
      runtime.profile = cloneProfile(profile);
      runtime.state = state;
      runtime.lastError = error;
      runtime.updatedAtMs = Date.now();
    }
    this.records.set(key, runtime);
    return cloneRuntime(runtime);
  }

  updateSnapshot(handle: SshSessionHandle, profileId: string, state: SshForwardingRuntimeState,
    activeConnections: number, transferredBytes: number, lastError: number,
    actualBindHost: string, actualBindPort: number, actualBindFamily: number): boolean {
    const key: string = runtimeKey(handle, profileId);
    const runtime: SshForwardingRuntimeRecord | undefined = this.records.get(key);
    if (runtime === undefined) { return false; }
    runtime.state = state;
    runtime.activeConnections = Math.max(0, Math.floor(activeConnections));
    runtime.transferredBytes = Math.max(0, Math.floor(transferredBytes));
    runtime.lastError = lastError;
    runtime.actualBindHost = actualBindHost;
    runtime.actualBindPort = actualBindPort;
    runtime.actualBindFamily = actualBindFamily;
    runtime.updatedAtMs = Date.now();
    return true;
  }

  get(handle: SshSessionHandle, profileId: string): SshForwardingRuntimeRecord | null {
    const runtime: SshForwardingRuntimeRecord | undefined =
      this.records.get(runtimeKey(handle, profileId));
    return runtime === undefined ? null : cloneRuntime(runtime);
  }

  list(handle: SshSessionHandle): SshForwardingRuntimeRecord[] {
    const result: SshForwardingRuntimeRecord[] = [];
    this.records.forEach((runtime: SshForwardingRuntimeRecord): void => {
      if (runtime.sessionId === handle.sessionId && runtime.channelId === handle.channelId &&
        runtime.generation === handle.generation) {
        result.push(cloneRuntime(runtime));
      }
    });
    return result;
  }

  markOlderGenerations(handle: SshSessionHandle): number {
    let changed: number = 0;
    this.records.forEach((runtime: SshForwardingRuntimeRecord): void => {
      if (runtime.sessionId === handle.sessionId && runtime.channelId === handle.channelId &&
        runtime.generation !== handle.generation && runtime.state !== 'stopped') {
        runtime.state = 'needsRebind';
        runtime.updatedAtMs = Date.now();
        changed++;
      }
    });
    return changed;
  }

  markHandleStale(handle: SshSessionHandle): number {
    let changed: number = 0;
    this.records.forEach((runtime: SshForwardingRuntimeRecord): void => {
      if (runtime.sessionId === handle.sessionId && runtime.channelId === handle.channelId &&
        runtime.generation === handle.generation && runtime.state !== 'stopped') {
        runtime.state = 'stale';
        runtime.updatedAtMs = Date.now();
        changed++;
      }
    });
    return changed;
  }

  remove(handle: SshSessionHandle, profileId: string): boolean {
    return this.records.delete(runtimeKey(handle, profileId));
  }

  clear(handle: SshSessionHandle): number {
    const keys: string[] = [];
    this.records.forEach((runtime: SshForwardingRuntimeRecord, key: string): void => {
      if (runtime.sessionId === handle.sessionId && runtime.channelId === handle.channelId &&
        runtime.generation === handle.generation) { keys.push(key); }
    });
    for (let index: number = 0; index < keys.length; index++) { this.records.delete(keys[index]); }
    return keys.length;
  }

  /** Remove every generation of one native session after its final teardown. */
  clearSession(handle: SshSessionHandle): number {
    const keys: string[] = [];
    this.records.forEach((runtime: SshForwardingRuntimeRecord, key: string): void => {
      if (runtime.sessionId === handle.sessionId && runtime.channelId === handle.channelId) {
        keys.push(key);
      }
    });
    for (let index: number = 0; index < keys.length; index++) { this.records.delete(keys[index]); }
    return keys.length;
  }

  clearOlderGenerations(handle: SshSessionHandle): number {
    const keys: string[] = [];
    this.records.forEach((runtime: SshForwardingRuntimeRecord, key: string): void => {
      if (runtime.sessionId === handle.sessionId && runtime.channelId === handle.channelId &&
        runtime.generation !== handle.generation) { keys.push(key); }
    });
    for (let index: number = 0; index < keys.length; index++) { this.records.delete(keys[index]); }
    return keys.length;
  }
}
