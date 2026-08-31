import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import rdpnapi from 'librdpnapi.so';
import { BoundedDocumentIo } from './BoundedDocumentIo';
import {
  CURRENT_RELEASE_VERSION,
  CURRENT_RELEASE_VERSION_CODE
} from './ReleaseNotesRegistry';
import {
  DIAGNOSTIC_CAPTURE_SCHEMA_VERSION,
  DIAGNOSTIC_MAX_CAPTURE_BYTES,
  DIAGNOSTIC_MAX_EVENTS,
  DIAGNOSTIC_MAX_EXPORT_BYTES,
  DIAGNOSTIC_MAX_SESSION_REFS,
  DIAGNOSTIC_REDACTION_POLICY_VERSION,
  DiagnosticAddressFamily,
  DiagnosticModuleId,
  DiagnosticNetworkFacts,
  DiagnosticOutcome,
  DiagnosticRuntimeBackend,
  DiagnosticRuntimeCodec,
  DiagnosticRuntimeFacts,
  DiagnosticRuntimePath,
  DiagnosticRuntimeState,
  DiagnosticPeerPlatform,
  DiagnosticPresentation,
  DiagnosticProducerTransform,
  diagnosticDurationIsAllowed,
  diagnosticEventIsAllowed,
  diagnosticLevelForOutcome,
  diagnosticModuleIsKnown,
  diagnosticNetworkFactsAreValid,
  diagnosticOutcomeIsAllowed,
  diagnosticRuntimeFactsAreValid,
  diagnosticSafeInteger,
  normalizeDiagnosticModules
} from './DiagnosticCapturePolicy';
import {
  DiagnosticCaptureActionCode,
  DiagnosticCaptureEvent,
  DiagnosticCaptureRuntime,
  FrozenDiagnosticCapture
} from './DiagnosticCaptureRuntime';

export type DiagnosticSerializationCode =
  'ok' | 'not_ready' | 'invalid_capture' | 'too_large' | 'invalid_jsonl';

export type DiagnosticSaveCode =
  'ok' | 'not_ready' | 'busy' | 'cancelled' | 'too_large' |
  'invalid_jsonl' | 'short_write' | 'verify_failed' | 'io_error';

export interface DiagnosticSerializationResult {
  ok: boolean;
  code: DiagnosticSerializationCode;
  fileName: string;
  text: string;
  bytes: Uint8Array;
}

export interface DiagnosticSaveResult {
  ok: boolean;
  code: DiagnosticSaveCode;
  fileName: string;
  bytesWritten: number;
}

export interface DiagnosticDocumentPort {
  save(fileName: string, bytes: Uint8Array): Promise<DiagnosticSaveResult>;
}

interface DiagnosticManifestLine {
  kind: string;
  schemaVersion: number;
  app: string;
  appVersion: string;
  appVersionCode: number;
  buildId: string;
  captureId: string;
  durationMinutes: number;
  selectedModules: DiagnosticModuleId[];
  startedWallTimeMs: number;
  endedWallTimeMs: number;
  stopReason: string;
  redactionPolicyVersion: number;
}

interface DiagnosticEventLine {
  kind: string;
  schemaVersion: number;
  sequence: number;
  elapsedMs: number;
  wallTimeMs: number;
  moduleId: DiagnosticModuleId;
  eventCode: string;
  level: string;
  outcome: string;
  sessionRef: string;
  generation: number;
  code: number;
  durationMs: number;
  count: number;
  bytes: number;
  runtime: DiagnosticRuntimeFacts;
  network: DiagnosticNetworkFacts;
}

interface DiagnosticSummaryLine {
  kind: string;
  schemaVersion: number;
  eventCount: number;
  droppedEventCount: number;
  approximateCaptureBytes: number;
  serializedBytes: number;
  moduleEventCounts: Record<string, number>;
}

function emptySerialization(code: DiagnosticSerializationCode): DiagnosticSerializationResult {
  return {
    ok: false,
    code: code,
    fileName: '',
    text: '',
    bytes: new Uint8Array(0)
  };
}

