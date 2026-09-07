import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, generateKeyPairSync } from 'node:crypto';
import { ProCloudOrderLedger, ProLedgerRecord, cloudLedgerSchema } from '../../server/pro-entitlement/cloud-ledger.mjs';
import { ProFulfillmentService, ProGrantSigner } from '../../server/pro-entitlement/fulfillment.mjs';
import { ownerForUnionId } from '../../server/pro-entitlement/huawei-api.mjs';
import { jwsParts } from '../../server/pro-entitlement/iap-crypto.mjs';

// Models the documented SDK boundary: only returned records have version
// preconditions; absent keys and ranges have none. This deliberately does NOT
// supply serializable isolation that the production adapter must provide itself.
class VersionedCollection {
  rows = new Map(); version = 0; conflicts = 0; rejectCommits = false; beforeCommit;
  query() {
    const query = { filters: [], sort: null, maximum: 1000 };
    for (const [method, compare] of [['equalTo', (a, b) => a === b], ['greaterThan', (a, b) => a > b],
      ['lessThanOrEqualTo', (a, b) => a <= b]]) {
      query[method] = (field, value) => { query.filters.push(row => compare(row[field], value)); return query; };
    }
    query.limit = count => { query.maximum = count; return query; };
    query.orderByAsc = field => { query.sort = field; return query; };
    return query;
  }
  seed(row) {
    if (this.rows.has(row.id)) throw new Error('duplicate insert');
    this.rows.set(row.id, { row: structuredClone(row), version: ++this.version });
  }
  async runTransaction(action) {
    for (let attempt = 0; attempt < 5; attempt++) {
      const read = new Map(); let writes;
      const tx = {
        executeQuery: async query => {
          assert.equal(writes, undefined, 'SDK forbids querying after upsert');
          let selected = [...this.rows.values()].filter(({ row }) => query.filters.every(filter => filter(row)));
          if (query.sort) selected.sort((a, b) => a.row[query.sort] - b.row[query.sort]);
          selected = selected.slice(0, query.maximum);
          return selected.map(item => { read.set(item.row.id, item.version); return new ProLedgerRecord(structuredClone(item.row)); });
        },
        executeUpsert: rows => { assert.equal(writes, undefined); writes = rows.map(row => structuredClone(row)); }
      };
      if (await action.apply(tx) !== true) return false;
      assert.ok(writes?.length, 'even read snapshots must validate their control record');
      if (this.beforeCommit) await this.beforeCommit(this, writes);
      if (this.rejectCommits) return false;
      if ([...read].some(([id, version]) => this.rows.get(id)?.version !== version)) { this.conflicts++; continue; }
      for (const row of writes) this.rows.set(row.id, { row, version: ++this.version });
      return true;
    }
    return false;
  }
}
const owner = ownerForUnionId('cloud-ledger-account');
const other = ownerForUnionId('cloud-ledger-other');
const config = { applicationId: 'test-app', productId: 'test-pro', environment: 'SANDBOX', issuer: 'test-issuer', keyId: 'test-key' };
const signing = generateKeyPairSync('rsa', { modulusLength: 2048 });
function receipt(reference) {
  return JSON.stringify({ jwsPurchaseOrder: 'eyJhbGciOiJFUzI1NiJ9.' + Buffer.from(JSON.stringify(reference)).toString('base64url') + '.eA' });
}
function fixture(t, seeded = true) {
  const collection = new VersionedCollection(); const key = randomBytes(32);
  const ledger = new ProCloudOrderLedger(collection, config, key);
  if (seeded) collection.seed(ledger.initialControlRecord());
  const state = { now: Date.now(), orders: new Map(), confirms: 0, offline: false, failConfirm: false, confirmedDurably: false };
  const iap = {
    async query(reference) {
      if (state.offline || state.orders.get(reference.purchaseOrderId)?.unavailable) throw new Error('offline');
      const order = state.orders.get(reference.purchaseOrderId);
      if (!order || order.purchaseToken !== reference.purchaseToken) throw new Error('unknown');
      return { ...order, signedTime: state.now };
    },
    async confirm(reference) {
      state.confirms++; state.confirmedDurably = (await ledger.snapshot(owner)).status === 'verified';
      if (state.failConfirm) throw new Error('timeout');
      state.orders.get(reference.purchaseOrderId).needsFinish = false;
    },
    async notification() { return { id: 'test-notification', reference: state.orders.values().next().value }; }
  };
  const signer = new ProGrantSigner(config, signing.privateKey.export({ type: 'pkcs8', format: 'pem' }));
  const service = new ProFulfillmentService(ledger, iap, signer, () => state.now);
  const another = () => new ProCloudOrderLedger(collection, config, key);
  const order = async (id = 'order-1', account = owner) => {
    const intent = await ledger.createIntent(account, state.now);
    const value = { ...config, purchaseOrderId: id, purchaseToken: 'private-token-' + id,
      developerPayload: intent.developerPayload, purchaseTime: state.now, signedTime: state.now, revoked: false, needsFinish: true };
    state.orders.set(id, value); return value;
  };
  t.after(() => ledger.close());
  return { collection, key, ledger, another, state, service, order,
    reconcile: (account, records = [], signal) => service.reconcile(account, records, signal, randomBytes(32).toString('base64url')) };
}
test('cloud schema denies every client role and requires an existing configuration control record', async t => {
  for (const permission of cloudLedgerSchema.permissions[0].permissions) {
    assert.deepEqual(permission.rights, permission.role === 'Administrator' ? ['Read', 'Upsert', 'Delete'] : []);
  }
  const f = fixture(t, false);
  await assert.rejects(() => f.ledger.createIntent(owner, f.state.now), /ledger_integrity/);
  assert.equal(f.collection.rows.size, 0);
});
test('async cloud reconciliation signs only after durable account binding, then worker delivers', async t => {
  const f = fixture(t); const order = await f.order();
  const grant = await f.reconcile(owner, [receipt(order)]);
  assert.equal(jwsParts(grant.signedEntitlement).payload.status, 'verified');
  assert.equal(grant.pendingDelivery, true); assert.equal(f.state.confirms, 0);
  await f.service.reconcileDue();
  assert.equal(f.state.confirms, 1); assert.equal(f.state.confirmedDurably, true);
  const reopened = f.another();
  assert.equal((await reopened.snapshot(owner)).pending, false); reopened.close();
});
test('an empty-key race cannot consume one purchase intent for two different orders', async t => {
  const f = fixture(t); const first = await f.order(); const second = { ...first, purchaseOrderId: 'order-2', purchaseToken: 'second-token' };
  const otherInstance = f.another();
  const results = await Promise.allSettled([f.ledger.applyCurrentOrder(first, owner, f.state.now),
    otherInstance.applyCurrentOrder(second, owner, f.state.now)]);
  assert.equal(results.filter(item => item.status === 'fulfilled').length, 1);
  assert.equal((await f.ledger.references(owner)).length, 1); assert.ok(f.collection.conflicts > 0);
  otherInstance.close();
});
test('an empty token-index race cannot assign the same token to different owners', async t => {
  const f = fixture(t); const a = await f.order('order-a'); const b = await f.order('order-b', other); b.purchaseToken = a.purchaseToken;
  const instance = f.another();
  const results = await Promise.allSettled([f.ledger.applyCurrentOrder(a, owner, f.state.now), instance.applyCurrentOrder(b, other, f.state.now)]);
  assert.equal(results.filter(result => result.status === 'fulfilled').length, 1);
  assert.equal((await f.ledger.references(owner)).length + (await f.ledger.references(other)).length, 1);
  instance.close();
});
test('range phantoms cannot exceed the per-account pending purchase limit', async t => {
  const f = fixture(t);
  for (let i = 0; i < 7; i++) await f.ledger.createIntent(owner, f.state.now);
  const instance = f.another();
  const results = await Promise.allSettled([f.ledger.createIntent(owner, f.state.now), instance.createIntent(owner, f.state.now)]);
  assert.equal(results.filter(result => result.status === 'fulfilled').length, 1);
  assert.equal([...f.collection.rows.values()].filter(item => item.row.kind === 'intent').length, 8); instance.close();
});
test('failed cloud commit cannot consume an intent, publish a grant or confirm delivery', async t => {
  const f = fixture(t); const order = await f.order(); f.collection.rejectCommits = true;
  await assert.rejects(() => f.reconcile(owner, [receipt(order)]), /transaction_conflict/);
  assert.equal(f.state.confirms, 0);
  f.collection.rejectCommits = false; assert.equal((await f.ledger.snapshot(owner)).status, 'noEntitlement');
  await f.reconcile(owner, [receipt(order)]); assert.equal((await f.ledger.snapshot(owner)).status, 'verified');
});
test('a refund committed during snapshot forces reread of both state and revision', async t => {
  const f = fixture(t); const order = await f.order(); await f.ledger.applyCurrentOrder(order, owner, f.state.now);
  const instance = f.another(); let changed = false;
  f.collection.beforeCommit = async (_collection, writes) => {
    if (!changed && writes.length === 1) {
      changed = true;
      await instance.applyCurrentOrder({ ...order, revoked: true, signedTime: f.state.now + 1 }, owner, f.state.now + 1);
    }
  };
  const snapshot = await f.ledger.snapshot(owner);
  assert.equal(snapshot.status, 'revoked'); assert.equal(snapshot.revision, 2); assert.equal(snapshot.pending, false);
  instance.close();
});
test('duplicate restoration and competing instances claim only one durable finish lease', async t => {
  const f = fixture(t); const order = await f.order(); await f.reconcile(owner, [receipt(order), receipt(order)]);
  const instance = f.another();
  const leases = await Promise.all([f.ledger.claimFinish(order, f.state.now), instance.claimFinish(order, f.state.now)]);
  assert.equal(leases.filter(Boolean).length, 1);
  await f.ledger.finishSucceeded(order.purchaseOrderId, 'wrong-lease'); assert.equal((await f.ledger.snapshot(owner)).pending, true);
  await instance.finishSucceeded(order.purchaseOrderId, leases.find(Boolean));
  await f.reconcile(owner, [receipt(order)]);
  assert.equal((await f.ledger.snapshot(owner)).revision, 1); assert.equal((await f.ledger.snapshot(owner)).pending, false);
  instance.close();
});
test('refund remains terminal while another purchase survives unavailable old vendor history', async t => {
  const f = fixture(t); const first = await f.order(); const second = await f.order('order-2');
  await f.reconcile(owner, [receipt(first), receipt(second)]);
  first.revoked = true; f.state.now++; await f.service.notification('signed notification'); first.unavailable = true;
  const grant = await f.reconcile(owner, [receipt(first), receipt(second)]);
  assert.equal(jwsParts(grant.signedEntitlement).payload.status, 'verified');
  second.revoked = true; f.state.now++; await f.reconcile(owner, [receipt(second)]);
  assert.equal((await f.ledger.snapshot(owner)).status, 'revoked');
  await f.ledger.applyCurrentOrder({ ...first, revoked: false, signedTime: ++f.state.now }, owner, f.state.now);
  assert.equal((await f.ledger.snapshot(owner)).status, 'revoked');
});
test('late purchase recovers from retained intent; copying owner or changing token fails', async t => {
  const f = fixture(t); const order = await f.order(); f.state.now += 30 * 86400000;
  await assert.rejects(() => f.reconcile(other, [receipt(order)]), /another_account/);
  await f.reconcile(owner, [receipt(order)]);
  await assert.rejects(() => f.ledger.terminalReference(owner, { ...order, purchaseToken: 'tampered' }), /binding_mismatch/);
  const invalid = await f.order('order-2'); invalid.purchaseTime += 3660001;
  await assert.rejects(() => f.reconcile(owner, [receipt(invalid)]), /intent_not_found/);
});
test('outbox timeout and process restart preserve pending state and backoff', async t => {
  const f = fixture(t); const order = await f.order(); await f.reconcile(owner, [receipt(order)]);
  f.state.failConfirm = true; await f.service.reconcileDue(); assert.equal(f.state.confirms, 1);
  const instance = f.another(); assert.equal((await instance.snapshot(owner)).pending, true);
  assert.deepEqual(await instance.dueOrders(f.state.now), []);
  f.state.now += 120001; f.state.failConfirm = false; await f.service.reconcileDue();
  assert.equal(f.state.confirms, 2); assert.equal((await instance.snapshot(owner)).pending, false); instance.close();
});
test('persistent scan ordering prevents failed first twenty orders from starving a later order', async t => {
  const f = fixture(t);
  for (let i = 0; i < 21; i++) {
    const order = await f.order('order-' + i); await f.reconcile(owner, [receipt(order)]);
  }
  let index = 0; for (const order of f.state.orders.values()) order.unavailable = index++ < 20;
  const first = await f.service.reconcileDue(); assert.equal(first.checked, 20); assert.equal(first.successful, 0);
  f.state.now += 180000; const second = await f.service.reconcileDue();
  assert.equal(second.successful, 1); assert.equal(f.state.confirms, 1);
});
test('network failure cannot renew a signed grant; cloud tokens are encrypted and scoped', async t => {
  const f = fixture(t); const order = await f.order(); await f.reconcile(owner, [receipt(order)]);
  const stored = JSON.stringify([...f.collection.rows.values()]); assert.equal(stored.includes(order.purchaseToken), false);
  f.state.offline = true; await assert.rejects(() => f.reconcile(owner));
  assert.equal((await f.ledger.snapshot(owner)).status, 'verified');
  const wrongKey = new ProCloudOrderLedger(f.collection, config, randomBytes(32));
  await assert.rejects(() => wrongKey.snapshot(owner), /ledger_integrity/); wrongKey.close();
  const wrongEnvironment = new ProCloudOrderLedger(f.collection, { ...config, environment: 'NORMAL' }, f.key);
  await assert.rejects(() => wrongEnvironment.snapshot(owner), /configuration_mismatch/); wrongEnvironment.close();
});
test('disconnect during the awaited cloud snapshot never signs a new grant', async t => {
  const f = fixture(t); const order = await f.order(); const controller = new AbortController();
  const snapshot = f.ledger.snapshot.bind(f.ledger);
  f.ledger.snapshot = async account => {
    const value = await snapshot(account); controller.abort(); return value;
  };
  await assert.rejects(() => f.reconcile(owner, [receipt(order)], controller.signal), /reconciliation_cancelled/);
  assert.equal((await snapshot(owner)).status, 'verified');
  assert.equal(f.state.confirms, 0);
});
