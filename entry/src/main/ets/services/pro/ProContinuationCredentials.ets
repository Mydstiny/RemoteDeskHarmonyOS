/**
 * Optional, user-enabled secret transfer for one continuation. It never travels in the
 * whitelisted envelope: the source attaches it as a separate parameter of the platform's
 * authenticated same-account continuation, the target validates it and holds it only in memory
 * for one connection to that host.
 */
export type ProContinuationSecretKind = 'password' | 'key';
export interface ProContinuationSecret {
  kind: ProContinuationSecretKind;
  password: string;
  privateKeyPem: string;
  passphrase: string;
  /** RDP carries its Windows account with the password; empty for the other protocols. */
  username?: string;
}
const PASSWORD_MAX: number = 1024;
const KEY_MAX: number = 32768;
const USERNAME_MAX: number = 256;

export function validProContinuationSecret(value: Object | null | undefined): ProContinuationSecret | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) { return null; }
  const keys: string[] = Object.keys(value);
  const base: string[] = ['kind', 'password', 'privateKeyPem', 'passphrase'];
  if (base.some((key: string): boolean => keys.indexOf(key) < 0) ||
      keys.some((key: string): boolean => base.indexOf(key) < 0 && key !== 'username')) { return null; }
  const secret = value as ProContinuationSecret;
  const username: string = keys.indexOf('username') >= 0 ? (secret.username as string) : '';
  if (typeof username !== 'string' || username.length > USERNAME_MAX) { return null; }
  if (typeof secret.password !== 'string' || typeof secret.privateKeyPem !== 'string' ||
      typeof secret.passphrase !== 'string' || secret.password.length > PASSWORD_MAX ||
      secret.privateKeyPem.length > KEY_MAX || secret.passphrase.length > PASSWORD_MAX) { return null; }
  if (secret.kind === 'password') {
    return secret.password.length > 0 && secret.privateKeyPem === '' && secret.passphrase === '' ?
      { kind: 'password', password: secret.password, privateKeyPem: '', passphrase: '', username } : null;
  }
  if (secret.kind === 'key') {
    return secret.privateKeyPem.includes('PRIVATE KEY') && secret.password === '' ?
      { kind: 'key', password: '', privateKeyPem: secret.privateKeyPem, passphrase: secret.passphrase, username: '' } : null;
  }
  return null;
}

/** Target-side, in-memory, one-shot secret for the next connection to one host of one account. */
export class ProContinuationCredentialHandoff {
  private static instance: ProContinuationCredentialHandoff | null = null;
  private hostId: string = '';
  private owner: string = '';
  private secret: ProContinuationSecret | null = null;
  private expiresAt: number = 0;

  static getInstance(): ProContinuationCredentialHandoff {
    if (ProContinuationCredentialHandoff.instance === null) {
      ProContinuationCredentialHandoff.instance = new ProContinuationCredentialHandoff();
    }
    return ProContinuationCredentialHandoff.instance;
  }
  deposit(hostId: string, owner: string, secret: ProContinuationSecret, ttlMs: number = 120000): void {
    this.hostId = hostId; this.owner = owner; this.secret = secret; this.expiresAt = Date.now() + ttlMs;
  }
  take(hostId: string, owner: string): ProContinuationSecret | null {
    if (this.secret === null || Date.now() >= this.expiresAt) { this.clear(); return null; }
    // Another host's connection neither sees nor consumes it.
    if (this.hostId !== hostId || this.owner !== owner || owner === '') { return null; }
    const secret = this.secret;
    this.clear();
    return secret;
  }
  clear(): void { this.hostId = ''; this.owner = ''; this.secret = null; this.expiresAt = 0; }
}
