import { DiagnosticCaptureEvent, DiagnosticCaptureRuntime, FrozenDiagnosticCapture } from '../DiagnosticCaptureRuntime';
import { DiagnosticModuleId, diagnosticAllModules } from '../DiagnosticCapturePolicy';
import { diagnosticEventInFacets } from '../DiagnosticCaptureFacetPolicy';

export interface DiagnosticAiCapturePlan { modules: DiagnosticModuleId[]; durationMinutes: number; consentId: string; }
export interface DiagnosticAiBundle { captureId: string; schemaVersion: number; modules: DiagnosticModuleId[]; eventCount: number; bytes: number; text: string; }
interface DiagnosticAiSafeEvent {
  sequence: number; elapsedMs: number; moduleId: DiagnosticModuleId; eventCode: string; level: string; outcome: string;
  generation: number; code: number; durationMs: number; count: number; bytes: number; runtime: Object; network: Object; window: Object;
}

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

function safeEvent(event: DiagnosticCaptureEvent): DiagnosticAiSafeEvent {
  return { sequence: event.sequence, elapsedMs: event.elapsedMs, moduleId: event.moduleId,
    eventCode: event.eventCode, level: event.level, outcome: event.outcome,
    generation: event.generation, code: event.code, durationMs: event.durationMs,
    count: event.count, bytes: event.bytes, runtime: compactFacts(event.runtime), network: compactFacts(event.network),
    window: compactFacts(event.window) };
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
    .map((event: DiagnosticCaptureEvent): Object => safeEvent(event));
  const text = JSON.stringify({ captureId: capture.captureId, profile: capture.profile, modules: capture.selectedModules,
    focus: focus, droppedEventCount: capture.droppedEventCount, events: rows });
  if (text.length > 1024 * 1024) { return null; }
  return { captureId: capture.captureId, schemaVersion: 8, modules: capture.selectedModules.slice(),
    eventCount: rows.length, bytes: text.length, text };
}

export function diagnosticAiCaptureStatus(runtime: DiagnosticCaptureRuntime): string {
  const status = runtime.status();
  return status.phase + ' · ' + status.eventCount.toString() + ' 条事件 · ' + status.approximateBytes.toString() + ' bytes';
}
