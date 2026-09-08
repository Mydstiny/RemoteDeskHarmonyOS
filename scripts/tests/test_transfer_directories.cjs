/* Production ETS directory provider and artifact store against real temporary files. */
const fs = require('node:fs'), os = require('node:os'), path = require('node:path'), vm = require('node:vm');
const crypto = require('node:crypto'), assert = require('node:assert/strict');
const { fileURLToPath, pathToFileURL } = require('node:url');
const ts = require(process.env.TRANSFER_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..'), tests = [];
const test = (name, run) => tests.push({ name, run });
function environment() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'transfer-directory-test-'));
  const filesDir = path.join(directory, 'app'); fs.mkdirSync(filesDir);
  const fds = new Map(), locks = new Map(); let hook = null, nativeHook = null, writes = 0;
  const target = value => typeof value === 'string' && value.startsWith('file://') ? fileURLToPath(value) : value;
  const translate = error => { error.code = ({ ENOENT: 13900002, EEXIST: 13900015, EACCES: 13900012 })[error.code] || error.code; throw error; };
  const sync = run => { try { return run(); } catch (error) { translate(error); } };
  const action = async (kind, value, run) => { const result = sync(run); if (hook) await hook(kind, target(value)); return result; };
  const info = stat => ({ size: stat.size, mtime: stat.mtimeMs, ctime: stat.ctimeMs, ino: BigInt(stat.ino),
    isFile: () => stat.isFile(), isDirectory: () => stat.isDirectory(), isSymbolicLink: () => stat.isSymbolicLink() });
  const stat = value => info(typeof value === 'number' ? fs.fstatSync(value) : fs.statSync(target(value)));
  const lstat = value => info(fs.lstatSync(target(value)));
  const open = (value, mode) => {
    let flags = (mode & 2) ? fs.constants.O_RDWR : (mode & 1) ? fs.constants.O_WRONLY : fs.constants.O_RDONLY;
    if (mode & 0o100) flags |= fs.constants.O_CREAT;
    if (mode & 0o1000) flags |= fs.constants.O_TRUNC;
    if (mode & 0o400000) flags |= fs.constants.O_NOFOLLOW;
    if (mode & 0o200000) flags |= fs.constants.O_DIRECTORY;
    const name = target(value), fd = fs.openSync(name, flags, 0o600); fds.set(fd, name);
    return { fd, path: name, tryLock() { if (locks.has(name) && locks.get(name) !== fd) throw Error('busy'); locks.set(name, fd); },
      unlock() { if (locks.get(name) === fd) locks.delete(name); } };
  };
  const close = value => { const fd = typeof value === 'number' ? value : value.fd;
    const name = fds.get(fd); if (locks.get(name) === fd) locks.delete(name); fs.closeSync(fd); fds.delete(fd); };
  const read = (fd, buffer) => fs.readSync(fd, Buffer.from(buffer), 0, buffer.byteLength, null);
  const write = (fd, buffer) => fs.writeSync(fd, Buffer.from(buffer), 0, buffer.byteLength, null);
  const list = (value, options) => fs.readdirSync(target(value)).slice(0, options?.listNum || Infinity);
  const fileIo = { OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, READ_WRITE: 2, CREATE: 0o100, TRUNC: 0o1000, NOFOLLOW: 0o400000, DIR: 0o200000 },
    lstatSync: value => sync(() => lstat(value)), lstat: value => action('lstat', value, () => lstat(value)),
    statSync: value => sync(() => stat(value)), stat: value => action('stat', value, () => stat(value)),
    openSync: (value, mode) => sync(() => open(value, mode)), open: (value, mode) => action('open', value, () => open(value, mode)),
    closeSync: close, close: value => action('close', fds.get(typeof value === 'number' ? value : value.fd), () => close(value)),
    mkdirSync: value => sync(() => fs.mkdirSync(target(value))), mkdir: value => action('mkdir', value, () => fs.mkdirSync(target(value))),
    listFileSync: value => sync(() => list(value)), listFile: (value, options) => action('list', value, () => list(value, options)),
    readSync: read, read: (fd, buffer) => action('read', fds.get(fd), () => read(fd, buffer)), writeSync: write,
    write: (fd, buffer) => action('write', fds.get(fd), () => { writes++; return write(fd, buffer); }),
    fsyncSync: fd => fs.fsyncSync(fd), fsync: fd => action('fsync', fds.get(fd), () => fs.fsyncSync(fd)),
    renameSync: (a, b) => fs.renameSync(a, b), rename: async (a, b) => fs.renameSync(a, b),
    unlink: async value => fs.unlinkSync(value), truncate: async (fd, size) => fs.ftruncateSync(fd, size) };
  function anchoredPath(fd) {
    const inode = fs.fstatSync(fd).ino;
    const walk = current => {
      const stat = fs.lstatSync(current); if (stat.isSymbolicLink() || !stat.isDirectory()) return null;
      if (stat.ino === inode) return current;
      for (const name of fs.readdirSync(current)) { const found = walk(path.join(current, name)); if (found) return found; }
      return null;
    };
    const resolved = walk(directory); if (!resolved) throw Error('unreachable root FD'); return resolved;
  }
  function nativeParents(fd, relative, create) {
    let current = anchoredPath(fd);
    for (const part of relative.split('/').filter(Boolean)) {
      if (part === '.' || part === '..' || part.includes('\\')) throw Error('invalid relative path');
      current = path.join(current, part);
      if (!fs.existsSync(current) && create) fs.mkdirSync(current);
      const info = fs.lstatSync(current); if (info.isSymbolicLink() || !info.isDirectory()) throw Error('unsafe parent');
    }
    return current;
  }
  const native = {
    openExclusiveTransferDirectory(fd, leaf) {
      try { const target = path.join(anchoredPath(fd), leaf); fs.mkdirSync(target); const file = open(target, 0o200000 | 0o400000);
        if (nativeHook) nativeHook('root', target); return file.fd; } catch { return -1; }
    },
    ensureTransferExportDirectory(fd, relative) {
      try { const target = nativeParents(fd, relative, true); if (nativeHook) nativeHook('directory', target); return true; } catch { return false; }
    },
    openExclusiveTransferFile(fd, relative) {
      try { const pieces = relative.split('/'), leaf = pieces.pop(); const parent = nativeParents(fd, pieces.join('/'), false);
        const target = path.join(parent, leaf); if (nativeHook) nativeHook('beforeFile', target);
        const out = fs.openSync(target, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
        fds.set(out, target); if (nativeHook) nativeHook('file', target); return out; } catch { return -1; }
    }
  };
  class Decoder { constructor(encoding, options) { this.decoder = new TextDecoder(encoding, options); } decodeToString(bytes) { return this.decoder.decode(bytes); } }
  const util = { TextEncoder, TextDecoder: Decoder, generateRandomUUID: () => crypto.randomUUID().replaceAll('-', '') };
  const cryptoFramework = { createMd: () => { const md = crypto.createHash('sha256');
    return { updateSync: ({ data }) => md.update(Buffer.from(data)), update: async ({ data }) => md.update(Buffer.from(data)),
      digestSync: () => ({ data: new Uint8Array(md.digest()) }), digest: async () => ({ data: new Uint8Array(md.digest()) }) }; } };
  const modules = new Map();
  function load(name) {
    if (modules.has(name)) return modules.get(name);
    const module = { exports: {} }, file = path.join(root, 'entry/src/main/ets/services', name + '.ets');
    const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
    vm.runInNewContext(code, { module, exports: module.exports, require(id) {
      if (id === '@kit.CoreFileKit') return { fileIo, fileUri: { FileUri: class { constructor(uri) { this.path = fileURLToPath(uri); } } },
        statfs: { getFreeSizeSync: () => 12 * 1024 ** 3, getFreeSize: async () => 12 * 1024 ** 3 } };
      if (id === '@kit.BasicServicesKit') return {}; if (id === '@kit.ArkTS') return { util }; if (id === '@kit.CryptoArchitectureKit') return { cryptoFramework };
      if (id === './ExtensionLoader') return { ExtensionLoader: { getInstance: () => native } };
      if (id.startsWith('./')) return load(id.slice(2)); throw Error('unexpected import ' + id);
    } }, { filename: file }); modules.set(name, module.exports); return module.exports;
  }
  const store = load('TransferArtifactStore'), api = load('TransferDirectoryProvider');
  return { directory, api, store, get writes() { return writes; }, hook(value) { hook = value; }, onNative(value) { nativeHook = value; },
    get descriptors() { return [...fds].filter(([_fd, name]) => !name.endsWith('/lease.lock')); },
    folder(name) { const value = path.join(directory, name); fs.mkdirSync(value); return value; },
    async artifacts() {
      const batch = new store.TransferArtifactBatch(filesDir, store.transferScopeKey('a', 'h'), 'received');
      const slot = await batch.createNativeReceiveDirectory(() => true, 10);
      const tree = path.join(slot.path, 'receive-1', 'files', 'Root');
      fs.mkdirSync(path.join(tree, 'nested'), { recursive: true }); fs.mkdirSync(path.join(tree, 'empty'));
      fs.mkdirSync(path.join(slot.path, 'receive-1', 'partial'));
      fs.writeFileSync(path.join(tree, 'nested', 'same.txt'), 'hello'); fs.writeFileSync(path.join(tree, 'same.txt'), 'world');
      const specs = [['Root', true, 0], ['Root/nested', true, 0], ['Root/empty', true, 0],
        ['Root/nested/same.txt', false, 5], ['Root/same.txt', false, 5]];
      const artifacts = await slot.commit(specs.map(([relativeName, directory, size], index) => ({ index, relativeName: 'receive-1/files/' + relativeName, directory, size })));
      return { artifacts, batch };
    },
    cleanup() { for (const fd of fds.keys()) { try { fs.closeSync(fd); } catch {} } fs.rmSync(directory, { recursive: true, force: true }); } };
}
async function using(run) { const env = environment(); try { await run(env); } finally { env.cleanup(); } }
const uri = value => pathToFileURL(value).href;
const scan = (env, source, guard = () => true) => env.api.scanAuthorizedTransferDirectory(uri(source), guard);
const exportTree = (env, artifacts, destination, guard = () => true, progress = () => {}) =>
  env.api.exportTransferArtifactTree(artifacts, uri(destination), guard, progress);