function twoDigits(value: number): string {
  return value < 10 ? '0' + value.toString() : value.toString();
}

export function diagnosticLogFileName(startedWallTimeMs: number): string {
  const date: Date = new Date(startedWallTimeMs);
  return 'RemoteDesktop-log-' + date.getFullYear().toString() +
    twoDigits(date.getMonth() + 1) + twoDigits(date.getDate()) + '-' +
    twoDigits(date.getHours()) + twoDigits(date.getMinutes()) +
    twoDigits(date.getSeconds()) + '.jsonl';
}

function eventLine(event: DiagnosticCaptureEvent): DiagnosticEventLine {
  return {
    kind: 'event',
    schemaVersion: DIAGNOSTIC_CAPTURE_SCHEMA_VERSION,
    sequence: event.sequence,
    elapsedMs: event.elapsedMs,
    wallTimeMs: event.wallTimeMs,
    moduleId: event.moduleId,
    eventCode: event.eventCode,
    level: event.level,
    outcome: event.outcome,
    sessionRef: event.sessionRef,
    generation: event.generation,
    code: event.code,
    durationMs: event.durationMs,
    count: event.count,
    bytes: event.bytes,
    runtime: event.runtime,
    network: event.network
  };
}

function moduleCounts(capture: FrozenDiagnosticCapture): Record<string, number> {
  const counts: Record<string, number> = {};
  for (let i: number = 0; i < capture.selectedModules.length; i++) {
    counts[capture.selectedModules[i]] = 0;
  }
  for (let i: number = 0; i < capture.events.length; i++) {
    const id: string = capture.events[i].moduleId;
    counts[id] = (counts[id] || 0) + 1;
  }
  return counts;
}

function objectHasExactKeys(source: Record<string, Object>, expected: string[]): boolean {
  const actual: string[] = Object.keys(source).sort();
  const sortedExpected: string[] = expected.slice().sort();
  if (actual.length !== sortedExpected.length) { return false; }
  for (let i: number = 0; i < actual.length; i++) {
    if (actual[i] !== sortedExpected[i]) { return false; }
  }
  return true;
}

