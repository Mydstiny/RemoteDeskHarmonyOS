const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const path = require('node:path');
const { test } = require('node:test');
const { proClientHost, base, sessionReply } = require('./helpers/pro_client_host.cjs');
const owner = 'owner-' + 'a'.repeat(64);
const other = 'owner-' + 'b'.repeat(64);
const keys = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const config = { applicationId: 'test-app', productId: 'test-pro', environment: 'sandbox', issuer: 'test-issuer',
  keyId: 'test-key', publicKeyDer: new Uint8Array(keys.publicKey.export({ format: 'der', type: 'spki' })) };
const normalize = value => JSON.parse(JSON.stringify(value));
async function fixture(t, options = {}) {
  const host = proClientHost(options); t.after(() => host.close());
  const { ProGrantSigner } = await import('../../server/pro-entitlement/fulfillment.mjs');
  const signer = new ProGrantSigner({ ...config, environment: 'SANDBOX' }, keys.privateKey.export({ type: 'pkcs8', format: 'pem' }));
  const { ProEntitlementStore } = host.load('ProEntitlementStore');
  const { ProEntitlementClock } = host.load('ProEntitlementClock');
  const { ProTrustedEntitlementClient, proPurchaseBatches } = host.load('ProTrustedEntitlementClient');
  const { ProEntitlementService } = host.load('ProEntitlementService');
  const store = new ProEntitlementStore();
  await Promise.all([store.initialize({}), store.initialize({})]); assert.equal(host.state.opens, 1);
  const clock = new ProEntitlementClock();
  const state = { revision: 1, status: 'verified', calls: [], cancelled: 0, offline: false, override: null, ...host.state };
  const transport = { cancel() { state.cancelled++; }, async post(operation, body, current) {
    const input = JSON.parse(body); const call = { operation, input, current }; state.calls.push(call);
    if (state.offline) throw new Error('offline');
    if (state.override) return state.override(call);
    if (operation === 'intents') return JSON.stringify({ developerPayload: crypto.randomBytes(32).toString('base64url'),
      productId: config.productId, environment: 'SANDBOX', expiresAt: host.state.now + 3600000 });
    return JSON.stringify({ signedEntitlement: signer.sign({ revision: state.revision, status: state.status }, owner,
      host.state.now, input.challenge), pendingDelivery: false });
  } };
  const client = new ProTrustedEntitlementClient(config, store, transport, clock); client.bind(owner, 1);
  const service = new ProEntitlementService(client, () => clock.now()); service.bindAccount(owner, 'sandbox', 1);
  const lease = client.lease();
  const backend = { lease: id => id === config.productId ? client.lease() : null, current: value => client.current(value),
    intent: (value, current) => client.intent(value, current), retain: (value, records) => client.retain(value, records),
    pending: value => client.pending(value), reconcile: (value, records) => client.current(value) ? service.reconcileResult(records) :
      Promise.resolve({ current: false, online: false, active: false }) };
  return { ...host, store, clock, signer, transport, client, service, lease, backend, protocol: state, proPurchaseBatches,
    rebind(account, generation) { client.bind(account, generation); service.bindAccount(account, 'sandbox', generation); } };
}

