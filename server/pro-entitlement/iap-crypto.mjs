// Independently implemented from Huawei's IAP REST contract. No SDK/sample code
// is vendored. The certificate path is validated by OpenSSL, not by a JWS header.
import { createHash, createPrivateKey, sign, verify, X509Certificate } from 'node:crypto';
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';

const runFile = promisify(execFile);
export const HUAWEI_IAP_ROOT_SHA256 = 'df21a3c09f7954579305f85c64f80cad86f79853ee3a887c1dec95d218df3a37';
const IAP_LEAF_OID = Buffer.from('2b060104018f5b02831f0101', 'hex');
export const MAX_JWS_BYTES = 65536;
export function fail(code) { throw new Error(code); }
export function object(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail('invalid_object');
  return value;
}
export function boundedString(value, max = 256) {
  if (typeof value !== 'string' || value.length === 0 || value.length > max || /[\u0000-\u001f\u007f]/.test(value)) {
    fail('invalid_string');
  }
  return value;
}
export function jsonBytes(bytes) {
  try { return object(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes))); }
  catch { fail('invalid_json'); }
}
function base64(value, url = true) {
  boundedString(value, MAX_JWS_BYTES);
  if (!(url ? /^[A-Za-z0-9_-]+$/ : /^[A-Za-z0-9+/]+={0,2}$/).test(value)) fail('invalid_base64');
  const result = Buffer.from(value, url ? 'base64url' : 'base64');
  if (result.toString(url ? 'base64url' : 'base64') !== value) fail('invalid_base64');
  return result;
}
export function jwsParts(compact) {
  boundedString(compact, MAX_JWS_BYTES);
  const parts = compact.split('.');
  if (parts.length !== 3) fail('invalid_jws');
  return { header: jsonBytes(base64(parts[0])), payload: jsonBytes(base64(parts[1])),
    signature: base64(parts[2]), input: Buffer.from(parts[0] + '.' + parts[1]) };
}

// Parse only the X.509 extension envelope. OpenSSL validates the complete path,
// constraints, key usage, critical extensions, dates and configured CRLs below.
function derChildren(bytes, start = 0, end = bytes.length) {
  const children = [];
  for (let at = start; at < end;) {
    const tag = bytes[at++];
    if ((tag & 31) === 31 || at >= end || children.length >= 128) fail('invalid_certificate');
    let length = bytes[at++];
    if (length & 128) {
      const width = length & 127;
      if (width === 0 || width > 3 || at + width > end || bytes[at] === 0) fail('invalid_certificate');
      length = 0;
      for (let i = 0; i < width; i++) length = length * 256 + bytes[at++];
      if (length < 128) fail('invalid_certificate');
    }
    if (at + length > end) fail('invalid_certificate');
    children.push({ tag, start: at, end: at + length });
    at += length;
  }
  return children;
}
function hasIapSigningExtensions(raw) {
  const root = derChildren(raw);
  if (root.length !== 1 || root[0].tag !== 48) return false;
  const certificate = derChildren(raw, root[0].start, root[0].end);
  if (certificate.length !== 3 || certificate[0].tag !== 48) return false;
  const tbs = derChildren(raw, certificate[0].start, certificate[0].end);
  const extensions = tbs.filter(field => field.tag === 163);
  if (extensions.length !== 1) return false;
  const wrapper = derChildren(raw, extensions[0].start, extensions[0].end);
  if (wrapper.length !== 1 || wrapper[0].tag !== 48) return false;
  let matches = 0;
  let signingUsages = 0;
  for (const extension of derChildren(raw, wrapper[0].start, wrapper[0].end)) {
    if (extension.tag !== 48) return false;
    const fields = derChildren(raw, extension.start, extension.end);
    if (fields.length < 2 || fields.length > 3 || fields[0].tag !== 6 || fields.at(-1).tag !== 4) return false;
    const oid = raw.subarray(fields[0].start, fields[0].end);
    if (oid.equals(Buffer.from('551d0f', 'hex'))) {
      const value = fields.at(-1);
      const bits = derChildren(raw, value.start, value.end);
      if (bits.length !== 1 || bits[0].tag !== 3 || bits[0].end - bits[0].start < 2 ||
          raw[bits[0].start] > 7 || (raw[bits[0].start + 1] & 128) === 0) return false;
      signingUsages++;
    }
    if (!oid.equals(IAP_LEAF_OID)) continue;
    // Huawei defines this as a non-critical extension.
    if (fields.length === 3 && (fields[1].tag !== 1 || fields[1].end - fields[1].start !== 1 ||
        raw[fields[1].start] !== 0)) return false;
    matches++;
  }
  return matches === 1 && signingUsages === 1;
}

