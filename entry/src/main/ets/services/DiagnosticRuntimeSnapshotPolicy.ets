import { videoDiagnosticEvidence, finalVideoSamplingCorners } from './VideoDiagnosticEvidence';
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
  DiagnosticRuntimePath,
  DiagnosticProtocolFacts,
  emptyDiagnosticProtocolFacts
} from './DiagnosticCapturePolicy';

export type DiagnosticDesktopModule =
  'connection.rdp' | 'connection.rustdesk' | 'connection.vnc';

interface DiagnosticRuntimeObservation {
  captureId: string;
  signature: string;
  recordedAtMs: number;
}

export const DIAGNOSTIC_RUNTIME_SNAPSHOT_INTERVAL_MS: number = 5000;
/** Full captures trade a bounded amount of storage for finer failure timing. */
export const DIAGNOSTIC_FULL_RUNTIME_SNAPSHOT_INTERVAL_MS: number = 1000;

export interface DiagnosticRuntimeSamplingScheduler {
  schedule(callback: () => void, delayMs: number): number;
  cancel(timerId: number): void;
}

export type DiagnosticRuntimeSamplingIntervalProvider = () => number;

export class DiagnosticRuntimeSamplingLoop {
  private readonly scheduler: DiagnosticRuntimeSamplingScheduler;
  private readonly sampler: (sessionId: number) => void;
  private readonly intervalProvider: DiagnosticRuntimeSamplingIntervalProvider;
  private sessionIds: number[] = [];
  private timerId: number = -1;

