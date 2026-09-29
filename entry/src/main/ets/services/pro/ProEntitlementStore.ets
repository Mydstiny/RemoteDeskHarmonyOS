import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { ProEnvironment } from './ProAccessPolicy';
import { ProTrustedSnapshot } from './ProSignedEntitlement';

export interface ProStoreScope { owner: string; environment: ProEnvironment; applicationId: string; productId: string; }
export interface ProCachedRecord {
  signedEntitlement: string;
  revision: number;
  verifiedAt: number;
  observedAt: number;
  clockBlocked: boolean;
}
export interface ProEntitlementStorePort {
  beginVerification(scope: ProStoreScope): Promise<boolean>;
  endVerification(scope: ProStoreScope, clear: boolean): Promise<void>;
  markRefundPending(scope: ProStoreScope, markedAt: number): Promise<void>;
  clearRefundPending(scope: ProStoreScope): Promise<void>;
  refundPending(scope: ProStoreScope): Promise<boolean>;
  read(scope: ProStoreScope, now: number): Promise<ProCachedRecord | null>;
  accept(scope: ProStoreScope, snapshot: ProTrustedSnapshot, observedAt: number, receipts: string[]): Promise<void>;
  retain(scope: ProStoreScope, receipts: string[]): Promise<void>;
  pending(scope: ProStoreScope): Promise<string[]>;
}
function hash(value: string): string {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: new util.TextEncoder().encodeInto(value) });
  const bytes = md.digestSync().data;
  let hex = '';
  for (const byte of bytes) { hex += byte.toString(16).padStart(2, '0'); }
  return hex;
}
function scopeKey(scope: ProStoreScope): string {
  if (!/^owner-[a-f0-9]{64}$/.test(scope.owner) || !['production', 'sandbox'].includes(scope.environment) ||
    !scope.applicationId || !scope.productId || scope.applicationId.length > 256 || scope.productId.length > 256) {
    throw new Error('Invalid Pro store scope');
  }
  return hash(JSON.stringify([scope.owner, scope.environment, scope.applicationId, scope.productId]));
}
function refundFenceKey(key: string): string { return key + ':refund'; }
// Scope keys are hex digests, so the LIKE pattern has no wildcard collisions.
function refundFencePattern(key: string): string { return refundFenceKey(key) + ':%'; }
// A refund request may still complete after the vendor UI reports an error, so
// only a fresh signed grant issued this long after the request may release it.
export const PRO_REFUND_FENCE_HOLD_MS: number = 10 * 60 * 1000;
// Fences written before the hold existed carry no time and release on the next
// fresh signed grant; an unreadable time never releases without revocation.
function refundFenceTime(key: string, row: string): number {
  if (row === refundFenceKey(key)) { return 0; }
  const value = Number(row.substring(refundFenceKey(key).length + 1));
  return Number.isSafeInteger(value) && value >= 0 ? value : Number.MAX_SAFE_INTEGER;
}
function validTime(value: number): boolean { return Number.isSafeInteger(value) && value > 0; }

