/* Actual service, RustDesk clipboard client and publication registry; protocol/file/OS boundaries mocked.
 * Tests orchestration and source fences, not device clipboard interoperability. */
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require(process.env.TRANSFER_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const tests = [], test = (name, run) => tests.push({name, run});
function fixture(protocol = 'rdp', names = ['a.txt', 'empty.txt'], installWriter = true) {
 const s = { current: true, sequence: 9, now: 0, writes: 0, count: 2, boardData: null, batches: [], starts: 0,
  cancels: 0, releases: 0, commits: 0, outcomes: [], stages: [], ticks: null, rdpStatus: null, rustStatus: null,
  commitHook: null, finalizeHook: null, boardHook: null, readHook: null, beginHook: null, admitted: true, nextId: 31 };
 s.entries = names.map((name,index)=>({index,relativeName:name,directory:false,sizeKnown:true,size:index===0?3:0}));
 class FakeDate extends Date { static now() { return s.now; } }
 function load(name, deps = {}) {
  const module = { exports:{} };
  const output = ts.transpileModule(fs.readFileSync(path.join(root,'entry/src/main/ets/services/'+name+'.ets'),'utf8'),
   {compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}});
  vm.runInNewContext(output.outputText,{module,exports:module.exports,Date:FakeDate,
   setTimeout:fn=>{s.now+=250;s.ticks?.();fn();},require:id=>{
    if(id in deps)return deps[id];throw Error('Unexpected '+name+' import '+id);
   }},{filename:name+'.ets'});
  return module.exports;
 }
 class Batch {
  constructor() { this.id='batch'+s.batches.length;this.directory='/cache/'+this.id;this.artifacts=[];
   this.holds=new Set(['creator']);this.pubs=new Set();this.retained=0;this.aborts=0;s.batches.push(this); }
  release() { this.holds.delete('creator'); }
  retainPublication(id) { this.pubs.add(id); }
  releasePublication(id) { return this.pubs.delete(id); }
  getArtifacts() { return this.artifacts.slice(); }
  async createDirectory(name,guard) { assert.ok(guard());this.artifacts.push({id:name,name:name.split('/').pop(),relativePath:name,
   path:this.directory+'/'+name,size:0,directory:true,sha256:''}); }
  async createNativeReceiveDirectory(guard) { s.beginHook?.();assert.ok(guard());return this.slot(guard); }
  async beginNativeReceiveRelative(name,size,guard) { s.beginHook?.();assert.ok(guard());return this.slot(guard,name,size); }
  slot(guard,name,size) {
   return {fd:19,commit:async expected=>{
    s.commitHook?.(s.commits);assert.ok(guard());s.commits++;
    const values=name?[{index:s.commits,relativeName:name,directory:false,size}]:expected.map(e=>({...e,relativeName:e.relativeName.split('/').slice(2).join('/')}));
    for(const e of values)this.artifacts.push({id:String(e.index),name:e.relativeName.split('/').pop(),relativePath:e.relativeName,
     path:this.directory+'/'+e.relativeName,size:e.size,directory:e.directory,sha256:e.directory?'':'a'.repeat(64)});
    await Promise.resolve();assert.ok(guard());return name?this.artifacts.at(-1):this.artifacts.slice();
   },abort:async()=>{this.aborts++;},retainPartial:async()=>{this.retained++;this.holds.add('unknown-writer');}};
  }
 }
 const artifacts = {TransferArtifactBatch:Batch,TRANSFER_FILE_LIMIT_BYTES:2*1024**3,transferScopeKey:()=> 'scope'};
 const registryModule=load('TransferArtifactPublicationService',{'@kit.ArkTS':{util:{generateRandomUUID:()=>String(++s.nextId)}},'./TransferArtifactStore':artifacts});
 const registry=registryModule.TransferArtifactPublicationService.getInstance();
 const clients=load('RustDeskClipboardClient');
 function pasteData(uri) {const d={records:[uri],tag:'',getProperty(){return {tag:this.tag};},setProperty(p){this.tag=p.tag;},
  getTag(){return this.tag;},getRecordCount(){return this.records.length;},addRecord(_mime,uri){this.records.push(uri);}};return d;}
 const board={setDataSync(data){s.writes++;s.boardData=data;s.count++;s.boardHook?.();},getChangeCount:()=>s.count,
  getDataSync(){s.readHook?.();return s.boardData;}};
 const pasteboard={MIMETYPE_TEXT_URI:'text/uri',createData:(_mime,uri)=>pasteData(uri),getSystemPasteboard:()=>board};
 const service={init:()=>true,enqueue(options,runner){
  if(!s.admitted)return {accepted:false,result:Promise.resolve({stage:'failed',evidence:'none'})};
  const control={taskId:'task',attemptId:1,isCurrent:()=>s.current&&options.isCurrent(),isCancellationRequested:()=>!s.current,
   update:p=>{s.progress=p;return control.isCurrent();},onCancel:fn=>{s.cancelCallback=fn;},
   enterCommit:async()=>{await Promise.resolve();return control.isCurrent();}};
  const result=Promise.resolve().then(()=>runner(control)).then(async outcome=>{
   s.outcomes.push(outcome);await options.onFinalize?.(outcome);s.finalizeHook?.();return outcome;});
  return {accepted:true,result};
 }};
 const snapshot=()=>({sequence:s.sequence,kind:'files',ready:true,text:''});
 const rustEntries=()=>s.entries.map(e=>({index:e.index,name:e.relativeName,isDirectory:e.directory,size:e.size,modifiedTime:12}));
 const native={getSessionClipboardSnapshot:snapshot,getSessionRdpClipboardFiles:()=>({sequence:9,state:'ready',streamSupported:true,
  totalKnown:true,totalBytes:s.entries.reduce((sum,e)=>sum+e.size,0),entries:s.entries}),requestSessionRdpClipboardFiles:()=>true,
  startSessionRdpClipboardReceive:(sid,gen,seq,indices,fd)=>{assert.deepEqual([sid,gen,seq,fd],[7,11,9,19]);s.starts++;return 31;},
  getSessionRdpClipboardReceive:()=>s.rdpStatus?s.rdpStatus():({taskId:31,sequence:9,phase:'completed',transferredBytes:s.entries.reduce((sum,e)=>sum+e.size,0),
   totalBytes:s.entries.reduce((sum,e)=>sum+e.size,0),totalKnown:true,artifacts:s.entries.map(e=>({...e,relativeName:'receive-31/files/'+e.relativeName}))}),
  cancelSessionRdpClipboardReceive:()=>{s.cancels++;return true;},releaseSessionRdpClipboardReceive:()=>{s.releases++;return true;},
  getSessionRustDeskFileClipboard:()=>({revision:s.sequence,state:3,capable:true,enabled:true,entryCount:s.entries.length}),
  getSessionRustDeskClipboardEntries:rustEntries,receiveSessionRustDeskClipboardFile:(_sid,_gen,_seq,index)=>{s.index=index;s.starts++;return 31;},
  getSessionFileTransfer:()=>s.rustStatus?s.rustStatus():({transferId:31,rustdeskTransferState:6,transferredBytes:s.entries[s.index].size}),
  cancelSessionFileTransfer:()=>{s.cancels++;return true;},releaseSessionFileTransfer:()=>{s.releases++;return true;}};
 const api=load('PcRemoteClipboardFileService',{'@kit.BasicServicesKit':{deviceInfo:{deviceType:'2in1'},pasteboard},
  '@kit.CoreFileKit':{fileUri:{getUriFromPath:p=>'file://'+p}},'./TransferArtifactStore':artifacts,
  './TransferArtifactPublicationService':registryModule,'./RustDeskClipboardClient':clients,
  './ManagedTransferTaskService':{ManagedTransferTaskService:{getInstance:()=>service}}});
 const lease={accountScopeId:'account',accountGeneration:1,hostId:'host',routeIdentity:'route',windowId:'window',
  protocol,sessionId:7,nativeGeneration:11,attemptId:2};
 const receiver=new api.PcRemoteClipboardFileService(native,lease,{filesDir:'/files'});
 if(installWriter)receiver.setAuthorityWriter(operation=>operation());
 receiver.setStatusListener(state=>{s.stages.push(state);});
 return {s,receiver,native,registry,board,lease,tag:'remotedesk:remote-text:v1:4:9',
  run(){return receiver.receiveRemote(snapshot(),()=>s.current,'remotedesk:remote-text:v1:4:9');}};
}
for(const protocol of ['rdp','rustdesk']) {
 test(protocol+' publishes once only after entire real-file batch is complete and retains system lease',async()=>{
  const f=fixture(protocol);assert.equal(await f.run(),true);const b=f.s.batches[0];
  assert.equal(f.s.writes,1);assert.equal(f.s.boardData.records.length,2);assert.equal(b.artifacts.length,2);
  assert.equal(b.holds.size,0);assert.equal(b.pubs.size,1);assert.equal(f.s.boardData.tag,f.tag);assert.equal(f.receiver.getStatus().phase,'ready');
  const starts=f.s.starts;assert.equal(await f.run(),false);assert.equal(f.s.starts,starts);assert.equal(f.s.writes,1);
  f.registry.observeSystemClipboard('local-new',f.s.count+1);assert.equal(b.pubs.size,0);
 });
 test(protocol+' source change during receive cancels exact native worker without publishing',async()=>{
  const f=fixture(protocol);let polls=0;
  if(protocol==='rdp')f.s.rdpStatus=()=>({taskId:31,sequence:9,phase:polls++===0?'receiving':'cancelled',transferredBytes:0});
  else f.s.rustStatus=()=>({transferId:31,rustdeskTransferState:polls++===0?2:5,transferredBytes:0});
  f.s.ticks=()=>{f.s.sequence=10;};assert.equal(await f.run(),false);assert.equal(f.s.writes,0);
  assert.equal(f.s.cancels,1);assert.equal(f.s.releases,1);assert.equal(f.s.batches[0].aborts,1);
 });
 test(protocol+' unknown native cancellation keeps partial writer lease and never releases by timeout',async()=>{
  const f=fixture(protocol);
  if(protocol==='rdp')f.s.rdpStatus=()=>({taskId:31,sequence:9,phase:'receiving',transferredBytes:0});
  else f.s.rustStatus=()=>({transferId:31,rustdeskTransferState:2,transferredBytes:0});
  f.s.ticks=()=>{f.s.current=false;};assert.equal(await f.run(),false);assert.equal(f.s.writes,0);
  assert.equal(f.s.releases,0);assert.equal(f.s.batches[0].retained,1);assert.ok(f.s.batches[0].holds.has('unknown-writer'));
  assert.equal(f.s.outcomes[0].stage,'paused');
 });
 test(protocol+' source replacement during metadata commit prevents URI publication',async()=>{
  const f=fixture(protocol);f.s.commitHook=()=>{f.s.sequence=10;};assert.equal(await f.run(),false);
  assert.equal(f.s.writes,0);assert.equal(f.receiver.getStatus().phase,'cancelled');
 });
 test(protocol+' directories are completely cached without flattened or fake URI success',async()=>{
  const f=fixture(protocol,['Root','Root/a.txt']);f.s.entries[0].directory=true;f.s.entries[0].size=0;f.s.entries[1].size=3;
  assert.equal(await f.run(),false);assert.equal(f.s.writes,0);assert.equal(f.receiver.getStatus().phase,'cached');
  assert.equal(f.receiver.getStatus().error,'directory_requires_export');assert.equal(f.s.batches[0].artifacts.length,2);
 });
}
test('RDP partial terminal artifact list cannot authorize a complete clipboard',async()=>{
 const f=fixture();f.s.rdpStatus=()=>({taskId:31,sequence:9,phase:'completed',transferredBytes:3,totalBytes:3,totalKnown:true,
  artifacts:[{index:0,relativeName:'receive-31/files/a.txt',directory:false,size:3}]});
 assert.equal(await f.run(),false);assert.equal(f.s.writes,0);assert.equal(f.s.commits,0);assert.equal(f.s.releases,1);
});
test('RustDesk later file failure preserves earlier complete cache but never publishes a subset',async()=>{
 const f=fixture('rustdesk');f.s.rustStatus=()=>({transferId:31,rustdeskTransferState:f.s.index===0?6:4,transferredBytes:f.s.index===0?3:0});
 assert.equal(await f.run(),false);assert.equal(f.s.writes,0);assert.equal(f.s.batches[0].artifacts.length,1);
 const starts=f.s.starts;assert.equal(await f.run(),false);assert.equal(f.s.starts,starts);
});
test('a throwing OS confirmation retains possibly published files and never reports ready',async()=>{
 const f=fixture();f.s.readHook=()=>{throw Error('no read permission');};assert.equal(await f.run(),false);
 assert.equal(f.s.writes,1);assert.equal(f.s.batches[0].pubs.size,1);assert.equal(f.receiver.getStatus().phase,'failed');
});
test('local clipboard replacement while managed finalization yields cannot return success',async()=>{
 const f=fixture();f.s.finalizeHook=()=>{f.s.count++;f.s.boardData.tag='new-local';};assert.equal(await f.run(),false);
 assert.equal(f.s.writes,1);assert.equal(f.receiver.getStatus().phase,'cancelled');assert.equal(f.s.batches[0].pubs.size,1);
});
test('source changes before synchronous clipboard publication release only unpublished registration',async()=>{
 const f=fixture();f.receiver.setStatusListener(state=>{if(state.phase==='publishing')f.s.current=false;});
 assert.equal(await f.run(),false);assert.equal(f.s.writes,0);assert.equal(f.s.batches[0].pubs.size,0);
});
test('single sequence failures are deduplicated; a new genuine source event can be attempted',async()=>{
 const f=fixture();f.s.admitted=false;assert.equal(await f.run(),false);assert.equal(f.s.batches.length,1);
 assert.equal(await f.run(),false);assert.equal(f.s.batches.length,1);f.s.sequence=10;
 f.native.getSessionRdpClipboardFiles=()=>({sequence:10,state:'failed',entries:[],totalBytes:0});
 assert.equal(await f.run(),false);assert.equal(f.receiver.getStatus().error,'invalid_offer');
});
test('RDP case and Unicode hierarchy aliases fail before native receive admission',async()=>{
 for(const names of [['Root/a','root/b'],['é/a','e\u0301/b'],['a','a/b']]){
  const f=fixture('rdp',names);assert.equal(await f.run(),false);assert.equal(f.s.starts,0);assert.equal(f.s.writes,0);
 }
});
test('invalid tag and oversized offer never admit a receiver',async()=>{
 const f=fixture();assert.equal(await f.receiver.receiveRemote({sequence:9,kind:'files'},()=>true,'untrusted'),false);assert.equal(f.s.starts,0);
 f.s.entries[0].size=2*1024**3+1;assert.equal(await f.run(),false);assert.equal(f.s.starts,0);
});
test('disposing a service fences pending work and removes observer callbacks',async()=>{
 const f=fixture();f.s.beginHook=()=>f.receiver.dispose();assert.equal(await f.run(),false);assert.equal(f.s.writes,0);assert.equal(f.s.starts,0);
});
test('missing native authority writer fails closed while retaining received files in cache',async()=>{
 const f=fixture('rdp',['a.txt'],false);assert.equal(await f.run(),false);assert.equal(f.s.writes,0);
 assert.equal(f.s.batches[0].artifacts.length,1);assert.equal(f.s.batches[0].pubs.size,0);
});
test('authority handoff between preparation and publication denies every system side effect',async()=>{
 const f=fixture();f.receiver.setAuthorityWriter(()=>false);assert.equal(await f.run(),false);
 assert.equal(f.s.writes,0);assert.equal(f.s.batches[0].pubs.size,0);assert.equal(f.receiver.getStatus().error,'publication_failed');
});
test('system write and immediate confirmation execute inside the synchronous authority callback',async()=>{
 const f=fixture();let locked=false;f.receiver.setAuthorityWriter(operation=>{locked=true;try{return operation();}finally{locked=false;}});
 f.s.boardHook=()=>assert.equal(locked,true);let reads=0;f.s.readHook=()=>{if(reads++===0)assert.equal(locked,true);};
 assert.equal(await f.run(),true);assert.equal(locked,false);
});
test('status observer receives only stage counters and fixed error enum',async()=>{
 const f=fixture();await f.run();for(const s of f.s.stages)assert.deepEqual(Object.keys(s).sort(),['error','phase','totalBytes','writtenBytes']);
});
(async()=>{for(const t of tests){await t.run();console.log('PASS '+t.name);}console.log(tests.length+' PC remote clipboard file checks passed');})().catch(e=>{console.error(e);process.exitCode=1;});
