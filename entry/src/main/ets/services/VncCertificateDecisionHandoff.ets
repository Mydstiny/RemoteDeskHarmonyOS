import { isVncSha256Fingerprint } from './VncCertificatePreflightPolicy';

export const VNC_CERTIFICATE_DECISION_HANDOFF_TTL_MS: number = 60 * 1000;

interface PendingVncCertificateDecision {
  userId: string;
  accountOwnerScopeId: string;
  accountStoreIdentityFingerprint: string;
  accountGeneration: number;
  attemptId: string;
  generation: number;
  endpointBindingFingerprint: string;
  fingerprintSha256: string;
  createdAt: number;
}

function isPositiveGeneration(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0;
}

/** Process-memory, one-shot pin handoff. It is never serialized or synced. */
export class VncCertificateDecisionHandoff {
  private static instance: VncCertificateDecisionHandoff;
  private pending: PendingVncCertificateDecision[] = [];

  /** Shared process-memory handoff used when the preflight Sheet owns routing. */
  static getInstance(): VncCertificateDecisionHandoff {
    if (!VncCertificateDecisionHandoff.instance) {
      VncCertificateDecisionHandoff.instance = new VncCertificateDecisionHandoff();
    }
    return VncCertificateDecisionHandoff.instance;
  }

  put(userId: string, attemptId: string, generation: number,
    endpointBindingFingerprint: string, fingerprintSha256: string,
    accountOwnerScopeId: string, accountStoreIdentityFingerprint: string,
    accountGeneration: number,
    now: number = Date.now()): boolean {
    const normalizedUserId: string = userId.trim();
    const normalizedAccountOwner: string = accountOwnerScopeId.trim();
    const normalizedAccountStore: string = accountStoreIdentityFingerprint.trim().toLowerCase();
    const normalizedAttemptId: string = attemptId.trim();
    const normalizedBinding: string = endpointBindingFingerprint.trim().toLowerCase();
    const normalizedFingerprint: string = fingerprintSha256.trim().toLowerCase();
    if (normalizedUserId === '' || normalizedAccountOwner === '' || normalizedUserId !== normalizedAccountOwner ||
      !isVncSha256Fingerprint(normalizedAccountStore) || !isPositiveGeneration(accountGeneration) ||
      normalizedAttemptId === '' || !isPositiveGeneration(generation) ||
      !isVncSha256Fingerprint(normalizedBinding) || !isVncSha256Fingerprint(normalizedFingerprint)) {
      return false;
    }
    this.removeExpired(now);
    this.pending = this.pending.filter((item: PendingVncCertificateDecision): boolean =>
      !(item.userId === normalizedUserId && item.attemptId === normalizedAttemptId));
    this.pending.push({
      userId: normalizedUserId,
      accountOwnerScopeId: normalizedAccountOwner,
      accountStoreIdentityFingerprint: normalizedAccountStore,
      accountGeneration: accountGeneration,
      attemptId: normalizedAttemptId,
      generation: generation,
      endpointBindingFingerprint: normalizedBinding,
      fingerprintSha256: normalizedFingerprint,
      createdAt: now
    });
    return true;
  }

  take(userId: string, attemptId: string, generation: number,
    endpointBindingFingerprint: string, accountOwnerScopeId: string,
    accountStoreIdentityFingerprint: string, accountGeneration: number,
    now: number = Date.now()): string {
    this.removeExpired(now);
    const normalizedUserId: string = userId.trim();
    const normalizedAttemptId: string = attemptId.trim();
    const normalizedBinding: string = endpointBindingFingerprint.trim().toLowerCase();
    const normalizedAccountOwner: string = accountOwnerScopeId.trim();
    const normalizedAccountStore: string = accountStoreIdentityFingerprint.trim().toLowerCase();
    if (normalizedUserId === '' || normalizedAccountOwner === '' ||
      normalizedUserId !== normalizedAccountOwner || !isPositiveGeneration(generation) ||
      !isPositiveGeneration(accountGeneration) || !isVncSha256Fingerprint(normalizedBinding) ||
      !isVncSha256Fingerprint(normalizedAccountStore)) { return ''; }
    for (let i = 0; i < this.pending.length; i++) {
      const item: PendingVncCertificateDecision = this.pending[i];
      if (item.userId === normalizedUserId && item.attemptId === normalizedAttemptId &&
        item.accountOwnerScopeId === normalizedAccountOwner &&
        item.accountStoreIdentityFingerprint === normalizedAccountStore &&
        item.accountGeneration === accountGeneration && item.generation === generation &&
        item.endpointBindingFingerprint === normalizedBinding) {
        this.pending.splice(i, 1);
        return item.fingerprintSha256;
      }
    }
    return '';
  }

  clear(userId: string, attemptId: string): void {
    const normalizedUserId: string = userId.trim();
    const normalizedAttemptId: string = attemptId.trim();
    this.pending = this.pending.filter((item: PendingVncCertificateDecision): boolean =>
      !(item.userId === normalizedUserId && item.attemptId === normalizedAttemptId));
  }

  clearAll(): void { this.pending = []; }

  private removeExpired(now: number): void {
    this.pending = this.pending.filter((item: PendingVncCertificateDecision): boolean =>
      now - item.createdAt <= VNC_CERTIFICATE_DECISION_HANDOFF_TTL_MS);
  }
}
