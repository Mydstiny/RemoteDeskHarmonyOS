import { boundedString, jsonBytes, MAX_JWS_BYTES } from './iap-crypto.mjs';

const MAX_BODY = 1024 * 1024;
const JSON_TYPE = /^application\/json(?:\s*;\s*charset=utf-8)?$/i;
class HttpFailure extends Error {
  constructor(status, code) { super(code); this.status = status; }
}
function response(status, value) {
  return new Response(value === undefined ? null : JSON.stringify(value), { status, headers: {
    'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff', ...(status === 503 ? { 'Retry-After': '30' } : {})
  } });
}
async function requestBody(request, maximum = MAX_BODY) {
  if (!JSON_TYPE.test(request.headers.get('content-type') || '') || request.headers.has('content-encoding')) {
    throw new HttpFailure(415, 'json_required');
  }
  const length = request.headers.get('content-length');
  if (length !== null && (!/^\d+$/.test(length) || Number(length) > maximum)) throw new HttpFailure(413, 'request_too_large');
  if (!request.body) throw new HttpFailure(400, 'invalid_request');
  const reader = request.body.getReader(); const chunks = []; let size = 0;
  const abort = () => { void reader.cancel().catch(() => {}); };
  request.signal.addEventListener('abort', abort, { once: true });
  try {
    for (;;) {
      if (request.signal.aborted) throw new HttpFailure(503, 'request_cancelled');
      const part = await reader.read(); if (part.done) break;
      size += part.value.byteLength;
      if (size > maximum) throw new HttpFailure(413, 'request_too_large');
      chunks.push(Buffer.from(part.value));
    }
    if (request.signal.aborted) throw new HttpFailure(503, 'request_cancelled');
    try { return jsonBytes(Buffer.concat(chunks)); }
    catch { throw new HttpFailure(400, 'invalid_request'); }
  } finally {
    request.signal.removeEventListener('abort', abort);
    await reader.cancel().catch(() => {}); reader.releaseLock();
  }
}
function onlyKeys(body, allowed) {
  if (Object.keys(body).some(key => !allowed.includes(key))) throw new HttpFailure(400, 'invalid_request');
}
// Only fixed, non-identifying categories reach the deployment logger.
const DIAGNOSTIC_CODES = new Set(['invalid_purchase_data', 'invalid_jws', 'invalid_base64', 'invalid_json',
  'invalid_object', 'invalid_string', 'vendor_request_failed', 'iap_request_failed', 'invalid_iap_header',
  'invalid_iap_certificate', 'iap_verification_failed', 'order_scope_or_freshness_invalid',
  'invalid_finish_status', 'invalid_finish_requirement', 'invalid_revocation', 'purchase_not_completed',
  'purchase_intent_not_found', 'order_belongs_to_another_account', 'order_binding_mismatch',
  'purchase_token_already_bound', 'ledger_integrity_error', 'ledger_transaction_conflict',
  'ledger_configuration_mismatch', 'stale_order_response', 'verification_busy']);
export function proFailureDiagnostic(error) {
  const code = DIAGNOSTIC_CODES.has(error?.message) ? error.message : 'unclassified';
  const vendorCode = code === 'iap_request_failed' && typeof error?.cause === 'string' &&
    /^[0-9]{1,12}$/.test(error.cause) ? error.cause : undefined;
  if (code === 'iap_verification_failed' && Number.isInteger(error?.cause?.stage) &&
      error.cause.stage >= 0 && error.cause.stage <= 4) {
    const reason = ['invalid_iap_signature', 'iap_crl_distribution_required', 'iap_crl_distribution_unsupported',
      'iap_crl_download_failed', 'iap_crls_required', 'invalid_certificate', 'ENOENT', 'EACCES'].includes(error.cause.reason)
      ? error.cause.reason : 'unclassified';
    const opensslError = error.cause.opensslError;
    // These are public PKI addresses from a pinned, verified certificate, not
    // order fields. Restrict logging to bounded Huawei URLs and safe ASCII.
    const points = error.cause.distributionPoints;
    const distributionPoints = reason === 'iap_crl_distribution_unsupported' && Array.isArray(points) ?
      points.filter(value => typeof value === 'string' && value.length <= 256 &&
        /^https?:\/\/[a-z0-9.-]+\.huawei\.com\/[A-Za-z0-9_./?=&%-]+$/.test(value)).slice(0,8) : [];

    return { code, cryptoStage: error.cause.stage, reason,
      ...(Number.isInteger(opensslError) && opensslError >= 0 && opensslError <= 999 ? { opensslError } : {}),
      ...(distributionPoints.length ? { distributionPoints } : {}) };
  }
  return vendorCode === undefined ? { code } : { code, vendorCode };
}
function failure(error) {
  if (error instanceof HttpFailure) return response(error.status, { error: error.message });
  if (error?.message === 'account_verification_failed') return response(401, { error: 'account_login_required' });
  if (['order_belongs_to_another_account', 'order_binding_mismatch', 'purchase_token_already_bound',
    'purchase_intent_not_found'].includes(error?.message)) return response(409, { error: 'purchase_binding_rejected' });
  if (error?.message === 'too_many_pending_purchases') return response(429, { error: 'purchase_retry_later' });
  // Never reflect a vendor response, token, signed purchase or exception text.
  return response(503, { error: 'verification_unavailable' });
}

