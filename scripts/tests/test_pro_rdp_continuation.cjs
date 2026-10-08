/* Executes production RDP identity boundaries. No native connection/device proof. */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
function createLoader(mocks = {}, globals = {}) {
  const cache = new Map();
  function load(file) {
    file = path.resolve(root, file);
    if (cache.has(file)) return cache.get(file).exports;
    const module = { exports: {} }; cache.set(file, module);
    const source = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
    }).outputText;
    vm.runInNewContext(source, { module, exports: module.exports, ...globals, require(id) {
      if (mocks[id]) return mocks[id];
      if (id === '@kit.CryptoArchitectureKit') return {};
      if (id.startsWith('.')) return load(path.resolve(path.dirname(file), id + '.ets'));
      throw new Error('unexpected import ' + id);
    } }, { filename: file });
    return module.exports;
  }
  return load;
}
const load = createLoader();
const policy = load('entry/src/main/ets/services/pro/ProRdpConnectionIdentity.ets');
const model = load('entry/src/main/ets/model/RemoteHost.ets');
const tests = [];
function test(name, body) { tests.push({ name, body }); }
function host(values = {}) {
  const result = { id: 'rdp-1', protocol: 'rdp', host: 'desktop.example.test', port: 3389,
    username: 'SHOULD_NOT_INFER', customHostname: '', gatewayHost: '', gatewayPort: 443,
    rdpGatewayServerName: '', rdpGatewayTransport: 'auto', rdpEndpointMode: 'direct_rdp',
    rdpAuthMode: 'password', ...values };
  for (const name of ['password', 'rdpRestrictedAdminHash', 'rdpCertificateFingerprintSha256',
    'rdpCertificateTrustMode', 'sshKeyData']) {
    Object.defineProperty(result, name, { get() { throw new Error('forbidden read: ' + name); } });
  }
  result.toJSON = () => { throw new Error('must not serialize host'); };
  return result;
}
function identity(value = host(), username = 'WORK\\alice', mode = 1) {
  return policy.describeProRdpConnectionIdentity(value, model.normalizeRdpCredentialParts(username, mode));
}

