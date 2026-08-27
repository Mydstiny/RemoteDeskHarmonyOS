import systemDateTime from '@ohos.systemDateTime';
import { util } from '@kit.ArkTS';
import {
  DIAGNOSTIC_DEFAULT_DURATION_MINUTES,
  DIAGNOSTIC_MAX_CAPTURE_BYTES,
  DIAGNOSTIC_MAX_EVENTS,
  DIAGNOSTIC_MAX_EVENT_BYTES,
  DIAGNOSTIC_MAX_SESSION_REFS,
  DiagnosticEventLevel,
  DiagnosticModuleId,
  DiagnosticOutcome,
  DiagnosticRuntimeFacts,
  DiagnosticStopReason,
  copyDiagnosticRuntimeFacts,
  diagnosticDurationIsAllowed,
  diagnosticEventIsAllowed,
  diagnosticLevelForOutcome,
  diagnosticOutcomeIsAllowed,
  diagnosticRuntimeFactsAreValid,
  diagnosticSafeInteger,
  emptyDiagnosticRuntimeFacts,
  normalizeDiagnosticModules
} from './DiagnosticCapturePolicy';

export type DiagnosticCapturePhase = 'idle' | 'capturing' | 'readyToSave' | 'saving';

export type DiagnosticCaptureActionCode =
  'ok' |
  'invalid_duration' |
  'already_active' |
  'not_active' |
  'not_ready' |
  'busy' |
  'stale_capture' |
  'clock_unavailable';

export interface DiagnosticClock {
  uptimeMs(): number;
  wallTimeMs(): number;
}

export interface DiagnosticCaptureEvent {
  sequence: number;
  elapsedMs: number;
  wallTimeMs: number;
  moduleId: DiagnosticModuleId;
  eventCode: string;
  level: DiagnosticEventLevel;
  outcome: DiagnosticOutcome;
  sessionRef: string;
  generation: number;
  code: number;
  durationMs: number;
  count: number;
  bytes: number;
  runtime: DiagnosticRuntimeFacts;
}

export interface DiagnosticCaptureStatus {
  phase: DiagnosticCapturePhase;
  captureId: string;
  durationMinutes: number;
  selectedModules: DiagnosticModuleId[];
  startedWallTimeMs: number;
  deadlineWallTimeMs: number;
  endedWallTimeMs: number;
  remainingSeconds: number;
  eventCount: number;
  droppedEventCount: number;
  approximateBytes: number;
  stopReason: DiagnosticStopReason | '';
}

export interface FrozenDiagnosticCapture {
  captureId: string;
  durationMinutes: number;
  selectedModules: DiagnosticModuleId[];
  startedWallTimeMs: number;
  endedWallTimeMs: number;
  stopReason: DiagnosticStopReason;
  events: DiagnosticCaptureEvent[];
  droppedEventCount: number;
  approximateBytes: number;
}

class SystemDiagnosticClock implements DiagnosticClock {
  uptimeMs(): number {
    return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false);
  }

  wallTimeMs(): number {
    return Date.now();
  }
}

export class DiagnosticCaptureRuntime {
  private static instance: DiagnosticCaptureRuntime | null = null;

  private readonly clock: DiagnosticClock;
  private phase: DiagnosticCapturePhase = 'idle';
  private captureOrdinal: number = 0;
  private captureId: string = '';
  private durationMinutes: number = DIAGNOSTIC_DEFAULT_DURATION_MINUTES;
  private selectedModules: DiagnosticModuleId[] = ['core.app'];
  private startedUptimeMs: number = 0;
  private deadlineUptimeMs: number = 0;
  private startedWallTimeMs: number = 0;
  private endedWallTimeMs: number = 0;
  private stopReason: DiagnosticStopReason | '' = '';
  private sequence: number = 0;
  private events: DiagnosticCaptureEvent[] = [];
  private approximateBytes: number = 0;
  private droppedEventCount: number = 0;
  private sessionIds: number[] = [];

  constructor(clock: DiagnosticClock = new SystemDiagnosticClock()) {
    this.clock = clock;
  }

  static getInstance(): DiagnosticCaptureRuntime {
    if (DiagnosticCaptureRuntime.instance === null) {
      DiagnosticCaptureRuntime.instance = new DiagnosticCaptureRuntime();
    }
    return DiagnosticCaptureRuntime.instance;
  }

