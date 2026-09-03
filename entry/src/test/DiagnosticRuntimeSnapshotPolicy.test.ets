import { describe, expect, it } from '@ohos/hypium';
import {
  RustDeskDiagnosticsSnapshot,
  SshTerminalDiagnosticsSnapshot
} from '../main/ets/types/rdpnapi';
import { MoonlightNativeStreamSnapshot } from '../main/ets/services/MoonlightHostService';
import {
  DIAGNOSTIC_RUNTIME_SNAPSHOT_INTERVAL_MS,
  DiagnosticRuntimeSamplingLoop,
  DiagnosticRuntimeSamplingScheduler,
  DiagnosticRuntimeSnapshotGate,
  diagnosticDesktopRuntimeFacts,
  diagnosticMoonlightRuntimeFacts,
  diagnosticSshRuntimeFacts
} from '../main/ets/services/DiagnosticRuntimeSnapshotPolicy';

class FakeRuntimeSamplingScheduler implements DiagnosticRuntimeSamplingScheduler {
  nextId: number = 1;
  delays: number[] = [];
  callbacks: Map<number, () => void> = new Map<number, () => void>();
  cancelled: number[] = [];

  schedule(callback: () => void, delayMs: number): number {
    const timerId: number = this.nextId++;
    this.delays.push(delayMs);
    this.callbacks.set(timerId, callback);
    return timerId;
  }

  cancel(timerId: number): void {
    this.cancelled.push(timerId);
    this.callbacks.delete(timerId);
  }

  fire(timerId: number): void {
    const callback: (() => void) | undefined = this.callbacks.get(timerId);
    this.callbacks.delete(timerId);
    if (callback !== undefined) { callback(); }
  }
}

function desktopSnapshot(): RustDeskDiagnosticsSnapshot {
  return {
    supported: true, sessionActive: true, protocolSnapshotAvailable: true,
    videoSeen: true, receivedRateAvailable: true, presentedRateAvailable: true,
    decodeRateAvailable: true,
    remoteInputPermissionKnown: true, remoteInputAllowed: true,
    remoteClipboardPermissionKnown: true, remoteClipboardAllowed: true,
    remoteFilePermissionKnown: true, remoteFileAllowed: true,
    sessionId: 7, latencyMs: 22, targetBitrateKbps: 8000,
    requestedImageQuality: 2, effectiveImageQuality: 2, sentImageQuality: 2,
    qualityProfile: 1, qualityFps: 60,
    qualityRequestedGeneration: 1, qualityAppliedGeneration: 1, qualityUpdateStatus: 2,
    videoMessages: 120, receivedFrames: 118, keyframes: 3, receivedBytes: 65536,
    audioFrames: 30, cadenceGaps: 0, maxCadenceGapMs: 0, testDelayCount: 1,
    receivedFps: 30, displayFps: 30, decodeFps: 30, bitrateKbps: 7000,
    codec: 0, width: 1920, height: 1080, connectionPath: 'relay',
    peerPlatform: 'windows', desktopSurfaceCompatibility: true,
    nativeImagePresentation: 'validated_producer', producerTransform: 'rotate_180',
    appliedTransform: 'identity', producerTransformSampled: true,
    producerTransformReadResult: 0, producerTransformSamples: 118,
    producerTransformChanges: 2, producerTransformReadFailures: 0,
    producerTransformClassMask: 18,
    producerTransformMatrix: [-1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, 1, 0, 1],
    appliedTextureTransform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
    rendererTransformValid: true, rendererTransformVersion: 4,
    rendererRotationQuarterTurns: 0, rendererFlipX: false, rendererFlipY: true,
    decoderGeneration: 11, rendererGeneration: 12,
    lastFrameAtMs: 1000, lastFrameAgeMs: 10,
    lastPresentedAtMs: 1000, lastPresentedFrameAgeMs: 10,
    decodeOk: 118, decodeErrors: 2, decodeP50Us: 1000, decodeP95Us: 2000,
    decodeMaxUs: 3000, presentedFrames: 116, presentationRejected: 1,
    lastDirtyX: -1, lastDirtyY: -1, lastDirtyWidth: 0, lastDirtyHeight: 0,
    requestedColorDepth: '', effectiveColorDepth: 0,
    inputEventsSent: 4, inputEventsDropped: 1,
    presentationWindowSamples: 30, presentationWindowMs: 1000,
    renderP50Us: 500, renderP95Us: 900, renderMaxUs: 1200,
    queueDepth: 2, queueMax: 30, droppedFrames: 3, decoderBackend: 'hardware'
  };
}