function safeMetadataToken(value: string, maxLength: number): boolean {
  if (value.length === 0 || value.length > maxLength) { return false; }
  for (let i: number = 0; i < value.length; i++) {
    const code: number = value.charCodeAt(i);
    const letter: boolean = (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
    const digit: boolean = code >= 48 && code <= 57;
    if (!letter && !digit && value[i] !== '.' && value[i] !== '_' &&
      value[i] !== '-' && value[i] !== '+') { return false; }
  }
  return true;
}

function captureIdIsValid(value: string): boolean {
  if (!value.startsWith('capture-') || value.length > 32) { return false; }
  const ordinal: number = Number(value.substring('capture-'.length));
  return Number.isSafeInteger(ordinal) && ordinal > 0;
}

function sessionRefIsValid(value: string): boolean {
  if (value === '') { return true; }
  if (!value.startsWith('session-') || value.length > 24) { return false; }
  const ordinal: number = Number(value.substring('session-'.length));
  return Number.isSafeInteger(ordinal) && ordinal > 0 && ordinal <= DIAGNOSTIC_MAX_SESSION_REFS;
}

function selectedModulesAreValid(moduleIds: DiagnosticModuleId[]): boolean {
  const raw: string[] = moduleIds as string[];
  const normalized: DiagnosticModuleId[] = normalizeDiagnosticModules(raw);
  if (normalized.length !== moduleIds.length) { return false; }
  for (let i: number = 0; i < moduleIds.length; i++) {
    if (!diagnosticModuleIsKnown(moduleIds[i]) || normalized[i] !== moduleIds[i]) { return false; }
  }
  return moduleIds.length > 0 && moduleIds[0] === 'core.app';
}

function eventIsValid(event: DiagnosticCaptureEvent, capture: FrozenDiagnosticCapture,
  expectedSequence: number): boolean {
  const elapsedLimit: number = capture.endedWallTimeMs - capture.startedWallTimeMs;
  const numbers: number[] = [
    event.sequence, event.elapsedMs, event.wallTimeMs, event.generation,
    event.code, event.durationMs, event.count, event.bytes
  ];
  for (let i: number = 0; i < numbers.length; i++) {
    if (diagnosticSafeInteger(numbers[i]) === null) { return false; }
  }
  if (event.sequence !== expectedSequence || event.elapsedMs < 0 ||
    event.elapsedMs > elapsedLimit || event.wallTimeMs !== capture.startedWallTimeMs + event.elapsedMs ||
    event.generation < 0 || event.durationMs < 0 || event.count < 0 || event.bytes < 0) {
    return false;
  }
  if (!diagnosticModuleIsKnown(event.moduleId) ||
    capture.selectedModules.indexOf(event.moduleId) < 0 ||
    !diagnosticEventIsAllowed(event.moduleId, event.eventCode) ||
    !diagnosticOutcomeIsAllowed(event.outcome) ||
    event.level !== diagnosticLevelForOutcome(event.outcome) ||
    !sessionRefIsValid(event.sessionRef) ||
    !diagnosticRuntimeFactsAreValid(event.runtime) ||
    !diagnosticNetworkFactsAreValid(event.network)) {
    return false;
  }
  return true;
}

export function validateFrozenDiagnosticCapture(capture: FrozenDiagnosticCapture | null): boolean {
  if (capture === null || !captureIdIsValid(capture.captureId) ||
    !diagnosticDurationIsAllowed(capture.durationMinutes) ||
    !selectedModulesAreValid(capture.selectedModules) ||
    diagnosticSafeInteger(capture.startedWallTimeMs) === null ||
    diagnosticSafeInteger(capture.endedWallTimeMs) === null ||
    capture.startedWallTimeMs <= 0 || capture.endedWallTimeMs < capture.startedWallTimeMs ||
    capture.endedWallTimeMs - capture.startedWallTimeMs > capture.durationMinutes * 60 * 1000 ||
    (capture.stopReason !== 'manual' && capture.stopReason !== 'deadline') ||
    capture.events.length === 0 || capture.events.length > DIAGNOSTIC_MAX_EVENTS ||
    diagnosticSafeInteger(capture.droppedEventCount) === null || capture.droppedEventCount < 0 ||
    diagnosticSafeInteger(capture.approximateBytes) === null || capture.approximateBytes <= 0 ||
    capture.approximateBytes > DIAGNOSTIC_MAX_CAPTURE_BYTES) {
    return false;
  }
  let computedBytes: number = 0;
  const encoder: util.TextEncoder = new util.TextEncoder();
  for (let i: number = 0; i < capture.events.length; i++) {
    if (!eventIsValid(capture.events[i], capture, i + 1)) { return false; }
    computedBytes += encoder.encode(JSON.stringify(capture.events[i])).length + 1;
  }
  if (computedBytes !== capture.approximateBytes ||
    capture.events[0].eventCode !== 'capture_started') { return false; }
  const last: DiagnosticCaptureEvent = capture.events[capture.events.length - 1];
  if (capture.stopReason === 'manual' && last.eventCode !== 'capture_stopped') { return false; }
  if (capture.stopReason === 'deadline' && last.eventCode !== 'capture_expired') { return false; }
  return true;
}

function jsonNumber(source: Record<string, Object>, key: string): number | null {
  const value: Object = source[key];
  if (typeof value !== 'number') { return null; }
  return diagnosticSafeInteger(value as number);
}

function jsonString(source: Record<string, Object>, key: string): string | null {
  const value: Object = source[key];
  return typeof value === 'string' ? value as string : null;
}

function jsonBoolean(source: Record<string, Object>, key: string): boolean | null {
  const value: Object = source[key];
  return typeof value === 'boolean' ? value as boolean : null;
}

function jsonNetworkFacts(value: Object): DiagnosticNetworkFacts | null {
  if (typeof value !== 'object' || value === null) { return null; }
  const source: Record<string, Object> = value as Record<string, Object>;
  if (!objectHasExactKeys(source, [
    'configuredEndpointFamily', 'configuredRouteFamily', 'hostnameCandidate',
    'ipv4Candidate', 'ipv6Candidate', 'scopedIpv6'
  ])) { return null; }
  const endpointFamily: string | null = jsonString(source, 'configuredEndpointFamily');
  const routeFamily: string | null = jsonString(source, 'configuredRouteFamily');
  const hostnameCandidate: boolean | null = jsonBoolean(source, 'hostnameCandidate');
  const ipv4Candidate: boolean | null = jsonBoolean(source, 'ipv4Candidate');
  const ipv6Candidate: boolean | null = jsonBoolean(source, 'ipv6Candidate');
  const scopedIpv6: boolean | null = jsonBoolean(source, 'scopedIpv6');
  if (endpointFamily === null || routeFamily === null || hostnameCandidate === null ||
    ipv4Candidate === null || ipv6Candidate === null || scopedIpv6 === null) {
    return null;
  }
  const facts: DiagnosticNetworkFacts = {
    configuredEndpointFamily: endpointFamily as DiagnosticAddressFamily,
    configuredRouteFamily: routeFamily as DiagnosticAddressFamily,
    hostnameCandidate: hostnameCandidate,
    ipv4Candidate: ipv4Candidate,
    ipv6Candidate: ipv6Candidate,
    scopedIpv6: scopedIpv6
  };
  return diagnosticNetworkFactsAreValid(facts) ? facts : null;
}

function jsonRuntimeFacts(value: Object): DiagnosticRuntimeFacts | null {
  if (typeof value !== 'object' || value === null) { return null; }
  const source: Record<string, Object> = value as Record<string, Object>;
  if (!objectHasExactKeys(source, [
    'state', 'backend', 'codec', 'path', 'peerPlatform', 'presentation',
    'producerTransform', 'width', 'height', 'frames', 'dropped', 'errors',
    'queueDepth', 'latencyMs'
  ])) { return null; }
  const state: string | null = jsonString(source, 'state');
  const backend: string | null = jsonString(source, 'backend');
  const codec: string | null = jsonString(source, 'codec');
  const path: string | null = jsonString(source, 'path');
  const peerPlatform: string | null = jsonString(source, 'peerPlatform');
  const presentation: string | null = jsonString(source, 'presentation');
  const producerTransform: string | null = jsonString(source, 'producerTransform');
  const width: number | null = jsonNumber(source, 'width');
  const height: number | null = jsonNumber(source, 'height');
  const frames: number | null = jsonNumber(source, 'frames');
  const dropped: number | null = jsonNumber(source, 'dropped');
  const errors: number | null = jsonNumber(source, 'errors');
  const queueDepth: number | null = jsonNumber(source, 'queueDepth');
  const latencyMs: number | null = jsonNumber(source, 'latencyMs');
  if (state === null || backend === null || codec === null || path === null ||
    peerPlatform === null || presentation === null || producerTransform === null ||
    width === null || height === null || frames === null || dropped === null ||
    errors === null || queueDepth === null || latencyMs === null) { return null; }
  const facts: DiagnosticRuntimeFacts = {
    state: state as DiagnosticRuntimeState,
    backend: backend as DiagnosticRuntimeBackend,
    codec: codec as DiagnosticRuntimeCodec,
    path: path as DiagnosticRuntimePath,
    peerPlatform: peerPlatform as DiagnosticPeerPlatform,
    presentation: presentation as DiagnosticPresentation,
    producerTransform: producerTransform as DiagnosticProducerTransform,
    width: width, height: height, frames: frames, dropped: dropped,
    errors: errors, queueDepth: queueDepth, latencyMs: latencyMs
  };
  return diagnosticRuntimeFactsAreValid(facts) ? facts : null;
}

function currentDiagnosticBuildId(): string {
  try {
    const nativeRevision: string = rdpnapi.VERSION.gitShortSha;
    if (safeMetadataToken(nativeRevision, 32)) {
      return CURRENT_RELEASE_VERSION + '+' + nativeRevision;
    }
  } catch (_err) {}
  return CURRENT_RELEASE_VERSION + '+unknown';
}

export function validateDiagnosticJsonl(text: string): boolean {
  try {
    if (text.length === 0 || !text.endsWith('\n')) { return false; }
    const lines: string[] = text.substring(0, text.length - 1).split('\n');
    if (lines.length < 2) { return false; }
    const first: Record<string, Object> = JSON.parse(lines[0]) as Record<string, Object>;
    const last: Record<string, Object> =
      JSON.parse(lines[lines.length - 1]) as Record<string, Object>;
    if (!objectHasExactKeys(first, [
      'kind', 'schemaVersion', 'app', 'appVersion', 'captureId', 'durationMinutes',
      'appVersionCode', 'buildId',
      'selectedModules', 'startedWallTimeMs', 'endedWallTimeMs', 'stopReason',
      'redactionPolicyVersion'
    ]) || !objectHasExactKeys(last, [
      'kind', 'schemaVersion', 'eventCount', 'droppedEventCount',
      'approximateCaptureBytes', 'serializedBytes', 'moduleEventCounts'
    ])) { return false; }
    if (jsonString(first, 'kind') !== 'manifest' || jsonString(last, 'kind') !== 'summary' ||
      jsonNumber(first, 'schemaVersion') !== DIAGNOSTIC_CAPTURE_SCHEMA_VERSION ||
      jsonNumber(last, 'schemaVersion') !== DIAGNOSTIC_CAPTURE_SCHEMA_VERSION ||
      jsonString(first, 'app') !== 'RemoteDesktop') { return false; }
    const appVersion: string | null = jsonString(first, 'appVersion');
    const appVersionCode: number | null = jsonNumber(first, 'appVersionCode');
    const buildId: string | null = jsonString(first, 'buildId');
    const captureId: string | null = jsonString(first, 'captureId');
    const stopReason: string | null = jsonString(first, 'stopReason');
    const selectedValue: Object = first['selectedModules'];
    if (appVersion === null || !safeMetadataToken(appVersion, 64) ||
      appVersionCode === null || appVersionCode <= 0 || buildId === null ||
      !safeMetadataToken(buildId, 96) || captureId === null ||
      !captureIdIsValid(captureId) || (stopReason !== 'manual' && stopReason !== 'deadline') ||
      !Array.isArray(selectedValue)) { return false; }
    const selectedModules: DiagnosticModuleId[] = selectedValue as DiagnosticModuleId[];
    if (!selectedModulesAreValid(selectedModules)) { return false; }
    const started: number | null = jsonNumber(first, 'startedWallTimeMs');
    const ended: number | null = jsonNumber(first, 'endedWallTimeMs');
    const duration: number | null = jsonNumber(first, 'durationMinutes');
    if (started === null || ended === null || duration === null ||
      jsonNumber(first, 'redactionPolicyVersion') !== DIAGNOSTIC_REDACTION_POLICY_VERSION) {
      return false;
    }
    const events: DiagnosticCaptureEvent[] = [];
    for (let i: number = 1; i < lines.length - 1; i++) {
      const parsed: Record<string, Object> = JSON.parse(lines[i]) as Record<string, Object>;
      if (!objectHasExactKeys(parsed, [
        'kind', 'schemaVersion', 'sequence', 'elapsedMs', 'wallTimeMs', 'moduleId',
        'eventCode', 'level', 'outcome', 'sessionRef', 'generation', 'code',
        'durationMs', 'count', 'bytes', 'runtime', 'network'
      ]) || jsonString(parsed, 'kind') !== 'event' ||
        jsonNumber(parsed, 'schemaVersion') !== DIAGNOSTIC_CAPTURE_SCHEMA_VERSION) { return false; }
      const moduleId: string | null = jsonString(parsed, 'moduleId');
      const eventCode: string | null = jsonString(parsed, 'eventCode');
      const level: string | null = jsonString(parsed, 'level');
      const outcome: string | null = jsonString(parsed, 'outcome');
      const sessionRef: string | null = jsonString(parsed, 'sessionRef');
      const sequence: number | null = jsonNumber(parsed, 'sequence');
      const elapsedMs: number | null = jsonNumber(parsed, 'elapsedMs');
      const wallTimeMs: number | null = jsonNumber(parsed, 'wallTimeMs');
      const generation: number | null = jsonNumber(parsed, 'generation');
      const code: number | null = jsonNumber(parsed, 'code');
      const durationMs: number | null = jsonNumber(parsed, 'durationMs');
      const count: number | null = jsonNumber(parsed, 'count');
      const bytes: number | null = jsonNumber(parsed, 'bytes');
      const runtime: DiagnosticRuntimeFacts | null = jsonRuntimeFacts(parsed['runtime']);
      const network: DiagnosticNetworkFacts | null = jsonNetworkFacts(parsed['network']);
      if (moduleId === null || eventCode === null || level === null || outcome === null ||
        sessionRef === null || sequence === null || elapsedMs === null || wallTimeMs === null ||
        generation === null || code === null || durationMs === null || count === null || bytes === null ||
        runtime === null || network === null ||
        !diagnosticModuleIsKnown(moduleId) || !diagnosticOutcomeIsAllowed(outcome)) { return false; }
      events.push({
        sequence: sequence, elapsedMs: elapsedMs, wallTimeMs: wallTimeMs,
        moduleId: moduleId as DiagnosticModuleId, eventCode: eventCode,
        level: level as 'info' | 'warn' | 'error', outcome: outcome as DiagnosticOutcome,
        sessionRef: sessionRef, generation: generation, code: code,
        durationMs: durationMs, count: count, bytes: bytes, runtime: runtime,
        network: network
      });
    }
    const dropped: number | null = jsonNumber(last, 'droppedEventCount');
    const approximate: number | null = jsonNumber(last, 'approximateCaptureBytes');
    const declaredBytes: number | null = jsonNumber(last, 'serializedBytes');
    const eventCount: number | null = jsonNumber(last, 'eventCount');
    if (dropped === null || approximate === null || declaredBytes === null || eventCount === null ||
      eventCount !== events.length || declaredBytes !== new util.TextEncoder().encode(text).length) {
      return false;
    }
    const reconstructed: FrozenDiagnosticCapture = {
      captureId: captureId,
      durationMinutes: duration,
      selectedModules: selectedModules,
      startedWallTimeMs: started,
      endedWallTimeMs: ended,
      stopReason: stopReason,
      events: events,
      droppedEventCount: dropped,
      approximateBytes: approximate
    };
    if (!validateFrozenDiagnosticCapture(reconstructed)) { return false; }
    const expectedCounts: Record<string, number> = moduleCounts(reconstructed);
    const countValue: Object = last['moduleEventCounts'];
    if (typeof countValue !== 'object' || countValue === null) { return false; }
    const actualCounts: Record<string, Object> = countValue as Record<string, Object>;
    if (!objectHasExactKeys(actualCounts, Object.keys(expectedCounts))) { return false; }
    const countKeys: string[] = Object.keys(expectedCounts);
    for (let i: number = 0; i < countKeys.length; i++) {
      if (jsonNumber(actualCounts, countKeys[i]) !== expectedCounts[countKeys[i]]) { return false; }
    }
    return true;
  } catch (_err) {
    return false;
  }
}

export function serializeDiagnosticCapture(
  capture: FrozenDiagnosticCapture | null): DiagnosticSerializationResult {
  if (!validateFrozenDiagnosticCapture(capture) ||
    !safeMetadataToken(CURRENT_RELEASE_VERSION, 64) ||
    !safeMetadataToken(currentDiagnosticBuildId(), 96)) {
    return emptySerialization('invalid_capture');
  }
  const validCapture: FrozenDiagnosticCapture = capture as FrozenDiagnosticCapture;
  try {
    const manifest: DiagnosticManifestLine = {
      kind: 'manifest',
      schemaVersion: DIAGNOSTIC_CAPTURE_SCHEMA_VERSION,
      app: 'RemoteDesktop',
      appVersion: CURRENT_RELEASE_VERSION,
      appVersionCode: CURRENT_RELEASE_VERSION_CODE,
      buildId: currentDiagnosticBuildId(),
      captureId: validCapture.captureId,
      durationMinutes: validCapture.durationMinutes,
      selectedModules: validCapture.selectedModules.slice(),
      startedWallTimeMs: validCapture.startedWallTimeMs,
      endedWallTimeMs: validCapture.endedWallTimeMs,
      stopReason: validCapture.stopReason,
      redactionPolicyVersion: DIAGNOSTIC_REDACTION_POLICY_VERSION
    };
    const lines: string[] = [JSON.stringify(manifest)];
    for (let i: number = 0; i < validCapture.events.length; i++) {
      lines.push(JSON.stringify(eventLine(validCapture.events[i])));
    }
    const counts: Record<string, number> = moduleCounts(validCapture);
    const summaryWithoutSize: DiagnosticSummaryLine = {
      kind: 'summary',
      schemaVersion: DIAGNOSTIC_CAPTURE_SCHEMA_VERSION,
      eventCount: validCapture.events.length,
      droppedEventCount: validCapture.droppedEventCount,
      approximateCaptureBytes: validCapture.approximateBytes,
      serializedBytes: 0,
      moduleEventCounts: counts
    };
    lines.push(JSON.stringify(summaryWithoutSize));
    let text: string = '';
    let bytes: Uint8Array = new Uint8Array(0);
    let declaredSize: number = 0;
    for (let attempt: number = 0; attempt < 4; attempt++) {
      const summary: DiagnosticSummaryLine = {
        kind: 'summary',
        schemaVersion: DIAGNOSTIC_CAPTURE_SCHEMA_VERSION,
        eventCount: validCapture.events.length,
        droppedEventCount: validCapture.droppedEventCount,
        approximateCaptureBytes: validCapture.approximateBytes,
        serializedBytes: declaredSize,
        moduleEventCounts: counts
      };
      lines[lines.length - 1] = JSON.stringify(summary);
      text = lines.join('\n') + '\n';
      bytes = new util.TextEncoder().encode(text);
      if (bytes.length === declaredSize) { break; }
      declaredSize = bytes.length;
    }
    if (bytes.length !== declaredSize) {
      const finalSummary: DiagnosticSummaryLine = {
        kind: 'summary',
        schemaVersion: DIAGNOSTIC_CAPTURE_SCHEMA_VERSION,
        eventCount: validCapture.events.length,
        droppedEventCount: validCapture.droppedEventCount,
        approximateCaptureBytes: validCapture.approximateBytes,
        serializedBytes: bytes.length,
        moduleEventCounts: counts
      };
      lines[lines.length - 1] = JSON.stringify(finalSummary);
      text = lines.join('\n') + '\n';
      bytes = new util.TextEncoder().encode(text);
    }
    if (bytes.length > DIAGNOSTIC_MAX_EXPORT_BYTES) {
      return emptySerialization('too_large');
    }
    if (!validateDiagnosticJsonl(text)) {
      return emptySerialization('invalid_jsonl');
    }
    return {
      ok: true,
      code: 'ok',
      fileName: diagnosticLogFileName(validCapture.startedWallTimeMs),
      text: text,
      bytes: bytes
    };
  } catch (_err) {
    return emptySerialization('invalid_jsonl');
  }
}

export function diagnosticBytesEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) { return false; }
  for (let i: number = 0; i < left.length; i++) {
    if (left[i] !== right[i]) { return false; }
  }
  return true;
}