test('real signed reconciliation atomically caches the grant and removes only accepted receipts', async t => {
  const f = await fixture(t); await f.client.retain(f.lease, ['receipt-a', 'receipt-b']);
  assert.equal(await f.service.reconcile(['receipt-a'], true), true);
  assert.equal(f.service.snapshot().state, 'active');
  assert.deepEqual(normalize(await f.client.pending(f.lease)), ['receipt-b']);
  const cached = await f.store.read(f.lease.scope, f.clock.now()); assert.equal(cached.revision, 1);
  assert.equal(f.protocol.calls[0].input.challenge.length, 43);
  await f.service.reconcile(['receipt-b'], true);
  assert.notEqual(f.protocol.calls[0].input.challenge, f.protocol.calls[1].input.challenge);
  assert.equal((await f.client.pending(f.lease)).length, 0);
});
test('replaying an old signed response cannot count as online verification or renew cache expiry', async t => {
  const f = await fixture(t); await f.service.reconcile([], true);
  const previous = await f.store.read(f.lease.scope, f.clock.now());
  f.state.now += 500; f.state.uptime += 500;
  f.protocol.override = () => JSON.stringify({ signedEntitlement: previous.signedEntitlement, pendingDelivery: false });
  assert.equal(await f.service.reconcile([], true), false);
  assert.equal(f.service.snapshot().state, 'active'); assert.equal(f.service.snapshot().needsRevalidation, true);
  const cached = await f.store.read(f.lease.scope, f.clock.now()); assert.equal(cached.signedEntitlement, previous.signedEntitlement);
});
test('account or environment ABA cannot revive an old in-flight response', async t => {
  const f = await fixture(t); let complete; let arrived;
  const started = new Promise(resolve => { arrived = resolve; });
  f.protocol.override = call => new Promise(resolve => { complete = () => resolve(JSON.stringify({
    signedEntitlement: f.signer.sign({ status: 'verified', revision: 1 }, owner, f.state.now, call.input.challenge),
    pendingDelivery: false })); arrived(); });
  const pending = f.service.reconcile([], true); await started;
  f.rebind('', -1); f.rebind(owner, 1); assert.equal(f.client.current(f.lease), false);
  complete(); assert.equal(await pending, false); assert.equal(f.service.snapshot().state, 'free');
  assert.equal(f.database.prepare('SELECT COUNT(*) AS count FROM pro_cache').get().count, 0);
});
test('a verified refund takes effect immediately when cache persistence fails and survives an account round trip', async t => {
  const f = await fixture(t); await f.service.reconcile([], true);
  f.protocol.revision = 2; f.protocol.status = 'revoked'; f.state.now++;
  f.state.beforeSql = sql => { if (sql.startsWith('INSERT OR REPLACE INTO pro_cache')) throw new Error('disk full'); };
  assert.equal(await f.service.reconcile([], true), false); assert.equal(f.service.snapshot().state, 'revoked');
  f.rebind(other, 2); f.rebind(owner, 3); await f.service.restoreCached();
  assert.equal(f.service.snapshot().state, 'revoked');
  f.protocol.offline = true; await f.service.reconcile([], true); assert.equal(f.service.snapshot().state, 'revoked');
  assert.equal(f.database.prepare('SELECT revision FROM pro_cache').get().revision, 1);
  f.state.beforeSql = () => {}; f.protocol.offline = false;
  const result = await f.service.reconcileResult([]); assert.equal(result.online, true);
  assert.equal(f.database.prepare('SELECT revision FROM pro_cache').get().revision, 2);
});
test('a verified refund applies while a second same-account reconciliation is still waiting', async t => {
  const f = await fixture(t); await f.service.reconcile([], true);
  let calls = 0; let release; let entered;
  const secondStarted = new Promise(resolve => { entered = resolve; });
  f.protocol.override = call => {
    if (++calls === 1) return JSON.stringify({ signedEntitlement: f.signer.sign({ status: 'revoked', revision: 2 },
      owner, f.state.now, call.input.challenge), pendingDelivery: false });
    return new Promise((_resolve, reject) => { release = () => reject(new Error('offline')); entered(); });
  };
  const first = f.service.reconcileResult([]); const second = f.service.reconcileResult([]);
  const revoked = await first; await secondStarted;
  assert.equal(revoked.current, true); assert.equal(revoked.online, true); assert.equal(revoked.active, false);
  assert.equal(f.database.prepare('SELECT revision FROM pro_cache').get().revision, 2);
  assert.equal(f.service.snapshot().state, 'revoked');
  release(); await second; assert.equal(f.service.snapshot().state, 'revoked');
});
test('offline restart loads only the original signed account and product cache', async t => {
  const f = await fixture(t); await f.service.reconcile([], true);
  const { ProEntitlementStore } = f.load('ProEntitlementStore'); const reopened = new ProEntitlementStore();
  await reopened.initialize({}); f.state.now += 1000; f.state.uptime += 1000;
  const { ProTrustedEntitlementClient } = f.load('ProTrustedEntitlementClient');
  f.protocol.offline = true; const client = new ProTrustedEntitlementClient(config, reopened, f.transport, f.clock);
  client.bind(owner, 5); assert.equal((await client.loadCached(owner, 'sandbox')).status, 'verified');
  assert.equal((await client.loadCached(owner, 'production')).status, 'unavailable');
  client.bind(other, 6); assert.equal((await client.loadCached(other, 'sandbox')).status, 'unavailable');
});
test('clock rollback stays blocked after replay and clears only after a fresh online signature', async t => {
  const f = await fixture(t); await f.service.reconcile([], true);
  const cached = await f.store.read(f.lease.scope, f.clock.now());
  f.state.now += 1000000000; f.state.uptime += 1; f.service.snapshot();
  f.state.now -= 1000000000; f.state.uptime += 1;
  await f.service.restoreCached(); assert.equal(f.service.snapshot().state, 'verificationRequired');
  f.protocol.override = () => JSON.stringify({ signedEntitlement: cached.signedEntitlement, pendingDelivery: false });
  assert.equal(await f.service.reconcile([], true), false); assert.equal(f.service.snapshot().state, 'verificationRequired');
  f.protocol.override = null; f.state.now += 10; f.protocol.revision++;
  assert.equal(await f.service.reconcile([], true), true); assert.equal(f.service.snapshot().state, 'active');
  assert.equal((await f.store.read(f.lease.scope, f.clock.now())).clockBlocked, false);
});
test('elapsed uptime exhausts offline validity even with a stalled wall clock', async t => {
  const f = await fixture(t); await f.service.reconcile([], true);
  f.protocol.offline = true; f.state.uptime += 7 * 86400000;
  assert.equal(f.service.snapshot().state, 'verificationRequired');
  assert.equal(await f.service.reconcile([], true), false);
  assert.equal(f.service.snapshot().entitlementIds.length, 0);
});
test('signed refund history protects the revision floor after its offline lifetime has elapsed', async t => {
  const f = await fixture(t); f.protocol.status = 'revoked'; f.protocol.revision = 9;
  await f.service.reconcile([], true); const cached = await f.store.read(f.lease.scope, f.clock.now());
  f.state.now += 8 * 86400000; f.state.uptime += 8 * 86400000;
  const { ProSignedEntitlementVerifier } = f.load('ProSignedEntitlement'); const verifier = new ProSignedEntitlementVerifier(config);
  assert.equal((await verifier.inspectCached(cached.signedEntitlement, owner, f.clock.now())).signedStatus, 'revoked');
  await assert.rejects(() => verifier.verify(cached.signedEntitlement, owner, f.clock.now()));
  f.protocol.revision = 8; f.protocol.status = 'verified'; await f.service.reconcile([], true);
  assert.equal(f.service.snapshot().state, 'revoked');
});
test('tampered revision metadata cannot bless a signature or be overwritten by a lower revision', async t => {
  const f = await fixture(t); await f.service.reconcile([], true);
  f.database.exec('UPDATE pro_cache SET revision=999'); f.rebind('', 2); f.rebind(owner, 3);
  await f.service.restoreCached(); assert.equal(f.service.snapshot().state, 'verificationRequired');
  assert.equal(await f.service.reconcile([], true), false);
  assert.equal(f.database.prepare('SELECT revision FROM pro_cache').get().revision, 999);
});
test('cache/dequeue failure rolls back the whole transaction and preserves all recovery receipts', async t => {
  const f = await fixture(t); await f.client.retain(f.lease, ['one', 'two']);
  f.state.beforeSql = sql => { if (sql.startsWith('DELETE FROM pro_pending')) throw new Error('write interrupted'); };
  assert.equal(await f.service.reconcile(['one'], true), false);
  assert.equal(f.database.prepare('SELECT COUNT(*) AS count FROM pro_cache').get().count, 0);
  assert.equal((await f.client.pending(f.lease)).length, 2);
  assert.notEqual(f.service.snapshot().state, 'active');
});
test('purchase intent pins the server product and environment and cancels before checkout', async t => {
  const f = await fixture(t); const intent = await f.client.intent(f.lease, () => true);
  assert.equal(intent.developerPayload.length, 43); assert.equal(intent.productId, config.productId);
  for (const changes of [{ environment: 'NORMAL' }, { productId: 'other' }, { developerPayload: '' },
    { expiresAt: f.state.now }, { intent: 'wrong-field' }]) {
    f.protocol.override = () => JSON.stringify({ ...intent, ...changes });
    await assert.rejects(() => f.client.intent(f.lease, () => true));
  }
  await assert.rejects(() => f.client.intent(f.lease, () => false));
});
test('UTF-8 receipt and encoded HTTP limits are bounded without truncating recoverable records', async t => {
  const f = await fixture(t); const records = Array.from({ length: 32 }, (_, i) => '"'.repeat(65000) + i);
  const batches = f.proPurchaseBatches(records); assert.ok(batches.length > 1);
  assert.equal(batches.flat().length, records.length);
  for (const batch of batches) assert.ok(Buffer.byteLength(JSON.stringify({ purchaseDataList: batch,
    challenge: crypto.randomBytes(32).toString('base64url') })) <= 1024 * 1024);
  assert.throws(() => f.proPurchaseBatches(['汉'.repeat(23000)]));
  await f.client.retain(f.lease, ['original']);
  await assert.rejects(() => f.client.retain(f.lease, Array.from({ length: 100 }, (_, i) => 'x'.repeat(65000) + i)));
  assert.deepEqual(normalize(await f.client.pending(f.lease)), ['original']);
  f.database.prepare('UPDATE pro_pending SET data=?').run('x'.repeat(66561));
  await assert.rejects(() => f.client.pending(f.lease));
});
test('cloud transport pins function identity, normal loading and the current Huawei identity', async t => {
  let scope; const auth = { isAuthorized: () => true, getUnionID: () => 'test-union',
    getAccessToken: () => assert.fail('legacy token field must never be used as the Pro credential') };
  const f = await fixture(t, { mocks: {
    [path.resolve(base, '../AccountKitService.ets')]: { AccountKitService: { getInstance: () => auth } },
    [path.resolve(base, '../AccountSessionCoordinator.ets')]: { AccountSessionCoordinator: { getInstance: () => ({ currentScope: () => scope }) } }
  } });
  const { ownerScopeIdForUnionId } = f.load(path.resolve(base, '../AccountScopePolicy.ets'));
  scope = { kind: 'huawei_account', ownerScopeId: ownerScopeIdForUnionId('test-union'), generation: 1 };
  const { ProCloudTransport } = f.load('ProCloudTransport');
  const configuration = { trust: config, functionName: 'pro-sandbox', functionVersion: '$latest' };
  const transport = new ProCloudTransport(configuration, {}); configuration.functionName = 'changed';
  f.state.onCloud = async call => ({ result: { version: 1, status: 200, body: call.data.operation === 'session' ?
    JSON.stringify(sessionReply(JSON.parse(call.data.body), scope.ownerScopeId, f.state.now)) : '{}' } });
  assert.equal(await transport.post('intents', '{}', () => true), '{}');
  const request = f.state.requests[1]; assert.equal(request.name, 'pro-sandbox');
  assert.equal(request.version, '$latest'); assert.equal(request.loadMode, 0);
  assert.equal(request.localUrl, undefined); assert.equal(request.data.operation, 'intents');
  assert.equal(f.state.cloudInitializations.length, 1); assert.equal(f.state.cloudInitializations[0].region, 0);
  scope.ownerScopeId = other; await assert.rejects(() => transport.post('intents', '{}', () => true));
  assert.equal(f.state.requests.length, 2);
  scope.ownerScopeId = ownerScopeIdForUnionId('test-union'); auth.isAuthorized = () => false;
  await assert.rejects(() => transport.post('intents', '{}', () => true)); assert.equal(f.state.requests.length, 2);
  assert.throws(() => new ProCloudTransport({ ...configuration, functionName: 'https://invalid' }, {}));
  assert.throws(() => new ProCloudTransport({ ...configuration, functionVersion: '../invalid' }, {}));
});
test('billing retains a late payment under its captured account and never finishes it locally', async t => {
  let calls = 0; let complete; let start;
  const checkout = new Promise(resolve => { start = resolve; });
  const iap = { ProductType: { NONCONSUMABLE: 1 }, isSandboxActivated: async () => true,
    createPurchase: async (_context, parameter) => {
      calls++; assert.equal(parameter.developerPayload.length, 43);
      start(); return new Promise(resolve => { complete = () => resolve({ purchaseData: 'late-receipt' }); });
    }, finishPurchase: () => assert.fail('client must never finishPurchase') };
  const f = await fixture(t, { mocks: { '@kit.IAPKit': { iap } } });
  const { HuaweiProBillingProvider } = f.load('ProBillingService'); const provider = new HuaweiProBillingProvider(f.backend);
  const buying = provider.purchase({}, config.productId, () => true); await checkout;
  f.rebind(other, 2); complete(); const outcome = await buying;
  assert.equal(outcome.verified, false); assert.equal(calls, 1);
  assert.deepEqual(normalize(await f.store.pending(f.lease.scope)), ['late-receipt']);
  assert.equal((await f.store.pending(f.client.lease().scope)).length, 0); assert.equal(f.service.snapshot().state, 'free');
});
test('checkout cancellation during intent preflight prevents the actual IAP side effect', async t => {
  let valid = true; let calls = 0;
  const iap = { ProductType: { NONCONSUMABLE: 1 }, isSandboxActivated: async () => true,
    createPurchase: async () => { calls++; return { purchaseData: 'unused' }; } };
  const f = await fixture(t, { mocks: { '@kit.IAPKit': { iap } } });
  f.protocol.override = () => { valid = false; return JSON.stringify({ developerPayload: crypto.randomBytes(32).toString('base64url'),
    productId: config.productId, environment: 'SANDBOX', expiresAt: f.state.now + 3600000 }); };
  const { HuaweiProBillingProvider } = f.load('ProBillingService'); const provider = new HuaweiProBillingProvider(f.backend);
  await assert.rejects(() => provider.purchase({}, config.productId, () => valid)); assert.equal(calls, 0);
});
test('restore deduplicates both Huawei query types, persists pages and reconciles bounded batches', async t => {
  const queries = [];
  const first = Array.from({ length: 32 }, (_, i) => 'order-' + i);
  const iap = { ProductType: { NONCONSUMABLE: 1 }, PurchaseQueryType: { CURRENT_ENTITLEMENT: 2, UNFINISHED: 3 },
    isSandboxActivated: async () => true, queryPurchases: async (_context, query) => {
      queries.push(query);
      if (query.queryType === 3) return { purchaseDataList: ['order-0', 'order-32'] };
      return query.continuationToken ? { purchaseDataList: ['order-32'] } : { purchaseDataList: first, continuationToken: 'page-2' };
    } };
  const f = await fixture(t, { mocks: { '@kit.IAPKit': { iap } } });
  const { HuaweiProBillingProvider } = f.load('ProBillingService'); const provider = new HuaweiProBillingProvider(f.backend);
  const result = await provider.restore({}, config.productId, () => true);
  assert.equal(result.records, 33); assert.equal(result.verified, true); assert.equal(queries.length, 3);
  assert.equal(f.protocol.calls.length, 2);
  assert.ok(f.protocol.calls.every(call => call.input.purchaseDataList.length <= 32));
  assert.equal((await f.client.pending(f.lease)).length, 0);
});
test('restore account switch stops pagination after retaining the in-flight page in its original scope', async t => {
  let f; let queries = 0;
  const iap = { ProductType: { NONCONSUMABLE: 1 }, PurchaseQueryType: { CURRENT_ENTITLEMENT: 2, UNFINISHED: 3 },
    isSandboxActivated: async () => true, queryPurchases: async () => {
      queries++; f.rebind(other, 2); return { purchaseDataList: ['old-account-page'], continuationToken: 'next' };
    } };
  f = await fixture(t, { mocks: { '@kit.IAPKit': { iap } } });
  const { HuaweiProBillingProvider } = f.load('ProBillingService'); const provider = new HuaweiProBillingProvider(f.backend);
  const result = await provider.restore({}, config.productId, () => true);
  assert.equal(result.verified, false); assert.equal(queries, 1); assert.equal(f.protocol.calls.length, 0);
  assert.deepEqual(normalize(await f.store.pending(f.lease.scope)), ['old-account-page']);
});
test('another nonconsumable product is routed away from the Pro ledger without a local grant decision', async t => {
  const unrelated = JSON.stringify({ jwsPurchaseOrder: 'e30.' + Buffer.from(JSON.stringify({ productId: 'different-product' })).toString('base64url') + '.eA' });
  const iap = { ProductType: { NONCONSUMABLE: 1 }, PurchaseQueryType: { CURRENT_ENTITLEMENT: 2, UNFINISHED: 3 },
    isSandboxActivated: async () => true, queryPurchases: async () => ({ purchaseDataList: [unrelated, 'pro-reference'] }) };
  const f = await fixture(t, { mocks: { '@kit.IAPKit': { iap } } });
  const { HuaweiProBillingProvider } = f.load('ProBillingService'); const provider = new HuaweiProBillingProvider(f.backend);
  const result = await provider.restore({}, config.productId, () => true);
  assert.equal(result.records, 1); assert.deepEqual(f.protocol.calls[0].input.purchaseDataList, ['pro-reference']);
});
test('runtime boundary timers use the same elapsed clock as the entitlement checks', async t => {
  const f = await fixture(t); await f.service.reconcile([], true);
  const { ProRuntime } = f.load('ProRuntime'); const runtime = new ProRuntime(f.service);
  t.after(() => runtime.dispose()); runtime.subscribe(() => {});
  assert.equal([...f.state.timers.values()][0].delay, 86400000);
  f.state.uptime += 86400000; runtime.refresh();
  assert.equal([...f.state.timers.values()][0].delay, 300000);
  f.state.uptime += 6 * 86400000; runtime.refresh();
  assert.equal(runtime.snapshot().realState, 'verificationRequired');
  assert.equal([...f.state.timers.values()][0].delay, 300000);
});
test('actual App runtime renews daily, retries an offline boundary and keeps Release sandbox inaccessible', async t => {
  for (const debug of [true, false]) {
    const liveOwner = 'owner-' + crypto.createHash('sha256').update('RemoteDeskHarmonyOS:owner:v1:test-union').digest('hex');
    let scope = { kind: 'huawei_account', ownerScopeId: liveOwner, generation: 1, sessionState: 'ready' };
    let onScope; let onTransition;
    const account = { currentScope: () => scope,
      onChange(callback) { onScope = callback; return () => {}; },
      onTransitionActivity(callback) { onTransition = callback; return () => {}; } };
    const auth = { isAuthorized: () => true, getUnionID: () => 'test-union' };
    const f = await fixture(t, { debug, mocks: {
      [path.resolve(base, '../AccountSessionCoordinator.ets')]: { AccountSessionCoordinator: { getInstance: () => account } },
      [path.resolve(base, '../AccountKitService.ets')]: { AccountKitService: { getInstance: () => auth } },
      [path.resolve(base, 'ProBackendConfiguration.ets')]: { proBackendConfiguration: () => ({ trust: config,
        functionName: 'pro-sandbox', functionVersion: '$latest' }) }
    } });
    let offline = false; let status = 'verified'; let revision = 1;
    f.state.onCloud = async call => {
      if (offline) throw new Error('offline');
      if (call.data.operation === 'session') return { result: { version: 1, status: 200,
        body: JSON.stringify(sessionReply(JSON.parse(call.data.body), liveOwner, f.state.now)) } };
      return { result: { version: 1, status: 200, body: JSON.stringify({ pendingDelivery: false,
        signedEntitlement: f.signer.sign({ status, revision }, liveOwner, f.state.now,
          JSON.parse(call.data.body).challenge) }) } };
    };
    const { ProAppRuntime } = f.load('ProAppRuntime'); const app = ProAppRuntime.getInstance();
    app.runtime.subscribe(() => app.runtime.snapshot());
    t.after(() => app.runtime.dispose()); await app.initialize({}); app.setSandbox(true);
    for (let i = 0; i < 20 && app.runtime.snapshot().realState !== 'active'; i++) await new Promise(resolve => setImmediate(resolve));
    if (debug) {
      assert.equal(app.runtime.snapshot().label, '沙盒 · Pro 已激活');
      assert.ok(app.lease(config.productId));
      for (const delay of [86400000, 86400000, 300000]) {
        if (delay === 300000) { offline = false; status = 'revoked'; revision = 2; }
        const timer = [...f.state.timers.entries()].find(([_id, value]) => value.delay === delay);
        assert.ok(timer, 'the actual runtime must schedule the next refresh');
        const requests = f.state.requests.length;
        const cached = f.database.prepare('SELECT verified_at FROM pro_cache').get().verified_at;
        f.state.now += delay; f.state.uptime += delay;
        f.state.timers.delete(timer[0]); timer[1].callback();
        for (let i = 0; i < 30 && (f.state.requests.length === requests || app.refreshing); i++) {
          await new Promise(resolve => setImmediate(resolve));
        }
        assert.equal(f.state.requests.length, requests + (offline ? 1 : 2));
        if (offline) {
          assert.equal(app.runtime.snapshot().needsRevalidation, true);
          assert.equal(f.database.prepare('SELECT verified_at FROM pro_cache').get().verified_at, cached);
        } else if (status === 'verified') {
          assert.equal(app.runtime.snapshot().needsRevalidation, false);
          assert.equal(f.database.prepare('SELECT verified_at FROM pro_cache').get().verified_at, f.state.now);
          offline = true;
        } else { assert.equal(app.runtime.snapshot().realState, 'revoked'); }
      }
      onTransition(true); assert.equal(app.runtime.snapshot().realState, 'free');
      scope = { ...scope, generation: 2, ownerScopeId: other }; onScope(scope); onTransition(false);
      assert.notEqual(app.runtime.snapshot().realState, 'active');
      app.setSandbox(false); assert.equal(app.lease(config.productId), null);
    } else {
      assert.equal(app.runtime.snapshot().realState, 'free'); assert.equal(app.sandboxSelected(), false);
      assert.equal(app.lease(config.productId), null); assert.equal(f.state.requests.length, 0);
    }
  }
});