// One process-wide encrypted local store, independent of CloudStore and E2EE.
// It is never registered for cloud sync or included in portable backups; system
// backup is disabled by the application's backup_config.json.
export class ProEntitlementStore implements ProEntitlementStorePort {
  private static instance: ProEntitlementStore;
  private store: relationalStore.RdbStore | null = null;
  private opening: Promise<void> | null = null;
  private queue: Promise<void> = Promise.resolve();
  private verifying: Set<string> = new Set();
  static getInstance(): ProEntitlementStore {
    if (!ProEntitlementStore.instance) { ProEntitlementStore.instance = new ProEntitlementStore(); }
    return ProEntitlementStore.instance;
  }
  initialize(context: common.Context): Promise<void> {
    if (this.store !== null) { return Promise.resolve(); }
    if (this.opening !== null) { return this.opening; }
    this.opening = this.open(context).finally((): void => { this.opening = null; });
    return this.opening;
  }
  private async open(context: common.Context): Promise<void> {
    const store = await relationalStore.getRdbStore(context, { name: 'remotedesk_pro_private_v1.db',
      securityLevel: relationalStore.SecurityLevel.S3, encrypt: true });
    try {
      if (store.version !== 0 && store.version !== 1 && store.version !== 2) { throw new Error('Unsupported Pro cache schema'); }
      if (store.version === 0) {
        store.beginTransaction();
        try {
          await store.executeSql('CREATE TABLE pro_cache (scope TEXT PRIMARY KEY, signed TEXT NOT NULL, ' +
            'revision INTEGER NOT NULL, verified_at INTEGER NOT NULL, observed_at INTEGER NOT NULL, clock_blocked INTEGER NOT NULL)');
          await store.executeSql('CREATE TABLE pro_pending (scope TEXT NOT NULL, id TEXT NOT NULL, data TEXT NOT NULL, ' +
            'PRIMARY KEY(scope,id))');
          store.version = 1;
          store.commit();
        } catch (_error) { store.rollBack(); throw new Error('Pro cache schema transaction failed'); }
      }
      if (store.version === 1) {
        store.beginTransaction();
        try {
          await store.executeSql('CREATE TABLE pro_verifying (scope TEXT PRIMARY KEY)');
          store.version = 2;
          store.commit();
        } catch (_error) { store.rollBack(); throw new Error('Pro cache migration failed'); }
      }
      this.store = store;
    } catch (_error) { await store.close(); throw new Error('Pro cache opening failed'); }
  }
  private serialize<T>(action: (store: relationalStore.RdbStore) => Promise<T>): Promise<T> {
    const operation = this.queue.then(async (): Promise<T> => {
      if (this.opening !== null) { await this.opening; }
      const store = this.store;
      if (store === null) { throw new Error('Pro cache unavailable'); }
      return action(store);
    });
    this.queue = operation.then((): void => {}, (): void => {});
    return operation;
  }
  private async row(store: relationalStore.RdbStore, key: string): Promise<ProCachedRecord | null> {
    const result = await store.querySql('SELECT signed,revision,verified_at,observed_at,clock_blocked FROM pro_cache WHERE scope=?', [key]);
    try {
      if (!result.goToFirstRow()) { return null; }
      const record: ProCachedRecord = { signedEntitlement: result.getString(0), revision: result.getLong(1),
        verifiedAt: result.getLong(2), observedAt: result.getLong(3), clockBlocked: result.getLong(4) !== 0 };
      if (record.signedEntitlement.length > 16384 || !Number.isSafeInteger(record.revision) || record.revision < 0 ||
        !validTime(record.verifiedAt) || !validTime(record.observedAt)) { throw new Error('Invalid Pro cache'); }
      return record;
    } finally { result.close(); }
  }
  read(scope: ProStoreScope, now: number): Promise<ProCachedRecord | null> {
    const key = scopeKey(scope);
    return this.serialize(async (store: relationalStore.RdbStore): Promise<ProCachedRecord | null> => {
      const record = await this.row(store, key);
      if (record === null) { return null; }
      const blocked = record.clockBlocked || !validTime(now) || now < record.observedAt;
      const observed = validTime(now) ? Math.max(record.observedAt, now) : record.observedAt;
      if (observed !== record.observedAt || blocked !== record.clockBlocked) {
        await store.executeSql('UPDATE pro_cache SET observed_at=?,clock_blocked=? WHERE scope=?', [observed, blocked ? 1 : 0, key]);
      }
      const fence = await store.querySql('SELECT scope FROM pro_verifying WHERE scope=? OR scope=? OR scope LIKE ?',
        [key, refundFenceKey(key), refundFencePattern(key)]);
      try { record.clockBlocked = blocked || fence.goToFirstRow(); } finally { fence.close(); }
      record.observedAt = observed;
      return record;
    });
  }
  // Persist before contacting the server: a crash or disk failure after an
  // observed refund must never make the previous positive cache usable again.
  // The singleton store also excludes a second in-process verifier per scope.
  beginVerification(scope: ProStoreScope): Promise<boolean> {
    const key = scopeKey(scope);
    return this.serialize(async (store: relationalStore.RdbStore): Promise<boolean> => {
      if (this.verifying.has(key)) { throw new Error('Pro verification already running'); }
      const fence = await store.querySql('SELECT scope FROM pro_verifying WHERE scope=?', [key]);
      let existed: boolean = false;
      try { existed = fence.goToFirstRow(); } finally { fence.close(); }
      await store.executeSql('INSERT OR IGNORE INTO pro_verifying VALUES (?)', [key]);
      this.verifying.add(key);
      return !existed;
    });
  }
  endVerification(scope: ProStoreScope, clear: boolean): Promise<void> {
    const key = scopeKey(scope);
    return this.serialize(async (store: relationalStore.RdbStore): Promise<void> => {
      try { if (clear) { await store.executeSql('DELETE FROM pro_verifying WHERE scope=?', [key]); } }
      finally { this.verifying.delete(key); }
    });
  }
  markRefundPending(scope: ProStoreScope, markedAt: number): Promise<void> {
    const key = scopeKey(scope);
    const time = validTime(markedAt) ? markedAt : Number.MAX_SAFE_INTEGER;
    return this.serialize(async (store: relationalStore.RdbStore): Promise<void> => {
      // The latest request defines the hold; replacement is atomic so a failure keeps the older fence.
      store.beginTransaction();
      try {
        await store.executeSql('DELETE FROM pro_verifying WHERE scope=? OR scope LIKE ?', [refundFenceKey(key), refundFencePattern(key)]);
        await store.executeSql('INSERT INTO pro_verifying VALUES (?)', [refundFenceKey(key) + ':' + time.toString()]);
        store.commit();
      } catch (error) { store.rollBack(); throw error as Error; }
    });
  }
  clearRefundPending(scope: ProStoreScope): Promise<void> {
    const key = scopeKey(scope);
    return this.serialize(async (store: relationalStore.RdbStore): Promise<void> => {
      await store.executeSql('DELETE FROM pro_verifying WHERE scope=? OR scope LIKE ?', [refundFenceKey(key), refundFencePattern(key)]);
    });
  }
  refundPending(scope: ProStoreScope): Promise<boolean> {
    const key = scopeKey(scope);
    return this.serialize(async (store: relationalStore.RdbStore): Promise<boolean> => {
      const result = await store.querySql('SELECT scope FROM pro_verifying WHERE scope=? OR scope LIKE ?',
        [refundFenceKey(key), refundFencePattern(key)]);
      try { return result.goToFirstRow(); } finally { result.close(); }
    });
  }
  accept(scope: ProStoreScope, snapshot: ProTrustedSnapshot, observedAt: number, receipts: string[]): Promise<void> {
    const key = scopeKey(scope);
    if (!validTime(observedAt) || snapshot.result.owner !== scope.owner || snapshot.result.environment !== scope.environment ||
      snapshot.signedEntitlement.length > 16384 || !Number.isSafeInteger(snapshot.revision) || snapshot.revision < 0 ||
      !validTime(snapshot.verifiedAt) || snapshot.verifiedAt > observedAt) { return Promise.reject(new Error('Invalid Pro cache write')); }
    return this.serialize(async (store: relationalStore.RdbStore): Promise<void> => {
      store.beginTransaction();
      try {
        const previous = await this.row(store, key);
        if (previous !== null && (snapshot.revision < previous.revision || snapshot.verifiedAt < previous.verifiedAt)) {
          throw new Error('Pro cache revision rollback');
        }
        await store.executeSql('INSERT OR REPLACE INTO pro_cache VALUES (?,?,?,?,?,0)',
          [key, snapshot.signedEntitlement, snapshot.revision, snapshot.verifiedAt, observedAt]);
        await store.executeSql('DELETE FROM pro_verifying WHERE scope=?', [key]);
        if (snapshot.signedStatus !== 'verified') {
          await store.executeSql('DELETE FROM pro_verifying WHERE scope=? OR scope LIKE ?', [refundFenceKey(key), refundFencePattern(key)]);
        } else {
          // Only fresh signed results reach accept(); an active order long after
          // the request proves the refund was cancelled or declined.
          const fences = await store.querySql('SELECT scope FROM pro_verifying WHERE scope=? OR scope LIKE ?',
            [refundFenceKey(key), refundFencePattern(key)]);
          const released: string[] = [];
          try {
            while (fences.goToNextRow()) {
              const row = fences.getString(0);
              if (snapshot.verifiedAt - refundFenceTime(key, row) >= PRO_REFUND_FENCE_HOLD_MS) { released.push(row); }
            }
          } finally { fences.close(); }
          for (const row of released) { await store.executeSql('DELETE FROM pro_verifying WHERE scope=?', [row]); }
        }
        // A refund must survive even when removal of recovery receipts fails.
        // Positive grants retain the original all-or-nothing transaction.
        if (snapshot.signedStatus !== 'verified') { store.commit(); store.beginTransaction(); }
        for (const receipt of receipts) {
          await store.executeSql('DELETE FROM pro_pending WHERE scope=? AND id=?', [key, hash(receipt)]);
        }
        store.commit();
      } catch (_error) { store.rollBack(); throw new Error('Pro cache transaction failed'); }
    });
  }
  retain(scope: ProStoreScope, receipts: string[]): Promise<void> {
    const key = scopeKey(scope);
    if (!Array.isArray(receipts) || receipts.length > 100 || receipts.some((item: string): boolean =>
      typeof item !== 'string' || item.length === 0 || new util.TextEncoder().encodeInto(item).length > 66560)) {
      return Promise.reject(new Error('Invalid pending purchases'));
    }
    return this.serialize(async (store: relationalStore.RdbStore): Promise<void> => {
      store.beginTransaction();
      try {
        for (const receipt of receipts) {
          await store.executeSql('INSERT OR IGNORE INTO pro_pending VALUES (?,?,?)', [key, hash(receipt), receipt]);
        }
        const limit = await store.querySql('SELECT COUNT(*),COALESCE(SUM(LENGTH(CAST(data AS BLOB))),0) FROM pro_pending WHERE scope=?', [key]);
        try {
          if (!limit.goToFirstRow() || limit.getLong(0) > 100 || limit.getLong(1) > 4 * 1024 * 1024) {
            throw new Error('Pro pending purchase limit');
          }
        } finally { limit.close(); }
        store.commit();
      } catch (_error) { store.rollBack(); throw new Error('Pro pending transaction failed'); }
    });
  }
  pending(scope: ProStoreScope): Promise<string[]> {
    const key = scopeKey(scope);
    return this.serialize(async (store: relationalStore.RdbStore): Promise<string[]> => {
      const result = await store.querySql('SELECT data FROM pro_pending WHERE scope=? ORDER BY id LIMIT 101', [key]);
      try {
        const records: string[] = [];
        let bytes: number = 0;
        while (result.goToNextRow()) {
          const value = result.getString(0);
          const size = new util.TextEncoder().encodeInto(value).length;
          if (size === 0 || size > 66560) { throw new Error('Invalid pending Pro purchase'); }
          bytes += size;
          if (bytes > 4 * 1024 * 1024) { throw new Error('Pro pending purchase limit'); }
          records.push(value);
        }
        if (records.length > 100) { throw new Error('Pro pending purchase limit'); }
        return records;
      } finally { result.close(); }
    });
  }
}
