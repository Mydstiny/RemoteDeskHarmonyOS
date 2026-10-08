import { describe, expect, it } from '@ohos/hypium';
import { DiagnosticCaptureEvent, FrozenDiagnosticCapture } from '../main/ets/services/DiagnosticCaptureRuntime';
import {
  DiagnosticModuleId,
  DiagnosticOutcome,
  emptyDiagnosticNetworkFacts,
  emptyDiagnosticRuntimeFacts,
  emptyDiagnosticWindowFacts
} from '../main/ets/services/DiagnosticCapturePolicy';
import {
  DiagnosticEvidenceCoverage,
  diagnosticEvidenceCoverage,
  diagnosticMissingEvidenceDescription
} from '../main/ets/services/DiagnosticEvidenceCoveragePolicy';
import {
  DIAGNOSTIC_AI_BUNDLE_VERSION,
  DiagnosticAiBundle,
  diagnosticAiBundleFromCapture
} from '../main/ets/services/diagnosticAi/DiagnosticAiBundlePolicy';
import {
  DiagnosticRdpGraphicsFacts,
  emptyDiagnosticRdpGraphicsFacts,
  rdpH264Status
} from '../main/ets/services/RdpGraphicsEvidencePolicy';

function event(sequence: number, moduleId: DiagnosticModuleId, eventCode: string,
  outcome: DiagnosticOutcome, code: number = 0): DiagnosticCaptureEvent {
  return {
    sequence: sequence, elapsedMs: sequence, wallTimeMs: 1000 + sequence, moduleId: moduleId,
    eventCode: eventCode, level: 'info', outcome: outcome, sessionRef: '', generation: 0,
    code: code, durationMs: 0, count: 0, bytes: 0, runtime: emptyDiagnosticRuntimeFacts(),
    network: emptyDiagnosticNetworkFacts(), window: emptyDiagnosticWindowFacts()
  };
}

function capture(modules: DiagnosticModuleId[], events: DiagnosticCaptureEvent[],
  dropped: number = 0): FrozenDiagnosticCapture {
  const all: DiagnosticCaptureEvent[] = [event(1, 'core.app', 'capture_started', 'started')];
  events.forEach((item: DiagnosticCaptureEvent): void => { all.push(item); });
  all.push(event(99, 'core.app', 'capture_stopped', 'succeeded'));
  return {
    captureId: 'capture-1', durationMinutes: 10, profile: 'selected', fullLog: false,
    selectedModules: modules, startedWallTimeMs: 1000, endedWallTimeMs: 2000, stopReason: 'manual',
    events: all, droppedEventCount: dropped, approximateBytes: 1
  };
}

function graphicsEvent(sequence: number, mutate: (facts: DiagnosticRdpGraphicsFacts) => void):
  DiagnosticCaptureEvent {
  const result: DiagnosticCaptureEvent = event(sequence, 'connection.rdp', 'rdp_runtime_snapshot', 'state');
  const graphics: DiagnosticRdpGraphicsFacts = emptyDiagnosticRdpGraphicsFacts();
  mutate(graphics);
  graphics.h264Status = rdpH264Status(graphics);
  result.runtime.rdpGraphics = graphics;
  return result;
}

