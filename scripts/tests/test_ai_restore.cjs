/* Production ArkTS regression with controlled platform ports. No device acceptance claim. */
const fs=require('node:fs'), vm=require('node:vm'), assert=require('node:assert/strict');
const ts=require(process.env.AI_TYPESCRIPT_PATH || 'typescript');
const base=require('node:path').resolve(__dirname, '../../entry/src/main/ets/services') + '/';
function compile(file, mocks) {
  const code=ts.transpileModule(fs.readFileSync(base+file,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  const module={exports:{}};
  vm.runInNewContext('(function(require,module,exports){'+code+'\n})',{Promise,Map,Set,Array,Object,JSON,Date,Number,Error})(key=>mocks[key]||{},module,module.exports);
  return module.exports;
}
async function scenario(drainResult, workResult) {
  const lifecycle=compile('ai/AiLifecycle.ets',{}).AiLifecycle;
  const counters={cancel:0,drain:0,restore:0};
  const lease={ownerScopeId:'fixtureOwner',generation:1};
  const cloud={currentScope:()=>lease,currentAccountLease:()=>lease,mergePortableBackup:async()=>workResult};
  const mocks={
    './ai/AiLifecycle':{AiLifecycle:lifecycle},
    './ai/AiTransport':{AiTransport:{cancelAll:()=>counters.cancel++,drain:async()=>{counters.drain++;assert.equal(lifecycle.restoring(),true);if(drainResult==='throw')throw Error('fixture-drain');return drainResult;}}},
    './CloudStore':{CloudStore:{getInstance:()=>cloud}},
    './CloudSyncCoordinator':{CloudSyncCoordinator:{getInstance:()=>({runExclusiveRestore:async work=>{counters.restore++;assert.equal(lifecycle.restoring(),true);if(workResult==='throw')throw Error('fixture-restore');return await work();}})}},
    './LocalBackupPolicy':{portableBackupScopeLeaseAllowed:()=>true,localBackupSha256:()=> 'fixtureFingerprint',adaptLocalBackupDocumentForRestore:()=>({})},
    './CloudLifecycleSafetyPolicy':{portableBackupRestoreAllowed:()=>true},
    './AccountScopePolicy':{accountSessionLeaseEquals:(a,b)=>a===b}
  };
  const service=compile('LocalBackupService.ets',mocks).LocalBackupService.getInstance();
  service.selectedLease=lease;service.selectedDocumentFingerprint='fixtureFingerprint';
  let outcome, error;
  try{outcome=await service.restore({version:3});}catch(e){error=e;}
  assert.equal(lifecycle.restoring(),false,'restoration admission must reopen after completion/failure');
  assert.equal(lifecycle.generation(),1,'restore must invalidate old operations');
  if(drainResult===false){assert.equal(counters.restore,0,'failed drain must not start restore');assert.equal(outcome,false);}
  else if(drainResult==='throw'){assert.equal(counters.restore,0);assert.ok(error||outcome===false);}
  else if(workResult==='throw'){assert.equal(counters.restore,1);assert.ok(error||outcome===false);}
  else {assert.equal(counters.restore,1);assert.equal(outcome,workResult);}
  console.log('PASS actual LocalBackupService.restore drain='+drainResult+' work='+workResult);
}
(async()=>{await scenario(false,true);await scenario('throw',true);await scenario(true,false);await scenario(true,'throw');await scenario(true,true);})().catch(error=>{console.error(error);process.exitCode=1;});
