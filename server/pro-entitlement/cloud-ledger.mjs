import { createCipheriv, createDecipheriv, createHash, randomBytes, randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { boundedString, fail, object } from './iap-crypto.mjs';

const NEVER = Number.MAX_SAFE_INTEGER;
const CONTROL_ID = 'control-v1';
const FIELD_TYPES = [['id', 'String'], ['kind', 'String'], ['owner', 'String'], ['state', 'String'],
  ['dueAt', 'Double'], ['sortAt', 'Double'], ['payload', 'Text']];
const INDEXES = [['kind', 'owner', 'state', 'dueAt'], ['kind', 'dueAt', 'sortAt']];
function ownerId(value) { if (!/^owner-[a-f0-9]{64}$/.test(value) || typeof value !== 'string') fail('invalid_owner'); return value; }
function time(value) { if (!Number.isSafeInteger(value) || value <= 0) fail('invalid_time'); }
function hash(value) { return createHash('sha256').update(boundedString(value)).digest('hex'); }
function key(kind, value) { return kind + '-' + hash(value); }

// Implements the official Server SDK model contract. No generated/sample source
// or dependency is embedded here; the deployment imports the pinned SDK.
export class ProLedgerRecord {
  constructor(values = {}) {
    this.id = ''; this.kind = ''; this.owner = ''; this.state = '';
    this.dueAt = NEVER; this.sortAt = 0; this.payload = '{}';
    for (const [field] of FIELD_TYPES) if (values[field] !== undefined) this[field] = values[field];
  }
  getClassName() { return 'ProLedgerRecord'; }
  getPrimaryKeyList() { return ['id']; }
  getFieldTypeMap() { return new Map(FIELD_TYPES); }
  getIndexList() { return INDEXES.map(fields => [...fields]); }
  getEncryptedFieldList() { return []; }
}

export const cloudLedgerSchema = {
  permissions: [{ objectTypeName: 'ProLedgerRecord', permissions: [
    { role: 'World', rights: [] }, { role: 'Authenticated', rights: [] }, { role: 'Creator', rights: [] },
    { role: 'Administrator', rights: ['Read', 'Upsert', 'Delete'] }
  ] }],
  objectTypes: [{ objectTypeName: 'ProLedgerRecord', indexes: INDEXES.map((fields, index) =>
    ({ indexName: 'proIndex' + index, indexList: fields })), fields: FIELD_TYPES.map(([fieldName, fieldType]) =>
    ({ fieldName, fieldType, notNull: fieldName === 'id', isNeedEncrypt: false, belongPrimaryKey: fieldName === 'id' })) }]
};

function record(id, kind, owner, payload, extra = {}) {
  return new ProLedgerRecord({ id, kind, owner, payload: JSON.stringify(payload), ...extra });
}
function content(row) {
  if (typeof row?.payload !== 'string' || Buffer.byteLength(row.payload) > 65536) fail('ledger_integrity_error');
  try { return object(JSON.parse(row.payload)); } catch { fail('ledger_integrity_error'); }
}
function counts(row) {
  const value = row ? content(row) : { revision: 0, total: 0, active: 0, pending: 0 };
  if (['revision', 'total', 'active', 'pending'].some(name => !Number.isSafeInteger(value[name]) || value[name] < 0) ||
      value.pending > value.active || value.active > value.total) fail('ledger_integrity_error');
  return value;
}
function orderRecord(order) {
  const eligible = Math.min(order.pending ? Math.max(order.nextAttempt, order.leaseUntil) : NEVER,
    order.revoked ? NEVER : order.checkedAt + 6 * 3600000);
  return record(key('order', order.orderId), 'order', order.owner, order,
    { state: order.revoked ? 'revoked' : 'active', dueAt: Math.max(eligible, order.queryNextAttempt), sortAt: order.queryAttemptedAt });
}

// One server-only CloudDB zone per application/environment/product. Every
// transaction reads AND writes an existing control row. The SDK verifies only
// returned rows, so this common row also protects absent keys and range phantoms.
// External IAP requests never execute inside retryable database transactions.
export class ProCloudOrderLedger {
  #collection;
  #key;
  #configuration;
  #identity;
  #wait;
  constructor(collection, configuration, encryptionKey, wait = delay) {
    if (!Buffer.isBuffer(encryptionKey) || encryptionKey.length !== 32) fail('ledger_key_required');
    this.#configuration = Object.freeze({ applicationId: boundedString(configuration.applicationId),
      productId: boundedString(configuration.productId), environment: boundedString(configuration.environment) });
    if (!['NORMAL', 'SANDBOX'].includes(this.#configuration.environment)) fail('invalid_environment');
    this.#collection = collection; this.#key = Buffer.from(encryptionKey); this.#identity = JSON.stringify(this.#configuration);
    this.#wait = wait;
  }
  #encrypt(value, aad) {
    const iv = randomBytes(12); const cipher = createCipheriv('aes-256-gcm', this.#key, iv);
    cipher.setAAD(Buffer.from(aad));
    const encrypted = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
    return Buffer.concat([iv, cipher.getAuthTag(), encrypted]).toString('base64');
  }
  #decrypt(value, aad) {
    try {
      const bytes = Buffer.from(value, 'base64'); const decipher = createDecipheriv('aes-256-gcm', this.#key, bytes.subarray(0, 12));
      decipher.setAuthTag(bytes.subarray(12, 28)); decipher.setAAD(Buffer.from(aad));
      return Buffer.concat([decipher.update(bytes.subarray(28)), decipher.final()]).toString('utf8');
    } catch { fail('ledger_integrity_error'); }
  }
  // Provision once while the service is disabled. Import this row into a NEW,
  // empty, dedicated zone. Runtime never creates/replaces a missing control row.
  initialControlRecord() {
    return record(CONTROL_ID, 'control', '', { schema: 1, identity: this.#identity,
      keyCheck: this.#encrypt(this.#identity, CONTROL_ID), commit: randomUUID() });
  }
  async #transaction(operation, action, prefetch = []) {
    let result; let step = 0;
    // The official SDK reports a rejected rate-limited request as 3007009.
    // Share one bounded backoff budget between reads and transaction commits;
    // never retry an ambiguous network failure or bypass the control fence.
    let retries = 0;
    const retryThrottle = async operation => {
      for (;;) {
        try { return await operation(); }
        catch (error) {
          if (error?.name !== 'database-server' || error?.errorCode?.code !== '3007009' || retries >= 3) throw error;
          await this.#wait(1000 * ++retries);
        }
      }
    };
    let committed;
    try { committed = await retryThrottle(() => this.#collection.runTransaction({ apply: async transaction => {
      step = 0;
      const query = value => { step++; return retryThrottle(() => transaction.executeQuery(value)); };
      const cache = new Map();
      // Batch known primary keys with the control fence in the same versioned
      // transaction query. Missing keys remain protected by the control write.
      if (prefetch.length) {
        const ids = [...new Set([CONTROL_ID, ...prefetch])];
        ids.forEach(id => cache.set(id, undefined));
        const rows = await query(this.#collection.query().in('id', ids).limit(ids.length + 1));
        const seen = new Set();
        for (const row of rows) {
          if (!cache.has(row.id) || seen.has(row.id)) fail('ledger_integrity_error');
          seen.add(row.id); cache.set(row.id, row);
        }
      }
      const read = async id => {
        if (!cache.has(id)) {
          const rows = await query(this.#collection.query().equalTo('id', id).limit(2));
          if (rows.length > 1 || (rows[0] && rows[0].id !== id)) fail('ledger_integrity_error');
          cache.set(id, rows[0]);
        }
        return cache.get(id);
      };
      const control = content(await read(CONTROL_ID));
      if (control.schema !== 1 || control.identity !== this.#identity ||
          this.#decrypt(control.keyCheck, CONTROL_ID) !== this.#identity) fail('ledger_configuration_mismatch');
      const writes = [];
      result = await action({ read, query, writes });
      // Queue writes only after all reads: the SDK rejects queries after upsert.
      control.commit = randomUUID();
      transaction.executeUpsert([...writes, record(CONTROL_ID, 'control', '', control)]);
      return true;
    } })); } catch (error) {
      if (error?.name === 'database-server' && typeof error?.errorCode?.code === 'string' &&
          /^[0-9]{1,12}$/.test(error.errorCode.code)) {
        throw Object.assign(new Error('cloud_database_failed'), { name: 'database-server',
          errorCode: { code: error.errorCode.code }, cause: { ledgerOperation: operation, ledgerRead: step } });
      }
      throw error;
    }
    if (committed !== true) fail('ledger_transaction_conflict');
    return result;
  }
  async createIntent(owner, now) {
    ownerId(owner); time(now);
    const id = randomBytes(32).toString('base64url'); const expiresAt = now + 3600000;
    return this.#transaction('createIntent', async ({ read, query, writes }) => {
      const previous = await read(key('intent', id));
      if (previous) {
        const saved = content(previous);
        if (saved.owner !== owner || saved.id !== id || saved.expiresAt !== expiresAt) fail('ledger_integrity_error');
      } else {
        const active = await query(this.#collection.query().equalTo('kind', 'intent').equalTo('owner', owner)
          .equalTo('state', 'unbound').greaterThan('dueAt', now).limit(9));
        if (active.length >= 8) fail('too_many_pending_purchases');
        writes.push(record(key('intent', id), 'intent', owner, { id, owner, createdAt: now, expiresAt, orderId: '' },
          { state: 'unbound', dueAt: expiresAt }));
      }
      return { developerPayload: id, expiresAt, productId: this.#configuration.productId, environment: this.#configuration.environment };
    });
  }
  #assertOrder(order) {
    boundedString(order.purchaseOrderId); boundedString(order.purchaseToken); time(order.signedTime);
    if (order.applicationId !== this.#configuration.applicationId || order.productId !== this.#configuration.productId ||
        order.environment !== this.#configuration.environment || typeof order.revoked !== 'boolean' ||
        typeof order.needsFinish !== 'boolean') fail('ledger_order_scope_invalid');
  }
  #binding(order, reference, owner) {
    if (owner !== undefined && order.owner !== owner) fail('order_belongs_to_another_account');
    if (order.orderId !== reference.purchaseOrderId || order.tokenHash !== hash(reference.purchaseToken) ||
        this.#decrypt(order.tokenCipher, order.orderId) !== reference.purchaseToken) fail('order_binding_mismatch');
  }
  async applyCurrentOrder(order, expectedOwner, now, notificationId = '') {
    this.#assertOrder(order); time(now);
    if (expectedOwner !== undefined) ownerId(expectedOwner);
    if (notificationId) boundedString(notificationId);
    return this.#transaction('applyCurrentOrder', async ({ read, writes }) => {
      const oldRow = await read(key('order', order.purchaseOrderId)); const old = oldRow ? content(oldRow) : undefined;
      let owner; let intent;
      if (old) {
        this.#binding(old, order, expectedOwner);
        if (order.developerPayload && order.developerPayload !== old.intentId) fail('order_binding_mismatch');
        if (order.signedTime < old.signedTime) fail('stale_order_response');
        owner = old.owner;
      } else {
        const intentRow = await read(key('intent', boundedString(order.developerPayload)));
        if (!intentRow) fail('purchase_intent_not_found');
        intent = content(intentRow);
        if (intent.id !== order.developerPayload || (intent.orderId && intent.orderId !== order.purchaseOrderId) ||
            !Number.isSafeInteger(order.purchaseTime) || order.purchaseTime < intent.createdAt - 60000 ||
            order.purchaseTime > intent.expiresAt + 60000) fail('purchase_intent_not_found');
        owner = ownerId(intent.owner);
        if (expectedOwner !== undefined && owner !== expectedOwner) fail('order_belongs_to_another_account');
      }
      const tokenRow = await read(key('token', order.purchaseToken));
      if (tokenRow && content(tokenRow).orderId !== order.purchaseOrderId) fail('purchase_token_already_bound');
      const account = counts(await read(key('account', owner)));
      const revoked = order.revoked || old?.revoked === true;
      const finished = old?.finished === true || (!order.needsFinish && !revoked);
      const pending = !revoked && !finished && order.needsFinish;
      const next = { ...(old || { orderId: order.purchaseOrderId, owner, intentId: intent.id, purchaseTime: order.purchaseTime,
        tokenHash: hash(order.purchaseToken), tokenCipher: this.#encrypt(order.purchaseToken, order.purchaseOrderId),
        lease: '', leaseUntil: 0, nextAttempt: 0, attempts: 0, queryAttemptedAt: 0, queryNextAttempt: 0 }),
        signedTime: order.signedTime, checkedAt: now, revoked, finished, pending };
      if (!old) { account.total++; account.revision++; }
      else if (revoked !== old.revoked) account.revision++;
      account.active += Number(!revoked) - Number(old !== undefined && !old.revoked);
      account.pending += Number(pending) - Number(old?.pending === true);
      counts(record('', '', '', account));
      if (intent) writes.push(record(key('intent', intent.id), 'intent', owner,
        { ...intent, orderId: order.purchaseOrderId }, { state: 'bound', dueAt: intent.expiresAt }));
      writes.push(orderRecord(next), record(key('token', order.purchaseToken), 'token', owner, { orderId: next.orderId }),
        record(key('account', owner), 'account', owner, account));
      if (notificationId) writes.push(record(key('notification', notificationId), 'notification', owner,
        { orderId: next.orderId, receivedAt: now }));
      return { owner, revoked, finishPending: pending };
    });
  }
  async references(owner, activeOnly = false) {
    ownerId(owner);
    return this.#transaction('references', async ({ query }) => {
      const queryBuilder = this.#collection.query().equalTo('kind', 'order').equalTo('owner', owner);
      if (activeOnly) queryBuilder.equalTo('state', 'active');
      const rows = await query(queryBuilder.limit(101));
      if (rows.length > 100) fail('account_order_limit');
      return rows.map(row => {
        const order = content(row);
        if (order.owner !== owner) fail('ledger_integrity_error');
        return { purchaseOrderId: order.orderId, purchaseToken: this.#decrypt(order.tokenCipher, order.orderId) };
      });
    });
  }
  async terminalReference(owner, reference) {
    ownerId(owner); boundedString(reference.purchaseOrderId);
    return this.#transaction('terminalReference', async ({ read }) => {
      const row = await read(key('order', reference.purchaseOrderId)); if (!row) return false;
      const order = content(row); this.#binding(order, reference, owner); return order.revoked === true;
    }, [key('order', reference.purchaseOrderId)]);
  }
  async snapshot(owner) {
    ownerId(owner);
    return this.#transaction('snapshot', async ({ read }) => {
      const account = counts(await read(key('account', owner)));
      return { status: account.active > 0 ? 'verified' : account.total > 0 ? 'revoked' : 'noEntitlement',
        revision: account.revision, pending: account.pending > 0, checkedAt: 0 };
    });
  }
  async claimFinish(reference, now) {
    boundedString(reference.purchaseOrderId); time(now);
    return this.#transaction('claimFinish', async ({ read, writes }) => {
      const row = await read(key('order', reference.purchaseOrderId)); if (!row) return '';
      const order = content(row); this.#binding(order, reference);
      if (order.revoked || !order.pending || order.leaseUntil > now || order.nextAttempt > now) return '';
      order.lease = randomUUID(); order.leaseUntil = now + 120000; order.attempts++;
      writes.push(orderRecord(order)); return order.lease;
    });
  }
  async finishSucceeded(orderId, lease) {
    boundedString(orderId); boundedString(lease);
    return this.#transaction('finishSucceeded', async ({ read, writes }) => {
      const row = await read(key('order', orderId)); if (!row) return;
      const order = content(row); if (order.lease !== lease) return;
      const account = counts(await read(key('account', order.owner)));
      if (order.pending) account.pending--;
      order.finished = true; order.pending = false; order.lease = ''; order.leaseUntil = 0; order.nextAttempt = 0;
      counts(record('', '', '', account));
      writes.push(orderRecord(order), record(key('account', order.owner), 'account', order.owner, account));
    });
  }
  async finishFailed(orderId, lease, now) {
    boundedString(orderId); boundedString(lease); time(now);
    return this.#transaction('finishFailed', async ({ read, writes }) => {
      const row = await read(key('order', orderId)); if (!row) return;
      const order = content(row); if (order.lease !== lease) return;
      order.lease = ''; order.leaseUntil = 0; order.nextAttempt = now + 120000; writes.push(orderRecord(order));
    });
  }
  async dueOrders(now, limit = 20) {
    time(now); if (!Number.isInteger(limit) || limit < 1 || limit > 100) fail('invalid_batch_limit');
    return this.#transaction('dueOrders', async ({ query, writes }) => {
      const rows = await query(this.#collection.query().equalTo('kind', 'order').lessThanOrEqualTo('dueAt', now)
        .orderByAsc('sortAt').limit(limit));
      return rows.map(row => {
        const order = content(row); order.queryAttemptedAt = now; order.queryNextAttempt = now + 120000;
        writes.push(orderRecord(order));
        return { owner: order.owner,
          reference: { purchaseOrderId: order.orderId, purchaseToken: this.#decrypt(order.tokenCipher, order.orderId) } };
      });
    });
  }
  close() { this.#key.fill(0); }
}
