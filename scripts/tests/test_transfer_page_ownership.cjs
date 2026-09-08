/* Invokes the production page's admission/async methods; no ArkUI/device claims. */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.TRANSFER_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/RemoteDesktop.ets'), 'utf8');
const tests = [];
const test = (name, run) => tests.push({name, run});
function extract(name) {
  const re = new RegExp('^  private (?:async )?' + name + '\\(', 'm');
  const match = re.exec(source); assert.ok(match, name);
  const end = source.indexOf('\n  private ', match.index + 1);
  assert.ok(end > match.index, name + ' bounded');
  return source.slice(match.index, end);
}
function loadPolicy(file) {
  const module = {exports: {}};
  const code = ts.transpileModule(fs.readFileSync(path.join(root, file),'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  vm.runInNewContext(code, {module, exports: module.exports}); return module.exports;
}
function sameRemoteTransferDirectory(a,b) { return a === b; }
const paths = loadPolicy('entry/src/main/ets/services/TransferRemotePathPolicy.ets');
function fixture() {
  const scope = {ownerScopeId:'scope-a',generation:1};
  const owner = {sessionId:7,generation:11,ownerToken:19,facadeGeneration:2};
  const state = { sent:[], closes:[], releases:[], updates:[], control:true, status:6,
    context:{filesDir:'/owned'}, nextPicker:null, fileSize:0, afterOpen:null, openPanel:0, artifactSequence:0, offers:[], batchReleases:0,
    platformComplete:0,platformRetained:0,platformUris:[],platformOffers:[], publicationState:2, metadata:{operationKind:0,sourceMetadataAvailable:false}, auth:{transferId:0}, nativePublications:[], localCount:1, remoteSequence:0, nextUnified:null, permission:Promise.resolve(true) };
  const control = { taskId:'test-task', attemptId:1, isCurrent:()=>state.control,
    isCancellationRequested:()=>!state.control, update:value=>{state.updates.push(value);return true;},
    onCancel:callback=>{state.cancel=callback;} };
  const service = {init:()=>true, enqueue(options,runner) {
    state.options=options;
    control.isCurrent=()=>state.control && options.isCurrent();
    return { accepted:true,taskId:'test-task',attemptId:1,result:runner(control) };
  }};
  const methods=['transferRouteIdentity','captureTransferLease','transferLeaseIsCurrent','clipboardLeaseIsCurrent',
    'releaseNativeTransfer','observeTransferAuthentication','clearTransferAuthentication','submitTransferAuthentication','waitClipboardPublication','publishClipboardForLease','cancelAndDrainNativeTransfer','sendRustDeskFile','submitFileToRustDesk','pickAndSendFile','prepareAndOfferRdpFiles',
    'handleRdpSystemFilePaste','transferClipboardSourceIsCurrent','startDeferredRdpFileDrop','createTransferArtifactBatch'];
  const module={exports:{}};
  const code=ts.transpileModule('export class Harness {\n'+methods.map(extract).join('\n')+'\n}',{
    compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}
  }).outputText;
  const fileIo={OpenMode:{READ_ONLY:0,NOFOLLOW:32},open:async()=>{if(state.afterOpen)await state.afterOpen();return {fd:42};},
    stat:async()=>({size:state.fileSize,isFile:()=>true}),close:async file=>state.closes.push(file.fd),
    openSync:()=>({fd:42}),statSync:()=>({size:state.fileSize,isFile:()=>true}),closeSync:file=>state.closes.push(file.fd)};
  vm.runInNewContext(code,{module,exports:module.exports,AccountSessionCoordinator:{getInstance:()=>({currentScope:()=>scope})},
    TransferArtifactBatch:class {
      constructor(){this.id='incoming';}
      createPlatformIncomingSync(){return {path:'/owned/incoming',complete:async uris=>{state.platformComplete++;state.platformUris=uris;
        return [{id:'root',name:'folder',relativePath:'folder',path:'/owned/incoming/folder',directory:true,size:0},
          {id:'child',name:'file',relativePath:'folder/file',path:'/owned/incoming/folder/file',size:4}];},
        retainPartial:async()=>{state.platformRetained++;}};}
      release(){state.batchReleases++;}
    },transferScopeKey:()=> 'scopehash',fileUri:{getUriFromPath:p=>'file://'+p},
    DragResult:{DRAG_FAILED:0,DRAG_SUCCESSFUL:1},uniformTypeDescriptor:{UniformDataType:{FILE_URI:'file'}},
    unifiedDataChannel:{FileConflictOptions:{OVERWRITE:1},ProgressIndicator:{DEFAULT:0}},
    TransferArtifactPublicationService:{getInstance:()=>({registerNativeOffer:(_batch,native)=>state.nativePublications.push(native)})},
    ManagedTransferTaskService:{getInstance:()=>service},rdpRouteIdentity:host=>'rdp:'+host.host,
    util:{TextEncoder},RDP_FILE_MAX_BYTES:2147483648,picker:{DocumentSelectMode:{FILE:0},DocumentViewPicker:class{select(){return state.nextPicker;}}},
    sameRemoteTransferDirectory,renamedRemoteTransferFileName:paths.renamedRemoteTransferFileName,fileIo,joinRemoteTransferPath:paths.joinRemoteTransferPath,remoteTransferPathIsAbsolute:paths.remoteTransferPathIsAbsolute,
    promptAction:{showToast(){}},hilog:{info(){},warn(){},error(){}},RD_DOMAIN:0,RD_TAG:'test',
    FILE_TRANSFER_DIAG_PICK:'pick',FILE_TRANSFER_DIAG_RUSTDESK_SEND:'send',KEYCODE_CTRL_LEFT:2072,KEY_V:2038,
    pasteboard:{getSystemPasteboard:()=>({getChangeCount:()=>state.localCount,getUnifiedData:()=>state.nextUnified})},Date,
    ArrayBuffer:class extends ArrayBuffer{constructor(length){assert.ok(length<=65536,'no whole-file allocation');super(length);}}
  });
  const page=new module.exports.Harness();
  Object.assign(page,{connected:true,cleanupStarted:false,sessionId:7,connectAttemptId:3,hostId:'host-a',
    sessionWindowId:'window-a',harmonyShortcutCaptureOwner:'capture-a',sessionWindowActive:true,sessionWindowMinimized:false,
    pendingHost:{id:'host-a',protocol:'rustdesk',host:'relay.invalid',port:21116,customHostname:'peer',
      rustdeskDirectEnabled:false,rustdeskDirectHost:'',rustdeskDirectPort:21118,rustdeskRelayId:'relay-a'},
    nativeDisconnectIdentity:owner,transferAuth:{transferId:0},transferAuthLease:null,transferAuthSecret:'',
    transferControlClient:()=>({list:async()=>state.remoteDirectory}),physicalModifierKeyCodesDown:[],rustdeskFilePasteEnabled:true,fileTransferBusy:false,remoteTransferDirectory:'/home/test',clipboardBridge:null,
    ensurePasteboardReadPermission:()=>state.permission,transferSourcesFromUnifiedData:data=>data.sources,
    currentProtocolName(){return this.pendingHost.protocol;},currentAbilityBackgroundState:()=>false,
    clipboardBridgeEnabledForSession:()=>true,currentSessionCapabilities:()=>({clipboardSend:{enabled:true},fileUpload:{enabled:true}}),
    getFileTransferContext:()=>state.context,setFileTransferStatus:()=>{},formatTransferSize:String,yieldUi:async()=>{},
    openFileTransferPanel:()=>state.openPanel++,fileBaseName:()=> 'test.bin',
    rdpFileTransferEnabledForSession:(sid=page.sessionId,attempt=page.connectAttemptId)=>page.currentProtocolName()==='rdp' && sid===page.sessionId&&attempt===page.connectAttemptId,
    createRdpClipboardBatchDir:()=>'/private/batch',transferArtifactBatches:new Map([['/private/batch',{
      id:'batch-test',setPublished(){},release(){state.batchReleases++;},stage:async(uri,name,size,current,progress)=>{assert.ok(current()); progress(size,size);return {path:'/private/file-'+(++state.artifactSequence),size};}
    }]]),keyDispatcher:{sendShortcutSequence:(_loader,sid)=>state.sent.push({paste:sid})},
    loader:{captureDisconnectIdentity:()=>({...owner}),ownsDisconnectIdentity:lease=>lease.sessionId===owner.sessionId&&lease.generation===owner.generation&&lease.ownerToken===owner.ownerToken,
      sendSessionFileFromFd:(sid,generation,remotePath,fd,conflict)=>{state.sent.push({sid,generation,remotePath,fd,conflict});return 29;},
      getSessionTransferAuthentication:()=>state.auth,getSessionTransferResult:()=>state.metadata,
      submitSessionTransferAuthentication:(...args)=>{state.authSubmitted=args;return true;},
      getSessionFileTransfer:()=>({transferId:29,rustdeskTransferState:state.status,transferredBytes:state.fileSize,totalBytes:state.fileSize}),
      cancelSessionFileTransfer:()=>true,releaseSessionFileTransfer:(sid,generation,id)=>state.releases.push({sid,generation,id}),
      getSessionClipboardSnapshot:()=>({sequence:state.remoteSequence}),publishSessionClipboardFiles:(sid,_gen,files)=>{state.offers.push({sid,files});return {publicationId:1,state:state.publicationState};},
      getSessionClipboardPublicationState:()=>state.publicationState,
      publishSessionClipboard:()=>({state:2,publicationId:1})}});
  return {page,state,scope,owner};
}
test('full owner rejects every account/route/window/native rollover',()=>{
  const mutations=[f=>f.scope.generation++,f=>f.scope.ownerScopeId='scope-b',f=>f.page.hostId='host-b',
    f=>f.page.sessionWindowId='window-b',f=>f.page.connectAttemptId++,f=>f.owner.generation++,
    f=>f.owner.ownerToken++,f=>f.page.pendingHost.rustdeskRelayId='relay-b',f=>f.page.sessionId++];
  for(const mutate of mutations){const f=fixture(),lease=f.page.captureTransferLease();assert.equal(f.page.transferLeaseIsCurrent(lease),true);mutate(f);assert.equal(f.page.transferLeaseIsCurrent(lease),false);}
});
test('picker completion after account rollover never opens or sends a file',async()=>{
  const f=fixture();let resolve;f.state.nextPicker=new Promise(r=>resolve=r);
  const result=f.page.pickAndSendFile();f.scope.generation++;resolve(['authorized://test']);await result;
  assert.equal(f.state.sent.length,0);assert.equal(f.state.closes.length,0);
});
test('FD opening completion after native owner rollover cannot enqueue bytes',async()=>{
  const f=fixture();f.state.fileSize=4;f.state.afterOpen=()=>{f.owner.generation++;};
  assert.equal(await f.page.submitFileToRustDesk('authorized://test','test.bin',4),'failed');
  assert.equal(f.state.sent.length,0);assert.deepEqual(f.state.closes,[42]);
});
test('zero and large files use captured FD/target and truthful sender completion',async()=>{
  for(const size of [0,104857601,2147483648]){const f=fixture();f.state.fileSize=size;
    assert.equal(await f.page.submitFileToRustDesk('authorized://test','test.bin',size),'senderCompleted');
    assert.deepEqual(f.state.sent,[{sid:7,generation:11,remotePath:'/home/test/test.bin',fd:42,conflict:0}]);
    assert.equal(f.state.releases.length,1);assert.deepEqual(f.state.closes,[42]);
    assert.equal(f.state.updates.at(-1).sentBytes,size);
  }
});
test('missing selected remote directory never falls back to a guessed Windows path',async()=>{
  const f=fixture();f.page.remoteTransferDirectory='';
  assert.equal(await f.page.submitFileToRustDesk('authorized://test','test.bin',0),'failed');
  assert.equal(f.state.sent.length,0);assert.equal(f.state.openPanel,1);
});
test('RDP batch publishes distinct artifacts once and leaves target unconfirmed',async()=>{
  const f=fixture();f.page.pendingHost.protocol='rdp';const lease=f.page.captureTransferLease();
  const files=[{uri:'authorized://one',name:'same.txt',size:0},{uri:'authorized://two',name:'same.txt',size:2}];
  assert.equal(await f.page.prepareAndOfferRdpFiles(files,lease,'picker'),true);
  assert.equal(f.state.offers.length,1);assert.deepEqual(Array.from(f.state.offers[0].files),['/private/file-1','/private/file-2']);
  assert.equal(f.state.updates.at(-1).stage,'offered');
});
test('verified source metadata is distinct from sender-only completion',async()=>{
  const f=fixture();f.state.fileSize=42;
  f.state.metadata={operationKind:1,sourceMetadataAvailable:true,sourceSize:42,sourceModifiedTime:1700000000};
  f.state.remoteDirectory={path:'/home/test',entries:[{name:'test.bin',type:4,size:42,modifiedTime:1700000000}]};
  assert.equal(await f.page.submitFileToRustDesk('uri','test.bin',42),'senderCompleted');
  assert.equal(f.state.updates.at(-1).verifiedBytes,42);
  const g=fixture();g.state.fileSize=42;g.state.metadata=f.state.metadata;
  g.state.remoteDirectory={path:'/home/test',entries:[{name:'test.bin',type:4,size:42,modifiedTime:1700000001}]};
  await g.page.submitFileToRustDesk('uri','test.bin',42);
  assert.equal(g.state.updates.some(u=>u.verifiedBytes!==undefined),false);
});
test('metadata query that completes after owner change never records verification',async()=>{
  const f=fixture();f.state.metadata={operationKind:1,sourceMetadataAvailable:true,sourceSize:0,sourceModifiedTime:1};
  f.page.transferControlClient=()=>({list:async()=>{f.owner.generation++;return {entries:[{name:'a',type:4,size:0,modifiedTime:1}]};}});
  await f.page.submitFileToRustDesk('uri','a',0);
  assert.equal(f.state.updates.some(u=>u.verifiedBytes!==undefined),false);
});
test('overwrite is explicit and frozen before the file picker yields',async()=>{
  const f=fixture();let resolve;f.state.nextPicker=new Promise(r=>resolve=r);f.page.transferAllowOverwrite=true;
  const pending=f.page.pickAndSendFile();assert.equal(f.page.transferAllowOverwrite,false);
  resolve(['authorized://test']);await pending;assert.equal(f.state.sent[0].conflict,1);
  const g=fixture();g.state.nextPicker=Promise.resolve(['authorized://test']);
  await g.page.pickAndSendFile();assert.equal(g.state.sent[0].conflict,0);
});
test('duplicate selected target names are rejected before any RustDesk upload',async()=>{
  const f=fixture();f.state.nextPicker=Promise.resolve(['uri:one','uri:two']);
  await f.page.pickAndSendFile();assert.equal(f.state.sent.length,0);
});
test('authentication submits exact challenge and clears transient secret',()=>{
  const f=fixture(),lease=f.page.captureTransferLease();
  f.page.observeTransferAuthentication(lease,{transferId:29,challengeId:87,kind:2,state:1});
  f.page.transferAuthSecret='123456';f.page.submitTransferAuthentication(2);
  assert.deepEqual(f.state.authSubmitted,[7,11,29,87,2,'123456']);assert.equal(f.page.transferAuthSecret,'');
  f.state.authSubmitted=null;f.page.transferAuthSecret='654321';f.owner.generation++;
  f.page.submitTransferAuthentication(2);assert.equal(f.state.authSubmitted,null);assert.equal(f.page.transferAuthSecret,'');
});
test('platform data loading starts synchronously and publishes each directory root only once',async()=>{
 const f=fixture();f.page.pendingHost.protocol='rdp';let listener,started=false;
 f.page.prepareAndOfferRdpFiles=async(sources,_lease,origin,_expected,batch,artifacts)=>{
  f.state.platformOffers.push({sources,origin,artifacts});return true;};
 const event={startDataLoading(options){started=true;listener=options.dataProgressListener;},setResult(){}};
 const returned=f.page.startDeferredRdpFileDrop(event);assert.equal(returned,undefined);assert.equal(started,true);
 const data={getRecords:()=>[{getEntry:()=>({oriUri:'file:///owned/incoming/folder'})}]};
 listener({progress:100},data);listener({progress:100},data);
 for(let i=0;i<15;i++)await Promise.resolve();
 assert.equal(f.state.platformComplete,1);assert.equal(f.state.platformOffers.length,1);
 assert.equal(f.state.platformOffers[0].sources.length,1);assert.equal(f.state.platformOffers[0].artifacts[0].id,'root');
});
test('late platform completion settles old storage without publishing into a replacement session',async()=>{
 const f=fixture();f.page.pendingHost.protocol='rdp';let listener;
 f.page.prepareAndOfferRdpFiles=async()=>{f.state.platformOffers.push(1);return true;};
 f.page.startDeferredRdpFileDrop({startDataLoading(o){listener=o.dataProgressListener;},setResult(){}});
 listener({progress:-1},null);for(let i=0;i<5;i++)await Promise.resolve();
 f.owner.generation++;listener({progress:100},{getRecords:()=>[{getEntry:()=>({oriUri:'file:///owned/incoming/file'})}]});
 for(let i=0;i<15;i++)await Promise.resolve();
 assert.equal(f.state.platformRetained,1);assert.equal(f.state.platformComplete,1);assert.equal(f.state.platformOffers.length,0);
});
test('Windows/Linux remote target joining rejects relative and traversal inputs',()=>{
  assert.equal(paths.joinRemoteTransferPath('C:\\Users\\Test','a.txt'),'C:\\Users\\Test\\a.txt');
  assert.equal(paths.joinRemoteTransferPath('/home/test','a.txt'),'/home/test/a.txt');
  for(const base of ['relative','C:test','/home/../root','C:\\a\\..\\b'])assert.equal(paths.joinRemoteTransferPath(base,'a'),'');
  for(const name of ['..','../a','a/b','a\\b','a\0b'])assert.equal(paths.joinRemoteTransferPath('/home/test',name),'');
  assert.equal(paths.parentRemoteTransferPath('/home'),'/');
  assert.equal(paths.parentRemoteTransferPath('C:\\Users'),'C:\\');
});
test('RDP paste waits for actual format-list acknowledgement and releases preparation',async()=>{
  const f=fixture();f.page.pendingHost.protocol='rdp';f.state.publicationState=1;
  f.page.yieldUi=async()=>{assert.equal(f.state.sent.length,0);f.state.publicationState=2;};
  assert.equal(await f.page.prepareAndOfferRdpFiles([{uri:'a',name:'a',size:0}],f.page.captureTransferLease(),'picker'),true);
  assert.deepEqual(f.state.sent,[{paste:7}]);assert.equal(f.state.batchReleases,1);
});
test('cancelled preparation releases creator without publishing or sending paste',async()=>{
  const f=fixture();f.page.pendingHost.protocol='rdp';f.state.control=false;
  assert.equal(await f.page.prepareAndOfferRdpFiles([{uri:'a',name:'a',size:0}],f.page.captureTransferLease(),'picker'),false);
  assert.equal(f.state.batchReleases,1);assert.equal(f.state.offers.length,0);assert.equal(f.state.sent.length,0);
});
test('clipboard source owner changes during pending ACK suppress paste',async()=>{
  const f=fixture();f.page.pendingHost.protocol='rdp';f.state.publicationState=1;
  f.page.yieldUi=async()=>{f.scope.generation++;f.state.publicationState=2;};
  assert.equal(await f.page.prepareAndOfferRdpFiles([{uri:'a',name:'a',size:0}],f.page.captureTransferLease(),'picker'),false);
  assert.equal(f.state.batchReleases,1);assert.equal(f.state.sent.length,0);
});
test('unobservable native transfer remains unconfirmed and is never released as drained',async()=>{
  const f=fixture();f.state.status=0;
  assert.equal(await f.page.submitFileToRustDesk('a','a',0),'failed');
  assert.equal(f.state.releases.length,0);
  assert.equal(await f.page.cancelAndDrainNativeTransfer(f.page.captureTransferLease(),29),null);
});
test('cancellation waits for native terminal state before reporting drain',async()=>{
  const f=fixture();f.state.status=2;let polls=0;
  f.page.yieldUi=async()=>{if(++polls===3)f.state.status=5;};
  const terminal=await f.page.cancelAndDrainNativeTransfer(f.page.captureTransferLease(),29);
  assert.equal(terminal.rustdeskTransferState,5);assert.equal(polls,3);
});
test('file clipboard event changes during UnifiedData read invalidate the old payload',async()=>{
  for(const mutate of [f=>f.state.localCount++,f=>f.state.remoteSequence++]){
    const f=fixture();f.page.pendingHost.protocol='rdp';let resolve;
    f.state.nextUnified=new Promise(r=>resolve=r);
    const pending=f.page.handleRdpSystemFilePaste();await Promise.resolve();
    mutate(f);resolve({sources:[{uri:'old://file',name:'old',size:4}]});await pending;
    assert.equal(f.state.offers.length,0);assert.equal(f.state.artifactSequence,0);
  }
});
test('permission wait cannot replace the triggering clipboard event',async()=>{
  const f=fixture();f.page.pendingHost.protocol='rdp';let resolve;
  f.state.permission=new Promise(r=>resolve=r);f.state.nextUnified=Promise.resolve({sources:[{uri:'new://file',name:'new',size:4}]});
  const pending=f.page.handleRdpSystemFilePaste();f.state.localCount++;resolve(true);await pending;
  assert.equal(f.state.offers.length,0);assert.equal(f.state.artifactSequence,0);
});
test('foreground loss while staging a file clipboard blocks offer as well as paste',async()=>{
  for(const mutate of [f=>f.page.sessionWindowActive=false,f=>f.page.sessionWindowMinimized=true,
    f=>f.page.currentAbilityBackgroundState=()=>true]){
    const f=fixture();f.page.pendingHost.protocol='rdp';
    f.page.transferArtifactBatches.get('/private/batch').stage=async()=>{mutate(f);return {path:'/private/staged',size:4};};
    assert.equal(await f.page.prepareAndOfferRdpFiles([{uri:'a',name:'a',size:4}],f.page.captureTransferLease(),'system-clipboard'),false);
    assert.equal(f.state.offers.length,0);assert.equal(f.state.sent.length,0);assert.equal(f.state.batchReleases,1);
  }
});
test('current local file clipboard event is offered after permission and bounded staging',async()=>{
  const f=fixture();f.page.pendingHost.protocol='rdp';f.state.nextUnified=Promise.resolve({sources:[{uri:'current://file',name:'current',size:4}]});
  await f.page.handleRdpSystemFilePaste();assert.equal(f.state.offers.length,1);assert.deepEqual(f.state.sent,[{paste:7}]);
});
(async()=>{for(const {name,run} of tests){await run();console.log('PASS '+name);}console.log(`${tests.length} page ownership tests passed`);})().catch(error=>{console.error(error);process.exitCode=1;});
