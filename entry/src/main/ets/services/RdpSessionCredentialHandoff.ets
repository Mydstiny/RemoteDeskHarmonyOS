/**
 * One-shot, process-memory-only RDP credential handoff.
 *
 * Credentials entered at connection time never enter RemoteHost, router
 * parameters, Preferences, a relational row, backup data or cloud sync. The
 * binding makes a pending secret valid for exactly one account generation and
 * one canonical RDP route.
 */
export const RDP_SESSION_CREDENTIAL_HANDOFF_IDLE_TTL_MS: number = 5 * 60 * 1000;
export const RDP_SESSION_CREDENTIAL_HANDOFF_ABSOLUTE_TTL_MS: number = 15 * 60 * 1000;

export interface RdpSessionCredentialDecision {
  username: string;
  password: string;
}

interface PendingRdpSessionCredential {
  userId: string;
  hostId: string;
  username: string;
  password: string;
  routeIdentity: string;
  accountOwnerScopeId: string;
  accountGeneration: number;
  connectionAttemptGeneration: number;
  createdAt: number;
  lastActivityAt: number;
}

export class RdpSessionCredentialHandoff {
  private static instance: RdpSessionCredentialHandoff;
  private pending: PendingRdpSessionCredential[] = [];
  private nowMs: () => number;

  constructor(nowMs: () => number = (): number => Date.now()) {
    this.nowMs = nowMs;
  }

  static getInstance(): RdpSessionCredentialHandoff {
    if (!RdpSessionCredentialHandoff.instance) {
      RdpSessionCredentialHandoff.instance = new RdpSessionCredentialHandoff();
    }
    return RdpSessionCredentialHandoff.instance;
  }

  put(userId: string, hostId: string, username: string, password: string,
    routeIdentity: string, accountOwnerScopeId: string,
    accountGeneration: number, connectionAttemptGeneration: number): boolean {
    const normalizedUserId: string = userId.trim();
    const normalizedHostId: string = hostId.trim();
    const normalizedUsername: string = username.trim();
    const normalizedRouteIdentity: string = routeIdentity.trim();
    const normalizedOwnerScopeId: string = accountOwnerScopeId.trim();
    if (normalizedUserId === '' || normalizedHostId === '' ||
      normalizedUsername === '' || password === '' || normalizedRouteIdentity === '' ||
      normalizedOwnerScopeId === '' || !Number.isSafeInteger(accountGeneration) ||
      accountGeneration <= 0 || !Number.isSafeInteger(connectionAttemptGeneration) ||
      connectionAttemptGeneration <= 0) {
      return false;
    }
    const now: number = this.nowMs();
    this.removeExpired(now);
    this.clear(normalizedUserId, normalizedHostId);
    this.pending.push({
      userId: normalizedUserId,
      hostId: normalizedHostId,
      username: normalizedUsername,
      password,
      routeIdentity: normalizedRouteIdentity,
      accountOwnerScopeId: normalizedOwnerScopeId,
      accountGeneration,
      connectionAttemptGeneration,
      createdAt: now,
      lastActivityAt: now
    });
    return true;
  }

  hasDecision(userId: string, hostId: string, routeIdentity: string,
    accountOwnerScopeId: string, accountGeneration: number,
    connectionAttemptGeneration: number): boolean {
    this.removeExpired(this.nowMs());
    const index: number = this.findIndex(userId, hostId);
    return index >= 0 && this.bindingMatches(
      this.pending[index], routeIdentity, accountOwnerScopeId, accountGeneration,
      connectionAttemptGeneration);
  }

  /** Extend only the idle deadline; the absolute lifetime can never move. */
  renewDecision(userId: string, hostId: string, routeIdentity: string,
    accountOwnerScopeId: string, accountGeneration: number,
    connectionAttemptGeneration: number): boolean {
    const now: number = this.nowMs();
    this.removeExpired(now);
    const index: number = this.findIndex(userId, hostId);
    if (index < 0 || !this.bindingMatches(
      this.pending[index], routeIdentity, accountOwnerScopeId, accountGeneration,
      connectionAttemptGeneration)) {
      return false;
    }
    this.pending[index].lastActivityAt = now;
    return true;
  }

