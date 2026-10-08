/** Immutable session identity; no endpoint credentials belong in clipboard state. */
export interface ClipboardLease {
  readonly accountScopeId: string;
  readonly accountGeneration: number;
  readonly windowId: string;
  readonly hostId: string;
  readonly protocol: string;
  readonly routeIdentity: string;
  readonly sessionId: number;
  readonly attemptId: number;
  readonly nativeGeneration: number;
}

export interface ClipboardAuthorization {
  readonly epoch: number;
  readonly lease: ClipboardLease;
}

function leaseKey(lease: ClipboardLease): string {
  return JSON.stringify([lease.accountScopeId, lease.accountGeneration.toString(), lease.windowId,
    lease.hostId, lease.protocol, lease.routeIdentity, lease.sessionId.toString(),
    lease.attemptId.toString(), lease.nativeGeneration.toString()]);
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
  notifiedChangeCount: number = -1;
  pendingLocal: boolean = false;
}

export interface LocalClipboardSnapshot {
  ok: boolean;
  hasText: boolean;
  text: string;
  tag: string;
  changeCount: number;
}

/**
 * One explicitly authorized target per ArkTS runtime. Focus never grants authority.
 * A process-level arbiter must additionally fence every bridge operation.
 * PasteData tags carry provenance across bridge reconstruction and runtimes;
 * they only suppress automatic forwarding and are never permission evidence.
 */
export class ClipboardCoordinator {
  private static instance: ClipboardCoordinator = new ClipboardCoordinator();
  private nextId: number = 0;
  private owner: number = 0;
  private epoch: number = 0;
  private authorizationEpoch: number = 0;
  private authorization: ClipboardAuthorization | null = null;
  private authorizedLeaseKey: string = '';
  private remoteSequence: number = 0;
  private checkpoints: Map<string, ClipboardSourceState> = new Map<string, ClipboardSourceState>();
  private static readonly REMOTE_TAG: string = 'remotedesk:remote-text:v1:';

  static getInstance(): ClipboardCoordinator { return ClipboardCoordinator.instance; }

  allocate(): number { return ++this.nextId; }

  sourceState(lease: ClipboardLease | undefined, id: number): ClipboardSourceState {
    const key: string = lease === undefined ? 'bridge:' + id.toString() : leaseKey(lease);
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

  /** Called only in an explicitly authorized user action, never by bridge startup. */
  claimExplicit(lease: ClipboardLease): ClipboardAuthorization {
    if (!Number.isSafeInteger(lease.accountGeneration) || lease.accountGeneration < 0 ||
      !Number.isSafeInteger(lease.sessionId) || lease.sessionId <= 0 ||
      !Number.isSafeInteger(lease.attemptId) || lease.attemptId < 0 ||
      !Number.isSafeInteger(lease.nativeGeneration) || lease.nativeGeneration <= 0 ||
      lease.accountScopeId.length === 0 || lease.windowId.length === 0 || lease.hostId.length === 0 ||
      lease.protocol.length === 0 || lease.routeIdentity.length === 0) { throw new Error('clipboard_lease_invalid'); }
    const key: string = leaseKey(lease);
    if (this.authorization !== null && this.authorizedLeaseKey === key && this.isAuthorized(this.authorization)) {
      return this.authorization;
    }
    const captured: ClipboardLease = { accountScopeId: lease.accountScopeId, accountGeneration: lease.accountGeneration,
      windowId: lease.windowId, hostId: lease.hostId, protocol: lease.protocol, routeIdentity: lease.routeIdentity,
      sessionId: lease.sessionId, attemptId: lease.attemptId, nativeGeneration: lease.nativeGeneration };
    const authorization: ClipboardAuthorization = { epoch: ++this.authorizationEpoch, lease: captured };
    this.authorization = authorization; this.authorizedLeaseKey = key;
    this.owner = 0; this.epoch++;
    return authorization;
  }

  isAuthorized(authorization: ClipboardAuthorization | undefined, lease?: ClipboardLease): boolean {
    try {
      return authorization !== undefined && authorization === this.authorization &&
        authorization.epoch === this.authorizationEpoch && leaseKey(authorization.lease) === this.authorizedLeaseKey &&
        (lease === undefined || leaseKey(lease) === this.authorizedLeaseKey);
    } catch (_error) { return false; }
  }

  revoke(authorization: ClipboardAuthorization): void {
    if (authorization !== this.authorization) { return; }
    this.authorization = null; this.authorizedLeaseKey = ''; this.authorizationEpoch++;
    this.owner = 0; this.epoch++;
  }

  attachBridge(authorization: ClipboardAuthorization, id: number): boolean {
    if (!this.isAuthorized(authorization) || (this.owner !== 0 && this.owner !== id)) { return false; }
    if (this.owner !== id) { this.owner = id; this.epoch++; }
    return true;
  }

  detachBridge(authorization: ClipboardAuthorization | undefined, id: number): void {
    if (authorization === this.authorization && this.owner === id) { this.owner = 0; this.epoch++; }
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
