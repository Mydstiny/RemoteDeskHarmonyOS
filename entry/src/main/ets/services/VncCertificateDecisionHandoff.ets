import { isVncSha256Fingerprint } from './VncCertificatePreflightPolicy';

export const VNC_CERTIFICATE_DECISION_HANDOFF_TTL_MS: number = 60 * 1000;

interface PendingVncCertificateDecision {
  userId: string;
  attemptId: string;
  generation: number;
  endpointBindingFingerprint: string;
  fingerprintSha256: string;
  createdAt: number;
}

/** Process-memory, one-shot pin handoff. It is never serialized or synced. */
export class VncCertificateDecisionHandoff {
  private pending: PendingVncCertificateDecision[] = [];

  put(userId: string, attemptId: string, generation: number,
    endpointBindingFingerprint: string, fingerprintSha256: string,
    now: number = Date.now()): boolean {
    const normalizedUserId: string = userId.trim();
    const normalizedAttemptId: string = attemptId.trim();
    const normalizedBinding: string = endpointBindingFingerprint.trim().toLowerCase();
    const normalizedFingerprint: string = fingerprintSha256.trim().toLowerCase();
    if (normalizedUserId === '' || normalizedAttemptId === '' || generation <= 0 ||
      !isVncSha256Fingerprint(normalizedBinding) || !isVncSha256Fingerprint(normalizedFingerprint)) {
      return false;
    }
    this.removeExpired(now);
    this.pending = this.pending.filter((item: PendingVncCertificateDecision): boolean =>
      !(item.userId === normalizedUserId && item.attemptId === normalizedAttemptId));
    this.pending.push({
      userId: normalizedUserId,
      attemptId: normalizedAttemptId,
      generation: generation,
      endpointBindingFingerprint: normalizedBinding,
      fingerprintSha256: normalizedFingerprint,
      createdAt: now
    });
    return true;
  }

  take(userId: string, attemptId: string, generation: number,
    endpointBindingFingerprint: string, now: number = Date.now()): string {
    this.removeExpired(now);
    const normalizedUserId: string = userId.trim();
    const normalizedAttemptId: string = attemptId.trim();
    const normalizedBinding: string = endpointBindingFingerprint.trim().toLowerCase();
    for (let i = 0; i < this.pending.length; i++) {
      const item: PendingVncCertificateDecision = this.pending[i];
      if (item.userId === normalizedUserId && item.attemptId === normalizedAttemptId &&
        item.generation === generation && item.endpointBindingFingerprint === normalizedBinding) {
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
