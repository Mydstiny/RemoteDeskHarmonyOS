import { describe, it, expect } from '@ohos/hypium';
import {
  CLOUD_SYNC_MAX_RETRY_ATTEMPTS,
  CloudSyncRequest,
  CloudSyncRetryRecord,
  cloudLocalMutationAllowed,
  cloudDistributedTableAutoSync,
  cloudSyncProgressFinished,
  cloudSyncProgressSucceeded,
  classifyCloudSyncFailure,
  cloudSyncFailureMessage,
  coalesceAutomaticPush,
  nextCloudSyncRetryDelayMs,
  retryTablesStillSelected,
  snapshotCloudSyncTables,
  shouldReplayAutomaticPush,
  shouldBlockAutomaticRetry,
  shouldRejectAutomaticEmptyCloudSnapshot,
  upsertAutomaticRetryRecord
} from '../main/ets/services/CloudSyncCoordinatorPolicy';
import { executeCloudSyncRequest } from '../main/ets/services/CloudSyncCoordinator';

export default function cloudSyncCoordinatorPolicyTest(): void {
  describe('CloudSyncCoordinatorPolicy', (): void => {
    it('disables_system_autosync_so_selection_cannot_be_bypassed', 0, (): void => {
      expect(cloudDistributedTableAutoSync()).assertFalse();
    });

    it('freezes_selected_tables_with_crypto_before_encrypted_data', 0, (): void => {
      const snapshot: string[] = snapshotCloudSyncTables(['sshkeys']);
      expect(snapshot.length).assertEqual(2);
      expect(snapshot[0]).assertEqual('cryptoparams');
      expect(snapshot[1]).assertEqual('sshkeys');
    });

    it('does_not_coalesce_distinct_automatic_table_pushes', 0, (): void => {
      expect(coalesceAutomaticPush('sshkeys', 'sshkeys')).assertTrue();
      expect(coalesceAutomaticPush('sshkeys', 'totpentries')).assertFalse();
    });

    it('replays_a_table_changed_while_its_upload_was_pending', 0, (): void => {
      expect(shouldReplayAutomaticPush(1, 2)).assertTrue();
      expect(shouldReplayAutomaticPush(2, 2)).assertFalse();
    });

    it('waits_for_the_terminal_progress_event_before_confirming_cloud_upload', 0, (): void => {
      expect(cloudSyncProgressFinished(0)).assertFalse();
      expect(cloudSyncProgressFinished(1)).assertFalse();
      expect(cloudSyncProgressFinished(2)).assertTrue();
    });

    it('accepts_only_a_successful_terminal_cloud_progress_event', 0, (): void => {
      expect(cloudSyncProgressSucceeded(2, 0)).assertTrue();
      expect(cloudSyncProgressSucceeded(1, 0)).assertFalse();
      expect(cloudSyncProgressSucceeded(2, 2)).assertFalse();
    });

    it('rejects_a_suspicious_empty_startup_snapshot_without_blocking_explicit_download', 0, (): void => {
      expect(shouldRejectAutomaticEmptyCloudSnapshot('startup', 'cloudFirst', 11, 0)).assertTrue();
      expect(shouldRejectAutomaticEmptyCloudSnapshot('foreground', 'cloudFirst', 1, 0)).assertTrue();
      expect(shouldRejectAutomaticEmptyCloudSnapshot('manualDownload', 'cloudFirst', 11, 0)).assertFalse();
      expect(shouldRejectAutomaticEmptyCloudSnapshot('startup', 'cloudFirst', 0, 0)).assertFalse();
    });

    it('classifies_version_conflict_and_pauses_automatic_retries', 0, (): void => {
      expect(classifyCloudSyncFailure('code=0 msg=VERSION_CONFLICT')).assertEqual('version_conflict');
      expect(shouldBlockAutomaticRetry('version_conflict')).assertTrue();
      expect(shouldBlockAutomaticRetry('network')).assertFalse();
      expect(cloudSyncFailureMessage('version_conflict')).assertContain('版本冲突');
    });

    it('uses_bounded_retry_delays', 0, (): void => {
      expect(CLOUD_SYNC_MAX_RETRY_ATTEMPTS).assertEqual(3);
      expect(nextCloudSyncRetryDelayMs(1)).assertEqual(1000);
      expect(nextCloudSyncRetryDelayMs(2)).assertEqual(5000);
      expect(nextCloudSyncRetryDelayMs(3)).assertEqual(30000);
      expect(nextCloudSyncRetryDelayMs(4)).assertEqual(-1);
    });

    it('blocks_local_writes_while_a_download_or_restore_owns_the_database', 0, (): void => {
      expect(cloudLocalMutationAllowed(false, false)).assertTrue();
      expect(cloudLocalMutationAllowed(true, false)).assertFalse();
      expect(cloudLocalMutationAllowed(false, true)).assertFalse();
    });

    it('keeps_retry_intent_for_each_distinct_automatic_table', 0, (): void => {
      const ssh: CloudSyncRetryRecord = {
        source: 'automaticPush', direction: 'nativeFirst', tables: ['cryptoparams', 'sshkeys'],
        failedTables: ['cryptoparams', 'sshkeys'], attempt: 1, nextRetryAt: 1000
      };
      const totp: CloudSyncRetryRecord = {
        source: 'automaticPush', direction: 'nativeFirst', tables: ['cryptoparams', 'totpentries'],
        failedTables: ['cryptoparams', 'totpentries'], attempt: 1, nextRetryAt: 1000
      };
      const records: CloudSyncRetryRecord[] = upsertAutomaticRetryRecord([ssh], totp);
      expect(records.length).assertEqual(2);
      expect(records[0].tables[1]).assertEqual('sshkeys');
      expect(records[1].tables[1]).assertEqual('totpentries');
    });

    it('drops_a_scheduled_retry_after_its_business_table_is_deselected', 0, (): void => {
      const dropped: string[] = retryTablesStillSelected(['cryptoparams', 'sshkeys'], ['totpentries']);
      expect(dropped.length).assertEqual(0);
      const retained: string[] = retryTablesStillSelected(['cryptoparams', 'sshkeys'], ['sshkeys']);
      expect(retained.length).assertEqual(2);
      expect(retained[1]).assertEqual('sshkeys');
    });

    it('converts_executor_rejection_into_a_failed_download_and_rolls_back', 0, async (): Promise<void> => {
      let rolledBack: boolean = false;
      const request: CloudSyncRequest = {
        source: 'manualDownload', direction: 'cloudFirst', tables: ['sshkeys']
      };
      const result = await executeCloudSyncRequest(
        request,
        async (): Promise<boolean> => { throw new Error('service unavailable'); },
        {
          beginManualDownload: (): boolean => true,
          rollbackManualDownload: async (): Promise<boolean> => { rolledBack = true; return true; },
          completeManualDownload: (): void => {},
          setRestorePending: (_pending: boolean): void => {}
        },
        (_tables: string[]): void => {}
      );
      expect(result.ok).assertFalse();
      expect(result.failedTables[0]).assertEqual('sshkeys');
      expect(rolledBack).assertTrue();
    });

    it('propagates_the_executor_failure_kind_to_retry_policy', 0, async (): Promise<void> => {
      const result = await executeCloudSyncRequest(
        { source: 'automaticPush', direction: 'nativeFirst', tables: ['remotehosts'] },
        async (): Promise<boolean> => false,
        {
          beginManualDownload: (): boolean => true,
          rollbackManualDownload: async (): Promise<boolean> => true,
          completeManualDownload: (): void => {},
          setRestorePending: (_pending: boolean): void => {},
          failureKindForTable: (_table: string): 'version_conflict' => 'version_conflict'
        },
        (_tables: string[]): void => {}
      );
      expect(result.failureKind).assertEqual('version_conflict');
    });

    it('retains_the_business_table_when_crypto_precondition_fails', 0, async (): Promise<void> => {
      const trace: string[] = [];
      const request: CloudSyncRequest = {
        source: 'automaticPush', direction: 'nativeFirst', tables: ['cryptoparams', 'sshkeys']
      };
      const result = await executeCloudSyncRequest(
        request,
        async (table: string): Promise<boolean> => { trace.push(table); return false; },
        null,
        (_tables: string[]): void => {}
      );
      expect(trace.length).assertEqual(1);
      expect(result.failedTables.length).assertEqual(2);
      expect(result.failedTables[1]).assertEqual('sshkeys');
    });

    it('reports_when_a_failed_download_cannot_restore_its_snapshot', 0, async (): Promise<void> => {
      const request: CloudSyncRequest = {
        source: 'manualDownload', direction: 'cloudFirst', tables: ['sshkeys']
      };
      const result = await executeCloudSyncRequest(
        request,
        async (): Promise<boolean> => false,
        {
          beginManualDownload: (): boolean => true,
          rollbackManualDownload: async (): Promise<boolean> => false,
          completeManualDownload: (): void => {},
          setRestorePending: (_pending: boolean): void => {}
        },
        (_tables: string[]): void => {}
      );
      expect(result.rollbackFailed).assertTrue();
    });
  });
}
