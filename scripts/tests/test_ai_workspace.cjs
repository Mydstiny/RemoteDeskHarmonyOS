/* Production ArkTS regression with controlled platform ports. No device acceptance claim. */
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require(process.env.AI_TYPESCRIPT_PATH || 'typescript');
const base=require('node:path').resolve(__dirname, '../../entry/src/main/ets/services/ai') + '/';
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return{promise,resolve,reject};};
function environment(){
  const modules=new Map(), timers=new Map();let tid=0,randomSeq=0;
  const account={owner:'fixtureOwner',generation:1,lifecycle:1};
  const access={assertCurrent(){},executable:()=>true,current:()=>true,subscribe:()=>()=>{}};
  const writes=[],reads=[];
  let readHook=async(method,params)=>method==='session.read'?{session:{id:params.sessionId,title:params.sessionId,archived:false},snapshot:{turns:[],nextCursor:null,status:'idle'},cursor:10}:method==='approval.list'?[]:{};
  let writeHook=async()=>({});
  const client={host:{id:'fixtureHost',backend:'codex'},account,ownerId:'fixtureClient',close(){},stopEvents(){},capability:()=>false,
    events:async()=>new Promise(()=>{}),read:(method,params)=>{reads.push({method,params});return readHook(method,params);},
    write:(method,params,session)=>{writes.push({method,params,session});return writeHook(method,params,session);}};
  const mocks={'./AiAccess':{AiAccess:{getInstance:()=>access}},'./AiBridgeClient':{AiBridgeClient:{connect:async()=>client}},
    '../EndpointAddressPolicy':{parseEndpointHost:()=>({ok:true}),parseEndpointServerIdentity:()=>({ok:true})},
    './AiTransport':{aiRandomId:()=> 'writer'+(++randomSeq)},'@kit.ArkTS':{util:{}},
    './AiLocalStore':{AiLocalStore:{getInstance:()=>({operations:async()=>[]})}}};
  function load(name){if(modules.has(name))return modules.get(name).exports;const module={exports:{}};modules.set(name,module);
    const source=ts.transpileModule(fs.readFileSync(base+name+'.ets','utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
    vm.runInNewContext('(function(require,module,exports){'+source+'\n})',{Promise,Map,Set,Array,Object,JSON,Date,Number,Error,
      setInterval:fn=>{timers.set(++tid,fn);return tid;},clearInterval:id=>timers.delete(id),setTimeout,clearTimeout})(key=>mocks[key]||load(key.slice(2)),module,module.exports);
    return module.exports;
  }
  const c=new(load('AiWorkspaceController').AiWorkspaceController)();c.client=client;c.sessionId='A';c.projectId='project';
  return{load,c,client,timers,writes,reads,onRead(fn){readHook=fn;},onWrite(fn){writeHook=fn;}};
}
(async()=>{
  {
    const e=environment(),pending=deferred();e.onWrite(async method=>method==='lease.acquire'?await pending.promise:{});
    const acquire=e.c.acquire();await e.c.selectSession('B');pending.resolve({lease:'leaseA',expires:Date.now()+90000});await assert.rejects(acquire,/AI_CONNECTION_CLOSED/);
    assert.equal(e.c.sessionId,'B');assert.equal(e.c.lease,'');assert.ok(e.writes.some(call=>call.method==='lease.release'&&call.params.sessionId==='A'));e.c.close();
    console.log('PASS late acquire(A) does not install lease in B and releases original A');
  }
  {
    const e=environment(),pending=deferred();e.c.lease='leaseA';e.c.leaseExpires=Date.now()+90000;
    e.onWrite(async()=>await pending.promise);const release=e.c.release();
    e.c.sessionId='B';e.c.lease='leaseB';e.c.leaseExpires=Date.now()+90000;
    e.load('AiLifecycle').AiLifecycle.claim('fixtureHost:B','fixtureClient');pending.resolve({released:true});await release;
    assert.equal(e.c.lease,'leaseB');assert.equal(e.load('AiLifecycle').AiLifecycle.claim('fixtureHost:B','otherClient'),false);e.c.close();
    console.log('PASS late release(A) preserves B lease and local writer');
  }
  {
    const e=environment(),pending=deferred();e.onRead(async(method,params)=>method==='diff.read'?await pending.promise:method==='session.read'?{session:{id:params.sessionId,title:params.sessionId},snapshot:{turns:[],status:'idle'},cursor:10}:[]);
    const diff=e.c.loadDiff();await e.c.selectSession('B');pending.resolve({available:true,diff:'A-only-diff'});await assert.rejects(diff,/AI_CONNECTION_CLOSED/);
    assert.equal(e.c.sessionId,'B');assert.equal(e.c.diff,'');e.c.close();
    console.log('PASS late diff(A) never appears in B');
  }
  {
    const e=environment();e.onRead(async(_method,params)=>({session:{id:'A',title:'A'},snapshot:{status:'idle',turns:[{id:params.cursor?'oldTurn':'newTurn',items:[{id:params.cursor?'old':'new',type:'agentMessage',text:params.cursor?'old text':'new text'}]}],nextCursor:params.cursor?null:'older'},cursor:10}));
    await e.c.snapshot(false);await e.c.snapshot(true);
    assert.deepEqual(Array.from(e.c.transcript.items,x=>x.id),['old','new']);e.c.close();
    console.log('PASS Codex older page precedes latest messages');
  }
  {
    const e=environment();e.c.transcript.codexItem({id:'message',type:'agentMessage',text:'Hello'},'turn','running');
    e.onRead(async()=>({snapshot:{turns:[{id:'turn',items:[{id:'message',type:'agentMessage',text:'Hello'}]}]}}));
    await e.c.refreshLiveSnapshot(0);await e.c.refreshLiveSnapshot(0);
    assert.equal(e.c.transcript.items[0].text,'Hello');e.c.close();
    console.log('PASS authoritative live snapshots upsert stable Codex items without delta duplication');
  }
  {
    const e=environment(),t=new(e.load('AiTranscript').AiTranscript)();
    const events=[0,1,2,3].map(seq=>({seq,time:seq,type:'user/message',data:{content:[{type:'text',text:'message'+seq}]},surfaceOp:'append'}));
    events.push({seq:4,time:4,type:'user/message',data:{content:[{type:'text',text:'summary1'}]},surfaceOp:{op:'replace',start:0,end:1},sourceEventSeqs:[0,1]});
    events.push({seq:5,time:5,type:'user/message',data:{content:[{type:'text',text:'summary2'}]},surfaceOp:{op:'replace',start:4,end:3},sourceEventSeqs:[4,2,3]});
    // Expected sequence independently verified against DSH 0.3.0 host's native foldSurface.
    if (process.env.AI_DSH_SURFACE_PATH) {
      const {foldSurface}=await import(require('node:url').pathToFileURL(process.env.AI_DSH_SURFACE_PATH).href);
      assert.deepEqual(foldSurface(events).nodes,[5]);
    }
    events.forEach(event=>t.dshEvent(event));
    assert.deepEqual(Array.from(t.items,x=>x.id),['dsh:5']);
    console.log('PASS DSH chained replacement equals official native surface [5]');
  }
  {
    const e=environment();e.c.projects=[{id:'privateProject'}];e.c.sessions=[{id:'privateSession'}];e.c.models=[{name:'privateModel'}];e.c.title='privateTitle';e.c.allowed=true;e.c.close();
    assert.equal(e.c.projects.length+e.c.sessions.length+e.c.models.length,0);assert.equal(e.c.title+e.c.projectId+e.c.sessionId,'');assert.equal(e.c.allowed,false);
    console.log('PASS close clears account-derived projects, sessions, models, title and selection');
  }
  {
    const e=environment(),pending=deferred();e.c.transcript.codexItem({id:'new1',type:'agentMessage',text:'new1'},'newTurn');e.c.historyCursor='older';
    e.onRead(async()=>await pending.promise);const older=e.c.snapshot(true);
    e.c.transcript.codexItem({id:'new2',type:'agentMessage',text:'new2'},'newestTurn');
    pending.resolve({session:{id:'A'},snapshot:{turns:[{id:'oldTurn',items:[{id:'old',type:'agentMessage',text:'old'}]}],nextCursor:null}});await older;
    assert.deepEqual(Array.from(e.c.transcript.items,x=>x.id),['old','new1','new2']);e.c.close();
    console.log('PASS older pagination preserves concurrent live item chronology');
  }
  {
    const e=environment();e.onRead(async(method)=>method==='session.items'?{data:[{id:'afterPage',type:'agentMessage',text:'visible output'}],nextCursor:null}:{snapshot:{turns:[{id:'turn',items:[],nextCursor:'itemPage'}]}});
    await e.c.refreshLiveSnapshot(0);assert.equal(e.c.transcript.items.length,1);assert.equal(e.reads.some(call=>call.method==='session.items'),true);e.c.close();
    console.log('PASS live snapshot follows item pagination and renders its output');
  }
  {
    const e=environment(),first=deferred(),second=deferred();let count=0,remoteLease='';
    e.onWrite(async method=>{if(method==='lease.acquire'){remoteLease='sameToken';return await(++count===1?first.promise:second.promise);}if(method==='lease.release'){remoteLease='';return{released:true};}return{};});
    const old=e.c.acquire();await e.c.selectSession('B');await e.c.selectSession('A');await assert.rejects(e.c.acquire(),/LEASE_BUSY/);
    assert.equal(count,1);
    first.resolve({lease:'sameToken',expires:Date.now()+90000});await assert.rejects(old,/AI_CONNECTION_CLOSED/);
    const newer=e.c.acquire();second.resolve({lease:'sameToken',expires:Date.now()+90000});await newer;
    assert.equal(e.c.lease,'sameToken');assert.equal(remoteLease,'sameToken');assert.equal(e.load('AiLifecycle').AiLifecycle.claim('fixtureHost:A','otherClient'),false);e.c.close();
    console.log('PASS A-B-A reacquire stays blocked until stale ownership settles; new lease survives');
  }
})().catch(error=>{console.error(error);process.exitCode=1;});
