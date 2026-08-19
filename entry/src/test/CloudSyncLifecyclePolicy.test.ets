import { describe, expect, it } from '@ohos/hypium';
import {
  CloudSyncDurableState,
  CloudSyncLifecyclePhase,
  cloudSyncAutomaticUploadAllowed,
  cloudSyncBootstrapCompleted,
  cloudSyncDownloadAllowed,
  cloudSyncDurableStateWithIntents,
  cloudSyncExternalRecoveryRequired,
  cloudSyncExternalRecoverySettled,
  cloudSyncIndeterminateSettled,
  cloudSyncManualDownloadAllowed,
  cloudSyncManualUploadAllowed,
  cloudSyncOperationFinished,
  cloudSyncOperationStarted,
  cloudSyncRestoreQuarantined,
  cloudSyncRestoreResolutionAttemptFinished,
  cloudSyncRestoreResolutionCompleted,
  cloudSyncRestoreReleased,
  corruptedCloudSyncDurableState,
  newCloudSyncDurableState,
  recoverCloudSyncDurableState
} from '../main/ets/services/CloudSyncLifecyclePolicy';
import { CloudAccountBinding } from '../main/ets/services/CloudLifecycleSafetyPolicy';
import { CloudSyncFailureKind } from '../main/ets/services/CloudSyncCoordinatorPolicy';

function binding(state: 'unbound' | 'validating' | 'bound' | 'blocked' = 'bound'):
  CloudAccountBinding {
  return {
    state,
    ownerScopeId: 'owner-a',
    storeIdentity: 'remotedesktop_owner-a.db',
    generation: 7,
    platformIdentityFingerprint:
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' +
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  };
}