test('actual normalized native username/domain, not a credential reference or password', () => {
  const value = identity();
  assert.equal(value.username, 'alice'); assert.equal(value.domain, 'WORK');
  assert.equal(value.authMode, 'password');
  assert.deepEqual(Object.keys(value).sort(), ['authMode', 'domain', 'route', 'username']);
  assert.ok(!JSON.stringify(value).includes('SHOULD_NOT_INFER'));
});
test('Microsoft and Azure identity modes cannot be exchanged after authentication', () => {
  for (const name of ['alice@example.test', 'MicrosoftAccount\\alice@example.test', 'AzureAD\\alice@example.test']) {
    for (let a = 0; a < 5; a++) for (let b = 0; b < 5; b++) {
      const left = identity(host(), name, a), right = identity(host(), name, b);
      const expected = model.normalizeRdpCredentialParts(name, a);
      const other = model.normalizeRdpCredentialParts(name, b);
      assert.equal(policy.sameProRdpConnectionIdentity(left, right),
        expected.username === other.username && expected.domain === other.domain);
    }
  }
});
test('direct, transparent TCP and Microsoft Gateway use actual canonical route identities', () => {
  for (const mode of ['direct_rdp', 'transparent_tcp_rdp', 'microsoft_rd_gateway']) {
    const h = host({ rdpEndpointMode: mode, gatewayHost: mode === 'microsoft_rd_gateway' ? 'gateway.example.test' : '' });
    const value = identity(h);
    assert.ok(value); assert.equal(value.route, model.rdpRouteIdentity(h));
    assert.equal(policy.proRdpConnectionRouteMatches(h, value), true);
  }
});
test('changing target, gateway, transport or server name invalidates the source route', () => {
  const h = host({ rdpEndpointMode: 'microsoft_rd_gateway', gatewayHost: 'gateway.example.test' });
  const value = identity(h);
  for (const mutation of [{host: 'other.example.test'}, {port: 3390}, {customHostname: 'other-name.example.test'},
    {gatewayHost: 'other-gateway.example.test'}, {gatewayPort: 444},
    {rdpGatewayServerName: 'gateway-name.example.test'}, {rdpGatewayTransport: 'rpc'},
    {rdpEndpointMode: 'transparent_tcp_rdp'}, {rdpAuthMode: 'restricted_admin'}, {protocol: 'ssh'}, {id: ''}]) {
    assert.equal(policy.proRdpConnectionRouteMatches(host({...h, ...mutation}), value), false, JSON.stringify(mutation));
  }
});
test('unsupported bastions and known unknown Gateway are rejected without probing', () => {
  for (const mode of ['vendor_https_bastion', 'azure_bastion', 'unknown_gateway']) {
    assert.equal(identity(host({rdpEndpointMode: mode})), null);
  }
});
test('connection-time credentials bind to the actual provided native pair', () => {
  const h = host({ username: '', rdpCredentialStorageMode: 'connect_time' });
  assert.ok(identity(h, 'DOMAIN\\alice'));
  assert.equal(identity(h, ''), null);
  assert.equal(policy.sameProRdpConnectionIdentity(identity(h, 'DOMAIN\\alice'), identity(h, 'DOMAIN\\bob')), false);
});
test('auth modes remain distinct while local secret rotation does not enter the model', () => {
  for (const mode of ['password', 'blank_password', 'restricted_admin']) {
    const h = host({rdpAuthMode: mode}); const value = identity(h);
    assert.equal(value.authMode, mode); assert.equal(policy.proRdpConnectionRouteMatches(h, value), true);
    for (const other of ['password', 'blank_password', 'restricted_admin']) {
      assert.equal(policy.proRdpConnectionRouteMatches(host({rdpAuthMode: other}), value), mode === other);
    }
  }
});
test('unknown fields, hidden controls, oversized values and malformed identities fail closed', () => {
  const value = identity();
  for (const candidate of [null, [], 1, {}, {...value, password: 'secret'}, {...value, domain: undefined},
    {...value, authMode: 'other'}, {...value, route: 'not-a-route'}, {...value, route: value.route+'\n'},
    {...value, username: ' '}, {...value, username: 'a'.repeat(257)}, {...value, domain: '\u202eWORK'},
    {...value, route: 'rdp-route-v2|'+'x'.repeat(4096)}]) {
    assert.equal(policy.validProRdpConnectionIdentity(candidate), false);
  }
});
test('identity copies cannot mutate the prepared description', () => {
  const value = identity(), copied = policy.copyProRdpConnectionIdentity(value);
  copied.domain = 'OTHER'; assert.equal(value.domain, 'WORK');
  assert.equal(policy.sameProRdpConnectionIdentity(value, copied), false);
});

const viewPolicy = load('entry/src/main/ets/services/pro/ProRdpContinuationView.ets');
const canvasPolicy = load('entry/src/main/ets/services/RemoteCanvasTransformPolicy.ets');
const envelopePolicy = load('entry/src/main/ets/services/pro/ProConnectionEnvelope.ets');
const view = () => ({sshPane: 'terminal', sshDirectory: '', monitor: 0, scale: 2,
  panX: 320, panY: -70, inputMode: 'keyboardMouse', strictBounds: false});
const viewport = () => ({transformVersion: 2, presentedTransformVersion: 2,
  sourceWidth: 1920, sourceHeight: 1080, surfaceWidth: 1280, surfaceHeight: 800,
  viewportX: 0, viewportY: 40, viewportW: 1280, viewportH: 720});
const stats = () => ({desktopWidth: 1920, desktopHeight: 1080, renderedPaintCount: 7,
  inputGeometryReady: true, desktopResizeInProgress: false,
  displayLayoutPending: false, displayLayoutInFlight: false});

