import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { generateKeyPairSync, randomBytes, verify } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { ProOrderLedger } from '../../server/pro-entitlement/ledger.mjs';
import { ProFulfillmentService, ProGrantSigner } from '../../server/pro-entitlement/fulfillment.mjs';
import { jwsParts } from '../../server/pro-entitlement/iap-crypto.mjs';
import { ownerForUnionId } from '../../server/pro-entitlement/huawei-api.mjs';

const owner = ownerForUnionId('unit-test-user');
const otherOwner = ownerForUnionId('other-test-user');
const configuration = { applicationId: 'test-app', environment: 'NORMAL', productId: 'test-pro',
  issuer: 'test-remote-desk-pro', keyId: 'test-grant-key' };
const signing = generateKeyPairSync('rsa', { modulusLength: 2048 });
function receipt(reference) {
  const segment = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  return JSON.stringify({ jwsPurchaseOrder: segment({ alg: 'ES256' }) + '.' + segment(reference) + '.eA' });
}
function fixture(t) {
  const directory = mkdtempSync(join(tmpdir(), 'pro-ledger-test-'));
  const database = join(directory, 'orders.db');
  const key = randomBytes(32);
  let ledger = new ProOrderLedger(database, configuration, key);
  const state = { now: Date.now(), queries: 0, confirms: 0, networkDown: false, failConfirm: false,
    loseConfirmResponse: false, orders: new Map(), confirmationObservedDurableGrant: false };
  const iap = {
    async query(reference) {
      state.queries++;
      if (state.networkDown) throw new Error('offline');
      const order = state.orders.get(reference.purchaseOrderId);
      if (!order || order.purchaseToken !== reference.purchaseToken) throw new Error('invalid order');
      return { ...order, signedTime: state.now };
    },
    async confirm(reference) {
      state.confirms++;
      state.confirmationObservedDurableGrant = ledger.snapshot(owner).status === 'verified' && ledger.references(owner).length > 0;
      if (state.failConfirm) throw new Error('network timeout');
      state.orders.get(reference.purchaseOrderId).needsFinish = false;
      if (state.loseConfirmResponse) throw new Error('response lost after acknowledgement');
    },
    async notification() { return { id: 'notification-1', reference: { purchaseOrderId: 'order-1', purchaseToken: 'private-purchase-token-1' } }; }
  };
  const signer = new ProGrantSigner(configuration, signing.privateKey.export({ type: 'pkcs8', format: 'pem' }));
  let service = new ProFulfillmentService(ledger, iap, signer, () => state.now);
  t.after(() => { ledger.close(); rmSync(directory, { recursive: true, force: true }); });
  function makeOrder(id = 'order-1', account = owner) {
    const intent = service.createIntent(account);
    const order = { purchaseOrderId: id, purchaseToken: 'private-purchase-token-' + id.split('-').at(-1),
      applicationId: configuration.applicationId, environment: configuration.environment, productId: configuration.productId,
      developerPayload: intent.developerPayload, purchaseTime: state.now, signedTime: state.now,
      revoked: false, needsFinish: true };
    state.orders.set(id, order); return order;
  }
  return { state, iap, makeOrder, database, key,
    get ledger() { return ledger; }, get service() { return service; },
    restart() { ledger.close(); ledger = new ProOrderLedger(database, configuration, key);
      service = new ProFulfillmentService(ledger, iap, signer, () => state.now); }
  };
}
test('grant and immutable owner binding are durable before any delivery confirmation', async t => {
  const f = fixture(t); const order = f.makeOrder();
  const result = await f.service.reconcile(owner, [receipt(order)]);
  assert.equal(f.state.confirms, 0); assert.equal(result.pendingDelivery, true);
  await f.service.reconcileDue();
  assert.equal(f.state.confirmationObservedDurableGrant, true);
  assert.equal(f.state.confirms, 1); assert.equal(f.ledger.snapshot(owner).pending, false);
  const signed = jwsParts(result.signedEntitlement);
  assert.equal(verify('RSA-SHA256', signed.input, signing.publicKey, signed.signature), true);
  assert.equal(signed.payload.owner, owner); assert.equal(signed.payload.status, 'verified');
  assert.equal(signed.payload.usableUntil - signed.payload.verifiedAt, 7 * 86400000);
  f.restart(); assert.equal(f.ledger.snapshot(owner).status, 'verified');
});
test('crash/restart preserves a timed-out pending delivery and retries only after backoff', async t => {
  const f = fixture(t); const order = f.makeOrder(); f.state.failConfirm = true;
  const result = await f.service.reconcile(owner, [receipt(order)]);
  assert.equal(result.pendingDelivery, true); assert.equal(jwsParts(result.signedEntitlement).payload.status, 'verified');
  await f.service.reconcileDue();
  f.restart(); assert.equal(f.ledger.snapshot(owner).pending, true);
  await f.service.reconcile(owner); assert.equal(f.state.confirms, 1);
  f.state.failConfirm = false; f.state.now += 120001;
  await f.service.reconcileDue(); assert.equal(f.state.confirms, 2); assert.equal(f.ledger.snapshot(owner).pending, false);
});
test('lost successful confirmation response is resolved by status query without confirming twice', async t => {
  const f = fixture(t); const order = f.makeOrder(); f.state.loseConfirmResponse = true;
  await f.service.reconcile(owner, [receipt(order)]);
  await f.service.reconcileDue();
  f.restart(); f.state.now += 120001;
  await f.service.reconcileDue();
  assert.equal(f.state.confirms, 1); assert.equal(f.ledger.snapshot(owner).pending, false);
});
test('repeated, duplicate-page and concurrent restores do not deliver twice or duplicate entitlement', async t => {
  const f = fixture(t); const order = f.makeOrder();
  await Promise.all([f.service.reconcile(owner, [receipt(order), receipt(order)]), f.service.reconcile(owner, [receipt(order)])]);
  await Promise.all([f.service.reconcileDue(), f.service.reconcileDue()]);
  const revision = f.ledger.snapshot(owner).revision;
  await f.service.reconcile(owner, [receipt(order)]);
  assert.equal(f.state.confirms, 1); assert.equal(f.ledger.references(owner).length, 1);
  assert.equal(f.ledger.snapshot(owner).revision, revision);
});
test('copied receipt, missing intent and reused token cannot transfer entitlement to another account', async t => {
  const f = fixture(t); const order = f.makeOrder();
  await assert.rejects(() => f.service.reconcile(otherOwner, [receipt(order)]), /another_account/);
  assert.equal(f.ledger.snapshot(otherOwner).status, 'noEntitlement'); assert.equal(f.state.confirms, 0);
  await f.service.reconcile(owner, [receipt(order)]);
  await f.service.reconcileDue();
  const reused = f.makeOrder('order-2'); reused.purchaseToken = order.purchaseToken;
  await assert.rejects(() => f.service.reconcile(owner, [receipt(reused)]), /already_bound/);
  const unbound = f.makeOrder('order-3'); unbound.developerPayload = 'client-chosen';
  await assert.rejects(() => f.service.reconcile(owner, [receipt(unbound)]), /intent_not_found/);
  assert.equal(f.state.confirms, 1); assert.equal(f.ledger.references(owner).length, 1);
});
test('failed SQL insert rolls back intent consumption and never acknowledges delivery', async t => {
  const f = fixture(t); const order = f.makeOrder(); const fault = new DatabaseSync(f.database);
  fault.exec("CREATE TRIGGER deny_order BEFORE INSERT ON orders BEGIN SELECT RAISE(ABORT, 'simulated disk write failure'); END");
  await assert.rejects(() => f.service.reconcile(owner, [receipt(order)]));
  assert.equal(f.ledger.references(owner).length, 0); assert.equal(f.state.confirms, 0);
  assert.equal(fault.prepare('SELECT order_id FROM intents WHERE id=?').get(order.developerPayload).order_id, '');
  fault.exec('DROP TRIGGER deny_order'); fault.close();
  await f.service.reconcile(owner, [receipt(order)]); await f.service.reconcileDue();
  assert.equal(f.state.confirms, 1);
});
test('expiry bounds checkout time but retained intent still recovers a delayed valid purchase', async t => {
  const f = fixture(t); const order = f.makeOrder(); f.state.now += 30 * 86400000;
  await f.service.reconcile(owner, [receipt(order)]); assert.equal(f.ledger.snapshot(owner).status, 'verified');
  const invalid = f.makeOrder('order-2'); invalid.purchaseTime += 3600000 + 60001;
  await assert.rejects(() => f.service.reconcile(owner, [receipt(invalid)]), /intent_not_found/);
});
test('refund is terminal for its order, preserves other purchases, and increments signed revision', async t => {
  const f = fixture(t); const first = f.makeOrder(); const second = f.makeOrder('order-2');
  await f.service.reconcile(owner, [receipt(first), receipt(second)]); const oldRevision = f.ledger.snapshot(owner).revision;
  first.revoked = true; f.state.now++;
  await f.service.notification('verified by vendor adapter');
  assert.equal(f.ledger.snapshot(owner).status, 'verified'); assert.ok(f.ledger.snapshot(owner).revision > oldRevision);
  second.revoked = true; f.state.now++;
  const result = await f.service.reconcile(owner);
  assert.equal(jwsParts(result.signedEntitlement).payload.status, 'revoked');
  first.revoked = false; f.state.now++;
  await f.service.reconcile(owner); assert.equal(f.ledger.snapshot(owner).status, 'revoked');
});
test('older concurrent order response cannot overwrite newer state or renew its verification timestamp', t => {
  const f = fixture(t); const order = f.makeOrder(); f.ledger.applyCurrentOrder(order, owner, f.state.now);
  f.ledger.applyCurrentOrder({ ...order, signedTime: order.signedTime + 1000, revoked: true }, owner, f.state.now + 1000);
  assert.throws(() => f.ledger.applyCurrentOrder(order, owner, f.state.now + 2000), /stale_order_response/);
  assert.equal(f.ledger.snapshot(owner).status, 'revoked'); assert.equal(f.ledger.snapshot(owner).checkedAt, f.state.now + 1000);
});
test('unavailable reconciliation issues no new signed grant and keeps durable purchase intact', async t => {
  const f = fixture(t); const order = f.makeOrder(); await f.service.reconcile(owner, [receipt(order)]);
  f.state.networkDown = true; f.state.now += 7 * 86400000;
  await assert.rejects(() => f.service.reconcile(owner)); assert.equal(f.ledger.snapshot(owner).status, 'verified');
});
test('database contains no raw purchase token and rejects environment/key reuse', async t => {
  const f = fixture(t); const order = f.makeOrder(); await f.service.reconcile(owner, [receipt(order)]);
  f.restart();
  assert.equal(readFileSync(f.database).includes(Buffer.from(order.purchaseToken)), false);
  assert.throws(() => new ProOrderLedger(f.database, { ...configuration, environment: 'SANDBOX' }, f.key));
  assert.throws(() => new ProOrderLedger(f.database, configuration, randomBytes(32)), /integrity/);
});
test('two processes sharing the ledger can claim only one delivery lease', t => {
  const f = fixture(t); const order = f.makeOrder(); f.ledger.applyCurrentOrder(order, owner, f.state.now);
  const second = new ProOrderLedger(f.database, configuration, f.key);
  const lease = f.ledger.claimFinish(order, f.state.now); assert.ok(lease);
  assert.equal(second.claimFinish(order, f.state.now), '');
  second.finishSucceeded(order.purchaseOrderId, 'old-unrelated-lease'); assert.equal(f.ledger.snapshot(owner).pending, true);
  f.ledger.finishSucceeded(order.purchaseOrderId, lease); assert.equal(second.snapshot(owner).pending, false); second.close();
});
test('an unknown schema fails without downgrading the database', t => {
  const f = fixture(t); const db = new DatabaseSync(f.database);
  db.exec('PRAGMA user_version=27');
  assert.throws(() => new ProOrderLedger(f.database, configuration, f.key), /schema_unsupported/);
  assert.equal(db.prepare('PRAGMA user_version').get().user_version, 27); db.close();
});
