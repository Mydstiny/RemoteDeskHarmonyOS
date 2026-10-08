const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { test } = require('node:test');
const { proClientHost } = require('./helpers/pro_client_host.cjs');
const key = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 }).publicKey.export({ format: 'der', type: 'spki' }).toString('base64');
const release = { enabled: true, functionName: 'fixture-pro-api', functionVersion: '3', applicationId: '1234567890',
  productId: 'fixture.pro', issuer: 'fixture-production', keyId: 'normal-v1', publicKeyBase64: key };
test('production configuration is disabled until reviewed values are populated; rejects mutable or sandbox routes', t => {
  const host = proClientHost({ debug: false }); t.after(() => host.close());
  const { productionProBackendConfiguration: build } = host.load('ProProductionRelease');
  assert.equal(build(), null);
  for (const bad of [{ enabled: false }, { functionVersion: '$latest' }, { functionVersion: '' },
    { functionName: 'remotedesk-pro-sandbox-api' }, { issuer: 'sandbox' }, { keyId: 'sandbox-key' },
    { productId: 'RemoteDesktop_Pro_Test' }, { applicationId: '' }, { publicKeyBase64: 'bad' }]) {
    assert.equal(build({ ...release, ...bad }), null);
  }
  const configured = build(release); assert.equal(configured.trust.environment, 'production');
  assert.equal(configured.functionVersion, '3'); assert.equal(configured.trust.productId, release.productId);
  configured.trust.publicKeyDer.fill(0); assert.equal(build(release).trust.publicKeyDer[0], 0x30);
  assert.equal(host.load('ProBackendConfiguration').proBackendConfiguration('production'), null);
});
function billing(t, { debug = false, environment = 'production' } = {}) {
  const calls = [], pending = []; let current = true;
  const lease = { generation: 1, scope: { owner: 'owner-fixture', applicationId: release.applicationId, productId: release.productId, environment } };
  const iap = { ProductType: { NONCONSUMABLE: 1 }, PurchaseQueryType: { CURRENT_ENTITLEMENT: 2, UNFINISHED: 3 },
    async isSandboxActivated() { calls.push('sandbox'); return true; },
    async queryProducts() { calls.push('product'); return [{ id: release.productId, type: 1, localPrice: '¥28.88', name: 'Fixture Pro' }]; },
    async createPurchase(_context, request) { calls.push(['purchase', request]); return { purchaseData: 'signed-receipt' }; },
    async queryPurchases(_context, request) { calls.push(['restore', request.queryType]); return { purchaseDataList: [] }; },
    async finishPurchase() { throw Error('client must not finish delivery'); }, async createRefundRequest() { calls.push('refund'); } };
  const backend = { lease: id => id === release.productId ? lease : null, current: value => current && value === lease,
    async intent() { return { developerPayload: 'server-bound-intent' }; },
    async retain(value, records) { assert.equal(value, lease); pending.push(...records); },
    async pending() { return pending; }, async reconcile() { calls.push('reconcile'); return { current, online: true, active: current }; },
    async refundOrder() { throw Error('production refund lookup must not execute'); } };
  const host = proClientHost({ debug, mocks: { '@kit.IAPKit': { iap } } }); t.after(() => host.close());
  return { calls, pending, lease, backend, iap, provider: new (host.load('ProBillingService').HuaweiProBillingProvider)(backend),
    invalidate() { current = false; } };
}
test('Release production purchase and restore use configured scope without calling debug-only sandbox probe', async t => {
  const f = billing(t);
  assert.equal((await f.provider.product({}, release.productId)).price, '¥28.88');
  assert.equal((await f.provider.purchase({}, release.productId, () => true)).verified, true);
  assert.deepEqual(f.pending, ['signed-receipt']);
  assert.equal(f.calls.find(x => Array.isArray(x) && x[0] === 'purchase')[1].developerPayload, 'server-bound-intent');
  assert.equal((await f.provider.restore({}, release.productId, () => true)).verified, true);
  assert.equal(f.calls.includes('sandbox'), false);
  assert.deepEqual(f.calls.filter(x => Array.isArray(x) && x[0] === 'restore'), [['restore', 2], ['restore', 3]]);
  await assert.rejects(() => f.provider.refund({}, release.productId, () => true));
  assert.equal(f.calls.includes('refund'), false);
});
test('Debug cannot charge production, Release cannot use sandbox, and cancelled production intent cannot launch payment', async t => {
  for (const options of [{ debug: true, environment: 'production' }, { debug: false, environment: 'sandbox' }]) {
    const f = billing(t, options); await assert.rejects(() => f.provider.purchase({}, release.productId, () => true));
    assert.equal(f.calls.length, 0);
  }
  const f = billing(t); f.backend.intent = async () => { f.invalidate(); return { developerPayload: 'stale' }; };
  assert.equal((await f.provider.purchase({}, release.productId, () => true)).verified, false);
  assert.equal(f.calls.some(x => Array.isArray(x) && x[0] === 'purchase'), false);
});