test('scan keeps root, nested names, empty directories and literal percent URI without double decoding', () => using(async env => {
  const source = env.folder('源 %20'); fs.mkdirSync(path.join(source, '空')); fs.writeFileSync(path.join(source, '名%20.txt'), 'abc');
  const result = await scan(env, source); assert.equal(result.status, 'ready'); assert.equal(result.totalBytes, 3);
  assert.deepEqual(Array.from(result.entries, item => item.relativePath).sort(), ['源 %20', '源 %20/名%20.txt', '源 %20/空'].sort());
  const file = result.entries.find(item => !item.directory); assert.equal(fs.readFileSync(fileURLToPath(file.uri), 'utf8'), 'abc');
}));
test('scan rejects symbolic links and normalized name collisions', () => using(async env => {
  for (const names of [['A', 'a'], ['é', 'e\u0301']]) {
    const source = env.folder(crypto.randomUUID()); for (const name of names) fs.writeFileSync(path.join(source, name), 'x');
    // HFS/APFS may normalize equivalent spellings into one physical filename; the export topology case below covers both spellings independently.
    const result = await scan(env, source);
    if (fs.readdirSync(source).length > 1) assert.equal(result.status, 'failed');
  }
  env.hook(null); const source = env.folder('symlink'); fs.symlinkSync(env.directory, path.join(source, 'escape'));
  assert.equal((await scan(env, source)).diagnosticCode, 'transfer_directory_unsafe_type');
  assert.equal((await scan(env, source)).entries.length, 0);
}));
test('scan enforces 32-level, 1024-item and 2 GiB limits, including zero-byte files', () => using(async env => {
  const many = env.folder('many'); for (let i = 0; i < 1024; i++) fs.writeFileSync(path.join(many, String(i)), '');
  assert.equal((await scan(env, many)).diagnosticCode, 'transfer_directory_item_limit');
  const deep = env.folder('deep'); let current = deep; for (let i = 0; i < 32; i++) { current = path.join(current, 'd'); fs.mkdirSync(current); }
  assert.equal((await scan(env, deep)).diagnosticCode, 'transfer_directory_invalid_path');
  const large = env.folder('large'); const fd = fs.openSync(path.join(large, 'sparse'), 'w'); fs.ftruncateSync(fd, 2 * 1024 ** 3 + 1); fs.closeSync(fd);
  assert.equal((await scan(env, large)).diagnosticCode, 'transfer_directory_byte_limit');
}));
test('scan cancellation after await returns no partial offer, and replaced ancestors are rejected', () => using(async env => {
  const source = env.folder('cancel'); fs.writeFileSync(path.join(source, 'a'), 'abc'); let active = true;
  env.hook((kind, value) => { if (kind === 'list' && value === source) active = false; });
  const cancelled = await scan(env, source, () => active); assert.equal(cancelled.status, 'cancelled'); assert.equal(cancelled.entries.length, 0);
  env.hook(null); let replaced = false;
  env.hook((kind, value) => { if (!replaced && kind === 'lstat' && value === path.join(source, 'a')) {
    replaced = true; fs.renameSync(source, source + '-old'); fs.mkdirSync(source); } });
  assert.equal((await scan(env, source)).diagnosticCode, 'transfer_directory_changed');
}));
test('actual permission denial and unsupported URI are unavailable without requesting persistent permissions', () => using(async env => {
  const source = env.folder('denied'); env.hook(() => { const error = Error('denied'); error.code = 13900012; throw error; });
  assert.equal((await scan(env, source)).status, 'unavailable'); env.hook(null);
  assert.equal((await env.api.scanAuthorizedTransferDirectory('datashare://cloud/file', () => true)).status, 'unavailable');
}));
test('whole-tree export retains nested duplicate basenames and empty dirs, renames existing root and preserves sources', () => using(async env => {
  const { artifacts, batch } = await env.artifacts(), destination = env.folder('out');
  fs.mkdirSync(path.join(destination, 'root')); fs.writeFileSync(path.join(destination, 'root', 'user'), 'untouched');
  const progress = [], result = await exportTree(env, artifacts, destination, () => true, (written, total) => progress.push([written, total]));
  assert.equal(result.status, 'saved'); assert.equal(result.rootName, 'Root (1)'); assert.equal(result.evidence, 'writtenAndSynced');
  assert.equal(result.writtenBytes, 10); assert.equal(result.entries.length, 5);
  assert.equal(fs.readFileSync(path.join(destination, 'Root (1)', 'nested', 'same.txt'), 'utf8'), 'hello');
  assert.equal(fs.readFileSync(path.join(destination, 'Root (1)', 'same.txt'), 'utf8'), 'world');
  assert.ok(fs.statSync(path.join(destination, 'Root (1)', 'empty')).isDirectory());
  assert.equal(fs.readFileSync(path.join(destination, 'root', 'user'), 'utf8'), 'untouched');
  for (const artifact of artifacts) assert.ok(fs.existsSync(artifact.path));
  assert.deepEqual(progress.at(-1), [10, 10]); batch.release();
}));
test('export validates complete topology before creating anything', () => using(async env => {
  const { artifacts } = await env.artifacts(), destination = env.folder('invalid');
  const changed = artifacts.map(item => ({ ...item })); changed.at(-1).relativePath = 'Root/../escape';
  assert.equal((await exportTree(env, changed, destination)).status, 'failed'); assert.equal(fs.readdirSync(destination).length, 0);
  const collision = artifacts.map(item => ({ ...item })); collision.at(-1).relativePath = 'Root/NESTED/same.txt';
  assert.equal((await exportTree(env, collision, destination)).diagnosticCode, 'transfer_directory_name_collision');
  assert.equal(fs.readdirSync(destination).length, 0);
}));
test('root creation collision races retry without entering the existing folder', () => using(async env => {
  const { artifacts } = await env.artifacts(), destination = env.folder('race'); let injected = false;
  env.hook((kind, value) => { if (!injected && kind === 'list' && value === destination) {
    injected = true; fs.mkdirSync(path.join(destination, 'Root')); fs.writeFileSync(path.join(destination, 'Root', 'user'), 'safe'); } });
  const result = await exportTree(env, artifacts, destination); assert.equal(result.status, 'saved'); assert.equal(result.rootName, 'Root (1)');
  assert.equal(fs.readFileSync(path.join(destination, 'Root', 'user'), 'utf8'), 'safe');
}));
test('export refuses pre-existing empty files inside its new root', () => using(async env => {
  const { artifacts } = await env.artifacts(), destination = env.folder('inject'); let injected = false;
  env.onNative((kind, value) => { if (!injected && kind === 'directory' && value === path.join(destination, 'Root', 'empty')) {
    injected = true; fs.writeFileSync(path.join(destination, 'Root', 'nested', 'same.txt'), ''); } });
  const result = await exportTree(env, artifacts, destination); assert.equal(result.status, 'partial'); assert.equal(result.writtenBytes, 0);
  assert.equal(fs.statSync(path.join(destination, 'Root', 'nested', 'same.txt')).size, 0);
  assert.equal(result.entries.find(item => item.relativePath === 'Root/nested/same.txt').status, 'failed');
  assert.equal(result.entries.find(item => item.relativePath === 'Root/same.txt').status, 'skipped');
}));
test('cancel during write retains partial target and source with per-item unknown evidence', () => using(async env => {
  const { artifacts } = await env.artifacts(), destination = env.folder('partial'); let active = true;
  env.hook((kind, value) => { if (kind === 'write' && value.startsWith(destination)) active = false; });
  const result = await exportTree(env, artifacts, destination, () => active);
  assert.equal(result.status, 'commitUnknown'); assert.equal(result.entries.filter(item => item.status === 'commitUnknown').length, 1);
  assert.ok(result.entries.some(item => item.status === 'skipped')); assert.equal(result.evidence, 'partial');
  for (const artifact of artifacts) assert.ok(fs.existsSync(artifact.path));
}));
test('permission denial on root creation reports unavailable; cancellation after creation reports retained partial folder', () => using(async env => {
  const { artifacts } = await env.artifacts(), destination = env.folder('auth');
  env.hook((kind) => { if (kind === 'list') { const error = Error('denied'); error.code = 13900012; throw error; } });
  assert.equal((await exportTree(env, artifacts, destination)).status, 'unavailable'); env.hook(null);
  let active = true; env.onNative((kind, value) => { if (kind === 'root' && value.startsWith(destination)) active = false; });
  const result = await exportTree(env, artifacts, destination, () => active); assert.equal(result.status, 'cancelled');
  assert.equal(result.rootName, 'Root'); assert.equal(result.evidence, 'partial'); assert.ok(fs.existsSync(path.join(destination, 'Root')));
}));
test('export rejects NFC-equivalent topology names before filesystem writes', () => using(async env => {
  const { artifacts } = await env.artifacts(), destination = env.folder('nfc');
  const changed = artifacts.map(item => ({ ...item })); changed.at(-1).relativePath = 'Root/é'; changed.at(-2).relativePath = 'Root/e\u0301';
  const result = await exportTree(env, changed, destination);
  assert.equal(result.diagnosticCode, 'transfer_directory_name_collision'); assert.equal(fs.readdirSync(destination).length, 0);
}));
test('export detects an ancestor replaced by a symlink during source hashing and never writes through it', () => using(async env => {
  const { artifacts } = await env.artifacts(), destination = env.folder('swap'), outside = env.folder('outside'); let swapped = false;
  env.hook((kind, value) => { if (!swapped && kind === 'read' && !value.startsWith(destination)) {
    swapped = true; const nested = path.join(destination, 'Root', 'nested'); fs.renameSync(nested, nested + '-old'); fs.symlinkSync(outside, nested);
  } });
  const result = await exportTree(env, artifacts, destination); assert.equal(result.status, 'commitUnknown');
  assert.equal(fs.readdirSync(outside).length, 0); assert.equal(result.destinationUri, ''); for (const artifact of artifacts) assert.ok(fs.existsSync(artifact.path));
}));
test('export supports an empty directory tree without fabricating file-write evidence', () => using(async env => {
  const { artifacts } = await env.artifacts(), destination = env.folder('emptyonly');
  const empty = artifacts.filter(item => item.directory && (item.relativePath === 'Root' || item.relativePath === 'Root/empty'));
  const result = await exportTree(env, empty, destination); assert.equal(result.status, 'saved');
  assert.equal(result.evidence, 'directoriesCreated'); assert.equal(result.writtenBytes, 0); assert.ok(fs.statSync(path.join(destination, 'Root', 'empty')).isDirectory());
}));
test('exclusive FD export does not overwrite an empty file injected immediately before the native open', () => using(async env => {
  const { artifacts } = await env.artifacts(), destination = env.folder('exclusive'); let injected = false;
  env.onNative((kind, value) => { if (!injected && kind === 'beforeFile') { injected = true; fs.writeFileSync(value, ''); } });
  const result = await exportTree(env, artifacts, destination); assert.equal(result.status, 'partial'); assert.equal(result.writtenBytes, 0);
  assert.equal(fs.statSync(path.join(destination, 'Root', 'nested', 'same.txt')).size, 0); assert.equal(env.descriptors.length, 0);
}));
test('moved root continues through its owned FD and returns unknown location instead of a stale destination URI', () => using(async env => {
  const { artifacts } = await env.artifacts(), destination = env.folder('moving'); let moved = false;
  env.hook((kind, value) => { if (!moved && kind === 'read' && !value.startsWith(destination)) {
    moved = true; fs.renameSync(path.join(destination, 'Root'), path.join(destination, 'Moved')); fs.mkdirSync(path.join(destination, 'Root'));
    fs.writeFileSync(path.join(destination, 'Root', 'user'), 'untouched');
  } });
  const result = await exportTree(env, artifacts, destination); assert.equal(result.status, 'commitUnknown'); assert.equal(result.destinationUri, '');
  assert.equal(result.writtenBytes, 10); assert.equal(fs.readFileSync(path.join(destination, 'Moved', 'nested', 'same.txt'), 'utf8'), 'hello');
  assert.equal(fs.readFileSync(path.join(destination, 'Moved', 'same.txt'), 'utf8'), 'world');
  assert.equal(fs.readFileSync(path.join(destination, 'Root', 'user'), 'utf8'), 'untouched');
  assert.ok(result.entries.every(item => item.destinationUri === '')); assert.equal(env.descriptors.length, 0);
}));
test('cancellation after the grant FD opens and after exclusive target creation closes every owned descriptor', () => using(async env => {
  const { artifacts } = await env.artifacts(), destination = env.folder('close'); let active = true;
  env.hook((kind, value) => { if (kind === 'open' && value === destination) active = false; });
  assert.equal((await exportTree(env, artifacts, destination, () => active)).status, 'cancelled'); assert.equal(env.descriptors.length, 0);
  env.hook(null); active = true; env.onNative((kind) => { if (kind === 'file') active = false; });
  assert.equal((await exportTree(env, artifacts, destination, () => active)).status, 'cancelled'); assert.equal(env.descriptors.length, 0);
}));
(async () => { let failures = 0; for (const item of tests) { try { await item.run(); console.log('PASS ' + item.name); }
  catch (error) { failures++; console.error('FAIL ' + item.name + '\n' + error.stack); } }
  console.log(`${tests.length - failures}/${tests.length} transfer directory tests passed`); process.exitCode = failures ? 1 : 0; })();