function sshSnapshot(): SshTerminalDiagnosticsSnapshot {
  return {
    supported: true, sessionActive: true, schemaVersion: 2, sessionId: 8,
    sessionGeneration: 4, channelId: 'pty', inputEvents: 10, inputBytes: 30,
    nativeEnqueueEvents: 10, writeAttempts: 10, writeCompleteEvents: 9,
    writeBytes: 29, writeEagain: 1, remoteReadEvents: 20, remoteReadBytes: 300,
    callbackAcceptedEvents: 20, callbackAcceptedBytes: 300, callbackQueueFull: 1,
    callbackDeliveryErrors: 2, callbackClosed: 0, inputDuplicate: 1,
    inputLoss: 2, inputReorder: 0, ownerStallEvents: 0, coverageMask: 7,
    coverageComplete: true, inputQueueDepth: 3, inputQueueBytes: 10,
    inputQueueMaxDepth: 8, inputQueueMaxBytes: 100, lastInputSequence: 10,
    lastInputCapturedAtNs: 1, lastNativeEnqueueAtNs: 2,
    lastWriteAttemptAtNs: 3, lastWriteCompleteAtNs: 4, lastRemoteReadAtNs: 5,
    maxInputToWriteAttemptNs: 1000000, maxInputToWriteCompleteNs: 3000000
  };
}

function moonlightSnapshot(): MoonlightNativeStreamSnapshot {
  return {
    matched: true, code: 'ok', sessionId: 9, generation: 5, ownerToken: 6,
    transportReady: true, videoReady: true, audioReady: true, inputReady: true,
    controllerReady: true, physicalControllerReady: false, inputMayBeStuck: false,
    firstFrameReady: true, terminal: false, lastSequence: 12,
    acceptedVideoFrames: 100, droppedVideoFrames: 4, acceptedVideoBytes: 9000,
    rejectedAudioPackets: 2, rejectedInputEvents: 1, streamWidth: 2560,
    streamHeight: 1440, codec: 'hevc', decoderQueueDepth: 3,
    decoderCodecLatencyMs: 18, decoderSurfaceUpdateFailures: 1,
    desktopSurfaceCompatibility: true,
    nativeImagePresentation: 'producer', producerTransform: 'flip_y',
    appliedTransform: 'flip_y', producerTransformSampled: true,
    producerTransformReadResult: 0, producerTransformSamples: 100,
    producerTransformChanges: 0, producerTransformReadFailures: 0,
    producerTransformClassMask: 8,
    producerTransformMatrix: [1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 0, 1, 0, 1],
    appliedTextureTransform: [1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 0, 1, 0, 1],
    rendererTransformValid: true, rendererTransformVersion: 6,
    rendererRotationQuarterTurns: 0, rendererFlipX: false, rendererFlipY: true,
    decoderGeneration: 13, rendererGeneration: 14
  };
}