  start(durationMinutes: number,
    moduleIds: string[] = ['core.app']): DiagnosticCaptureActionCode {
    if (!diagnosticDurationIsAllowed(durationMinutes)) { return 'invalid_duration'; }
    if (this.phase !== 'idle') { return 'already_active'; }
    try {
      const uptime: number = this.safeClockInteger(this.clock.uptimeMs());
      const wallTime: number = this.safeClockInteger(this.clock.wallTimeMs());
      if (uptime < 0 || wallTime <= 0) { return 'clock_unavailable'; }
      this.captureOrdinal += 1;
      this.captureId = 'capture-' + this.captureOrdinal.toString();
      this.durationMinutes = durationMinutes;
      this.selectedModules = normalizeDiagnosticModules(moduleIds);
      this.startedUptimeMs = uptime;
      this.deadlineUptimeMs = uptime + durationMinutes * 60 * 1000;
      this.startedWallTimeMs = wallTime;
      this.endedWallTimeMs = 0;
      this.stopReason = '';
      this.sequence = 0;
      this.events = [];
      this.approximateBytes = 0;
      this.droppedEventCount = 0;
      this.sessionIds = [];
      this.phase = 'capturing';
      this.appendEventAt(uptime, 'core.app', 'capture_started',
        'started', 0, 0, 0, 0, this.selectedModules.length, 0,
        emptyDiagnosticRuntimeFacts());
      return 'ok';
    } catch (_err) {
      this.resetCapture();
      return 'clock_unavailable';
    }
  }

  isModuleCapturing(moduleId: DiagnosticModuleId): boolean {
    return this.phase === 'capturing' && this.selectedModules.indexOf(moduleId) >= 0;
  }

  captureIdForModule(moduleId: DiagnosticModuleId): string {
    return this.isModuleCapturing(moduleId) ? this.captureId : '';
  }

  record(moduleId: DiagnosticModuleId, eventCode: string, outcome: DiagnosticOutcome,
    correlationId: number = 0, generation: number = 0, code: number = 0,
    durationMs: number = 0, count: number = 0, bytes: number = 0,
    runtime?: DiagnosticRuntimeFacts): boolean {
    if (!this.isModuleCapturing(moduleId)) { return false; }
    try {
      if (!diagnosticEventIsAllowed(moduleId, eventCode) ||
        !diagnosticOutcomeIsAllowed(outcome)) {
        this.droppedEventCount += 1;
        return false;
      }
      const safeCorrelation: number | null = diagnosticSafeInteger(correlationId);
      const safeGeneration: number | null = diagnosticSafeInteger(generation);
      const safeCode: number | null = diagnosticSafeInteger(code);
      const safeDuration: number | null = diagnosticSafeInteger(durationMs);
      const safeCount: number | null = diagnosticSafeInteger(count);
      const safeBytes: number | null = diagnosticSafeInteger(bytes);
      const safeRuntime: DiagnosticRuntimeFacts = runtime === undefined ?
        emptyDiagnosticRuntimeFacts() : copyDiagnosticRuntimeFacts(runtime);
      if (safeCorrelation === null || safeCorrelation < 0 ||
        safeGeneration === null || safeGeneration < 0 || safeCode === null ||
        safeDuration === null || safeDuration < 0 ||
        safeCount === null || safeCount < 0 || safeBytes === null || safeBytes < 0 ||
        !diagnosticRuntimeFactsAreValid(safeRuntime)) {
        this.droppedEventCount += 1;
        return false;
      }
      const uptime: number = this.safeClockInteger(this.clock.uptimeMs());
      if (uptime >= this.deadlineUptimeMs) {
        this.expireAt(uptime);
        return false;
      }
      return this.appendEventAt(uptime, moduleId, eventCode, outcome,
        safeCorrelation, safeGeneration, safeCode, safeDuration, safeCount, safeBytes,
        safeRuntime);
    } catch (_err) {
      this.droppedEventCount += 1;
      return false;
    }
  }

  stop(): DiagnosticCaptureActionCode {
    if (this.phase === 'idle') { return 'not_active'; }
    if (this.phase === 'saving') { return 'busy'; }
    if (this.phase === 'readyToSave') { return 'ok'; }
    try {
      const uptime: number = this.safeClockInteger(this.clock.uptimeMs());
      if (uptime >= this.deadlineUptimeMs) {
        this.expireAt(uptime);
        return 'ok';
      }
      const elapsed: number = Math.max(0, uptime - this.startedUptimeMs);
      this.appendEventAt(uptime, 'core.app', 'capture_stopped',
        'succeeded', 0, 0, 0, elapsed, this.events.length, this.approximateBytes,
        emptyDiagnosticRuntimeFacts());
      this.freeze('manual', uptime);
      return 'ok';
    } catch (_err) {
      return 'clock_unavailable';
    }
  }

