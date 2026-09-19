import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, randomBytes, createHash } from 'node:crypto';
import { mkdtemp, readFile, writeFile, rm, stat, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readSandboxConfiguration } from '../../server/pro-entitlement/agc/runtime.mjs';
import { buildSandboxPackage, publishSandboxArchive } from '../../server/pro-entitlement/agc/build-package.mjs';

const agc = fileURLToPath(new URL('../../server/pro-entitlement/agc/', import.meta.url));
const configuration = { applicationId: '1000000000000000001', productId: 'RemoteDesktop_Pro_Test', environment: 'SANDBOX',
  packageName: 'com.example.remotedesktop', zoneName: 'ProSandbox', issuer: 'remotedesk-pro-sandbox',
  grantKeyId: 'sandbox-rs256-v1', iapIssuerId: 'test-issuer', iapKeyId: 'test-iap-key' };
async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'pro-deployment-test-')); t.after(() => rm(directory, { recursive: true, force: true }));
  const rsa = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const ec = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const records = { 'sandbox.json': JSON.stringify(configuration),
    'oauth-client.json': JSON.stringify({ clientId: configuration.applicationId, clientSecret: 'unit-test-only-secret' }),
    'agc-server-credential.json': JSON.stringify({ region: 'CN', project_id: '100000000000000001', client_id: 'test-client', client_secret: 'unit-test-project-secret' }),
    'ledger-key.bin': randomBytes(32), 'session-key.bin': randomBytes(32),
    'grant-private.pem': rsa.privateKey.export({ format: 'pem', type: 'pkcs8' }),
    'grant-public.der': rsa.publicKey.export({ format: 'der', type: 'spki' }),
    'iap-private.p8': ec.privateKey.export({ format: 'pem', type: 'pkcs8' }) };
  for (const [name, value] of Object.entries(records)) await writeFile(join(directory, name), value, { mode: 0o600 });
  return { directory, records, write: (name, value) => writeFile(join(directory, name), value),
    load: () => readSandboxConfiguration(directory) };
}
test('private deployment configuration binds real RSA/P256 keys and signs the fixed sandbox identity', async t => {
  const f = await fixture(t); const loaded = await f.load();
  const challenge = randomBytes(32).toString('base64url');
  const signed = loaded.signer.sign({ status: 'noEntitlement', revision: 0 }, 'owner-' + 'a'.repeat(64), Date.now(), challenge);
  const body = JSON.parse(Buffer.from(signed.split('.')[1], 'base64url'));
  assert.equal(body.environment, 'sandbox'); assert.equal(body.productId, configuration.productId);
  assert.equal(body.applicationId, configuration.applicationId); assert.deepEqual(body.entitlementIds, []);
});
test('production scope, alternate app/OAuth identity, unknown fields and key mismatch fail before SDK startup', async t => {
  const f = await fixture(t);
  for (const change of [{ environment: 'NORMAL' }, { productId: 'other-product' }, { zoneName: 'SharedZone' },
    { packageName: 'other.app' }, { applicationId: 'not-an-app' }, { issuer: 'other-issuer' }, { extra: 'injected' }]) {
    await f.write('sandbox.json', JSON.stringify({ ...configuration, ...change })); await assert.rejects(f.load);
  }
  await f.write('sandbox.json', f.records['sandbox.json']);
  await f.write('oauth-client.json', JSON.stringify({ clientId: '1000000000000000002', clientSecret: 'test' })); await assert.rejects(f.load);
  await f.write('oauth-client.json', f.records['oauth-client.json']);
  await f.write('session-key.bin', f.records['ledger-key.bin']); await assert.rejects(f.load);
  await f.write('session-key.bin', f.records['session-key.bin']);
  await f.write('grant-public.der', generateKeyPairSync('rsa', { modulusLength: 2048 }).publicKey.export({ format: 'der', type: 'spki' }));
  await assert.rejects(f.load);
});
test('private files reject symlinks, oversized credentials, short keys and the wrong IAP curve', async t => {
  const f = await fixture(t);
  for (const [file, value] of [['ledger-key.bin', randomBytes(31)], ['oauth-client.json', ' '.repeat(4097)],
    ['iap-private.p8', generateKeyPairSync('ec', { namedCurve: 'secp384r1' }).privateKey.export({ format: 'pem', type: 'pkcs8' })]]) {
    await f.write(file, value); await assert.rejects(f.load); await f.write(file, f.records[file]);
  }
  await rm(join(f.directory, 'grant-public.der')); await symlink(join(f.directory, 'grant-private.pem'), join(f.directory, 'grant-public.der'));
  await assert.rejects(f.load);
});
test('packager cannot place secret input/output inside the application repository', async t => {
  const f = await fixture(t);
  await assert.rejects(() => buildSandboxPackage({ privateDirectory: f.directory, pkixDirectory: f.directory,
    output: join(agc, 'pro-private.zip') }), /outside_repository/);
  await assert.rejects(() => buildSandboxPackage({ privateDirectory: agc, pkixDirectory: f.directory,
    output: join(f.directory, 'pro-private.zip') }), /outside_repository/);
  await assert.rejects(() => buildSandboxPackage({ privateDirectory: f.directory, pkixDirectory: '.',
    output: join(f.directory, 'pro-private.zip') }), /absolute_deployment_paths/);
});
test('every bundled PKIX license matches its declared hash and the binary is absent from source', async () => {
  const manifest = JSON.parse(await readFile(join(agc, 'pkix/manifest.json'), 'utf8'));
  for (const [name, hash] of Object.entries(manifest.licenses)) {
    const bytes = await readFile(join(agc, 'pkix', name));
    assert.equal(createHash('sha256').update(bytes).digest('hex'), hash);
  }
  await assert.rejects(() => readFile(join(agc, 'pkix/bin/openssl')), { code: 'ENOENT' });
});

