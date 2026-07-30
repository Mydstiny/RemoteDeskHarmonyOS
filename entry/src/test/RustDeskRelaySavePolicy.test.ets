import { describe, it, expect } from '@ohos/hypium';
import { RustDeskRelayConfig } from '../main/ets/model/RustDeskRelayConfig';
import { DataMutationResult } from '../main/ets/services/DataMutationResult';
import {
  RustDeskRelaySaveResult,
  rustDeskRelayIdFingerprint,
  rustDeskRelayReadbackMatches,
  rustDeskRelaySaveRecoveryForCode
} from '../main/ets/services/RustDeskRelaySavePolicy';
import {
  RustDeskRelaySetupCoordinator,
  RustDeskRelaySetupDraft
} from '../main/ets/services/RustDeskRelaySetupCoordinator';

function relay(id: string): RustDeskRelayConfig {
  const value = new RustDeskRelayConfig();
  value.id = id;
  value.userId = 'owner-local';
  value.idServer = 'id.example.invalid';
  value.idServerPort = 21116;
  value.relayServer = 'relay.example.invalid';
  value.relayPort = 21117;
  value.key = 'public-key';
  value.keyMode = 'server_public_key';
  value.updatedAt = 1234;
  return value;
}

export default function rustDeskRelaySavePolicyTest(): void {
  describe('RustDeskRelaySavePolicy', (): void => {
    it('maps_gate_failures_to_specific_recovery_without_losing_the_stage', 0, (): void => {
      const mutation = DataMutationResult.failure(
        'relay-1', 'unlock_required', 'locked', 'waiting_gate');
      const result = RustDeskRelaySaveResult.fromMutation(
        'attempt-1', 'relay-1', mutation);
      expect(result.ok).assertFalse();
      expect(result.stage).assertEqual('waiting_gate');
      expect(result.code).assertEqual('unlock_required');
      expect(result.recovery).assertEqual('unlock');
      expect(result.localCommitted).assertFalse();
    });

    it('marks_post_commit_readback_failure_without_claiming_rollback', 0, (): void => {
      const mutation = DataMutationResult.failure(
        'relay-1', 'readback_mismatch', '', 'verifying', true);
      const result = RustDeskRelaySaveResult.fromMutation(
        'attempt-2', 'relay-1', mutation);
      expect(result.ok).assertFalse();
      expect(result.localCommitted).assertTrue();
      expect(result.recovery).assertEqual('reload');
      expect(result.message.indexOf('校验不一致') >= 0).assertTrue();
    });

    it('compares_secret_bearing_fields_in_memory_without_serializing_them', 0, (): void => {
      const expected = relay('relay-1');
      const actual = RustDeskRelayConfig.fromJSON(expected.toJSON());
      expect(rustDeskRelayReadbackMatches(expected, actual)).assertTrue();
      actual.key = 'different';
      expect(rustDeskRelayReadbackMatches(expected, actual)).assertFalse();
    });

    it('uses_an_irreversible_short_relay_identifier_for_diagnostics', 0, (): void => {
      const fingerprint = rustDeskRelayIdFingerprint('relay-private-id');
      expect(fingerprint.length).assertEqual(12);
      expect(fingerprint.indexOf('relay-private-id')).assertEqual(-1);
      expect(rustDeskRelayIdFingerprint('relay-private-id')).assertEqual(fingerprint);
    });

    it('keeps_restore_and_owner_recovery_distinct', 0, (): void => {
      expect(rustDeskRelaySaveRecoveryForCode('restore_in_progress'))
        .assertEqual('wait_for_restore');
      expect(rustDeskRelaySaveRecoveryForCode('invalid_data'))
        .assertEqual('review_account');
    });

    it('uses_one_setup_validator_for_every_entry_point', 0, (): void => {
      const draft = new RustDeskRelaySetupDraft();
      draft.relayId = 'relay-validation';
      draft.idServer = '';
      const result = RustDeskRelaySetupCoordinator.getInstance().save(
        draft, null, 'attempt-validation');
      expect(result.ok).assertFalse();
      expect(result.stage).assertEqual('validating');
      expect(result.recovery).assertEqual('review_fields');
      expect(result.message).assertEqual('ID 服务器地址不能为空');
    });

    it('diagnostic_summary_contains_only_safe_identifiers_and_state', 0, (): void => {
      const mutation = DataMutationResult.failure(
        'relay-secret-id', 'not_ready', 'database', 'waiting_gate');
      const result = RustDeskRelaySaveResult.fromMutation(
        'attempt-safe', 'relay-secret-id', mutation);
      const summary = result.diagnosticSummary();
      expect(summary.indexOf('relay-secret-id')).assertEqual(-1);
      expect(summary.indexOf('database')).assertEqual(-1);
      expect(summary.indexOf('attempt-safe') >= 0).assertTrue();
      expect(summary.indexOf('code=not_ready') >= 0).assertTrue();
    });
  });
}
