import {
  DiagnosticCaptureActionCode,
  DiagnosticCaptureRuntime,
  DiagnosticCaptureStatus,
  FrozenDiagnosticCapture
} from './DiagnosticCaptureRuntime';

/** The two user-facing entry points that may own the shared capture runtime. */
export type DiagnosticCaptureOwnerKind = 'manual' | 'ai';

export interface DiagnosticCaptureCoordinatorStatus extends DiagnosticCaptureStatus {
  ownerId: string;
  ownerKind: DiagnosticCaptureOwnerKind | '';
  generation: number;
}

/**
 * Serializes access to DiagnosticCaptureRuntime.
 *
 * Runtime samplers intentionally keep using DiagnosticCaptureRuntime directly;
 * only user-facing lifecycle actions go through this coordinator. This keeps a
 * manual log capture from being stopped or discarded by the AI workbench (and
 * vice versa) while preserving the existing sampling hot path.
 */
export class DiagnosticCaptureCoordinator {
  private static instance: DiagnosticCaptureCoordinator | null = null;
  private readonly captureRuntime: DiagnosticCaptureRuntime;
  private ownerId: string = '';
  private ownerKindValue: DiagnosticCaptureOwnerKind | '' = '';
  private generationValue: number = 0;

  constructor(runtime: DiagnosticCaptureRuntime = DiagnosticCaptureRuntime.getInstance()) {
    this.captureRuntime = runtime;
  }

  static getInstance(): DiagnosticCaptureCoordinator {
    if (DiagnosticCaptureCoordinator.instance === null) {
      DiagnosticCaptureCoordinator.instance = new DiagnosticCaptureCoordinator();
    }
    return DiagnosticCaptureCoordinator.instance;
  }

  runtime(): DiagnosticCaptureRuntime {
    return this.captureRuntime;
  }

  status(): DiagnosticCaptureCoordinatorStatus {
    this.reconcileIdleOwner();
    const status: DiagnosticCaptureStatus = this.captureRuntime.status();
    return {
      phase: status.phase,
      captureId: status.captureId,
      durationMinutes: status.durationMinutes,
      profile: status.profile,
      fullLog: status.fullLog,
      selectedModules: status.selectedModules,
      startedWallTimeMs: status.startedWallTimeMs,
      deadlineWallTimeMs: status.deadlineWallTimeMs,
      endedWallTimeMs: status.endedWallTimeMs,
      remainingSeconds: status.remainingSeconds,
      eventCount: status.eventCount,
      droppedEventCount: status.droppedEventCount,
      approximateBytes: status.approximateBytes,
      stopReason: status.stopReason,
      ownerId: this.ownerId,
      ownerKind: this.ownerKindValue,
      generation: this.generationValue
    };
  }

  ownerKind(): DiagnosticCaptureOwnerKind | '' {
    this.reconcileIdleOwner();
    return this.ownerKindValue;
  }

  generation(): number {
    return this.generationValue;
  }

  start(ownerId: string, ownerKind: DiagnosticCaptureOwnerKind,
    durationMinutes: number, modules: string[], fullLog: boolean = false): DiagnosticCaptureActionCode {
    if (!this.claim(ownerId, ownerKind)) { return 'busy'; }
    const result: DiagnosticCaptureActionCode =
      this.captureRuntime.start(durationMinutes, modules, fullLog);
    if (result !== 'ok') { this.clearOwnerIfIdle(); }
    return result;
  }

  stop(ownerId: string, ownerKind: DiagnosticCaptureOwnerKind): DiagnosticCaptureActionCode {
    if (!this.isOwner(ownerId, ownerKind)) { return 'busy'; }
    return this.captureRuntime.stop();
  }

  discard(ownerId: string, ownerKind: DiagnosticCaptureOwnerKind,
    expectedCaptureId: string = ''): DiagnosticCaptureActionCode {
    if (!this.isOwner(ownerId, ownerKind)) { return 'busy'; }
    const result: DiagnosticCaptureActionCode = this.captureRuntime.discard(expectedCaptureId);
    if (result === 'ok' || result === 'not_active') { this.clearOwnerIfIdle(); }
    return result;
  }

  bundle(ownerId: string, ownerKind: DiagnosticCaptureOwnerKind): FrozenDiagnosticCapture | null {
    if (!this.isOwner(ownerId, ownerKind)) { return null; }
    return this.captureRuntime.frozenCapture();
  }

  isOwner(ownerId: string, ownerKind: DiagnosticCaptureOwnerKind): boolean {
    this.reconcileIdleOwner();
    return ownerId.trim().length > 0 && this.ownerId === ownerId && this.ownerKindValue === ownerKind;
  }

  /**
   * Invalidates the shared capture at an account/logout boundary. A save that
   * is already in progress is allowed to finish through the existing document
   * picker; its runtime phase still blocks a new owner until it reaches idle.
   */
  invalidateAll(): void {
    this.generationValue += 1;
    const status: DiagnosticCaptureStatus = this.captureRuntime.status();
    if (status.phase === 'capturing') {
      this.captureRuntime.stop();
    }
    const afterStop: DiagnosticCaptureStatus = this.captureRuntime.status();
    if (afterStop.phase === 'readyToSave') {
      this.captureRuntime.discard(afterStop.captureId);
    }
    this.clearOwnerIfIdle();
  }

  private claim(ownerId: string, ownerKind: DiagnosticCaptureOwnerKind): boolean {
    if (ownerId.trim().length === 0) { return false; }
    this.reconcileIdleOwner();
    const status: DiagnosticCaptureStatus = this.captureRuntime.status();
    if (status.phase !== 'idle') {
      return this.ownerId === ownerId && this.ownerKindValue === ownerKind;
    }
    if (this.ownerId !== '' &&
      (this.ownerId !== ownerId || this.ownerKindValue !== ownerKind)) {
      this.ownerId = '';
      this.ownerKindValue = '';
    }
    this.ownerId = ownerId;
    this.ownerKindValue = ownerKind;
    return true;
  }

  private reconcileIdleOwner(): void {
    if (this.captureRuntime.status().phase === 'idle') {
      this.ownerId = '';
      this.ownerKindValue = '';
    }
  }

  private clearOwnerIfIdle(): void {
    if (this.captureRuntime.status().phase === 'idle') {
      this.ownerId = '';
      this.ownerKindValue = '';
    }
  }
}
