const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const path = require('node:path');
const { test } = require('node:test');
const { proClientHost, base, sessionReply } = require('./helpers/pro_client_host.cjs');
const owner = 'owner-' + crypto.createHash('sha256').update('RemoteDeskHarmonyOS:owner:v1:test-union').digest('hex');
const other = 'owner-' + 'b'.repeat(64);
const configuration = { trust: {}, sessionUrl: 'https://test.example/v1/pro/session',
  intentsUrl: 'https://test.example/v1/pro/intents', reconcileUrl: 'https://test.example/v1/pro/reconcile' };
async function fixture(t) {
  const scope = { kind: 'huawei_account', ownerScopeId: owner, generation: 1, sessionState: 'ready' };
  const auth = { getUnionID: () => 'test-union', isAuthorized: () => true,
    getAccessToken: () => assert.fail('existing token field is not request authentication') };
  const f = proClientHost({ mocks: {
    [path.resolve(base, '../AccountKitService.ets')]: { AccountKitService: { getInstance: () => auth } },
    [path.resolve(base, '../AccountSessionCoordinator.ets')]: { AccountSessionCoordinator: { getInstance: () => ({ currentScope: () => scope }) } }
  } });
  t.after(() => f.close());
  const { ProSessionService } = await import('../../server/pro-entitlement/session.mjs');
  const { ProHttpApi } = await import('../../server/pro-entitlement/http-api.mjs');
  const exchanges = []; let api;
  const rotate = () => {
    const sessions = new ProSessionService({ applicationId: 'test-app', issuer: 'test-issuer', environment: 'SANDBOX' },
      { async exchange(code) { exchanges.push(code); return owner; } }, crypto.randomBytes(32), () => f.state.now);
    api = new ProHttpApi({ async createIntent(account) { assert.equal(account, owner); return { intent: 'server-confirmed-owner' }; } }, sessions);
  };
  rotate();
  f.state.onHttp = async call => {
    const result = await api.handle(new Request(call.url, { method: 'POST', headers: call.configuration.header,
      body: call.configuration.extraData }));
    return { responseCode: result.status, result: await result.text() };
  };
  const { ProHttpTransport } = f.load('ProHttpTransport'); const transport = new ProHttpTransport(configuration, {});
  return { ...f, scope, auth, exchanges, rotate, transport, post: () => transport.post('intents', '{}', () => true) };
}
test('native authorization and real server session authenticate requests without using the old token field', async t => {
  const f = await fixture(t); assert.equal(JSON.parse(await f.post()).intent, 'server-confirmed-owner');
  const native = f.state.nativeRequests[0]; assert.equal(native.forceAuthorization, false);
  assert.deepEqual([...native.scopes], ['openid']); assert.deepEqual([...native.permissions], ['serviceauthcode']);
  assert.equal(native.state.length, 43); assert.equal(f.exchanges.length, 1);
  assert.equal(f.state.requests[0].configuration.header.Authorization, undefined);
  const body = JSON.parse(f.state.requests[0].configuration.extraData);
  assert.deepEqual(Object.keys(body).sort(), ['authorizationCode', 'challenge']); assert.equal(body.challenge, native.state);
  assert.match(f.state.requests[1].configuration.header.Authorization, /^Bearer /);
  assert.equal(JSON.parse(await f.post()).intent, 'server-confirmed-owner'); assert.equal(f.exchanges.length, 1);
  assert.equal(f.state.nativeRequests.length, 1);
  for (const call of f.state.requests) {
    assert.equal(call.configuration.remoteValidation, 'system'); assert.equal(call.configuration.maxRedirects, 0);
    assert.equal(call.request.destroyed, 1);
  }
});
test('concurrent requests share one native code exchange and keep independent authenticated operations', async t => {
  const f = await fixture(t); const results = await Promise.all([f.post(), f.post(), f.post()]);
  assert.equal(results.length, 3); assert.equal(f.state.nativeRequests.length, 1); assert.equal(f.exchanges.length, 1);
  assert.equal(f.state.requests.filter(call => call.url.endsWith('/intents')).length, 3);
});
test('elapsed expiry and clock rollback discard the cached session and acquire fresh native codes', async t => {
  const f = await fixture(t); await f.post();
  f.state.uptime += 570000; await f.post(); assert.equal(f.exchanges.length, 2);
  f.state.now -= 1; await f.post(); assert.equal(f.exchanges.length, 3);
  f.state.now += 600000; f.state.uptime += 600000; await f.post(); assert.equal(f.exchanges.length, 4);
  assert.equal(new Set(f.exchanges).size, 4);
});
test('a server key rotation renews the session once after 401 and repeated 401 stops after one retry', async t => {
  const f = await fixture(t); await f.post(); f.rotate();
  assert.equal(JSON.parse(await f.post()).intent, 'server-confirmed-owner'); assert.equal(f.exchanges.length, 2);
  const original = f.state.onHttp; let rejected = 0;
  f.state.onHttp = call => call.url.endsWith('/intents') ?
    (rejected++, Promise.resolve({ responseCode: 401, result: '{}' })) : original(call);
  await assert.rejects(() => f.post()); assert.equal(rejected, 2); assert.equal(f.exchanges.length, 3);
});
test('native state/UnionID mismatch and malformed authorization codes never reach the backend', async t => {
  for (const change of ['state', 'union', 'empty', 'oversized', 'control']) {
    const f = await fixture(t);
    f.state.onAuthorization = async request => ({ state: change === 'state' ? 'wrong' : request.state,
      data: { unionID: change === 'union' ? 'other' : 'test-union',
        authorizationCode: change === 'empty' ? '' : change === 'oversized' ? '汉'.repeat(3000) : change === 'control' ? 'code\n' : 'code' } });
    await assert.rejects(() => f.post()); assert.equal(f.state.requests.length, 0);
  }
});
test('account changes or a transport cancel while native authorization waits cannot send the old code', async t => {
  for (const change of ['account', 'cancel']) {
    const f = await fixture(t); let arrived; let complete;
    const started = new Promise(resolve => { arrived = resolve; });
    f.state.onAuthorization = request => new Promise(resolve => {
      complete = () => resolve({ state: request.state, data: { unionID: 'test-union', authorizationCode: 'late-code' } }); arrived();
    });
    const request = f.post(); await started;
    if (change === 'account') { f.scope.ownerScopeId = other; f.scope.generation++; } else f.transport.cancel();
    complete(); await assert.rejects(() => request); assert.equal(f.state.requests.length, 0);
  }
});
test('native timeout does not exchange a delayed code or block the next attempt', async t => {
  const f = await fixture(t); let arrived; let complete;
  const started = new Promise(resolve => { arrived = resolve; });
  f.state.onAuthorization = request => new Promise(resolve => {
    complete = () => resolve({ state: request.state, data: { unionID: 'test-union', authorizationCode: 'late-code' } }); arrived();
  });
  const request = f.post(); await started;
  const timer = [...f.state.timers.values()].find(value => value.delay === 10000); assert.ok(timer); timer.callback();
  await assert.rejects(() => request); complete(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.state.requests.length, 0);
  f.state.onAuthorization = async request => ({ state: request.state, data: { unionID: 'test-union', authorizationCode: 'fresh-code' } });
  assert.equal(JSON.parse(await f.post()).intent, 'server-confirmed-owner');
});
test('session reply owner, challenge, shape and lifetime mismatches cannot authorize a purchase intent', async t => {
  for (const change of ['owner', 'challenge', 'expired', 'long', 'format', 'extra']) {
    const f = await fixture(t);
    f.state.onHttp = async call => {
      assert.ok(call.url.endsWith('/session'));
      const reply = sessionReply(JSON.parse(call.configuration.extraData), owner, f.state.now);
      if (change === 'owner') reply.owner = other;
      if (change === 'challenge') reply.challenge = crypto.randomBytes(32).toString('base64url');
      if (change === 'expired') reply.expiresAt = f.state.now;
      if (change === 'long') reply.expiresAt = f.state.now + 86400000;
      if (change === 'format') reply.sessionToken = 'old-open-id';
      if (change === 'extra') reply.accessToken = 'unexpected-vendor-token';
      return { responseCode: 200, result: JSON.stringify(reply) };
    };
    await assert.rejects(() => f.post()); assert.equal(f.state.requests.length, 1);
  }
});
test('cancelling an in-flight authenticated request rejects a late response and clears the session', async t => {
  const f = await fixture(t); await f.post(); const original = f.state.onHttp;
  let complete; let entered; const started = new Promise(resolve => { entered = resolve; });
  f.state.onHttp = () => new Promise(resolve => { complete = () => resolve({ responseCode: 200, result: '{}' }); entered(); });
  const request = f.post(); await started; f.transport.cancel(); complete(); await assert.rejects(() => request);
  f.state.onHttp = original; await f.post(); assert.equal(f.exchanges.length, 2);
});
