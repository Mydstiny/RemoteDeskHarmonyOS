import { ProEnvironment, ProVerifiedGrant, ProEntitlementState, proGrantState, proGrantMatches } from './ProAccessPolicy';
export type ProVerificationStatus = 'verified' | 'noEntitlement' | 'revoked' | 'unavailable';
export interface ProVerificationResult {
  status: ProVerificationStatus;
  owner: string;
  environment: ProEnvironment;
  grant?: ProVerifiedGrant;
}
export interface ProOrderVerifier {
  verify(records: string[], owner: string, environment: ProEnvironment): Promise<ProVerificationResult>;
}
export interface ProEntitlementSnapshot {
  state: ProEntitlementState;
  entitlementIds: string[];
  needsRevalidation: boolean;
}
export class ProEntitlementService {
  private owner: string = '';
  private environment: ProEnvironment = 'production';
  private accountRevision: number = -1;
  private generation: number = 0;
  private grant: ProVerifiedGrant | null = null;
  private revoked: boolean = false;
  private clockInvalidated: boolean = false;
  private lastObservedTime: number = 0;
  private verificationUnavailable: boolean = false;
  private listeners: Array<() => void> = [];
  private verifier: ProOrderVerifier;
  private now: () => number;
  constructor(verifier: ProOrderVerifier, now: () => number = (): number => Date.now()) {
    this.verifier = verifier;
    this.now = now;
  }

  bindAccount(owner: string, environment: ProEnvironment, revision: number = 0): void {
    if (owner === this.owner && environment === this.environment && revision === this.accountRevision) { return; }
    this.generation++;
    this.owner = owner;
    this.environment = environment;
    this.accountRevision = revision;
    this.grant = null;
    this.clockInvalidated = false;
    this.lastObservedTime = 0;
    this.revoked = false;
    this.verificationUnavailable = false;
    this.publish();
  }
  snapshot(): ProEntitlementSnapshot {
    const now = this.now();
    if (this.grant !== null) {
      if (!Number.isFinite(now) || now < this.lastObservedTime || now >= this.grant.usableUntil) {
        this.clockInvalidated = true;
      }
      if (Number.isFinite(now)) { this.lastObservedTime = Math.max(now, this.lastObservedTime); }
    }
    let state = proGrantState(this.grant, this.owner, this.environment, now);
    if (this.grant !== null && this.clockInvalidated) { state = 'verificationRequired'; }
    if (this.grant === null) {
      state = this.revoked ? 'revoked' : this.verificationUnavailable ? 'verificationRequired' : 'free';
    }
    return { state, entitlementIds: state === 'active' && this.grant !== null ? this.grant.entitlementIds.slice() : [],
      needsRevalidation: this.verificationUnavailable || state === 'verificationRequired' ||
        (this.grant !== null && now >= this.grant.revalidateAfter) };
  }
  nextChangeAt(): number {
    if (this.grant === null || this.clockInvalidated) { return 0; }
    const now = this.now();
    if (now < this.grant.revalidateAfter) { return this.grant.revalidateAfter; }
    return now < this.grant.usableUntil ? this.grant.usableUntil : 0;
  }
  async reconcile(records: string[]): Promise<boolean> {
    if (this.owner.length === 0) { return false; }
    const generation = ++this.generation;
    const owner = this.owner;
    const environment = this.environment;
    let result: ProVerificationResult;
    try { result = await this.verifier.verify(records.slice(), owner, environment); }
    catch (_error) { result = { status: 'unavailable', owner, environment }; }
    if (generation !== this.generation || !result || result.owner !== owner || result.environment !== environment) { return false; }
    if (result.status === 'verified') {
      const grant = result.grant;
      if (!grant || !proGrantMatches(grant, owner, environment, this.now()) || grant.usableUntil <= this.now()) {
        this.verificationUnavailable = true;
      } else {
        this.grant = { owner: grant.owner, environment: grant.environment, productId: grant.productId,
          verifiedAt: grant.verifiedAt, revalidateAfter: grant.revalidateAfter, usableUntil: grant.usableUntil,
          entitlementIds: grant.entitlementIds.slice() };
        this.clockInvalidated = false;
        this.lastObservedTime = this.now();
        this.revoked = false;
        this.verificationUnavailable = false;
      }
    } else if (result.status === 'noEntitlement' || result.status === 'revoked') {
      this.grant = null;
      this.revoked = result.status === 'revoked';
      this.verificationUnavailable = false;
    } else {
      this.verificationUnavailable = true;
    }
    this.publish();
    return this.snapshot().state === 'active';
  }
  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    try { listener(); } catch (_error) { /* isolate UI subscribers */ }
    return (): void => { this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener); };
  }
  refresh(): void { this.publish(); }
  private publish(): void {
    this.listeners.slice().forEach((listener: () => void): void => {
      try { listener(); } catch (_error) { /* one window must not block the others */ }
    });
  }
}
