const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require(process.env.TRANSFER_TYPESCRIPT_PATH||'typescript');
const source=fs.readFileSync(path.resolve(__dirname,'../../entry/src/main/ets/services/RustDeskClipboardClient.ets'),'utf8');
function fixture(){
 const s={now:0,current:true,publication:1,pubid:23,drained:false,transfer:2,transferid:31,bytes:0,revokes:0,cancels:0,releases:[],wait:null,revision:9,reads:0};
 const module={exports:{}};class FakeDate extends Date {static now(){return s.now;}}
 vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,
  {module,exports:module.exports,Date:FakeDate,setTimeout:fn=>{s.now+=250;s.wait?.();fn();}});
 const entry={index:0,name:'a.txt',isDirectory:false,size:3,modifiedTime:12};
 const native={configureSessionRustDeskFileClipboard:()=>true,getSessionRustDeskFileClipboard:()=>({revision:s.revision,state:3,capable:true,enabled:true,entryCount:1}),
 getSessionRustDeskClipboardEntries:()=>{s.reads++;return [entry];},publishSessionRustDeskClipboardFiles:()=>23,
 getSessionRustDeskClipboardPublication:(sid,gen,id)=>{assert.deepEqual([sid,gen,id],[7,11,23]);return {publicationId:s.pubid,state:s.publication,drained:s.drained};},
 revokeSessionRustDeskClipboardPublication:()=>{s.revokes++;},receiveSessionRustDeskClipboardFile:()=>31,
 getSessionFileTransfer:(sid,gen,id)=>{assert.deepEqual([sid,gen,id],[7,11,31]);return {transferId:s.transferid,rustdeskTransferState:s.transfer,transferredBytes:s.bytes};},
 cancelSessionFileTransfer:()=>{s.cancels++;},releaseSessionFileTransfer:(...args)=>s.releases.push(args)};
 const control={isCurrent:()=>s.current,onCancel:cb=>{s.cancelCallback=cb;},update:p=>{s.progress=p;}};
 return {s,entry,native,control,client:new module.exports.RustDeskClipboardClient(native,7,11,()=>s.current)};
}
const tests=[],test=(name,run)=>tests.push({name,run});
test('does not paste before peer-ready publication',async()=>{const f=fixture();f.s.wait=()=>{f.s.publication=2;};const result=await f.client.publish([]);assert.equal(result.ready,true);assert.equal(f.s.now,250);assert.equal(f.s.revokes,0);});
test('ownership loss revokes exact old publication and waits for actual drain',async()=>{const f=fixture();f.s.wait=()=>{f.s.current=false;f.s.publication=5;f.s.drained=true;};const result=await f.client.publish([]);assert.equal(result.ready,false);assert.equal(result.drained,true);assert.equal(f.s.revokes,1);});
test('publication timeout plus revoke deadline is bounded and retains unknown data',async()=>{const f=fixture();const result=await f.client.publish([]);assert.equal(result.ready,false);assert.equal(result.drained,false);assert.equal(f.s.now,15000);});
test('mismatched publication cannot authorize paste or cleanup',async()=>{const f=fixture();f.s.pubid=99;f.s.publication=2;f.s.drained=true;const result=await f.client.publish([]);assert.equal(result.ready,false);assert.equal(result.drained,false);});
test('descriptor acquisition cannot return an old revision',()=>{const f=fixture();f.native.getSessionRustDeskClipboardEntries=()=>{f.s.revision++;return [f.entry];};assert.equal(f.client.entries(9).length,0);});
test('untrusted descriptors reject paths, collisions and over-budget data',()=>{for(const name of ['../a','a/../b','/a','a\\b','a/','a.']){const f=fixture();f.entry.name=name;assert.equal(f.client.entries(9).length,0,name);}const f=fixture();f.entry.size=2147483649;assert.equal(f.client.entries(9).length,0);});
test('receive requires exact terminal byte count and releases captured transfer',async()=>{const f=fixture();f.s.transfer=6;f.s.bytes=3;const result=await f.client.receive(9,f.entry,10,f.control,8);assert.equal(result.outcome.stage,'completed');assert.equal(f.s.progress.writtenBytes,11);assert.deepEqual(f.s.releases,[[7,11,31]]);});
test('short terminal file is failed and never called verified',async()=>{const f=fixture();f.s.transfer=6;f.s.bytes=2;const result=await f.client.receive(9,f.entry,10,f.control,0);assert.equal(result.outcome.stage,'failed');assert.equal(result.outcome.evidence,'none');});
test('stale transfer slot cannot confirm completion or drain',async()=>{const f=fixture();f.s.transferid=99;f.s.transfer=6;f.s.bytes=3;const result=await f.client.receive(9,f.entry,10,f.control,0);assert.equal(result.outcome.stage,'paused');assert.equal(result.drained,false);assert.equal(f.s.releases.length,0);});
test('cancel ownership loss drains only captured worker',async()=>{const f=fixture();f.s.wait=()=>{f.s.current=false;f.s.transfer=5;};const result=await f.client.receive(9,f.entry,10,f.control,0);assert.equal(result.outcome.stage,'cancelled');assert.equal(result.drained,true);assert.equal(f.s.cancels,1);assert.deepEqual(f.s.releases,[[7,11,31]]);});
test('missing cancellation acknowledgement preserves partial after five seconds',async()=>{const f=fixture();f.s.wait=()=>{f.s.current=false;};const result=await f.client.receive(9,f.entry,10,f.control,0);assert.equal(result.outcome.stage,'paused');assert.equal(result.drained,false);assert.equal(f.s.now,5250);assert.equal(f.s.releases.length,0);});
(async()=>{for(const t of tests){await t.run();console.log('PASS '+t.name);}console.log(tests.length+' RustDesk clipboard client tests passed');})().catch(e=>{console.error(e);process.exitCode=1;});
