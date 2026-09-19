const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { test } = require('node:test');
const { proClientHost } = require('./helpers/pro_client_host.cjs');

test('sandbox deployment pins the project, function and RSA verification identity', t => {
  const host = proClientHost(); t.after(() => host.close());
  const { proBackendConfiguration } = host.load('ProBackendConfiguration');
  const config = proBackendConfiguration('sandbox');
  assert.equal(config.functionName, 'remotedesk-pro-sandbox-api');
  assert.equal(config.functionVersion, '$latest');
  assert.equal(config.trust.applicationId, '6917607610255320307');
  assert.equal(config.trust.productId, 'RemoteDesktop_Pro_Test');
  assert.equal(config.trust.issuer, 'remotedesk-pro-sandbox');
  assert.equal(config.trust.keyId, 'sandbox-rs256-v1');
  assert.equal(config.trust.environment, 'sandbox');
  const key = crypto.createPublicKey({ key: Buffer.from(config.trust.publicKeyDer), type: 'spki', format: 'der' });
  assert.equal(key.asymmetricKeyType, 'rsa');
  assert.equal(key.asymmetricKeyDetails.modulusLength, 2048);
  config.trust.publicKeyDer.fill(0);
  assert.notEqual(proBackendConfiguration('sandbox').trust.publicKeyDer[0], 0);
  assert.equal(proBackendConfiguration('production'), null);
});

test('Release cannot select a sandbox or production backend through this configuration', t => {
  const host = proClientHost({ debug: false }); t.after(() => host.close());
  const { proBackendConfiguration } = host.load('ProBackendConfiguration');
  assert.equal(proBackendConfiguration('sandbox'), null);
  assert.equal(proBackendConfiguration('production'), null);
});