export default function diagnosticEvidenceCoveragePolicyTest(): void {
  describe('DiagnosticEvidenceCoveragePolicy', () => {
    it('reports a selected protocol without events instead of treating silence as healthy', 0, () => {
      const coverage: DiagnosticEvidenceCoverage = diagnosticEvidenceCoverage(
        capture(['core.app', 'connection.rustdesk'], []));
      expect(coverage.moduleCoverage['connection.rustdesk']).assertEqual('no_events');
      expect(coverage.missingEvidence.join(',')).assertEqual('rustdesk_activity_unobserved');
      expect(coverage.coverageComplete).assertFalse();
      expect(diagnosticMissingEvidenceDescription('rustdesk_activity_unobserved').length > 0).assertTrue();
    });

    it('flags requested GFX without confirmation and a connected channel without frames', 0, () => {
      const coverage: DiagnosticEvidenceCoverage = diagnosticEvidenceCoverage(capture(
        ['core.app', 'connection.rdp'], [graphicsEvent(2, (facts: DiagnosticRdpGraphicsFacts): void => {
          facts.evidenceLevel = 'configured';
          facts.requestedMode = 'gfx';
          facts.gfxChannelConnected = true;
          facts.presentation = 'gfx_gdi_consumer';
        })]));
      expect(coverage.missingEvidence.join(','))
        .assertEqual('rdp_gfx_caps_unconfirmed,rdp_wire_codec_unobserved');
    });

    it('is complete when RDP negotiation and wire codec are observed', 0, () => {
      const coverage: DiagnosticEvidenceCoverage = diagnosticEvidenceCoverage(capture(
        ['core.app', 'connection.rdp'], [graphicsEvent(2, (facts: DiagnosticRdpGraphicsFacts): void => {
          facts.evidenceLevel = 'observed_native';
          facts.requestedMode = 'gfx';
          facts.gfxChannelConnected = true;
          facts.presentation = 'gfx_gdi_consumer';
          facts.capsConfirmed = true;
          facts.capsConfirmedVersion = '10.7';
          facts.surfaceCommands = 10;
          facts.wireCodec = 'remotefx';
        })]));
      expect(coverage.missingEvidence.length).assertEqual(0);
      expect(coverage.coverageComplete).assertTrue();
    });

    it('marks snapshots from a native build without graphics evidence', 0, () => {
      const coverage: DiagnosticEvidenceCoverage = diagnosticEvidenceCoverage(capture(
        ['core.app', 'connection.rdp'], [event(2, 'connection.rdp', 'rdp_runtime_snapshot', 'state')], 3));
      expect(coverage.missingEvidence.join(','))
        .assertEqual('capture_events_dropped,rdp_graphics_native_missing');
    });

    it('tracks unresolved RustDesk quality requests and direct attempts', 0, () => {
      const open: DiagnosticEvidenceCoverage = diagnosticEvidenceCoverage(capture(
        ['core.app', 'connection.rustdesk'], [
          event(2, 'connection.rustdesk', 'rustdesk_direct_stage', 'failed', 1),
          event(3, 'connection.rustdesk', 'rustdesk_direct_stage', 'started', 0),
          event(4, 'connection.rustdesk', 'rustdesk_quality_request', 'started', 1)
        ]));
      expect(open.missingEvidence.join(','))
        .assertEqual('rustdesk_quality_unconfirmed,rustdesk_direct_stage_unresolved');
      const closed: DiagnosticEvidenceCoverage = diagnosticEvidenceCoverage(capture(
        ['core.app', 'connection.rustdesk'], [
          event(2, 'connection.rustdesk', 'rustdesk_direct_stage', 'started', 0),
          event(3, 'connection.rustdesk', 'rustdesk_direct_stage', 'failed', 4),
          event(4, 'connection.rustdesk', 'rustdesk_quality_request', 'started', 1),
          event(5, 'connection.rustdesk', 'rustdesk_quality_result', 'state', 4)
        ]));
      expect(closed.missingEvidence.length).assertEqual(0);
      expect(closed.coverageComplete).assertTrue();
      // A user-cancelled attempt and a superseded quality request are closed, not gaps.
      const cancelled: DiagnosticEvidenceCoverage = diagnosticEvidenceCoverage(capture(
        ['core.app', 'connection.rustdesk'], [
          event(2, 'connection.rustdesk', 'rustdesk_direct_stage', 'started', 0),
          event(3, 'connection.rustdesk', 'rustdesk_direct_stage', 'cancelled', 12),
          event(4, 'connection.rustdesk', 'rustdesk_quality_request', 'started', 1),
          event(5, 'connection.rustdesk', 'rustdesk_quality_result', 'cancelled', 6)
        ]));
      expect(cancelled.missingEvidence.length).assertEqual(0);
      // An entry-path validation failure never closes another open attempt.
      const stillOpen: DiagnosticEvidenceCoverage = diagnosticEvidenceCoverage(capture(
        ['core.app', 'connection.rustdesk'], [
          event(2, 'connection.rustdesk', 'rustdesk_direct_stage', 'started', 0),
          event(3, 'connection.rustdesk', 'rustdesk_direct_stage', 'failed', 1)
        ]));
      expect(stillOpen.missingEvidence.join(',')).assertEqual('rustdesk_direct_stage_unresolved');
    });

    it('gives the AI bundle stable event refs, coverage gaps and the evidence rules', 0, () => {
      const source: FrozenDiagnosticCapture = capture(['core.app', 'connection.rdp'],
        [graphicsEvent(2, (facts: DiagnosticRdpGraphicsFacts): void => {
          facts.evidenceLevel = 'configured';
          facts.requestedMode = 'gfx';
        })]);
      source.events[1].sessionRef = 'session-3';
      source.events[1].generation = 4;
      const bundle: DiagnosticAiBundle | null = diagnosticAiBundleFromCapture(source);
      expect(bundle !== null).assertTrue();
      const value: DiagnosticAiBundle = bundle as DiagnosticAiBundle;
      const parsed: Record<string, Object> = JSON.parse(value.text) as Record<string, Object>;
      expect(parsed['bundleVersion'] as number).assertEqual(DIAGNOSTIC_AI_BUNDLE_VERSION);
      const events: Record<string, Object>[] = parsed['events'] as Record<string, Object>[];
      expect(events[1]['ref'] as string).assertEqual('capture-1/session-3/g4/seq-2');
      expect(events[0]['ref'] as string).assertEqual('capture-1/app/g0/seq-1');
      expect((value.missingEvidence as string[]).join(',')).assertEqual('rdp_gfx_caps_unconfirmed');
      const coverage: Record<string, Object> = parsed['evidenceCoverage'] as Record<string, Object>;
      expect(coverage['coverageComplete'] as boolean).assertFalse();
      const summary: Record<string, Object> = parsed['factSummary'] as Record<string, Object>;
      expect(summary['rdpGraphicsRef'] as string).assertEqual('capture-1/session-3/g4/seq-2');
      expect((parsed['evidenceRules'] as string).indexOf('未确认') >= 0).assertTrue();
    });

    it('keeps the newest quality verdicts in the AI fact summary', 0, () => {
      const events: DiagnosticCaptureEvent[] = [];
      for (let index: number = 0; index < 10; index++) {
        const result: DiagnosticCaptureEvent =
          event(index + 2, 'connection.rustdesk', 'rustdesk_quality_result', 'cancelled', 6);
        result.generation = index % 3;
        events.push(result);
      }
      events[9].code = 2;
      const bundle: DiagnosticAiBundle | null =
        diagnosticAiBundleFromCapture(capture(['core.app', 'connection.rustdesk'], events));
      const parsed: Record<string, Object> =
        JSON.parse((bundle as DiagnosticAiBundle).text) as Record<string, Object>;
      const summary: Record<string, Object> = parsed['factSummary'] as Record<string, Object>;
      const quality: Record<string, Object>[] = summary['rustDeskQuality'] as Record<string, Object>[];
      expect(quality.length).assertEqual(8);
      expect(quality[7]['resultCode'] as number).assertEqual(2);
      expect(quality[7]['ref'] as string).assertEqual('capture-1/app/g0/seq-11');
    });
  });
}
