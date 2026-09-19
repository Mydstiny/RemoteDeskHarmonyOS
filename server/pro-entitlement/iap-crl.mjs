import { certificateCrlUrls, fail } from './iap-crypto.mjs';

const MAX_BYTES = 2 * 1024 * 1024;
const CACHE_MS = 300000;
// Exact public CDPs observed in the pinned Huawei chain. Never follow a
// server-selected redirect or admit another CDN path. Revocation signatures
// and validity are still checked by OpenSSL before any cache admission.
const FIXED_CRL_URLS = new Map([
  ['http://h5hosting-drcn.dbankcdn.cn/cch5/crl/haicag3/HuaweiCBGHAIG3crl.crl',
    'https://h5hosting-drcn.dbankcdn.cn/cch5/crl/haicag3/HuaweiCBGHAIG3crl.crl'],
  ['https://h5hosting-drcn.dbankcdn.cn/cch5/crl/haicag3/HuaweiCBGHAIG3crl.crl',
    'https://h5hosting-drcn.dbankcdn.cn/cch5/crl/haicag3/HuaweiCBGHAIG3crl.crl'],
  ['http://cpki-caweb.huawei.com/cpki/servlet/crlFileDown.crl?certype=10&/root_g2_crl.crl',
    'https://h5hosting.dbankcdn.com/cch5/crl/pki_CRL_root_g2_crl/root_g2_crl.crl'],
  ['http://pki.consumer.huawei.com/ca/crl/root_g2_crl.crl',
    'https://h5hosting.dbankcdn.com/cch5/crl/pki_CRL_root_g2_crl/root_g2_crl.crl']
]);
function supportedUrl(value) {
  if (FIXED_CRL_URLS.has(value)) return true;
  try {
    const url = new URL(value);
    if (!['http:', 'https:'].includes(url.protocol) || url.hostname !== 'pki.consumer.huawei.com' ||
        url.username || url.password || url.port || url.search || url.hash ||
        !/^\/[A-Za-z0-9_./-]+\.crl$/i.test(url.pathname)) return false;
    return true;
  } catch { return false; }
}
function pem(bytes) {
  // Huawei publishes DER CRLs. OpenSSL validates syntax, issuer/signature,
  // thisUpdate/nextUpdate and revocation for every use, including cached data.
  return '-----BEGIN X509 CRL-----\n' + bytes.toString('base64').match(/.{1,64}/g).join('\n') + '\n-----END X509 CRL-----\n';
}

export class HuaweiIapCrlSource {
  #fetcher;
  #now;
  #cache = new Map();
  constructor(fetcher = fetch, now = Date.now) { this.#fetcher = fetcher; this.#now = now; }
  async #download(url) {
    const result = await this.#fetcher(url, { method: 'GET', redirect: 'error',
      headers: { Accept: 'application/pkix-crl, application/octet-stream' }, signal: AbortSignal.timeout(5000) });
    if (result.status !== 200 || !result.body) throw new Error('iap_crl_download_failed', { cause: { status: result.status } });
    const declared = result.headers.get('content-length');
    if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > MAX_BYTES)) fail('iap_crl_oversized');
    const reader = result.body.getReader(); const chunks = []; let size = 0;
    try {
      for (;;) {
        const part = await reader.read(); if (part.done) break;
        size += part.value.byteLength;
        if (size > MAX_BYTES) fail('iap_crl_oversized');
        chunks.push(Buffer.from(part.value));
      }
    } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
    if (size === 0) fail('iap_crl_empty');
    return Buffer.concat(chunks);
  }
  async prepare(certificates) {
    if (!Array.isArray(certificates) || certificates.length !== 2) fail('iap_crl_path_required');
    const allDistributions = certificates.map(certificateCrlUrls);
    const urls = [...new Set(allDistributions.map(distributions => {
      const url = distributions.find(supportedUrl);
      if (!url) throw new Error('iap_crl_distribution_unsupported', { cause: allDistributions.flat() });
      return FIXED_CRL_URLS.get(url) || url;
    }))];
    const now = this.#now();
    if (!Number.isSafeInteger(now) || now <= 0) fail('invalid_clock');
    const results = await Promise.allSettled(urls.map(async url => {
      const cached = this.#cache.get(url);
      if (cached && cached.created <= now && cached.expires > now) return { url, value: cached };
      this.#cache.delete(url);
      return { url, value: { bytes: await this.#download(url), created: now, expires: now + CACHE_MS } };
    }));
    // Retain the verifier's concurrency slot until both bounded downloads end.
    const failedIndex = results.findIndex(result => result.status !== 'fulfilled');
    if (failedIndex >= 0) {
      const error = results[failedIndex].reason;
      const code = error?.cause?.code;
      const kind = error?.name === 'TimeoutError' ? 'timeout' : error?.cause?.message === 'unexpected redirect' ? 'redirect' :
        ['ENOTFOUND', 'EAI_AGAIN'].includes(code) ? 'dns' :
        ['ECONNREFUSED', 'UND_ERR_CONNECT_TIMEOUT'].includes(code) ? 'connect' :
        ['CERT_HAS_EXPIRED', 'UNABLE_TO_VERIFY_LEAF_SIGNATURE', 'UNABLE_TO_GET_ISSUER_CERT_LOCALLY'].includes(code) ? 'tls' :
        Number.isInteger(error?.cause?.status) ? 'http' :
        error?.message === 'iap_crl_oversized' ? 'oversized' : error?.message === 'iap_crl_empty' ? 'empty' : 'network';
      throw new Error('iap_crl_download_failed', { cause: { index: failedIndex, kind, url: urls[failedIndex],
        ...(kind === 'http' ? { status: error.cause.status } : {}) } });
    }
    const records = results.map(result => result.value);
    return { pem: records.map(record => pem(record.value.bytes)).join(''),
      // Untrusted or stale responses are never admitted to the cache. Each
      // verifier checks the whole path with these CRLs before calling accept.
      accept: () => {
        for (const { url, value } of records) {
          const existing = this.#cache.get(url);
          if (!existing || value.created >= existing.created) this.#cache.set(url, value);
        }
        while (this.#cache.size > 8) this.#cache.delete(this.#cache.keys().next().value);
      },
      reject: () => {
        for (const { url, value } of records) if (this.#cache.get(url) === value) this.#cache.delete(url);
      }
    };
  }
}
