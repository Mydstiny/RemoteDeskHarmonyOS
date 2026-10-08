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
    assert.match(options.leaseId,/^[0-9]+$/);assert.equal(Number(options.leaseId),owner.generation);
    control.isCurrent=()=>state.control && options.isCurrent();
    return { accepted:true,taskId:'test-task',attemptId:1,result:state.skipRunner ? Promise.resolve({stage:'cancelled',evidence:'none',diagnosticCode:'cancelled_before_start'}).then(async outcome=>{await options.onFinalize?.(outcome);return outcome;}) : runner(control) };
  }};
  const methods=['transferRouteIdentity','captureTransferLease','transferLeaseIsCurrent','transferQueueKey','activeTransferPanelLease','clipboardLeaseIsCurrent',
    'releaseNativeTransfer','waitForRdpOfferReadsToSettle','followRdpFileOfferReads','observeTransferAuthentication','clearTransferAuthentication','submitTransferAuthentication','waitClipboardPublication','publishClipboardForLease','cancelAndDrainNativeTransfer','sendRustDeskFile','submitFileToRustDesk','pickAndSendFile','prepareAndOfferRdpFiles',
    'rdpClipboardHierarchyIsSafe','receiveRdpClipboardEntries','rustDeskClipboardFilesAllowed','offerRustDeskClipboardFiles','observeRustDeskLocalClipboardChange','prepareAndOfferRdpDirectory','pickAndSendDirectory','handleRdpSystemFilePaste','transferClipboardSourceIsCurrent','startDeferredRdpFileDrop','createTransferArtifactBatch'];
  const module={exports:{}};
  const code=ts.transpileModule('export class Harness {\n'+methods.map(extract).join('\n')+'\n}',{
    compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}
  }).outputText;
  const fileIo={OpenMode:{READ_ONLY:0,NOFOLLOW:32},open:async()=>{if(state.afterOpen)await state.afterOpen();return {fd:42};},
    stat:async()=>({size:state.fileSize,isFile:()=>true}),close:async file=>state.closes.push(file.fd),
    openSync:()=>({fd:42}),statSync:()=>({size:state.fileSize,isFile:()=>true}),closeSync:file=>state.closes.push(file.fd)};
  vm.runInNewContext(code,{module,exports:module.exports,AccountSessionCoordinator:{getInstance:()=>({currentScope:()=>scope})},
    transferStorageFailureCode:(error,fallback)=>['transfer_space_limit','transfer_size_limit'].includes(error?.message)?error.message:fallback,
    TransferArtifactBatch:class {
      constructor(){this.id='incoming';}
      async stage(uri,name,size,current,progress){assert.ok(current());progress(size,size);return {name,path:'/private/staged',size};}
      createPlatformIncomingSync(){return {path:'/owned/incoming',complete:async uris=>{state.platformComplete++;state.platformUris=uris;
        return [{id:'root',name:'folder',relativePath:'folder',path:'/owned/incoming/folder',directory:true,size:0},
          {id:'child',name:'file',relativePath:'folder/file',path:'/owned/incoming/folder/file',size:4}];},
        retainPartial:async()=>{state.platformRetained++;}};}
      release(){state.batchReleases++;}
    },transferScopeKey:()=> 'scopehash',fileUri:{getUriFromPath:p=>'file://'+p},
    DragResult:{DRAG_FAILED:0,DRAG_SUCCESSFUL:1},uniformTypeDescriptor:{UniformDataType:{FILE_URI:'file'}},
    unifiedDataChannel:{FileConflictOptions:{OVERWRITE:1},ProgressIndicator:{DEFAULT:0}},
    TransferArtifactPublicationService:{getInstance:()=>({registerNativeOffer:(_batch,native)=>state.nativePublications.push(native)})},
    SystemClipboardFileProvider:class{async read(current,progress){state.platformReads=(state.platformReads||0)+1;state.platformCurrent=current;progress(25);const data=await state.nextUnified;return data.sources.map(source=>source.uri);}},
    RustDeskClipboardClient:class{
      configure(){return true;}
      async publish(sources){state.clipboardSources=sources;await state.clipboardPublishWait?.();return {publicationId:73,ready:true,drained:false};}
      async revoke(id){state.revokedClipboard=id;return true;}
    },RemoteKeyboardLayout:{MACOS:'macos',WINDOWS:'windows'},KEYCODE_META_LEFT:2076,
    ManagedTransferTaskService:{getInstance:()=>service},rdpRouteIdentity:host=>'rdp:'+host.host,
    util:{TextEncoder},RDP_FILE_MAX_BYTES:2147483648,picker:{DocumentSelectMode:{FILE:0,FOLDER:1},DocumentViewPicker:class{select(){state.pickerCalls=(state.pickerCalls||0)+1;return state.nextPicker;}}},
    scanAuthorizedTransferDirectory:async()=>({status:'ready',rootName:'Root',totalBytes:4,entries:[{directory:true,relativePath:'Root',uri:'file://root',name:'Root',size:0},{directory:false,relativePath:'Root/x',uri:'authorized://x',name:'x',size:4}]}),parentRemoteTransferPath:paths.parentRemoteTransferPath,sameRemoteTransferDirectory,renamedRemoteTransferFileName:paths.renamedRemoteTransferFileName,fileIo,joinRemoteTransferPath:paths.joinRemoteTransferPath,remoteTransferPathIsAbsolute:paths.remoteTransferPathIsAbsolute,
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
    transferControlClient:()=>({list:async()=>state.remoteDirectory}),physicalKeyboardLayout:'windows',rustdeskClipboardEnabled:true,physicalModifierKeyCodesDown:[],rustdeskFilePasteEnabled:true,fileTransferBusy:false,remoteTransferDirectory:'/home/test',clipboardBridge:null,
    ensurePasteboardReadPermission:()=>state.permission,transferSourcesFromUnifiedData:data=>data.sources,transferSourcesFromUris:uris=>uris.map(uri=>({uri,name:'current',size:4})),
    currentProtocolName(){return this.pendingHost.protocol;},currentAbilityBackgroundState:()=>false,
    clipboardBridgeEnabledForSession:()=>true,currentSessionCapabilities:()=>({clipboardSend:{enabled:true},clipboardReceive:{enabled:true},fileUpload:{enabled:true},fileDownload:{enabled:true}}),
    getFileTransferContext:()=>state.context,setFileTransferStatus:(_status,_progress,busy)=>{state.busyStates??=[];state.busyStates.push(busy);},showClipboardFileStatus:(_status,busy,_progress)=>{state.clipboardFileStates??=[];state.clipboardFileStates.push(busy);},formatTransferSize:String,yieldUi:async()=>{},
    openFileTransferPanel:()=>state.openPanel++,fileBaseName:()=> 'test.bin',
    rdpFileTransferEnabledForSession:(sid=page.sessionId,attempt=page.connectAttemptId)=>page.currentProtocolName()==='rdp' && sid===page.sessionId&&attempt===page.connectAttemptId,
    createRdpClipboardBatchDir:()=>'/private/batch',transferArtifactBatches:new Map([['/private/batch',{
      id:'batch-test',setPublished(){},release(){state.batchReleases++;},stage:async(uri,name,size,current,progress)=>{assert.ok(current()); progress(size,size);return {path:'/private/file-'+(++state.artifactSequence),size};}
    }]]),keyDispatcher:{sendShortcutSequence:(_loader,sid)=>state.sent.push({paste:sid})},
    loader:{captureDisconnectIdentity:()=>({...owner}),ownsDisconnectIdentity:lease=>lease.sessionId===owner.sessionId&&lease.generation===owner.generation&&lease.ownerToken===owner.ownerToken,
      revokeSessionRustDeskClipboardPublication:(sid,gen,id)=>{state.revokedClipboard={sid,gen,id};return true;},
      sendSessionFileFromFd:(sid,generation,remotePath,fd,conflict)=>{state.sent.push({sid,generation,remotePath,fd,conflict});return 29;},
      getSessionTransferAuthentication:()=>state.auth,getSessionTransferResult:()=>state.metadata,
      submitSessionTransferAuthentication:(...args)=>{state.authSubmitted=args;return true;},
      getSessionFileTransfer:()=>({transferId:29,rustdeskTransferState:state.status,transferredBytes:state.fileSize,totalBytes:state.fileSize}),
      cancelSessionFileTransfer:()=>true,releaseSessionFileTransfer:(sid,generation,id)=>state.releases.push({sid,generation,id}),
      getSessionClipboardSnapshot:()=>({sequence:state.remoteSequence}),publishSessionClipboardFiles:(sid,_gen,files)=>{state.offers.push({sid,files});return {publicationId:1,state:state.publicationState};},
      getSessionClipboardPublicationState:()=>state.publicationState,
      getSessionRdpFileOfferProgress:()=>state.readProgress??{generation:1,requestedBytes:Number.MAX_SAFE_INTEGER,requests:1,lastRequestAgoMs:5000},
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
  assert.ok(f.state.updates.some(u=>u.stage==='offered'));
  // The remote then read every byte: the task follows its reads to the end.
  assert.equal(f.state.updates.at(-1).stage,'transferring');assert.equal(f.state.updates.at(-1).sentBytes,2);
});
test('an RDP offer the remote stopped reading halfway is handed off, not completed',async()=>{
  const f=fixture();f.page.pendingHost.protocol='rdp';const lease=f.page.captureTransferLease();
  f.state.readProgress={generation:1,requestedBytes:1,requests:3,lastRequestAgoMs:31000};
  let outcome;f.page.followRdpFileOfferReads(lease,10,{isCurrent:()=>true,update:u=>{f.state.updates.push(u);return true;}}).then(o=>{outcome=o;});
  for(let i=0;i<20&&!outcome;i++)await Promise.resolve();
  assert.equal(outcome.stage,'handedOff');assert.equal(outcome.diagnosticCode,'remote_read_partial');
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
test('file clipboard event changes during cancellable platform read invalidate the old payload',async()=>{
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
test('system file read guard rejects permission revocation and reports local-only progress',async()=>{
 const f=fixture();let resolve;f.state.nextUnified=new Promise(r=>resolve=r);let label='';
 f.page.setFileTransferStatus=value=>{label=value;};const pending=f.page.handleRdpSystemFilePaste();await new Promise(setImmediate);
 assert.match(label,/正在读取本机文件剪贴板 25%/);assert.equal(f.state.platformCurrent(),true);
 f.page.rustdeskFilePasteEnabled=false;assert.equal(f.state.platformCurrent(),false);
 resolve({sources:[{uri:'old://file'}]});await pending;assert.equal(f.state.sent.length,0);
});
test('duplicate system paste during acquisition starts one read and releases pending guard',async()=>{
 const f=fixture();let resolve;f.state.nextUnified=new Promise(r=>resolve=r);
 const pending=f.page.handleRdpSystemFilePaste();await new Promise(setImmediate);
 await f.page.handleRdpSystemFilePaste();assert.equal(f.state.platformReads,1);
 f.state.localCount++;resolve({sources:[]});await pending;assert.equal(f.page.systemClipboardReadPending,false);
});
test('RDP directory acquisition rejects case and NFC parent aliases before any task',async()=>{
 for(const names of [['Root','root/a'],['é','e\u0301/a'],['Root/a','root/b'],['Root/É/a','Root/E\u0301/b']]){
  for(const order of [names,[...names].reverse()]){
   const f=fixture();f.page.pendingHost.protocol='rdp';f.page.transferPanelLease=f.page.captureTransferLease();
   const offer={state:'ready',entries:order.map((relativeName,index)=>({relativeName,index}))};
   assert.equal(f.page.rdpClipboardHierarchyIsSafe(offer),false);
   f.page.rdpReceiveOffer=offer;await f.page.receiveRdpClipboardEntries(offer.entries);
   assert.equal(f.state.options,undefined);
  }
 }
});
test('RDP hierarchy preserves consistent implicit parents and rejects normalized full duplicates',()=>{
 const f=fixture();
 assert.equal(f.page.rdpClipboardHierarchyIsSafe({entries:[{relativeName:'Root/a'},{relativeName:'Root'},{relativeName:'Root/sub/b'}]}),true);
 assert.equal(f.page.rdpClipboardHierarchyIsSafe({entries:[{relativeName:'É.txt'},{relativeName:'E\u0301.txt'}]}),false);
});
test('queued RDP directory cancellation releases creator without running preparation',async()=>{
 const f=fixture();f.page.pendingHost.protocol='rdp';f.state.skipRunner=true;
 await f.page.prepareAndOfferRdpDirectory({rootName:'Root',entries:[],totalBytes:0},f.page.captureTransferLease());
 assert.equal(f.state.batchReleases,1);assert.equal(typeof f.state.options.onFinalize,'function');
});
test('the clipboard file-paste switch does not gate an explicit RustDesk directory send',async()=>{
 const f=fixture();f.page.rustdeskFilePasteEnabled=false;f.state.nextPicker=Promise.resolve([]);
 await f.page.pickAndSendDirectory();assert.equal(f.state.pickerCalls,1);
});
test('a RustDesk directory send without an opened remote folder says so instead of opening the Picker',async()=>{
 const f=fixture();f.page.remoteTransferDirectory='';f.state.nextPicker=Promise.resolve([]);
 await f.page.pickAndSendDirectory();assert.equal(f.state.pickerCalls||0,0);
 assert.match(f.page.remoteTransferBrowserMessage,/远端文件夹/);
});
test('RustDesk system file paste publishes prepared FD then sends one paste chord',async()=>{
 const f=fixture();f.state.nextUnified=Promise.resolve({sources:[{uri:'local://a',name:'a',size:4}]});
 await f.page.handleRdpSystemFilePaste();assert.equal(f.state.clipboardSources.length,1);assert.equal(f.state.clipboardSources[0].fd,42);
 assert.deepEqual(f.state.sent,[{paste:7}]);assert.deepEqual(f.state.closes,[42]);
});
test('late RustDesk publication cannot paste after ownership changes',async()=>{
 const f=fixture();f.state.nextUnified=Promise.resolve({sources:[{uri:'local://a',name:'a',size:4}]});
 f.state.clipboardPublishWait=async()=>{f.owner.generation++;};await f.page.handleRdpSystemFilePaste();
 assert.equal(f.state.sent.length,0);assert.equal(f.state.revokedClipboard,73);assert.deepEqual(f.state.closes,[42]);
});
test('RustDesk file clipboard respects both settings',async()=>{
 for(const setting of ['rustdeskClipboardEnabled','rustdeskFilePasteEnabled']){const f=fixture();f.page[setting]=false;
 f.state.nextUnified=Promise.resolve({sources:[{uri:'local://a',name:'a',size:4}]});await f.page.handleRdpSystemFilePaste();
 assert.equal(f.state.clipboardSources,undefined);assert.equal(f.state.sent.length,0);}
});
test('a new local clipboard event revokes only the captured file publication',async()=>{
 const f=fixture();f.page.rustdeskLocalPublicationId=73;f.page.rustdeskLocalPublicationLease=f.page.captureTransferLease();
 f.page.rustdeskLocalPublicationCount=1;await f.page.observeRustDeskLocalClipboardChange(()=>true);assert.equal(f.state.revokedClipboard,undefined);
 f.state.localCount=2;await f.page.observeRustDeskLocalClipboardChange(()=>true);assert.deepEqual(f.state.revokedClipboard,{sid:7,gen:11,id:73});assert.equal(f.page.rustdeskLocalPublicationId,0);
});
test('automatic RDP file synchronization offers once in background without injecting paste',async()=>{
 const f=fixture();f.page.pendingHost.protocol='rdp';const lease=f.page.captureTransferLease();
 f.page.cleanupStarted=true;f.page.sessionWindowActive=false;
 f.page.withClipboardAuthority=(_lease,operation)=>operation();
 assert.equal(await f.page.prepareAndOfferRdpFiles([{uri:'authorized://file',name:'file',size:4}],lease,
  'continuous-clipboard',undefined,undefined,undefined,()=>true),true);
 assert.equal(f.state.offers.length,1);assert.equal(f.state.sent.length,0);assert.equal((f.state.busyStates??[]).includes(true),false);
});
test('automatic RDP authority handoff rejects final offer after file staging',async()=>{
 const f=fixture();f.page.pendingHost.protocol='rdp';const lease=f.page.captureTransferLease();
 f.page.withClipboardAuthority=()=>false;
 assert.equal(await f.page.prepareAndOfferRdpFiles([{uri:'authorized://file',name:'file',size:4}],lease,
  'continuous-clipboard',undefined,undefined,undefined,()=>true),false);
 assert.equal(f.state.offers.length,0);assert.equal(f.state.sent.length,0);
});
test('automatic RustDesk file synchronization publishes in background without injecting paste',async()=>{
 const f=fixture(),lease=f.page.captureTransferLease();f.page.cleanupStarted=true;f.page.sessionWindowActive=false;
 f.page.withClipboardAuthority=(_lease,operation)=>operation();
 assert.equal(await f.page.offerRustDeskClipboardFiles([{uri:'authorized://file',name:'file',size:4}],lease,
  'continuous-clipboard',undefined,()=>true),true);
 assert.equal(f.state.clipboardSources.length,1);assert.equal(f.state.sent.length,0);
});
(async()=>{for(const {name,run} of tests){await run();console.log('PASS '+name);}console.log(`${tests.length} page ownership tests passed`);})().catch(error=>{console.error(error);process.exitCode=1;});