for (const failingPath of ['test.zip', 'test.zip.sha256']) {
  test(`partial write of ${failingPath} closes handles and removes only owned files`, async () => {
    const files = new Map(); const handles = [];
    const io = {
      async open(path, flags, mode) {
        assert.equal(flags, 'wx'); assert.equal(mode, 0o600);
        assert.equal(files.has(path), false); files.set(path, Buffer.alloc(0));
        const handle = {
          closed: false,
          async writeFile(bytes) {
            files.set(path, Buffer.from(bytes).subarray(0, 3));
            if (path === failingPath) throw Object.assign(new Error('simulated disk full'), { code: 'ENOSPC' });
            files.set(path, Buffer.from(bytes));
          },
          async close() { this.closed = true; }
        };
        handles.push(handle); return handle;
      },
      async remove(path) { assert.equal(handles.every(handle => handle.closed), true); files.delete(path); }
    };
    await assert.rejects(() => publishSandboxArchive('test.zip', Buffer.from('non-secret test archive'), io), { code: 'ENOSPC' });
    assert.equal(files.size, 0); assert.equal(handles.every(handle => handle.closed), true);
  });
}

test('real archive publication preserves existing files and writes a private checksum pair', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pro-package-output-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const output = join(directory, 'test.zip'); const archive = Buffer.from('non-secret test archive');
  await writeFile(output, 'existing archive');
  await assert.rejects(() => publishSandboxArchive(output, archive), { code: 'EEXIST' });
  assert.equal(await readFile(output, 'utf8'), 'existing archive');
  await rm(output);
  await writeFile(output + '.sha256', 'existing checksum');
  await assert.rejects(() => publishSandboxArchive(output, archive), { code: 'EEXIST' });
  await assert.rejects(() => readFile(output), { code: 'ENOENT' });
  assert.equal(await readFile(output + '.sha256', 'utf8'), 'existing checksum');
  await rm(output + '.sha256');
  await publishSandboxArchive(output, archive);
  assert.deepEqual(await readFile(output), archive);
  assert.equal(await readFile(output + '.sha256', 'utf8'), createHash('sha256').update(archive).digest('hex') + '\n');
  if (process.platform !== 'win32') {
    for (const path of [output, output + '.sha256']) assert.equal((await stat(path)).mode & 0o777, 0o600);
  }
});

test('AGC entry uses the platform logger only for bounded diagnostics while suppressing SDK console output', async t => {
  const { execFile } = await import('node:child_process');
  const { promisify } = await import('node:util');
  const { mkdir, copyFile } = await import('node:fs/promises');
  const directory = await mkdtemp(join(tmpdir(), 'pro-handler-log-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await mkdir(join(directory, 'agc'));
  await copyFile(join(agc, 'handler.cjs'), join(directory, 'handler.cjs'));
  await writeFile(join(directory, 'agc/runtime.mjs'), `
    export async function createSandboxRuntime({ diagnostic }) {
      console.info('private-sdk-details'); console.error('private-sdk-error');
      return { api: { async handle() { diagnostic({ code: 'invalid_jws' });
        return { version: 1, status: 503, body: '{"error":"verification_unavailable"}' }; } },
        async worker() { return { checked: 0, successful: 0, busy: false }; } };
    }
  `);
  const script = `const assert=require('node:assert/strict');
    global.logger={info:message=>process.stdout.write(message+'\\n')};
    const handler=require('./handler.cjs');
    handler.myHandler({}, {}, reply => { assert.equal(reply.status,503);
      handler.myWorker({}, {}, result => { assert.equal(result.result.checked,0); }); });`;
  const { stdout, stderr } = await promisify(execFile)(process.execPath, ['-e', script], { cwd: directory });
  assert.equal(stderr, '');
  assert.deepEqual(stdout.trim().split('\n').map(line => JSON.parse(line)),
    [{ event: 'pro_verification_failure', code: 'invalid_jws' }]);
});
