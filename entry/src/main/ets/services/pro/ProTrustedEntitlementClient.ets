import { DEBUG } from 'BuildProfile';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { ProEnvironment } from './ProAccessPolicy';
import { ProOrderVerifier, ProVerificationResult } from './ProEntitlementService';
import { ProEntitlementClock } from './ProEntitlementClock';
import { ProCachedRecord, ProEntitlementStorePort, ProStoreScope } from './ProEntitlementStore';
import { ProSignedEntitlementVerifier, ProTrustConfiguration, ProTrustedSnapshot } from './ProSignedEntitlement';

export type ProBackendOperation = 'intents' | 'reconcile' | 'refund-order';
export interface ProBackendTransport {
  post(operation: ProBackendOperation, body: string, isCurrent: () => boolean): Promise<string>;
  cancel(): void;
}
export interface ProPurchaseIntent { developerPayload: string; expiresAt: number; productId: string; environment: string; }
interface ProBackendReply { signedEntitlement: string; pendingDelivery: boolean; }
interface ProRefundRoute { owner: string; applicationId: string; productId: string; environment: string; purchaseOrderId: string; }
export interface ProClientLease { scope: ProStoreScope; generation: number; }

export function proPurchaseBatches(records: string[]): string[][] {
  const batches: string[][] = [];
  let current: string[] = [];
  if (!Array.isArray(records) || records.length > 100) { throw new Error('Invalid Pro purchase batch'); }
  for (const record of records) {
    if (typeof record !== 'string' || record.length === 0 || new util.TextEncoder().encodeInto(record).length > 66560) {
      throw new Error('Invalid Pro purchase record');
    }
    const next = current.concat([record]);
    if (next.length > 32 || new util.TextEncoder().encodeInto(JSON.stringify({ purchaseDataList: next })).length > 1024 * 1024 - 128) {
      if (current.length === 0) { throw new Error('Pro purchase record too large'); }
      batches.push(current); current = [record];
    } else { current = next; }
  }
  if (current.length > 0) { batches.push(current); }
  return batches;
}

