/**
 * One-shot, process-memory credential handoff for the VNC add-and-connect
 * flow. This is deliberately not a router parameter, preference, cloud row,
 * or RemoteHost field.
 */
export const VNC_SESSION_CREDENTIAL_HANDOFF_TTL_MS: number = 60 * 1000;

export interface VncSessionCredentialDecision {
  password: string;
}

interface PendingVncCredential {
  userId: string;
  hostId: string;
  password: string;
  endpointBindingFingerprint: string;
  accountOwnerScopeId: string;
  accountGeneration: number;
  createdAt: number;
}

export class VncSessionCredentialHandoff {
  private static instance: VncSessionCredentialHandoff;
  private pending: PendingVncCredential[] = [];

  static getInstance(): VncSessionCredentialHandoff {
    if (!VncSessionCredentialHandoff.instance) {
      VncSessionCredentialHandoff.instance = new VncSessionCredentialHandoff();
    }
    return VncSessionCredentialHandoff.instance;
  }

  put(userId: string, hostId: string, password: string,
    endpointBindingFingerprint: string = '',
    accountOwnerScopeId: string = '',
    accountGeneration: number = 0): boolean {
    const normalizedUserId: string = userId.trim();
    const normalizedHostId: string = hostId.trim();
    if (normalizedUserId === '' || normalizedHostId === '') { return false; }
    const normalizedEndpointBinding: string = endpointBindingFingerprint.trim().toLowerCase();
    const normalizedOwnerScopeId: string = accountOwnerScopeId.trim();
    const bindingRequested: boolean = normalizedEndpointBinding !== '' ||
      normalizedOwnerScopeId !== '' || accountGeneration !== 0;
    if (bindingRequested && !this.bindingIsValid(
      normalizedEndpointBinding, normalizedOwnerScopeId, accountGeneration)) { return false; }
    this.removeExpired();
    this.pending = this.pending.filter((item: PendingVncCredential): boolean =>
      !(item.userId === normalizedUserId && item.hostId === normalizedHostId));
    this.pending.push({
      userId: normalizedUserId,
      hostId: normalizedHostId,
      password,
      endpointBindingFingerprint: normalizedEndpointBinding,
      accountOwnerScopeId: normalizedOwnerScopeId,
      accountGeneration,
      createdAt: Date.now()
    });
    return true;
  }

  take(userId: string, hostId: string): string {
    const decision: VncSessionCredentialDecision | null = this.takeDecision(userId, hostId);
    return decision === null ? '' : decision.password;
  }

  takeDecision(userId: string, hostId: string,
    endpointBindingFingerprint: string = '',
    accountOwnerScopeId: string = '',
    accountGeneration: number = 0): VncSessionCredentialDecision | null {
    this.removeExpired();
    const normalizedUserId: string = userId.trim();
    const normalizedHostId: string = hostId.trim();
    for (let i = 0; i < this.pending.length; i++) {
      const item: PendingVncCredential = this.pending[i];
      if (item.userId === normalizedUserId && item.hostId === normalizedHostId) {
        this.pending.splice(i, 1);
        if (!this.bindingMatches(
          item, endpointBindingFingerprint, accountOwnerScopeId, accountGeneration)) {
          return null;
        }
        return { password: item.password };
      }
    }
    return null;
  }

  has(userId: string, hostId: string): boolean {
    this.removeExpired();
    const normalizedUserId: string = userId.trim();
    const normalizedHostId: string = hostId.trim();
    return this.pending.some((item: PendingVncCredential): boolean =>
      item.userId === normalizedUserId && item.hostId === normalizedHostId);
  }

  /**
   * Binds a settings/add-flow credential only after certificate preflight.
   * A credential that was already bound cannot be rebound to a new endpoint.
   */
  bind(userId: string, hostId: string, endpointBindingFingerprint: string,
    accountOwnerScopeId: string, accountGeneration: number): boolean {
    this.removeExpired();
    const normalizedUserId: string = userId.trim();
    const normalizedHostId: string = hostId.trim();
    const normalizedEndpointBinding: string = endpointBindingFingerprint.trim().toLowerCase();
    const normalizedOwnerScopeId: string = accountOwnerScopeId.trim();
    if (normalizedUserId === '' || normalizedHostId === '' || !this.bindingIsValid(
      normalizedEndpointBinding, normalizedOwnerScopeId, accountGeneration)) { return false; }
    for (let i = 0; i < this.pending.length; i++) {
      const item: PendingVncCredential = this.pending[i];
      if (item.userId !== normalizedUserId || item.hostId !== normalizedHostId) { continue; }
      if (item.endpointBindingFingerprint === '' && item.accountOwnerScopeId === '' &&
        item.accountGeneration === 0) {
        item.endpointBindingFingerprint = normalizedEndpointBinding;
        item.accountOwnerScopeId = normalizedOwnerScopeId;
        item.accountGeneration = accountGeneration;
        return true;
      }
      if (this.bindingMatches(
        item, normalizedEndpointBinding, normalizedOwnerScopeId, accountGeneration)) {
        return true;
      }
      this.pending.splice(i, 1);
      return false;
    }
    return false;
  }

  clear(userId: string, hostId: string): void {
    const normalizedUserId: string = userId.trim();
    const normalizedHostId: string = hostId.trim();
    this.pending = this.pending.filter((item: PendingVncCredential): boolean =>
      !(item.userId === normalizedUserId && item.hostId === normalizedHostId));
  }

  clearAll(): void {
    this.pending = [];
  }

  private removeExpired(): void {
    const now: number = Date.now();
    this.pending = this.pending.filter((item: PendingVncCredential): boolean =>
      now - item.createdAt <= VNC_SESSION_CREDENTIAL_HANDOFF_TTL_MS);
  }

  private bindingIsValid(endpointBindingFingerprint: string,
    accountOwnerScopeId: string, accountGeneration: number): boolean {
    return endpointBindingFingerprint.length === 64 &&
      /^[0-9a-f]{64}$/.test(endpointBindingFingerprint) &&
      accountOwnerScopeId !== '' && Number.isSafeInteger(accountGeneration) &&
      accountGeneration > 0;
  }

  private bindingMatches(item: PendingVncCredential,
    endpointBindingFingerprint: string,
    accountOwnerScopeId: string,
    accountGeneration: number): boolean {
    const expectedEndpointBinding: string = endpointBindingFingerprint.trim().toLowerCase();
    const expectedOwnerScopeId: string = accountOwnerScopeId.trim();
    const bindingExpected: boolean = expectedEndpointBinding !== '' ||
      expectedOwnerScopeId !== '' || accountGeneration !== 0;
    if (!bindingExpected) { return true; }
    return this.bindingIsValid(
      expectedEndpointBinding, expectedOwnerScopeId, accountGeneration) &&
      item.endpointBindingFingerprint === expectedEndpointBinding &&
      item.accountOwnerScopeId === expectedOwnerScopeId &&
      item.accountGeneration === accountGeneration;
  }
}
