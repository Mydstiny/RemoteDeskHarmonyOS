import { chmod, copyFile, lstat, mkdir, mkdtemp, readFile, readdir, realpath, rm, writeFile } from 'node:fs/promises';
import { createHash, X509Certificate } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { readSandboxConfiguration } from './runtime.mjs';

const runFile = promisify(execFile);
const agc = dirname(fileURLToPath(import.meta.url));
const repository = resolve(agc, '../../..');
const coreFiles = ['cloud-api.mjs', 'cloud-ledger.mjs', 'fulfillment.mjs', 'http-api.mjs',
  'huawei-api.mjs', 'iap-crl.mjs', 'iap-crypto.mjs', 'session.mjs'];
const privateFiles = ['sandbox.json', 'oauth-client.json', 'agc-server-credential.json',
  'grant-private.pem', 'grant-public.der', 'iap-private.p8', 'ledger-key.bin', 'session-key.bin'];
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

async function artifact(path, maximum) {
  const info = await lstat(path);
  if (!info.isFile() || info.isSymbolicLink() || info.size === 0 || info.size > maximum) throw new Error('invalid_pkix_file');
  const bytes = await readFile(path);
  if (bytes.length > maximum) throw new Error('invalid_pkix_file');
  return bytes;
}

async function copy(source, target, mode = 0o600) {
  const info = await lstat(source);
  if (!info.isFile() || info.isSymbolicLink()) throw new Error('non_regular_deployment_file');
  await mkdir(dirname(target), { recursive: true, mode: 0o700 });
  await copyFile(source, target); await chmod(target, mode);
}
async function inventory(directory, prefix = '') {
  const files = {};
  for (const entry of await readdir(join(directory, prefix), { withFileTypes: true })) {
    const name = prefix + entry.name;
    if (entry.isSymbolicLink()) throw new Error('package_symlink_rejected');
    if (entry.isDirectory()) Object.assign(files, await inventory(directory, name + '/'));
    else if (entry.isFile() && !name.startsWith('private/')) files[name] = digest(await readFile(join(directory, name)));
    else if (!entry.isFile()) throw new Error('package_file_type_rejected');
  }
  return Object.fromEntries(Object.entries(files).sort(([a], [b]) => a.localeCompare(b)));
}
function outside(path, parent) {
  const part = relative(parent, path);
  return part.startsWith('..' + sep) || part === '..' || isAbsolute(part);
}