  constructor(scheduler: DiagnosticRuntimeSamplingScheduler,
    sampler: (sessionId: number) => void,
    intervalProvider: DiagnosticRuntimeSamplingIntervalProvider =
      (): number => DIAGNOSTIC_RUNTIME_SNAPSHOT_INTERVAL_MS) {
    this.scheduler = scheduler;
    this.sampler = sampler;
    this.intervalProvider = intervalProvider;
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

  /**
   * Sample every currently tracked session immediately.  The periodic timer
   * is intentionally phase independent, so a short capture must not wait for
   * the next five second tick before it gets its first/final snapshot.
   */
  sampleNow(): void {
    const sessions: number[] = this.sessionIds.slice();
    for (let index: number = 0; index < sessions.length; index++) {
      if (this.sessionIds.indexOf(sessions[index]) < 0) { continue; }
      try { this.sampler(sessions[index]); } catch (_err) {}
    }
  }

  private scheduleNext(): void {
    if (this.timerId >= 0 || this.sessionIds.length === 0) { return; }
    try {
      this.timerId = this.scheduler.schedule((): void => {
        this.timerId = -1;
        this.sampleNow();
        this.scheduleNext();
      }, this.safeIntervalMs());
    } catch (_err) {
      this.timerId = -1;
    }
  }

  private cancelTimer(): void {
    if (this.timerId < 0) { return; }
    try { this.scheduler.cancel(this.timerId); } catch (_err) {}
    this.timerId = -1;
  }

  private safeIntervalMs(): number {
    try {
      const value: number = this.intervalProvider();
      return Number.isSafeInteger(value) && value > 0 ? value :
        DIAGNOSTIC_RUNTIME_SNAPSHOT_INTERVAL_MS;
    } catch (_err) {
      return DIAGNOSTIC_RUNTIME_SNAPSHOT_INTERVAL_MS;
    }
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

function safeSignedInteger(value: number | undefined): number {
  if (value === undefined || !Number.isFinite(value) || !Number.isSafeInteger(value)) {
    return 0;
  }
  return Math.max(-2147483648, Math.min(2147483647, value));
}

function safeTransformMatrix(value: number[] | undefined,
  sampled: boolean): number[] {
  if (!sampled || value === undefined || value.length !== 16) { return []; }
  const result: number[] = [];
  for (let index: number = 0; index < value.length; index++) {
    if (!Number.isFinite(value[index]) || Math.abs(value[index]) > 16) { return []; }
    result.push(Math.round(value[index] * 1000000) / 1000000);
  }
  return result;
}

function protocolFactsFromDesktop(source: RustDeskDiagnosticsSnapshot): DiagnosticProtocolFacts {
  const facts: DiagnosticProtocolFacts = emptyDiagnosticProtocolFacts();
  facts.supported = source.supported === true;
  facts.sessionActive = source.sessionActive === true;
  facts.snapshotAvailable = source.protocolSnapshotAvailable === true;
  facts.videoSeen = source.videoSeen === true;
  facts.inputPermissionKnown = source.remoteInputPermissionKnown === true;
  facts.inputAllowed = source.remoteInputAllowed === true;
  facts.clipboardPermissionKnown = source.remoteClipboardPermissionKnown === true;
  facts.clipboardAllowed = source.remoteClipboardAllowed === true;
  facts.filePermissionKnown = source.remoteFilePermissionKnown === true;
  facts.fileAllowed = source.remoteFileAllowed === true;
  facts.targetBitrateKbps = safeCounter(source.targetBitrateKbps);
  facts.requestedQuality = safeCounter(source.requestedImageQuality);
  facts.effectiveQuality = safeCounter(source.effectiveImageQuality);
  facts.sentQuality = safeCounter(source.sentImageQuality);
  facts.qualityProfile = safeCounter(source.qualityProfile);
  facts.qualityFps = safeCounter(source.qualityFps);
  facts.qualityRequestedGeneration = safeCounter(source.qualityRequestedGeneration);
  facts.qualityAppliedGeneration = safeCounter(source.qualityAppliedGeneration);
  facts.qualityUpdateStatus = safeSignedInteger(source.qualityUpdateStatus);
  facts.messages = safeCounter(source.videoMessages);
  facts.receivedFrames = safeCounter(source.receivedFrames);
  facts.keyframes = safeCounter(source.keyframes);
  facts.receivedBytes = safeCounter(source.receivedBytes);
  facts.audioFrames = safeCounter(source.audioFrames);
  facts.cadenceGaps = safeCounter(source.cadenceGaps);
  facts.maxCadenceGapMs = safeCounter(source.maxCadenceGapMs);
  facts.testDelayCount = safeCounter(source.testDelayCount);
  facts.receivedFps = safeCounter(source.receivedFps);
  facts.displayFps = safeCounter(source.displayFps);
  facts.decodeFps = safeCounter(source.decodeFps);
  facts.bitrateKbps = safeCounter(source.bitrateKbps);
  facts.lastFrameAgeMs = safeCounter(source.lastFrameAgeMs);
  facts.lastPresentedFrameAgeMs = safeCounter(source.lastPresentedFrameAgeMs);
  facts.decodeOk = safeCounter(source.decodeOk);
  facts.decodeErrors = safeCounter(source.decodeErrors);
  facts.decodeP50Us = safeCounter(source.decodeP50Us);
  facts.decodeP95Us = safeCounter(source.decodeP95Us);
  facts.decodeMaxUs = safeCounter(source.decodeMaxUs);
  facts.presentedFrames = safeCounter(source.presentedFrames);
  facts.presentationRejected = safeCounter(source.presentationRejected);
  facts.lastDirtyX = safeCounter(source.lastDirtyX);
  facts.lastDirtyY = safeCounter(source.lastDirtyY);
  facts.lastDirtyWidth = safeCounter(source.lastDirtyWidth);
  facts.lastDirtyHeight = safeCounter(source.lastDirtyHeight);
  facts.requestedColorDepthCode = source.requestedColorDepth === 'rgb555' ? 1 :
    (source.requestedColorDepth === 'rgb565' ? 2 :
      (source.requestedColorDepth === 'rgb888' ? 3 : 0));
  facts.effectiveColorDepth = safeCounter(source.effectiveColorDepth);
  facts.inputEventsSent = safeCounter(source.inputEventsSent);
  facts.inputEventsDropped = safeCounter(source.inputEventsDropped);
  facts.presentationWindowSamples = safeCounter(source.presentationWindowSamples);
  facts.presentationWindowMs = safeCounter(source.presentationWindowMs);
  facts.renderP50Us = safeCounter(source.renderP50Us);
  facts.renderP95Us = safeCounter(source.renderP95Us);
  facts.renderMaxUs = safeCounter(source.renderMaxUs);
  facts.queueMax = safeCounter(source.queueMax);
  facts.droppedFrames = safeCounter(source.droppedFrames);
  return facts;
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
  if (value === 'top_left_producer') { return 'top_left_producer'; }
  if (value === 'identity') { return 'identity'; }
  if (value === 'producer') { return 'producer'; }
  if (value === 'validated_producer') { return 'validated_producer'; }
  if (value === 'vertical_flip_producer') { return 'vertical_flip_producer'; }
  return 'unknown';
}

function producerTransform(value: string | undefined): DiagnosticProducerTransform {
  switch (value) {
    case 'not_sampled': return 'not_sampled';
    case 'identity': return 'identity';
    case 'flip_x': return 'flip_x';
    case 'flip_y': return 'flip_y';
    case 'rotate_90': return 'rotate_90';
    case 'rotate_180': return 'rotate_180';
    case 'rotate_270': return 'rotate_270';
    case 'transpose': return 'transpose';
    case 'transverse': return 'transverse';
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
  source: RustDeskDiagnosticsSnapshot, currentPreference: number = -1): DiagnosticRuntimeFacts {
  const sampled: boolean = source.producerTransformSampled === true;
  const video = videoDiagnosticEvidence(source);
  video.currentCodecPreference = currentPreference;
  video.finalSamplingCorners = source.rendererTransformValid === true ? finalVideoSamplingCorners(
    safeTransformMatrix(source.appliedTextureTransform, sampled),
    source.rendererRotationQuarterTurns ?? 0, source.rendererFlipX === true, source.rendererFlipY === true) : [];
  return {
    video: moduleId === 'connection.rustdesk' ? video : undefined,
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
    appliedTransform: moduleId === 'connection.rustdesk' ?
      producerTransform(source.appliedTransform) : 'unknown',
    desktopSurfaceCompatibility: source.desktopSurfaceCompatibility === true,
    producerTransformSampled: sampled,
    producerTransformReadResult: safeSignedInteger(source.producerTransformReadResult),
    producerTransformSamples: safeCounter(source.producerTransformSamples),
    producerTransformChanges: safeCounter(source.producerTransformChanges),
    producerTransformReadFailures: safeCounter(source.producerTransformReadFailures),
    producerTransformClassMask: safeCounter(source.producerTransformClassMask),
    producerTransformMatrix: safeTransformMatrix(source.producerTransformMatrix, sampled),
    appliedTextureTransform: safeTransformMatrix(source.appliedTextureTransform, sampled),
    rendererTransformValid: source.rendererTransformValid === true,
    rendererTransformVersion: safeCounter(source.rendererTransformVersion),
    rendererRotationQuarterTurns: Math.min(3,
      safeCounter(source.rendererRotationQuarterTurns)),
    rendererFlipX: source.rendererFlipX === true,
    rendererFlipY: source.rendererFlipY === true,
    decoderGeneration: safeCounter(source.decoderGeneration),
    rendererGeneration: safeCounter(source.rendererGeneration),
    width: safeCounter(source.width),
    height: safeCounter(source.height),
    frames: safeCounter(source.receivedFrames),
    dropped: safeSum([
      source.droppedFrames, source.presentationRejected, source.inputEventsDropped
    ]),
    errors: safeCounter(source.decodeErrors),
    queueDepth: safeCounter(source.queueDepth),
    latencyMs: safeCounter(source.latencyMs),
    protocol: protocolFactsFromDesktop(source),
    resources: {
      supported: false, cpuAvailable: false, cpuPercent: 0,
      memoryAvailable: false, memoryBytes: 0, gpuAvailable: false,
      gpuPercent: 0, sampledAtMs: 0
    }
  };
}

export function diagnosticSshRuntimeFacts(
  source: SshTerminalDiagnosticsSnapshot): DiagnosticRuntimeFacts {
  const protocol: DiagnosticProtocolFacts = emptyDiagnosticProtocolFacts();
  protocol.supported = source.supported === true;
  protocol.sessionActive = source.sessionActive === true;
  protocol.snapshotAvailable = source.schemaVersion > 0;
  protocol.inputEventsSent = safeCounter(source.inputEvents);
  protocol.inputBytes = safeCounter(source.inputBytes);
  protocol.messages = safeCounter(source.nativeEnqueueEvents);
  protocol.writeBytes = safeCounter(source.writeBytes);
  protocol.readBytes = safeCounter(source.remoteReadBytes);
  protocol.callbackBytes = safeCounter(source.callbackAcceptedBytes);
  protocol.inputEventsDropped = safeSum([source.inputLoss, source.inputDuplicate,
    source.callbackQueueFull, source.callbackDeliveryErrors]);
  protocol.inputQueueBytes = safeCounter(source.inputQueueBytes);
  protocol.inputQueueMaxBytes = safeCounter(source.inputQueueMaxBytes);
  protocol.inputReorder = safeCounter(source.inputReorder);
  protocol.ownerStallEvents = safeCounter(source.ownerStallEvents);
  protocol.coverageMask = safeCounter(source.coverageMask);
  protocol.coverageComplete = source.coverageComplete === true;
  protocol.lastInputSequence = safeCounter(source.lastInputSequence);
  protocol.maxInputToWriteAttemptNs = safeCounter(source.maxInputToWriteAttemptNs);
  protocol.maxInputToWriteCompleteNs = safeCounter(source.maxInputToWriteCompleteNs);
  return {
    state: source.sessionActive ? 'connected' :
      (source.supported ? 'disconnected' : 'unknown'),
    backend: 'terminal', codec: 'unknown', path: 'unknown',
    peerPlatform: 'unknown', presentation: 'unknown', producerTransform: 'unknown',
    appliedTransform: 'unknown', desktopSurfaceCompatibility: false,
    producerTransformSampled: false, producerTransformReadResult: 0,
    producerTransformSamples: 0, producerTransformChanges: 0,
    producerTransformReadFailures: 0, producerTransformClassMask: 0,
    producerTransformMatrix: [], appliedTextureTransform: [],
    rendererTransformValid: false, rendererTransformVersion: 0,
    rendererRotationQuarterTurns: 0, rendererFlipX: false, rendererFlipY: false,
    decoderGeneration: 0, rendererGeneration: 0,
    width: 0, height: 0,
    frames: safeCounter(source.remoteReadEvents),
    dropped: safeSum([source.inputLoss, source.inputDuplicate, source.callbackQueueFull]),
    errors: safeSum([source.callbackDeliveryErrors, source.callbackClosed]),
    queueDepth: safeCounter(source.inputQueueDepth),
    latencyMs: safeCounter(source.maxInputToWriteCompleteNs / 1000000),
    protocol: protocol,
    resources: {
      supported: false, cpuAvailable: false, cpuPercent: 0,
      memoryAvailable: false, memoryBytes: 0, gpuAvailable: false,
      gpuPercent: 0, sampledAtMs: 0
    }
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
  const protocol: DiagnosticProtocolFacts = emptyDiagnosticProtocolFacts();
  protocol.supported = source.matched === true;
  protocol.sessionActive = source.terminal !== true;
  protocol.snapshotAvailable = true;
  protocol.videoSeen = source.firstFrameReady === true;
  protocol.receivedFrames = safeCounter(source.acceptedVideoFrames);
  protocol.receivedBytes = safeCounter(source.acceptedVideoBytes);
  protocol.presentedFrames = safeCounter(source.rendererPresentedFrames);
  protocol.audioFrames = safeCounter(source.acceptedAudioPackets);
  protocol.inputEventsDropped = safeCounter(source.rejectedInputEvents);
  protocol.targetBitrateKbps = safeCounter(source.configuredBitrateKbps);
  protocol.qualityFps = safeCounter(source.targetFps);
  protocol.inputEventsSent = source.inputReady === true ? 1 : 0;
  const sampled: boolean = source.producerTransformSampled === true;
  const video = videoDiagnosticEvidence(source);
  video.decodedFrames = -1;
  video.presentedFrames = safeCounter(source.rendererPresentedFrames);
  // Moonlight's codec field is the launch configuration, not an observed frame type.
  video.firstFrameCodec = -1;
  video.finalSamplingCorners = source.rendererTransformValid === true ? finalVideoSamplingCorners(
    safeTransformMatrix(source.appliedTextureTransform, sampled),
    source.rendererRotationQuarterTurns ?? 0, source.rendererFlipX === true, source.rendererFlipY === true) : [];
  return {
    video: video,
    state: source.terminal ? 'disconnected' :
      (source.transportReady ? 'connected' : 'connecting'),
    backend: source.videoReady ? 'hardware' : 'native',
    codec: moonlightCodec(source.codec), path: 'unknown',
    peerPlatform: 'unknown', presentation: presentation(source.nativeImagePresentation),
    producerTransform: producerTransform(source.producerTransform),
    appliedTransform: producerTransform(source.appliedTransform),
    desktopSurfaceCompatibility: source.desktopSurfaceCompatibility === true,
    producerTransformSampled: sampled,
    producerTransformReadResult: safeSignedInteger(source.producerTransformReadResult),
    producerTransformSamples: safeCounter(source.producerTransformSamples),
    producerTransformChanges: safeCounter(source.producerTransformChanges),
    producerTransformReadFailures: safeCounter(source.producerTransformReadFailures),
    producerTransformClassMask: safeCounter(source.producerTransformClassMask),
    producerTransformMatrix: safeTransformMatrix(source.producerTransformMatrix, sampled),
    appliedTextureTransform: safeTransformMatrix(source.appliedTextureTransform, sampled),
    rendererTransformValid: source.rendererTransformValid === true,
    rendererTransformVersion: safeCounter(source.rendererTransformVersion),
    rendererRotationQuarterTurns: Math.min(3,
      safeCounter(source.rendererRotationQuarterTurns)),
    rendererFlipX: source.rendererFlipX === true,
    rendererFlipY: source.rendererFlipY === true,
    decoderGeneration: safeCounter(source.decoderGeneration),
    rendererGeneration: safeCounter(source.rendererGeneration),
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
    latencyMs: safeCounter(source.decoderCodecLatencyMs),
    protocol: protocol,
    resources: {
      supported: false, cpuAvailable: false, cpuPercent: 0,
      memoryAvailable: false, memoryBytes: 0, gpuAvailable: false,
      gpuPercent: 0, sampledAtMs: 0
    }
  };
}

export function diagnosticRuntimeFactsSignature(facts: DiagnosticRuntimeFacts): string {
  return [
    facts.state, facts.backend, facts.codec, facts.path, facts.peerPlatform,
    facts.presentation, facts.producerTransform, facts.appliedTransform,
    facts.desktopSurfaceCompatibility, facts.producerTransformSampled,
    facts.producerTransformReadResult, facts.producerTransformChanges,
    facts.producerTransformReadFailures, facts.producerTransformClassMask,
    facts.producerTransformMatrix.join(','), facts.appliedTextureTransform.join(','),
    facts.rendererTransformVersion, facts.rendererRotationQuarterTurns,
    facts.rendererFlipX, facts.rendererFlipY, facts.decoderGeneration,
    facts.rendererGeneration, facts.width, facts.height,
    facts.frames, facts.dropped, facts.errors, facts.queueDepth, facts.latencyMs,
    JSON.stringify(facts.protocol), JSON.stringify(facts.resources),
    facts.video?.sentCodecPreference, facts.video?.codecOptionSendFailures,
    facts.video?.firstFrameCodec, facts.video?.codecChanges,
    JSON.stringify(facts.video?.decoderAttempts),
    facts.rdpGraphics?.evidenceLevel, facts.rdpGraphics?.presentation,
    facts.rdpGraphics?.capsConfirmedVersion, facts.rdpGraphics?.wireCodec,
    facts.rdpGraphics?.h264Status, facts.rdpGraphics?.fallbackReason
  ].join('|');
}

export class DiagnosticRuntimeSnapshotGate {
  private readonly observations: Map<string, DiagnosticRuntimeObservation> =
    new Map<string, DiagnosticRuntimeObservation>();

  shouldRecord(moduleId: DiagnosticModuleId, sessionId: number, captureId: string,
    facts: DiagnosticRuntimeFacts, nowMs: number,
    intervalMs: number = DIAGNOSTIC_RUNTIME_SNAPSHOT_INTERVAL_MS): boolean {
    const key: string = moduleId + ':' + sessionId.toString();
    if (captureId.length === 0 || sessionId <= 0 || !Number.isFinite(nowMs) || nowMs < 0) {
      this.observations.delete(key);
      return false;
    }
    const signature: string = diagnosticRuntimeFactsSignature(facts);
    const previous: DiagnosticRuntimeObservation | undefined = this.observations.get(key);
    const safeInterval: number = Number.isSafeInteger(intervalMs) && intervalMs > 0 ?
      intervalMs : DIAGNOSTIC_RUNTIME_SNAPSHOT_INTERVAL_MS;
    const due: boolean = previous === undefined || previous.captureId !== captureId ||
      previous.signature !== signature || nowMs < previous.recordedAtMs ||
      nowMs - previous.recordedAtMs >= safeInterval;
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
