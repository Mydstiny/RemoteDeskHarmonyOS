/* Actual Legacy recovery + directory scanner + artifact batch on a temporary
 * filesystem. No fake copying or source-account inference is used.
 */
const fs = require('node:fs'), os = require('node:os'), path = require('node:path'), vm = require('node:vm');
const crypto = require('node:crypto'), assert = require('node:assert/strict');
const { pathToFileURL, fileURLToPath } = require('node:url');
const ts = require(process.env.TRANSFER_TYPESCRIPT_PATH || process.env.SSH_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..'), tests = [];
const test = (name, run) => tests.push({ name, run });
function environment() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'legacy-transfer-recovery-'));
  const filesDir = path.join(directory, 'app'); fs.mkdirSync(filesDir);
  const descriptors = new Map(), locks = new Map(), io = [], cache = new Map(); let onRead = null, onLstat = null;
  const target = value => typeof value === 'string' && value.startsWith('file://') ? fileURLToPath(value) : value;
  function wrap(info) { return { size: info.size, mtime: info.mtimeMs, ctime: info.ctimeMs, ino: BigInt(info.ino),
    isFile: () => info.isFile(), isDirectory: () => info.isDirectory(), isSymbolicLink: () => info.isSymbolicLink() }; }
  function lstat(value) { const name = target(value); io.push({ op: 'lstat', path: name }); const result = wrap(fs.lstatSync(name));
    if (onLstat) onLstat(name); return result; }
  function stat(value) { return wrap(typeof value === 'number' ? fs.fstatSync(value) : fs.statSync(target(value))); }
  function list(value, options = {}) { const name = target(value); io.push({ op: 'list', path: name });
    assert.equal(options.recursion ?? false, false); const names = fs.readdirSync(name); return options.listNum ? names.slice(0, options.listNum) : names; }
  function open(value, mode) { const name = target(value);
    let flags = mode & 2 ? fs.constants.O_RDWR : mode & 1 ? fs.constants.O_WRONLY : fs.constants.O_RDONLY;
    if (mode & 0o100) flags |= fs.constants.O_CREAT; if (mode & 0o1000) flags |= fs.constants.O_TRUNC;
    if (mode & 0o400000) flags |= fs.constants.O_NOFOLLOW; if (mode & 0o200000) flags |= fs.constants.O_DIRECTORY;
    io.push({ op: 'open', path: name }); const fd = fs.openSync(name, flags, 0o600); descriptors.set(fd, name);
    return { fd, path: name, name: path.basename(name), tryLock() {
      if (locks.has(name) && locks.get(name) !== fd) throw Error('busy'); locks.set(name, fd);
    }, unlock() { if (locks.get(name) === fd) locks.delete(name); } }; }
  function close(value) { const fd = typeof value === 'number' ? value : value.fd, name = descriptors.get(fd);
    if (locks.get(name) === fd) locks.delete(name); fs.closeSync(fd); descriptors.delete(fd); }
  function read(fd, buffer) { const result = fs.readSync(fd, Buffer.from(buffer), 0, buffer.byteLength, null);
    if (onRead) onRead(descriptors.get(fd)); return result; }
  function write(fd, buffer) { return fs.writeSync(fd, Buffer.from(buffer), 0, buffer.byteLength, null); }
  const fileIo = { OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, READ_WRITE: 2, CREATE: 0o100, TRUNC: 0o1000, NOFOLLOW: 0o400000, DIR: 0o200000 },
    mkdirSync: name => fs.mkdirSync(name), lstatSync: lstat, lstat: async name => lstat(name), statSync: stat, stat: async value => stat(value),
    listFileSync: list, listFile: async (value, options) => list(value, options), openSync: open, open: async (value, mode) => open(value, mode),
    closeSync: close, close: async value => close(value), readSync: read, read: async (fd, buffer) => read(fd, buffer),
    writeSync: write, write: async (fd, buffer) => write(fd, buffer), fsyncSync: fd => fs.fsyncSync(fd), fsync: async fd => fs.fsyncSync(fd),
    renameSync: (a,b) => fs.renameSync(a,b), rename: async (a,b) => fs.renameSync(a,b),
    unlink: async name => { io.push({ op: 'unlink', path: name }); fs.unlinkSync(name); }, truncate: async (fd, size) => fs.ftruncateSync(fd,size) };
  const fileUri = { getUriFromPath: name => pathToFileURL(name).href, FileUri: class { constructor(uri) { this.path = fileURLToPath(uri); } } };
  class Decoder { constructor(encoding, options) { this.decoder = new TextDecoder(encoding, options); } decodeToString(bytes) { return this.decoder.decode(bytes); } }
  const util = { TextEncoder, TextDecoder: Decoder, generateRandomUUID: () => crypto.randomUUID().replaceAll('-', '') };
  const cryptoFramework = { createMd: () => { const value = crypto.createHash('sha256'); return {
    updateSync: ({data}) => value.update(Buffer.from(data)), update: async ({data}) => value.update(Buffer.from(data)),
    digestSync: () => ({ data: new Uint8Array(value.digest()) }), digest: async () => ({ data: new Uint8Array(value.digest()) }) }; } };
  function load(file) {
    file = path.resolve(root,file); if (cache.has(file)) return cache.get(file).exports;
    const module = { exports: {} }; cache.set(file,module);
    const source = ts.transpileModule(fs.readFileSync(file,'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
    }).outputText;
    function requireEts(id) {
      if (id === '@kit.CoreFileKit') return { fileIo, fileUri, statfs: { getFreeSize: async () => 12*1024**3, getFreeSizeSync: () => 12*1024**3 } };
      if (id === '@kit.ArkTS') return { util }; if (id === '@kit.CryptoArchitectureKit') return { cryptoFramework };
      if (id === './ExtensionLoader') return { ExtensionLoader: { getInstance() { throw Error('Recovery must not invoke native exports or publish'); } } };
      if (id === '@kit.BasicServicesKit') return {};
      if (!id.startsWith('.')) throw Error('Unexpected dependency '+id);
      return load(path.resolve(path.dirname(file),id+'.ets'));
    }
    vm.runInNewContext(source,{module,exports:module.exports,require:requireEts,ArrayBuffer,Uint8Array,Date},{filename:file}); return module.exports;
  }
  const legacy = load('entry/src/main/ets/services/LegacyTransferCacheRecovery.ets');
  const store = load('entry/src/main/ets/services/TransferArtifactStore.ets');
  return { legacy, store, directory, filesDir, io, descriptors,
    cache(name = 'rdp_transfer', files = { 'content.txt': 'original' }) { const folder = path.join(filesDir,name); fs.mkdirSync(folder);
      for (const [relative,bytes] of Object.entries(files)) { const output = path.join(folder,relative); fs.mkdirSync(path.dirname(output),{recursive:true}); fs.writeFileSync(output,bytes); }
      return folder; },
    batch() { return new store.TransferArtifactBatch(filesDir,store.transferScopeKey('current-account','current-host'),'received'); },
    onRead(value) { onRead=value; }, onLstat(value) { onLstat=value; },
    cleanup() { for (const fd of descriptors.keys()) { try { fs.closeSync(fd); } catch {} } fs.rmSync(directory,{recursive:true,force:true}); }
  };
}
async function using(run) { const env=environment(); try { await run(env); } finally { env.cleanup(); } }