export async function buildSandboxPackage({ privateDirectory, pkixDirectory, output }) {
  if (![privateDirectory, pkixDirectory, output].every(value => typeof value === 'string' && isAbsolute(value))) {
    throw new Error('absolute_deployment_paths_required');
  }
  // Neither the secret input nor the resulting ZIP may live in an application
  // checkout. The transient stage is private and always removed on completion.
  const sourceDirectory = await realpath(privateDirectory);
  const parent = await realpath(dirname(output));
  if (!outside(sourceDirectory, await realpath(repository)) || !outside(parent, await realpath(repository))) {
    throw new Error('private_package_must_be_outside_repository');
  }
  const config = await readSandboxConfiguration(sourceDirectory);
  const manifest = JSON.parse(await readFile(join(agc, 'pkix/manifest.json'), 'utf8'));
  const binary = await artifact(join(pkixDirectory, manifest.binary.path), 20 * 1024 * 1024);
  // Huawei's .cer download is PEM. Pin the certificate's canonical DER bytes,
  // which are identical across PEM formatting and the OpenSSL/X509 API.
  const rootCertificate = new X509Certificate(await artifact(join(pkixDirectory, manifest.rootCertificate.file), 16384)).raw;
  if (digest(binary) !== manifest.binary.sha256 || binary.length !== manifest.binary.bytes ||
    digest(rootCertificate) !== manifest.rootCertificate.sha256) throw new Error('pkix_artifact_mismatch');
  for (const [file, hash] of Object.entries(manifest.licenses)) {
    if (digest(await readFile(join(agc, 'pkix', file))) !== hash) throw new Error('pkix_license_mismatch');
  }
  const stage = await mkdtemp(join(tmpdir(), 'remotedesk-pro-package-')); await chmod(stage, 0o700);
  try {
    for (const name of coreFiles) await copy(join(agc, '..', name), join(stage, name));
    for (const name of privateFiles) await copy(join(sourceDirectory, name), join(stage, 'private', name));
    await readSandboxConfiguration(join(stage, 'private'));
    await copy(join(agc, 'handler.cjs'), join(stage, 'handler.js'));
    await copy(join(agc, 'runtime.mjs'), join(stage, 'agc/runtime.mjs'));
    for (const name of ['manifest.json', 'SBOM.spdx.json', 'build-openssl.sh', 'build-packages.txt',
      ...Object.keys(manifest.licenses)]) await copy(join(agc, 'pkix', name), join(stage, 'agc/pkix', name));
    for (const name of ['package.json', 'package-lock.json', 'SBOM.spdx.json', 'THIRD_PARTY_NOTICES.md',
      'ProLedgerRecord.json']) await copy(join(agc, name), join(stage, name));
    await copy(join(agc, 'DEPLOYMENT.md'), join(stage, 'DEPLOYMENT.md'));
    await copy(join(repository, 'LICENSES/AGPL-3.0-or-later.txt'), join(stage, 'AGPL-LICENSE.txt'));
    await mkdir(join(stage, 'pkix/bin'), { recursive: true, mode: 0o700 });
    await writeFile(join(stage, 'pkix', manifest.binary.path), binary, { mode: 0o755 });
    await writeFile(join(stage, 'pkix', manifest.rootCertificate.file), rootCertificate, { mode: 0o600 });
    await runFile('npm', ['ci', '--ignore-scripts', '--omit=dev', '--no-audit', '--no-fund', '--no-bin-links',
      '--cache', join(tmpdir(), 'remotedesk-pro-package-npm')], { cwd: stage, timeout: 120000, maxBuffer: 1024 * 1024 });
    const files = await inventory(stage);
    if (Object.keys(files).some(name => name.endsWith('.node') || name === 'ledger.mjs')) throw new Error('unexpected_native_dependency');
    for (const name of coreFiles) {
      if (/node:sqlite/.test(await readFile(join(stage, name), 'utf8'))) throw new Error('unexpected_native_dependency');
    }
    const reviewManifest = { schema: 1, functionEntry: 'handler.myHandler', workerEntry: 'handler.myWorker',
      environment: 'SANDBOX', productId: config.configuration.productId, zone: config.configuration.zoneName,
      runtime: 'AGC Node22+ Linux x64', createdAt: new Date().toISOString(),
      dependencyLockSha256: digest(await readFile(join(stage, 'package-lock.json'))),
      privateFiles, files };
    // Public-source hashes only: never expose hashes or values of individual keys.
    await writeFile(join(stage, 'DEPLOYMENT-MANIFEST.json'), JSON.stringify(reviewManifest, null, 2) + '\n', { mode: 0o600 });
    const temporaryZip = join(stage, 'deployment.zip');
    await runFile('zip', ['-q', '-r', temporaryZip, '.', '-x', 'deployment.zip'], { cwd: stage, timeout: 60000, maxBuffer: 1024 * 1024 });
    const archive = await readFile(temporaryZip);
    await writeFile(output, archive, { flag: 'wx', mode: 0o600 });
    try {
      await writeFile(output + '.sha256', digest(archive) + '\n', { flag: 'wx', mode: 0o600 });
    } catch (error) {
      // Only remove the archive created by this invocation. Never overwrite an
      // earlier package or leave a new secret-bearing ZIP after a failed build.
      await rm(output, { force: true });
      throw error;
    }
    return { output, sha256: digest(archive), bytes: archive.length, sourceFiles: Object.keys(files).length,
      privateFileCount: privateFiles.length, environment: 'SANDBOX' };
  } finally { await rm(stage, { recursive: true, force: true }); }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const names = ['--private-dir', '--pkix-dir', '--output'];
  if (args.length !== 6 || names.some((name, index) => args[index * 2] !== name)) {
    process.stderr.write('Usage: node build-package.mjs --private-dir ABS --pkix-dir ABS --output ABS.zip\n');
    process.exitCode = 2;
  } else {
    try { process.stdout.write(JSON.stringify(await buildSandboxPackage({ privateDirectory: args[1], pkixDirectory: args[3], output: args[5] })) + '\n'); }
    catch { process.stderr.write('Sandbox package preparation failed; no credentials were logged.\n'); process.exitCode = 1; }
  }
}
