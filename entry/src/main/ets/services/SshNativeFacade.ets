/**
 * Explicit ArkTS SSH boundary.
 *
 * ExtensionLoader still contains compatibility methods for the other
 * protocols. SSH page/background code uses this facade so every operation is
 * authorized by a SshSessionHandle instead of an implicit active adapter.
 */

import {
  SessionConfig,
  SftpListAsyncResult,
  SshForwardingConfig,
  SshForwardingSnapshotsResult,
  SshSessionEventsResult,
  SshSessionSnapshot,
  SshTerminalInputEnqueueResult
} from '../types/rdpnapi';
import { ExtensionLoader } from './ExtensionLoader';
import {
  SshSessionHandle,
  SshSessionLifecycleState,
  SshSessionStore
} from './SshSessionStore';

export interface SshConnectHandoff {
  handle: SshSessionHandle;
  promise: Promise<number>;
}

export class SshNativeFacade {
  private static instance: SshNativeFacade | null = null;
  private readonly loader: ExtensionLoader;
  private readonly store: SshSessionStore;

  constructor(loader: ExtensionLoader = ExtensionLoader.getInstance(),
    store: SshSessionStore = SshSessionStore.getInstance()) {
    this.loader = loader;
    this.store = store;
  }

  static getInstance(): SshNativeFacade {
    if (SshNativeFacade.instance === null) {
      SshNativeFacade.instance = new SshNativeFacade();
    }
    return SshNativeFacade.instance;
  }

  connectSshAsync(config: SessionConfig, hostId: string, label: string,
    address: string, foreground: boolean = true): SshConnectHandoff | null {
    const nativePromise = this.loader.connectSshAsync(config, foreground);
    const handle: SshSessionHandle = {
      sessionId: nativePromise.sessionId,
      channelId: 'shell',
      generation: nativePromise.generation
    };
    if (!this.store.reserve(hostId, label, address, handle)) {
      if (handle.sessionId > 0) { this.loader.disconnectSshSession(handle.sessionId); }
      return null;
    }
    this.store.transition(handle, 'Connecting', 'connect.requested');
    const promise: Promise<number> = nativePromise.then(
      (sessionId: number): number => {
        if (sessionId <= 0) {
          this.store.transition(handle, 'Failed', 'connect.failed', 'native-connect-failed');
        } else {
          this.store.transition(handle, 'Authenticating', 'connect.transport-ready');
        }
        return sessionId;
      },
      (_error: Object): number => {
        this.store.transition(handle, 'Failed', 'connect.failed', 'native-connect-rejected');
        return -1;
      });
    return { handle, promise };
  }

  bindExistingSession(hostId: string, label: string, address: string,
    handle: SshSessionHandle, state: SshSessionLifecycleState = 'Ready'): boolean {
    return this.store.registerExisting(hostId, label, address, handle, state);
  }

  rebindGeneration(handle: SshSessionHandle, nextGeneration: number): SshSessionHandle | null {
    return this.store.rebindGeneration(handle.sessionId, handle.channelId,
      handle.generation, nextGeneration);
  }

  handleForHost(hostId: string): SshSessionHandle | null {
    return this.store.handleForHost(hostId);
  }

  accepts(handle: SshSessionHandle): boolean { return this.store.accepts(handle); }

  forwardingSessionState(handle: SshSessionHandle): SshSessionLifecycleState | '' {
    const context = this.store.context(handle);
    return context === null ? '' : context.state;
  }

  configureSshForwarding(handle: SshSessionHandle, config: SshForwardingConfig): number {
    if (!this.store.accepts(handle)) { return -75; }
    return this.loader.configureSshForwarding(handle.sessionId, handle.generation, config);
  }

  removeSshForwarding(handle: SshSessionHandle, id: string): number {
    if (!this.store.accepts(handle)) { return -75; }
    return this.loader.removeSshForwarding(handle.sessionId, handle.generation, id);
  }

  startSshForwarding(handle: SshSessionHandle, id: string): number {
    if (!this.store.accepts(handle)) { return -75; }
    return this.loader.startSshForwarding(handle.sessionId, handle.generation, id);
  }

  stopSshForwarding(handle: SshSessionHandle, id: string): number {
    if (!this.store.accepts(handle)) { return -75; }
    return this.loader.stopSshForwarding(handle.sessionId, handle.generation, id);
  }

