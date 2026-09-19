import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { ProHttpApi, proFailureDiagnostic, startProReconciliationWorker } from '../../server/pro-entitlement/http-api.mjs';
import { createProNodeListener } from '../../server/pro-entitlement/node-listener.mjs';

const challenge = Buffer.alloc(32, 7).toString('base64url');
function fixture(maximum = 4) {
  const calls = [];
  const service = {
    async createIntent(owner) { calls.push(['intent', owner]); return { developerPayload: 'test-intent' }; },
    async reconcile(owner, records, signal, nonce) { calls.push(['reconcile', owner, records, signal, nonce]); return { signedEntitlement: 'test-only-http-contract' }; },
    async notification(jws) { calls.push(['notification', jws]); },
    async reconcileDue() { calls.push(['worker']); }
  };
  const accounts = { async owner(token) {
    calls.push(['identity', token]);
    if (token !== 'test-user-token') throw new Error('account_verification_failed');
    return 'verified-account';
  } };
  const api = new ProHttpApi(service, accounts, maximum);
  return { api, accounts, service, calls };
}
function request(path, body = {}, headers = {}, options = {}) {
  return new Request('https://pro.example.test' + path, { method: 'POST', headers: {
    'Content-Type': 'application/json; charset=utf-8', Authorization: 'Bearer test-user-token', ...headers
  }, body: JSON.stringify(body), ...options });
}
test('only a vendor-verified account owns a purchase intent; body and proxy owner injection cannot grant', async () => {
  const f = fixture();
  const response = await f.api.handle(request('/v1/pro/intents', {}, { 'X-Owner': 'attacker', 'X-Union-ID': 'attacker' }));
  assert.equal(response.status, 200); assert.deepEqual(f.calls.at(-1), ['intent', 'verified-account']);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  const invalid = await f.api.handle(request('/v1/pro/intents', { owner: 'attacker' }));
  assert.equal(invalid.status, 400); assert.equal(f.calls.filter(call => call[0] === 'intent').length, 1);
});
test('missing, wrong and comma-joined credentials never reach fulfillment', async () => {
  const f = fixture();
  for (const Authorization of ['', 'Bearer wrong-user', 'Bearer one, Bearer two']) {
    assert.equal((await f.api.handle(request('/v1/pro/intents', {}, { Authorization }))).status, 401);
  }
  assert.equal(f.calls.some(call => call[0] === 'intent'), false);
});
test('restoration forwards raw references and cancellation only to the trusted service', async () => {
  const f = fixture(); const controller = new AbortController();
  const response = await f.api.handle(request('/v1/pro/reconcile', { purchaseDataList: ['untrusted-reference'], challenge }, {}, { signal: controller.signal }));
  assert.equal(response.status, 200); assert.deepEqual(f.calls.at(-1).slice(0, 3), ['reconcile', 'verified-account', ['untrusted-reference']]);
  assert.equal(f.calls.at(-1)[3].aborted, false); assert.equal(f.calls.at(-1)[4], challenge);
  for (const body of [{}, { purchaseDataList: [], challenge: '' }, { purchaseDataList: [], challenge: 'x'.repeat(43) },
    { purchaseDataList: [], challenge: challenge + '=' }, { purchaseDataList: [], challenge, owner: 'injected' }, { purchaseDataList: 'wrong', challenge }, { purchaseDataList: [7] }, { purchaseDataList: Array(33).fill('r') }]) {
    assert.equal((await f.api.handle(request('/v1/pro/reconcile', body))).status, 400);
  }
});
test('signed notification is acknowledged empty only after persistent handling completes', async () => {
  const f = fixture(); let finish; let completed = false;
  f.service.notification = () => new Promise(resolve => { finish = resolve; });
  const response = f.api.handle(request('/v1/iap/notifications', { jwsNotification: 'test-jws' }, { Authorization: '' }))
    .then(result => { completed = true; return result; });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(completed, false); assert.equal(f.calls.length, 0);
  finish(); const result = await response; assert.equal(result.status, 200); assert.equal(await result.text(), '');
  f.service.notification = async () => { throw new Error('simulated_private_vendor_body'); };
  const failure = await f.api.handle(request('/v1/iap/notifications', { jwsNotification: 'test-jws' }));
  assert.equal(failure.status, 503); assert.equal((await failure.text()).includes('private'), false);
});
test('streaming and declared body limits reject before identity and order queries', async () => {
  const f = fixture();
  const tooLarge = request('/v1/pro/intents', {}, { 'content-length': String(1024 * 1024 + 1) });
  assert.equal((await f.api.handle(tooLarge)).status, 413);
  const streaming = new ReadableStream({ start(controller) {
    controller.enqueue(new Uint8Array(600000)); controller.enqueue(new Uint8Array(600000)); controller.close();
  } });
  const result = await f.api.handle(request('/v1/pro/intents', {}, {}, { body: streaming, duplex: 'half' }));
  assert.equal(result.status, 413); assert.deepEqual(f.calls, []);
});
test('invalid UTF-8, JSON shape, MIME and content encoding are not treated as purchases', async () => {
  const f = fixture();
  for (const body of [new Uint8Array([0xff]), '[]', 'null', '{']) {
    assert.equal((await f.api.handle(request('/v1/pro/intents', {}, {}, { body }))).status, 400);
  }
  assert.equal((await f.api.handle(request('/v1/pro/intents', {}, { 'content-type': 'text/plain' }))).status, 415);
  assert.equal((await f.api.handle(request('/v1/pro/intents', {}, { 'content-encoding': 'gzip' }))).status, 415);
  assert.deepEqual(f.calls, []);
});
test('bounded admission, cancellation and failures release the HTTP slot', async () => {
  const f = fixture(1); let release;
  f.accounts.owner = () => new Promise(resolve => { release = resolve; });
  const controller = new AbortController();
  const pending = f.api.handle(request('/v1/pro/intents', {}, {}, { signal: controller.signal }));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal((await f.api.handle(request('/v1/pro/intents'))).status, 503);
  controller.abort(); release('verified-account');
  assert.equal((await pending).status, 503); assert.equal(f.calls.some(call => call[0] === 'intent'), false);
  f.accounts.owner = async () => 'verified-account';
  assert.equal((await f.api.handle(request('/v1/pro/intents'))).status, 200);
});
test('worker admits one reconciliation and graceful stop waits for it without starting another', async () => {
  const f = fixture(); let complete; let calls = 0;
  f.service.reconcileDue = () => { calls++; return new Promise(resolve => { complete = resolve; }); };
  const worker = startProReconciliationWorker(f.service, 1000);
  await new Promise(resolve => setImmediate(resolve)); worker.tick(); worker.tick(); assert.equal(calls, 1);
  let stopped = false; const stop = worker.stop().then(() => { stopped = true; });
  await new Promise(resolve => setImmediate(resolve)); assert.equal(stopped, false);
  complete(); await stop; worker.tick(); await new Promise(resolve => setImmediate(resolve)); assert.equal(calls, 1);
});
test('real loopback HTTP listener enforces routes and returns no grant for cross-account conflict', async t => {
  const f = fixture(); const server = createProNodeListener(f.api);
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  const base = 'http://127.0.0.1:' + server.address().port;
  assert.equal((await fetch(base + '/healthz')).status, 200);
  assert.equal((await fetch(base + '/v1/pro/intents')).status, 405);
  assert.equal((await fetch(base + '/unknown')).status, 404);
  const options = { method: 'POST', headers: { Authorization: 'Bearer test-user-token', 'Content-Type': 'application/json' }, body: '{}' };
  assert.equal((await fetch(base + '/v1/pro/intents', options)).status, 200);
  assert.equal((await fetch(base + '/v1/pro/intents', { ...options, headers: { ...options.headers, Origin: 'https://untrusted.example' } })).status, 403);
  f.service.reconcile = async () => { throw new Error('order_belongs_to_another_account'); };
  const conflict = await fetch(base + '/v1/pro/reconcile', { ...options, body: JSON.stringify({ purchaseDataList: [], challenge }) });
  assert.equal(conflict.status, 409); assert.deepEqual(await conflict.json(), { error: 'purchase_binding_rejected' });
});


