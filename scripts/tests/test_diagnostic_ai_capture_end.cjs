'use strict';

/* Regression checks for the AI capture end state machine. This extracts the
 * production non-Builder methods; it does not emulate ArkUI or a device. */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.AI_TYPESCRIPT_PATH || 'typescript');

const root = process.env.AI_REPO_ROOT || path.resolve(__dirname, '../..');
const file = path.join(root, 'entry/src/main/ets/components/diagnosticAi/DiagnosticAiAssistantPanel.ets');
const original = fs.readFileSync(file, 'utf8');
const end = original.indexOf('  @Builder');
assert.ok(end > 0, 'assistant panel lifecycle boundary exists');
const source = (original.slice(0, end) + '\n}\n')
  .replace(/^import .*;\n/gm, '')
  .replace(/^@(Component|Entry)\s*$/gm, '')
  .replace(/@(?:StorageProp|StorageLink|Watch)\([^\n]*?\)\s*/g, '')
  .replace(/@(?:State|Prop|Link)\s+/g, '')
  .replace('export struct DiagnosticAiAssistantPanel', 'class DiagnosticAiAssistantPanel');
const context = vm.createContext({
  Date, JSON, Math, Number, Object, Array, Map, Set, Error,
  setTimeout, clearTimeout, setInterval, clearInterval,
  DiagnosticAiCaptureOrchestrator: { getInstance: () => ({}) },
  DiagnosticAiAgentService: class {}, DiagnosticAiProfileStore: class {},
  DiagnosticAiConversationStore: class {}, DiagnosticAiModelCatalog: class {},
  AccountSessionCoordinator: { getInstance: () => ({ currentScope: () => ({ ownerScopeId: '' }) }) },
  AppStorage: { setOrCreate: () => {} },
  ProEntries: { visible: () => true }, ProAppRuntime: { getInstance: () => ({ context: () => ({}) }) },
  diagnosticAiModulesForQuestion: () => ['core.app'], diagnosticAiCaptureStatus: () => '',
  diagnosticAiProviderIsHarmonyLocal: () => false,
  aiSuggestionsFor: () => [],
  DiagnosticCaptureActionCode: {},
  getContext: () => ({}), focusControl: { requestFocus: () => {} }
});
vm.runInContext(ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.None }
}).outputText + '\nglobalThis.Target = DiagnosticAiAssistantPanel;', context);

function fixture({ stop = 'ok', phaseAfterStop = 'readyToSave', bundle = null, selected = undefined } = {}) {
  const state = { phase: 'capturing', stop, phaseAfterStop, bundle, cancelled: 0, activity: [], captureState: [], response: null };
  const capture = {
    stop: () => { state.phase = state.phaseAfterStop; return state.stop; },
    status: () => ({ phase: state.phase, eventCount: 1, durationMinutes: 3, remainingSeconds: 1, approximateBytes: 20 }),
    bundle: () => state.bundle,
    currentGeneration: () => 1,
    cancel: () => { state.cancelled++; state.phase = 'idle'; return 'ok'; },
    discard: () => 'ok',
    start: () => 'ok'
  };
  const page = Object.create(context.Target.prototype);
  Object.assign(page, {
    capture, owner: 'fixture-owner', busy: false, question: '请诊断 RDP 黑屏',
    captureOwnedByPanel: true, lifecycleGeneration: 1, alive: true, pendingCaptureId: '', latestBundleText: '',
    lastCapturePhase: 'idle',
    status: '', modules: ['core.app'], conversation: '', agentMode: 'diagnose',
    assistantPreferences: { name: 'RD', personality: 'balanced', verbosity: 'standard', role: 'expert', language: 'zh-CN' },
    store: { list: () => selected === undefined ? [] : [selected], secret: () => 'secret' },
    agent: { respond: async () => { state.response = true; return { summary: 'ok', severity: 'info', confidence: 1, unknowns: [], recommendedReadOnlySteps: [], settingProposals: [], appActions: [], evidenceRefs: [], hypotheses: [] }; } },
    allowed: () => true,
    onActivityChanged: (value) => state.activity.push(value),
    onCaptureStateChanged: (value) => state.captureState.push(value),
    reportActivity: context.Target.prototype.reportActivity,
    syncCapture: context.Target.prototype.syncCapture,
    capturing: context.Target.prototype.capturing,
    finishCaptureFailure: context.Target.prototype.finishCaptureFailure,
    cancelCapture: context.Target.prototype.cancelCapture,
    selectedProfile: () => selected,
    assistantMemoryContext: () => ''
  });
  return { page, state };
}

async function run() {
  {
    const f = fixture({ bundle: null });
    await f.page.finishCapture();
    assert.deepEqual(f.state.activity, [true, false]);
    assert.equal(f.page.busy, false);
    assert.equal(f.state.cancelled, 1);
    console.log('PASS empty bundle end failure releases busy activity and runtime');
  }
  {
    const f = fixture({ bundle: { captureId: 'capture-1', text: '{}', modules: ['core.app'] } });
    await f.page.finishCapture();
    assert.deepEqual(f.state.activity, [true, false]);
    assert.equal(f.page.busy, false);
    assert.equal(f.page.pendingCaptureId, 'capture-1');
    assert.equal(f.page.captureOwnedByPanel, false);
    console.log('PASS missing provider profile keeps retryable bundle and releases animation');
  }
  {
    const f = fixture({ stop: 'busy', phaseAfterStop: 'capturing' });
    await f.page.finishCapture();
    assert.deepEqual(f.state.activity, [true]);
    assert.equal(f.page.busy, false);
    assert.equal(f.page.captureOwnedByPanel, true);
    assert.equal(f.state.captureState.length, 0);
    console.log('PASS failed stop retains active capture ownership for retry/cancel');
  }
  {
    const f = fixture({ bundle: { captureId: 'capture-deadline', text: '{}', modules: ['core.app'] } });
    f.page.syncCapture();
    f.state.phase = 'readyToSave';
    f.page.syncCapture();
    assert.deepEqual(f.state.activity, [true, false]);
    assert.deepEqual(f.state.captureState, [false]);
    assert.equal(f.page.pendingCaptureId, 'capture-deadline');
    assert.equal(f.page.captureOwnedByPanel, false);
    console.log('PASS deadline transition releases island and preserves retryable bundle');
  }
  {
    const f = fixture();
    f.page.syncCapture();
    f.state.phase = 'idle';
    f.page.syncCapture();
    assert.deepEqual(f.state.activity, [true, false]);
    assert.deepEqual(f.state.captureState, [false]);
    assert.equal(f.page.captureOwnedByPanel, false);
    console.log('PASS external invalidation releases stale capture ownership and animation');
  }
}

run().catch((error) => { console.error(error.stack); process.exitCode = 1; });
