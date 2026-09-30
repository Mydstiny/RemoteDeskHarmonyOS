import { common } from '@kit.AbilityKit';
import { distributedDataObject } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

/**
 * Optional, user-enabled secret transfer for one continuation. It never travels in the
 * continuation envelope: the source offers it on a separate same-account data object whose
 * session is derived from the envelope's random channel, the target takes it once, and it is
 * held only in memory for one connection to that host.
 */
export type ProContinuationSecretKind = 'password' | 'key';
export interface ProContinuationSecret {
  kind: ProContinuationSecretKind;
  password: string;
  privateKeyPem: string;
  passphrase: string;
}
const PASSWORD_MAX: number = 1024;
const KEY_MAX: number = 32768;

export function validProContinuationSecret(value: Object | null | undefined): ProContinuationSecret | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) { return null; }
  const keys: string[] = Object.keys(value);
  if (keys.length !== 4 || ['kind', 'password', 'privateKeyPem', 'passphrase'].some((key: string): boolean =>
    keys.indexOf(key) < 0)) { return null; }
  const secret = value as ProContinuationSecret;
  if (typeof secret.password !== 'string' || typeof secret.privateKeyPem !== 'string' ||
      typeof secret.passphrase !== 'string' || secret.password.length > PASSWORD_MAX ||
      secret.privateKeyPem.length > KEY_MAX || secret.passphrase.length > PASSWORD_MAX) { return null; }
  if (secret.kind === 'password') {
    return secret.password.length > 0 && secret.privateKeyPem === '' && secret.passphrase === '' ?
      { kind: 'password', password: secret.password, privateKeyPem: '', passphrase: '' } : null;
  }
  if (secret.kind === 'key') {
    return secret.privateKeyPem.includes('PRIVATE KEY') && secret.password === '' ?
      { kind: 'key', password: '', privateKeyPem: secret.privateKeyPem, passphrase: secret.passphrase } : null;
  }
  return null;
}

/** Credential session derived from the envelope's random channel id; unrelated devices cannot guess it. */
export function proContinuationCredentialSession(channelId: string): string {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: new util.TextEncoder().encodeInto(channelId + ':credential') });
  let hex = '';
  md.digestSync().data.forEach((byte: number): void => { hex += byte.toString(16).padStart(2, '0'); });
  return 'rd_' + hex.substring(0, 32);
}

// Official continuation data path: live object sync between the two devices is not available
// during continuation (the target sees no collaboration peer), so the source saves the object for
// the continuation target inside onContinue and the target restores it when it joins the session.
// The source revokes the save when the transfer expires or is cancelled; the target reads once,
// wipes its copy and leaves the session.
interface CredentialFields { secret: string; }
interface CredentialObject extends distributedDataObject.DataObject { secret: string; }

export class ProContinuationCredentialChannel {
  private object: CredentialObject | null = null;
  private status: ((session: string, networkId: string, status: string) => void) | null = null;
  private saved: boolean = false;
  private timer: number = -1;
  private generation: number = 0;

  private valid(session: string, expiresAt: number): boolean {
    return /^rd_[a-f0-9]{32}$/.test(session) && expiresAt > Date.now() && expiresAt - Date.now() <= 120000 &&
      canIUse('SystemCapability.DistributedDataManager.DataObject.DistributedObject');
  }

  /** Source: saves the secret for the continuation target device until the transfer expires. */
  async offer(context: common.Context, session: string, secret: ProContinuationSecret, expiresAt: number,
    targetDevice: string): Promise<boolean> {
    this.close();
    if (!this.valid(session, expiresAt) || validProContinuationSecret(secret) === null ||
        targetDevice.length === 0 || targetDevice.length > 256) { return false; }
    const generation = this.generation;
    const fields: CredentialFields = { secret: JSON.stringify(secret) };
    let object: CredentialObject;
    try { object = distributedDataObject.create(context, fields) as CredentialObject; } catch (_error) { return false; }
    this.object = object;
    try {
      this.timer = setTimeout((): void => { if (generation === this.generation) { this.close(); } }, expiresAt - Date.now());
      await object.setSessionId(session);
      if (generation !== this.generation) { return false; }
      await object.save(targetDevice);
      if (generation !== this.generation) { return false; }
      this.saved = true;
      return true;
    } catch (_error) {
      if (generation === this.generation) { this.close(); }
      return false;
    }
  }

  /** Target: restores the saved secret once, waiting briefly for the restore to complete. */
  async receive(context: common.Context, session: string, expiresAt: number, waitMs: number): Promise<ProContinuationSecret | null> {
    this.close();
    if (!this.valid(session, expiresAt)) { return null; }
    const generation = this.generation;
    const fields: CredentialFields = { secret: '' };
    let object: CredentialObject;
    try { object = distributedDataObject.create(context, fields) as CredentialObject; } catch (_error) { return null; }
    this.object = object;
    return new Promise<ProContinuationSecret | null>((resolve: (value: ProContinuationSecret | null) => void): void => {
      let settled = false;
      const finish = (value: ProContinuationSecret | null): void => {
        if (settled) { return; }
        settled = true;
        if (generation === this.generation) { this.close(); }
        resolve(value);
      };
      const read = (): void => {
        if (generation !== this.generation) { finish(null); return; }
        try {
          if (typeof object.secret === 'string' && object.secret.length > 0 && object.secret.length <= KEY_MAX + 4096) {
            finish(validProContinuationSecret(JSON.parse(object.secret) as Object));
          }
        } catch (_error) { finish(null); }
      };
      const status = (sessionId: string, _networkId: string, value: string): void => {
        if (sessionId === session && value === 'restored') { read(); }
      };
      this.status = status;
      try { object.on('status', status); } catch (_error) { finish(null); return; }
      this.timer = setTimeout((): void => { read(); finish(null); }, Math.max(0, Math.min(waitMs, expiresAt - Date.now())));
      object.setSessionId(session).then((): void => {
        read();
        if (waitMs <= 0) { finish(null); }
      }).catch((): void => { finish(null); });
    });
  }

  close(): void {
    this.generation++;
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    const object = this.object; const status = this.status; const saved = this.saved;
    this.object = null; this.status = null; this.saved = false;
    if (object === null) { return; }
    try { object.secret = ''; } catch (_error) { /* best effort wipe before leaving the session */ }
    if (saved) { try { void object.revokeSave().catch((): void => {}); } catch (_error) {} }
    try { if (status !== null) { object.off('status', status); } } catch (_error) {}
    try { void object.setSessionId('').catch((): void => {}); } catch (_error) {}
  }
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
