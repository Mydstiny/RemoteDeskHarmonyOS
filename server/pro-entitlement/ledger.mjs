import { DatabaseSync } from 'node:sqlite';
import { createCipheriv, createDecipheriv, createHash, randomBytes, randomUUID } from 'node:crypto';
import { chmodSync, lstatSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { boundedString, fail } from './iap-crypto.mjs';

function ownerId(value) {
  if (typeof value !== 'string' || !/^owner-[a-f0-9]{64}$/.test(value)) fail('invalid_owner');
  return value;
}
function time(value) { if (!Number.isSafeInteger(value) || value <= 0) fail('invalid_time'); return value; }
function tokenHash(value) { return createHash('sha256').update(boundedString(value)).digest('hex'); }

// One local SQLite database per configured application/environment/product.
// All token material is AES-GCM encrypted; the key is provided by deployment.
export class ProOrderLedger {
  #db;
  #key;
  #configuration;
  constructor(path, configuration, encryptionKey) {
    if (!Buffer.isBuffer(encryptionKey) || encryptionKey.length !== 32) fail('ledger_key_required');
    this.#configuration = Object.freeze({ applicationId: boundedString(configuration.applicationId),
      productId: boundedString(configuration.productId), environment: boundedString(configuration.environment) });
    if (!['NORMAL', 'SANDBOX'].includes(this.#configuration.environment)) fail('invalid_environment');
    this.#key = Buffer.from(encryptionKey);
    if (path !== ':memory:') {
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
      const directory = lstatSync(dirname(path));
      if (!directory.isDirectory() || directory.isSymbolicLink() || (directory.mode & 0o077) !== 0) fail('ledger_directory_not_private');
      try {
        const file = lstatSync(path);
        if (!file.isFile() || file.isSymbolicLink() || (file.mode & 0o077) !== 0) fail('ledger_file_not_private');
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
    try {
      this.#db = new DatabaseSync(path);
      if (path !== ':memory:') chmodSync(path, 0o600);
      const version = this.#db.prepare('PRAGMA user_version').get().user_version;
      if (version !== 0 && version !== 1) fail('ledger_schema_unsupported');
      this.#db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS configuration (id INTEGER PRIMARY KEY CHECK(id=1), identity TEXT NOT NULL, key_check TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS intents (id TEXT PRIMARY KEY, owner TEXT NOT NULL, created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL, order_id TEXT NOT NULL DEFAULT '');
      CREATE INDEX IF NOT EXISTS intents_owner ON intents(owner);
      CREATE TABLE IF NOT EXISTS accounts (owner TEXT PRIMARY KEY, revision INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS orders (order_id TEXT PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE, token_cipher TEXT NOT NULL,
        owner TEXT NOT NULL, intent_id TEXT NOT NULL, purchase_time INTEGER NOT NULL, signed_time INTEGER NOT NULL,
        checked_at INTEGER NOT NULL, revoked INTEGER NOT NULL, finished INTEGER NOT NULL, finish_pending INTEGER NOT NULL,
        finish_lease TEXT NOT NULL DEFAULT '', lease_until INTEGER NOT NULL DEFAULT 0, next_attempt INTEGER NOT NULL DEFAULT 0,
        attempts INTEGER NOT NULL DEFAULT 0);
      CREATE INDEX IF NOT EXISTS orders_owner ON orders(owner);
      CREATE TABLE IF NOT EXISTS notifications (id TEXT PRIMARY KEY, order_id TEXT NOT NULL, received_at INTEGER NOT NULL);
      PRAGMA user_version=1;`);
      const identity = JSON.stringify(this.#configuration);
      const existing = this.#db.prepare('SELECT identity, key_check FROM configuration WHERE id=1').get();
      if (existing) {
        if (existing.identity !== identity || this.#decrypt(existing.key_check, 'configuration') !== identity) {
          fail('ledger_configuration_mismatch');
        }
      } else {
        this.#db.prepare('INSERT INTO configuration(id,identity,key_check) VALUES(1,?,?)').run(identity, this.#encrypt(identity, 'configuration'));
      }
    } catch (error) {
      this.close(); throw error;
    }
  }
  #encrypt(value, aad) {
    const iv = randomBytes(12); const cipher = createCipheriv('aes-256-gcm', this.#key, iv);
    cipher.setAAD(Buffer.from(aad));
    const encrypted = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
    return Buffer.concat([iv, cipher.getAuthTag(), encrypted]).toString('base64');
  }
  #decrypt(value, aad) {
    try {
      const bytes = Buffer.from(value, 'base64');
      const decipher = createDecipheriv('aes-256-gcm', this.#key, bytes.subarray(0, 12));
      decipher.setAuthTag(bytes.subarray(12, 28)); decipher.setAAD(Buffer.from(aad));
      return Buffer.concat([decipher.update(bytes.subarray(28)), decipher.final()]).toString('utf8');
    } catch { fail('ledger_integrity_error'); }
  }
  #transaction(action) {
    this.#db.exec('BEGIN IMMEDIATE');
    try { const result = action(); this.#db.exec('COMMIT'); return result; }
    catch (error) { this.#db.exec('ROLLBACK'); throw error; }
  }
  createIntent(owner, now) {
    ownerId(owner); time(now);
    return this.#transaction(() => {
      if (this.#db.prepare('SELECT COUNT(*) AS count FROM intents WHERE owner=? AND order_id=\'\' AND expires_at>?').get(owner, now).count >= 8) {
        fail('too_many_pending_purchases');
      }
      const id = randomBytes(32).toString('base64url');
      // Retain the binding after checkout expiry so a delayed valid callback or
      // later restore can recover a purchase made within the allowed window.
      const expiresAt = now + 3600000;
      this.#db.prepare('INSERT INTO intents(id,owner,created_at,expires_at) VALUES(?,?,?,?)').run(id, owner, now, expiresAt);
      return { developerPayload: id, expiresAt, productId: this.#configuration.productId, environment: this.#configuration.environment };
    });
  }
  #assertOrder(order) {
    boundedString(order.purchaseOrderId); boundedString(order.purchaseToken); time(order.signedTime);
    if (order.applicationId !== this.#configuration.applicationId || order.productId !== this.#configuration.productId ||
        order.environment !== this.#configuration.environment || typeof order.revoked !== 'boolean' ||
        typeof order.needsFinish !== 'boolean') fail('ledger_order_scope_invalid');
  }
  applyCurrentOrder(order, expectedOwner, now, notificationId = '') {
    this.#assertOrder(order); time(now);
    if (expectedOwner !== undefined) ownerId(expectedOwner);
    if (notificationId) boundedString(notificationId);
    return this.#transaction(() => {
      const existing = this.#db.prepare('SELECT * FROM orders WHERE order_id=?').get(order.purchaseOrderId);
      let owner = existing?.owner;
      let intentId = existing?.intent_id;
      if (existing) {
        if (existing.token_hash !== tokenHash(order.purchaseToken) ||
            this.#decrypt(existing.token_cipher, order.purchaseOrderId) !== order.purchaseToken ||
            (order.developerPayload && order.developerPayload !== existing.intent_id)) fail('order_binding_mismatch');
      } else {
        const intent = this.#db.prepare('SELECT * FROM intents WHERE id=?').get(boundedString(order.developerPayload));
        if (!intent || (intent.order_id !== '' && intent.order_id !== order.purchaseOrderId) ||
            !Number.isSafeInteger(order.purchaseTime) || order.purchaseTime < intent.created_at - 60000 ||
            order.purchaseTime > intent.expires_at + 60000) fail('purchase_intent_not_found');
        owner = intent.owner; intentId = intent.id;
      }
      if (expectedOwner !== undefined && owner !== expectedOwner) fail('order_belongs_to_another_account');
      const tokenOwner = this.#db.prepare('SELECT order_id FROM orders WHERE token_hash=?').get(tokenHash(order.purchaseToken));
      if (tokenOwner && tokenOwner.order_id !== order.purchaseOrderId) fail('purchase_token_already_bound');
      if (existing && order.signedTime < existing.signed_time) {
        // Do not mark an older response as a fresh reconciliation.
        fail('stale_order_response');
      }
      // Revocation for a particular purchase is terminal. A subsequent valid
      // purchase has a different order/token and can independently restore Pro.
      const revoked = order.revoked || existing?.revoked === 1;
      const finished = existing?.finished === 1 || (!order.needsFinish && !revoked);
      const pending = !revoked && !finished && order.needsFinish;
      if (!existing) {
        this.#db.prepare('UPDATE intents SET order_id=? WHERE id=?').run(order.purchaseOrderId, intentId);
        this.#db.prepare(`INSERT INTO orders(order_id,token_hash,token_cipher,owner,intent_id,purchase_time,signed_time,
          checked_at,revoked,finished,finish_pending) VALUES(?,?,?,?,?,?,?,?,?,?,?)`).run(order.purchaseOrderId,
          tokenHash(order.purchaseToken), this.#encrypt(order.purchaseToken, order.purchaseOrderId), owner, intentId,
          order.purchaseTime, order.signedTime, now, Number(revoked), Number(finished), Number(pending));
      } else {
        this.#db.prepare('UPDATE orders SET signed_time=?,checked_at=?,revoked=?,finished=?,finish_pending=? WHERE order_id=?')
          .run(order.signedTime, now, Number(revoked), Number(finished), Number(pending), order.purchaseOrderId);
      }
      if (!existing || revoked !== (existing.revoked === 1)) {
        this.#db.prepare('INSERT INTO accounts(owner,revision) VALUES(?,1) ON CONFLICT(owner) DO UPDATE SET revision=revision+1').run(owner);
      }
      if (notificationId) this.#db.prepare('INSERT OR IGNORE INTO notifications(id,order_id,received_at) VALUES(?,?,?)')
        .run(notificationId, order.purchaseOrderId, now);
      return { owner, revoked, finishPending: pending };
    });
  }
  references(owner) {
    ownerId(owner);
    const rows = this.#db.prepare('SELECT order_id,token_cipher FROM orders WHERE owner=? ORDER BY order_id LIMIT 101').all(owner);
    if (rows.length > 100) fail('account_order_limit');
    return rows.map(row => ({ purchaseOrderId: row.order_id, purchaseToken: this.#decrypt(row.token_cipher, row.order_id) }));
  }
  snapshot(owner) {
    ownerId(owner);
    const rows = this.#db.prepare('SELECT revoked,finish_pending,checked_at FROM orders WHERE owner=?').all(owner);
    const active = rows.filter(row => row.revoked === 0);
    return { status: active.length ? 'verified' : rows.length ? 'revoked' : 'noEntitlement',
      revision: this.#db.prepare('SELECT revision FROM accounts WHERE owner=?').get(owner)?.revision || 0,
      pending: rows.some(row => row.finish_pending === 1),
      checkedAt: rows.length ? Math.min(...rows.map(row => row.checked_at)) : 0 };
  }
  claimFinish(reference, now) {
    boundedString(reference.purchaseOrderId); time(now);
    return this.#transaction(() => {
      const row = this.#db.prepare('SELECT * FROM orders WHERE order_id=?').get(reference.purchaseOrderId);
      if (!row || row.token_hash !== tokenHash(reference.purchaseToken) || row.revoked || !row.finish_pending ||
          row.lease_until > now || row.next_attempt > now) return '';
      const lease = randomUUID();
      this.#db.prepare('UPDATE orders SET finish_lease=?,lease_until=?,attempts=attempts+1 WHERE order_id=?')
        .run(lease, now + 120000, reference.purchaseOrderId);
      return lease;
    });
  }
  finishSucceeded(orderId, lease) {
    this.#db.prepare(`UPDATE orders SET finished=1,finish_pending=0,finish_lease='',lease_until=0,next_attempt=0
      WHERE order_id=? AND finish_lease=?`).run(boundedString(orderId), boundedString(lease));
  }
  finishFailed(orderId, lease, now) {
    time(now);
    this.#db.prepare(`UPDATE orders SET finish_lease='',lease_until=0,next_attempt=?
      WHERE order_id=? AND finish_lease=?`).run(now + 120000, boundedString(orderId), boundedString(lease));
  }
  dueOrders(now, limit = 20) {
    time(now);
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) fail('invalid_batch_limit');
    // Active orders are periodically rechecked even when delivery was already
    // acknowledged, so a missed refund notification is eventually reconciled.
    return this.#db.prepare(`SELECT order_id,token_cipher,owner FROM orders WHERE
      (finish_pending=1 AND next_attempt<=? AND lease_until<=?) OR (revoked=0 AND checked_at<=?)
      ORDER BY checked_at LIMIT ?`).all(now, now, now - 6 * 3600000, limit).map(row => ({ owner: row.owner,
      reference: { purchaseOrderId: row.order_id, purchaseToken: this.#decrypt(row.token_cipher, row.order_id) } }));
  }
  close() { this.#db?.close(); this.#db = undefined; this.#key.fill(0); }
}