  status(): DiagnosticCaptureStatus {
    this.refreshDeadlineSafely();
    let remainingSeconds: number = 0;
    if (this.phase === 'capturing') {
      try {
        const remainingMs: number = Math.max(0,
          this.deadlineUptimeMs - this.safeClockInteger(this.clock.uptimeMs()));
        remainingSeconds = Math.ceil(remainingMs / 1000);
      } catch (_err) {
        remainingSeconds = 0;
      }
    }
    return {
      phase: this.phase,
      captureId: this.captureId,
      durationMinutes: this.durationMinutes,
      selectedModules: this.selectedModules.slice(),
      startedWallTimeMs: this.startedWallTimeMs,
      deadlineWallTimeMs: this.startedWallTimeMs > 0 ?
        this.startedWallTimeMs + this.durationMinutes * 60 * 1000 : 0,
      endedWallTimeMs: this.endedWallTimeMs,
      remainingSeconds: remainingSeconds,
      eventCount: this.events.length,
      droppedEventCount: this.droppedEventCount,
      approximateBytes: this.approximateBytes,
      stopReason: this.stopReason
    };
  }

  frozenCapture(): FrozenDiagnosticCapture | null {
    this.refreshDeadlineSafely();
    if (this.phase !== 'readyToSave' && this.phase !== 'saving') { return null; }
    return {
      captureId: this.captureId,
      durationMinutes: this.durationMinutes,
      selectedModules: this.selectedModules.slice(),
      startedWallTimeMs: this.startedWallTimeMs,
      endedWallTimeMs: this.endedWallTimeMs,
      stopReason: this.stopReason === '' ? 'manual' : this.stopReason,
      events: this.events.map((event: DiagnosticCaptureEvent): DiagnosticCaptureEvent => {
        return this.copyEvent(event);
      }),
      droppedEventCount: this.droppedEventCount,
      approximateBytes: this.approximateBytes
    };
  }

  beginSaving(): DiagnosticCaptureActionCode {
    this.refreshDeadlineSafely();
    if (this.phase === 'saving') { return 'busy'; }
    if (this.phase !== 'readyToSave') { return 'not_ready'; }
    this.phase = 'saving';
    return 'ok';
  }

  finishSaving(success: boolean): void {
    if (this.phase !== 'saving') { return; }
    if (success) {
      this.resetCapture();
    } else {
      this.phase = 'readyToSave';
    }
  }

  discard(expectedCaptureId: string = ''): DiagnosticCaptureActionCode {
    if (this.phase === 'saving') { return 'busy'; }
    if (this.phase === 'idle') { return 'not_active'; }
    if (expectedCaptureId.length > 0 && expectedCaptureId !== this.captureId) {
      return 'stale_capture';
    }
    this.resetCapture();
    return 'ok';
  }

  private appendEventAt(uptime: number, moduleId: DiagnosticModuleId,
    eventCode: string, outcome: DiagnosticOutcome,
    correlationId: number, generation: number, code: number,
    durationMs: number, count: number, bytes: number,
    runtime: DiagnosticRuntimeFacts): boolean {
    const terminalEvent: boolean = moduleId === 'core.app' &&
      (eventCode === 'capture_stopped' || eventCode === 'capture_expired');
    const eventLimit: number = terminalEvent ? DIAGNOSTIC_MAX_EVENTS : DIAGNOSTIC_MAX_EVENTS - 1;
    if (this.events.length >= eventLimit) {
      this.droppedEventCount += 1;
      return false;
    }
    const sessionRef: string = this.sessionRefFor(correlationId);
    if (correlationId > 0 && sessionRef === '') {
      this.droppedEventCount += 1;
      return false;
    }
    const elapsedMs: number = Math.max(0, uptime - this.startedUptimeMs);
    const event: DiagnosticCaptureEvent = {
      sequence: this.sequence + 1,
      elapsedMs: elapsedMs,
      wallTimeMs: this.startedWallTimeMs + elapsedMs,
      moduleId: moduleId,
      eventCode: eventCode,
      level: diagnosticLevelForOutcome(outcome),
      outcome: outcome,
      sessionRef: sessionRef,
      generation: generation,
      code: code,
      durationMs: durationMs,
      count: count,
      bytes: bytes,
      runtime: copyDiagnosticRuntimeFacts(runtime)
    };
    const eventBytes: number = new util.TextEncoder().encode(JSON.stringify(event)).length + 1;
    const reservedTerminalBytes: number = terminalEvent ? 0 : DIAGNOSTIC_MAX_EVENT_BYTES;
    if (eventBytes > DIAGNOSTIC_MAX_EVENT_BYTES ||
      this.approximateBytes + eventBytes + reservedTerminalBytes > DIAGNOSTIC_MAX_CAPTURE_BYTES) {
      this.droppedEventCount += 1;
      return false;
    }
    this.sequence = event.sequence;
    this.events.push(event);
    this.approximateBytes += eventBytes;
    return true;
  }

