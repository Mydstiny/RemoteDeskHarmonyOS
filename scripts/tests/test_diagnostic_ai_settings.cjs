'use strict';

/* Local behavior checks for the Pro diagnostic-AI settings surfaces. */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.AI_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const modules = new Map();
const preferenceStores = new Map();

class PreferenceStore {
  constructor(name) { this.name = name; this.values = preferenceStores.get(name) || new Map(); preferenceStores.set(name, this.values); }
  getSync(key, fallback) { return this.values.has(key) ? this.values.get(key) : fallback; }
  putSync(key, value) { this.values.set(key, value); }
  flushSync() {}
}

function load(file, mocks = {}) {
  if (modules.has(file)) return modules.get(file).exports;
  const module = { exports: {} }; modules.set(file, module);
  const source = fs.readFileSync(path.join(root, file + '.ets'), 'utf8');
  const context = vm.createContext({ module, exports: module.exports, Date, JSON, Math, Number, String, Object, Array, Map, Set, Error, isFinite });
  const output = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  // Execute with a relative resolver when the transpiled module requests one.
  const requireRelative = name => {
    if (mocks[name]) return mocks[name];
    if (name === '@kit.ArkData') return { preferences: { getPreferencesSync: (_context, options) => new PreferenceStore(options.name) } };
    if (name === '@kit.AbilityKit') return { common: {} };
    const child = path.posix.normalize(path.posix.join(path.posix.dirname(file), name));
    return load(child.endsWith('.ets') ? child.slice(0, -4) : child, mocks);
  };
  const wrapped = vm.runInContext('(function(require,module,exports){' + output + '\n})', context);
  const fresh = { exports: {} };
  wrapped(requireRelative, fresh, fresh.exports);
  modules.set(file, fresh);
  return fresh.exports;
}

const models = load('entry/src/main/ets/services/diagnosticAi/DiagnosticAiModels');
const storeModule = load('entry/src/main/ets/services/diagnosticAi/DiagnosticAiConversationStore');
const store = new storeModule.DiagnosticAiConversationStore();
store.init({}, 'fixture-owner');
assert.equal(storeModule.defaultDiagnosticAiAssistantPreferences().name, 'RD Assistant');
store.saveSession({ id: 'session-1', title: 'RDP 连接', createdAt: 1, updatedAt: 2, providerId: 'deepseek', modelId: 'deepseek-chat', turns: [
  { question: 'RDP 断开怎么办？', answer: '先检查网络代际。', mode: 'diagnose', createdAt: 2 }
] });
assert.match(store.summarizedSessionMemory(), /RDP 连接/);
assert.match(store.memoryContext(), /RDP 断开怎么办/);
const prefs = storeModule.defaultDiagnosticAiAssistantPreferences();
prefs.manualMemorySummary = '我优先使用中文。'; prefs.memorySummary = store.summarizedSessionMemory();
assert.equal(store.saveAssistantPreferences(prefs), true);
assert.equal(store.assistantPreferences().manualMemorySummary, '我优先使用中文。');
assert.match(store.memoryContext(), /我优先使用中文/);
console.log('PASS session memory is locally summarized and manual preference remains separate');

const catalogModule = load('entry/src/main/ets/services/diagnosticAi/DiagnosticAiModelCatalog', {
  '@kit.ArkData': { preferences: { getPreferencesSync: (_context, options) => new PreferenceStore(options.name) } },
  '@kit.AbilityKit': { common: {} }
});
const catalog = new catalogModule.DiagnosticAiModelCatalog(); catalog.init({}, 'fixture-owner');
assert.ok(catalog.list().length >= 14);
assert.ok(catalog.priceFor('deepseek', 'deepseek-chat'));
assert.ok(catalog.estimateCost('deepseek', 'deepseek-chat', 1000000, 1000000, 0) > 0);
catalog.updateFromProvider([{ providerId: 'deepseek', modelId: 'deepseek-chat', displayName: 'DeepSeek Chat', inputCnyPerMillion: -1, outputCnyPerMillion: -1, cachedInputCnyPerMillion: -1, source: 'DeepSeek /models', sourceKind: 'provider', updatedAt: 3 }]);
assert.equal(catalog.priceFor('deepseek', 'deepseek-chat').inputCnyPerMillion, 1);
console.log('PASS maintained model table survives a model-only online refresh and estimates cost');