// Only call the downloader after validating the complete pinned certificate
// path and JWS signature. This parser does not itself establish trust.
export function certificateCrlUrls(raw) {
  const root = derChildren(raw);
  if (root.length !== 1 || root[0].tag !== 48) fail('invalid_certificate');
  const certificate = derChildren(raw, root[0].start, root[0].end);
  if (certificate.length !== 3 || certificate[0].tag !== 48) fail('invalid_certificate');
  const extensions = derChildren(raw, certificate[0].start, certificate[0].end).filter(field => field.tag === 163);
  if (extensions.length !== 1) fail('iap_crl_distribution_required');
  const wrapper = derChildren(raw, extensions[0].start, extensions[0].end);
  if (wrapper.length !== 1 || wrapper[0].tag !== 48) fail('invalid_certificate');
  const urls = []; let matches = 0;
  for (const extension of derChildren(raw, wrapper[0].start, wrapper[0].end)) {
    if (extension.tag !== 48) fail('invalid_certificate');
    const fields = derChildren(raw, extension.start, extension.end);
    if (fields.length < 2 || fields.length > 3 || fields[0].tag !== 6 || fields.at(-1).tag !== 4) fail('invalid_certificate');
    if (!raw.subarray(fields[0].start, fields[0].end).equals(Buffer.from('551d1f', 'hex'))) continue;
    matches++;
    const value = fields.at(-1); const points = derChildren(raw, value.start, value.end);
    if (points.length !== 1 || points[0].tag !== 48) fail('invalid_certificate');
    for (const point of derChildren(raw, points[0].start, points[0].end)) {
      if (point.tag !== 48) fail('invalid_certificate');
      const distributions = derChildren(raw, point.start, point.end).filter(field => field.tag === 160);
      for (const distribution of distributions) {
        const names = derChildren(raw, distribution.start, distribution.end);
        if (names.length !== 1 || names[0].tag !== 160) continue;
        for (const name of derChildren(raw, names[0].start, names[0].end)) {
          if (name.tag !== 134) continue;
          const bytes = raw.subarray(name.start, name.end);
          if (bytes.length === 0 || bytes.length > 2048 || bytes.some(byte => byte < 33 || byte > 126)) fail('invalid_crl_url');
          urls.push(bytes.toString('ascii'));
          if (urls.length > 8) fail('invalid_crl_url');
        }
      }
    }
  }
  if (matches !== 1 || urls.length === 0) fail('iap_crl_distribution_required');
  return urls;
}

