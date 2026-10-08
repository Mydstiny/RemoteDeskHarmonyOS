import { DiagnosticCaptureEvent, DiagnosticCaptureRuntime, FrozenDiagnosticCapture } from '../DiagnosticCaptureRuntime';
import {
  DIAGNOSTIC_CAPTURE_SCHEMA_VERSION,
  DiagnosticModuleId,
  diagnosticAllModules
} from '../DiagnosticCapturePolicy';
import { diagnosticEventInFacets } from '../DiagnosticCaptureFacetPolicy';
import {
  DiagnosticEvidenceCoverage,
  DiagnosticMissingEvidence,
  DiagnosticModuleCoverage,
  diagnosticEvidenceCoverage,
  diagnosticMissingEvidenceDescription
} from '../DiagnosticEvidenceCoveragePolicy';
import { DiagnosticRdpGraphicsFacts } from '../RdpGraphicsEvidencePolicy';

export interface DiagnosticAiCapturePlan { modules: DiagnosticModuleId[]; durationMinutes: number; consentId: string; }
/** schemaVersion is the capture schema the bundle was cut from; the bundle text itself carries bundleVersion. */
export interface DiagnosticAiBundle {
  captureId: string; schemaVersion: number; modules: DiagnosticModuleId[]; eventCount: number; bytes: number; text: string;
  /** Evidence gaps of the whole capture, also present in the text; absent on bundles built elsewhere. */
  missingEvidence?: string[];
}
interface DiagnosticAiSafeEvent {
  ref: string;
  sequence: number; elapsedMs: number; moduleId: DiagnosticModuleId; eventCode: string; level: string; outcome: string;
  generation: number; code: number; durationMs: number; count: number; bytes: number; runtime: Object; network: Object; window: Object;
}
interface DiagnosticAiMissingEvidenceRow { code: string; meaning: string; }
interface DiagnosticAiQualityFact { ref: string; quality: number; resultCode: number; remoteBitrateKbps: number; }
interface DiagnosticAiDirectStageFact {
  ref: string; outcome: string; source: number; stage: number; addressClass: number;
}
interface DiagnosticAiFactSummary {
  rdpGraphicsRef: string;
  rdpGraphics: Object | null;
  rustDeskQuality: DiagnosticAiQualityFact[];
  rustDeskDirectStages: DiagnosticAiDirectStageFact[];
}
interface DiagnosticAiBundleCoverage {
  coverageComplete: boolean;
  moduleCoverage: Record<string, DiagnosticModuleCoverage>;
  missingEvidence: DiagnosticAiMissingEvidenceRow[];
}
/** JSON layout of DiagnosticAiBundle.text (bundleVersion 2). */
interface DiagnosticAiBundleDocument {
  bundleVersion: number;
  captureSchemaVersion: number;
  captureId: string;
  profile: string;
  modules: DiagnosticModuleId[];
  focus: string[];
  droppedEventCount: number;
  evidenceCoverage: DiagnosticAiBundleCoverage;
  factSummary: DiagnosticAiFactSummary;
  evidenceRules: string;
  events: Object[];
}

/** Version of the JSON layout inside DiagnosticAiBundle.text. */
export const DIAGNOSTIC_AI_BUNDLE_VERSION: number = 2;

/**
 * Rules sent with every bundle. Conclusions must cite event refs, and a gap
 * listed in missingEvidence is reported as unconfirmed, never guessed.
 */
export const DIAGNOSTIC_AI_EVIDENCE_RULES: string =
  '证据规则：evidenceRefs 只能填写诊断包 events 中的 ref（如 capture-2/session-1/g0/seq-18），每个确定结论至少引用一条；' +
  'evidenceCoverage.missingEvidence 列出的项目是缺失的证据，相关结论只能写成“未确认”并放进 unknowns，不能当作事实；' +
  'RDP 线上编码只看 runtime.rdpGraphics.wireCodec 与 h264Status，requestedMode 只是客户端请求；' +
  'RustDesk 画质是否生效只看 rustdesk_quality_result 的结论码，2/3 才算远端码率已调整。';

export function diagnosticAiModulesForQuestion(question: string): DiagnosticModuleId[] {
  const value = question.toLowerCase();
  if (value.includes('rdp') || value.includes('黑屏') || value.includes('画面')) { return ['core.app', 'connection.rdp', 'network.routing']; }
  if (value.includes('rust') || value.includes('rustdesk') || value.includes('中继')) { return ['core.app', 'connection.rustdesk', 'network.routing']; }
  if (value.includes('ssh') || value.includes('终端') || value.includes('sftp')) { return ['core.app', 'connection.ssh_sftp', 'network.routing']; }
  if (value.includes('vnc')) { return ['core.app', 'connection.vnc', 'network.routing']; }
  if (value.includes('moonlight') || value.includes('串流')) { return ['core.app', 'connection.moonlight', 'network.routing']; }
  return ['core.app'];
}

export function diagnosticAiPlanValid(plan: DiagnosticAiCapturePlan): boolean {
  return plan.consentId.length >= 8 && plan.modules.length > 0 && plan.modules.length <= diagnosticAllModules().length &&
    [1, 3, 5, 10, 15, 30].indexOf(plan.durationMinutes) >= 0;
}

/** Facts with their default values (0, false, '', 'unknown', []) left out: most of a snapshot is defaults. */
function compactFacts(facts: Object): Object {
  const text: string = JSON.stringify(facts, (_key: string, value: Object): Object | undefined => {
    if (value === 0 || value === false || value === '' || value === 'unknown' || value === 'not_sampled') { return undefined; }
    if (Array.isArray(value) && (value as Object[]).length === 0) { return undefined; }
    return value;
  });
  return JSON.parse(text === undefined || text === '' ? '{}' : text) as Object;
}

