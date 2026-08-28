/**
 * ActiveRemoteSessionRegistry.ets — 后台保活会话注册表 (T-256)
 *
 * 通过 AppStorage 保存当前仍由 native 持有的远程协议会话。
 * 页面实例重建后可用它判断应恢复渲染，而不是新建协议连接。
 */
import { RemoteProtocol } from './RemoteSessionState';
import { RemoteSessionTransitionGate } from './RemoteSessionTransitionGate';

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

/**
 * Process-local ownership for rebuilding the page of one preserved native
 * session. Only the latest adoption may tear down the predecessor
 * presentation or attach a new renderer.
 */
export interface ActiveRemoteSessionRestoreAdoption {
  ownerScopeId: string;
  accountGeneration: number;
  sessionId: number;
  hostId: string;
  protocol: RemoteProtocol;
  epoch: number;
}

/** Exact process-local right to finish tearing down one registered session. */
export interface ActiveRemoteSessionTermination {
  ownerScopeId: string;
  accountGeneration: number;
  sessionId: number;
  hostId: string;
  protocol: RemoteProtocol;
  epoch: number;
}

export class ActiveRemoteSessionRegistry {
  private static instance: ActiveRemoteSessionRegistry | null = null;
  private ownerScopeId: string = '';
  private accountGeneration: number = 0;
  private restoreAdoptionEpoch: number = 0;
  private restoreAdoption: ActiveRemoteSessionRestoreAdoption | null = null;
  private terminationEpoch: number = 0;
  private termination: ActiveRemoteSessionTermination | null = null;

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

