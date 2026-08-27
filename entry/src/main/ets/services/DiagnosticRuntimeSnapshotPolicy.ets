import {
  RustDeskDiagnosticsSnapshot,
  SshTerminalDiagnosticsSnapshot
} from '../types/rdpnapi';
import { MoonlightNativeStreamSnapshot } from './MoonlightHostService';
import {
  DiagnosticModuleId,
  DiagnosticPeerPlatform,
  DiagnosticPresentation,
  DiagnosticProducerTransform,
  DiagnosticRuntimeBackend,
  DiagnosticRuntimeCodec,
  DiagnosticRuntimeFacts,
  DiagnosticRuntimePath
} from './DiagnosticCapturePolicy';

export type DiagnosticDesktopModule =
  'connection.rdp' | 'connection.rustdesk' | 'connection.vnc';

interface DiagnosticRuntimeObservation {
  captureId: string;
  signature: string;
  recordedAtMs: number;
}

export const DIAGNOSTIC_RUNTIME_SNAPSHOT_INTERVAL_MS: number = 5000;

export interface DiagnosticRuntimeSamplingScheduler {
  schedule(callback: () => void, delayMs: number): number;
  cancel(timerId: number): void;
}

export class DiagnosticRuntimeSamplingLoop {
  private readonly scheduler: DiagnosticRuntimeSamplingScheduler;
  private readonly sampler: (sessionId: number) => void;
  private sessionIds: number[] = [];
  private timerId: number = -1;

  constructor(scheduler: DiagnosticRuntimeSamplingScheduler,
    sampler: (sessionId: number) => void) {
    this.scheduler = scheduler;
    this.sampler = sampler;
  }

  track(sessionId: number): void {
    if (!Number.isSafeInteger(sessionId) || sessionId <= 0) { return; }
    if (this.sessionIds.indexOf(sessionId) < 0) {
      this.sessionIds.push(sessionId);
    }
    this.scheduleNext();
  }

  forget(sessionId: number): void {
    const index: number = this.sessionIds.indexOf(sessionId);
    if (index >= 0) { this.sessionIds.splice(index, 1); }
    if (this.sessionIds.length === 0) { this.cancelTimer(); }
  }

  clear(): void {
    this.sessionIds = [];
    this.cancelTimer();
  }

  private scheduleNext(): void {
    if (this.timerId >= 0 || this.sessionIds.length === 0) { return; }
    try {
      this.timerId = this.scheduler.schedule((): void => {
        this.timerId = -1;
        const sessions: number[] = this.sessionIds.slice();
        for (let index: number = 0; index < sessions.length; index++) {
          if (this.sessionIds.indexOf(sessions[index]) < 0) { continue; }
          try { this.sampler(sessions[index]); } catch (_err) {}
        }
        this.scheduleNext();
      }, DIAGNOSTIC_RUNTIME_SNAPSHOT_INTERVAL_MS);
    } catch (_err) {
      this.timerId = -1;
    }
  }

  private cancelTimer(): void {
    if (this.timerId < 0) { return; }
    try { this.scheduler.cancel(this.timerId); } catch (_err) {}
    this.timerId = -1;
  }
}

function safeCounter(value: number | undefined): number {
  if (value === undefined || !Number.isFinite(value) || value <= 0) { return 0; }
  return Math.min(Number.MAX_SAFE_INTEGER, Math.floor(value));
}

function safeSum(values: number[]): number {
  let total: number = 0;
  for (let index: number = 0; index < values.length; index++) {
    total = Math.min(Number.MAX_SAFE_INTEGER, total + safeCounter(values[index]));
  }
  return total;
}

function desktopBackend(value: string): DiagnosticRuntimeBackend {
  switch (value.trim().toLowerCase()) {
    case 'hardware': return 'hardware';
    case 'software': return 'software';
    case 'gdi': return 'gdi';
    case 'raw': return 'raw';
    case 'zrle': return 'zrle';
    case 'copyrect': return 'copyrect';
    default: return 'unknown';
  }
}

function desktopCodec(value: number): DiagnosticRuntimeCodec {
  switch (value) {
    case 0: return 'h264';
    case 1: return 'h265';
    case 2: return 'vp8';
    case 3: return 'vp9';
    case 4: return 'av1';
    case 5: return 'raw';
    default: return 'unknown';
  }
}

function connectionPath(value: string): DiagnosticRuntimePath {
  switch (value.trim().toLowerCase()) {
    case 'direct': return 'direct';
    case 'relay': return 'relay';
    case 'gateway': return 'gateway';
    case 'proxy': return 'proxy';
    default: return 'unknown';
  }
}

function peerPlatform(value: string | undefined): DiagnosticPeerPlatform {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'windows': return 'windows';
    case 'macos': return 'macos';
    case 'linux': return 'linux';
    case 'android': return 'android';
    case 'ios': return 'ios';
    case 'other': return 'other';
    default: return 'unknown';
  }
}

function presentation(value: string | undefined): DiagnosticPresentation {
  if (value === 'identity') { return 'identity'; }
  if (value === 'producer') { return 'producer'; }
  return 'unknown';
}

function producerTransform(value: string | undefined): DiagnosticProducerTransform {
  switch (value) {
    case 'not_sampled': return 'not_sampled';
    case 'identity': return 'identity';
    case 'flip_x': return 'flip_x';
    case 'flip_y': return 'flip_y';
    case 'rotate_180': return 'rotate_180';
    case 'other': return 'other';
    case 'read_failed': return 'read_failed';
    default: return 'unknown';
  }
}