// Standard Request/Response adapter can be used by the local Node listener or
// by a managed-function adapter. Account ownership always comes from Huawei.
export class ProHttpApi {
  #service;
  #accounts;
  #active = 0;
  #maximum;
  #diagnostic;
  constructor(service, accounts, maximumConcurrent = 4, diagnostic = () => {}) {
    if (!Number.isInteger(maximumConcurrent) || maximumConcurrent < 1 || maximumConcurrent > 16) throw new Error('invalid_concurrency');
    this.#service = service; this.#accounts = accounts; this.#maximum = maximumConcurrent; this.#diagnostic = diagnostic;
  }
  async handle(request) {
    const url = new URL(request.url);
    if (url.search || url.hash) return response(404, { error: 'not_found' });
    if (request.method === 'GET' && url.pathname === '/healthz') return response(200, { status: 'running' });
    if (!['/v1/pro/session', '/v1/pro/intents', '/v1/pro/reconcile', '/v1/iap/notifications'].includes(url.pathname)) {
      return response(404, { error: 'not_found' });
    }
    if (request.method !== 'POST') return response(405, { error: 'post_required' });
    if (request.headers.has('origin')) return response(403, { error: 'browser_origin_denied' });
    if (this.#active >= this.#maximum) return response(503, { error: 'service_busy' });
    this.#active++;
    try {
      const body = await requestBody(request, url.pathname === '/v1/pro/session' ? 16384 : MAX_BODY);
      if (url.pathname === '/v1/pro/session') {
        onlyKeys(body, ['authorizationCode', 'challenge']);
        try { boundedString(body.authorizationCode, 8192); }
        catch { throw new HttpFailure(400, 'invalid_request'); }
        if (typeof body.challenge !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(body.challenge) ||
          Buffer.from(body.challenge, 'base64url').toString('base64url') !== body.challenge) {
          throw new HttpFailure(400, 'invalid_request');
        }
        if (typeof this.#accounts.issue !== 'function') throw new HttpFailure(503, 'verification_unavailable');
        return response(200, await this.#accounts.issue(body.authorizationCode, body.challenge, request.signal));
      }
      if (url.pathname === '/v1/iap/notifications') {
        onlyKeys(body, ['jwsNotification']);
        try { boundedString(body.jwsNotification, MAX_JWS_BYTES); }
        catch { throw new HttpFailure(400, 'invalid_request'); }
        await this.#service.notification(body.jwsNotification);
        // Huawei requires HTTP 200 with an empty body after durable handling.
        return response(200);
      }
      const authorization = request.headers.get('authorization') || '';
      if (!/^Bearer [^\s,\u0000-\u001f\u007f]{1,16384}$/.test(authorization)) throw new HttpFailure(401, 'account_login_required');
      const owner = await this.#accounts.owner(authorization.slice(7));
      if (request.signal.aborted) throw new HttpFailure(503, 'request_cancelled');
      if (url.pathname === '/v1/pro/intents') {
        onlyKeys(body, []);
        return response(200, await this.#service.createIntent(owner));
      }
      onlyKeys(body, ['purchaseDataList', 'challenge']);
      if (typeof body.challenge !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(body.challenge) ||
          Buffer.from(body.challenge, 'base64url').toString('base64url') !== body.challenge ||
          !Array.isArray(body.purchaseDataList) || body.purchaseDataList.length > 32 ||
          body.purchaseDataList.some(record => typeof record !== 'string' || record.length > MAX_JWS_BYTES + 1024)) {
        throw new HttpFailure(400, 'invalid_request');
      }
      return response(200, await this.#service.reconcile(owner, body.purchaseDataList, request.signal, body.challenge));
    } catch (error) {
      try { this.#diagnostic(proFailureDiagnostic(error)); } catch { /* logging cannot affect verification */ }
      return failure(error);
    }
    finally { this.#active--; }
  }
}

export function startProReconciliationWorker(service, intervalMs = 30000) {
  if (!Number.isSafeInteger(intervalMs) || intervalMs < 1000) throw new Error('invalid_worker_interval');
  let running = null; let stopped = false;
  const tick = () => {
    if (stopped || running !== null) return;
    running = Promise.resolve().then(() => service.reconcileDue()).catch(() => {}).finally(() => { running = null; });
  };
  const timer = setInterval(tick, intervalMs); timer.unref?.(); tick();
  return { tick, async stop() { stopped = true; clearInterval(timer); if (running !== null) await running; } };
}