const route = load('entry/src/main/ets/services/SettingsSheetRoutePolicy');
assert.equal(route.diagnosticAiSettingsLeafSheetHeight(route.SETTINGS_SHEET_DIAGNOSTIC_AI, 1, 700), 652);
assert.equal(route.diagnosticAiSettingsLeafSheetHeight(route.SETTINGS_SHEET_DIAGNOSTIC_AI, 3, 1000), 620);
assert.equal(route.diagnosticAiSettingsLeafSheetHeight(route.SETTINGS_SHEET_DIAGNOSTIC_AI, 4, 600), 552);
assert.equal(route.diagnosticAiSettingsLeafSheetHeight(route.SETTINGS_SHEET_DIAGNOSTIC_AI, 5, 900), 620);
console.log('PASS AI assistant, usage, personalization and session sheets use adaptive route heights');

const providerCatalog = load('entry/src/main/ets/services/diagnosticAi/DiagnosticAiProviderCatalog');
const qwenManifest = providerCatalog.diagnosticAiProviderManifest('qwen');
assert.equal(providerCatalog.diagnosticAiProviderNormalApiAvailable(qwenManifest), true);
assert.equal(providerCatalog.diagnosticAiProviderCodingPlanAvailable(qwenManifest), false);
const unverifiedCodingManifest = { ...qwenManifest, billingMode: 'coding_plan', authModes: ['coding_plan_key'],
  codingPlanModelIds: ['coding-model'] };
assert.equal(providerCatalog.diagnosticAiProviderCodingPlanAvailable(unverifiedCodingManifest), false);
console.log('PASS ordinary API availability is independent from the unverified Coding Plan route');
const authPolicy = load('entry/src/main/ets/services/diagnosticAi/DiagnosticAiAuthPolicy');
const useCasePolicy = load('entry/src/main/ets/services/diagnosticAi/DiagnosticAiUseCasePolicy');
const billingPolicy = load('entry/src/main/ets/services/diagnosticAi/DiagnosticAiBillingPolicy');
const manifest = providerCatalog.diagnosticAiProviderManifest('deepseek');
const profile = {
  id: 'deepseek-fixture', owner: 'fixture-owner', providerId: 'deepseek', displayName: 'DeepSeek', endpoint: 'https://api.deepseek.com', modelId: 'deepseek-chat',
  authKind: 'bearer', authHeader: 'Authorization', authMode: 'api_key', billingMode: 'payg_api', allowedUseCases: ['diagnostic_assistant'],
  requiresInteractive: false, requiresOfficialTool: false, entitlementEndpoint: '', termsVersion: '2026-10-02', dataRegion: 'mainland_cn',
  authorizationStatus: 'connected', consentId: 'fixture-consent', consentAt: 1, secretRef: 'fixture', secretFingerprint: 'fixture', manifestVersion: 1,
  privacy: manifest.privacy, showOrbOnHostPage: true, revision: 1, updatedAt: 1
};
assert.equal(authPolicy.diagnosticAiAuthDecision(manifest, profile).ok, true);
assert.equal(billingPolicy.diagnosticAiBillingDecision(manifest, profile, 'diagnostic_assistant').ok, true);
assert.equal(useCasePolicy.diagnosticAiUseCaseDecision(manifest, profile, 'diagnostic_assistant').ok, true);
const denied = { ...profile, allowedUseCases: ['coding_agent'] };
assert.equal(useCasePolicy.diagnosticAiUseCaseDecision(manifest, denied, 'diagnostic_assistant').code, 'USE_CASE_NOT_ALLOWED');
const officialOnly = { ...profile, billingMode: 'coding_plan', authMode: 'coding_plan_key', allowedUseCases: ['coding_agent'], requiresOfficialTool: true };
assert.equal(billingPolicy.diagnosticAiBillingDecision({ ...manifest, billingMode: 'coding_plan', authModes: ['coding_plan_key'], allowedUseCases: ['coding_agent'], requiresOfficialTool: true }, officialOnly, 'diagnostic_assistant').ok, false);
assert.equal(authPolicy.diagnosticAiAuthDecision({ ...manifest, authModes: ['oauth_pkce'] }, profile).code, 'AUTH_MODE_UNSUPPORTED');
const codingManifest = { ...manifest, billingMode: 'coding_plan', authModes: ['coding_plan_key'],
  allowedUseCases: ['diagnostic_assistant'], codingPlanModelIds: ['coding-model'], requiresOfficialTool: false };