test('versioned RDP envelopes require exact identity and view; SSH V1 stays distinct', () => {
  const value = {version: 2, purpose: 'continuation', transferId: 'b'.repeat(32), channelId: 'rd_'+'c'.repeat(32),
    owner: 'owner-'+'a'.repeat(64), createdAt: 1000, expiresAt: 121000,
    connection: {protocol: 'rdp', label: 'Work RDP', host: 'desktop.example.test', port: 3389,
      username: 'alice', hostReference: 'rdp-1', view: view(), rdpIdentity: identity()}};
  assert.ok(envelopePolicy.parseProConnectionEnvelope(JSON.stringify(value), 2000));
  const variants = [v => v.version=1, v=>v.purpose='share', v=>v.connection.protocol='ssh',
    v=>delete v.connection.rdpIdentity, v=>delete v.connection.view.strictBounds,
    v=>v.connection.rdpIdentity.password='secret', v=>v.connection.username='bob',
    v=>v.connection.view.monitor=1, v=>v.connection.view.rotation=1,
    v=>v.connection.view.scale=12.01, v=>v.connection.view.sshDirectory='/hidden',
    v=>v.connection.view.strictBounds=0];
  for (const mutate of variants) {
    const candidate=JSON.parse(JSON.stringify(value)); mutate(candidate);
    assert.equal(envelopePolicy.parseProConnectionEnvelope(JSON.stringify(candidate), 2000), null);
  }
  const copy = envelopePolicy.copyProConnectionDescription(value.connection);
  copy.rdpIdentity.domain='OTHER'; copy.view.panX=0;
  assert.equal(value.connection.rdpIdentity.domain,'WORK'); assert.equal(value.connection.view.panX,320);
});
test('all RDP input modes round-trip; monitor/rotation/non-finite geometry never masquerade as restored', () => {
  for (const mode of [0,1,2]) {
    const described=viewPolicy.describeProRdpView({scale: 12,panX: 100000,panY: -100000,rotation: 0,strictContentBounds: true},mode);
    assert.equal(viewPolicy.proRdpInputModeValue(described.inputMode),mode); assert.equal(described.strictBounds,true);
  }
  for (const transform of [{scale:0}, {scale:12.01}, {panX:NaN}, {panY:Infinity}, {rotation:1}]) {
    assert.equal(viewPolicy.describeProRdpView({scale:2,panX:0,panY:0,...transform},0),null);
  }
  assert.equal(viewPolicy.describeProRdpView({scale:2,panX:0,panY:0},3),null);
  for (const change of [{sourceWidth:0},{sourceHeight:Infinity},{surfaceWidth:32769},{surfaceHeight:-1}]) {
    assert.equal(viewPolicy.restoreProRdpView(view(), {...viewport(),...change}),null);
  }
  for (const change of [{monitor:1},{strictBounds:undefined},{inputMode:'other'},{scale:NaN}]) {
    assert.equal(viewPolicy.restoreProRdpView({...view(),...change},viewport()),null);
  }
});
test('restoration uses the actual target viewport and production RDP pan clamps', () => {
  for (const [w,h] of [[720,1280],[2880,1800],[2560,1080]]) for (const strictBounds of [true,false]) {
    const target={...viewport(),surfaceWidth:w,surfaceHeight:h};
    const offered={...view(),panX:100000,panY:-100000,strictBounds};
    const actual=viewPolicy.restoreProRdpView(offered,target);
    const expected=canvasPolicy.clampCanvasTransform({scale:offered.scale,panX:offered.panX,panY:offered.panY,
      rotation:0,strictContentBounds:strictBounds},{...target,freePanInsetRatio:0.45});
    assert.equal(JSON.stringify(actual),JSON.stringify(expected));
    assert.ok(Math.abs(actual.panX)<100000 && Math.abs(actual.panY)<100000);
  }
});
test('only exact successfully presented transform and matching stable desktop dimensions are ready', () => {
  assert.equal(viewPolicy.proRdpPresentedViewReady(stats(),viewport(),2),true);
  for (const version of [0,-1,1,3,2.5,NaN]) assert.equal(viewPolicy.proRdpPresentedViewReady(stats(),viewport(),version),false);
  for (const change of [{transformVersion:4},{presentedTransformVersion:0},{presentedTransformVersion:4},
    {sourceWidth:1919},{sourceHeight:1079},{surfaceWidth:0},{surfaceHeight:Infinity}]) {
    assert.equal(viewPolicy.proRdpPresentedViewReady(stats(),{...viewport(),...change},2),false);
  }
  for (const change of [{renderedPaintCount:0},{renderedPaintCount:NaN},{inputGeometryReady:false},
    {desktopResizeInProgress:true},{displayLayoutPending:true},{displayLayoutInFlight:true},
    {desktopWidth:1280},{desktopHeight:720}]) {
    assert.equal(viewPolicy.proRdpPresentedViewReady({...stats(),...change},viewport(),2),false);
  }
});
function storeFixture() {
  const state={scope:{kind:'huawei_account',ownerScopeId:'owner-'+'a'.repeat(64),generation:1},transitions:[]};
  const localLoad=createLoader({'../AccountSessionCoordinator':{AccountSessionCoordinator:{getInstance:()=>({
    currentScope:()=>state.scope,onTransitionActivity(fn){state.transitions.push(fn);fn(false);return ()=>{};}
  })}}});
  const Store=localLoad('entry/src/main/ets/services/pro/ProRdpSessionIdentityStore.ets').ProRdpSessionIdentityStore;
  return {state,store:Store.getInstance()};
}
const nativeOwner=()=>({sessionId:23,generation:5,ownerToken:7,facadeGeneration:4,
  rendererHandle:11,decoderHandle:12,audioPlayerHandle:13});
