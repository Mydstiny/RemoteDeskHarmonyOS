import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac, randomBytes } from 'node:crypto';
import { HuaweiAuthorizationCodeVerifier, ownerForUnionId } from '../../server/pro-entitlement/huawei-api.mjs';
import { ProSessionService } from '../../server/pro-entitlement/session.mjs';
import { ProHttpApi } from '../../server/pro-entitlement/http-api.mjs';

const challenge = randomBytes(32).toString('base64url');
const owner = ownerForUnionId('test-union');
const configuration = { applicationId: 'test-app', issuer: 'test-issuer', environment: 'SANDBOX' };
function fixture() {
  const state = { now: 1788753534000, calls: [], used: new Set(), token: {}, identity: {}, exchange: null };
  const fetcher = async (url, options) => {
    state.calls.push({ url, options }); options.signal.throwIfAborted();
    assert.equal(options.redirect, 'error');
    const input = new URLSearchParams(options.body);
    if (url === 'https://oauth-login.cloud.huawei.com/oauth2/v3/token') {
      assert.deepEqual([...input.keys()].sort(), ['client_id', 'client_secret', 'code', 'grant_type']);
      assert.equal(input.get('client_id'), 'test-client'); assert.equal(input.get('client_secret'), 'private-server-secret');
      assert.equal(input.get('grant_type'), 'authorization_code');
      if (state.exchange) return state.exchange(options);
      if (state.used.has(input.get('code'))) return new Response('{"error":"invalid_grant"}', { status: 400 });
      state.used.add(input.get('code'));
      return Response.json({ access_token: 'private-vendor-token', refresh_token: 'private-refresh-token',
        expires_in: 3600, token_type: 'Bearer', ...state.token });
    }
    assert.equal(url, 'https://oauth-api.cloud.huawei.com/rest.php?nsp_fmt=JSON&nsp_svc=huawei.oauth2.user.getTokenInfo');
    assert.equal(input.get('access_token'), 'private-vendor-token');
    return Response.json({ client_id: 'test-client', type: 0, expire_in: 3600, union_id: 'test-union', open_id: 'test-open', ...state.identity });
  };
  const authorization = new HuaweiAuthorizationCodeVerifier('test-client', 'private-server-secret', fetcher);
  const key = randomBytes(32); const sessions = new ProSessionService(configuration, authorization, key, () => state.now);
  const service = { async createIntent(owner) { return { verifiedOwner: owner }; } };
  const api = new ProHttpApi(service, sessions);
  const request = (path, body, token = '') => new Request('https://example.test' + path, { method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) }, body: JSON.stringify(body) });
  return { state, key, sessions, api, request, authorization };
}
function sign(key, header, payload) {
  const input = Buffer.from(JSON.stringify(header)).toString('base64url') + '.' + Buffer.from(JSON.stringify(payload)).toString('base64url');
  return input + '.' + createHmac('sha256', key).update(input).digest('base64url');
}
test('native code exchanges only at Huawei and returns a bounded Pro session without vendor secrets', async () => {
  const f = fixture();
  const response = await f.api.handle(f.request('/v1/pro/session', { authorizationCode: 'fresh-code', challenge }));
  assert.equal(response.status, 200); assert.equal(response.headers.get('cache-control'), 'no-store');
  const text = await response.text(); const result = JSON.parse(text);
  assert.equal(text.includes('private-'), false); assert.equal(result.challenge, challenge);
  assert.equal(result.owner, owner); assert.equal(result.expiresAt, f.state.now + 600000);
  assert.equal(await f.sessions.owner(result.sessionToken), owner);
  assert.equal(f.state.calls.length, 2);
  const intent = await f.api.handle(f.request('/v1/pro/intents', {}, result.sessionToken));
  assert.equal(intent.status, 200); assert.equal((await intent.json()).verifiedOwner, owner);
  assert.equal((await f.api.handle(f.request('/v1/pro/intents', {}, 'private-vendor-token'))).status, 401);
  assert.equal((await f.api.handle(f.request('/v1/pro/session', { authorizationCode: 'fresh-code', challenge }))).status, 503);
});
test('public session route rejects owner injection, malformed codes/nonces and oversized bodies before OAuth', async () => {
  const f = fixture();
  for (const body of [{}, { authorizationCode: 'code', challenge, owner }, { authorizationCode: '', challenge },
    { authorizationCode: 'code\n', challenge }, { authorizationCode: 'code', challenge: 'x'.repeat(43) },
    { authorizationCode: 'code', challenge: challenge + '=' }, { authorizationCode: 42, challenge }]) {
    assert.equal((await f.api.handle(f.request('/v1/pro/session', body))).status, 400);
  }
  assert.equal((await f.api.handle(f.request('/v1/pro/session', { authorizationCode: 'x'.repeat(17000), challenge }))).status, 413);
  assert.equal(f.state.calls.length, 0);
});
test('wrong client, application credentials, expiry and malformed token exchange never produce a session', async () => {
  for (const identity of [{ client_id: 'other' }, { type: 1 }, { expire_in: 0 }, { union_id: '' }, { open_id: '' }]) {
    const f = fixture(); f.state.identity = identity;
    await assert.rejects(() => f.sessions.issue('code', challenge), /account_verification_failed/);
  }
  for (const token of [{ token_type: 'Basic' }, { expires_in: 0 }, { expires_in: '3600' }, { access_token: '' }, { error: 'invalid' }]) {
    const f = fixture(); f.state.token = token;
    await assert.rejects(() => f.sessions.issue('code', challenge), /account_verification_failed/);
    assert.equal(f.state.calls.length, 1);
  }
});
test('session HMAC, type, audience and environment reject token and entitlement substitution', async () => {
  const f = fixture(); const result = await f.sessions.issue('code', challenge);
  const [head, body, signature] = result.sessionToken.split('.'); const payload = JSON.parse(Buffer.from(body, 'base64url'));
  const header = JSON.parse(Buffer.from(head, 'base64url'));
  for (const token of [head + '.' + body + '.' + (signature[0] === 'A' ? 'B' : 'A') + signature.slice(1),
    result.sessionToken + '=', sign(f.key, { ...header, typ: 'JWT' }, payload), sign(f.key, { ...header, alg: 'RS256' }, payload),
    sign(f.key, { ...header, kid: 'other' }, payload), sign(f.key, header, { ...payload, aud: 'other' }),
    sign(f.key, header, { ...payload, env: 'NORMAL' }), sign(f.key, header, { ...payload, iss: 'other' }),
    sign(f.key, header, { ...payload, role: 'admin' })]) {
    await assert.rejects(() => f.sessions.owner(token), /account_verification_failed/);
  }
  const otherKey = new ProSessionService(configuration, f.authorization, randomBytes(32), () => f.state.now);
  await assert.rejects(() => otherKey.owner(result.sessionToken), /account_verification_failed/);
  const otherEnvironment = new ProSessionService({ ...configuration, environment: 'NORMAL' }, f.authorization, f.key, () => f.state.now);
  await assert.rejects(() => otherEnvironment.owner(result.sessionToken), /account_verification_failed/);
});
test('expiry, future issue time, lifetime changes and a bad server clock fail closed', async () => {
  const f = fixture(); const result = await f.sessions.issue('code', challenge);
  f.state.now += 599999; assert.equal(await f.sessions.owner(result.sessionToken), owner);
  f.state.now++; await assert.rejects(() => f.sessions.owner(result.sessionToken), /account_verification_failed/);
  const [head, body] = result.sessionToken.split('.'); const payload = JSON.parse(Buffer.from(body, 'base64url'));
  const header = JSON.parse(Buffer.from(head, 'base64url'));
  for (const changes of [{ iat: payload.iat + 1200, exp: payload.exp + 1200 }, { exp: payload.exp + 3600 }, { iat: '123' }]) {
    await assert.rejects(() => f.sessions.owner(sign(f.key, header, { ...payload, ...changes })), /account_verification_failed/);
  }
  f.state.now = Number.NaN; await assert.rejects(() => f.sessions.issue('new-code', challenge), /account_verification_failed/);
});
test('cancellation during native code exchange aborts the vendor fetch and cannot issue a late session', async () => {
  const f = fixture(); let entered; let complete;
  const started = new Promise(resolve => { entered = resolve; });
  f.state.exchange = options => new Promise(resolve => {
    complete = () => { assert.equal(options.signal.aborted, true); resolve(Response.json({ access_token: 'late-private-token',
      token_type: 'Bearer', expires_in: 3600 })); }; entered();
  });
  const controller = new AbortController(); const pending = f.sessions.issue('code', challenge, controller.signal);
  await started; controller.abort(); complete(); await assert.rejects(() => pending, /account_verification_failed/);
  assert.equal(f.state.calls.length, 1);
});