test('module loading is quiet and only exact legacy names are examined on explicit listing', () => using(async env => {
  assert.equal(env.io.length,0);
  for (const name of ['rdp_transfer','rdp_transfer_aB_12','rdp_transfer_'+'a'.repeat(20)]) env.cache(name);
  for (const name of ['rdp_transfer_','rdp_transfer_'+'a'.repeat(21),'rdp_transfer-invalid','rdp_transfer_%2e','account_private']) env.cache(name);
  const values=await env.legacy.listLegacyTransferCaches(env.filesDir);
  assert.deepEqual(Array.from(values,item=>item.name).sort(),['rdp_transfer','rdp_transfer_aB_12','rdp_transfer_'+'a'.repeat(20)].sort());
  assert.ok(values.every(item=>item.available&&item.fileCount===1&&item.totalBytes===8));
  assert.equal(env.io.some(item=>item.path.includes('account_private')),false);
  assert.equal(env.io.some(item=>item.op==='open'||item.op==='unlink'),false);
  for (const value of values) assert.deepEqual(Object.keys(value).sort(),['available','diagnosticCode','fileCount','key','name','totalBytes']);
}));
test('forged keys and forged sandbox paths cannot enter staging or traverse outside', () => using(async env => {
  env.cache(); const batch=env.batch(); const before=fs.readFileSync(path.join(batch.directory,'manifest.json'),'utf8');
  for (const key of ['../outside','rdp_transfer/child','rdp_transfer_..','rdp_transfer_%2f','/rdp_transfer','rdp_transfer\\child','rdp_transfer\0x','rdp_transfer_'+'x'.repeat(21)]) {
    await assert.rejects(env.legacy.importLegacyTransferCache(env.filesDir,key,batch,()=>true,()=>{}));
  }
  for (const directory of [env.filesDir+'/../outside',env.filesDir+'//other','relative',env.filesDir+'/./']) {
    await assert.rejects(env.legacy.listLegacyTransferCaches(directory));
  }
  assert.equal(fs.readFileSync(path.join(batch.directory,'manifest.json'),'utf8'),before);
  assert.equal(env.io.some(item=>item.path.includes('outside')),false);
}));
test('matching symlink roots and descendant links are unavailable without opening their outside targets', () => using(async env => {
  const outside=path.join(env.directory,'outside');fs.mkdirSync(outside);fs.writeFileSync(path.join(outside,'secret'),'keep');
  fs.symlinkSync(outside,path.join(env.filesDir,'rdp_transfer_link'));
  const old=env.cache('rdp_transfer',{});fs.symlinkSync(outside,path.join(old,'nested'));
  const values=await env.legacy.listLegacyTransferCaches(env.filesDir);assert.equal(values.length,2);assert.ok(values.every(item=>!item.available));
  await assert.rejects(env.legacy.importLegacyTransferCache(env.filesDir,'rdp_transfer',env.batch(),()=>true,()=>{}));
  assert.equal(env.io.some(item=>item.op==='open'&&item.path.startsWith(outside)),false);
  assert.equal(fs.readFileSync(path.join(outside,'secret'),'utf8'),'keep');
}));
test('a symlink supplied as filesDir is rejected before any enumeration', () => using(async env => {
  const moved=path.join(env.directory,'moved');fs.renameSync(env.filesDir,moved);fs.symlinkSync(moved,env.filesDir);
  await assert.rejects(env.legacy.listLegacyTransferCaches(env.filesDir));assert.equal(env.io.some(item=>item.op==='list'),false);
}));
test('selected legacy tree copies into the current managed batch while every original remains', () => using(async env => {
  const old=env.cache('rdp_transfer_legacy',{'nested/中文.txt':'payload','zero':Buffer.alloc(0)}), batch=env.batch(), progress=[];
  const artifacts=await env.legacy.importLegacyTransferCache(env.filesDir,'rdp_transfer_legacy',batch,()=>true,(done,total)=>progress.push([done,total]));
  assert.equal(artifacts.filter(item=>!item.directory).length,2);assert.equal(artifacts.filter(item=>item.directory).length,2);
  const file=artifacts.find(item=>item.name==='中文.txt');assert.equal(fs.readFileSync(file.path,'utf8'),'payload');
  assert.equal(file.sha256,crypto.createHash('sha256').update('payload').digest('hex'));
  assert.equal(fs.readFileSync(path.join(old,'nested/中文.txt'),'utf8'),'payload');assert.equal(fs.statSync(path.join(old,'zero')).size,0);
  assert.equal(env.io.some(item=>item.op==='unlink'&&item.path.startsWith(old)),false);
  const manifest=JSON.parse(fs.readFileSync(path.join(batch.directory,'manifest.json'),'utf8'));assert.equal(manifest.published,false);
  assert.equal(manifest.scopeKey,env.store.transferScopeKey('current-account','current-host'));assert.equal(manifest.purpose,'received');
  assert.deepEqual(progress.at(-1),[7,7]); assert.equal(batch.getArtifacts().length,artifacts.length);
}));
test('listing metadata is advisory and import rescans the selected current content', () => using(async env => {
  const old=env.cache(), listed=await env.legacy.listLegacyTransferCaches(env.filesDir);assert.equal(listed[0].totalBytes,8);
  fs.writeFileSync(path.join(old,'content.txt'),'new value');
  const artifacts=await env.legacy.importLegacyTransferCache(env.filesDir,listed[0].key,env.batch(),()=>true,()=>{});
  assert.equal(artifacts.find(item=>!item.directory).size,9);
  assert.equal(fs.readFileSync(path.join(old,'content.txt'),'utf8'),'new value');
}));
test('account guard loss before work avoids scanning and guard loss during copy never publishes a partial tree', () => using(async env => {
  const old=env.cache(),batch=env.batch();let current=true;
  const initial=env.io.length;await assert.rejects(env.legacy.listLegacyTransferCaches(env.filesDir,()=>false));assert.equal(env.io.length,initial);
  env.onRead(name=>{if(name===path.join(old,'content.txt')) current=false;});
  await assert.rejects(env.legacy.importLegacyTransferCache(env.filesDir,'rdp_transfer',batch,()=>current,()=>{}));
  assert.equal(batch.getArtifacts().length,0);assert.equal(fs.readFileSync(path.join(old,'content.txt'),'utf8'),'original');
  assert.equal([...env.descriptors.values()].filter(name=>!name.endsWith('/lease.lock')).length,0);
}));
test('replacing a scanned root by an outside symlink invalidates listing without following it', () => using(async env => {
  const old=env.cache(), outside=path.join(env.directory,'outside');fs.mkdirSync(outside);fs.writeFileSync(path.join(outside,'content.txt'),'outside');
  let swapped=false;env.onLstat(name=>{if(!swapped&&name===path.join(old,'content.txt')){swapped=true;fs.renameSync(old,old+'-held');fs.symlinkSync(outside,old);}});
  const values=await env.legacy.listLegacyTransferCaches(env.filesDir);assert.equal(values[0].available,false);
  assert.equal(env.io.some(item=>item.op==='open'&&item.path.startsWith(outside)),false);assert.equal(fs.readFileSync(path.join(outside,'content.txt'),'utf8'),'outside');
}));
test('32-component depth is accepted and deeper trees are unavailable', () => using(async env => {
  const old=env.cache('rdp_transfer',{});const allowed=path.join(old,...Array(31).fill('d'));fs.mkdirSync(allowed,{recursive:true});
  assert.equal((await env.legacy.listLegacyTransferCaches(env.filesDir))[0].available,true);
  fs.mkdirSync(path.join(allowed,'overflow'));assert.equal((await env.legacy.listLegacyTransferCaches(env.filesDir))[0].available,false);
}));
test('1024 total entries and 2GiB metadata budgets are enforced before payload reads', () => using(async env => {
  const old=env.cache('rdp_transfer',{});for(let i=0;i<1024;i++)fs.writeFileSync(path.join(old,'f'+i),'');
  assert.equal((await env.legacy.listLegacyTransferCaches(env.filesDir))[0].available,false);
  fs.unlinkSync(path.join(old,'f1023'));const limit=await env.legacy.listLegacyTransferCaches(env.filesDir);assert.equal(limit[0].available,true);assert.equal(limit[0].fileCount,1023);
  const file=fs.openSync(path.join(old,'f0'),'r+');fs.ftruncateSync(file,2*1024**3);fs.closeSync(file);
  assert.equal((await env.legacy.listLegacyTransferCaches(env.filesDir))[0].available,true);
  fs.writeFileSync(path.join(old,'f1'),'x');assert.equal((await env.legacy.listLegacyTransferCaches(env.filesDir))[0].available,false);
  assert.equal(env.io.some(item=>item.op==='open'),false);
}));

(async()=>{for(const {name,run}of tests){await run();console.log('PASS '+name);}console.log(`PASS ${tests.length} legacy transfer cache recovery regressions`);})()
.catch(error=>{console.error(error);process.exitCode=1;});
