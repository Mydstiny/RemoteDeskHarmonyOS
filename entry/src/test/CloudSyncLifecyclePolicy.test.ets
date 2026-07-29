import { describe, expect, it } from '@ohos/hypium';
import {
  CloudSyncDurableState,
  CloudSyncLifecyclePhase,
  cloudSyncAutomaticUploadAllowed,
  cloudSyncBootstrapCompleted,
  cloudSyncDownloadAllowed,
  cloudSyncDurableStateWithIntents,
  cloudSyncOperationFinished,
  cloudSyncOperationStarted,
  cloudSyncRestoreQuarantined,
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
    generation: 7
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

    it('rejects_a_durable_state_from_another_physical_owner_store', 0, (): void => {
      const foreign: CloudSyncDurableState =
        newCloudSyncDurableState(binding(), true, true, 1);
      const target: CloudAccountBinding = {
        state: 'bound',
        ownerScopeId: 'owner-b',
        storeIdentity: 'remotedesktop_owner-b.db',
        generation: 1
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
