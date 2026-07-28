/**
 * One-shot, process-memory credential handoff for the VNC add-and-connect
 * flow. This is deliberately not a router parameter, preference, cloud row,
 * or RemoteHost field.
 */
export const VNC_SESSION_CREDENTIAL_HANDOFF_TTL_MS: number = 60 * 1000;

interface PendingVncCredential {
  userId: string;
  hostId: string;
  password: string;
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

  put(userId: string, hostId: string, password: string): void {
    const normalizedUserId: string = userId.trim();
    const normalizedHostId: string = hostId.trim();
    if (normalizedUserId === '' || normalizedHostId === '' || password.length === 0) { return; }
    this.removeExpired();
    this.pending = this.pending.filter((item: PendingVncCredential): boolean =>
      !(item.userId === normalizedUserId && item.hostId === normalizedHostId));
    this.pending.push({
      userId: normalizedUserId,
      hostId: normalizedHostId,
      password,
      createdAt: Date.now()
    });
  }

  take(userId: string, hostId: string): string {
    this.removeExpired();
    const normalizedUserId: string = userId.trim();
    const normalizedHostId: string = hostId.trim();
    for (let i = 0; i < this.pending.length; i++) {
      const item: PendingVncCredential = this.pending[i];
      if (item.userId === normalizedUserId && item.hostId === normalizedHostId) {
        this.pending.splice(i, 1);
        return item.password;
      }
    }
    return '';
  }

  clear(userId: string, hostId: string): void {
    const normalizedUserId: string = userId.trim();
    const normalizedHostId: string = hostId.trim();
    this.pending = this.pending.filter((item: PendingVncCredential): boolean =>
      !(item.userId === normalizedUserId && item.hostId === normalizedHostId));
  }

  private removeExpired(): void {
    const now: number = Date.now();
    this.pending = this.pending.filter((item: PendingVncCredential): boolean =>
      now - item.createdAt <= VNC_SESSION_CREDENTIAL_HANDOFF_TTL_MS);
  }
}
