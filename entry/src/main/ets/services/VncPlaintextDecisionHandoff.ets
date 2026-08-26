import { isVncSha256Fingerprint } from './VncCertificatePreflightPolicy';

export const VNC_PLAINTEXT_DECISION_HANDOFF_TTL_MS: number = 60 * 1000;

interface PendingVncPlaintextDecision {
  userId: string;
  attemptId: string;
  generation: number;
  endpointBindingFingerprint: string;
  accountOwnerScopeId: string;
  accountStoreIdentityFingerprint: string;
  accountGeneration: number;
  createdAt: number;
}

function isPositiveGeneration(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0;
}

/** Process-memory, endpoint-bound proof that plaintext transport was confirmed. */
export class VncPlaintextDecisionHandoff {
  private static instance: VncPlaintextDecisionHandoff | null = null;
  private pending: PendingVncPlaintextDecision[] = [];

  static getInstance(): VncPlaintextDecisionHandoff {
    if (VncPlaintextDecisionHandoff.instance === null) {
      VncPlaintextDecisionHandoff.instance = new VncPlaintextDecisionHandoff();
    }
    return VncPlaintextDecisionHandoff.instance;
  }

  put(userId: string, attemptId: string, generation: number,
    endpointBindingFingerprint: string, accountOwnerScopeId: string,
    accountStoreIdentityFingerprint: string, accountGeneration: number,
    nowMs: number = Date.now()): boolean {
    const normalizedUserId: string = userId.trim();
    const normalizedAttemptId: string = attemptId.trim();
    const normalizedEndpoint: string = endpointBindingFingerprint.trim().toLowerCase();
    const normalizedOwner: string = accountOwnerScopeId.trim();
    const normalizedStore: string = accountStoreIdentityFingerprint.trim().toLowerCase();
    if (normalizedUserId === '' || normalizedAttemptId === '' ||
      normalizedUserId !== normalizedOwner || !isPositiveGeneration(generation) ||
      !isVncSha256Fingerprint(normalizedEndpoint) ||
      !isVncSha256Fingerprint(normalizedStore) ||
      !isPositiveGeneration(accountGeneration)) { return false; }
    this.removeExpired(nowMs);
    this.pending = this.pending.filter((item: PendingVncPlaintextDecision): boolean =>
      !(item.userId === normalizedUserId && item.attemptId === normalizedAttemptId));
    this.pending.push({
      userId: normalizedUserId,
      attemptId: normalizedAttemptId,
      generation,
      endpointBindingFingerprint: normalizedEndpoint,
      accountOwnerScopeId: normalizedOwner,
      accountStoreIdentityFingerprint: normalizedStore,
      accountGeneration,
      createdAt: nowMs
    });
    return true;
  }

  take(userId: string, attemptId: string, generation: number,
    endpointBindingFingerprint: string, accountOwnerScopeId: string,
    accountStoreIdentityFingerprint: string, accountGeneration: number,
    nowMs: number = Date.now()): boolean {
    this.removeExpired(nowMs);
    const normalizedUserId: string = userId.trim();
    const normalizedAttemptId: string = attemptId.trim();
    const normalizedEndpoint: string = endpointBindingFingerprint.trim().toLowerCase();
    const normalizedOwner: string = accountOwnerScopeId.trim();
    const normalizedStore: string = accountStoreIdentityFingerprint.trim().toLowerCase();
    for (let i = 0; i < this.pending.length; i++) {
      const item: PendingVncPlaintextDecision = this.pending[i];
      if (item.userId !== normalizedUserId || item.attemptId !== normalizedAttemptId) { continue; }
      this.pending.splice(i, 1);
      return item.generation === generation &&
        item.endpointBindingFingerprint === normalizedEndpoint &&
        item.accountOwnerScopeId === normalizedOwner &&
        item.accountStoreIdentityFingerprint === normalizedStore &&
        item.accountGeneration === accountGeneration;
    }
    return false;
  }

  clear(userId: string, attemptId: string): void {
    const normalizedUserId: string = userId.trim();
    const normalizedAttemptId: string = attemptId.trim();
    this.pending = this.pending.filter((item: PendingVncPlaintextDecision): boolean =>
      !(item.userId === normalizedUserId && item.attemptId === normalizedAttemptId));
  }

  clearAll(): void { this.pending = []; }

  private removeExpired(nowMs: number): void {
    this.pending = this.pending.filter((item: PendingVncPlaintextDecision): boolean =>
      nowMs - item.createdAt <= VNC_PLAINTEXT_DECISION_HANDOFF_TTL_MS);
  }
}
