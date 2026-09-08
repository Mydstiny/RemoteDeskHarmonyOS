/** Immutable session identity; no endpoint credentials belong in clipboard state. */
export interface ClipboardLease {
  accountScopeId: string;
  windowId: string;
  hostId: string;
  protocol: string;
  routeIdentity: string;
  sessionId: number;
  attemptId: number;
  nativeGeneration: number;
}

export interface RemoteClipboardSnapshot {
  sequence: number;
  text: string;
  kind: 'none' | 'text' | 'files' | 'rich' | 'unsupported';
  ready: boolean;
}

export class ClipboardSourceState {
  observedSequence: number = 0;
  deliveredSequence: number = 0;
  remoteSource: boolean = false;
  systemChangeCount: number = -1;
}

export interface LocalClipboardSnapshot {
  ok: boolean;
  hasText: boolean;
  text: string;
  tag: string;
  changeCount: number;
}

/**
 * One target per ArkTS runtime. Window focus must activate/release the owner.
 * PasteData tags carry provenance across bridge reconstruction and runtimes;
 * they only suppress automatic forwarding and are never permission evidence.
 */
export class ClipboardCoordinator {
  private static instance: ClipboardCoordinator = new ClipboardCoordinator();
  private nextId: number = 0;
  private owner: number = 0;
  private epoch: number = 0;
  private remoteSequence: number = 0;
  private checkpoints: Map<string, ClipboardSourceState> = new Map<string, ClipboardSourceState>();
  private static readonly REMOTE_TAG: string = 'remotedesk:remote-text:v1:';

  static getInstance(): ClipboardCoordinator { return ClipboardCoordinator.instance; }

  allocate(): number { return ++this.nextId; }

  sourceState(lease: ClipboardLease | undefined, id: number): ClipboardSourceState {
    const key: string = lease === undefined ? 'bridge:' + id.toString() : JSON.stringify([
      lease.accountScopeId, lease.windowId, lease.hostId, lease.protocol, lease.routeIdentity,
      lease.sessionId.toString(), lease.attemptId.toString(), lease.nativeGeneration.toString()
    ]);
    const existing: ClipboardSourceState | undefined = this.checkpoints.get(key);
    if (existing !== undefined) { return existing; }
    const state: ClipboardSourceState = new ClipboardSourceState();
    // Checkpoints contain counters only. Bound retained historical session entries.
    if (this.checkpoints.size >= 128) {
      const keys: Array<string> = Array.from(this.checkpoints.keys());
      this.checkpoints.delete(keys[0]);
    }
    this.checkpoints.set(key, state);
    return state;
  }

  activate(id: number): void {
    if (this.owner !== id) {
      this.owner = id;
      this.epoch++;
    }
  }

  release(id: number): void {
    if (this.owner === id) {
      this.owner = 0;
      this.epoch++;
    }
  }

  currentEpoch(): number { return this.epoch; }
  owns(id: number): boolean { return this.owner === id; }
  isCurrent(id: number, epoch: number): boolean {
    return this.owns(id) && this.epoch === epoch;
  }

  remoteTag(id: number): string {
    return ClipboardCoordinator.REMOTE_TAG + id.toString() + ':' + (++this.remoteSequence).toString();
  }

  isRemoteTag(tag: string): boolean { return tag.startsWith(ClipboardCoordinator.REMOTE_TAG); }

  isRemoteOrigin(snapshot: LocalClipboardSnapshot): boolean {
    return this.isRemoteTag(snapshot.tag);
  }
}