test('purchase sheet observes delayed backend readiness without discarding a loaded product on entitlement updates', async () => {
  const fs = require('node:fs'), vm = require('node:vm'), path = require('node:path');
  const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
  const original = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/components/ProPurchaseSheet.ets'), 'utf8');
  const source = (original.slice(0, original.indexOf('  @Builder')) + '\n}')
    .replace(/^import[\s\S]*?;\n/gm, '').replace(/^@Component\s*$/gm, '')
    .replace(/@StorageProp\([^\n]*?\)\s*/g, '').replace(/@State\s+/g, '')
    .replace('export struct ProPurchaseSheet', 'class ProPurchaseSheet');
  let ready = false, listener, active = false, productCalls = 0;
  const runtime = { sandboxSelected: () => false, billingProductId: () => 'fixture.pro', billingAvailable: () => ready,
    runtime: { subscribe(cb) { listener = cb; cb(); return () => {}; },
      snapshot: () => ({ realState: active ? 'active' : 'free', effectiveState: active ? 'active' : 'free',
        label: active ? 'Pro' : '免费版', mode: 'real' }) } };
  const context = vm.createContext({ DEBUG: false, ProAppRuntime: { getInstance: () => runtime },
    ProFeatureVisibility: { getInstance: () => ({ load: () => {}, subscribe: cb => { cb(); return () => {}; }, isVisible: () => true }) },
    ProFeatureVisibilityPanel: { prepare: () => {} },
    HuaweiProBillingProvider: class { async product() { productCalls++; return { id: 'fixture.pro', price: '¥1', name: 'Fixture' }; } },
    ProPurchaseCoordinator: { enter: () => true, leave: () => {} },
    ProPurchaseLifecycle: { capture: () => 1, current: () => true }, getContext: () => ({}),
    proTrialStarted: () => false, markProTrialStarted: () => {},
    // The main app (not an 应用分身): the label passes through unchanged.
    AppCloneContext: { getInstance: () => ({ isClone: () => false }) },
    proCloneLabel: (_isClone, _state, label) => label });
  vm.runInContext(ts.transpileModule(source + '\nglobalThis.page = new ProPurchaseSheet();', {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText, context);
  const page = context.page;
  page.aboutToAppear(); assert.equal(page.billingReady, false);
  ready = true; listener(); assert.equal(page.billingReady, true);
  await page.operate('load'); assert.equal(productCalls, 1); assert.equal(page.storePrice, '¥1');
  const product = page.product, generation = page.generation;
  active = true; listener(); assert.equal(page.purchased, true);
  assert.equal(page.product, product); assert.equal(page.storePrice, '¥1'); assert.equal(page.generation, generation);
  ready = false; listener(); assert.equal(page.billingReady, false); assert.equal(page.product, null);
  assert.equal(page.storePrice, ''); assert.ok(page.generation > generation);
  page.aboutToDisappear();
});
