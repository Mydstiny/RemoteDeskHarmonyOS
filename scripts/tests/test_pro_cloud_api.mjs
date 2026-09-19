import test from 'node:test';
import assert from 'node:assert/strict';
import { ProCloudApi } from '../../server/pro-entitlement/cloud-api.mjs';
import { ProHttpApi } from '../../server/pro-entitlement/http-api.mjs';

const challenge = Buffer.alloc(32, 9).toString('base64url');
const token = 'eyJ0eXAiOiJKV1QifQ.e30.' + challenge;
const input = (operation = 'intents', body = '{}') => ({ version: 1, operation, body, sessionToken: operation === 'session' ? '' : token });
function fixture() {
  const calls = [];
  const service = { async createIntent(owner) { calls.push(['intent', owner]); return { developerPayload: 'bound' }; },
    async reconcile(owner, records, signal, nonce) { calls.push(['reconcile', owner, records, nonce, signal]); return { signedEntitlement: 'signed' }; },
    async notification() { assert.fail('notification is a separate ingress'); }, async reconcileDue() { assert.fail('worker must be private'); } };
  const accounts = { async issue(code, nonce) { calls.push(['session', code, nonce]); return { sessionToken: token }; },
    async owner(value) { if (value !== token) throw new Error('account_verification_failed'); return 'trusted-owner'; } };
  return { calls, service, api: new ProCloudApi(new ProHttpApi(service, accounts)) };
}
test('AGC JSON, object and base64 event bodies reach the same trusted account service', async () => {
  const f = fixture();
  for (const body of [input(), JSON.stringify(input()), Buffer.from(JSON.stringify(input())).toString('base64')]) {
    const result = await f.api.handle({ httpMethod: 'POST', headers: {}, body,
      isBase64Encoded: typeof body === 'string' && !body.startsWith('{') });
    assert.equal(result.status, 200); assert.equal(result.version, 1); assert.equal(JSON.parse(result.body).developerPayload, 'bound');
    assert.deepEqual(f.calls.at(-1), ['intent', 'trusted-owner']);
  }
  assert.equal((await f.api.handle(input())).status, 200);
});
test('only allowlisted account operations are routable and caller metadata never supplies an owner', async () => {
  const f = fixture();
  const session = await f.api.handle(input('session', JSON.stringify({ authorizationCode: 'native-code', challenge })));
  assert.equal(session.status, 200); assert.deepEqual(f.calls.at(-1), ['session', 'native-code', challenge]);
  const result = await f.api.handle({ httpMethod: 'POST', headers: { 'X-Owner': 'attacker' },
    path: '/worker', body: input('reconcile', JSON.stringify({ purchaseDataList: ['reference'], challenge })) });
  assert.equal(result.status, 200); assert.deepEqual(f.calls.at(-1).slice(0, 4), ['reconcile', 'trusted-owner', ['reference'], challenge]);
  for (const operation of ['notification', 'worker', '../session', '__proto__', ['session']]) {
    assert.equal((await f.api.handle({ ...input(), operation })).status, 400);
  }
  assert.equal((await f.api.handle({ ...input(), owner: 'attacker' })).status, 400);
  assert.equal((await f.api.handle(input('intents', '{"owner":"attacker"}'))).status, 400);
});
test('bad envelopes, browser origins, encoded/compressed data and limits fail before account operations', async () => {
  const f = fixture();
  for (const event of [null, [], '{}', '{', { ...input(), version: 2 }, { ...input(), sessionToken: '' },
    { ...input('session'), sessionToken: token }, { ...input(), body: 'x'.repeat(1048577) },
    { httpMethod: 'GET', body: input() }, { httpMethod: 'POST', body: input(), headers: { Origin: 'https://untrusted.invalid' } },
    { httpMethod: 'POST', body: input(), headers: { 'Content-Encoding': 'gzip' } },
    { httpMethod: 'POST', body: '!!!!', isBase64Encoded: true }, { httpMethod: 'POST', body: input(), isBase64Encoded: 'false' },
    { httpMethod: 'POST', body: '/w==', isBase64Encoded: true }, { httpMethod: 'POST', body: 'x'.repeat(3000000) }]) {
    assert.equal((await f.api.handle(event)).status, 400);
  }
  assert.deepEqual(f.calls, []);
});
test('refund lookup accepts only the authenticated owner and no caller order identifiers', async () => {
  const f = fixture();
  f.service.refundOrder = async owner => { f.calls.push(['refund-route', owner]); return { purchaseOrderId: 'test-order' }; };
  assert.equal((await f.api.handle(input('refund-order'))).status, 200);
  assert.deepEqual(f.calls, [['refund-route', 'trusted-owner']]);
  for (const body of [{ owner: 'attacker' }, { purchaseOrderId: 'foreign-order' }, { purchaseToken: 'foreign-token' }]) {
    assert.equal((await f.api.handle(input('refund-order', JSON.stringify(body)))).status, 400);
  }
  assert.equal((await f.api.handle({ ...input('refund-order'), sessionToken: '' })).status, 400);
  assert.equal((await f.api.handle({ ...input('refund-order'), sessionToken: 'e30.e30.' + 'a'.repeat(43) })).status, 401);
  assert.equal(f.calls.length, 1);
});
test('cloud errors and oversized responses cannot reflect credentials or create a successful grant', async () => {
  const f = fixture();
  f.service.createIntent = async () => { throw new Error('private-token-example'); };
  let response = await f.api.handle(input()); assert.equal(response.status, 503); assert.doesNotMatch(response.body, /private-token/);
  const large = new ProCloudApi({ handle: async () => new Response('x'.repeat(32769), { status: 200 }) });
  response = await large.handle(input()); assert.equal(response.status, 503);
});