export default function cloudSyncLifecyclePolicyTest(): void {
  describe('CloudSyncLifecyclePolicy', (): void => {
    it('stays_disabled_until_rollout_and_identity_binding_are_both_proven', 0, (): void => {
      expect(newCloudSyncDurableState(binding('bound'), false, false, 1).phase)
        .assertEqual('disabled');
      expect(newCloudSyncDurableState(binding('validating'), true, false, 1).phase)
        .assertEqual('identity_validating');
      expect(newCloudSyncDurableState(binding('bound'), true, false, 1).phase)
        .assertEqual('bootstrap_required');
    });

    it('recovers_an_interrupted_transfer_without_allowing_an_upload', 0, (): void => {
      const initial: CloudSyncDurableState =
        newCloudSyncDurableState(binding(), true, true, 1);
      const started: CloudSyncDurableState = cloudSyncOperationStarted(
        initial, 'automaticPush', 'nativeFirst', ['remotehosts'], 2);
      const reopenedBinding: CloudAccountBinding = binding();
      reopenedBinding.generation = 8;
      const recovered: CloudSyncDurableState = recoverCloudSyncDurableState(
        started, reopenedBinding, true, true, 3);
      expect(recovered.phase).assertEqual('recovery_required');
      expect(recovered.generation).assertEqual(8);
      expect(cloudSyncAutomaticUploadAllowed(recovered)).assertFalse();
      const editedWhileRecovering: CloudSyncDurableState =
        cloudSyncDurableStateWithIntents(
          recovered, ['remotehosts'], [], [], 4);
      expect(editedWhileRecovering.phase).assertEqual('recovery_required');
      expect(cloudSyncAutomaticUploadAllowed(editedWhileRecovering)).assertFalse();
      expect(cloudSyncDownloadAllowed(editedWhileRecovering)).assertTrue();
    });

    it('never_allows_native_first_before_authoritative_bootstrap', 0, (): void => {
      const initial: CloudSyncDurableState =
        newCloudSyncDurableState(binding(), true, false, 1);
      expect(cloudSyncAutomaticUploadAllowed(initial)).assertFalse();
      const ready: CloudSyncDurableState = cloudSyncBootstrapCompleted(initial, 2);
      expect(ready.phase).assertEqual('ready');
      expect(cloudSyncAutomaticUploadAllowed(ready)).assertTrue();
    });

    it('persists_conflict_and_rollback_failures_as_fail_closed_states', 0, (): void => {
      const initial: CloudSyncDurableState =
        newCloudSyncDurableState(binding(), true, true, 1);
      const conflict: CloudSyncDurableState = cloudSyncOperationFinished(
        initial, false, ['remotehosts'], false, 'version_conflict', true, 2);
      expect(conflict.phase).assertEqual('conflict_blocked');
      expect(conflict.conflictTables[0]).assertEqual('remotehosts');

      const blocked: CloudSyncDurableState = cloudSyncOperationFinished(
        conflict, false, ['remotehosts'], true, 'unknown', true, 3);
      expect(blocked.phase).assertEqual('blocked');
      expect(cloudSyncAutomaticUploadAllowed(blocked)).assertFalse();
    });

    it('keeps_a_watchdog_timeout_in_recovery_until_native_terminal_arrives', 0, (): void => {
      const initial: CloudSyncDurableState =
        newCloudSyncDurableState(binding(), true, true, 1);
      const timedOut: CloudSyncDurableState = cloudSyncOperationFinished(
        initial, false, ['remotehosts'], false, 'indeterminate', true, 2);
      expect(timedOut.phase).assertEqual('recovery_required');
      expect(cloudSyncAutomaticUploadAllowed(timedOut)).assertFalse();
      expect(cloudSyncDownloadAllowed(timedOut)).assertTrue();

      const terminal: CloudSyncDurableState =
        cloudSyncIndeterminateSettled(timedOut, binding(), true, 3);
      expect(terminal.phase).assertEqual('ready');
      expect(terminal.lastFailureKind).assertEqual('indeterminate');
      expect(cloudSyncAutomaticUploadAllowed(terminal)).assertTrue();
    });

    it('keeps_external_checkpoint_recovery_distinct_and_releases_only_the_restored_table',
      0, (): void => {
        const initial: CloudSyncDurableState =
          newCloudSyncDurableState(
            binding(), true, true, 1);
        const required: CloudSyncDurableState =
          cloudSyncExternalRecoveryRequired(
            initial,
            ['vncrecord', 'remotehosts'], 2);
        expect(required.phase)
          .assertEqual('recovery_required');
        expect(required.lastFailureKind)
          .assertEqual('unknown');
        expect(cloudSyncAutomaticUploadAllowed(
          required)).assertFalse();

        const partial: CloudSyncDurableState =
          cloudSyncExternalRecoverySettled(
            required, binding(), true,
            ['vncrecord'], 3);
        expect(partial.phase)
          .assertEqual('recovery_required');
        expect(partial.failedTables.length)
          .assertEqual(1);
        expect(partial.failedTables[0])
          .assertEqual('remotehosts');

        const settled: CloudSyncDurableState =
          cloudSyncExternalRecoverySettled(
            partial, binding(), true,
            ['remotehosts'], 4);
        expect(settled.phase).assertEqual('ready');
        expect(settled.lastFailureKind)
          .assertEqual('none');
      });

    it('rejects_a_durable_state_from_another_physical_owner_store', 0, (): void => {
      const foreign: CloudSyncDurableState =
        newCloudSyncDurableState(binding(), true, true, 1);
      const target: CloudAccountBinding = {
        state: 'bound',
        ownerScopeId: 'owner-b',
        storeIdentity: 'remotedesktop_owner-b.db',
        generation: 1,
        platformIdentityFingerprint:
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' +
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
      };
      const recovered: CloudSyncDurableState =
        recoverCloudSyncDurableState(foreign, target, true, false, 2);
      expect(recovered.ownerScopeId).assertEqual('owner-b');
      expect(recovered.phase).assertEqual('bootstrap_required');
      expect(recovered.dirtyTables.length).assertEqual(0);
    });

    it('keeps_restore_quarantine_across_restart_even_when_rollout_is_disabled', 0, (): void => {
      const initial: CloudSyncDurableState =
        newCloudSyncDurableState(binding(), false, true, 1);
      const quarantined: CloudSyncDurableState =
        cloudSyncRestoreQuarantined(initial, 2);
      const recovered: CloudSyncDurableState = recoverCloudSyncDurableState(
        quarantined, binding(), false, true, 3);
      expect(recovered.phase).assertEqual('restore_quarantine');
      expect(cloudSyncAutomaticUploadAllowed(recovered)).assertFalse();
      expect(cloudSyncDownloadAllowed(recovered)).assertFalse();
    });

    it('releases_a_failed_restore_without_rewinding_the_revision', 0, (): void => {
      const initial: CloudSyncDurableState =
        newCloudSyncDurableState(binding(), true, true, 1);
      const quarantined: CloudSyncDurableState =
        cloudSyncRestoreQuarantined(initial, 2);
      const released: CloudSyncDurableState =
        cloudSyncRestoreReleased(quarantined, initial, 3);
      expect(released.phase).assertEqual('ready');
      expect(released.revision).assertEqual(quarantined.revision + 1);
    });

    it('allows_only_explicit_direction_while_restore_is_quarantined', 0, (): void => {
      const initial: CloudSyncDurableState =
        newCloudSyncDurableState(binding(), true, true, 1);
      const quarantined: CloudSyncDurableState =
        cloudSyncRestoreQuarantined(initial, 2);
      expect(cloudSyncAutomaticUploadAllowed(
        quarantined)).assertFalse();
      expect(cloudSyncDownloadAllowed(
        quarantined)).assertFalse();
      expect(cloudSyncManualUploadAllowed(
        quarantined, true)).assertTrue();
      expect(cloudSyncManualDownloadAllowed(
        quarantined, true)).assertTrue();
      expect(cloudSyncManualUploadAllowed(
        quarantined, false)).assertFalse();
      expect(cloudSyncManualDownloadAllowed(
        quarantined, false)).assertFalse();
    });

    it('keeps_each_terminal_restore_leg_quarantined_until_atomic_completion', 0, (): void => {
      const initial: CloudSyncDurableState =
        newCloudSyncDurableState(binding(), true, true, 1);
      const quarantined: CloudSyncDurableState =
        cloudSyncRestoreQuarantined(initial, 2);
      const started: CloudSyncDurableState =
        cloudSyncOperationStarted(
          quarantined, 'manualUpload',
          'nativeFirst', ['remotehosts'], 3);
      const legComplete: CloudSyncDurableState =
        cloudSyncRestoreResolutionAttemptFinished(
          started, true, [], false,
          'none', true, 4);
      expect(legComplete.phase)
        .assertEqual('restore_quarantine');
      expect(cloudSyncAutomaticUploadAllowed(
        legComplete)).assertFalse();

      const completed: CloudSyncDurableState =
        cloudSyncRestoreResolutionCompleted(
          legComplete, 5);
      expect(completed.phase).assertEqual('ready');
      expect(completed.bootstrapCompleted)
        .assertTrue();
      expect(completed.lastFailureKind)
        .assertEqual('none');
    });

    it('retains_stronger_recovery_after_indeterminate_restore_resolution', 0, (): void => {
      const initial: CloudSyncDurableState =
        newCloudSyncDurableState(binding(), true, true, 1);
      const quarantined: CloudSyncDurableState =
        cloudSyncRestoreQuarantined(initial, 2);
      const started: CloudSyncDurableState =
        cloudSyncOperationStarted(
          quarantined, 'manualUpload',
          'nativeFirst', ['remotehosts'], 3);
      const indeterminate: CloudSyncDurableState =
        cloudSyncRestoreResolutionAttemptFinished(
          started, false, ['remotehosts'], false,
          'indeterminate', true, 4);
      expect(indeterminate.phase)
        .assertEqual('recovery_required');
      expect(cloudSyncManualUploadAllowed(
        indeterminate, true)).assertFalse();
      expect(cloudSyncManualDownloadAllowed(
        indeterminate, true)).assertTrue();
    });

    it('treats_unknown_or_malformed_persisted_state_as_recovery_required', 0, (): void => {
      const invalid: CloudSyncDurableState =
        newCloudSyncDurableState(binding(), true, true, 1);
      invalid.phase = 'future_phase' as CloudSyncLifecyclePhase;
      invalid.revision = Number.NaN;
      invalid.lastFailureKind = 'future_failure' as CloudSyncFailureKind;
      const recovered: CloudSyncDurableState = recoverCloudSyncDurableState(
        invalid, binding(), true, true, 2);
      expect(recovered.phase).assertEqual('recovery_required');
      expect(recovered.revision).assertEqual(2);
      expect(recovered.lastFailureKind).assertEqual('unknown');
      expect(cloudSyncAutomaticUploadAllowed(recovered)).assertFalse();
    });

    it('accepts_the_no_selection_failure_kind_from_a_previous_process',
      0, (): void => {
        const persisted: CloudSyncDurableState =
          newCloudSyncDurableState(binding(), true, true, 1);
        persisted.lastFailureKind = 'no_selection';
        const recovered: CloudSyncDurableState = recoverCloudSyncDurableState(
          persisted, binding(), true, true, 2);
        expect(recovered.phase).assertEqual('ready');
        expect(recovered.lastFailureKind).assertEqual('no_selection');
      });

    it('keeps_a_json_corruption_sentinel_in_recovery_across_restart', 0, (): void => {
      const corrupted: CloudSyncDurableState =
        corruptedCloudSyncDurableState(binding(), true, 1);
      const recovered: CloudSyncDurableState = recoverCloudSyncDurableState(
        corrupted, binding(), true, true, 2);
      expect(recovered.phase).assertEqual('recovery_required');
      expect(cloudSyncAutomaticUploadAllowed(recovered)).assertFalse();
      expect(cloudSyncDownloadAllowed(recovered)).assertTrue();
    });
  });
}
