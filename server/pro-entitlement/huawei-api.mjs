import { createHash } from 'node:crypto';
import { boundedString, fail, iapAuthorization, jsonBytes, jwsParts, object, MAX_JWS_BYTES } from './iap-crypto.mjs';

const IAP_ROOT = 'https://iap.cloud.huawei.com';
const ACCOUNT_URL = 'https://oauth-api.cloud.huawei.com/rest.php?nsp_fmt=JSON&nsp_svc=huawei.oauth2.user.getTokenInfo';
const MAX_RESPONSE = 128 * 1024;
export function ownerForUnionId(unionId) {
  return 'owner-' + createHash('sha256').update('RemoteDeskHarmonyOS:owner:v1:' + boundedString(unionId).trim()).digest('hex');
}
// Fixed vendor destinations, no redirects, no response/error body logging.
export async function vendorPost(url, body, headers, fetcher = fetch) {
  const result = await fetcher(url, { method: 'POST', body, headers, redirect: 'error', signal: AbortSignal.timeout(10000) });
  if (result.status !== 200 || result.headers.get('nsp_status') !== null) fail('vendor_request_failed');
  if (Number(result.headers.get('content-length') || 0) > MAX_RESPONSE || !result.body) fail('vendor_response_invalid');
  const reader = result.body.getReader();
  const chunks = [];
  let length = 0;
  try {
    for (;;) {
      const part = await reader.read();
      if (part.done) break;
      length += part.value.length;
      if (length > MAX_RESPONSE) fail('vendor_response_oversized');
      chunks.push(Buffer.from(part.value));
    }
  } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
  return jsonBytes(Buffer.concat(chunks));
}
export class HuaweiAccountVerifier {
  constructor(clientId, fetcher = fetch) { this.clientId = boundedString(clientId); this.fetcher = fetcher; }
  async owner(accessToken) {
    boundedString(accessToken, 16384);
    const body = new URLSearchParams({ access_token: accessToken, open_id: 'OPENID' }).toString();
    const result = await vendorPost(ACCOUNT_URL, body, { 'Content-Type': 'application/x-www-form-urlencoded' }, this.fetcher);
    if (result.error !== undefined || result.client_id !== this.clientId || result.type !== 0 ||
        !Number.isSafeInteger(result.expire_in) || result.expire_in <= 0 || typeof result.union_id !== 'string' ||
        result.union_id.trim().length === 0 || typeof result.open_id !== 'string' || result.open_id.length === 0) {
      fail('account_verification_failed');
    }
    return ownerForUnionId(result.union_id);
  }
}
// Input is deliberately UNVERIFIED. Only the bounded order reference is used
// to query a fixed Huawei endpoint. No product/owner/grant is accepted from it.
export function orderReferenceFromPurchaseData(record) {
  boundedString(record, MAX_JWS_BYTES + 1024);
  let wrapper;
  try { wrapper = object(JSON.parse(record)); } catch { fail('invalid_purchase_data'); }
  const payload = jwsParts(wrapper.jwsPurchaseOrder).payload;
  return { purchaseOrderId: boundedString(payload.purchaseOrderId), purchaseToken: boundedString(payload.purchaseToken) };
}
export function validateCurrentOrder(payload, reference, configuration, now) {
  object(payload);
  if (payload.applicationId !== configuration.applicationId || payload.productId !== configuration.productId ||
      payload.productType !== '1' || payload.environment !== configuration.environment ||
      payload.purchaseOrderId !== reference.purchaseOrderId || payload.purchaseToken !== reference.purchaseToken ||
      !Number.isSafeInteger(payload.signedTime) || payload.signedTime <= 0 || payload.signedTime > now + 60000 ||
      payload.signedTime < now - 300000) fail('order_scope_or_freshness_invalid');
  if (payload.finishStatus !== undefined && payload.finishStatus !== '1' && payload.finishStatus !== '2') fail('invalid_finish_status');
  if (payload.needFinish !== undefined && typeof payload.needFinish !== 'boolean') fail('invalid_finish_requirement');
  const revoked = payload.revocationTime !== undefined || payload.purchaseOrderRevocationReasonCode !== undefined;
  if (payload.revocationTime !== undefined && (!Number.isSafeInteger(payload.revocationTime) ||
      payload.revocationTime <= 0 || payload.revocationTime > now + 60000)) fail('invalid_revocation');
  if (payload.purchaseOrderRevocationReasonCode !== undefined &&
      !['0', '1'].includes(payload.purchaseOrderRevocationReasonCode)) fail('invalid_revocation');
  if (!revoked && (!Number.isSafeInteger(payload.purchaseTime) || payload.purchaseTime <= 0 ||
      payload.purchaseTime > payload.signedTime + 60000)) fail('purchase_not_completed');
  if (payload.developerPayload !== undefined) boundedString(payload.developerPayload, 256);
  return { ...reference, productId: payload.productId, environment: payload.environment,
    applicationId: payload.applicationId, developerPayload: payload.developerPayload || '',
    signedTime: payload.signedTime, purchaseTime: payload.purchaseTime || 0, revoked,
    needsFinish: !revoked && payload.finishStatus !== '1' && payload.needFinish === true };
}
export class HuaweiIapClient {
  constructor(configuration, verifier, fetcher = fetch, now = Date.now) {
    if (!['NORMAL', 'SANDBOX'].includes(configuration.environment)) fail('invalid_iap_environment');
    boundedString(configuration.applicationId); boundedString(configuration.productId, 128);
    this.configuration = Object.freeze({ ...configuration });
    this.verifier = verifier; this.fetcher = fetcher; this.now = now;
  }
  async post(path, reference) {
    const body = JSON.stringify({ purchaseOrderId: boundedString(reference.purchaseOrderId),
      purchaseToken: boundedString(reference.purchaseToken) });
    const result = await vendorPost(IAP_ROOT + path, body, { 'Content-Type': 'application/json;charset=UTF-8',
      Authorization: 'Bearer ' + iapAuthorization(body, this.configuration, this.now()) }, this.fetcher);
    if (result.responseCode !== '0') fail('iap_request_failed');
    return result;
  }
  async query(reference) {
    const result = await this.post('/order/harmony/v1/application/order/status/query', reference);
    const payload = await this.verifier.verify(result.jwsPurchaseOrder);
    return validateCurrentOrder(payload, reference, this.configuration, this.now());
  }
  // Call only after an atomic persistent grant. A timeout remains pending;
  // retry first queries finishStatus so an acknowledged order is not resent.
  async confirm(reference) {
    await this.post('/order/harmony/v1/application/purchase/shipped/confirm', reference);
  }
  async notification(jws) {
    const payload = await this.verifier.verify(jws);
    const meta = object(payload.notificationMetaData);
    if (meta.environment !== this.configuration.environment || meta.applicationId !== this.configuration.applicationId ||
        meta.type !== 1 || meta.currentProductId !== this.configuration.productId ||
        !Number.isSafeInteger(payload.signedTime) || payload.signedTime > this.now() + 60000 ||
        payload.signedTime <= 0 || payload.signedTime < this.now() - 7 * 86400000) fail('invalid_notification');
    return { id: boundedString(payload.notificationRequestId), reference: {
      purchaseOrderId: boundedString(meta.purchaseOrderId), purchaseToken: boundedString(meta.purchaseToken) } };
  }
}