test('deployment diagnostics allow only fixed categories and numeric vendor codes; response remains private', async () => {
  const sensitive = 'private-token-order-and-account';
  for (const error of [new Error(sensitive), new Error('iap_request_failed', { cause: sensitive }),
    new Error('iap_request_failed', { cause: { token: sensitive } }), new Error('invalid_jws', { cause: '1234' })]) {
    assert.equal(JSON.stringify(proFailureDiagnostic(error)).includes(sensitive), false);
    assert.equal(proFailureDiagnostic(error).vendorCode, undefined);
  }
  assert.deepEqual(proFailureDiagnostic(new Error('iap_request_failed', { cause: '100123' })),
    { code: 'iap_request_failed', vendorCode: '100123' });
  const f = fixture(); const messages = [];
  f.service.reconcile = async () => { throw new Error('invalid_iap_certificate', { cause: sensitive }); };
  const api = new ProHttpApi(f.service, f.accounts, 4, value => { messages.push(value); throw new Error('logger failed'); });
  const reply = await api.handle(request('/v1/pro/reconcile', { purchaseDataList: ['private-receipt'], challenge }));
  assert.equal(reply.status, 503); assert.deepEqual(await reply.json(), { error: 'verification_unavailable' });
  assert.deepEqual(messages, [{ code: 'invalid_iap_certificate' }]);
  f.service.reconcile = async () => ({});
  assert.equal((await api.handle(request('/v1/pro/reconcile', { purchaseDataList: [], challenge }))).status, 200);
});

test('PKIX diagnostics retain only bounded stage and numeric verification errors', () => {
  assert.deepEqual(proFailureDiagnostic(new Error('iap_verification_failed', { cause:
    { stage: 4, reason: 'secret-subject', opensslError: 3, stderr: 'private certificate' } })),
    { code: 'iap_verification_failed', cryptoStage: 4, reason: 'unclassified', opensslError: 3 });
  for (const stage of [-1, 5, '3', NaN]) {
    assert.deepEqual(proFailureDiagnostic(new Error('iap_verification_failed', { cause: { stage } })),
      { code: 'iap_verification_failed' });
  }
  for (const opensslError of [-1, 1000, 'private-token', NaN]) {
    assert.equal(proFailureDiagnostic(new Error('iap_verification_failed', { cause:
      { stage: 3, reason: 'iap_crl_download_failed', opensslError } })).opensslError, undefined);
  }
});