test('native identity receipt survives PC renderer handoff but never native/account owner replacement', () => {
  const f=storeFixture(), owner=nativeOwner(), id=identity();
  assert.equal(f.store.remember('rdp-1',owner,id),true); id.domain='CHANGED';
  const retrieved=f.store.get('rdp-1',{...owner,rendererHandle:21,decoderHandle:22,facadeGeneration:15});
  assert.equal(retrieved.domain,'WORK'); retrieved.username='bob';
  assert.equal(f.store.get('rdp-1',owner).username,'alice');
  for (const change of [{sessionId:24},{generation:6},{ownerToken:8}]) assert.equal(f.store.get('rdp-1',{...owner,...change}),null);
  assert.equal(f.store.get('other',owner),null);
  for (const change of [{generation:2},{ownerScopeId:'owner-'+'b'.repeat(64)},{kind:'guest'}]) {
    const old=f.state.scope;f.state.scope={...old,...change};assert.equal(f.store.get('rdp-1',owner),null);f.state.scope=old;
  }
  f.state.transitions.forEach(fn=>fn(true));assert.equal(f.store.get('rdp-1',owner),null);
  assert.equal(f.store.remember('rdp-1',owner,identity()),false);
  f.state.transitions.forEach(fn=>fn(false));assert.equal(f.store.get('rdp-1',owner),null);
});
test('identity receipt bounds memory and only exact teardown removes a record', () => {
  const f=storeFixture(),owner=nativeOwner();
  for (const bad of [null,{...owner,sessionId:0},{...owner,generation:NaN},{...owner,ownerToken:0}]) {
    assert.equal(f.store.remember('rdp-1',bad,identity()),false);
  }
  for(let n=1;n<=17;n++) assert.equal(f.store.remember('rdp-1',{...owner,sessionId:n},identity()),true);
  assert.equal(f.store.get('rdp-1',{...owner,sessionId:1}),null);
  f.store.forget({...owner,sessionId:17,generation:6});assert.ok(f.store.get('rdp-1',{...owner,sessionId:17}));
  f.store.forget({...owner,sessionId:17});assert.equal(f.store.get('rdp-1',{...owner,sessionId:17}),null);
});
function productionPage(bindings) {
  const file='entry/src/main/ets/pages/RemoteDesktop.ets',input=fs.readFileSync(path.join(root,file),'utf8');
  const names=['stageProRdpIncoming','cancelProRdpIncoming','proRdpNativeCurrent','proRdpViewKey',
    'proRdpPresentationCurrent','submitProRdpView','waitProRdpPresentedView','prepareProRdpContinuation',
    'restoreProRdpContinuation','currentRdpControlMode','setRdpControlModePreference','applyCanvasTransform',
    'armProRdpAutoContinuation'];
  const methods=names.map(name=>{
    const start=input.search(new RegExp(`  private (?:async )?${name}\\(`));assert.ok(start>=0,name);
    const open=input.indexOf('{',start),scanner=ts.createScanner(ts.ScriptTarget.Latest,true,ts.LanguageVariant.Standard,input.slice(open));
    let depth=0,token; do { token=scanner.scan();if(token===ts.SyntaxKind.OpenBraceToken)depth++;
      if(token===ts.SyntaxKind.CloseBraceToken)depth--; }while(depth>0 && token!==ts.SyntaxKind.EndOfFileToken);
    assert.equal(depth,0,name);return input.slice(start,open+scanner.getTextPos());
  });
  const module={exports:{}};
  vm.runInNewContext(ts.transpileModule('class Subject {\n'+methods.join('\n')+'\n}\nmodule.exports=Subject;',{
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,
    {module,...bindings},{filename:file});
  return new module.exports();
}
function pageFixture() {
  const f=storeFixture(),owner=nativeOwner(),id='b'.repeat(32);
  Object.assign(f.state,{nativeOwner:owner,nativeState:2,bg:false,timers:[],view:view(),viewport:viewport(),stats:stats(),
    autoAck:true,submitFail:false,allowed:true,incomingId:id,completed:[],cancelled:[],toasts:[],preferences:[],source:null,
    closed:0,prepareWait:null});
  const state=f.state,service={incomingId:()=>state.incomingId,
    incomingRdpIdentity:(which)=>which===state.incomingId && state.allowed ? identity():null,
    restoreView:(which)=>which===state.incomingId && state.allowed ? state.view:null,
    complete(which,host,actual){if(!state.allowed)return false;state.completed.push({which,actual});return true;},
    cancelIncoming(which){state.cancelled.push(which);if(which===state.incomingId)state.incomingId='';},
    async prepare(context,source){state.source=source;if(state.prepareWait)await state.prepareWait;
      return state.allowed && source.isCurrent();},
    lastPrepareFailure:()=>'changed'};
  const hostValue=host({userId:state.scope.ownerScopeId});
  f.store.remember(hostValue.id,owner,identity());
  const page=productionPage({...viewPolicy,...canvasPolicy,
    describeProRdpConnection:(h,i,v)=>({protocol:'rdp',label:'Work',host:h.host,port:h.port,
      username:i.username,hostReference:h.id,rdpIdentity:i,view:v}),
    sameProRdpConnectionIdentity:policy.sameProRdpConnectionIdentity,
    ProRdpSessionIdentityStore:{getInstance:()=>f.store},ProContinuationService:{getInstance:()=>service},proContinuationFailureText:r=>'无法准备接续：'+r,
    normalizeRdpSessionControlMode:x=>Math.max(0,Math.min(2,Math.floor(x))),
    getContext:()=>({}),window:{findWindow:()=>({getWindowProperties:()=>({id:9})})},
    promptAction:{showToast:message=>state.toasts.push(message)},setTimeout:fn=>state.timers.push(fn)});
  Object.assign(page,{proRdpPageLive:true,proRdpIncomingId:id,proRdpContinuationEpoch:1,proRdpRestoreRunning:false,
    proRdpSourceWindowId:0,proRdpControlModeOverride:-1,rdpControlMode:0,
    connected:true,cleanupStarted:false,sessionWindowMinimized:false,surfaceReady:true,
    sessionId:owner.sessionId,rendererHandle:owner.rendererHandle,pendingHost:hostValue,
    pcWindowAfterAuthentication:false,canvasVisualFlipX:false,canvasVisualFlipY:false,
    canvasTransform:{scale:1,panX:0,panY:0,rotation:0},rendererCanvasTransformPendingVersion:2,
    canvasTransformInitialized:true,
    currentAbilityBackgroundState:()=>state.bg,getUIContext:()=>({getWindowName:()=> 'current'}),
    currentCanvasViewport:()=>page.canvasViewportSnapshot ?? state.viewport,
    refreshCanvasTransformModified:()=>{},updateRendererViewportCacheForCanvasTransform:()=>{},
    persistSessionPref:(key,value)=>state.preferences.push({key,value}),
    disconnectAndCleanup:()=>state.closed++,goBack:()=>{},
    proRemoteArming:false,proRdpManualPreparing:false,proRemoteSourceWindowId:0,
    maybeArmProRemoteContinuation:()=>{state.autoArmChecks=(state.autoArmChecks??0)+1;},
    loader:{captureDisconnectIdentity:()=>state.nativeOwner,
      ownsDisconnectIdentity:receipt=>receipt!==null && state.nativeOwner!==null &&
        ['sessionId','generation','ownerToken','facadeGeneration'].every(k=>receipt[k]===state.nativeOwner[k]),
      getConnectionState:()=>state.nativeState,getRendererViewport:()=>state.viewport,getRdpRenderStats:()=>state.stats,
      setRendererCanvasTransform(){if(state.submitFail)return 0;
        state.viewport.transformVersion+=2;
        if(state.autoAck)state.viewport.presentedTransformVersion=state.viewport.transformVersion;
        return state.viewport.transformVersion;}}});
  return {...f,state,page,service,owner,id};
}
async function settlePage(){for(let i=0;i<20;i++)await Promise.resolve();}
async function tick(f){const jobs=f.state.timers.splice(0);for(const job of jobs)job();await settlePage();}
async function finishTimers(f){for(let i=0;i<125 && f.state.timers.length;i++)await tick(f);}

test('actual target page restores mode only in current session and receipts only after new EGL acknowledgement', async()=>{
  const f=pageFixture();f.state.autoAck=false;
  const pending=f.page.restoreProRdpContinuation();await settlePage();
  assert.equal(f.page.currentRdpControlMode(),2);assert.equal(f.page.rdpControlMode,0);assert.equal(f.state.preferences.length,0);
  assert.equal(f.state.completed.length,0);assert.equal(f.state.viewport.transformVersion,4);
  f.state.viewport.presentedTransformVersion=4;await tick(f);await pending;
  assert.equal(f.state.completed.length,1);assert.equal(f.state.completed[0].actual.domain,'WORK');
  assert.equal(f.state.closed,0);assert.equal(f.page.proRdpIncomingId,'');
});
test('actual target page rejects native submission failure instead of reusing old presented acknowledgement', async()=>{
  const f=pageFixture();f.state.submitFail=true;
  await f.page.restoreProRdpContinuation();assert.equal(f.state.completed.length,0);
  assert.deepEqual(f.state.cancelled,[f.id]);assert.equal(f.state.closed,0);
});
test('actual target receipt fails closed on lifecycle, native owner, renderer, mode, Pro and account races', async()=>{
  const changes={background:f=>{f.state.bg=true;},page:f=>{f.page.proRdpPageLive=false;},
    epoch:f=>{f.page.proRdpContinuationEpoch++;},minimized:f=>{f.page.sessionWindowMinimized=true;},
    surface:f=>{f.page.surfaceReady=false;},renderer:f=>{f.page.rendererHandle++;},
    native:f=>{f.state.nativeOwner={...f.owner,generation:6};},disconnected:f=>{f.state.nativeState=1;},
    mode:f=>{f.page.setRdpControlModePreference(1);},pan:f=>{f.page.canvasTransform.panX++;},
    version:f=>{f.page.rendererCanvasTransformPendingVersion++;},
    pro:f=>{f.state.allowed=false;},account:f=>{f.state.scope={...f.state.scope,generation:2};}};
  for(const [name,mutate] of Object.entries(changes)){
    const f=pageFixture();f.state.autoAck=false;const pending=f.page.restoreProRdpContinuation();await settlePage();
    mutate(f);f.state.viewport.presentedTransformVersion=f.state.viewport.transformVersion;
    await tick(f);await pending;assert.equal(f.state.completed.length,0,name);assert.equal(f.state.closed,0,name);
  }
});
test('actual target waits boundedly for real geometry and never reports first-frame or resize gaps as success', async()=>{
  for(const field of ['inputGeometryReady','renderedPaintCount','desktopWidth','presentedTransformVersion']){
    const f=pageFixture();if(field==='presentedTransformVersion')f.state.viewport[field]=0;
    else f.state.stats[field]=field==='inputGeometryReady'?false:0;
    const pending=f.page.restoreProRdpContinuation();await settlePage();await finishTimers(f);await pending;
    assert.equal(f.state.completed.length,0,field);assert.deepEqual(f.state.cancelled,[f.id],field);
    assert.equal(f.state.closed,0,field);
  }
});
test('an old target failure cannot cancel a replacement transfer', async()=>{
  const f=pageFixture();f.state.autoAck=false;
  const pending=f.page.restoreProRdpContinuation();await settlePage();
  f.state.incomingId='d'.repeat(32);f.page.proRdpIncomingId=f.state.incomingId;f.page.proRdpContinuationEpoch++;
  await tick(f);await pending;assert.equal(f.state.cancelled.length,0);assert.equal(f.state.incomingId,'d'.repeat(32));
});
test('actual source keeps live native background preservation but refuses old identity or changed source view', async()=>{
  const f=pageFixture();f.page.proRdpIncomingId='';await f.page.prepareProRdpContinuation();
  assert.ok(f.state.source);assert.equal(f.state.source.isCurrent(),true);
  f.state.bg=true;f.page.proRdpPageLive=false;f.page.cleanupStarted=true;f.page.rendererHandle=-1;
  assert.equal(f.state.source.isCurrent(),true);
  f.state.nativeOwner={...f.owner,generation:6};assert.equal(f.state.source.isCurrent(),false);
  f.state.nativeOwner=f.owner;f.page.canvasTransform.scale=3;assert.equal(f.state.source.isCurrent(),false);
  assert.equal(f.state.closed,0);
});
test('automatic RDP arming reads the view at continuation time and survives view changes', async()=>{
  const f=pageFixture();f.page.proRdpIncomingId='';
  assert.equal(await f.page.armProRdpAutoContinuation(),true);
  const source=f.state.source;assert.ok(source);assert.equal(f.page.proRemoteSourceWindowId,9);
  assert.equal(source.describe().view.scale,1);
  f.page.canvasTransform.scale=2;
  assert.equal(source.isCurrent(),true,'a zoom does not invalidate the always-on source');
  assert.equal(source.describe().view.scale,2,'the target gets the view current at continuation');
  f.page.canvasVisualFlipX=true;assert.equal(source.describe(),null);f.page.canvasVisualFlipX=false;
  f.state.nativeOwner={...f.owner,generation:6};assert.equal(source.isCurrent(),false);
  f.state.nativeOwner=f.owner;f.store.forget(f.owner);assert.equal(source.isCurrent(),false);
  assert.equal(await f.page.armProRdpAutoContinuation(),false,'no verified identity, no arming');
});
test('the control-center action suppresses auto arming while it prepares, then re-checks', async()=>{
  const f=pageFixture();f.page.proRdpIncomingId='';
  await f.page.prepareProRdpContinuation();
  assert.equal(f.page.proRdpManualPreparing,false);assert.equal(f.page.proRemoteSourceWindowId,9);
  assert.equal(f.state.autoArmChecks,1);
});
test('actual source preparation rejects background during permission await and missing native receipts', async()=>{
  const f=pageFixture();f.page.proRdpIncomingId='';let resolve;
  f.state.prepareWait=new Promise(r=>{resolve=r;});const pending=f.page.prepareProRdpContinuation();await settlePage();
  f.state.bg=true;resolve();await pending;assert.equal(f.state.source.isCurrent(),false);
  assert.ok(f.state.toasts.at(-1).message.includes('无法准备'));assert.equal(f.state.closed,0);
  const missing=pageFixture();missing.store.forget(missing.owner);await missing.page.prepareProRdpContinuation();
  assert.equal(missing.state.source,null);
});
test('actual target route IDs are whitelist-only and cancellation is exact',()=>{
  const f=pageFixture();f.page.stageProRdpIncoming({proConnectionTransferId:f.id});assert.equal(f.page.proRdpIncomingId,f.id);
  f.page.stageProRdpIncoming({proConnectionTransferId:'not-an-id'});assert.equal(f.page.proRdpIncomingId,'');
  assert.deepEqual(f.state.cancelled,[f.id]);
  f.state.incomingId='c'.repeat(32);f.page.stageProRdpIncoming({proConnectionTransferId:f.id});assert.equal(f.page.proRdpIncomingId,'');
});

(async () => {
  for (const {name, body} of tests) {
    await body(); console.log('PASS ' + name);
  }
  console.log(`${tests.length} RDP continuation checks passed`);
})().catch(error => { console.error(error); process.exitCode = 1; });