export class ProTrustedEntitlementClient implements ProOrderVerifier {
  private signature: ProSignedEntitlementVerifier;
  private configuration: ProTrustConfiguration;
  private store: ProEntitlementStorePort;
  private transport: ProBackendTransport;
  private clock: ProEntitlementClock;
  private owner: string = '';
  private generation: number = 0;
  private accountRevision: number = -1;
  private queue: Promise<void> = Promise.resolve();
  private observed: Map<string, ProTrustedSnapshot> = new Map();
  constructor(configuration: ProTrustConfiguration, store: ProEntitlementStorePort,
    transport: ProBackendTransport, clock: ProEntitlementClock) {
    this.signature = new ProSignedEntitlementVerifier(configuration);
    this.configuration = { applicationId: configuration.applicationId, issuer: configuration.issuer,
      productId: configuration.productId, environment: configuration.environment,
      keyId: configuration.keyId, publicKeyDer: configuration.publicKeyDer.slice() };
    this.store = store; this.transport = transport; this.clock = clock;
  }
  bind(owner: string, generation: number): void {
    if (owner === this.owner && generation === this.accountRevision) { return; }
    this.owner = owner; this.accountRevision = generation; this.generation++;
    this.transport.cancel();
  }
  lease(): ProClientLease | null {
    if (!/^owner-[a-f0-9]{64}$/.test(this.owner)) { return null; }
    return { scope: { owner: this.owner, environment: this.configuration.environment,
      applicationId: this.configuration.applicationId, productId: this.configuration.productId }, generation: this.generation };
  }
  current(lease: ProClientLease): boolean {
    return lease.generation === this.generation && lease.scope.owner === this.owner &&
      lease.scope.environment === this.configuration.environment && lease.scope.applicationId === this.configuration.applicationId &&
      lease.scope.productId === this.configuration.productId;
  }
  private serialize<T>(action: () => Promise<T>): Promise<T> {
    const operation = this.queue.then(action);
    this.queue = operation.then((): void => {}, (): void => {});
    return operation;
  }
  private unavailable(owner: string): ProVerificationResult {
    return { status: 'unavailable', owner, environment: this.configuration.environment,
      fromCache: true, needsRevalidation: true };
  }
  private async cache(lease: ProClientLease, forceRevalidation: boolean): Promise<ProVerificationResult> {
    try {
      const denied = this.observed.get(lease.scope.owner);
      if (denied !== undefined && denied.signedStatus !== 'verified' && this.current(lease)) {
        const result = this.observedFailure(lease.scope.owner, denied);
        result.refundPending = await this.store.refundPending(lease.scope);
        return result;
      }
      const now = this.clock.now();
      const cached = await this.store.read(lease.scope, now);
      const refundPending = await this.store.refundPending(lease.scope);
      if (cached === null || cached.clockBlocked || !Number.isSafeInteger(now) || !this.current(lease)) {
        const result = this.unavailable(lease.scope.owner);
        result.refundPending = refundPending;
        return result;
      }
      const snapshot = await this.signature.inspectCached(cached.signedEntitlement, lease.scope.owner, this.clock.now());
      if (!this.current(lease) || cached.revision !== snapshot.revision || cached.verifiedAt !== snapshot.verifiedAt) {
        return this.unavailable(lease.scope.owner);
      }
      const observed = this.observed.get(lease.scope.owner);
      if (observed !== undefined && (snapshot.revision < observed.revision ||
        (snapshot.revision === observed.revision && snapshot.signedStatus !== observed.signedStatus))) {
        const result = this.observedFailure(lease.scope.owner, observed);
        result.refundPending = refundPending;
        return result;
      }
      snapshot.result.refundPending = refundPending;
      snapshot.result.fromCache = true;
      snapshot.result.needsRevalidation = forceRevalidation || snapshot.result.status === 'unavailable' ||
        (snapshot.result.grant !== undefined && this.clock.now() >= snapshot.result.grant.revalidateAfter);
      return snapshot.result;
    } catch (_error) { return this.unavailable(lease.scope.owner); }
  }
  private observedFailure(owner: string, snapshot: ProTrustedSnapshot, refundPending: boolean = false): ProVerificationResult {
    if (snapshot.signedStatus === 'verified') { return this.unavailable(owner); }
    return { status: snapshot.signedStatus, owner, environment: this.configuration.environment,
      fromCache: true, needsRevalidation: true, refundPending };
  }
  loadCached(owner: string, environment: ProEnvironment): Promise<ProVerificationResult> {
    const lease = this.lease();
    if (lease === null || lease.scope.owner !== owner || lease.scope.environment !== environment) {
      return Promise.resolve(this.unavailable(owner));
    }
    return this.serialize((): Promise<ProVerificationResult> => this.cache(lease, false));
  }
  verify(records: string[], owner: string, environment: ProEnvironment): Promise<ProVerificationResult> {
    const lease = this.lease();
    if (lease === null || lease.scope.owner !== owner || lease.scope.environment !== environment) {
      return Promise.resolve(this.unavailable(owner));
    }
    const copied = records.slice();
    return this.serialize(async (): Promise<ProVerificationResult> => {
      if (!this.current(lease)) { return this.unavailable(owner); }
      let verificationStage: number = 0;
      let fenced: boolean = false;
      let newFence: boolean = false;
      let denial: ProTrustedSnapshot | null = null;
      try {
        if (copied.length > 32 || proPurchaseBatches(copied).length > 1) { throw new Error('Invalid Pro batch'); }
        const random = await cryptoFramework.createRandom().generateRandom(32);
        const challenge = new util.Base64Helper().encodeToStringSync(random.data)
          .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
        if (!this.current(lease)) { throw new Error('Stale Pro scope'); }
        newFence = await this.store.beginVerification(lease.scope);
        fenced = true;
        if (!this.current(lease)) { throw new Error('Stale Pro scope'); }
        const startedAt = this.clock.wallNow();
        verificationStage = 1;
        const text = await this.transport.post('reconcile', JSON.stringify({ purchaseDataList: copied, challenge }),
          (): boolean => this.current(lease));
        if (!this.current(lease) || typeof text !== 'string' || text.length > 32768) { throw new Error('Stale Pro response'); }
        const reply = JSON.parse(text) as ProBackendReply;
        if (!reply || Object.keys(reply).length !== 2 || typeof reply.signedEntitlement !== 'string' ||
          typeof reply.pendingDelivery !== 'boolean') { throw new Error('Invalid Pro response'); }
        verificationStage = 2;
        const snapshot = await this.signature.verify(reply.signedEntitlement, owner, this.clock.wallNow());
        if (snapshot.challenge !== challenge || snapshot.verifiedAt < startedAt - 60000 || !this.current(lease)) {
          throw new Error('Stale Pro signature');
        }
        verificationStage = 3;
        if (snapshot.signedStatus !== 'verified') { denial = snapshot; }
        snapshot.result.refundPending = await this.store.refundPending(lease.scope);
        const previous: ProCachedRecord | null = await this.store.read(lease.scope, this.clock.now());
        if (previous !== null) {
          const old: ProTrustedSnapshot = await this.signature.inspectCached(previous.signedEntitlement, owner, this.clock.wallNow());
          if (old.revision !== previous.revision || old.verifiedAt !== previous.verifiedAt || snapshot.revision < old.revision ||
            snapshot.verifiedAt < old.verifiedAt || (snapshot.revision === old.revision && snapshot.signedStatus !== old.signedStatus)) {
            throw new Error('Pro cache rollback');
          }
        }
        const observed = this.observed.get(owner);
        if (observed !== undefined && (snapshot.revision < observed.revision || snapshot.verifiedAt < observed.verifiedAt ||
          (snapshot.revision === observed.revision && snapshot.signedStatus !== observed.signedStatus))) {
          throw new Error('Pro observed rollback');
        }
        if (!this.current(lease)) { throw new Error('Stale Pro scope'); }
        if (!this.observed.has(owner) && this.observed.size >= 64) { throw new Error('Pro account observation limit'); }
        this.observed.set(owner, snapshot);
        // Positive grants and dequeue are atomic; negative grants commit before
        // dequeue so receipt cleanup cannot roll back a verified refund.
        verificationStage = 4;
        await this.store.accept(lease.scope, snapshot, this.clock.wallNow(), copied);
        if (!this.current(lease)) { return this.unavailable(owner); }
        this.clock.resetAfterOnlineVerification();
        snapshot.result.fromCache = false;
        return snapshot.result;
      } catch (_error) {
        if (DEBUG) { console.info(`[ProVerify] reconcile failed stage=${verificationStage}`); }
        if (fenced) {
          // Only failures before a fresh trusted response may restore a newly
          // placed fence. A previous crash's fence requires online acceptance.
          try { await this.store.endVerification(lease.scope, newFence && verificationStage < 3); }
          catch (_endError) { /* retain the durable fence and require revalidation */ }
          fenced = false;
        }
        if (denial !== null && this.current(lease)) {
          const old = this.observed.get(owner);
          if ((old !== undefined && denial.revision >= old.revision) || (old === undefined && this.observed.size < 64)) {
            this.observed.set(owner, denial);
          }
          return this.observedFailure(owner, denial, denial.result.refundPending === true);
        }
        const observed = this.observed.get(owner);
        if (observed !== undefined && observed.signedStatus !== 'verified' && this.current(lease)) {
          let refundPending = observed.result.refundPending === true;
          try { refundPending = refundPending || await this.store.refundPending(lease.scope); } catch (_error) { /* fail closed in service */ }
          return this.observedFailure(owner, observed, refundPending);
        }
        return this.cache(lease, true);
      } finally {
        if (fenced) {
          try { await this.store.endVerification(lease.scope, false); } catch (_endError) { /* fence remains safe */ }
        }
      }
    });
  }
  async intent(lease: ProClientLease, isCurrent: () => boolean): Promise<ProPurchaseIntent> {
    if (!this.current(lease) || !isCurrent()) { throw new Error('Pro purchase cancelled'); }
    const text = await this.transport.post('intents', '{}', (): boolean => this.current(lease) && isCurrent());
    if (!this.current(lease) || !isCurrent() || text.length > 4096) { throw new Error('Pro purchase cancelled'); }
    const value = JSON.parse(text) as ProPurchaseIntent;
    if (!value || Object.keys(value).length !== 4 || typeof value.developerPayload !== 'string' ||
      !/^[A-Za-z0-9_-]{43}$/.test(value.developerPayload) || value.productId !== lease.scope.productId ||
      value.environment !== (lease.scope.environment === 'sandbox' ? 'SANDBOX' : 'NORMAL') || !Number.isSafeInteger(value.expiresAt) ||
      value.expiresAt <= this.clock.wallNow() || value.expiresAt - this.clock.wallNow() > 3600000) {
      throw new Error('Invalid Pro purchase intent');
    }
    return value;
  }
  async refundOrder(lease: ProClientLease, isCurrent: () => boolean): Promise<string> {
    if (!DEBUG || lease.scope.environment !== 'sandbox' || !this.current(lease) || !isCurrent()) {
      throw new Error('Pro service unavailable');
    }
    const text = await this.transport.post('refund-order', '{}', (): boolean => this.current(lease) && isCurrent());
    if (!this.current(lease) || !isCurrent() || typeof text !== 'string' || text.length > 4096) {
      throw new Error('Pro purchase cancelled');
    }
    // Authenticated cloud response routes Huawei's UI only. Entitlement changes
    // still require the separate signed reconciliation protocol.
    const value = JSON.parse(text) as ProRefundRoute;
    if (!value || Object.keys(value).length !== 5 || value.owner !== lease.scope.owner ||
      value.applicationId !== lease.scope.applicationId || value.productId !== lease.scope.productId ||
      value.environment !== 'SANDBOX' || typeof value.purchaseOrderId !== 'string' ||
      !/^[^\s\u0000-\u001f\u007f]{1,256}$/.test(value.purchaseOrderId)) { throw new Error('Invalid refund record'); }
    return value.purchaseOrderId;
  }
  // A late checkout callback may persist to its captured old account, but can
  // never be rebound to the new login. These records contain no local grant.
  retain(lease: ProClientLease, records: string[]): Promise<void> {
    if (lease.scope.environment !== this.configuration.environment || lease.scope.applicationId !== this.configuration.applicationId ||
      lease.scope.productId !== this.configuration.productId) { return Promise.reject(new Error('Invalid Pro receipt scope')); }
    return this.store.retain(lease.scope, records.slice());
  }
  pending(lease: ProClientLease): Promise<string[]> {
    if (!this.current(lease)) { return Promise.reject(new Error('Stale Pro scope')); }
    return this.store.pending(lease.scope);
  }
}
