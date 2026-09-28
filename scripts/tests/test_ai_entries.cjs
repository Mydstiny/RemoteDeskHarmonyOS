/* Actual host-entry policies and extracted protocol callback regression. */
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const ts=require(process.env.AI_TYPESCRIPT_PATH || 'typescript');
const root=path.resolve(__dirname, '../../entry/src/main') + '/';
const modules=new Map();
class RemoteHost{constructor(){this.host='';this.username='';this.groupId='';this.lastHealth=0;this.lastConnected=0;}static getDefaultPort(p){return p==='ssh'?22:p==='vnc'?5900:p==='rustdesk'?21116:3389;}}
const mocks={'../model/RemoteHost':{RemoteHost,ConnectionHealth:{UNKNOWN:0}},'../../model/RemoteHost':{RemoteHost},
  './AiAccess':{AiAccess:{getInstance:()=>({capture:()=>({owner:'fixtureOwner'})})}},'./AiLocalStore':{AiLocalStore:{}}};
function load(file){if(modules.has(file))return modules.get(file).exports;const module={exports:{}};modules.set(file,module);
  const source=ts.transpileModule(fs.readFileSync(path.join(root,'ets',file+'.ets'),'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  vm.runInNewContext('(function(require,module,exports){'+source+'\n})',{Promise,Map,Set,Array,Object,JSON,Date,Number,Error})
    (key=>mocks[key]||load(path.posix.normalize(path.posix.join(path.posix.dirname(file),key))),module,module.exports);return module.exports;}
const projected=load('services/ai/AiHostService').projectAiHost({id:'codexHost',label:'Workstation',backend:'codex',address:'127.0.0.1',port:9443,groupId:'dev',sortOrder:0,lastConnected:0});
const rdp=Object.assign(new RemoteHost(),{id:'rdpHost',label:'Desktop',protocol:'rdp'});
const filter=load('services/HostListFilterService'),group=load('services/HostGroupCardPolicy');
assert.equal(projected.id,'ai:codexHost');assert.equal(projected.protocol,'ai');assert.equal(load('services/ai/AiHostService').aiHostId(projected),'codexHost');
assert.equal(group.buildHostGroupCards([projected,rdp]).find(row=>row.type==='ai').hosts.length,1);
assert.equal(group.hostGroupTitle('ai'),'远程 AI');
assert.deepEqual(Array.from(filter.visibleHostsForHostListMode([projected,rdp],'',true,'xl','',8),host=>host.id),['ai:codexHost']);
assert.equal(filter.visibleHostsForHostListMode([projected,rdp],'codex',false,'sm','',0).length,1);
for(let i=0;i<4;i++)assert.equal(filter.hostListProtocolForTab(i),['rdp','rustdesk','ssh','vnc'][i]);
console.log('PASS namespaced AI card appears in grouped, desktop AI filter, and Codex search; old tabs remain mapped');
const picker=load('services/HostProtocolPickerPolicy');let selected='';picker.dispatchSelectedHostProtocol(picker.resolveHostProtocolPickerOption('ai',true),protocol=>selected=protocol);assert.equal(selected,'ai');
let blocked='';const blockedAi=picker.resolveHostProtocolPickerOption('ai',true,false,false);
picker.dispatchSelectedHostProtocol(blockedAi,protocol=>blocked=protocol);
assert.equal(blocked,'');assert.equal(blockedAi.statusLabel,'需要 Pro');
console.log('PASS non-Pro AI picker is visible only as a blocked route and cannot dispatch');
const catalog=load('services/pro/ProFeatureCatalog').proFeatures();for(const id of ['pro.ai.workspace','pro.ai.codex','pro.ai.dsh']){
  const item=catalog.find(item=>item.id===id);assert.equal(item.requiredEntitlementId,'pro.lifetime');assert.equal(item.availability,'available');assert.deepEqual(Array.from(item.protocols),['ai']);}
assert.equal(catalog.find(item=>item.id==='pro.ai.rustdeskTransport').availability,'planned');
const pages=JSON.parse(fs.readFileSync(path.join(root,'resources/base/profile/main_pages.json'),'utf8')).src;
for(const route of ['pages/RemoteAiWorkspace','pages/AiSettingsPage']){assert.equal(pages.filter(page=>page===route).length,1);assert.ok(fs.existsSync(path.join(root,'ets',route+'.ets')));}
console.log('PASS picker route, Pro declarations, deferred relay, and both page registrations are consistent');
const hostSource=fs.readFileSync(path.join(root,'ets/pages/HostListPage.ets'),'utf8');
assert.ok(hostSource.includes('filterHostGroupCardsByProVisibility'),
  'homepage grouped cards must pass through the shared Pro visibility policy');
assert.ok(hostSource.includes("isHostGroupTypeVisibleByPro('ai'"),
  'homepage AI group renderer must be entitlement-gated');
const sheet=hostSource.slice(hostSource.indexOf('@Builder hostAddSheetContent()'));
const callback=sheet.slice(sheet.indexOf('onSelectProtocol: ')+18,sheet.indexOf(',\n        onClose:'));
const callbackJs=ts.transpileModule('(function(){return '+callback+';});', {compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText;
const bindSelect=vm.runInNewContext(callbackJs,{RemoteHost});
const layout=load('services/HostAddSheetLayoutPolicy');
function activeHostAddProtocol(){return layout.resolveActiveHostAddProtocol(this.modernAddProtocol,this.proto,this.addSheetShowsModernPicker);}
const state={proto:'ai',modernAddProtocol:'',addSheetShowsModernPicker:true,activeHostAddProtocol,switchHostProtocol(p){this.proto=p;}};
bindSelect.call(state)('rdp');assert.equal(state.modernAddProtocol,'rdp');
const match=sheet.match(/\} else if \(([^\n]+)\) \{\n      AiHostEditor/);assert.ok(match);
const rendersAi=Function('return ('+match[1]+')');
assert.equal(rendersAi.call(state),false,'Selecting RDP from desktop AI picker must not render AiHostEditor');
assert.equal(rendersAi.call({modernAddProtocol:'',proto:'ai',activeHostAddProtocol}),true);
assert.equal(rendersAi.call({modernAddProtocol:'ai',proto:'rdp',activeHostAddProtocol}),true);
console.log('PASS actual picker callback and AI branch precedence route RDP, modern AI, and classic AI correctly');
