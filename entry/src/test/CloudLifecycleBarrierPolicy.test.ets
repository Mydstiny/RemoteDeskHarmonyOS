import { describe, expect, it } from '@ohos/hypium';
import {
  VncSelectionFinalizeResult,
  cloudSelectionAfterAuthoritativePull,
  cloudSelectionAfterLocalPromotion,
  cloudSelectionBarrierAfterRollback,
  cloudSelectionLocalPromotionAllowed,
  cloudSelectionNativeFirstAllowed,
  cloudSelectionTransitionNeedsCloudFirst,
  executeVncSelectionFinalize,
  vncSelectionPostCommitUploadAllowed,
  vncSelectionRecoveryBarrier,
  vncSettingsRollbackJournal,
  vncSettingsRollbackRows,
  normalizeCloudSelectionReenablePhase
} from '../main/ets/services/CloudSelectionReenablePolicy';
import {
  cloudBootstrapRecordReconcileAction
} from '../main/ets/services/CloudBootstrapReconcilePolicy';

export default function cloudLifecycleBarrierPolicyTest():
  void {
  describe('CloudLifecycleBarrierPolicy', (): void => {
    it('keeps_native_first_blocked_until_pull_and_promotion_commit',
      0, (): void => {
        const pulled = cloudSelectionAfterAuthoritativePull(
          'pending_pull');
        expect(pulled).assertEqual('pull_complete');
        expect(cloudSelectionNativeFirstAllowed(
          pulled)).assertFalse();
        const promoted = cloudSelectionAfterLocalPromotion(
          pulled);
        expect(promoted).assertEqual(
          'promotion_complete');
        expect(cloudSelectionNativeFirstAllowed(
          promoted)).assertFalse();
        expect(cloudSelectionNativeFirstAllowed(
          null)).assertTrue();
        expect(cloudSelectionLocalPromotionAllowed(
          true, false)).assertTrue();
        expect(cloudSelectionLocalPromotionAllowed(
          false, false)).assertFalse();
        expect(normalizeCloudSelectionReenablePhase(
          'corrupt') === null).assertTrue();
      });

    it('reconciles_only_records_proven_by_the_pre_bootstrap_journal',
      0, (): void => {
        expect(cloudBootstrapRecordReconcileAction(
          true, 'crypto_migrate', false))
          .assertEqual('restore_table');
        expect(cloudBootstrapRecordReconcileAction(
          false, 'update', true))
          .assertEqual('restore_record');
        expect(cloudBootstrapRecordReconcileAction(
          false, 'delete', false))
          .assertEqual('delete_record');
        expect(cloudBootstrapRecordReconcileAction(
          false, 'update', false))
          .assertEqual('invalid');
      });

    it('requires_cloud_first_only_when_a_vnc_scope_is_newly_enabled',
      0, (): void => {
        expect(cloudSelectionTransitionNeedsCloudFirst(
          [], ['hosts'], true)).assertTrue();
        expect(cloudSelectionTransitionNeedsCloudFirst(
          ['hosts'], ['hosts', 'secrets'],
          true)).assertTrue();
        expect(cloudSelectionTransitionNeedsCloudFirst(
          ['hosts'], [], true)).assertFalse();
        expect(cloudSelectionTransitionNeedsCloudFirst(
          [], ['hosts'], false)).assertFalse();
      });

    it('restores_the_exact_pre_save_barrier_after_a_failed_vnc_save',
      0, (): void => {
        expect(cloudSelectionBarrierAfterRollback(
          null) === null).assertTrue();
        expect(cloudSelectionBarrierAfterRollback(
          'pull_complete'))
          .assertEqual('pull_complete');
        expect(cloudSelectionBarrierAfterRollback(
          'pending_pull'))
          .assertEqual('pending_pull');
      });

    it('rolls_back_if_promotion_phase_persistence_fails_after_mirror_write',
      0, (): void => {
        const steps: string[] = [];
        let rolledBack: boolean = false;
        const finalized: VncSelectionFinalizeResult =
          executeVncSelectionFinalize({
            begin: (): boolean => {
              steps.push('begin'); return true;
            },
            persistPullComplete: (): boolean => {
              steps.push('pull'); return true;
            },
            promote: (): boolean => {
              steps.push('promote'); return true;
            },
            persistPromotionComplete:
              (): boolean => {
                steps.push('promotion_phase');
                return false;
              },
            releaseBarrier: (): boolean => {
              steps.push('release'); return true;
            },
            deleteCheckpoint: (): boolean => {
              steps.push('delete'); return true;
            },
            commit: (): boolean => {
              steps.push('commit'); return true;
            },
            rollback: (): void => {
              rolledBack = true;
              steps.push('rollback');
            }
          });
        expect(finalized.ok).assertFalse();
        expect(finalized.failedStep)
          .assertEqual('promotion_phase');
        expect(rolledBack).assertTrue();
        expect(steps.indexOf('promote') >= 0)
          .assertTrue();
        expect(steps.indexOf('release'))
          .assertEqual(-1);
        expect(vncSelectionPostCommitUploadAllowed(
          finalized, true, 'pending_pull'))
          .assertFalse();
      });

    it('rolls_back_release_failure_without_deleting_checkpoint_or_uploading_secret_scope',
      0, (): void => {
        const newlyEnabledScopes: string[] =
          ['secrets'];
        let checkpointDeleted: boolean = false;
        let rolledBack: boolean = false;
        const finalized: VncSelectionFinalizeResult =
          executeVncSelectionFinalize({
            begin: (): boolean => true,
            persistPullComplete:
              (): boolean => true,
            promote: (): boolean => true,
            persistPromotionComplete:
              (): boolean => true,
            releaseBarrier: (): boolean => false,
            deleteCheckpoint: (): boolean => {
              checkpointDeleted = true;
              return true;
            },
            commit: (): boolean => true,
            rollback: (): void => {
              rolledBack = true;
            }
          });
        expect(finalized.failedStep)
          .assertEqual('release');
        expect(rolledBack).assertTrue();
        expect(checkpointDeleted).assertFalse();
        expect(newlyEnabledScopes.indexOf(
          'secrets') >= 0).assertTrue();
        expect(vncSelectionPostCommitUploadAllowed(
          finalized, true, 'pending_pull'))
          .assertFalse();
      });

    it('preserves_a_cloud_first_settings_row_with_the_deterministic_id_on_rollback',
      0, (): void => {
        const restored = vncSettingsRollbackRows(
          [{
            id: 'vncsettings_owner-a',
            payload: 'authoritative-cloud'
          }],
          [{
            id: 'vncsettings_owner-a',
            payload: 'uncommitted-local'
          }],
          [{
            id: 'vncsettings_owner-a',
            payload: 'original-local'
          }],
          'vncsettings_owner-a');
        expect(restored.cloudRows.length)
          .assertEqual(1);
        expect(restored.cloudRows[0]['payload'])
          .assertEqual('authoritative-cloud');
        expect(restored.localRows.length)
          .assertEqual(1);
        expect(restored.localRows[0]['payload'])
          .assertEqual('original-local');
        const journal =
          vncSettingsRollbackJournal(
            [{
              id: 'current-settings',
              tablename: 'vncrecord',
              recordid:
                'vncsettings_owner-a',
              operation: 'scope_promote'
            }, {
              id: 'unrelated',
              tablename: 'vncrecord',
              recordid: 'host-1',
              operation: 'scope_promote'
            }],
            [{
              id: 'original-settings',
              tablename: 'vncrecord_local',
              recordid:
                'vncsettings_owner-a',
              operation: 'upsert'
            }],
            'vncsettings_owner-a',
            'vncrecord', 'vncrecord_local');
        expect(journal.length).assertEqual(2);
        expect(journal[0]['id'])
          .assertEqual('original-settings');
        expect(journal[1]['id'])
          .assertEqual('unrelated');
      });

    it('keeps_process_interruption_recovery_fail_closed_until_checkpoint_finalization',
      0, (): void => {
        expect(vncSelectionRecoveryBarrier(
          true, null)).assertEqual('pending_pull');
        expect(vncSelectionRecoveryBarrier(
          true, 'pull_complete'))
          .assertEqual('pending_pull');
        const committed: VncSelectionFinalizeResult = {
          ok: true, failedStep: 'none'
        };
        expect(vncSelectionPostCommitUploadAllowed(
          committed, true, null)).assertFalse();
        expect(vncSelectionPostCommitUploadAllowed(
          committed, false,
          'promotion_complete')).assertFalse();
        expect(vncSelectionPostCommitUploadAllowed(
          committed, false, null)).assertTrue();
      });
  });
}