export class HuaweiIapJwsVerifier {
  #root;
  #crls;
  #crlSource;
  #openssl;
  #now;
  #busy = 0;
  constructor({ rootCertificate, crls, crlSource, openssl = 'openssl', now = Date.now,
    rootFingerprint = HUAWEI_IAP_ROOT_SHA256 }) {
    this.#root = new X509Certificate(rootCertificate);
    // Alternate roots are solely a dependency-injected unit-test seam. The
    // service configuration always supplies the immutable Huawei fingerprint.
    if (createHash('sha256').update(this.#root.raw).digest('hex') !== rootFingerprint || !this.#root.ca) {
      fail('untrusted_iap_root');
    }
    if (crlSource === undefined) {
      if (typeof crls !== 'string' || crls.length === 0 || crls.length > 6 * 1024 * 1024) fail('iap_crls_required');
    } else if (crls !== undefined || typeof crlSource?.prepare !== 'function') fail('iap_crls_required');
    this.#crls = crls;
    this.#crlSource = crlSource;
    this.#openssl = openssl;
    this.#now = now;
  }
  async verify(compact) {
    const parts = jwsParts(compact);
    const header = parts.header;
    if (header.alg !== 'ES256' || header.typ !== 'JWT' || header.crit !== undefined || header.b64 !== undefined ||
        !Array.isArray(header.x5c) || header.x5c.length !== 3 || parts.signature.length !== 64) fail('invalid_iap_header');
    const certificates = header.x5c.map(cert => new X509Certificate(base64(cert, false)));
    const [leaf, intermediate, suppliedRoot] = certificates;
    if (!suppliedRoot.raw.equals(this.#root.raw) || leaf.ca || !intermediate.ca ||
        leaf.publicKey.asymmetricKeyType !== 'ec' || leaf.publicKey.asymmetricKeyDetails?.namedCurve !== 'prime256v1' ||
        !hasIapSigningExtensions(leaf.raw)) fail('invalid_iap_certificate');
    const now = this.#now();
    if (!Number.isSafeInteger(now) || now <= 0) fail('invalid_clock');
    if (this.#busy >= 4) fail('verification_busy');
    this.#busy++;
    let directory; let bundle; let stage = 0;
    try {
      directory = await mkdtemp(join(tmpdir(), 'remotedesk-iap-cert-'));
      await Promise.all([
        writeFile(join(directory, 'root.pem'), this.#root.toString(), { mode: 0o600 }),
        writeFile(join(directory, 'intermediate.pem'), intermediate.toString(), { mode: 0o600 }),
        writeFile(join(directory, 'leaf.pem'), leaf.toString(), { mode: 0o600 })
      ]);
      const pathArguments = ['verify', '-x509_strict', '-check_ss_sig', '-purpose', 'any',
        '-verify_depth', '2', '-attime', String(Math.floor(now / 1000)),
        '-CAfile', join(directory, 'root.pem'), '-no-CApath', '-no-CAstore',
        '-untrusted', join(directory, 'intermediate.pem')];
      const options = { timeout: 4000, maxBuffer: 65536 };
      stage = 1;
      if (this.#crlSource) await runFile(this.#openssl, [...pathArguments, join(directory, 'leaf.pem')], options);
      stage = 2;
      if (!verify('sha256', parts.input, { key: leaf.publicKey, dsaEncoding: 'ieee-p1363' }, parts.signature)) {
        fail('invalid_iap_signature');
      }
      stage = 3;
      if (this.#crlSource) bundle = await this.#crlSource.prepare([leaf.raw, intermediate.raw]);
      const crls = bundle ? bundle.pem : this.#crls;
      if (typeof crls !== 'string' || crls.length === 0 || crls.length > 6 * 1024 * 1024) fail('iap_crls_required');
      await writeFile(join(directory, 'crls.pem'), crls, { mode: 0o600 });
      stage = 4;
      await runFile(this.#openssl, [...pathArguments, '-crl_check_all', '-CRLfile', join(directory, 'crls.pem'),
        join(directory, 'leaf.pem')], options);
      bundle?.accept();
      return parts.payload;
    } catch (error) {
      bundle?.reject();
      // Keep only bounded stage/error identifiers; never propagate OpenSSL
      // output, certificate subjects or download URLs to deployment logs.
      const reason = ['invalid_iap_signature', 'iap_crl_distribution_required', 'iap_crl_distribution_unsupported',
        'iap_crl_download_failed', 'iap_crls_required', 'invalid_certificate', 'ENOENT', 'EACCES'].includes(error?.code || error?.message)
        ? (error.code || error.message) : 'unclassified';
      const match = typeof error?.stderr === 'string' ? /(?:^|\n)error ([0-9]{1,3}) at [0-9]{1,2} depth lookup:/.exec(error.stderr) : null;
      throw new Error('iap_verification_failed', { cause: { stage, reason,
        ...(match ? { opensslError: Number(match[1]) } : {}) } });
    }
    finally {
      this.#busy--;
      if (directory) await rm(directory, { recursive: true, force: true });
    }
  }
}

export function iapAuthorization(body, { applicationId, issuerId, keyId, privateKey }, now = Date.now()) {
  [applicationId, issuerId, keyId].forEach(value => boundedString(value));
  const key = createPrivateKey(privateKey);
  if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') fail('invalid_iap_signing_key');
  if (!Number.isSafeInteger(now) || now <= 0 || typeof body !== 'string') fail('invalid_authorization_input');
  const iat = Math.floor(now / 1000);
  const header = { alg: 'ES256', typ: 'JWT', kid: keyId };
  const payload = { iss: issuerId, aud: 'iap-v1', aid: applicationId, iat, exp: iat + 300,
    digest: createHash('sha256').update(body, 'utf8').digest('hex') };
  const input = Buffer.from(JSON.stringify(header)).toString('base64url') + '.' +
    Buffer.from(JSON.stringify(payload)).toString('base64url');
  return input + '.' + sign('sha256', Buffer.from(input), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
}

export async function configuredIapVerifier(rootPath, crlPath) {
  return new HuaweiIapJwsVerifier({ rootCertificate: await readFile(rootPath), crls: await readFile(crlPath, 'utf8') });
}
