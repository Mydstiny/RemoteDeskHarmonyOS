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
  const descriptors = new Map(), deleted = [];
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
    const fd = fs.openSync(name, flags, 0o600); descriptors.set(fd, name); return { fd, path: name, name: path.basename(name) };
  }
  function close(file) { const fd = typeof file === 'number' ? file : file.fd; fs.closeSync(fd); descriptors.delete(fd); }
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
    if (id === '@kit.CoreFileKit') return { fileIo, statfs: { getFreeSize: async () => free } };
    if (id === '@kit.ArkTS') return { util };
    if (id === '@kit.CryptoArchitectureKit') return { cryptoFramework };
    throw Error('Unexpected module ' + id);
  } }, { filename: file });
  const api = module.exports, scope = api.transferScopeKey('account', 'host');
  return { api, directory, filesDir, scope, deleted, descriptors,
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
test('export cancellation after target write reports unknown and preserves partial and source', () => using(async env => {
  const source = env.source('source', crypto.randomBytes(100)), batch = env.batch();
  const artifact = await batch.stage(source, 'file', 100, () => true, () => {}), destination = path.join(env.directory, 'partial-export');
  let active = true; env.limitWrite(5); env.onWrite(name => { if (name === destination) active = false; });
  const result = await env.api.exportTransferArtifact(artifact, destination, () => active, () => {});
  assert.equal(result.status, 'commitUnknown'); assert.equal(result.writtenBytes, 5);
  assert.ok(fs.existsSync(destination)); assert.ok(fs.existsSync(artifact.path)); assert.ok(fs.existsSync(source));
  assert.equal(env.descriptors.size, 0);
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
  env.api.TransferArtifactBatch.batches.clear();
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
  env.api.TransferArtifactBatch.batches.clear();
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
(async () => { for (const { name, run } of tests) { await run(); console.log('PASS ' + name); }
  console.log(`PASS ${tests.length} real-filesystem artifact regressions`);
})().catch(error => { console.error(error); process.exitCode = 1; });
