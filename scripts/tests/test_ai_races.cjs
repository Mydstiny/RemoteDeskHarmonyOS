/* Production ArkTS regression with controlled platform ports. No device acceptance claim. */
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const ts = require(process.env.AI_TYPESCRIPT_PATH || 'typescript');
const root = require('node:path').resolve(__dirname, '../../entry/src/main/ets/services/ai');
const owner = 'owner-' + 'a'.repeat(64);
const tick = () => new Promise(r => setImmediate(r));
function environment() {
  const modules = new Map(), transitionListeners = [], accountListeners = [], proListeners = [];
  let pro = true, transition = false, seq = 0, dnsResolve, delayedDns = false;
  const scope = { kind: 'huawei_account', ownerScopeId: owner, generation: 1, sessionState: 'ready' };
  const host = { id: 'fixtureHost', owner, revision: 1, label: 'Original', backend: 'codex',
    address: 'host.test', port: 9443, serverName: '', groupId: '', sortOrder: 0,
    lastConnected: 0, createdAt: 1, transport: 'lan', relayHostId: '', projectId: '' };
  let storedHost = {...host}, identityHook = () => {};
  const identity = {ca: 'CERT', certificate: 'CERT', privateKey: 'KEY', deviceId: 'fixtureDevice', instance: 'fixtureInstance'};
  const nativeCalls = [], savedReceipts = [], retained = [], cancelled = [];
  const account = { currentScope: () => ({...scope}),
    onTransitionActivity: f => { transitionListeners.push(f); f(transition); return () => {}; },
    onChange: f => {accountListeners.push(f); return () => {};} };
  const proRuntime = {runtime: {subscribe: f => {proListeners.push(f); f(); return () => {};},
    decision: () => ({executable: pro, visible: pro})}, context: () => ({})};
  const store = {connection: async () => {const snapshot={host:{...storedHost},identity:{...identity}};identityHook();return snapshot;},
    retainOperation: async (_a, op) => retained.push(op), saveReceipt: async (_a, id, receipt) => savedReceipts.push({id,receipt})};
  const encode = value => new TextEncoder().encode(JSON.stringify(value)).buffer;
  const mocks = {
    '../AccountSessionCoordinator': {AccountSessionCoordinator: {getInstance: () => account}},
    '../pro/ProAppRuntime': {ProAppRuntime: {getInstance: () => proRuntime}},
    '../EndpointAddressPolicy': {parseEndpointHost: value => ({ok: true, endpoint: {family: value.includes('.test') ? 'hostname' : 'ipv4'}}), parseEndpointServerIdentity: () => ({ok: true})},
    './AiLocalStore': {AiLocalStore: {getInstance: () => store}},
    '@kit.ArkTS': {util: {TextEncoder: class {encodeInto(text) {return new TextEncoder().encode(text);}},
      TextDecoder: {create: (_encoding, options) => {const decoder=new TextDecoder('utf-8', options); return {decodeToString: (bytes, settings) => decoder.decode(bytes, settings)};}}}},
    '@kit.NetworkKit': {connection: {getAddressesByName: async () => delayedDns ? await new Promise(resolve => {dnsResolve = resolve;}) : [{address:'127.0.0.1'}]}},
    '@kit.CryptoArchitectureKit': {cryptoFramework: {createRandom: () => ({generateRandomSync: () => ({data: new Uint8Array(24).fill(++seq)})})}},
    'librdpnapi.so': {default: {aiCancelRequest: options => cancelled.push(options.id), aiTlsRequest: async options => {
      const body = JSON.parse(options.body); nativeCalls.push(body);
      if (body.method === 'handshake') return {status:200, body: encode({result:{version:1,engine:'codex',instance:'fixtureInstance',deviceId:'fixtureDevice',runtime:'fixtureRuntime',role:'operator',epoch:{id:'fixtureEpoch',device:'fixtureDevice',expires:Date.now()+600000},capabilities:{}}})};
      return {status:200, body:encode({operation:{operationId:body.operationId,epoch:body.epoch,status:'succeeded',result:body.method==='lease.acquire'?{lease:'fixtureLease'}:body.method==='lease.renew'?{expires:Date.now()+90000}:{ok:true}}})};
    }}}
  };
  function load(name) {
    if (modules.has(name)) return modules.get(name).exports;
    const module={exports:{}}; modules.set(name,module);
    const source=ts.transpileModule(fs.readFileSync(path.join(root,name+'.ets'),'utf8'), {compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
    vm.runInNewContext('(function(require,module,exports){'+source+'\n})', {Promise,Map,Set,Array,Object,JSON,Date,Number,Error,Uint8Array,ArrayBuffer,setTimeout,clearTimeout})(key => {
      if (key in mocks) return mocks[key];
      if (key.startsWith('./')) return load(key.slice(2));
      if (key === '../AccountScopePolicy') return {};
      throw Error('Unexpected import '+key);
    },module,module.exports);
    return module.exports;
  }
  return {load, host, nativeCalls, savedReceipts, retained, cancelled,
    useRealStore() {delete mocks['./AiLocalStore']; mocks['@kit.ArkData']={relationalStore:{}};},
    revoke() {pro=false; proListeners.forEach(f=>f());},
    editDuringIdentity() {identityHook=()=>{storedHost={...storedHost,revision:2,label:'Edited'};load('AiLifecycle').AiLifecycle.closeHost(host.id);};},
    delayDns() {delayedDns=true;}, get dnsPending() {return typeof dnsResolve === 'function';},
    releaseDns() {dnsResolve([{address:'127.0.0.1'}]);},
    transitionCycle() {transition=true;transitionListeners.forEach(f=>f(true));transition=false;transitionListeners.forEach(f=>f(false));}
  };
}
(async () => {
  {
    const e=environment(), access=e.load('AiAccess').AiAccess.getInstance(), lease=access.capture();
    e.load('AiLifecycle').AiLifecycle.invalidateAll();
    assert.equal(access.current(lease),false);
    const lease2=access.capture();e.transitionCycle(); assert.equal(access.current(lease2),false);
    const lifecycle=e.load('AiLifecycle').AiLifecycle,end=lifecycle.beginRestore();assert.throws(()=>access.capture(),/AI_ACCOUNT_UNAVAILABLE/);end();end();assert.equal(lifecycle.restoring(),false);
    console.log('PASS old leases stay invalid after invalidateAll and failed transition; nested-safe restore blocks admission');
  }
  {
    const e=environment();e.useRealStore();
    const access=e.load('AiAccess').AiAccess.getInstance(), lease=access.capture();
    const store=e.load('AiLocalStore').AiLocalStore.getInstance();
    let unblock, committed=false;
    store.store={beginTransaction(){},executeSql:async()=>{},commit(){committed=true;},rollBack(){}};
    store.queue=new Promise(resolve=>{unblock=resolve;});
    const pending=store.saveSettings(lease,{showExecution:true,textSize:15,reconnectOnForeground:true,defaultBackend:'codex'});
    e.load('AiLifecycle').AiLifecycle.invalidateAll();unblock();await assert.rejects(pending,/AI_ACCOUNT_CHANGED/);
    assert.equal(committed,false);
    console.log('PASS queued production AiLocalStore write rejects after lifecycle invalidation');
  }
  {
    const e=environment(); e.editDuringIdentity();
    await assert.rejects(e.load('AiBridgeClient').AiBridgeClient.connect(e.host),/AI_HOST_CHANGED/);
    assert.equal(e.nativeCalls.length,0);
    console.log('PASS changed host revision prevents connection before native handshake');
  }
  {
    const e=environment(); const client=await e.load('AiBridgeClient').AiBridgeClient.connect(e.host);
    e.delayDns();
    const result=client.write('turn.start',{sessionId:'fixtureSession',lease:'fixtureLease',text:'fixture'},'fixtureSession').then(()=>'',error=>error.message);
    for(let i=0;i<50&&!e.dnsPending;i++) await tick(); assert.equal(e.dnsPending,true);
    e.revoke(); assert.equal(e.cancelled.length,1);e.releaseDns();
    assert.equal(await result,'AI_REQUEST_CANCELLED');
    assert.equal(e.nativeCalls.filter(call=>call.method==='turn.start').length,0);
    assert.equal(e.retained.length,1);assert.equal(e.savedReceipts.length,0);client.close();
    console.log('PASS revoked Pro cancels DNS-pending turn.start before dispatch');
  }
  {
    const e=environment(),client=await e.load('AiBridgeClient').AiBridgeClient.connect(e.host);
    await client.write('lease.acquire',{sessionId:'fixtureSession'},'fixtureSession');
    await client.write('lease.renew',{sessionId:'fixtureSession',lease:'fixtureLease'},'fixtureSession');
    e.revoke();
    await assert.rejects(client.write('turn.cancel',{sessionId:'other',lease:'fixtureLease'},'other'),/AI_OWNED_LEASE_REQUIRED/);
    await assert.rejects(client.write('turn.start',{sessionId:'fixtureSession',lease:'fixtureLease',text:'fixture'},'fixtureSession'),/AI_RECONNECT_REQUIRED/);
    await client.write('turn.cancel',{sessionId:'fixtureSession',lease:'fixtureLease'},'fixtureSession');
    await client.write('lease.release',{sessionId:'fixtureSession',lease:'fixtureLease'},'fixtureSession');
    await assert.rejects(client.write('turn.cancel',{sessionId:'fixtureSession',lease:'fixtureLease'},'fixtureSession'),/AI_OWNED_LEASE_REQUIRED/);
    assert.equal(e.nativeCalls.filter(call=>call.method==='turn.cancel').length,1);
    assert.equal(e.savedReceipts.length,4);client.close();
    console.log('PASS revoked client retains only owned cleanup; renew retains original token and release removes it');
  }
  {
    const e=environment();const client=await e.load('AiBridgeClient').AiBridgeClient.connect(e.host);
    e.delayDns();const result=client.write('turn.start',{sessionId:'fixtureSession',lease:'fixtureLease',text:'fixture'},'fixtureSession').then(()=>'',error=>error.message);
    for(let i=0;i<50&&!e.dnsPending;i++)await tick();assert.equal(e.dnsPending,true);
    client.close();assert.equal(await e.load('AiTransport').AiTransport.drain(100),true);
    assert.equal(await result,'AI_REQUEST_CANCELLED');e.releaseDns();await tick();
    assert.equal(e.nativeCalls.filter(call=>call.method==='turn.start').length,0);
    console.log('PASS explicit close cancels DNS pending write; late resolver never dispatches');
  }
})().catch(error => {console.error(error);process.exitCode=1;});