const codingProfile = { ...profile, authMode: 'coding_plan_key', billingMode: 'coding_plan', modelId: 'other-model' };
const unverifiedCodingProfile = { ...codingProfile, modelId: 'coding-model' };
assert.equal(authPolicy.diagnosticAiAuthDecision(unverifiedCodingManifest, unverifiedCodingProfile).code, 'CODING_PLAN_MANIFEST_UNVERIFIED');
assert.equal(billingPolicy.diagnosticAiBillingDecision(unverifiedCodingManifest, unverifiedCodingProfile, 'diagnostic_assistant').code, 'CODING_PLAN_MANIFEST_UNVERIFIED');
assert.equal(authPolicy.diagnosticAiAuthDecision(codingManifest, codingProfile).code, 'CODING_PLAN_MODEL_NOT_ALLOWED');
assert.equal(billingPolicy.diagnosticAiBillingDecision(codingManifest, codingProfile, 'diagnostic_assistant').code, 'CODING_PLAN_MODEL_NOT_ALLOWED');
assert.equal(authPolicy.diagnosticAiAuthDecision(codingManifest, { ...codingProfile, modelId: 'coding-model' }).ok, true);
assert.equal(authPolicy.diagnosticAiAuthDecision({ ...manifest, schemaVersion: 2 }, profile).code, 'MANIFEST_VERSION_STALE');
console.log('PASS P0 authentication, billing and diagnostic-use-case policies fail closed for unknown or coding-only plans');

const sheetSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/components/diagnosticAi/DiagnosticAiSettingsSheet.ets'), 'utf8');
const hostSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/HostListPage.ets'), 'utf8');
const providerSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/services/diagnosticAi/DiagnosticAiProviderService.ets'), 'utf8');
assert.equal(sheetSource.includes('sessionDialogVisible'), false);
assert.ok(sheetSource.includes('onOpenSession(session.id)'));
assert.ok(hostSource.includes('private openDiagnosticAiSession(sessionId: string)'));
assert.ok(hostSource.includes('initialResumeSessionId: this.diagnosticAiResumeSessionId'));
console.log('PASS history replaces the native sheet instead of mounting a floating overlay');
assert.ok(sheetSource.includes('selectedAuthMode'));
assert.ok(sheetSource.includes('termsAcceptedDraft'));
assert.ok(sheetSource.includes('Coding Plan 必须使用 Manifest 声明的专用 Base URL'));
assert.ok(sheetSource.includes('Coding Plan 专用连接待官方核验'));
assert.ok(sheetSource.includes('普通 API 与 Coding Plan 分开保存'));
assert.ok(sheetSource.includes('diagnosticAiProviderNormalApiAvailable'));
assert.ok(sheetSource.includes('diagnosticAiProviderCodingPlanAvailable'));
assert.ok(sheetSource.includes('删除/撤销 Provider 配置失败'));
assert.ok(providerSource.includes('diagnosticAiUseCaseDecision(manifest, profile, \'diagnostic_assistant\')'));
console.log('PASS P1 auth-mode selection, explicit terms consent, dedicated endpoint and revoke UI are fail-closed');

void models;