export function diagnosticDesktopRuntimeEventCode(moduleId: DiagnosticDesktopModule): string {
  if (moduleId === 'connection.rdp') { return 'rdp_runtime_snapshot'; }
  if (moduleId === 'connection.vnc') { return 'vnc_runtime_snapshot'; }
  return 'rustdesk_runtime_snapshot';
}

export function diagnosticDesktopRuntimeFacts(moduleId: DiagnosticDesktopModule,
  source: RustDeskDiagnosticsSnapshot): DiagnosticRuntimeFacts {
  return {
    state: source.sessionActive ? 'connected' :
      (source.supported ? 'disconnected' : 'unknown'),
    backend: desktopBackend(source.decoderBackend),
    codec: desktopCodec(source.codec),
    path: connectionPath(source.connectionPath),
    peerPlatform: moduleId === 'connection.rustdesk' ?
      peerPlatform(source.peerPlatform) : 'unknown',
    presentation: moduleId === 'connection.rustdesk' ?
      presentation(source.nativeImagePresentation) : 'unknown',
    producerTransform: moduleId === 'connection.rustdesk' ?
      producerTransform(source.producerTransform) : 'unknown',
    width: safeCounter(source.width),
    height: safeCounter(source.height),
    frames: safeCounter(source.receivedFrames),
    dropped: safeSum([
      source.droppedFrames, source.presentationRejected, source.inputEventsDropped
    ]),
    errors: safeCounter(source.decodeErrors),
    queueDepth: safeCounter(source.queueDepth),
    latencyMs: safeCounter(source.latencyMs)
  };
}

export function diagnosticSshRuntimeFacts(
  source: SshTerminalDiagnosticsSnapshot): DiagnosticRuntimeFacts {
  return {
    state: source.sessionActive ? 'connected' :
      (source.supported ? 'disconnected' : 'unknown'),
    backend: 'terminal', codec: 'unknown', path: 'unknown',
    peerPlatform: 'unknown', presentation: 'unknown', producerTransform: 'unknown',
    width: 0, height: 0,
    frames: safeCounter(source.remoteReadEvents),
    dropped: safeSum([source.inputLoss, source.inputDuplicate, source.callbackQueueFull]),
    errors: safeSum([source.callbackDeliveryErrors, source.callbackClosed]),
    queueDepth: safeCounter(source.inputQueueDepth),
    latencyMs: safeCounter(source.maxInputToWriteCompleteNs / 1000000)
  };
}

function moonlightCodec(value: string | undefined): DiagnosticRuntimeCodec {
  if (value === 'h264') { return 'h264'; }
  if (value === 'hevc') { return 'h265'; }
  if (value === 'av1') { return 'av1'; }
  return 'unknown';
}

export function diagnosticMoonlightRuntimeFacts(
  source: MoonlightNativeStreamSnapshot): DiagnosticRuntimeFacts {
  return {
    state: source.terminal ? 'disconnected' :
      (source.transportReady ? 'connected' : 'connecting'),
    backend: 'native', codec: moonlightCodec(source.codec), path: 'unknown',
    peerPlatform: 'unknown', presentation: 'unknown', producerTransform: 'unknown',
    width: safeCounter(source.streamWidth),
    height: safeCounter(source.streamHeight),
    frames: safeCounter(source.acceptedVideoFrames),
    dropped: safeSum([
      source.droppedVideoFrames ?? 0,
      source.rejectedAudioPackets ?? 0,
      source.rejectedInputEvents ?? 0
    ]),
    errors: safeCounter(source.decoderSurfaceUpdateFailures),
    queueDepth: safeCounter(source.decoderQueueDepth),
    latencyMs: safeCounter(source.decoderCodecLatencyMs)
  };
}

export function diagnosticRuntimeFactsSignature(facts: DiagnosticRuntimeFacts): string {
  return [
    facts.state, facts.backend, facts.codec, facts.path, facts.peerPlatform,
    facts.presentation, facts.producerTransform, facts.width, facts.height
  ].join('|');
}

export class DiagnosticRuntimeSnapshotGate {
  private readonly observations: Map<string, DiagnosticRuntimeObservation> =
    new Map<string, DiagnosticRuntimeObservation>();

  shouldRecord(moduleId: DiagnosticModuleId, sessionId: number, captureId: string,
    facts: DiagnosticRuntimeFacts, nowMs: number): boolean {
    const key: string = moduleId + ':' + sessionId.toString();
    if (captureId.length === 0 || sessionId <= 0 || !Number.isFinite(nowMs) || nowMs < 0) {
      this.observations.delete(key);
      return false;
    }
    const signature: string = diagnosticRuntimeFactsSignature(facts);
    const previous: DiagnosticRuntimeObservation | undefined = this.observations.get(key);
    const due: boolean = previous === undefined || previous.captureId !== captureId ||
      previous.signature !== signature || nowMs < previous.recordedAtMs ||
      nowMs - previous.recordedAtMs >= DIAGNOSTIC_RUNTIME_SNAPSHOT_INTERVAL_MS;
    if (!due) { return false; }
    this.observations.set(key, {
      captureId: captureId, signature: signature, recordedAtMs: Math.floor(nowMs)
    });
    return true;
  }

  forget(moduleId: DiagnosticModuleId, sessionId: number): void {
    this.observations.delete(moduleId + ':' + sessionId.toString());
  }

  clear(): void {
    this.observations.clear();
  }
}
