/* Requires Node with node:sqlite; executes production SQL and ArkTS methods. */
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {DatabaseSync}=require('node:sqlite');
const ts=require(process.env.AI_TYPESCRIPT_PATH || 'typescript');
const base=require('node:path').resolve(__dirname, '../../entry/src/main/ets/services/ai') + '/';
function environment(){
  const modules=new Map(),subscribers=new Set();let executable=true,seq=0,connectHook;
  const account={owner:'fixtureOwner',generation:1,lifecycle:1};
  const access={assertCurrent(){},executable:()=>executable,current:()=>true,subscribe(fn){subscribers.add(fn);fn();return()=>subscribers.delete(fn);}};
  let readHook=async method=>method==='project.list'?[{id:'project',title:'Project'}]:{data:[]};
  const client={host:{id:'fixtureHost',backend:'codex'},account,close(){},stopEvents(){},capability:()=>false,
    read:(method,params)=>readHook(method,params)};
  connectHook=async()=>client;
  const mocks={'./AiAccess':{AiAccess:{getInstance:()=>access}},'./AiBridgeClient':{AiBridgeClient:{connect:()=>connectHook()}},
    './AiTransport':{aiRandomId:()=> 'writer'+(++seq)},
    '../EndpointAddressPolicy':{parseEndpointHost:()=>({ok:true}),parseEndpointServerIdentity:()=>({ok:true})},
    '@kit.ArkData':{relationalStore:{}},'@kit.ArkTS':{util:{TextEncoder:class{encodeInto(text){return new TextEncoder().encode(text);}}}}};
  function load(name){if(modules.has(name))return modules.get(name).exports;const module={exports:{}};modules.set(name,module);
    const source=ts.transpileModule(fs.readFileSync(base+name+'.ets','utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
    vm.runInNewContext('(function(require,module,exports){'+source+'\n})',{Promise,Map,Set,Array,Object,JSON,Date,Number,Error,setInterval,clearInterval,setTimeout,clearTimeout})
      (key=>mocks[key]||load(key.slice(2)),module,module.exports);return module.exports;}
  return{load,account,client,subscribers,onRead(fn){readHook=fn;},onConnect(fn){connectHook=fn;},pro(value){executable=value;[...subscribers].forEach(fn=>fn());}};
}
function rows(values){let at=-1;return{goToNextRow(){return++at<values.length;},goToFirstRow(){at=0;return values.length>0;},getString(i){return values[at][i];},getLong(i){return values[at][i];},close(){}};}
function storeEnvironment(){
  const e=environment(),db=new DatabaseSync(':memory:');
  db.exec('CREATE TABLE ai_operations(owner TEXT,id TEXT,host TEXT,session TEXT,created INTEGER,body TEXT,receipt TEXT,PRIMARY KEY(owner,id))');
  const store=e.load('AiLocalStore').AiLocalStore.getInstance();
  store.store={beginTransaction(){db.exec('BEGIN');},commit(){db.exec('COMMIT');},rollBack(){db.exec('ROLLBACK');},
    async querySql(sql,params){const statement=db.prepare(sql);statement.setReturnArrays(true);return rows(statement.all(...params));},
    async executeSql(sql,params){db.prepare(sql).run(...params);}};
  function seed(id,body,receipt,created,owner=e.account.owner){db.prepare('INSERT INTO ai_operations VALUES (?,?,?,?,?,?,?)').run(owner,id,'fixtureHost','session',created,body,typeof receipt==='string'?receipt:JSON.stringify(receipt));}
  const operation={id:'newOperation',hostId:'fixtureHost',sessionId:'session',createdAt:10000,body:'new operation',receipt:''};
  return{...e,db,store,seed,operation};
}
(async()=>{
  {
    const e=environment(),c=new(e.load('AiWorkspaceController').AiWorkspaceController)();
    e.onRead(async method=>{if(method==='project.list')return[{id:'project'}];throw Error('fixture session failure');});
    await c.connect(e.client.host);assert.equal(c.busy,false);assert.equal(c.status,'连接未完成');assert.ok(c.error);c.close();assert.equal(e.subscribers.size,0);
    console.log('PASS connect catch finishes busy/error after project selection changes generation');
  }
  {
    const e=environment(),c=new(e.load('AiWorkspaceController').AiWorkspaceController)();await c.connect(e.client.host);
    assert.equal(c.allowed,true);e.pro(false);assert.equal(c.allowed,false);e.pro(true);assert.equal(c.allowed,false);assert.match(c.status,/重新连接/);
    await c.connect(e.client.host);assert.equal(c.allowed,true);c.close();console.log('PASS restored Pro remains disabled until explicit reconnect resets revocation');
  }
  {
    const e=environment(),c=new(e.load('AiWorkspaceController').AiWorkspaceController)();c.client=e.client;c.sessionId='session';
    e.onRead(async()=>({session:{},snapshot:{turns:[],inputModalities:['text','image']}}));await c.snapshot(false);
    assert.deepEqual(Array.from(c.inputModalities),['text','image']);c.close();assert.equal(c.inputModalities.length,0);
    c.client=e.client;c.sessionId='other';e.onRead(async()=>({session:{},snapshot:{turns:[]}}));await c.snapshot(false);assert.equal(c.inputModalities.length,0);c.close();
    console.log('PASS snapshot records native input modalities and absent/new connection clears them');
  }
  {
    const e=storeEnvironment();try{
      for(let i=0;i<20;i++)e.seed('completed'+i,'x'.repeat(700000),{status:i%2?'rejected':'succeeded'},i);
      for(const status of ['pending','unknown','running'])e.seed(status,'pending',{status},100);
      e.seed('empty','pending','',101);e.seed('otherOwner','untouched',{status:'succeeded'},1,'otherOwner');
      await e.store.retainOperation(e.account,e.operation);
      assert.equal(e.db.prepare('SELECT COUNT(*) n FROM ai_operations WHERE owner=? AND id LIKE ?').get(e.account.owner,'completed%').n,11);
      for(const id of ['pending','unknown','running','empty','otherOwner','newOperation'])assert.ok(e.db.prepare('SELECT id FROM ai_operations WHERE id=?').get(id));
      assert.ok(e.db.prepare('SELECT id FROM ai_operations WHERE id=?').get('completed19'));assert.equal(e.db.prepare('SELECT id FROM ai_operations WHERE id=?').get('completed0'),undefined);
      console.log('PASS production retention SQL keeps newest completed bodies under 8 MiB and preserves unresolved/other-owner rows');
    }finally{e.db.close();}
  }
  {
    const e=storeEnvironment();try{for(let i=0;i<205;i++)e.seed('completed'+i,'small',{status:'succeeded'},i);await e.store.retainOperation(e.account,e.operation);
      assert.equal(e.db.prepare('SELECT COUNT(*) n FROM ai_operations WHERE id LIKE ?').get('completed%').n,200);
      console.log('PASS production retention keeps only newest 200 completed operations');
    }finally{e.db.close();}
  }
  {
    const e=environment(),p=e.load('AiPresentation');
    const text=p.aiFileChanges([{path:'created.txt',kind:{type:'add'},diff:'+created'},{path:'deleted.txt',kind:{type:'delete'},diff:'-deleted'},
      {path:'old.txt',kind:{type:'update',move_path:'new.txt'},diff:'-old\n+new'}]);
    for(const expected of ['新增 created.txt','删除 deleted.txt','修改 old.txt → new.txt','+created','-deleted','-old\n+new'])assert.ok(text.includes(expected));
    assert.match(p.aiApprovalDetails({kind:'fileChange',nativeItemComplete:false,nativeItem:{changes:[]}}),/预览不可用/);
    assert.ok(p.aiApprovalDetails({kind:'fileChange',nativeItemComplete:true,nativeItem:{changes:[{path:'file',kind:'add',diff:'+line'}]}}).includes('新增 file'));
    console.log('PASS file preview labels add/delete/update/move and incomplete preview fails closed');
  }
})().catch(error=>{console.error(error);process.exitCode=1;});