  completeSshForwardingStop(handle: SshSessionHandle, id: string): number {
    if (!this.store.accepts(handle)) { return -75; }
    return this.loader.completeSshForwardingStop(handle.sessionId, handle.generation, id);
  }

  acquireSshForwardingConnection(handle: SshSessionHandle, id: string): number {
    if (!this.store.accepts(handle)) { return -75; }
    return this.loader.acquireSshForwardingConnection(handle.sessionId, handle.generation, id);
  }

  releaseSshForwardingConnection(handle: SshSessionHandle, id: string): number {
    if (!this.store.accepts(handle)) { return -75; }
    return this.loader.releaseSshForwardingConnection(handle.sessionId, handle.generation, id);
  }

  getSshForwardingSnapshots(handle: SshSessionHandle): SshForwardingSnapshotsResult {
    if (!this.store.accepts(handle)) {
      return { errorCode: -75, sessionId: handle.sessionId, sessionGeneration: 0, snapshots: [] };
    }
    return this.loader.getSshForwardingSnapshots(handle.sessionId, handle.generation);
  }

  snapshot(handle: SshSessionHandle): SshSessionSnapshot {
    if (!this.store.accepts(handle)) {
      return {
        schemaVersion: 1,
        errorCode: -83,
        sessionId: handle.sessionId,
        generation: 0,
        channelId: handle.channelId,
        state: 10,
        stateName: 'Closed',
        eventSequence: 0,
        host: '',
        port: 22,
        backgroundLimited: false,
        lastEventType: 'stale.session'
      };
    }
    return this.loader.getSshSessionSnapshot(handle.sessionId, handle.generation);
  }

  events(handle: SshSessionHandle, afterSequence: number = 0): SshSessionEventsResult {
    if (!this.store.accepts(handle)) {
      return {
        schemaVersion: 1,
        errorCode: -83,
        sessionId: handle.sessionId,
        channelId: handle.channelId,
        generation: 0,
        afterSequence: Math.max(0, Math.floor(afterSequence)),
        events: []
      };
    }
    return this.loader.getSshSessionEvents(handle.sessionId, handle.channelId,
      handle.generation, afterSequence);
  }

  enqueueTerminalInput(handle: SshSessionHandle, data: string,
    control: boolean = false, ordered: boolean = false,
    orderedEnd: boolean = false): SshTerminalInputEnqueueResult {
    if (!this.store.accepts(handle)) {
      return { accepted: false, status: 'sessionClosed', sequence: 0,
        generation: 0, queueDepth: 0, queueBytes: 0 };
    }
    return this.loader.enqueueTerminalInput(handle.sessionId, data, handle.generation,
      control, ordered, orderedEnd);
  }

  setOnDataCallback(handle: SshSessionHandle, callback: ((data: ArrayBuffer) => void) | null): boolean {
    if (!this.store.accepts(handle)) { return false; }
    this.loader.setOnDataCallback(handle.sessionId, callback);
    return true;
  }

  resume(handle: SshSessionHandle): boolean {
    if (!this.store.accepts(handle)) { return false; }
    return this.loader.resumeSshSession(handle.sessionId);
  }

  resizePty(handle: SshSessionHandle, cols: number, rows: number): boolean {
    if (!this.store.accepts(handle) || cols <= 0 || rows <= 0) { return false; }
    this.loader.resizePty(handle.sessionId, cols, rows);
    return true;
  }

  listRemoteDirAsync(handle: SshSessionHandle, remotePath: string): Promise<SftpListAsyncResult> {
    if (!this.store.accepts(handle)) {
      return Promise.resolve({ errorCode: -83, entries: [] });
    }
    return this.loader.listRemoteDirAsync(handle.sessionId, remotePath, handle.generation);
  }

  detach(handle: SshSessionHandle, hostId: string): boolean {
    if (!this.store.accepts(handle)) { return false; }
    const detached: boolean = this.loader.detachSshSession(handle.sessionId, hostId);
    if (detached) { this.store.markDetached(handle, true); }
    return detached;
  }

  disconnect(handle: SshSessionHandle): number {
    if (!this.store.accepts(handle)) { return 0; }
    this.store.close(handle, 'session.disconnect.requested');
    return this.loader.disconnectSshSession(handle.sessionId);
  }

  sessionStore(): SshSessionStore { return this.store; }
}
