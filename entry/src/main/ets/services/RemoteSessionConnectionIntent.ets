/**
 * Process-local navigation intent for settings pages that request a remote
 * connection. It carries no credential or trust decision: HostList consumes
 * it and re-enters the protocol's existing lock/preflight/authentication flow.
 */
export type RemoteSessionConnectionIntentProtocol = 'vnc';
export type RemoteSessionConnectionIntentReason =
  'connect' | 'authentication_retry' | 'certificate_retry';

export interface RemoteSessionConnectionIntentValue {
  protocol: RemoteSessionConnectionIntentProtocol;
  reason: RemoteSessionConnectionIntentReason;
  replaceSavedCredential: boolean;
  hostId: string;
  issuedAtMs: number;
  expiresAtMs: number;
}

const CONNECTION_INTENT_TTL_MS: number = 15000;

export class RemoteSessionConnectionIntent {
  private static instance: RemoteSessionConnectionIntent | null = null;
  private value: RemoteSessionConnectionIntentValue | null = null;

  static getInstance(): RemoteSessionConnectionIntent {
    if (RemoteSessionConnectionIntent.instance === null) {
      RemoteSessionConnectionIntent.instance = new RemoteSessionConnectionIntent();
    }
    return RemoteSessionConnectionIntent.instance;
  }

  put(protocol: RemoteSessionConnectionIntentProtocol, hostId: string,
    nowMs: number = Date.now(),
    reason: RemoteSessionConnectionIntentReason = 'connect',
    replaceSavedCredential: boolean = false): boolean {
    const normalizedHostId: string = hostId.trim();
    if (normalizedHostId.length === 0 || normalizedHostId.length > 256) { return false; }
    this.value = {
      protocol,
      reason,
      replaceSavedCredential,
      hostId: normalizedHostId,
      issuedAtMs: nowMs,
      expiresAtMs: nowMs + CONNECTION_INTENT_TTL_MS
    };
    return true;
  }

  take(nowMs: number = Date.now()): RemoteSessionConnectionIntentValue | null {
    const value: RemoteSessionConnectionIntentValue | null = this.value;
    this.value = null;
    if (value === null || value.expiresAtMs < nowMs) { return null; }
    return value;
  }

  resetForTest(): void { this.value = null; }
}
