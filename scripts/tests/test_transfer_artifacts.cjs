/* Runs the actual artifact store against real temporary filesystem files.
 * TRANSFER_TYPESCRIPT_PATH=<DevEco typescript module> node scripts/tests/test_transfer_artifacts.cjs
 * TRANSFER_ARTIFACT_SOURCE permits validating a complete draft before atomic installation.
 */
const fs = require('node:fs'), os = require('node:os'), path = require('node:path'), vm = require('node:vm');
const crypto = require('node:crypto'); const { fileURLToPath, pathToFileURL } = require('node:url');
const assert = require('node:assert/strict');
const ts = require(process.env.TRANSFER_TYPESCRIPT_PATH || process.env.SSH_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..'), tests = [];
const test = (name, run) => tests.push({ name, run });
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
function environment() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'transfer-artifact-test-'));
  const filesDir = path.join(directory, 'app'); fs.mkdirSync(filesDir);
  const descriptors = new Map(), deleted = [], locks = new Map();
  let maxWrite = Infinity, maxRead = Infinity, free = 12 * 1024 ** 3, manifestFail = false;
  let readHook = null, writeHook = null, corruptWrites = false, now = Date.now();
  const target = input => typeof input === 'string' && input.startsWith('file://') ? fileURLToPath(input) : input;
  const stat = input => {
    const info = typeof input === 'number' ? fs.fstatSync(input) : fs.statSync(target(input));
    return { size: info.size, mtime: info.mtimeMs, ctime: info.ctimeMs, ino: BigInt(info.ino),
      isFile: () => info.isFile(), isDirectory: () => info.isDirectory(), isSymbolicLink: () => info.isSymbolicLink() };
  };
  function lstat(input) {
    const info = fs.lstatSync(target(input));
    return { size: info.size, mtime: info.mtimeMs, ctime: info.ctimeMs, ino: BigInt(info.ino),
      isFile: () => info.isFile(), isDirectory: () => info.isDirectory(), isSymbolicLink: () => info.isSymbolicLink() };
  }
  function open(input, mode) {
    const name = target(input); let flags = (mode & 2) ? fs.constants.O_RDWR : (mode & 1) ? fs.constants.O_WRONLY : fs.constants.O_RDONLY;
    if (mode & 0o100) flags |= fs.constants.O_CREAT;
    if (mode & 0o1000) flags |= fs.constants.O_TRUNC;
    if (mode & 0o400000) flags |= fs.constants.O_NOFOLLOW;
    if (mode & 0o200000) flags |= fs.constants.O_DIRECTORY;
    const fd = fs.openSync(name, flags, 0o600); descriptors.set(fd, name); return { fd, path: name, name: path.basename(name),
      tryLock() { if (locks.has(name) && locks.get(name) !== fd) throw Error('synthetic lock busy'); locks.set(name, fd); },
      unlock() { if (locks.get(name) === fd) locks.delete(name); } };
  }
  function close(file) { const fd = typeof file === 'number' ? file : file.fd;
    const name = descriptors.get(fd); if (locks.get(name) === fd) locks.delete(name); fs.closeSync(fd); descriptors.delete(fd); }
  function read(fd, buffer) {
    const count = fs.readSync(fd, Buffer.from(buffer), 0, Math.min(buffer.byteLength, maxRead), null);
    if (readHook) readHook(descriptors.get(fd), count); return count;
  }
  function write(fd, buffer, sync = false) {
    if (sync && manifestFail && descriptors.get(fd)?.endsWith('manifest.pending')) throw Error('synthetic manifest write failure');
    const bytes = Buffer.from(buffer).subarray(0, Math.min(buffer.byteLength, maxWrite));
    const stored = corruptWrites && !sync ? Buffer.alloc(bytes.length, 0x78) : bytes;
    const count = fs.writeSync(fd, stored, 0, stored.length, null);
    if (writeHook) writeHook(descriptors.get(fd), count); return count;
  }
  const fileIo = { OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, READ_WRITE: 2, CREATE: 0o100, TRUNC: 0o1000, NOFOLLOW: 0o400000, DIR: 0o200000 },
    mkdirSync: p => fs.mkdirSync(p), lstatSync: lstat, stat: async p => stat(p), statSync: stat,
    openSync: open, open: async (p, mode) => open(p, mode), closeSync: close, close: async p => close(p),
    readSync: read, read: async (fd, buffer) => read(fd, buffer), writeSync: (fd, buffer) => write(fd, buffer, true),
    write: async (fd, buffer) => write(fd, buffer), fsyncSync: fd => fs.fsyncSync(fd), fsync: async fd => fs.fsyncSync(fd),
    renameSync: (a, b) => fs.renameSync(a, b), rename: async (a, b) => fs.renameSync(a, b),
    unlink: async p => { deleted.push(p); fs.unlinkSync(p); }, listFileSync: p => fs.readdirSync(p),
    unlinkSync: p => { deleted.push(p); fs.unlinkSync(p); }, rmdirSync: p => { deleted.push(p); fs.rmSync(p, { recursive: true }); },
    truncate: async (fd, size) => fs.ftruncateSync(fd, size)
  };
  class Decoder { constructor(encoding, options) { this.decoder = new TextDecoder(encoding, options); } decodeToString(bytes) { return this.decoder.decode(bytes); } }
  const util = { TextEncoder, TextDecoder: Decoder, generateRandomUUID: () => crypto.randomUUID().replaceAll('-', '') };
  const cryptoFramework = { createMd: () => {
    const digest = crypto.createHash('sha256');
    return { updateSync: ({ data }) => digest.update(Buffer.from(data)), update: async ({ data }) => digest.update(Buffer.from(data)),
      digestSync: () => ({ data: new Uint8Array(digest.digest()) }), digest: async () => ({ data: new Uint8Array(digest.digest()) }) };
  } };
  const file = process.env.TRANSFER_ARTIFACT_SOURCE || path.join(root, 'entry/src/main/ets/services/TransferArtifactStore.ets');
  const module = { exports: {} };
  const source = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  class FakeDate extends Date { static now() { return now; } }
  vm.runInNewContext(source, { module, exports: module.exports, Date: FakeDate, require(id) {
    if (id === '@kit.CoreFileKit') return { fileIo, fileUri: { FileUri: class { constructor(uri) { this.path = fileURLToPath(uri); } } }, statfs: { getFreeSize: async () => free, getFreeSizeSync: () => free } };
    if (id === '@kit.ArkTS') return { util };
    if (id === '@kit.CryptoArchitectureKit') return { cryptoFramework };
    throw Error('Unexpected module ' + id);
  } }, { filename: file });
  const api = module.exports, scope = api.transferScopeKey('account', 'host');
  const publicationModule = { exports: {} };
  const publicationCode = ts.transpileModule(fs.readFileSync(path.join(root, 'entry/src/main/ets/services/TransferArtifactPublicationService.ets'), 'utf8'),
    { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  vm.runInNewContext(publicationCode, { module: publicationModule, exports: publicationModule.exports, require(id) {
    if (id === '@kit.ArkTS') return { util }; if (id === './TransferArtifactStore') return api;
    throw Error('Unexpected publication dependency ' + id); } });
  return { api, directory, filesDir, scope, deleted,
    get descriptors() { return new Map([...descriptors].filter(([_fd, name]) => !name.endsWith('/lease.lock'))); },
    get leaseDescriptors() { return new Map([...descriptors].filter(([_fd, name]) => name.endsWith('/lease.lock'))); },
    publisher() { return new publicationModule.exports.TransferArtifactPublicationService(); },
    claimBatchLock(batch) { const file = open(path.join(batch.directory, 'lease.lock'), 2); file.tryLock(true); return () => close(file); },
    batch(purpose = 'clipboard') { return new api.TransferArtifactBatch(filesDir, scope, purpose); },
    source(name, bytes) { const target = path.join(directory, name); fs.writeFileSync(target, bytes); return target; },
    limitWrite(n) { maxWrite = n; }, limitRead(n) { maxRead = n; }, freeSpace(n) { free = n; },
    failManifest(v) { manifestFail = v; }, onRead(cb) { readHook = cb; }, onWrite(cb) { writeHook = cb; },
    corruptWrites(v) { corruptWrites = v; }, advance(ms) { now += ms; },
    cleanup() { for (const fd of descriptors.keys()) { try { fs.closeSync(fd); } catch {} } fs.rmSync(directory, { recursive: true, force: true }); }
  };
}
async function using(run) { const env = environment(); try { await run(env); } finally { env.cleanup(); } }

test('0 B and Unicode names stage with exact digest; literal percent URI is decoded once', () => using(async env => {
  const batch = env.batch(), empty = env.source('zero', Buffer.alloc(0));
  const a = await batch.stage(empty, '空😀.bin', 0, () => true, () => {});
  assert.equal(a.size, 0); assert.equal(a.sha256, sha(Buffer.alloc(0))); assert.equal(fs.statSync(a.path).size, 0);
  const source = env.source('literal%20name', Buffer.from('payload'));
  const b = await batch.stage(pathToFileURL(source).href, 'literal%20name', 7, () => true, () => {});
  assert.equal(fs.readFileSync(b.path, 'utf8'), 'payload'); assert.equal(b.name, 'literal%20name');
  assert.equal(env.descriptors.size, 0);
}));
test('duplicate, case and sanitization collisions receive distinct stable filenames including long Unicode names', () => using(async env => {
  const batch = env.batch(), source = env.source('source', Buffer.from('abc'));
  const names = ['File.txt', 'file.txt', 'a:b', 'a?b', 'content.partial', '😀'.repeat(60) + '.txt', '😀'.repeat(60) + '.txt'];
  const artifacts = [];
  for (const name of names) artifacts.push(await batch.stage(source, name, 3, () => true, () => {}));
  assert.equal(new Set(artifacts.map(a => a.name.toLowerCase())).size, names.length);
  for (const a of artifacts) { assert.equal(fs.readFileSync(a.path, 'utf8'), 'abc'); assert.ok(Buffer.byteLength(a.name) <= 180); }
}));
test('short reads and writes loop to completion without dropping bytes', () => using(async env => {
  env.limitRead(11); env.limitWrite(3); const bytes = crypto.randomBytes(513), source = env.source('short', bytes), batch = env.batch();
  const result = await batch.stage(source, 'short.bin', bytes.length, () => true, () => {});
  assert.deepEqual(fs.readFileSync(result.path), bytes); assert.equal(result.sha256, sha(bytes)); assert.equal(env.descriptors.size, 0);
}));
test('source mutation, wrong metadata, cancellation and corrupt destination writes reject staged success', () => using(async env => {
  const bytes = Buffer.alloc(100, 1), source = env.source('mutable', bytes); let changed = false;
  env.onRead((name) => { if (name === source && !changed) { changed = true; fs.appendFileSync(source, 'extra'); } });
  await assert.rejects(env.batch().stage(source, 'changed', 100, () => true, () => {}));
  env.onRead(null); await assert.rejects(env.batch().stage(source, 'size', 100, () => true, () => {}));
  let active = true; env.onRead((name) => { if (name === source) active = false; });
  await assert.rejects(env.batch().stage(source, 'cancel', 105, () => active, () => {})); env.onRead(null);
  env.corruptWrites(true); await assert.rejects(env.batch().stage(source, 'corrupt', 105, () => true, () => {}));
  assert.equal(fs.readFileSync(source).length, 105); assert.equal(env.descriptors.size, 0);
}));
test('quota reservation rejects low space and recovers capacity after failure; unknown picker size is measured', () => using(async env => {
  const batch = env.batch(), source = env.source('small', Buffer.from('small'));
  env.freeSpace(32 * 1024 * 1024 + 4); await assert.rejects(batch.stage(source, 'small', 5, () => true, () => {}));
  env.freeSpace(12 * 1024 ** 3); const result = await batch.stage(source, 'small', -1, () => true, () => {});
  assert.equal(result.size, 5); assert.equal(env.descriptors.size, 0);
}));
test('manifest write failure never publishes success or deletes source, and observers cannot undo commit', () => using(async env => {
  const source = env.source('source', Buffer.from('abc')), batch = env.batch(); env.failManifest(true);
  await assert.rejects(batch.stage(source, 'file', 3, () => true, () => {})); env.failManifest(false);
  assert.equal(fs.readFileSync(source, 'utf8'), 'abc'); assert.equal(batch.getArtifacts().length, 0);
  const good = await batch.stage(source, 'file', 3, () => true, () => { throw Error('observer failure'); });
  assert.equal(fs.readFileSync(good.path, 'utf8'), 'abc');
}));
test('native receive slot validates exact size, hashes closed payload and provides idempotent commit', () => using(async env => {
  const batch = env.batch('received'), bytes = crypto.randomBytes(100);
  const slot = await batch.beginNativeReceive('native.bin', bytes.length, () => true);
  fs.writeSync(slot.fd, bytes); const artifact = await slot.commit();
  assert.deepEqual(fs.readFileSync(artifact.path), bytes); assert.equal(artifact.sha256, sha(bytes));
  assert.equal((await slot.commit()).path, artifact.path); await slot.abort(); assert.ok(fs.existsSync(artifact.path));
  const short = await batch.beginNativeReceive('short.bin', 8, () => true); fs.writeSync(short.fd, Buffer.from('few'));
  await assert.rejects(short.commit()); assert.equal(env.descriptors.size, 0);
}));
test('stream receive rejects overrun and unknown-sized receive verifies bounded chunks', () => using(async env => {
  const batch = env.batch('received'), slot = await batch.beginReceive('stream.bin', -1, () => true);
  await slot.write(Uint8Array.from([1, 2, 3]).buffer); const artifact = await slot.commit(); assert.equal(artifact.size, 3);
  const short = await batch.beginReceive('small.bin', 1, () => true); await assert.rejects(short.write(new ArrayBuffer(2))); await short.abort();
  assert.equal(env.descriptors.size, 0);
}));
test('TTL cleanup requires release and non-published state; unknown old directories remain untouched', () => using(async env => {
  const source = env.source('source', Buffer.from('abc')), batch = env.batch();
  const artifact = await batch.stage(source, 'file', 3, () => true, () => {});
  const old = path.join(env.filesDir, 'rdp_transfer_legacy'); fs.mkdirSync(old); fs.writeFileSync(path.join(old, 'only-copy'), 'keep');
  env.advance(10000); assert.equal((await env.api.cleanupExpiredTransferArtifacts(env.filesDir, env.scope, 'clipboard', 0)).removedFiles, 0);
  batch.setPublished(true); batch.release(); env.advance(10000);
  assert.equal((await env.api.cleanupExpiredTransferArtifacts(env.filesDir, env.scope, 'clipboard', 0)).removedFiles, 0);
  batch.setPublished(false); env.advance(10000);
  assert.equal((await env.api.cleanupExpiredTransferArtifacts(env.filesDir, env.scope, 'clipboard', 0)).removedFiles, 1);
  assert.equal(fs.existsSync(artifact.path), false); assert.equal(fs.readFileSync(path.join(old, 'only-copy'), 'utf8'), 'keep');
  assert.equal(fs.readFileSync(source, 'utf8'), 'abc');
}));
test('malformed/forged manifests and symlinks prevent traversal and cleanup', () => using(async env => {
  assert.throws(() => env.api.ensureTransferScopeDirectory(env.filesDir, '../outside', 'clipboard'));
  const external = env.source('outside', Buffer.from('keep')), batch = env.batch();
  const artifact = await batch.stage(external, 'file', 4, () => true, () => {}); batch.release();
  fs.unlinkSync(artifact.path); fs.symlinkSync(external, artifact.path);
  const cleanup = await env.api.cleanupExpiredTransferArtifacts(env.filesDir, env.scope, 'clipboard', 0);
  assert.equal(cleanup.removedFiles, 0); assert.equal(fs.readFileSync(external, 'utf8'), 'keep');
  const manifestPath = path.join(batch.directory, 'manifest.json'); const original = fs.readFileSync(manifestPath, 'utf8');
  const forged = JSON.parse(original); forged.artifacts[0].id = '../outside'; fs.writeFileSync(manifestPath, JSON.stringify(forged));
  assert.equal(env.api.recoverTransferArtifactBatches(env.filesDir, env.scope).length, 0);
  assert.equal((await env.api.cleanupExpiredTransferArtifacts(env.filesDir, env.scope, 'clipboard', 0)).removedFiles, 0);
  fs.writeFileSync(manifestPath, original);
  const badRoot = path.join(env.directory, 'symlink-root'); fs.mkdirSync(badRoot);
  fs.symlinkSync(env.filesDir, path.join(badRoot, 'transfer-artifacts-v1'));
  assert.throws(() => env.api.ensureTransferScopeDirectory(badRoot, env.scope, 'clipboard'));
}));
test('export writes selected destination, never deletes source and refuses overwrite or alias', () => using(async env => {
  const bytes = crypto.randomBytes(100), source = env.source('source', bytes), batch = env.batch('received');
  const artifact = await batch.stage(source, 'file', bytes.length, () => true, () => {}), destination = path.join(env.directory, 'exported');
  env.limitWrite(7); const result = await env.api.exportTransferArtifact(artifact, pathToFileURL(destination).href, () => true, () => {});
  assert.equal(result.status, 'saved'); assert.equal(result.evidence, 'writtenAndSynced'); assert.equal(result.verified, false);
  assert.deepEqual(fs.readFileSync(destination), bytes); assert.ok(fs.existsSync(source)); assert.ok(fs.existsSync(artifact.path));
  fs.writeFileSync(destination, 'existing'); const refused = await env.api.exportTransferArtifact(artifact, destination, () => true, () => {});
  assert.equal(refused.status, 'failed'); assert.equal(fs.readFileSync(destination, 'utf8'), 'existing');
  const alias = await env.api.exportTransferArtifact(artifact, artifact.path, () => true, () => {}, true);
  assert.equal(alias.status, 'failed'); assert.deepEqual(fs.readFileSync(artifact.path), bytes);
  assert.equal(env.descriptors.size, 0);
}));
test('export cancellation after target write removes the half-written file and preserves the copy and source', () => using(async env => {
  const source = env.source('source', crypto.randomBytes(100)), batch = env.batch();
  const artifact = await batch.stage(source, 'file', 100, () => true, () => {}), destination = path.join(env.directory, 'partial-export');
  let active = true; env.limitWrite(5); env.onWrite(name => { if (name === destination) active = false; });
  const result = await env.api.exportTransferArtifact(artifact, destination, () => active, () => {});
  assert.equal(result.status, 'cancelled'); assert.equal(result.writtenBytes, 5);
  assert.equal(result.diagnosticCode, 'export_destination_cleared');
  assert.equal(fs.existsSync(destination), false); assert.ok(fs.existsSync(artifact.path)); assert.ok(fs.existsSync(source));
  assert.equal(env.descriptors.size, 0);
}));
test('a failed replace empties the chosen file but never deletes it', () => using(async env => {
  const source = env.source('source', crypto.randomBytes(100)), batch = env.batch('received');
  const artifact = await batch.stage(source, 'file', 100, () => true, () => {}), destination = path.join(env.directory, 'chosen');
  fs.writeFileSync(destination, 'the old version');
  let active = true; env.limitWrite(5); env.onWrite(name => { if (name === destination) active = false; });
  const result = await env.api.exportTransferArtifact(artifact, destination, () => active, () => {}, true);
  assert.equal(result.diagnosticCode, 'export_destination_emptied'); assert.ok(fs.existsSync(destination));
  assert.equal(fs.statSync(destination).size, 0);
}));
test('a save that replaces a file the user picked overwrites it', () => using(async env => {
  const bytes = crypto.randomBytes(40), source = env.source('source', bytes), batch = env.batch('received');
  const artifact = await batch.stage(source, 'file', bytes.length, () => true, () => {}), destination = path.join(env.directory, 'picked');
  fs.writeFileSync(destination, 'an older version of the file');
  const result = await env.api.exportTransferArtifact(artifact, destination, () => true, () => {}, true);
  assert.equal(result.status, 'saved'); assert.deepEqual(fs.readFileSync(destination), bytes);
}));
function nativeTree(slot, entries) {
  fs.mkdirSync(path.join(slot.path, 'receive-42/files'), { recursive: true });
  fs.mkdirSync(path.join(slot.path, 'receive-42/partial'));
  return entries.map((entry, index) => {
    const name = 'receive-42/files/' + entry.name, target = path.join(slot.path, name);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    if (entry.directory) fs.mkdirSync(target, { recursive: true }); else fs.writeFileSync(target, entry.bytes);
    return { index, relativeName: name, directory: !!entry.directory, size: entry.directory ? 0 : entry.bytes.length };
  });
}
test('native directory import preserves nested same basenames and empty directories with safe TTL', () => using(async env => {
  const batch = env.batch('received'), slot = await batch.createNativeReceiveDirectory(() => true, 6);
  const expected = nativeTree(slot, [{ name: '甲/a.txt', bytes: Buffer.from('abc') },
    { name: '乙/a.txt', bytes: Buffer.from('def') }, { name: '空目录', directory: true }]);
  const result = await slot.commit(expected);
  assert.deepEqual(Array.from(result, a => a.relativePath), ['甲/a.txt', '乙/a.txt', '空目录']);
  assert.equal(result[0].sha256, sha('abc')); assert.equal(result[2].directory, true);
  assert.equal((await slot.commit(expected)), result); assert.equal(env.descriptors.size, 0);
  const recovered = env.api.recoverTransferArtifactBatches(env.filesDir, env.scope, 'received');
  assert.equal(recovered.length, 1); assert.equal(recovered[0].getArtifacts().length, 3);
  batch.release(); env.advance(10000);
  const cleanup = await batch.cleanupExpired(0); assert.equal(cleanup.removedFiles, 2); assert.equal(cleanup.removedBytes, 6);
  assert.equal(fs.existsSync(result[0].path), false); assert.ok(fs.statSync(result[2].path).isDirectory());
  assert.equal((await batch.cleanupExpired(0)).removedFiles, 0);
}));
test('native import rejects unexpected files, traversal, symlinks and preserves failed imports', async () => {
  for (const kind of ['unexpected', 'traversal', 'symlink', 'size']) await using(async env => {
    const batch = env.batch('received'), slot = await batch.createNativeReceiveDirectory(() => true, 3);
    const expected = nativeTree(slot, [{ name: 'folder/a', bytes: Buffer.from('abc') }]);
    if (kind === 'unexpected') fs.writeFileSync(path.join(slot.path, 'surprise'), 'keep');
    if (kind === 'traversal') expected[0].relativeName = 'receive-42/files/../escape';
    if (kind === 'symlink') { const file = path.join(slot.path, expected[0].relativeName); fs.unlinkSync(file); fs.symlinkSync(env.source('outside', 'abc'), file); }
    if (kind === 'size') expected[0].size = 2;
    await assert.rejects(slot.commit(expected)); await slot.abort();
    assert.ok(fs.existsSync(slot.path)); assert.equal(slot.fd, -1); assert.equal(batch.getArtifacts().length, 0);
    const manifest = JSON.parse(fs.readFileSync(path.join(batch.directory, 'manifest.json')));
    assert.ok(manifest.holders.some(h => h.startsWith('native-unknown:')));
    batch.release(); env.advance(10000); assert.equal((await batch.cleanupExpired(0)).removedFiles, 0);
    await assert.rejects(batch.beginReceive('next', 0, () => true));
  });
});
test('unknown native FD lifetime closes only store handles and keeps storage, ownership and reservation', () => using(async env => {
  const batch = env.batch('received'), slot = await batch.beginNativeReceive('native', 100, () => true);
  const fd = fs.openSync(slot.path, 'r+'); await slot.retainPartial(); fs.writeSync(fd, Buffer.from('still-writing')); fs.closeSync(fd);
  await slot.abort(); assert.ok(fs.existsSync(slot.path)); assert.equal(slot.fd, -1);
  await assert.rejects(slot.commit()); await assert.rejects(batch.beginReceive('next', 0, () => true));
  const directoryBatch = env.batch('received'), directory = await directoryBatch.createNativeReceiveDirectory(() => true, 200);
  const dirfd = fs.openSync(directory.path, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY);
  await directory.abandon(); fs.writeFileSync(path.join(directory.path, 'native-still-owned'), 'data'); fs.closeSync(dirfd);
  await directory.abort(); assert.equal(directory.fd, -1); assert.ok(fs.existsSync(path.join(directory.path, 'native-still-owned')));
  assert.equal(env.descriptors.size, 0); assert.ok(env.api.TransferArtifactBatch.reservedBytes >= 300);
}));
test('retainPartial closes owned descriptors even when persistence fails', () => using(async env => {
  const batch = env.batch('received'), slot = await batch.beginNativeReceive('native', 3, () => true);
  env.failManifest(true); await assert.rejects(slot.retainPartial()); assert.equal(slot.fd, -1); assert.ok(fs.existsSync(slot.path));
  await slot.abort(); assert.ok(fs.existsSync(slot.path));
}));
test('global cache quota includes sparse unknown and retained files without deleting them', () => using(async env => {
  const batch = env.batch(), unknown = path.join(env.filesDir, 'transfer-artifacts-v1/unknown-cache');
  fs.mkdirSync(unknown); const file = path.join(unknown, 'sparse'); const fd = fs.openSync(file, 'w');
  fs.ftruncateSync(fd, 4 * 1024 ** 3); fs.closeSync(fd);
  await assert.rejects(batch.beginReceive('next', 1, () => true)); assert.ok(fs.existsSync(file));
}));
test('concurrent finalize and unknown-lifetime retention serialize descriptor closure', () => using(async env => {
  const batch = env.batch('received'), slot = await batch.beginNativeReceive('file', 3, () => true);
  fs.writeSync(slot.fd, Buffer.from('abc'));
  const commit = slot.commit(); const retain = slot.retainPartial();
  await assert.rejects(commit); await retain; assert.equal(slot.fd, -1); assert.ok(fs.existsSync(slot.path));
  const treeBatch = env.batch('received'), tree = await treeBatch.createNativeReceiveDirectory(() => true, 3);
  const expected = nativeTree(tree, [{ name: 'file', bytes: Buffer.from('abc') }]);
  const treeCommit = tree.commit(expected); const treeRetain = tree.retainPartial();
  await assert.rejects(treeCommit); await treeRetain; assert.equal(tree.fd, -1);
  assert.ok(fs.existsSync(path.join(tree.path, expected[0].relativeName))); assert.equal(env.descriptors.size, 0);
}));
test('native tree rejects case or Unicode normalization collisions before publication', () => using(async env => {
  const batch = env.batch('received'), slot = await batch.createNativeReceiveDirectory(() => true, 6);
  const expected = nativeTree(slot, [{ name: 'File', bytes: Buffer.from('abc') }]);
  expected.push({ index: 1, relativeName: 'receive-42/files/file', directory: false, size: 3 });
  await assert.rejects(slot.commit(expected)); assert.equal(batch.getArtifacts().length, 0);
}));
test('NFC-equivalent display names receive distinct names and recover from disk', () => using(async env => {
  const batch = env.batch(), source = env.source('source', Buffer.from('abc'));
  const first = await batch.stage(source, '\u00e9.txt', 3, () => true, () => {});
  const second = await batch.stage(source, 'e\u0301.txt', 3, () => true, () => {});
  assert.notEqual(first.name.normalize('NFC').toLowerCase(), second.name.normalize('NFC').toLowerCase());
  batch.release(); env.api.TransferArtifactBatch.batches.clear();
  const recovered = env.api.recoverTransferArtifactBatches(env.filesDir, env.scope, 'clipboard');
  assert.equal(recovered.length, 1); assert.equal(recovered[0].getArtifacts().length, 2);
  recovered[0].release(); env.advance(10000);
  const cleanup = await recovered[0].cleanupExpired(0);
  assert.equal(cleanup.invalidBatches, 0); assert.equal(cleanup.removedFiles, 2); assert.ok(fs.existsSync(source));
}));
test('manifest failure preserves empty attempt directory ownership for later successful-stage recovery and TTL', () => using(async env => {
  const batch = env.batch(), source = env.source('source', Buffer.from('abc'));
  env.failManifest(true); await assert.rejects(batch.stage(source, 'file', 3, () => true, () => {}));
  env.failManifest(false); const artifact = await batch.stage(source, 'file', 3, () => true, () => {});
  batch.release(); env.api.TransferArtifactBatch.batches.clear();
  const recovered = env.api.recoverTransferArtifactBatches(env.filesDir, env.scope, 'clipboard');
  assert.equal(recovered.length, 1); assert.equal(recovered[0].getArtifacts().length, 1);
  recovered[0].release(); env.advance(10000);
  const cleanup = await recovered[0].cleanupExpired(0);
  assert.equal(cleanup.invalidBatches, 0); assert.equal(cleanup.removedFiles, 1);
  assert.equal(fs.existsSync(artifact.path), false); assert.equal(fs.readFileSync(source, 'utf8'), 'abc');
}));
test('guard failure after attempt manifest retains cleanup ownership without publishing an artifact', () => using(async env => {
  const batch = env.batch(), source = env.source('source', Buffer.from('abc')); let active = true;
  env.onWrite(name => { if (name.endsWith('manifest.pending')) active = false; });
  await assert.rejects(batch.stage(source, 'file', 3, () => active, () => {}));
  env.onWrite(null); const artifact = await batch.stage(source, 'file', 3, () => true, () => {});
  batch.release(); env.advance(10000); const cleanup = await batch.cleanupExpired(0);
  assert.equal(cleanup.invalidBatches, 0); assert.equal(cleanup.removedFiles, 1);
  assert.equal(fs.existsSync(artifact.path), false); assert.ok(fs.existsSync(source));
}));
const publicationOwner = (generation = 11) => ({ sessionId: 7, generation, ownerToken: 19,
  facadeGeneration: 2, rendererHandle: 31, decoderHandle: 32, audioPlayerHandle: 33 });
test('scope inventory restores completed received artifacts and explicit cleanup retains external exports', () => using(async env => {
  const batch = env.batch('received'), source = env.source('source', Buffer.from('abc'));
  const artifact = await batch.stage(source, 'file', 3, () => true, () => {});
  const target = path.join(env.directory, 'saved'); assert.equal((await env.api.exportTransferArtifact(artifact, target, () => true, () => {})).status, 'saved');
  batch.release(); assert.equal(env.leaseDescriptors.size, 0); env.api.TransferArtifactBatch.batches.clear();
  const inventory = env.api.recoverTransferArtifactInventory(env.filesDir, env.scope);
  assert.equal(inventory.artifacts.length, 1); assert.equal(inventory.batches[0].canCleanup, true);
  const otherScope = env.api.transferScopeKey('other-account', 'host');
  assert.equal(env.api.recoverTransferArtifactInventory(env.filesDir, otherScope).artifacts.length, 0);
  assert.equal((await env.api.cleanupOwnedTransferArtifactBatch(env.filesDir, otherScope, 'received', batch.id)).invalidBatches, 1);
  assert.equal((await env.api.cleanupOwnedTransferArtifactBatch(env.filesDir, env.scope, 'received', batch.id)).removedFiles, 1);
  assert.equal(fs.existsSync(artifact.path), false); assert.equal(fs.readFileSync(source, 'utf8'), 'abc'); assert.equal(fs.readFileSync(target, 'utf8'), 'abc');
}));
test('recovered holders stay unknown even if a caller can acquire the lease lock', () => using(async env => {
  const batch = env.batch('received'), source = env.source('source', Buffer.from('abc'));
  await batch.stage(source, 'file', 3, () => true, () => {});
  batch.closeMutationLock(); env.api.TransferArtifactBatch.batches.clear(); // Simulate loss of runtime ownership, not a success receipt.
  const recovered = env.api.recoverTransferArtifactBatches(env.filesDir, env.scope, 'received')[0];
  const info = recovered.getInfo(); assert.equal(info.held, true); assert.equal(info.unknown, true); assert.equal(info.canCleanup, false);
  assert.throws(() => recovered.release()); await assert.rejects(recovered.beginReceive('new', 0, () => true));
  assert.equal((await env.api.cleanupOwnedTransferArtifactBatch(env.filesDir, env.scope, 'received', batch.id)).removedFiles, 0);
}));
test('after a restart, stale holders are cleared: staged upload copies go at once, received copies after the TTL', () => using(async env => {
  const day = 24 * 60 * 60 * 1000;
  const received = env.batch('received'), source = env.source('source', Buffer.from('abc'));
  const kept = await received.stage(source, 'file', 3, () => true, () => {});
  const upload = env.batch('clipboard'), publisher = env.publisher();
  const offered = await upload.stage(source, 'offer', 3, () => true, () => {});
  publisher.registerNativeOffer(upload, publicationOwner());
  received.closeMutationLock(); upload.closeMutationLock(); env.api.TransferArtifactBatch.batches.clear();
  const first = await env.api.reconcileTransferArtifactStorage(env.filesDir, 7 * day);
  assert.equal(first.removedFiles, 1); assert.equal(fs.existsSync(offered.path), false); assert.ok(fs.existsSync(kept.path));
  // The emptied upload batch is deleted, not rewritten on every later run.
  assert.equal(first.removedBatches, 1); assert.equal(fs.existsSync(upload.directory), false);
  assert.equal((await env.api.reconcileTransferArtifactStorage(env.filesDir, 7 * day)).removedBatches, 0);
  const info = env.api.recoverTransferArtifactInventory(env.filesDir, env.scope, 'received').batches[0];
  assert.equal(info.held, false); assert.equal(info.unknown, false); assert.equal(info.canCleanup, true);
  env.advance(6 * day); assert.equal((await env.api.reconcileTransferArtifactStorage(env.filesDir, 7 * day)).removedFiles, 0);
  env.advance(2 * day); const expired = await env.api.reconcileTransferArtifactStorage(env.filesDir, 7 * day);
  assert.equal(expired.removedFiles, 1); assert.equal(expired.removedBatches, 1);
  assert.equal(fs.existsSync(kept.path), false); assert.equal(fs.existsSync(received.directory), false);
  assert.equal(fs.readFileSync(source, 'utf8'), 'abc');
}));
test('reconcile never clears a batch held in this process or whose lock someone else holds', () => using(async env => {
  const source = env.source('source', Buffer.from('abc'));
  const live = env.batch('received'); const liveArtifact = await live.stage(source, 'live', 3, () => true, () => {});
  assert.equal((await env.api.reconcileTransferArtifactStorage(env.filesDir, 0)).removedFiles, 0);
  assert.equal(live.getInfo().held, true); assert.ok(fs.existsSync(liveArtifact.path));
  const other = env.batch('received'); await other.stage(source, 'other', 3, () => true, () => {});
  other.closeMutationLock(); env.api.TransferArtifactBatch.batches.delete(other.directory);
  const unlock = env.claimBatchLock(other);
  const restored = env.api.TransferArtifactBatch.recover(env.filesDir, env.scope, 'received', other.id);
  assert.equal(restored.reconcileStale(), false); assert.equal(restored.getInfo().held, true); unlock();
  assert.equal(restored.reconcileStale(), true); assert.equal(restored.getInfo().held, false);
}));
test('a stale unfinished receive tree is emptied and its batch becomes cleanable', () => using(async env => {
  const batch = env.batch('received'), directory = await batch.createNativeReceiveDirectory(() => true, 200);
  fs.mkdirSync(path.join(directory.path, 'receive-1')); fs.writeFileSync(path.join(directory.path, 'receive-1', 'half'), 'xx');
  const nativePath = directory.path;
  await directory.abandon(); batch.closeMutationLock(); env.api.TransferArtifactBatch.batches.clear();
  // The stale tree is emptied; the batch then holds nothing and is deleted with it.
  const result = await env.api.reconcileTransferArtifactStorage(env.filesDir, 7 * 24 * 60 * 60 * 1000);
  assert.equal(result.removedBatches, 1); assert.equal(fs.existsSync(nativePath), false);
  assert.equal(fs.existsSync(batch.directory), false);
  assert.equal(env.api.recoverTransferArtifactInventory(env.filesDir, env.scope, 'received').batches.length, 0);
}));
test('storage failures keep the space and size reasons a user can act on', () => using(async env => {
  const batch = env.batch('received'), source = env.source('source', Buffer.from('abc'));
  env.freeSpace(1); await assert.rejects(batch.stage(source, 'file', 3, () => true, () => {}), /transfer_space_limit/);
  env.freeSpace(12 * 1024 ** 3);
  await assert.rejects(batch.beginReceive('big', 3 * 1024 ** 3, () => true), /transfer_size_limit/);
  assert.equal(env.api.transferStorageFailureCode(new Error('weird'), 'fallback_code'), 'fallback_code');
  assert.equal(env.api.transferStorageFailureCode(new Error('transfer_space_limit'), 'x'), 'transfer_space_limit');
}));
test('a contended file lock blocks cleanup of an otherwise unheld batch', () => using(async env => {
  const batch = env.batch('received'), source = env.source('source', Buffer.from('abc'));
  const artifact = await batch.stage(source, 'file', 3, () => true, () => {}); batch.release();
  const unlock = env.claimBatchLock(batch);
  assert.equal((await env.api.cleanupOwnedTransferArtifactBatch(env.filesDir, env.scope, 'received', batch.id)).removedFiles, 0);
  assert.ok(fs.existsSync(artifact.path)); unlock();
  assert.equal((await env.api.cleanupOwnedTransferArtifactBatch(env.filesDir, env.scope, 'received', batch.id)).removedFiles, 1);
}));
test('native publication retirement requires every exact owner field and successful teardown', () => using(async env => {
  const batch = env.batch(), publisher = env.publisher(), owner = publicationOwner();
  const source = env.source('source', Buffer.from('abc')); await batch.stage(source, 'file', 3, () => true, () => {});
  publisher.registerNativeOffer(batch, owner); batch.release();
  assert.equal(batch.getInfo().published, true); assert.equal(publisher.completeNativeTeardown(owner, false), 0);
  for (const key of Object.keys(owner)) assert.equal(publisher.completeNativeTeardown({ ...owner, [key]: owner[key] + 1 }, true), 0);
  assert.equal((await batch.cleanupExpired(0)).removedFiles, 0);
  assert.equal(publisher.completeNativeTeardown(owner, true), 1); assert.equal(batch.getInfo().canCleanup, true);
  assert.equal(publisher.completeNativeTeardown(owner, true), 0); assert.equal((await batch.cleanupExpired(0)).removedFiles, 1);
}));
test('system clipboard leases survive native teardown and retire only after observed replacement', () => using(async env => {
  const batch = env.batch(), publisher = env.publisher(), owner = publicationOwner();
  publisher.registerNativeOffer(batch, owner); const system = publisher.registerSystemClipboard(batch);
  const tag = publisher.systemClipboardTag(system); assert.equal(publisher.confirmSystemClipboard(system, tag, 10), true); batch.release();
  assert.equal(publisher.completeNativeTeardown(owner, true), 1); assert.equal(batch.getInfo().published, true);
  assert.equal(publisher.observeSystemClipboard(tag, 11), 0); assert.equal(publisher.observeSystemClipboard('other', 10), 0);
  assert.equal(publisher.releaseSystemClipboard(system, false), false);
  assert.equal(publisher.observeSystemClipboard('other', 11), 1); assert.equal(batch.getInfo().published, false);
}));
test('bridge source tag retains real system clipboard artifacts until exact replacement', () => using(async env => {
  const batch = env.batch('received'), publisher = env.publisher();
  const source = env.source('tagged-source', Buffer.from('abc'));
  const artifact = await batch.stage(source, 'file', 3, () => true, () => {});
  const tag = 'remotedesk:remote-text:v1:42:9', id = publisher.registerSystemClipboard(batch, tag);
  assert.equal(publisher.systemClipboardTag(id), tag); batch.release();
  assert.equal(publisher.confirmSystemClipboard(id, tag, 17), true);
  assert.equal((await batch.cleanupExpired(0)).removedFiles, 0); assert.ok(fs.existsSync(artifact.path));
  assert.equal(publisher.observeSystemClipboard(tag, 18), 0);
  assert.equal(publisher.observeSystemClipboard('local-copy', 18), 1);
  assert.equal((await batch.cleanupExpired(0)).removedFiles, 1);
}));
test('bridge tags cannot be rebound after their publication was retired in this runtime', () => using(async env => {
  const first = env.batch(), second = env.batch(), publisher = env.publisher();
  const tag = 'remotedesk:remote-text:v1:42:10', id = publisher.registerSystemClipboard(first, tag);
  assert.throws(() => publisher.registerSystemClipboard(second, tag), /tag_invalid/);
  assert.equal(publisher.releaseSystemClipboard(id, true), true);
  assert.throws(() => publisher.registerSystemClipboard(second, tag), /tag_invalid/);
  assert.equal(second.getInfo().published, false);
}));
test('malformed remote tags are refused before durable publication registration', () => using(async env => {
  const batch = env.batch(), publisher = env.publisher();
  for (const tag of ['', 'local-tag', 'remotedesk:remote-text:v1:', 'remotedesk:remote-text:v1:a/b',
    'remotedesk:remote-text:v1:' + 'x'.repeat(129), 'remotedesk:remote-text:v1:a\n']) {
    assert.throws(() => publisher.registerSystemClipboard(batch, tag), /tag_invalid/);
    assert.equal(batch.getInfo().published, false);
  }
  assert.ok(publisher.systemClipboardTag(publisher.registerSystemClipboard(batch)).startsWith('remotedesk:remote-text:v1:artifact:'));
}));
test('unknown runtime publications and failed durable release never become cleanable', () => using(async env => {
  const batch = env.batch(), publisher = env.publisher(), owner = publicationOwner();
  publisher.registerNativeOffer(batch, owner); batch.release();
  assert.equal(env.publisher().completeNativeTeardown(owner, true), 0);
  env.failManifest(true); assert.equal(publisher.completeNativeTeardown(owner, true), 0); env.failManifest(false);
  assert.equal(batch.getInfo().published, true);
  batch.closeMutationLock(); env.api.TransferArtifactBatch.batches.clear();
  const inventory = env.api.recoverTransferArtifactInventory(env.filesDir, env.scope, 'clipboard');
  assert.equal(inventory.batches[0].unknown, true); assert.equal(inventory.batches[0].retentionReason, 'publication-owner-unknown');
  assert.equal(inventory.batches[0].canCleanup, false);
}));
test('platform incoming completion hashes the controlled directory once and preserves roots and empty folders', () => using(async env => {
  const batch = env.batch(), slot = await batch.createPlatformIncoming(() => true, 6);
  for (const directory of ['a', 'b', 'empty']) fs.mkdirSync(path.join(slot.path, directory));
  fs.writeFileSync(path.join(slot.path, 'a/item%20.bin'), 'abc'); fs.writeFileSync(path.join(slot.path, 'b/item%20.bin'), 'def');
  const artifacts = await slot.complete(['a', 'b', 'empty'].map(name => pathToFileURL(path.join(slot.path, name)).href));
  assert.deepEqual(Array.from(artifacts, item => item.relativePath), ['a', 'a/item%20.bin', 'b', 'b/item%20.bin', 'empty']);
  assert.equal(artifacts[1].sha256, sha('abc')); assert.ok(artifacts[1].path.startsWith(slot.path + '/')); // No second staged copy.
  batch.release(); env.api.TransferArtifactBatch.batches.clear();
  const inventory = env.api.recoverTransferArtifactInventory(env.filesDir, env.scope, 'clipboard');
  assert.equal(inventory.artifacts.length, 5); assert.equal(inventory.batches[0].canCleanup, true);
  const cleanup = await env.api.cleanupOwnedTransferArtifactBatch(env.filesDir, env.scope, 'clipboard', batch.id);
  assert.equal(cleanup.removedFiles, 2); assert.equal(cleanup.invalidBatches, 0); assert.ok(fs.statSync(path.join(slot.path, 'empty')).isDirectory());
}));
test('platform cancellation preserves an active producer and a later genuine completion can settle ownership', () => using(async env => {
  const batch = env.batch(), slot = await batch.createPlatformIncoming(() => true, 3);
  await slot.retainPartial(); batch.release(); fs.writeFileSync(path.join(slot.path, 'late'), 'abc');
  assert.equal(batch.getInfo().retentionReason, 'platform-writer-unknown'); assert.equal((await batch.cleanupExpired(0)).removedFiles, 0);
  const artifacts = await slot.complete([pathToFileURL(path.join(slot.path, 'late')).href]);
  assert.equal(artifacts.length, 1); assert.equal(batch.getInfo().canCleanup, true);
  assert.equal((await batch.cleanupExpired(0)).removedFiles, 1);
}));
test('platform import rejects external URIs, symlinks and undeclared payloads without deleting anything', async () => {
  for (const kind of ['external', 'symlink', 'unexpected']) await using(async env => {
    const batch = env.batch(), slot = await batch.createPlatformIncoming(() => true, 3), source = env.source('outside', 'abc');
    const item = path.join(slot.path, 'item'); if (kind === 'symlink') fs.symlinkSync(source, item); else fs.writeFileSync(item, 'abc');
    if (kind === 'unexpected') fs.writeFileSync(path.join(slot.path, 'extra'), 'keep');
    await assert.rejects(slot.complete([pathToFileURL(kind === 'external' ? source : item).href])); batch.release();
    assert.equal((await batch.cleanupExpired(0)).removedFiles, 0); assert.equal(fs.readFileSync(source, 'utf8'), 'abc'); assert.ok(fs.existsSync(item));
  });
});
test('logical directory APIs separate storage paths, preserve duplicate roots and survive disk recovery', () => using(async env => {
  const batch = env.batch('received'), source = env.source('source', Buffer.from('abc'));
  const first = await batch.createDirectoryRoot('目录', () => true), second = await batch.createDirectoryRoot('目录', () => true);
  assert.notEqual(first.relativePath, second.relativePath); await batch.createDirectory(first.relativePath + '/empty', () => true);
  const a = await batch.stageRelative(source, first.relativePath + '/same.txt', 3, () => true, () => {});
  const slot = await batch.beginNativeReceiveRelative(second.relativePath + '/same.txt', 3, () => true); fs.writeSync(slot.fd, Buffer.from('def'));
  const b = await slot.commit(); assert.notEqual(a.path, b.path); assert.equal(a.relativePath, first.relativePath + '/same.txt');
  await assert.rejects(batch.createDirectory(a.relativePath + '/child', () => true));
  await assert.rejects(batch.stageRelative(source, first.relativePath, 3, () => true, () => {}));
  await assert.rejects(batch.stageRelative(source, '../escape', 3, () => true, () => {}));
  batch.release(); env.api.TransferArtifactBatch.batches.clear();
  const inventory = env.api.recoverTransferArtifactInventory(env.filesDir, env.scope);
  assert.equal(inventory.artifacts.length, 5); assert.equal(inventory.batches[0].directoryCount, 3);
  assert.equal((await env.api.cleanupOwnedTransferArtifactBatch(env.filesDir, env.scope, 'received', batch.id)).removedFiles, 2);
  assert.ok(fs.existsSync(source));
}));
test('logical batches exceed the flat 15-file cap but reserve at most 2GiB in total', () => using(async env => {
  const batch = env.batch('received'), source = env.source('source', Buffer.alloc(0));
  for (let index = 0; index < 20; index++) await batch.stageRelative(source, 'root/file-' + index, 0, () => true, () => {});
  const one = env.source('one', Buffer.from('x')); await batch.stageRelative(one, 'root/one', 1, () => true, () => {});
  await assert.rejects(batch.beginNativeReceiveRelative('root/too-large', 2 * 1024 ** 3, () => true));
  const limit = await batch.beginNativeReceiveRelative('root/remaining', 2 * 1024 ** 3 - 1, () => true); await limit.abort();
  assert.equal(batch.getArtifacts().length, 21);
}));
test('malformed manifests appear as unknown inventory entries and cannot be explicitly cleaned', () => using(async env => {
  const batch = env.batch('received'), source = env.source('source', 'abc');
  const artifact = await batch.stage(source, 'file', 3, () => true, () => {}); batch.release();
  fs.writeFileSync(path.join(batch.directory, 'manifest.json'), '{corrupt'); env.api.TransferArtifactBatch.batches.clear();
  const inventory = env.api.recoverTransferArtifactInventory(env.filesDir, env.scope);
  assert.equal(inventory.invalidBatches, 1); assert.equal(inventory.batches.length, 1);
  assert.equal(inventory.batches[0].retentionReason, 'ownership-manifest-invalid'); assert.equal(inventory.batches[0].canCleanup, false);
  assert.equal((await env.api.cleanupOwnedTransferArtifactBatch(env.filesDir, env.scope, 'received', batch.id)).removedFiles, 0);
  assert.ok(fs.existsSync(artifact.path));
}));
test('publication registration failure refuses admission and unrelated exact native owners stay held', () => using(async env => {
  const a = env.batch(), b = env.batch(), publisher = env.publisher(), first = publicationOwner(), second = publicationOwner(12);
  env.failManifest(true); assert.throws(() => publisher.registerNativeOffer(a, first)); env.failManifest(false);
  assert.equal(a.getInfo().published, false);
  publisher.registerNativeOffer(a, first); publisher.registerNativeOffer(b, second); a.release(); b.release();
  assert.equal(publisher.completeNativeTeardown(first, true), 1); assert.equal(b.getInfo().published, true);
  assert.equal(publisher.completeNativeTeardown(second, true), 1); assert.equal(b.getInfo().published, false);
}));
test('legacy published state cannot be cleared by a recovered runtime and unknown exports release only their own locks', () => using(async env => {
  const batch = env.batch('received'), source = env.source('source', 'abc');
  const artifact = await batch.stage(source, 'file', 3, () => true, () => {}); batch.setPublished(true); batch.release();
  batch.closeMutationLock(); env.api.TransferArtifactBatch.batches.clear();
  const recovered = env.api.recoverTransferArtifactBatches(env.filesDir, env.scope, 'received')[0];
  assert.throws(() => recovered.setPublished(false)); assert.equal(env.leaseDescriptors.size, 0);
  const output = path.join(env.directory, 'exported'); assert.equal((await env.api.exportTransferArtifact(artifact, output, () => true, () => {})).status, 'saved');
  assert.equal(env.leaseDescriptors.size, 0); assert.equal(recovered.getInfo().published, true); assert.equal(recovered.getInfo().unknown, true);
}));
test('explicit cleanup clears empty-directory records without recursive removal', () => using(async env => {
  const batch = env.batch('received'), directory = await batch.createDirectory('root/empty', () => true); batch.release();
  assert.equal((await env.api.cleanupOwnedTransferArtifactBatch(env.filesDir, env.scope, 'received', batch.id)).invalidBatches, 0);
  assert.ok(fs.statSync(directory.path).isDirectory()); assert.equal(env.api.recoverTransferArtifactInventory(env.filesDir, env.scope).artifacts.length, 0);
}));
test('platform admission is synchronous for onDrop and enforces the same space reservation', () => using(async env => {
  const batch = env.batch(); env.freeSpace(32 * 1024 * 1024 + 2);
  assert.throws(() => batch.createPlatformIncomingSync(() => true, 3));
  env.freeSpace(12 * 1024 ** 3); const slot = batch.createPlatformIncomingSync(() => true, 3);
  assert.equal(typeof slot.then, 'undefined'); assert.ok(fs.statSync(slot.path).isDirectory());
  fs.writeFileSync(path.join(slot.path, 'item'), 'abc'); await slot.complete([pathToFileURL(path.join(slot.path, 'item')).href]);
  batch.release(); assert.equal(batch.getInfo().canCleanup, true);
}));
test('platform trees over 1024 entries are rejected and preserved before any hashing or publication', () => using(async env => {
  const batch = env.batch(), slot = batch.createPlatformIncomingSync(() => true, 0), directory = path.join(slot.path, 'root');
  fs.mkdirSync(directory); for (let index = 0; index < 1024; index++) fs.writeFileSync(path.join(directory, 'file-' + index), '');
  await assert.rejects(slot.complete([pathToFileURL(directory).href])); batch.release();
  assert.equal(batch.getArtifacts().length, 0); assert.equal(batch.getInfo().canCleanup, false); assert.equal(fs.readdirSync(directory).length, 1024);
}));
function localTreeSources(directory, rootName) {
  const result = [];
  const visit = (target, relativePath) => {
    const info = fs.lstatSync(target), isDirectory = info.isDirectory();
    result.push({ uri: pathToFileURL(target).href, relativePath, directory: isDirectory, size: isDirectory ? 0 : info.size, mtime: info.mtimeMs });
    if (isDirectory) for (const name of fs.readdirSync(target)) visit(path.join(target, name), relativePath + '/' + name);
  };
  visit(directory, rootName); return result;
}
test('local folder stages directly into one physical hierarchy with exact hashes and owned TTL', () => using(async env => {
  const sourceRoot = path.join(env.directory, 'Source %20'); fs.mkdirSync(path.join(sourceRoot, 'nested'), { recursive: true });
  fs.mkdirSync(path.join(sourceRoot, 'empty')); fs.writeFileSync(path.join(sourceRoot, 'a%20.txt'), 'alpha');
  fs.writeFileSync(path.join(sourceRoot, 'nested', 'a%20.txt'), 'beta'); fs.writeFileSync(path.join(sourceRoot, 'zero'), '');
  const batch = env.batch(), sources = localTreeSources(sourceRoot, '原根😀'); let payloadWrites = 0; const progress = [];
  env.onWrite((name, count) => { if (name.includes('/native-')) payloadWrites += count; });
  env.onRead((name) => { if (name.includes('/native-')) { assert.equal(batch.getArtifacts().length, 0); assert.ok(progress.every(([copied, total]) => copied < total)); } });
  const artifacts = await batch.stageLocalDirectoryTree(sources, () => true, (copied, total) => progress.push([copied, total]));
  env.onRead(null); env.onWrite(null); const root = artifacts.find(item => item.relativePath === '原根😀');
  assert.equal(root.directory, true); assert.equal(fs.readFileSync(path.join(root.path, 'a%20.txt'), 'utf8'), 'alpha');
  assert.equal(fs.readFileSync(path.join(root.path, 'nested', 'a%20.txt'), 'utf8'), 'beta'); assert.ok(fs.statSync(path.join(root.path, 'empty')).isDirectory());
  assert.equal(payloadWrites, 9); assert.equal(artifacts.find(item => item.relativePath.endsWith('/zero')).sha256, sha(''));
  assert.deepEqual(progress.at(-1), [9, 9]); assert.equal(env.descriptors.size, 0);
  const manifest = JSON.parse(fs.readFileSync(path.join(batch.directory, 'manifest.json'), 'utf8'));
  assert.ok(manifest.artifacts.every(item => item.state === 'complete' && item.storageRelativePath.startsWith('native-')));
  assert.equal(manifest.platformDirectories.length, 0); assert.equal(manifest.nativeDirectories[0].state, 'complete');
  assert.equal(env.api.recoverTransferArtifactBatches(env.filesDir, env.scope, 'clipboard')[0].getArtifacts().length, 6);
  batch.release(); const cleaned = await batch.cleanupExpired(0); assert.equal(cleaned.invalidBatches, 0); assert.equal(cleaned.removedFiles, 3);
  assert.equal(fs.readFileSync(path.join(sourceRoot, 'a%20.txt'), 'utf8'), 'alpha'); assert.ok(fs.existsSync(sourceRoot));
}));
test('local folder plan rejects malformed topology, outside URIs and NFC collisions before allocating a physical root', () => using(async env => {
  const sourceRoot = path.join(env.directory, 'source'); fs.mkdirSync(path.join(sourceRoot, 'nested'), { recursive: true });
  fs.writeFileSync(path.join(sourceRoot, 'a'), 'x'); fs.writeFileSync(path.join(sourceRoot, 'nested', 'b'), 'y');
  const original = localTreeSources(sourceRoot, 'Root');
  const mutations = [
    entries => { entries.at(-1).relativePath = 'Root/../escape'; },
    entries => { entries.at(-1).uri = pathToFileURL(path.join(env.directory, 'outside')).href; },
    entries => { entries.splice(entries.findIndex(item => item.relativePath === 'Root/nested'), 1); },
    entries => { entries[1].relativePath = 'Root/é'; entries.at(-1).relativePath = 'Root/e\u0301'; },
    entries => { entries.at(-1).size = 2 * 1024 ** 3 + 1; },
    entries => { entries[0].directory = false; }
  ];
  for (const mutate of mutations) {
    const batch = env.batch(), entries = original.map(item => ({ ...item })); mutate(entries);
    await assert.rejects(batch.stageLocalDirectoryTree(entries, () => true, () => {}));
    assert.equal(fs.readdirSync(batch.directory).filter(name => name.startsWith('native-')).length, 0); batch.release();
  }
}));
test('local tree copies short reads/writes and more than fifteen files without flattening', () => using(async env => {
  const sourceRoot = path.join(env.directory, 'many'); fs.mkdirSync(sourceRoot);
  for (let index = 0; index < 16; index++) fs.writeFileSync(path.join(sourceRoot, String(index)), 'abcdefghij');
  env.limitRead(3); env.limitWrite(2); const batch = env.batch();
  const artifacts = await batch.stageLocalDirectoryTree(localTreeSources(sourceRoot, 'Root'), () => true, () => {});
  assert.equal(artifacts.length, 17); const root = artifacts.find(item => item.directory);
  for (let index = 0; index < 16; index++) assert.equal(fs.readFileSync(path.join(root.path, String(index)), 'utf8'), 'abcdefghij');
  assert.equal(env.descriptors.size, 0); batch.release();
}));
test('local tree source mutation aborts the whole offer, retains attributable partial bytes and permits owned cleanup', () => using(async env => {
  const sourceRoot = path.join(env.directory, 'mutable'); fs.mkdirSync(sourceRoot); const file = path.join(sourceRoot, 'a'); fs.writeFileSync(file, 'abc');
  const sources = localTreeSources(sourceRoot, 'Root'), batch = env.batch(); let changed = false;
  env.onRead(name => { if (!changed && name === file) { changed = true; fs.appendFileSync(file, 'extra'); } });
  await assert.rejects(batch.stageLocalDirectoryTree(sources, () => true, () => {})); env.onRead(null);
  assert.equal(batch.getArtifacts().length, 0); assert.equal(env.descriptors.size, 0);
  const manifest = JSON.parse(fs.readFileSync(path.join(batch.directory, 'manifest.json'), 'utf8'));
  assert.equal(manifest.nativeDirectories[0].state, 'aborted'); assert.ok(manifest.artifacts.every(item => item.state === 'partial'));
  batch.release(); assert.equal(batch.getInfo().canCleanup, true);
  const cleaned = await batch.cleanupExpired(0); assert.equal(cleaned.invalidBatches, 0); assert.equal(cleaned.removedFiles, 1);
  assert.equal(fs.readFileSync(file, 'utf8'), 'abcextra');
}));
test('local tree cancellation after a payload write closes FDs and records the actual partial for cleanup', () => using(async env => {
  const sourceRoot = path.join(env.directory, 'cancel'); fs.mkdirSync(sourceRoot); fs.writeFileSync(path.join(sourceRoot, 'a'), 'abc');
  const batch = env.batch(); let active = true;
  env.onWrite(name => { if (name.includes('/native-')) active = false; });
  await assert.rejects(batch.stageLocalDirectoryTree(localTreeSources(sourceRoot, 'Root'), () => active, () => {})); env.onWrite(null);
  assert.equal(env.descriptors.size, 0); assert.equal(batch.getArtifacts().length, 0); batch.release();
  const cleaned = await batch.cleanupExpired(0); assert.equal(cleaned.removedBytes, 3); assert.equal(cleaned.invalidBatches, 0);
  assert.equal(fs.readFileSync(path.join(sourceRoot, 'a'), 'utf8'), 'abc');
}));
test('local tree manifest failure preserves partial ownership until persistence recovers', () => using(async env => {
  const sourceRoot = path.join(env.directory, 'manifest'); fs.mkdirSync(sourceRoot); fs.writeFileSync(path.join(sourceRoot, 'a'), 'abc');
  const batch = env.batch(); env.onRead(name => { if (name.includes('/native-')) env.failManifest(true); });
  await assert.rejects(batch.stageLocalDirectoryTree(localTreeSources(sourceRoot, 'Root'), () => true, () => {}));
  env.onRead(null); env.failManifest(false); assert.equal(batch.getArtifacts().length, 0); assert.equal(env.descriptors.size, 0);
  batch.release(); const recovered = env.api.recoverTransferArtifactBatches(env.filesDir, env.scope, 'clipboard'); assert.equal(recovered.length, 1);
  const cleaned = await batch.cleanupExpired(0); assert.equal(cleaned.invalidBatches, 0); assert.equal(cleaned.removedFiles, 1);
}));
test('local tree rejects unlisted children and directory symlinks and supports a truly empty root', () => using(async env => {
  const sourceRoot = path.join(env.directory, 'tree'); fs.mkdirSync(sourceRoot); fs.writeFileSync(path.join(sourceRoot, 'hidden'), 'secret');
  const batch = env.batch(), entries = localTreeSources(sourceRoot, 'Root'); entries.pop();
  await assert.rejects(batch.stageLocalDirectoryTree(entries, () => true, () => {})); assert.equal(batch.getArtifacts().length, 0);
  fs.unlinkSync(path.join(sourceRoot, 'hidden')); const sources = localTreeSources(sourceRoot, 'Root');
  fs.symlinkSync(env.directory, path.join(sourceRoot, 'link'));
  await assert.rejects(batch.stageLocalDirectoryTree(sources, () => true, () => {})); fs.unlinkSync(path.join(sourceRoot, 'link'));
  const progress = []; const artifacts = await batch.stageLocalDirectoryTree(localTreeSources(sourceRoot, 'Root'), () => true, (a, b) => progress.push([a, b]));
  assert.equal(artifacts.length, 1); assert.ok(artifacts[0].directory); assert.equal(fs.readdirSync(artifacts[0].path).length, 0);
  assert.deepEqual(progress, [[0, 0]]); batch.release();
}));
test('local tree partial filename uses persisted local layout and remains cleanable after recovery', () => using(async env => {
  const sourceRoot = path.join(env.directory, 'ordinary'); fs.mkdirSync(sourceRoot); fs.writeFileSync(path.join(sourceRoot, 'partial'), 'abc');
  const batch = env.batch(), artifacts = await batch.stageLocalDirectoryTree(localTreeSources(sourceRoot, 'Root'), () => true, () => {});
  batch.release(); const disk = JSON.parse(fs.readFileSync(path.join(batch.directory, 'manifest.json'), 'utf8'));
  assert.equal(disk.nativeDirectories[0].layout, 'localTree'); env.api.TransferArtifactBatch.batches.clear();
  const recovered = env.api.recoverTransferArtifactBatches(env.filesDir, env.scope, 'clipboard'); assert.equal(recovered.length, 1);
  assert.equal(recovered[0].getInfo().canCleanup, true); const cleaned = await recovered[0].cleanupExpired(0);
  assert.equal(cleaned.removedFiles, 1); assert.equal(cleaned.removedBytes, 3); assert.equal(cleaned.invalidBatches, 0);
  assert.equal(fs.existsSync(artifacts.find(item => !item.directory).path), false); assert.equal(fs.readFileSync(path.join(sourceRoot, 'partial'), 'utf8'), 'abc');
}));
test('old schema-2 local trees infer layout from exact stored/logical paths and persist the discriminator', () => using(async env => {
  const sourceRoot = path.join(env.directory, 'legacy-local'); fs.mkdirSync(sourceRoot); fs.writeFileSync(path.join(sourceRoot, 'partial'), 'abc');
  const batch = env.batch(); await batch.stageLocalDirectoryTree(localTreeSources(sourceRoot, 'receive-42'), () => true, () => {}); batch.release();
  const manifest = path.join(batch.directory, 'manifest.json'), disk = JSON.parse(fs.readFileSync(manifest, 'utf8'));
  delete disk.nativeDirectories[0].layout; fs.writeFileSync(manifest, JSON.stringify(disk)); env.api.TransferArtifactBatch.batches.clear();
  const recovered = env.api.recoverTransferArtifactBatches(env.filesDir, env.scope, 'clipboard'); assert.equal(recovered.length, 1);
  const cleaned = await recovered[0].cleanupExpired(0); assert.equal(cleaned.removedFiles, 1); assert.equal(cleaned.invalidBatches, 0);
  assert.equal(JSON.parse(fs.readFileSync(manifest, 'utf8')).nativeDirectories[0].layout, 'localTree');
}));
test('old RDP layouts remain strict and never treat their protocol partial directory as a local file', () => using(async env => {
  for (const corrupt of [false, true]) {
    const batch = env.batch('received'), slot = await batch.createNativeReceiveDirectory(() => true, 3);
    const expected = nativeTree(slot, [{ name: 'Root/file', bytes: Buffer.from('abc') }]);
    const artifacts = await slot.commit(expected); batch.release();
    const manifest = path.join(batch.directory, 'manifest.json'), disk = JSON.parse(fs.readFileSync(manifest, 'utf8'));
    assert.equal(disk.nativeDirectories[0].layout, 'rdpReceive'); delete disk.nativeDirectories[0].layout;
    fs.writeFileSync(manifest, JSON.stringify(disk));
    if (corrupt) { const partial = path.join(slot.path, 'receive-42/partial'); fs.rmdirSync(partial); fs.writeFileSync(partial, 'unexpected'); }
    env.api.TransferArtifactBatch.batches.clear();
    const recovered = env.api.TransferArtifactBatch.recover(env.filesDir, env.scope, 'received', batch.id); assert.ok(recovered);
    if (corrupt) { await assert.rejects(recovered.cleanupExpired(0)); assert.ok(fs.existsSync(artifacts[0].path)); }
    else { assert.equal((await recovered.cleanupExpired(0)).removedFiles, 1); }
  }
}));
test('forged or conflicting explicit layouts fail closed without deleting payloads', () => using(async env => {
  const sourceRoot = path.join(env.directory, 'conflict'); fs.mkdirSync(sourceRoot); fs.writeFileSync(path.join(sourceRoot, 'partial'), 'abc');
  const batch = env.batch(), artifacts = await batch.stageLocalDirectoryTree(localTreeSources(sourceRoot, 'Root'), () => true, () => {}); batch.release();
  const manifest = path.join(batch.directory, 'manifest.json'), original = JSON.parse(fs.readFileSync(manifest, 'utf8'));
  for (const layout of ['rdpReceive', 'anything']) {
    const disk = structuredClone(original); disk.nativeDirectories[0].layout = layout; fs.writeFileSync(manifest, JSON.stringify(disk));
    assert.equal(env.api.TransferArtifactBatch.recover(env.filesDir, env.scope, 'clipboard', batch.id), null);
    assert.ok(fs.existsSync(artifacts.find(item => !item.directory).path));
  }
}));
test('aborted local partial filename retains ownership and uses local layout during cleanup', () => using(async env => {
  const sourceRoot = path.join(env.directory, 'cancel-partial'); fs.mkdirSync(sourceRoot); fs.writeFileSync(path.join(sourceRoot, 'partial'), 'abc');
  const batch = env.batch(); let active = true; env.onWrite(name => { if (name.includes('/native-')) active = false; });
  await assert.rejects(batch.stageLocalDirectoryTree(localTreeSources(sourceRoot, 'Root'), () => active, () => {})); env.onWrite(null); batch.release();
  env.api.TransferArtifactBatch.batches.clear(); const recovered = env.api.TransferArtifactBatch.recover(env.filesDir, env.scope, 'clipboard', batch.id); assert.ok(recovered);
  const cleaned = await recovered.cleanupExpired(0); assert.equal(cleaned.removedFiles, 1); assert.equal(cleaned.removedBytes, 3); assert.equal(cleaned.invalidBatches, 0);
}));
(async () => { for (const { name, run } of tests) { await run(); console.log('PASS ' + name); }
  console.log(`PASS ${tests.length} real-filesystem artifact regressions`);
})().catch(error => { console.error(error); process.exitCode = 1; });