  setActive(record: ActiveRemoteSessionRecord,
    adoption: ActiveRemoteSessionRestoreAdoption | null = null): boolean {
    if (!RemoteSessionTransitionGate.getInstance()
      .newSessionAllowed()) { return false; }
    if (this.termination !== null || !this.restoreOwnerAllows(adoption)) { return false; }
    if (record.ownerScopeId !== this.ownerScopeId ||
      record.accountGeneration !== this.accountGeneration ||
      this.ownerScopeId.length === 0 || this.accountGeneration <= 0) {
      return false;
    }
    // Moonlight's resumable registry marker is deliberately endpoint-free.
    // The transient address may reach a future native transport port, but it
    // must never become process-recovery or AppStorage data.
    if (record.protocol === RemoteProtocol.moonlight && record.hostAddress.length > 0) {
      return false;
    }
    const current: ActiveRemoteSessionRecord | null = this.getActive();
    if (current !== null && (current.ownerScopeId !== record.ownerScopeId ||
      current.accountGeneration !== record.accountGeneration ||
      current.sessionId !== record.sessionId || current.protocol !== record.protocol)) {
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

  reserveActive(record: ActiveRemoteSessionRecord): boolean {
    if (this.getActive() !== null) {
      return false;
    }
    return this.setActive(record);
  }

  promoteReserved(ownerScopeId: string, accountGeneration: number, reservationSessionId: number,
    next: ActiveRemoteSessionRecord): boolean {
    if (this.termination !== null || !this.restoreOwnerAllows(null)) { return false; }
    const current: ActiveRemoteSessionRecord | null = this.getActive();
    if (current === null || current.ownerScopeId !== ownerScopeId ||
      current.accountGeneration !== accountGeneration ||
      current.sessionId !== reservationSessionId || current.protocol !== RemoteProtocol.moonlight ||
      next.ownerScopeId !== ownerScopeId || next.accountGeneration !== accountGeneration ||
      next.protocol !== RemoteProtocol.moonlight || next.hostAddress.length > 0) {
      return false;
    }
    const now: number = Date.now();
    this.write({
      ownerScopeId: next.ownerScopeId,
      accountGeneration: next.accountGeneration,
      sessionId: next.sessionId,
      hostId: next.hostId,
      protocol: next.protocol,
      hostAddress: next.hostAddress,
      protocolConnected: next.protocolConnected,
      renderAttached: next.renderAttached,
      restoreNeeded: next.restoreNeeded,
      latestSurfaceId: next.latestSurfaceId,
      createdAtMs: current.createdAtMs > 0 ? current.createdAtMs : now,
      updatedAtMs: now
    });
    return true;
  }

  rotateMoonlightToReconnectReservation(ownerScopeId: string, accountGeneration: number,
    currentSessionId: number, reservationSessionId: number, hostId: string): boolean {
    if (this.termination !== null || !this.restoreOwnerAllows(null)) { return false; }
    const current: ActiveRemoteSessionRecord | null = this.getActive();
    if (current === null || current.ownerScopeId !== ownerScopeId ||
      current.accountGeneration !== accountGeneration ||
      current.sessionId !== currentSessionId || current.protocol !== RemoteProtocol.moonlight ||
      !Number.isSafeInteger(reservationSessionId) || reservationSessionId <= 0 ||
      hostId.trim() === '' || current.hostId !== hostId) {
      return false;
    }
    const now: number = Date.now();
    this.write({
      ownerScopeId: current.ownerScopeId,
      accountGeneration: current.accountGeneration,
      sessionId: reservationSessionId,
      hostId: current.hostId,
      protocol: RemoteProtocol.moonlight,
      hostAddress: '',
      protocolConnected: false,
      renderAttached: false,
      restoreNeeded: true,
      latestSurfaceId: '',
      createdAtMs: current.createdAtMs > 0 ? current.createdAtMs : now,
      updatedAtMs: now
    });
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

  beginRestoreAdoption(
    record: ActiveRemoteSessionRecord
  ): ActiveRemoteSessionRestoreAdoption | null {
    const active: ActiveRemoteSessionRecord | null = this.getActive();
    if (this.termination !== null || active === null ||
        !active.protocolConnected || !active.restoreNeeded ||
        active.ownerScopeId !== record.ownerScopeId ||
        active.accountGeneration !== record.accountGeneration ||
        active.sessionId !== record.sessionId || active.hostId !== record.hostId ||
        active.protocol !== record.protocol ||
        this.restoreAdoptionEpoch >= Number.MAX_SAFE_INTEGER) {
      return null;
    }
    this.restoreAdoptionEpoch += 1;
    const adoption: ActiveRemoteSessionRestoreAdoption = {
      ownerScopeId: active.ownerScopeId,
      accountGeneration: active.accountGeneration,
      sessionId: active.sessionId,
      hostId: active.hostId,
      protocol: active.protocol,
      epoch: this.restoreAdoptionEpoch
    };
    this.restoreAdoption = this.cloneRestoreAdoption(adoption);
    return this.cloneRestoreAdoption(adoption);
  }

  isRestoreAdoptionCurrent(
    adoption: ActiveRemoteSessionRestoreAdoption | null
  ): boolean {
    if (adoption === null || this.restoreAdoption === null) { return false; }
    const active: ActiveRemoteSessionRecord | null = this.getActive();
    return active !== null && active.protocolConnected &&
      this.restoreAdoption.ownerScopeId === adoption.ownerScopeId &&
      this.restoreAdoption.accountGeneration === adoption.accountGeneration &&
      this.restoreAdoption.sessionId === adoption.sessionId &&
      this.restoreAdoption.hostId === adoption.hostId &&
      this.restoreAdoption.protocol === adoption.protocol &&
      this.restoreAdoption.epoch === adoption.epoch &&
      active.ownerScopeId === adoption.ownerScopeId &&
      active.accountGeneration === adoption.accountGeneration &&
      active.sessionId === adoption.sessionId && active.hostId === adoption.hostId &&
      active.protocol === adoption.protocol;
  }

  /**
   * Whether one page still owns the right to touch the preserved native
   * session during foreground restoration. A page without an adoption token
   * is valid only while no reconstructed page has claimed the session.
   */
  isRestoreOwnerCurrent(
    adoption: ActiveRemoteSessionRestoreAdoption | null
  ): boolean {
    const active: ActiveRemoteSessionRecord | null = this.getActive();
    return this.termination === null && active !== null && active.protocolConnected &&
      this.restoreOwnerAllows(adoption);
  }

  completeRestoreAdoption(
    adoption: ActiveRemoteSessionRestoreAdoption | null
  ): boolean {
    const current: ActiveRemoteSessionRestoreAdoption | null = this.restoreAdoption;
    const active: ActiveRemoteSessionRecord | null = this.getActive();
    if (adoption === null || current === null || active === null ||
        current.ownerScopeId !== adoption.ownerScopeId ||
        current.accountGeneration !== adoption.accountGeneration ||
        current.sessionId !== adoption.sessionId || current.hostId !== adoption.hostId ||
        current.protocol !== adoption.protocol || current.epoch !== adoption.epoch ||
        active.ownerScopeId !== adoption.ownerScopeId ||
        active.accountGeneration !== adoption.accountGeneration ||
        active.sessionId !== adoption.sessionId || active.hostId !== adoption.hostId ||
        active.protocol !== adoption.protocol) {
      return false;
    }
    // Completion transfers durable process-local ownership to the reconstructed
    // page. Keep the exact adoption until termination or a later reconstruction
    // supersedes it, otherwise a delayed old page could disconnect or mutate
    // the newly attached session using only the recycled numeric session id.
    return true;
  }

  beginTermination(record: ActiveRemoteSessionRecord,
    adoption: ActiveRemoteSessionRestoreAdoption | null):
    ActiveRemoteSessionTermination | null {
    const active: ActiveRemoteSessionRecord | null = this.getActive();
    if (this.termination !== null || active === null ||
        active.ownerScopeId !== record.ownerScopeId ||
        active.accountGeneration !== record.accountGeneration ||
        active.sessionId !== record.sessionId || active.hostId !== record.hostId ||
        active.protocol !== record.protocol ||
        this.terminationEpoch >= Number.MAX_SAFE_INTEGER) {
      return null;
    }
    if (this.restoreAdoption === null) {
      if (adoption !== null) { return null; }
    } else if (!this.restoreAdoptionEquals(this.restoreAdoption, adoption)) {
      return null;
    }
    this.terminationEpoch += 1;
    const termination: ActiveRemoteSessionTermination = {
      ownerScopeId: active.ownerScopeId,
      accountGeneration: active.accountGeneration,
      sessionId: active.sessionId,
      hostId: active.hostId,
      protocol: active.protocol,
      epoch: this.terminationEpoch
    };
    this.termination = this.cloneTermination(termination);
    this.restoreAdoption = null;
    return this.cloneTermination(termination);
  }

  isTerminationCurrent(
    termination: ActiveRemoteSessionTermination | null
  ): boolean {
    if (termination === null || this.termination === null) { return false; }
    const active: ActiveRemoteSessionRecord | null = this.getActive();
    return active !== null &&
      this.termination.ownerScopeId === termination.ownerScopeId &&
      this.termination.accountGeneration === termination.accountGeneration &&
      this.termination.sessionId === termination.sessionId &&
      this.termination.hostId === termination.hostId &&
      this.termination.protocol === termination.protocol &&
      this.termination.epoch === termination.epoch &&
      active.ownerScopeId === termination.ownerScopeId &&
      active.accountGeneration === termination.accountGeneration &&
      active.sessionId === termination.sessionId && active.hostId === termination.hostId &&
      active.protocol === termination.protocol;
  }

  completeTermination(
    termination: ActiveRemoteSessionTermination | null
  ): boolean {
    if (!this.isTerminationCurrent(termination)) { return false; }
    this.clear('terminated-session-clear');
    return true;
  }

  markRenderDetached(
    adoption: ActiveRemoteSessionRestoreAdoption | null = null
  ): boolean {
    if (this.termination !== null || !this.restoreOwnerAllows(adoption)) { return false; }
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

  markRenderAttached(surfaceId: string,
    adoption: ActiveRemoteSessionRestoreAdoption | null = null): boolean {
    if (this.termination !== null || !this.restoreOwnerAllows(adoption)) { return false; }
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

  markRestoreNeeded(value: boolean,
    adoption: ActiveRemoteSessionRestoreAdoption | null = null): boolean {
    if (this.termination !== null || !this.restoreOwnerAllows(adoption)) { return false; }
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
    this.restoreAdoption = null;
    this.termination = null;
    AppStorage.setOrCreate<ActiveRemoteSessionRecord | null>(ACTIVE_REMOTE_SESSION_KEY, null);
  }

  clearIfMatches(ownerScopeId: string, accountGeneration: number, sessionId: number,
    protocol: RemoteProtocol,
    adoption: ActiveRemoteSessionRestoreAdoption | null = null): boolean {
    if (this.termination !== null || !this.restoreOwnerAllows(adoption)) { return false; }
    const active: ActiveRemoteSessionRecord | null = this.getActive();
    if (active === null || active.ownerScopeId !== ownerScopeId ||
      active.accountGeneration !== accountGeneration || active.sessionId !== sessionId ||
      active.protocol !== protocol) {
      return false;
    }
    this.clear('matched-session-clear');
    return true;
  }

  resetForTest(): void {
    this.clear('test-reset');
  }

  private write(record: ActiveRemoteSessionRecord): void {
    AppStorage.setOrCreate<ActiveRemoteSessionRecord>(ACTIVE_REMOTE_SESSION_KEY, record);
  }

  private cloneRestoreAdoption(
    adoption: ActiveRemoteSessionRestoreAdoption
  ): ActiveRemoteSessionRestoreAdoption {
    return {
      ownerScopeId: adoption.ownerScopeId,
      accountGeneration: adoption.accountGeneration,
      sessionId: adoption.sessionId,
      hostId: adoption.hostId,
      protocol: adoption.protocol,
      epoch: adoption.epoch
    };
  }

  private restoreAdoptionEquals(left: ActiveRemoteSessionRestoreAdoption,
    right: ActiveRemoteSessionRestoreAdoption | null): boolean {
    return right !== null && left.ownerScopeId === right.ownerScopeId &&
      left.accountGeneration === right.accountGeneration &&
      left.sessionId === right.sessionId && left.hostId === right.hostId &&
      left.protocol === right.protocol && left.epoch === right.epoch;
  }

  private restoreOwnerAllows(
    adoption: ActiveRemoteSessionRestoreAdoption | null
  ): boolean {
    if (this.restoreAdoption === null) { return adoption === null; }
    return this.restoreAdoptionEquals(this.restoreAdoption, adoption);
  }

  private cloneTermination(
    termination: ActiveRemoteSessionTermination
  ): ActiveRemoteSessionTermination {
    return {
      ownerScopeId: termination.ownerScopeId,
      accountGeneration: termination.accountGeneration,
      sessionId: termination.sessionId,
      hostId: termination.hostId,
      protocol: termination.protocol,
      epoch: termination.epoch
    };
  }
}
