import { jsonBytes, object } from './iap-crypto.mjs';

const MAX_BODY = 1024 * 1024;
const MAX_ENVELOPE = 2 * MAX_BODY + 16384;
const routes = Object.freeze({ session: '/v1/pro/session', intents: '/v1/pro/intents', reconcile: '/v1/pro/reconcile',
  'refund-order': '/v1/pro/refund-order' });
const reply = (status, error) => ({ version: 1, status, body: JSON.stringify({ error }) });

function envelope(event) {
  let value = event;
  // AGC HTTP triggers supply the SDK's data in event.body. Direct objects are
  // also supported by the console test runner; neither form supplies an owner.
  if (event?.httpMethod !== undefined) {
    if (event.httpMethod !== 'POST') throw new Error('invalid_request');
    const headers = Object.entries(object(event.headers || {}));
    if (headers.some(([name]) => ['origin', 'content-encoding'].includes(name.toLowerCase()))) throw new Error('invalid_request');
    if (event.isBase64Encoded !== undefined && typeof event.isBase64Encoded !== 'boolean') throw new Error('invalid_request');
    value = event.body;
    if (event.isBase64Encoded) {
      if (typeof value !== 'string' || value.length > Math.ceil(MAX_ENVELOPE / 3) * 4) throw new Error('invalid_request');
      const decoded = Buffer.from(value, 'base64');
      if (decoded.toString('base64') !== value) throw new Error('invalid_request');
      value = jsonBytes(decoded);
    }
  }
  const bytes = typeof value === 'string' ? Buffer.from(value) : Buffer.from(JSON.stringify(value));
  if (bytes.length > MAX_ENVELOPE) throw new Error('invalid_request');
  value = jsonBytes(bytes);
  if (Object.keys(value).length !== 4 || value.version !== 1 || typeof value.operation !== 'string' || !Object.hasOwn(routes, value.operation) ||
    typeof value.sessionToken !== 'string' || typeof value.body !== 'string' ||
    Buffer.byteLength(value.body) > MAX_BODY || value.sessionToken.length > 4096 ||
    (value.operation === 'session' ? value.sessionToken !== '' : !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{43}$/.test(value.sessionToken))) {
    throw new Error('invalid_request');
  }
  return value;
}

// AGC serializes callback values as the HTTP response body. Keep business
// status inside a bounded, versioned envelope for Cloud Foundation clients.
// Notifications and the independent delivery worker are never public methods.
export class ProCloudApi {
  #api;
  constructor(api) { this.#api = api; }
  async handle(event) {
    let input;
    try { input = envelope(event); }
    catch { return reply(400, 'invalid_request'); }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 14000); timer.unref?.();
    try {
      const request = new Request('https://pro.internal' + routes[input.operation], { method: 'POST',
        signal: controller.signal, body: input.body, headers: { 'Content-Type': 'application/json; charset=utf-8',
          ...(input.sessionToken ? { Authorization: 'Bearer ' + input.sessionToken } : {}) } });
      const response = await this.#api.handle(request);
      const body = await response.text();
      if (controller.signal.aborted || Buffer.byteLength(body) > 32768) return reply(503, 'verification_unavailable');
      return { version: 1, status: response.status, body };
    } catch { return reply(503, 'verification_unavailable'); }
    finally { clearTimeout(timer); }
  }
}
