/* Executes exact page lease/start/stop methods. Host proof excludes device scheduling. */
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require(process.env.TRANSFER_TYPESCRIPT_PATH||'typescript');
const root=path.resolve(__dirname,'../..'),source=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/RemoteDesktop.ets'),'utf8');
const names=['transferRouteIdentity','captureTransferLease','clipboardSessionLeaseIsCurrent','withClipboardAuthority','startClipboardBridgeBestEffort','stopClipboardBridge','restartClipboardBridgeIfActiveForeground','publishClipboardForLease','waitClipboardPublication','publishContinuousLocalContent'];
const methods=names.map(name=>{const match=new RegExp('^  private (?:async )?'+name+'\\(','m').exec(source);assert.ok(match,name);const end=source.indexOf('\n  private ',match.index+1);assert.ok(end>match.index);return source.slice(match.index,end)});
const code=ts.transpileModule('export class Harness {\n'+methods.join('\n')+'\n}',{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
function fixture(){
 const state={scope:{ownerScopeId:'account',generation:2},owner:{sessionId:7,generation:11},claims:[],events:[],timers:[],token:0,authority:null,epoch:0,blockCommit:false,enabled:true,background:false,count:10,fileReads:0,failFileRead:false,fileOffers:0,fileOfferAccepted:true};
 const coordinator={isAuthorized:value=>value!==null&&value===state.authority,claimExplicit:lease=>state.authority={epoch:++state.epoch,lease},revoke:token=>{state.events.push('revoke-local');if(token===state.authority)state.authority=null;}};
 const module={exports:{}};
 vm.runInNewContext(code,{module,exports:module.exports,ClipboardCoordinator:{getInstance:()=>coordinator},AccountSessionCoordinator:{getInstance:()=>({currentScope:()=>state.scope})},rdpRouteIdentity:host=>'rdp:'+host.host,
  pasteboard:{MIMETYPE_TEXT_URI:'uri',getSystemPasteboard:()=>({getChangeCount:()=>state.count})},
  SystemClipboardFileProvider:class{async read(){state.fileReads++;if(state.failFileRead)throw Error('synthetic temporary error');return ['file://owned']}},
  util:{TextEncoder},Date,setTimeout:callback=>{state.timers.push(callback);return state.timers.length},hilog:{warn(){}}});
 const page=new module.exports.Harness();
 Object.assign(page,{connected:true,cleanupStarted:false,sessionId:7,connectAttemptId:3,hostId:'host',sessionWindowId:'window',harmonyShortcutCaptureOwner:'capture',sessionWindowActive:true,sessionWindowMinimized:false,
  pendingHost:{host:'rdp.invalid',protocol:'rdp'},currentProtocolName:()=> 'rdp',clipboardBridgeEnabledForSession:()=>state.enabled,currentAbilityBackgroundState:()=>state.background,currentSessionCapabilities:()=>({clipboardSend:{enabled:true}}),
  isDesktopDevice:true,continuousLocalFileCount:-1,continuousLocalAttemptCount:-1,continuousLocalAttempts:0,observeRustDeskLocalClipboardChange:async()=>{},continuousClipboardFilesAllowed:()=>true,transferSourcesFromUris:uris=>uris,offerRustDeskClipboardFiles:async()=>{state.fileOffers++;return state.fileOfferAccepted},
  clipboardBridge:null,clipboardAuthorityLease:null,clipboardAuthorization:null,clipboardAuthorityToken:0,clipboardBridgeStartGeneration:0,pcClipboardFiles:null,
  loader:{captureDisconnectIdentity:()=>({...state.owner}),claimSessionClipboardAuthority(sid,generation,replace){state.claims.push({sid,generation,replace});if(state.token&&!replace)return 0;return state.token=++state.epoch;},
   ownsSessionClipboardAuthority:(sid,generation,token)=>sid===state.owner.sessionId&&generation===state.owner.generation&&token>0&&token===state.token,
   revokeSessionClipboardAuthority:(_sid,_gen,token)=>{state.events.push('revoke-native');if(state.token===token)state.token=0;},
   withSessionClipboardAuthority(sid,gen,token,operation){if(state.blockCommit){state.token++;return false}return this.ownsSessionClipboardAuthority(sid,gen,token)&&operation()},
   publishSessionClipboard:()=>{state.events.push('publish');return {publicationId:1,state:2}}}});
 function authorize(){page.startClipboardBridgeBestEffort(7,3,true);return page.clipboardAuthorityLease}
 return {page,state,authorize};
}
const tests=[],test=(name,run)=>tests.push({name,run});
test('authorized live connection survives blur minimize background and render cleanup',()=>{
 const f=fixture(),lease=f.authorize();assert.equal(f.page.clipboardSessionLeaseIsCurrent(lease),true);
 f.page.sessionWindowActive=false;f.page.sessionWindowMinimized=true;f.state.background=true;f.page.cleanupStarted=true;
 assert.equal(f.page.clipboardSessionLeaseIsCurrent(lease),true);
});
test('every identity or authorization rollover fences the continuous connection',()=>{
 for(const mutate of [f=>f.state.scope.ownerScopeId='other',f=>f.state.scope.generation++,f=>f.page.hostId='other',f=>f.page.sessionWindowId='other',f=>f.page.sessionId++,f=>f.page.connectAttemptId++,f=>f.page.pendingHost.host='other',f=>f.state.owner.generation++,f=>f.state.token++,f=>f.state.enabled=false,f=>f.page.connected=false,f=>f.state.authority=null]){
  const f=fixture(),lease=f.authorize();mutate(f);assert.equal(f.page.clipboardSessionLeaseIsCurrent(lease),false);
 }
});
test('startup with persisted enabled setting cannot replace an existing native authority',()=>{
 const f=fixture();f.state.token=99;f.page.startClipboardBridgeBestEffort(7,3,true);
 assert.equal(f.state.claims.length,1);assert.equal(f.state.claims[0].replace,false);assert.equal(f.state.token,99);assert.equal(f.page.clipboardAuthorityLease,null);assert.equal(f.state.timers.length,0);
});
test('foreground restart does not claim authority or revive a superseded token',()=>{
 const f=fixture();f.page.restartClipboardBridgeIfActiveForeground();assert.equal(f.state.claims.length,0);
 f.authorize();const calls=f.state.claims.length,timers=f.state.timers.length;f.state.token++;
 f.page.restartClipboardBridgeIfActiveForeground();assert.equal(f.state.claims.length,calls);assert.equal(f.state.timers.length,timers);
});
test('explicit enable alone replaces authority and old work cannot commit afterward',()=>{
 const f=fixture(),old=f.authorize();f.page.startClipboardBridgeBestEffort(7,3,true,true);
 assert.equal(f.state.claims.at(-1).replace,true);assert.notEqual(f.page.clipboardAuthorityLease,old);assert.equal(f.page.clipboardSessionLeaseIsCurrent(old),false);
});
test('stop revokes both authorities before disposal and never leaves an attached bridge',()=>{
 const f=fixture();f.authorize();f.page.pcClipboardFiles={dispose:()=>f.state.events.push('dispose-files')};f.page.clipboardBridge={stopMonitoring:()=>f.state.events.push('stop-bridge')};
 f.page.stopClipboardBridge();assert.deepEqual(f.state.events,['revoke-local','revoke-native','dispose-files','stop-bridge']);assert.equal(f.page.clipboardAuthorityLease,null);assert.equal(f.state.token,0);
});
test('cross-runtime authority handoff between query and atomic submission blocks publication',async()=>{
 const f=fixture(),lease=f.authorize();f.state.blockCommit=true;
 assert.equal(await f.page.publishClipboardForLease(lease,'new text'),false);assert.equal(f.state.events.includes('publish'),false);
});
test('background text is admitted for the captured current authority',async()=>{
 const f=fixture(),lease=f.authorize();f.page.cleanupStarted=true;f.page.sessionWindowActive=false;f.state.background=true;
 assert.equal(await f.page.publishClipboardForLease(lease,'new text'),true);assert.deepEqual(f.state.events,['publish']);
});
test('transient file read failure can retry without checkpointing a failed event',async()=>{
 const f=fixture(),data={getRecordCount:()=>1,getRecord:()=>({mimeType:'uri'})},lease={protocol:'rustdesk'};
 f.state.failFileRead=true;assert.equal(await f.page.publishContinuousLocalContent(lease,{},()=>true,data),false);
 assert.equal(f.page.continuousLocalFileCount,-1);f.state.failFileRead=false;
 assert.equal(await f.page.publishContinuousLocalContent(lease,{},()=>true,data),true);
 assert.equal(f.state.fileReads,2);assert.equal(f.state.fileOffers,1);assert.equal(f.page.continuousLocalFileCount,10);
});
test('three failed file attempts terminate retry explicitly and new copy resets the budget',async()=>{
 const f=fixture(),data={getRecordCount:()=>1,getRecord:()=>({mimeType:'uri'})},lease={protocol:'rustdesk'};
 f.state.fileOfferAccepted=false;for(let i=0;i<3;i++)assert.equal(await f.page.publishContinuousLocalContent(lease,{},()=>true,data),false);
 assert.equal(await f.page.publishContinuousLocalContent(lease,{},()=>true,data),'unavailable');assert.equal(f.state.fileReads,3);
 assert.equal(f.page.continuousLocalFileCount,-1);f.state.count++;f.state.fileOfferAccepted=true;
 assert.equal(await f.page.publishContinuousLocalContent(lease,{},()=>true,data),true);assert.equal(f.state.fileReads,4);
});
test('successful file checkpoint avoids duplicate offers while preserving new copy events',async()=>{
 const f=fixture(),data={getRecordCount:()=>1,getRecord:()=>({mimeType:'uri'})},lease={protocol:'rustdesk'};
 assert.equal(await f.page.publishContinuousLocalContent(lease,{},()=>true,data),true);
 assert.equal(await f.page.publishContinuousLocalContent(lease,{},()=>true,data),true);assert.equal(f.state.fileOffers,1);
 f.state.count++;assert.equal(await f.page.publishContinuousLocalContent(lease,{},()=>true,data),true);assert.equal(f.state.fileOffers,2);
});
(async()=>{for(const {name,run}of tests){await run();console.log('PASS '+name)}console.log(`${tests.length} continuous clipboard page tests passed`);})().catch(error=>{console.error(error);process.exitCode=1});