/** Stable, address-free reference of one event inside one capture. */
export function diagnosticAiEventRef(captureId: string, event: DiagnosticCaptureEvent): string {
  return captureId + '/' + (event.sessionRef === '' ? 'app' : event.sessionRef) + '/g' +
    event.generation.toString() + '/seq-' + event.sequence.toString();
}

function safeEvent(captureId: string, event: DiagnosticCaptureEvent): DiagnosticAiSafeEvent {
  return { ref: diagnosticAiEventRef(captureId, event),
    sequence: event.sequence, elapsedMs: event.elapsedMs, moduleId: event.moduleId,
    eventCode: event.eventCode, level: event.level, outcome: event.outcome,
    generation: event.generation, code: event.code, durationMs: event.durationMs,
    count: event.count, bytes: event.bytes, runtime: compactFacts(event.runtime), network: compactFacts(event.network),
    window: compactFacts(event.window) };
}

function factSummary(capture: FrozenDiagnosticCapture): DiagnosticAiFactSummary {
  const summary: DiagnosticAiFactSummary = {
    rdpGraphicsRef: '', rdpGraphics: null, rustDeskQuality: [], rustDeskDirectStages: []
  };
  let latestGraphics: DiagnosticRdpGraphicsFacts | undefined = undefined;
  for (let index: number = 0; index < capture.events.length; index++) {
    const event: DiagnosticCaptureEvent = capture.events[index];
    const graphics: DiagnosticRdpGraphicsFacts | undefined = event.runtime.rdpGraphics;
    if (graphics !== undefined && graphics.evidenceLevel !== 'missing') {
      latestGraphics = graphics;
      summary.rdpGraphicsRef = diagnosticAiEventRef(capture.captureId, event);
    }
    if (event.eventCode === 'rustdesk_quality_result') {
      summary.rustDeskQuality.push({ ref: diagnosticAiEventRef(capture.captureId, event),
        quality: event.generation, resultCode: event.code, remoteBitrateKbps: event.count });
    }
    if (event.eventCode === 'rustdesk_direct_stage') {
      summary.rustDeskDirectStages.push({ ref: diagnosticAiEventRef(capture.captureId, event),
        outcome: event.outcome, source: event.generation, stage: event.code, addressClass: event.count });
    }
  }
  // Keep the newest rows: the latest verdict/stage is what the question is
  // about; every row is still present in the events list.
  summary.rustDeskQuality = summary.rustDeskQuality.slice(-8);
  summary.rustDeskDirectStages = summary.rustDeskDirectStages.slice(-12);
  // Kept whole (not compacted): false/'none' values are evidence here.
  summary.rdpGraphics = latestGraphics === undefined ? null : latestGraphics as Object;
  return summary;
}

function missingEvidenceRows(coverage: DiagnosticEvidenceCoverage): DiagnosticAiMissingEvidenceRow[] {
  return coverage.missingEvidence.map((code: DiagnosticMissingEvidence): DiagnosticAiMissingEvidenceRow => {
    return { code: code, meaning: diagnosticMissingEvidenceDescription(code) };
  });
}

/**
 * The capture as the AI reads it. With 日志子模块 selected (`focus`), only their events are kept (plus the capture's
 * start/stop markers), so the model sees the part of the app the question is about.
 */
export function diagnosticAiBundleFromCapture(capture: FrozenDiagnosticCapture | null, focus: string[] = []): DiagnosticAiBundle | null {
  if (capture === null || capture.events.length === 0) { return null; }
  const focused: DiagnosticCaptureEvent[] = capture.events
    .filter((event: DiagnosticCaptureEvent): boolean => diagnosticEventInFacets(event.moduleId, event.eventCode, focus));
  // Nothing but the capture's own markers in the selection: give the model everything that was recorded instead.
  const informative: boolean = focused.some((event: DiagnosticCaptureEvent): boolean =>
    !(event.moduleId === 'core.app' && event.eventCode.indexOf('capture_') === 0));
  const rows: Object[] = (informative ? focused : capture.events)
    .map((event: DiagnosticCaptureEvent): Object => safeEvent(capture.captureId, event));
  // Coverage and the fact summary describe the whole capture, not only the
  // focused sub-modules, so a gap outside the focus is still visible.
  const coverage: DiagnosticEvidenceCoverage = diagnosticEvidenceCoverage(capture);
  const document: DiagnosticAiBundleDocument = {
    bundleVersion: DIAGNOSTIC_AI_BUNDLE_VERSION, captureSchemaVersion: DIAGNOSTIC_CAPTURE_SCHEMA_VERSION,
    captureId: capture.captureId, profile: capture.profile, modules: capture.selectedModules, focus: focus,
    droppedEventCount: capture.droppedEventCount,
    evidenceCoverage: {
      coverageComplete: coverage.coverageComplete, moduleCoverage: coverage.moduleCoverage,
      missingEvidence: missingEvidenceRows(coverage)
    },
    factSummary: factSummary(capture), evidenceRules: DIAGNOSTIC_AI_EVIDENCE_RULES, events: rows
  };
  const text: string = JSON.stringify(document);
  if (text.length > 1024 * 1024) { return null; }
  return { captureId: capture.captureId, schemaVersion: DIAGNOSTIC_CAPTURE_SCHEMA_VERSION,
    modules: capture.selectedModules.slice(), eventCount: rows.length, bytes: text.length, text,
    missingEvidence: coverage.missingEvidence.slice() };
}

export function diagnosticAiCaptureStatus(runtime: DiagnosticCaptureRuntime): string {
  const status = runtime.status();
  return status.phase + ' · ' + status.eventCount.toString() + ' 条事件 · ' + status.approximateBytes.toString() + ' bytes';
}
