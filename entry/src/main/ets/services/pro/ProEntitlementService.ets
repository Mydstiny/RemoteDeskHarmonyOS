import { ProEnvironment, ProVerifiedGrant, ProEntitlementState, proGrantState, proGrantMatches } from './ProAccessPolicy';
export type ProVerificationStatus = 'verified' | 'noEntitlement' | 'revoked' | 'unavailable';
export interface ProVerificationResult {
  status: ProVerificationStatus;
  owner: string;
  environment: ProEnvironment;
  grant?: ProVerifiedGrant;
  fromCache?: boolean;
  needsRevalidation?: boolean;
  refundPending?: boolean;
}
export interface ProOrderVerifier {
  verify(records: string[], owner: string, environment: ProEnvironment): Promise<ProVerificationResult>;
  loadCached?(owner: string, environment: ProEnvironment): Promise<ProVerificationResult>;
}
export interface ProEntitlementSnapshot {
  state: ProEntitlementState;
  entitlementIds: string[];
  needsRevalidation: boolean;
  environment: ProEnvironment;
  refundPending: boolean;
}
export interface ProReconciliationOutcome { current: boolean; online: boolean; active: boolean; }
export class ProEntitlementService {
  private owner: string = '';
  private environment: ProEnvironment = 'production';
  private accountRevision: number = -1;
  private generation: number = 0;
  private acceptedGeneration: number = 0;
  private grant: ProVerifiedGrant | null = null;
  private revoked: boolean = false;
  private clockInvalidated: boolean = false;
  private lastObservedTime: number = 0;
  private verificationUnavailable: boolean = false;
  private refundPending: boolean = false;
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
    this.acceptedGeneration = this.generation;
    this.owner = owner;
    this.environment = environment;
    this.accountRevision = revision;
    this.grant = null;
    this.clockInvalidated = false;
    this.lastObservedTime = 0;
    this.revoked = false;
    this.verificationUnavailable = false;
    this.refundPending = false;
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
    if (this.grant !== null && (this.clockInvalidated || this.refundPending)) { state = 'verificationRequired'; }
    if (this.grant === null) {
      state = this.revoked ? 'revoked' : this.verificationUnavailable ? 'verificationRequired' : 'free';
    }
    return { state, environment: this.environment,
      entitlementIds: state === 'active' && this.grant !== null ? this.grant.entitlementIds.slice() : [],
      needsRevalidation: this.verificationUnavailable || state === 'verificationRequired' ||
        this.refundPending || (this.grant !== null && now >= this.grant.revalidateAfter), refundPending: this.refundPending };
  }
  nextChangeAt(): number {
    if (this.grant === null || this.clockInvalidated) { return 0; }
    const now = this.now();
    if (now < this.grant.revalidateAfter) { return this.grant.revalidateAfter; }
    return now < this.grant.usableUntil ? this.grant.usableUntil : 0;
  }
  nextChangeDelay(): number {
    const next = this.nextChangeAt();
    const now = this.now();
    return next > 0 && Number.isFinite(now) ? Math.max(1, next - now) : 0;
  }
  markRefundPending(): void {
    this.refundPending = true;
    this.publish();
  }
  async restoreCached(): Promise<boolean> {
    if (this.owner.length === 0 || !this.verifier.loadCached) { return false; }
    const generation = ++this.generation;
    const owner = this.owner;
    const environment = this.environment;
    let result: ProVerificationResult;
    try { result = await this.verifier.loadCached(owner, environment); }
    catch (_error) { result = { status: 'unavailable', owner, environment, fromCache: true }; }
    return this.acceptResult(result, generation, owner, environment);
  }
  async reconcile(records: string[], requireOnline: boolean = false): Promise<boolean> {
    const result = await this.reconcileResult(records);
    return result.active && (!requireOnline || result.online);
  }
  async reconcileResult(records: string[]): Promise<ProReconciliationOutcome> {
    if (this.owner.length === 0) { return { current: false, online: false, active: false }; }
    const generation = ++this.generation;
    const owner = this.owner;
    const environment = this.environment;
    let result: ProVerificationResult;
    try { result = await this.verifier.verify(records.slice(), owner, environment); }
    catch (_error) { result = { status: 'unavailable', owner, environment }; }
    const active = this.acceptResult(result, generation, owner, environment);
    const current = !!result && generation === this.acceptedGeneration && this.owner === owner &&
      this.environment === environment && result.owner === owner && result.environment === environment;
    const valid = !!result && (result.status === 'noEntitlement' || result.status === 'revoked' ||
      (result.status === 'verified' && result.grant !== undefined &&
        proGrantMatches(result.grant, owner, environment, this.now()) && result.grant.usableUntil > this.now()));
    return { current, active, online: current && valid && result.fromCache !== true };
  }
  private acceptResult(result: ProVerificationResult, generation: number,
    owner: string, environment: ProEnvironment): boolean {
    if (generation <= this.acceptedGeneration || this.owner !== owner || this.environment !== environment ||
      !result || result.owner !== owner || result.environment !== environment) { return false; }
    // A later request still waiting for the server must not hide an observed
    // refund. Only an already accepted newer result supersedes this result.
    this.acceptedGeneration = generation;
    // Once a refund has been submitted, an active, cached or unavailable
    // result cannot clear the local fail-closed state. Only the signed
    // revoked/noEntitlement branches below may release that fence.
    if (result.refundPending === true) { this.refundPending = true; }
    if (result.status === 'verified') {
      const grant = result.grant;
      if (!grant || !proGrantMatches(grant, owner, environment, this.now()) || grant.usableUntil <= this.now()) {
        this.verificationUnavailable = true;
      } else {
        this.grant = { owner: grant.owner, environment: grant.environment, productId: grant.productId,
          verifiedAt: grant.verifiedAt, revalidateAfter: grant.revalidateAfter, usableUntil: grant.usableUntil,
          entitlementIds: grant.entitlementIds.slice() };
        if (result.fromCache !== true) { this.clockInvalidated = false; }
        this.lastObservedTime = result.fromCache === true ? Math.max(this.now(), this.lastObservedTime) : this.now();
        this.revoked = false;
        this.verificationUnavailable = result.needsRevalidation === true;
      }
    } else if (result.status === 'noEntitlement' || result.status === 'revoked') {
      this.grant = null;
      this.revoked = result.status === 'revoked';
      this.verificationUnavailable = result.needsRevalidation === true;
      if (result.fromCache !== true) { this.refundPending = false; }
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
