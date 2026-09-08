/* Production bounded control-job client; no device/network acceptance implied. */
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require(process.env.TRANSFER_TYPESCRIPT_PATH||'typescript');
const source=fs.readFileSync(path.resolve(__dirname,'../../entry/src/main/ets/services/RustDeskTransferClient.ets'),'utf8');
function fixture(){
 const state={now:0,current:true,kind:'list',status:2,auth:[],release:[],cancel:0,steps:0,afterWait:null};
 const module={exports:{}};
 class FakeDate extends Date {static now(){return state.now;}}
 vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,
  {module,exports:module.exports,Date:FakeDate,setTimeout:fn=>{state.now+=200;state.steps++;state.afterWait?.();fn();}});
 const lease={sessionId:7,nativeGeneration:11};
 const loader={requestSessionRemoteDirectory:()=>29,createSessionRemoteDirectory:()=>29,
  getSessionFileTransfer:(sid,gen,id)=>{assert.deepEqual([sid,gen,id],[7,11,29]);return {transferId:29,rustdeskTransferState:state.status};},
  getSessionTransferAuthentication:()=>({transferId:29,challengeId:87,state:1}),
  getSessionRemoteDirectory:()=>({path:'/selected',entries:[]}),
  getSessionTransferResult:()=>({operationKind:4,remoteOperationAcknowledged:state.ack}),
  cancelSessionFileTransfer:()=>{state.cancel++;},releaseSessionFileTransfer:(...args)=>state.release.push(args)};
 const client=new module.exports.RustDeskTransferClient(loader,lease,()=>state.current,s=>state.auth.push(s));
 return {client,state,loader};
}
const tests=[],test=(name,run)=>tests.push({name,run});
test('list exposes job-scoped auth then releases exact terminal owner',async()=>{
 const f=fixture();f.state.afterWait=()=>{f.state.status=6;};
 assert.equal((await f.client.list('/selected')).path,'/selected');
 assert.ok(f.state.auth.length>0);assert.deepEqual(f.state.release,[[7,11,29]]);assert.equal(f.state.cancel,0);
});
test('owner change cancels and never returns another session directory',async()=>{
 const f=fixture();f.state.afterWait=()=>{f.state.current=false;f.state.status=5;};
 assert.equal(await f.client.list('/selected'),null);assert.equal(f.state.cancel,1);assert.equal(f.state.release.length,1);
});
test('unobservable job is retained rather than falsely released as drained',async()=>{
 const f=fixture();f.state.status=0;assert.equal(await f.client.list('/selected'),null);
 assert.equal(f.state.cancel,1);assert.equal(f.state.release.length,0);
});
test('missing terminal response stops within operation plus cancellation deadlines',async()=>{
 const f=fixture();assert.equal(await f.client.list('/selected'),null);
 assert.equal(f.state.now,125000);assert.equal(f.state.cancel,1);assert.equal(f.state.release.length,0);
});
test('mkdir requires matching operation acknowledgement, not sender completion alone',async()=>{
 for(const ack of [false,true]){const f=fixture();f.state.status=6;f.state.ack=ack;
  assert.equal(await f.client.mkdir('/selected/new'),ack);assert.equal(f.state.release.length,1);}
});
(async()=>{for(const t of tests){await t.run();console.log('PASS '+t.name);}console.log(tests.length+' control client tests passed');})().catch(e=>{console.error(e);process.exitCode=1;});
