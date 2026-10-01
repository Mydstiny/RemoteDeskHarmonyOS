// The Pro management list explains each entitlement decision without granting anything.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const file = path.join(__dirname, '../../entry/src/main/ets/services/pro/ProFeatureStatus.ets');
const loaded = { exports: {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText,
{ module: loaded, exports: loaded.exports, require: () => ({}) }, { filename: file });
const { proFeatureStatus, proFeatureScope } = loaded.exports;
const feature = (overrides = {}) => ({ id: 'pro.test', title: 'T', description: '', requiredEntitlementId: 'pro.lifetime',
  availability: 'available', minAppVersionCode: 0, minApiVersion: 26, devices: ['phone', 'tablet', 'pc'],
  protocols: ['ssh', 'rdp'], capabilities: [], permissions: [], serverAuthorized: false, ...overrides });
const denied = reason => ({ visible: false, executable: false, reason });
assert.equal(proFeatureStatus(feature(), { visible: true, executable: true, reason: 'allowed' }, false).label, '可用');
assert.equal(proFeatureStatus(feature(), denied('purchaseRequired'), false).label, '需要 Pro');
assert.equal(proFeatureStatus(feature(), denied('verificationRequired'), false).label, '等待验证');
const experimental = proFeatureStatus(feature({ availability: 'experimental' }), denied('planned'), true);
assert.equal(experimental.label, '实验中'); assert.match(experimental.detail, /沙盒或模拟/);
assert.equal(proFeatureStatus(feature({ availability: 'experimental' }), denied('planned'), false).detail, '正式版暂未开放');
assert.equal(proFeatureStatus(feature({ availability: 'planned' }), denied('planned'), true).label, '规划中');
assert.match(proFeatureStatus(feature({ devices: ['pc'] }), denied('deviceUnsupported'), false).detail, /PC/);
assert.match(proFeatureStatus(feature(), denied('versionUnsupported'), false).detail, /API 26/);
assert.equal(proFeatureStatus(feature(), denied('capabilityUnsupported'), false).tone, 'unsupported');
assert.equal(proFeatureStatus(feature(), { visible: true, executable: false, reason: 'permissionRequired' }, false).label, '需要授权');
assert.equal(proFeatureScope(feature()), '手机/平板/PC · SSH/RDP · API 26+');
assert.equal(proFeatureScope(feature({ devices: [], protocols: ['ai'], minApiVersion: 0 })), '远程 AI');
// Only HarmonyOS system capabilities go through canIUse; the app's own protocol capabilities count as present,
// so RDP/RustDesk 高级显示方案 no longer read as 系统能力不支持.
assert.equal(loaded.exports.proSystemCapability('SystemCapability.Collaboration.HarmonyShare'), true);
assert.equal(loaded.exports.proSystemCapability('rdp.displayControl'), false);
assert.equal(loaded.exports.proSystemCapability('rustdesk.displayControl'), false);
const reader = fs.readFileSync(path.resolve(__dirname, '../../entry/src/main/ets/services/pro/ProFeatureStatusReader.ets'), 'utf8');
assert.match(reader, /if \(!proSystemCapability\(capability\) \|\| canIUse\(capability\)\) \{ context\.capabilities\.push\(capability\); \}/);
console.log('PASS Pro feature status explains every decision reason and scope');
