import { createPrivateKey, sign } from 'node:crypto';
import { boundedString, fail } from './iap-crypto.mjs';
import { orderReferenceFromPurchaseData } from './huawei-api.mjs';

export class ProGrantSigner {
  #key;
  #configuration;
  constructor(configuration, privateKey) {
    this.#key = createPrivateKey(privateKey);
    if (this.#key.asymmetricKeyType !== 'rsa' || this.#key.asymmetricKeyDetails?.modulusLength !== 2048) fail('grant_rsa2048_key_required');
    for (const value of [configuration.applicationId, configuration.productId, configuration.keyId, configuration.issuer]) boundedString(value);
    if (!['NORMAL', 'SANDBOX'].includes(configuration.environment)) fail('grant_environment_required');
    this.#configuration = Object.freeze({ ...configuration });
  }
  sign(snapshot, owner, now) {
    if (!/^owner-[a-f0-9]{64}$/.test(owner) || !['verified', 'revoked', 'noEntitlement'].includes(snapshot.status) ||
        !Number.isSafeInteger(snapshot.revision) || snapshot.revision < 0 || !Number.isSafeInteger(now) || now <= 0) fail('invalid_grant');
    const payload = { version: 1, issuer: this.#configuration.issuer, applicationId: this.#configuration.applicationId,
      owner, environment: this.#configuration.environment === 'NORMAL' ? 'production' : 'sandbox',
      productId: this.#configuration.productId, status: snapshot.status, revision: snapshot.revision,
      entitlementIds: snapshot.status === 'verified' ? ['pro.lifetime'] : [],
      verifiedAt: now, revalidateAfter: now + 86400000, usableUntil: now + 7 * 86400000 };
    const input = Buffer.from(JSON.stringify({ alg: 'RS256', typ: 'JWT', kid: this.#configuration.keyId })).toString('base64url') + '.' +
      Buffer.from(JSON.stringify(payload)).toString('base64url');
    return input + '.' + sign('RSA-SHA256', Buffer.from(input), this.#key).toString('base64url');
  }
}

export class ProFulfillmentService {
  #ledger;
  #iap;
  #signer;
  #now;
  #operations = new Map();
  constructor(ledger, iap, signer, now = Date.now) {
    this.#ledger = ledger; this.#iap = iap; this.#signer = signer; this.#now = now;
  }
  createIntent(owner) { return this.#ledger.createIntent(owner, this.#now()); }
  async #exclusive(reference, action) {
    const key = reference.purchaseOrderId;
    while (this.#operations.has(key)) await this.#operations.get(key).catch(() => {});
    const operation = action(); this.#operations.set(key, operation);
    try { return await operation; }
    finally { if (this.#operations.get(key) === operation) this.#operations.delete(key); }
  }
  async #refresh(reference, expectedOwner, notificationId = '', deliver = false) {
    return this.#exclusive(reference, async () => {
      const order = await this.#iap.query(reference);
      const applied = await this.#ledger.applyCurrentOrder(order, expectedOwner, this.#now(), notificationId);
      // Only the independent outbox worker confirms delivery. Checkout/restore
      // first return the signed grant backed by this durable account binding.
      if (deliver && applied.finishPending) {
        const lease = await this.#ledger.claimFinish(reference, this.#now());
        if (lease) {
          try {
            await this.#iap.confirm(reference);
            await this.#ledger.finishSucceeded(reference.purchaseOrderId, lease);
          } catch { await this.#ledger.finishFailed(reference.purchaseOrderId, lease, this.#now()); }
        }
      }
      return applied.owner;
    });
  }
  async reconcile(owner, records = [], signal) {
    if (!Array.isArray(records) || records.length > 32 || records.some(record => typeof record !== 'string') ||
        records.reduce((size, record) => size + Buffer.byteLength(record), 0) > 1024 * 1024) fail('restore_batch_invalid');
    const references = new Map((await this.#ledger.references(owner, true)).map(reference => [reference.purchaseOrderId, reference]));
    for (const record of records) {
      const reference = orderReferenceFromPurchaseData(record);
      // A verified terminal refund remains an immutable local tombstone. Its
      // vendor record becoming unavailable cannot block a different purchase.
      if (await this.#ledger.terminalReference(owner, reference)) continue;
      const existing = references.get(reference.purchaseOrderId);
      if (existing && existing.purchaseToken !== reference.purchaseToken) fail('conflicting_order_reference');
      references.set(reference.purchaseOrderId, reference);
    }
    if (references.size > 100) fail('restore_order_limit');
    // Do not issue a new signed cache lifetime until every nonterminal order was
    // checked. Network/identity errors preserve the client's prior valid cache.
    for (const reference of references.values()) {
      if (signal?.aborted) fail('reconciliation_cancelled');
      await this.#refresh(reference, owner);
    }
    if (signal?.aborted) fail('reconciliation_cancelled');
    const snapshot = await this.#ledger.snapshot(owner);
    return { signedEntitlement: this.#signer.sign(snapshot, owner, this.#now()), pendingDelivery: snapshot.pending };
  }
  async notification(jws) {
    const notification = await this.#iap.notification(jws);
    if (notification.reference === null) return;
    await this.#refresh(notification.reference, undefined, notification.id);
    // The HTTP adapter acknowledges only after the durable transaction above.
  }
  async reconcileDue() {
    const due = await this.#ledger.dueOrders(this.#now());
    let successful = 0;
    for (const item of due) {
      try { await this.#refresh(item.reference, item.owner, '', true); successful++; }
      catch { /* retain pending state for the next bounded reconciliation */ }
    }
    return { checked: due.length, successful };
  }
}