  /** Read-only access for authenticated RD Gateway certificate preflight. */
  peekDecision(userId: string, hostId: string, routeIdentity: string,
    accountOwnerScopeId: string,
    accountGeneration: number,
    connectionAttemptGeneration: number): RdpSessionCredentialDecision | null {
    this.removeExpired(this.nowMs());
    const index: number = this.findIndex(userId, hostId);
    if (index < 0) { return null; }
    const item: PendingRdpSessionCredential = this.pending[index];
    if (!this.bindingMatches(item, routeIdentity, accountOwnerScopeId,
      accountGeneration, connectionAttemptGeneration)) {
      return null;
    }
    return { username: item.username, password: item.password };
  }

  /** Consume before starting the real RDP session. Any mismatch burns the entry. */
  takeDecision(userId: string, hostId: string, routeIdentity: string,
    accountOwnerScopeId: string,
    accountGeneration: number,
    connectionAttemptGeneration: number): RdpSessionCredentialDecision | null {
    this.removeExpired(this.nowMs());
    const index: number = this.findIndex(userId, hostId);
    if (index < 0) { return null; }
    const item: PendingRdpSessionCredential = this.pending[index];
    // A delayed route from an older attempt must not consume or erase the
    // replacement credential for the same owner/host pair.
    if (item.connectionAttemptGeneration !== connectionAttemptGeneration) {
      return null;
    }
    this.pending.splice(index, 1);
    if (!this.bindingMatches(item, routeIdentity, accountOwnerScopeId,
      accountGeneration, connectionAttemptGeneration)) {
      this.scrub(item);
      return null;
    }
    const decision: RdpSessionCredentialDecision = {
      username: item.username,
      password: item.password
    };
    this.scrub(item);
    return decision;
  }

  clear(userId: string, hostId: string): void {
    const normalizedUserId: string = userId.trim();
    const normalizedHostId: string = hostId.trim();
    this.pending = this.pending.filter((item: PendingRdpSessionCredential): boolean => {
      const remove: boolean = item.userId === normalizedUserId &&
        item.hostId === normalizedHostId;
      if (remove) { this.scrub(item); }
      return !remove;
    });
  }

  /** Exact cleanup for delayed router/page callbacks from one connection attempt. */
  clearIfMatches(userId: string, hostId: string,
    connectionAttemptGeneration: number): boolean {
    if (!Number.isSafeInteger(connectionAttemptGeneration) ||
      connectionAttemptGeneration <= 0) {
      return false;
    }
    const index: number = this.findIndex(userId, hostId);
    if (index < 0 || this.pending[index].connectionAttemptGeneration !==
      connectionAttemptGeneration) {
      return false;
    }
    const item: PendingRdpSessionCredential = this.pending[index];
    this.pending.splice(index, 1);
    this.scrub(item);
    return true;
  }

  clearAll(): void {
    for (let index: number = 0; index < this.pending.length; index++) {
      this.scrub(this.pending[index]);
    }
    this.pending = [];
  }

  private findIndex(userId: string, hostId: string): number {
    const normalizedUserId: string = userId.trim();
    const normalizedHostId: string = hostId.trim();
    return this.pending.findIndex((item: PendingRdpSessionCredential): boolean =>
      item.userId === normalizedUserId && item.hostId === normalizedHostId);
  }

  private removeExpired(now: number): void {
    this.pending = this.pending.filter((item: PendingRdpSessionCredential): boolean => {
      const keep: boolean =
        now >= item.createdAt && now >= item.lastActivityAt &&
        now - item.createdAt <= RDP_SESSION_CREDENTIAL_HANDOFF_ABSOLUTE_TTL_MS &&
        now - item.lastActivityAt <= RDP_SESSION_CREDENTIAL_HANDOFF_IDLE_TTL_MS;
      if (!keep) { this.scrub(item); }
      return keep;
    });
  }

  private scrub(item: PendingRdpSessionCredential): void {
    item.username = '';
    item.password = '';
  }

  private bindingMatches(item: PendingRdpSessionCredential,
    routeIdentity: string, accountOwnerScopeId: string,
    accountGeneration: number, connectionAttemptGeneration: number): boolean {
    return item.routeIdentity === routeIdentity.trim() &&
      item.accountOwnerScopeId === accountOwnerScopeId.trim() &&
      item.accountGeneration === accountGeneration &&
      Number.isSafeInteger(accountGeneration) && accountGeneration > 0 &&
      item.connectionAttemptGeneration === connectionAttemptGeneration &&
      Number.isSafeInteger(connectionAttemptGeneration) &&
      connectionAttemptGeneration > 0;
  }
}