class SystemDiagnosticDocumentPort implements DiagnosticDocumentPort {
  private readonly context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async save(fileName: string, bytes: Uint8Array): Promise<DiagnosticSaveResult> {
    try {
      const options: picker.DocumentSaveOptions = { newFileNames: [fileName] };
      const uris: string[] =
        await new picker.DocumentViewPicker(this.context).save(options);
      if (uris.length === 0) {
        return { ok: false, code: 'cancelled', fileName: fileName, bytesWritten: 0 };
      }
      const destination = fileIo.openSync(uris[0], fileIo.OpenMode.CREATE |
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        const written = BoundedDocumentIo.writeFully(destination.fd, bytes);
        if (!written.ok) {
          return {
            ok: false,
            code: written.code === 'short_write' ? 'short_write' : 'io_error',
            fileName: fileName,
            bytesWritten: written.bytesWritten
          };
        }
        fileIo.fsyncSync(destination.fd);
      } finally {
        fileIo.closeSync(destination);
      }
      if (!this.verify(uris[0], bytes)) {
        return {
          ok: false, code: 'verify_failed', fileName: fileName, bytesWritten: bytes.length
        };
      }
      return { ok: true, code: 'ok', fileName: fileName, bytesWritten: bytes.length };
    } catch (_err) {
      return { ok: false, code: 'io_error', fileName: fileName, bytesWritten: 0 };
    }
  }

