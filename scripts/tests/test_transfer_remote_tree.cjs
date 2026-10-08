const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require(process.env.TRANSFER_TYPESCRIPT_PATH||'typescript'),root=path.resolve(__dirname,'../../entry/src/main/ets/services');
function load(name){const module={exports:{}};vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root,name+'.ets'),'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,{module,exports:module.exports,require:id=>load(id.replace('./',''))});return module.exports;}
const {collectRemoteTransferTree:collect,sameRemoteTransferDirectory:same,remoteTransferTreeFromFiles:fromFiles}=load('TransferRemoteTreePolicy');
const tests=[],test=(name,run)=>tests.push({name,run}),file=(name,size=0,type=4)=>({name,size,type,modifiedTime:1});
test('retains empty directories and zero-byte files in one bounded logical tree',async()=>{
 const tree=await collect('/root','root',async p=>({path:p,entries:p==='/root'?[file('empty',0,0),file('zero')]:[]}),()=>true);
 assert.deepEqual(Array.from(tree.items,i=>i.relativePath),['root','root/empty','root/zero']);assert.equal(tree.totalBytes,0);
});
test('case and Unicode collisions are detected before transfer',async()=>{
 for(const names of [['a','A'],['é','e\u0301']]) await assert.rejects(()=>collect('/root','root',async p=>({path:p,entries:names.map(n=>file(n))}),()=>true),/collision/);
});
test('remote symlink and traversal entries never start child reads',async()=>{
 for(const entry of [file('link',0,1),file('../escape')]){let calls=0;await assert.rejects(()=>collect('/root','root',async p=>{calls++;return {path:p,entries:[entry]};},()=>true));assert.equal(calls,1);}
});
test('wrong directory response and post-await owner loss reject stale enumeration',async()=>{
 await assert.rejects(()=>collect('/root','root',async()=>({path:'/other',entries:[]}),()=>true),/unconfirmed/);
 let current=true;await assert.rejects(()=>collect('/root','root',async p=>{current=false;return {path:p,entries:[]};},()=>current),/cancelled/);
});
test('item, depth and aggregate byte budgets are enforced during preflight',async()=>{
 await assert.rejects(()=>collect('/root','root',async p=>({path:p,entries:Array.from({length:1024},(_,i)=>file('f'+i))}),()=>true),/count/);
 await assert.rejects(()=>collect('/root','root',async p=>({path:p,entries:[file('next',0,0)]}),()=>true),/depth/);
 await assert.rejects(()=>collect('/root','root',async p=>({path:p,entries:[file('a',2147483648),file('b',1)]}),()=>true),/size/);
});
test('Windows paths normalize separators/case while Unix remains case sensitive',()=>{
 assert.equal(same('C:\\Root\\','c:/root'),true);assert.equal(same('/Root','/root'),false);
 const {joinRemoteTransferPath:join}=load('TransferRemotePathPolicy');
 for(const name of ['NUL','CON.txt','LPT1','name.','name '])assert.equal(join('C:\\',name),'');
});
test('a recursive listing becomes the same tree, with the folders its files live in',()=>{
 const tree=fromFiles('/root','root',{path:'/root',entries:[file('a.txt',3),file('sub/b.txt',4),file('sub/deep/c.txt',5),file('link',0,5)]});
 assert.deepEqual(Array.from(tree.items,i=>i.relativePath),['root','root/a.txt','root/sub','root/sub/b.txt','root/sub/deep','root/sub/deep/c.txt']);
 assert.equal(tree.totalBytes,12);assert.equal(tree.items[2].entry.type,0);assert.equal(tree.items[3].path,'/root/sub/b.txt');
 const windows=fromFiles('C:\\Data','Data',{path:'C:\\Data',entries:[file('x/y.txt',1)]});
 assert.equal(windows.items[2].path,'C:\\Data\\x\\y.txt');
 for(const bad of ['../x','a//b','a/./b']) assert.throws(()=>fromFiles('/root','root',{path:'/root',entries:[file(bad,1)]}),/collision/);
 assert.throws(()=>fromFiles('/root','root',{path:'/root',entries:[file('A',1),file('a',1)]}),/collision/);
 assert.throws(()=>fromFiles('/root','root',{path:'/root',entries:Array.from({length:1024},(_,i)=>file('f'+i))}),/count/);
});
(async()=>{for(const t of tests){await t.run();console.log('PASS '+t.name);}console.log(tests.length+' remote tree tests passed');})().catch(e=>{console.error(e);process.exitCode=1;});
