import { describe, expect, it } from '@ohos/hypium';
import {
  DIAGNOSTIC_DEFAULT_DURATION_MINUTES,
  DIAGNOSTIC_CAPTURE_SCHEMA_VERSION,
  DIAGNOSTIC_REDACTION_POLICY_VERSION,
  DiagnosticModuleId,
  DiagnosticRuntimeFacts,
  diagnosticAllModules,
  diagnosticDurationIsAllowed,
  diagnosticDurationOptions,
  diagnosticEventIsAllowed,
  diagnosticLevelForOutcome,
  diagnosticModuleIsKnown,
  diagnosticModuleSpecs,
  diagnosticOutcomeIsAllowed,
  diagnosticRuntimeFactsAreValid,
  normalizeDiagnosticModules
} from '../main/ets/services/DiagnosticCapturePolicy';

export default function diagnosticCapturePolicyTest(): void {
  describe('DiagnosticCapturePolicy', (): void => {
    it('accepts_only_the_six_fixed_one_to_thirty_minute_options', 0, (): void => {
      expect(diagnosticDurationOptions().join(',')).assertEqual('1,3,5,10,15,30');
      expect(DIAGNOSTIC_DEFAULT_DURATION_MINUTES).assertEqual(10);
      expect(DIAGNOSTIC_CAPTURE_SCHEMA_VERSION).assertEqual(2);
      expect(DIAGNOSTIC_REDACTION_POLICY_VERSION).assertEqual(2);
      expect(diagnosticDurationIsAllowed(1)).assertTrue();
      expect(diagnosticDurationIsAllowed(30)).assertTrue();
      expect(diagnosticDurationIsAllowed(0)).assertFalse();
      expect(diagnosticDurationIsAllowed(2)).assertFalse();
      expect(diagnosticDurationIsAllowed(31)).assertFalse();
      expect(diagnosticDurationIsAllowed(Number.NaN)).assertFalse();
    });

    it('normalizes_modules_in_catalog_order_and_always_keeps_core', 0, (): void => {
      const selected: DiagnosticModuleId[] = normalizeDiagnosticModules([
        'connection.vnc', 'connection.rdp', 'connection.vnc', 'unknown'
      ]);
      expect(selected.length).assertEqual(3);
      expect(selected[0]).assertEqual('core.app');
      expect(selected[1]).assertEqual('connection.rdp');
      expect(selected[2]).assertEqual('connection.vnc');
      expect(diagnosticAllModules().length).assertEqual(10);
      expect(diagnosticModuleSpecs()[0].alwaysEnabled).assertTrue();
      expect(diagnosticModuleIsKnown('security.ssh_key')).assertTrue();
      expect(diagnosticModuleIsKnown('security.totp')).assertFalse();
    });

    it('rejects_unknown_or_cross_module_event_codes', 0, (): void => {
      expect(diagnosticEventIsAllowed('connection.rdp', 'rdp_state_changed')).assertTrue();
      expect(diagnosticEventIsAllowed('connection.rdp', 'rdp_runtime_snapshot')).assertTrue();
      expect(diagnosticEventIsAllowed('connection.rustdesk', 'rustdesk_runtime_snapshot')).assertTrue();
      expect(diagnosticEventIsAllowed('connection.ssh_sftp', 'ssh_runtime_snapshot')).assertTrue();
      expect(diagnosticEventIsAllowed('connection.vnc', 'vnc_runtime_snapshot')).assertTrue();
      expect(diagnosticEventIsAllowed('connection.moonlight', 'moonlight_runtime_snapshot')).assertTrue();
      expect(diagnosticEventIsAllowed('connection.vnc', 'rdp_state_changed')).assertFalse();
      expect(diagnosticEventIsAllowed('connection.rdp', 'raw_error_message')).assertFalse();
      expect(diagnosticEventIsAllowed('security.ssh_key', 'ssh_key_import')).assertTrue();
    });

    it('accepts_only_closed_runtime_facts_and_non_negative_counters', 0, (): void => {
      const facts: DiagnosticRuntimeFacts = {
        state: 'connected', backend: 'hardware', codec: 'h264', path: 'direct',
        peerPlatform: 'windows', presentation: 'identity',
        producerTransform: 'rotate_180', width: 1920, height: 1080,
        frames: 10, dropped: 1, errors: 0, queueDepth: 2, latencyMs: 31
      };
      expect(diagnosticRuntimeFactsAreValid(facts)).assertTrue();
      facts.width = -1;
      expect(diagnosticRuntimeFactsAreValid(facts)).assertFalse();
      facts.width = 1920;
      facts.backend = 'endpoint.example.invalid' as 'hardware';
      expect(diagnosticRuntimeFactsAreValid(facts)).assertFalse();
    });

    it('uses_a_closed_outcome_set_and_derives_levels_without_free_text', 0, (): void => {
      expect(diagnosticOutcomeIsAllowed('succeeded')).assertTrue();
      expect(diagnosticOutcomeIsAllowed('native said password=secret')).assertFalse();
      expect(diagnosticLevelForOutcome('succeeded')).assertEqual('info');
      expect(diagnosticLevelForOutcome('retry')).assertEqual('warn');
      expect(diagnosticLevelForOutcome('failed')).assertEqual('error');
    });
  });
}