  private verify(uri: string, expected: Uint8Array): boolean {
    const source = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const size: number = fileIo.statSync(source.fd).size;
      const read = BoundedDocumentIo.readFully(source.fd, size, DIAGNOSTIC_MAX_EXPORT_BYTES);
      if (!read.ok || !diagnosticBytesEqual(expected, read.bytes)) { return false; }
      return validateDiagnosticJsonl(new util.TextDecoder().decodeToString(read.bytes));
    } catch (_err) {
      return false;
    } finally {
      fileIo.closeSync(source);
    }
  }
}

export class DiagnosticCaptureExportService {
  private static instance: DiagnosticCaptureExportService | null = null;

  static getInstance(): DiagnosticCaptureExportService {
    if (DiagnosticCaptureExportService.instance === null) {
      DiagnosticCaptureExportService.instance = new DiagnosticCaptureExportService();
    }
    return DiagnosticCaptureExportService.instance;
  }

  async save(runtime: DiagnosticCaptureRuntime,
    context: common.UIAbilityContext): Promise<DiagnosticSaveResult> {
    return this.saveWithPort(runtime, new SystemDiagnosticDocumentPort(context));
  }

  async saveWithPort(runtime: DiagnosticCaptureRuntime,
    documentPort: DiagnosticDocumentPort): Promise<DiagnosticSaveResult> {
    const startSaving: DiagnosticCaptureActionCode = runtime.beginSaving();
    if (startSaving !== 'ok') {
      return {
        ok: false,
        code: startSaving === 'busy' ? 'busy' : 'not_ready',
        fileName: '',
        bytesWritten: 0
      };
    }
    const serialized: DiagnosticSerializationResult =
      serializeDiagnosticCapture(runtime.frozenCapture());
    if (!serialized.ok) {
      runtime.finishSaving(false);
      return {
        ok: false,
        code: serialized.code === 'too_large' ? 'too_large' : 'invalid_jsonl',
        fileName: '',
        bytesWritten: 0
      };
    }
    try {
      const result: DiagnosticSaveResult =
        await documentPort.save(serialized.fileName, serialized.bytes);
      runtime.finishSaving(result.ok);
      return {
        ok: result.ok,
        code: result.code,
        fileName: result.fileName === '' ? serialized.fileName : result.fileName,
        bytesWritten: result.bytesWritten
      };
    } catch (_err) {
      runtime.finishSaving(false);
      return {
        ok: false,
        code: 'io_error',
        fileName: serialized.fileName,
        bytesWritten: 0
      };
    }
  }
}
