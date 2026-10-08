import { readFile, lstat } from 'node:fs/promises';
import { createHash, createPrivateKey, createPublicKey } from 'node:crypto';
import { createRequire } from 'node:module';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { boundedString, jsonBytes, HuaweiIapJwsVerifier } from '../iap-crypto.mjs';
import { HuaweiIapCrlSource } from '../iap-crl.mjs';
import { HuaweiAuthorizationCodeVerifier, HuaweiIapClient } from '../huawei-api.mjs';
import { ProCloudOrderLedger, ProLedgerRecord } from '../cloud-ledger.mjs';
import { ProFulfillmentService, ProGrantSigner } from '../fulfillment.mjs';
import { ProSessionService } from '../session.mjs';
import { ProHttpApi } from '../http-api.mjs';
import { ProCloudApi } from '../cloud-api.mjs';

const runFile = promisify(execFile);
const root = fileURLToPath(new URL('../', import.meta.url));
const configurationKeys = ['applicationId', 'productId', 'environment', 'packageName', 'zoneName',
  'issuer', 'grantKeyId', 'iapIssuerId', 'iapKeyId'];
const probeOwner = 'owner-' + createHash('sha256').update('ProSandbox deployment empty snapshot check').digest('hex');

async function boundedFile(path, maximum) {
  const info = await lstat(path);
  if (!info.isFile() || info.isSymbolicLink() || info.size === 0 || info.size > maximum) throw new Error('invalid_deployment_file');
  const value = await readFile(path);
  if (value.length === 0 || value.length > maximum) throw new Error('invalid_deployment_file');
  return value;
}

// Fixed sandbox identity only. This deployment cannot be reused for production
// by replacing an environment variable, event field or one configuration key.
export async function readSandboxConfiguration(directory) {
  const configuration = jsonBytes(await boundedFile(join(directory, 'sandbox.json'), 8192));
  if (Object.keys(configuration).length !== configurationKeys.length || configurationKeys.some(key =>
    typeof configuration[key] !== 'string' || configuration[key].length === 0 || configuration[key].length > 256) ||
    configuration.environment !== 'SANDBOX' || configuration.productId !== 'RemoteDesktop_Pro_Test' ||
    configuration.packageName !== 'com.example.remotedesktop' || configuration.zoneName !== 'ProSandbox' ||
    configuration.issuer !== 'remotedesk-pro-sandbox' || configuration.grantKeyId !== 'sandbox-rs256-v1' ||
    !/^[0-9]{10,24}$/.test(configuration.applicationId)) throw new Error('invalid_sandbox_configuration');
  configurationKeys.forEach(key => boundedString(configuration[key]));
  const oauth = jsonBytes(await boundedFile(join(directory, 'oauth-client.json'), 4096));
  if (Object.keys(oauth).length !== 2 || oauth.clientId !== configuration.applicationId) throw new Error('invalid_oauth_configuration');
  boundedString(oauth.clientSecret, 2048);
  const credentials = jsonBytes(await boundedFile(join(directory, 'agc-server-credential.json'), 8192));
  if (credentials.region !== 'CN' || typeof credentials.project_id !== 'string' || !/^[0-9]+$/.test(credentials.project_id)) {
    throw new Error('invalid_project_configuration');
  }
  boundedString(credentials.client_id); boundedString(credentials.client_secret, 2048);
  const ledgerKey = await boundedFile(join(directory, 'ledger-key.bin'), 32);
  const sessionKey = await boundedFile(join(directory, 'session-key.bin'), 32);
  if (ledgerKey.length !== 32 || sessionKey.length !== 32 || ledgerKey.equals(sessionKey)) throw new Error('invalid_deployment_keys');
  const grantKey = await boundedFile(join(directory, 'grant-private.pem'), 8192);
  const iapKey = await boundedFile(join(directory, 'iap-private.p8'), 8192);
  const iapPrivate = createPrivateKey(iapKey);
  if (iapPrivate.asymmetricKeyType !== 'ec' || iapPrivate.asymmetricKeyDetails?.namedCurve !== 'prime256v1') {
    throw new Error('invalid_iap_private_key');
  }
  const publicKey = createPublicKey(createPrivateKey(grantKey)).export({ format: 'der', type: 'spki' });
  const expectedPublic = await boundedFile(join(directory, 'grant-public.der'), 1024);
  if (!publicKey.equals(expectedPublic)) throw new Error('invalid_grant_public_key');
  // The production signer validates the RSA algorithm and modulus length.
  const signer = new ProGrantSigner({ ...configuration, keyId: configuration.grantKeyId }, grantKey);
  return { configuration, oauth, ledgerKey, sessionKey, iapKey, signer };
}

export async function createSandboxRuntime({ privateDirectory = join(root, 'private'), pkixDirectory = join(root, 'pkix'), diagnostic = () => {} } = {}) {
  if (process.platform !== 'linux' || process.arch !== 'x64' || Number(process.versions.node.split('.')[0]) < 22) {
    throw new Error('unsupported_sandbox_runtime');
  }
  const configuration = await readSandboxConfiguration(privateDirectory);
  const manifest = jsonBytes(await boundedFile(new URL('./pkix/manifest.json', import.meta.url), 16384));
  const openssl = join(pkixDirectory, 'bin', 'openssl');
  const executable = await boundedFile(openssl, 20 * 1024 * 1024);
  if (createHash('sha256').update(executable).digest('hex') !== manifest.binary.sha256) throw new Error('invalid_pkix_runtime');
  const { stdout } = await runFile(openssl, ['version'], { timeout: 4000, maxBuffer: 4096,
    env: { ...process.env, OPENSSL_CONF: '/dev/null' } });
  if (!stdout.startsWith('OpenSSL ' + manifest.version + ' ')) throw new Error('invalid_pkix_runtime');
  const verifier = new HuaweiIapJwsVerifier({ openssl,
    rootCertificate: await boundedFile(join(pkixDirectory, 'RootCaG2Ecdsa.cer'), 16384), crlSource: new HuaweiIapCrlSource() });
  const require = createRequire(import.meta.url);
  const { cloud, Region } = require('@hw-agconnect/cloud-server');
  const { configuration: identity, oauth, ledgerKey, sessionKey, iapKey, signer } = configuration;
  const collection = cloud.createInstance(join(privateDirectory, 'agc-server-credential.json'), 'remotedesk-pro-sandbox', Region.REGION_CN)
    .database({ zoneName: identity.zoneName }).collection(ProLedgerRecord);
  const ledger = new ProCloudOrderLedger(collection, identity, ledgerKey);
  // Fail startup if the existing control row, scope or encryption key is wrong.
  // This reads an empty probe account; it never creates an order/intent/account.
  await ledger.snapshot(probeOwner);
  const iap = new HuaweiIapClient({ ...identity, issuerId: identity.iapIssuerId, keyId: identity.iapKeyId, privateKey: iapKey }, verifier);
  const fulfillment = new ProFulfillmentService(ledger, iap, signer);
  const sessions = new ProSessionService(identity, new HuaweiAuthorizationCodeVerifier(oauth.clientId, oauth.clientSecret), sessionKey);
  const api = new ProCloudApi(new ProHttpApi(fulfillment, sessions, 4, diagnostic));
  let working = false;
  return { api, async worker() {
    if (working) return { checked: 0, successful: 0, busy: true };
    working = true;
    try { return { ...await fulfillment.reconcileDue(), busy: false }; }
    finally { working = false; }
  } };
}
