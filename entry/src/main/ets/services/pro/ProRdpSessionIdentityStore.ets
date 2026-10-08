import { NativeDisconnectIdentity } from '../ExtensionLoader';
import { AccountSessionCoordinator } from '../AccountSessionCoordinator';
import { ProRdpConnectionIdentity, validProRdpConnectionIdentity,
  copyProRdpConnectionIdentity } from './ProRdpConnectionIdentity';

interface ProRdpSessionIdentityRecord {
  hostId: string;
  accountOwner: string;
  accountGeneration: number;
  identity: ProRdpConnectionIdentity;
}

/** Local-process identity receipt for an already authenticated native session.
 * The native owner survives the existing authenticated PC window handoff;
 * account transitions and exact native teardown invalidate its receipt. */
export class ProRdpSessionIdentityStore {
  private static instance: ProRdpSessionIdentityStore = new ProRdpSessionIdentityStore();
  private records: Map<string, ProRdpSessionIdentityRecord> = new Map<string, ProRdpSessionIdentityRecord>();
  private transitionActive: boolean = true;
  private constructor() {
    AccountSessionCoordinator.getInstance().onTransitionActivity((active: boolean): void => {
      this.transitionActive = active;
      if (active) { this.records.clear(); }
    });
  }
  static getInstance(): ProRdpSessionIdentityStore { return ProRdpSessionIdentityStore.instance; }
  private key(owner: NativeDisconnectIdentity | null): string {
    if (owner === null || !Number.isSafeInteger(owner.sessionId) || owner.sessionId <= 0 ||
      !Number.isSafeInteger(owner.generation) || owner.generation <= 0 ||
      !Number.isSafeInteger(owner.ownerToken) || owner.ownerToken <= 0) { return ''; }
    return owner.sessionId.toString() + ':' + owner.generation.toString() + ':' + owner.ownerToken.toString();
  }
  remember(hostId: string, owner: NativeDisconnectIdentity | null, identity: ProRdpConnectionIdentity): boolean {
    const key = this.key(owner); const scope = AccountSessionCoordinator.getInstance().currentScope();
    if (key === '' || hostId === '' || this.transitionActive || scope.kind !== 'huawei_account' ||
      !validProRdpConnectionIdentity(identity)) { return false; }
    if (!this.records.has(key) && this.records.size >= 16) {
      // A missing receipt only disables preparation; it never terminates a session.
      const oldest: string[] = Array.from(this.records.keys()); this.records.delete(oldest[0]);
    }
    this.records.set(key, { hostId, accountOwner: scope.ownerScopeId, accountGeneration: scope.generation,
      identity: copyProRdpConnectionIdentity(identity) });
    return true;
  }
  get(hostId: string, owner: NativeDisconnectIdentity | null): ProRdpConnectionIdentity | null {
    const record = this.records.get(this.key(owner)); const scope = AccountSessionCoordinator.getInstance().currentScope();
    if (record === undefined || this.transitionActive || scope.kind !== 'huawei_account' ||
      record.hostId !== hostId || record.accountOwner !== scope.ownerScopeId ||
      record.accountGeneration !== scope.generation) { return null; }
    return copyProRdpConnectionIdentity(record.identity);
  }
  forget(owner: NativeDisconnectIdentity | null): void { this.records.delete(this.key(owner)); }
}