export default function diagnosticRuntimeSnapshotPolicyTest(): void {
  describe('DiagnosticRuntimeSnapshotPolicy', (): void => {
    it('maps_rustdesk_presentation_and_producer_evidence_without_peer_text', 0,
      (): void => {
        const facts = diagnosticDesktopRuntimeFacts(
          'connection.rustdesk', desktopSnapshot());
        expect(facts.backend).assertEqual('hardware');
        expect(facts.codec).assertEqual('h264');
        expect(facts.peerPlatform).assertEqual('windows');
        expect(facts.presentation).assertEqual('validated_producer');
        expect(facts.producerTransform).assertEqual('rotate_180');
        expect(facts.appliedTransform).assertEqual('identity');
        expect(facts.rendererFlipY).assertTrue();
        const rotated = desktopSnapshot();
        rotated.producerTransform = 'rotate_270';
        expect(diagnosticDesktopRuntimeFacts(
          'connection.rustdesk', rotated).producerTransform).assertEqual('rotate_270');
        expect(facts.dropped).assertEqual(5);
      });

    it('maps_vnc_ssh_and_moonlight_to_fixed_categories_and_counters', 0, (): void => {
      const vnc: RustDeskDiagnosticsSnapshot = desktopSnapshot();
      vnc.decoderBackend = 'ZRLE';
      vnc.codec = 5;
      const vncFacts = diagnosticDesktopRuntimeFacts('connection.vnc', vnc);
      expect(vncFacts.backend).assertEqual('zrle');
      expect(vncFacts.codec).assertEqual('raw');
      expect(vncFacts.peerPlatform).assertEqual('unknown');
      const sshFacts = diagnosticSshRuntimeFacts(sshSnapshot());
      expect(sshFacts.backend).assertEqual('terminal');
      expect(sshFacts.frames).assertEqual(20);
      expect(sshFacts.latencyMs).assertEqual(3);
      const moonlightFacts = diagnosticMoonlightRuntimeFacts(moonlightSnapshot());
      expect(moonlightFacts.backend).assertEqual('hardware');
      expect(moonlightFacts.codec).assertEqual('h265');
      expect(moonlightFacts.presentation).assertEqual('producer');
      expect(moonlightFacts.producerTransform).assertEqual('flip_y');
      expect(moonlightFacts.appliedTransform).assertEqual('flip_y');
      expect(moonlightFacts.rendererFlipY).assertTrue();
      expect(moonlightFacts.dropped).assertEqual(7);
    });

    it('records_immediate_path_changes_but_throttles_moving_counters', 0, (): void => {
      const gate: DiagnosticRuntimeSnapshotGate = new DiagnosticRuntimeSnapshotGate();
      const facts = diagnosticDesktopRuntimeFacts(
        'connection.rustdesk', desktopSnapshot());
      expect(gate.shouldRecord('connection.rustdesk', 7, 'capture-1', facts, 1000))
        .assertTrue();
      facts.frames += 1;
      expect(gate.shouldRecord('connection.rustdesk', 7, 'capture-1', facts, 1100))
        .assertFalse();
      facts.width = 1600;
      expect(gate.shouldRecord('connection.rustdesk', 7, 'capture-1', facts, 1200))
        .assertTrue();
      expect(gate.shouldRecord('connection.rustdesk', 7, 'capture-1', facts,
        1200 + DIAGNOSTIC_RUNTIME_SNAPSHOT_INTERVAL_MS)).assertTrue();
      expect(gate.shouldRecord('connection.rustdesk', 7, 'capture-2', facts,
        1300 + DIAGNOSTIC_RUNTIME_SNAPSHOT_INTERVAL_MS)).assertTrue();
      expect(gate.shouldRecord('connection.rustdesk', 7, '', facts, 20000)).assertFalse();
    });

    it('drives_tracked_sessions_every_five_seconds_without_hud_polling', 0,
      (): void => {
        const scheduler: FakeRuntimeSamplingScheduler =
          new FakeRuntimeSamplingScheduler();
        const sampled: number[] = [];
        const loop: DiagnosticRuntimeSamplingLoop = new DiagnosticRuntimeSamplingLoop(
          scheduler, (sessionId: number): void => { sampled.push(sessionId); });
        loop.track(11);
        loop.track(12);
        loop.track(11);
        expect(scheduler.callbacks.size).assertEqual(1);
        expect(scheduler.delays[0]).assertEqual(DIAGNOSTIC_RUNTIME_SNAPSHOT_INTERVAL_MS);
        scheduler.fire(1);
        expect(sampled.join(',')).assertEqual('11,12');
        expect(scheduler.callbacks.size).assertEqual(1);
        expect(scheduler.delays.length).assertEqual(2);
        loop.forget(11);
        scheduler.fire(2);
        expect(sampled.join(',')).assertEqual('11,12,12');
        loop.clear();
        expect(scheduler.callbacks.size).assertEqual(0);
        expect(scheduler.cancelled.indexOf(3) >= 0).assertTrue();
      });
  });
}
