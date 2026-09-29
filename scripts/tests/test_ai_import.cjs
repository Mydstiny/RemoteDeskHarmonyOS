/* Production ArkTS regression with controlled platform ports. No device acceptance claim. */
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require(process.env.AI_TYPESCRIPT_PATH || 'typescript');
const base=require('node:path').resolve(__dirname, '../../entry/src/main/ets/services/ai') + '/';
const tick=()=>new Promise(resolve=>setImmediate(resolve));
const owner='owner-'+'a'.repeat(64);
let resolveDrain, imported=0, importedLease, seq=0;
const transitionListeners=[],accountListeners=[],proListeners=[];
const account={currentScope:()=>({kind:'huawei_account',ownerScopeId:owner,generation:1,sessionState:'ready'}),
  onTransitionActivity:f=>{transitionListeners.push(f);f(false);return()=>{};},onChange:f=>{accountListeners.push(f);return()=>{};}};
const settings={showExecution:true,textSize:15,reconnectOnForeground:true,defaultBackend:'codex'};
const document={version:1,hosts:[{label:'Imported',backend:'codex',address:'127.0.0.1',port:9443,serverName:'',groupId:'',sortOrder:0,transport:'lan'}],settings};
const bytes=new TextEncoder().encode(JSON.stringify(document));
const modules=new Map();
const mocks={
  '../EndpointAddressPolicy':{parseEndpointHost:()=>({ok:true}),parseEndpointServerIdentity:()=>({ok:true})},
  '../AccountSessionCoordinator':{AccountSessionCoordinator:{getInstance:()=>account}},
  '../pro/ProAppRuntime':{ProAppRuntime:{getInstance:()=>({runtime:{subscribe:f=>{proListeners.push(f);f();return()=>{};},decision:()=>({executable:true})},context:()=>({})})}},
  '../pro/ProFeatureVisibility':{ProFeatureVisibility:{getInstance:()=>({isVisible:()=>true,subscribe:f=>{f();return()=>{};}})}},
  '@kit.CoreFileKit':{picker:{DocumentViewPicker:class{async select(){return['fixtureUri'];}}},fileIo:{OpenMode:{READ_ONLY:0},openSync:()=>({fd:1}),statSync:()=>({size:bytes.length}),readSync:(_fd,buffer)=>{new Uint8Array(buffer).set(bytes);return bytes.length;},closeSync(){}}},
  '@kit.ArkTS':{util:{TextDecoder:{create:()=>({decodeToString:data=>new TextDecoder().decode(data)})}}},
  './AiTransport':{AiTransport:{drain:()=>new Promise(resolve=>{resolveDrain=resolve;})},aiRandomId:()=> 'fixture'+(++seq)},
  './AiLocalStore':{AiLocalStore:{getInstance:()=>({importHosts:async(lease,hosts,prefs)=>{load('AiAccess').AiAccess.getInstance().assertCurrent(lease);imported++;importedLease=lease;assert.equal(hosts[0].owner,owner);assert.deepEqual(prefs,settings);}})}}
};
function load(name){if(modules.has(name))return modules.get(name).exports;const module={exports:{}};modules.set(name,module);
  const code=ts.transpileModule(fs.readFileSync(base+name+'.ets','utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  vm.runInNewContext('(function(require,module,exports){'+code+'\n})',{Promise,Map,Set,Array,Object,JSON,Date,Number,Error,Uint8Array})(key=>mocks[key]||load(key.slice(2)),module,module.exports);return module.exports;
}
async function scenario(kind){
  resolveDrain=undefined;imported=0;importedLease=undefined;modules.clear();transitionListeners.length=0;accountListeners.length=0;proListeners.length=0;
  const lifecycle=load('AiLifecycle').AiLifecycle;
  const operation=load('AiDataTransfer').AiDataTransfer.importConfig();
  for(let i=0;i<50&&!resolveDrain;i++)await tick();assert.equal(typeof resolveDrain,'function');
  const importEpoch=lifecycle.generation();
  if(kind==='invalidate'){transitionListeners.forEach(f=>f(true));transitionListeners.forEach(f=>f(false));assert.notEqual(lifecycle.generation(),importEpoch);}
  resolveDrain(kind!=='drain-failure');
  if(kind==='invalidate'){await assert.rejects(operation,/AI_ACCOUNT_CHANGED/);assert.equal(imported,0);}
  else if(kind==='drain-failure'){await assert.rejects(operation,/AI_RESTORE_DRAIN_FAILED/);assert.equal(imported,0);}
  else{assert.equal(await operation,1);assert.equal(imported,1);assert.equal(importedLease.lifecycle,lifecycle.generation());}
  assert.equal(lifecycle.restoring(),false);
  console.log('PASS actual AiDataTransfer import '+kind+' preserves ownership and releases admission');
}
(async()=>{await scenario('invalidate');await scenario('drain-failure');await scenario('success');})().catch(error=>{console.error(error);process.exitCode=1;});