  private sessionRefFor(correlationId: number): string {
    if (correlationId <= 0) { return ''; }
    const existing: number = this.sessionIds.indexOf(correlationId);
    if (existing >= 0) { return 'session-' + (existing + 1).toString(); }
    if (this.sessionIds.length >= DIAGNOSTIC_MAX_SESSION_REFS) { return ''; }
    this.sessionIds.push(correlationId);
    return 'session-' + this.sessionIds.length.toString();
  }

  private expireAt(uptime: number): void {
    if (this.phase !== 'capturing') { return; }
    const eventUptime: number = Math.max(this.startedUptimeMs,
      Math.min(uptime, this.deadlineUptimeMs));
    this.appendEventAt(eventUptime, 'core.app', 'capture_expired',
      'timeout', 0, 0, 0, this.durationMinutes * 60 * 1000,
      this.events.length, this.approximateBytes, emptyDiagnosticRuntimeFacts());
    this.freeze('deadline', eventUptime);
  }

  private freeze(reason: DiagnosticStopReason, uptime: number): void {
    this.stopReason = reason;
    this.endedWallTimeMs = this.startedWallTimeMs +
      Math.max(0, uptime - this.startedUptimeMs);
    this.phase = 'readyToSave';
  }

  private refreshDeadlineSafely(): void {
    if (this.phase !== 'capturing') { return; }
    try {
      const uptime: number = this.safeClockInteger(this.clock.uptimeMs());
      if (uptime < this.deadlineUptimeMs) { return; }
      this.expireAt(uptime);
    } catch (_err) {
      // Clock failure must not affect the calling business path. The next
      // status/record call can retry the deadline check.
    }
  }

  private safeClockInteger(value: number): number {
    if (!Number.isFinite(value) || value < 0) { throw new Error('clock'); }
    return Math.floor(value);
  }

  private copyEvent(source: DiagnosticCaptureEvent): DiagnosticCaptureEvent {
    return {
      sequence: source.sequence,
      elapsedMs: source.elapsedMs,
      wallTimeMs: source.wallTimeMs,
      moduleId: source.moduleId,
      eventCode: source.eventCode,
      level: source.level,
      outcome: source.outcome,
      sessionRef: source.sessionRef,
      generation: source.generation,
      code: source.code,
      durationMs: source.durationMs,
      count: source.count,
      bytes: source.bytes,
      runtime: copyDiagnosticRuntimeFacts(source.runtime)
    };
  }

  private resetCapture(): void {
    this.phase = 'idle';
    this.captureId = '';
    this.durationMinutes = DIAGNOSTIC_DEFAULT_DURATION_MINUTES;
    this.selectedModules = ['core.app'];
    this.startedUptimeMs = 0;
    this.deadlineUptimeMs = 0;
    this.startedWallTimeMs = 0;
    this.endedWallTimeMs = 0;
    this.stopReason = '';
    this.sequence = 0;
    this.events = [];
    this.approximateBytes = 0;
    this.droppedEventCount = 0;
    this.sessionIds = [];
  }
}

export function isDiagnosticModuleCapturing(moduleId: DiagnosticModuleId): boolean {
  try {
    return DiagnosticCaptureRuntime.getInstance().isModuleCapturing(moduleId);
  } catch (_err) {
    return false;
  }
}

export function diagnosticCaptureIdForModule(moduleId: DiagnosticModuleId): string {
  try {
    return DiagnosticCaptureRuntime.getInstance().captureIdForModule(moduleId);
  } catch (_err) {
    return '';
  }
}

export function recordDiagnosticEvent(moduleId: DiagnosticModuleId,
  eventCode: string, outcome: DiagnosticOutcome, correlationId: number = 0,
  generation: number = 0, code: number = 0, durationMs: number = 0,
  count: number = 0, bytes: number = 0,
  runtime?: DiagnosticRuntimeFacts): void {
  try {
    DiagnosticCaptureRuntime.getInstance().record(moduleId, eventCode, outcome,
      correlationId, generation, code, durationMs, count, bytes, runtime);
  } catch (_err) {
    // Diagnostics are a best-effort side channel and can never fail a producer.
  }
}
