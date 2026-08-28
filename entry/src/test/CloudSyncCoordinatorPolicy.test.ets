import { describe, it, expect } from '@ohos/hypium';
import {
  CLOUD_SYNC_ACCEPT_TIMEOUT_MS,
  CLOUD_SYNC_IDLE_TIMEOUT_MS,
  CLOUD_SYNC_MAX_RETRY_ATTEMPTS,
  CLOUD_SYNC_OVERALL_TIMEOUT_MS,
  CloudSyncRequest,
  CloudSyncRetryRecord,
  CloudSyncCallbackIdentity,
  CloudSyncWatchdogState,
  cloudDataChangeShouldRequestPull,
  cloudLocalMutationAllowed,
  cloudSyncBlockedByLocalRestore,
  cloudSyncCallbackIdentityMatches,
  cloudFirstCompatibleTablesAfterOptionalFailure,
  cloudFirstTablesForSelectionFinalization,
  cloudDistributedTableAutoSync,
  cloudSyncProgressFinished,
  cloudSyncProgressSucceeded,
  cloudSyncTargetTableCompleted,
  cloudSyncWatchdogNextDelayMs,
  cloudSyncWatchdogTimeoutKind,
  classifyCloudSyncFailure,
  classifyCloudSyncProgressCode,
  cloudSyncFailureMessage,
  coalesceAutomaticPush,
  exclusiveCloudOperationLeaseValid,
  exclusiveVncSelectionAdmissionAllowed,
  nextCloudSyncRetryDelayMs,
  retryTablesStillSelected,
  retryVncTablesStillSelected,
  snapshotCloudSyncTables,
  shouldReplayAutomaticPush,
  shouldBlockAutomaticRetry,
  shouldProtectMoonlightBeforeEmptyCloudMaterialization,
  shouldRejectAutomaticEmptyCloudSnapshot,
  shouldDeferAutomaticPushDuringBootstrap,
  shouldUseCloudFirstForInitialBootstrap,
  upsertAutomaticRetryRecord
} from '../main/ets/services/CloudSyncCoordinatorPolicy';
import {
  executeCloudSyncRequest,
  restoreQuarantinedStartupResult
} from '../main/ets/services/CloudSyncCoordinator';

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

    it('admits_one_lease_bound_VNC_mutation_and_blocks_sync_during_restore',
      0, (): void => {
        expect(exclusiveVncSelectionAdmissionAllowed(
          false, false, true, true)).assertTrue();
        expect(exclusiveVncSelectionAdmissionAllowed(
          true, false, true, true)).assertFalse();
        expect(exclusiveVncSelectionAdmissionAllowed(
          false, true, true, true)).assertFalse();
        expect(exclusiveCloudOperationLeaseValid(
          7, 7, true)).assertTrue();
        expect(exclusiveCloudOperationLeaseValid(
          7, 8, true)).assertFalse();
        expect(exclusiveCloudOperationLeaseValid(
          7, 7, false)).assertFalse();
        expect(cloudSyncBlockedByLocalRestore(
          true, false)).assertTrue();
        expect(cloudSyncBlockedByLocalRestore(
          false, true)).assertTrue();
        expect(cloudSyncBlockedByLocalRestore(
          false, false)).assertFalse();
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

    it('bounds_accept_idle_and_overall_cloud_sync_waits', 0, (): void => {
      const waitingForAccept: CloudSyncWatchdogState = {
        startedAt: 1000,
        lastSignalAt: 1000,
        signalObserved: false,
        settled: false
      };
      expect(cloudSyncWatchdogNextDelayMs(waitingForAccept, 1000))
        .assertEqual(CLOUD_SYNC_ACCEPT_TIMEOUT_MS);
      expect(cloudSyncWatchdogTimeoutKind(
        waitingForAccept, 1000 + CLOUD_SYNC_ACCEPT_TIMEOUT_MS - 1))
        .assertEqual('none');
      expect(cloudSyncWatchdogTimeoutKind(
        waitingForAccept, 1000 + CLOUD_SYNC_ACCEPT_TIMEOUT_MS))
        .assertEqual('accept_timeout');

      const progressing: CloudSyncWatchdogState = {
        startedAt: 1000,
        lastSignalAt: 5000,
        signalObserved: true,
        settled: false
      };
      expect(cloudSyncWatchdogTimeoutKind(
        progressing, 5000 + CLOUD_SYNC_IDLE_TIMEOUT_MS))
        .assertEqual('idle_timeout');
      progressing.lastSignalAt = 5000 + CLOUD_SYNC_IDLE_TIMEOUT_MS - 1;
      expect(cloudSyncWatchdogTimeoutKind(
        progressing, 5000 + CLOUD_SYNC_IDLE_TIMEOUT_MS))
        .assertEqual('none');
      expect(cloudSyncWatchdogTimeoutKind(
        progressing, 1000 + CLOUD_SYNC_OVERALL_TIMEOUT_MS))
        .assertEqual('overall_timeout');
      progressing.settled = true;
      expect(cloudSyncWatchdogTimeoutKind(
        progressing, 1000 + CLOUD_SYNC_OVERALL_TIMEOUT_MS))
        .assertEqual('none');
      expect(cloudSyncWatchdogNextDelayMs(
        progressing, 1000 + CLOUD_SYNC_OVERALL_TIMEOUT_MS))
        .assertEqual(-1);
    });

    it('accepts_late_callbacks_only_for_the_exact_operation_store_and_generation', 0, (): void => {
      const expected: CloudSyncCallbackIdentity = {
        operationId: 9,
        storeInstanceId: 4,
        generation: 7
      };
      expect(cloudSyncCallbackIdentityMatches(expected, {
        operationId: 9, storeInstanceId: 4, generation: 7
      })).assertTrue();
      expect(cloudSyncCallbackIdentityMatches(expected, {
        operationId: 8, storeInstanceId: 4, generation: 7
      })).assertFalse();
      expect(cloudSyncCallbackIdentityMatches(expected, {
        operationId: 9, storeInstanceId: 3, generation: 7
      })).assertFalse();
      expect(cloudSyncCallbackIdentityMatches(expected, {
        operationId: 9, storeInstanceId: 4, generation: 6
      })).assertFalse();
    });

    it('requires_complete_target_table_statistics_at_sync_finish', 0, (): void => {
      expect(cloudSyncTargetTableCompleted(null, 'remotehosts')).assertFalse();
      expect(cloudSyncTargetTableCompleted({}, 'remotehosts')).assertFalse();
      expect(cloudSyncTargetTableCompleted({
        remotehosts: {
          upload: { successful: 1, failed: 0, remained: 0 },
          download: { successful: 2, failed: 0, remained: 0 }
        }
      }, 'remotehosts')).assertTrue();
      expect(cloudSyncTargetTableCompleted({
        remotehosts: {
          upload: { successful: 0, failed: 0, remained: 1 },
          download: { successful: 0, failed: 0, remained: 0 }
        }
      }, 'remotehosts')).assertFalse();
    });

    it('classifies_numeric_progress_codes_without_string_guessing', 0, (): void => {
      expect(classifyCloudSyncProgressCode(2)).assertEqual('network');
      expect(classifyCloudSyncProgressCode(7)).assertEqual('network');
      expect(classifyCloudSyncProgressCode(3)).assertEqual('cloud_service');
      expect(classifyCloudSyncProgressCode(5)).assertEqual('cloud_service');
      expect(classifyCloudSyncProgressCode(1)).assertEqual('unknown');
    });

    it('rejects_a_suspicious_empty_startup_snapshot_without_blocking_explicit_download', 0, (): void => {
      expect(shouldRejectAutomaticEmptyCloudSnapshot('startup', 'cloudFirst', 11, 0)).assertTrue();
      expect(shouldRejectAutomaticEmptyCloudSnapshot('foreground', 'cloudFirst', 1, 0)).assertTrue();
      expect(shouldRejectAutomaticEmptyCloudSnapshot('manualDownload', 'cloudFirst', 11, 0)).assertFalse();
      expect(shouldRejectAutomaticEmptyCloudSnapshot('startup', 'cloudFirst', 0, 0)).assertFalse();
      expect(shouldRejectAutomaticEmptyCloudSnapshot(
        'startup', 'cloudFirst', 11, 0, true))
        .assertFalse();
    });

    it('protects_moonlight_before_local_overlay_materialization_on_automatic_empty_results',
      0, (): void => {
        expect(shouldProtectMoonlightBeforeEmptyCloudMaterialization(
          'startup', 'cloudFirst', 5, 0)).assertTrue();
        expect(shouldProtectMoonlightBeforeEmptyCloudMaterialization(
          'foreground', 'cloudFirst', 1, 0)).assertTrue();
        expect(shouldProtectMoonlightBeforeEmptyCloudMaterialization(
          'cloudEvent', 'cloudFirst', 7, 0)).assertTrue();
        expect(shouldProtectMoonlightBeforeEmptyCloudMaterialization(
          'manualDownload', 'cloudFirst', 5, 0)).assertFalse();
        expect(shouldProtectMoonlightBeforeEmptyCloudMaterialization(
          'startup', 'nativeFirst', 5, 0)).assertFalse();
        expect(shouldProtectMoonlightBeforeEmptyCloudMaterialization(
          'startup', 'cloudFirst', 0, 0)).assertFalse();
      });

    it('commits_legacy_cloud_first_tables_only_when_every_failure_is_optional',
      0, (): void => {
        expect(cloudFirstCompatibleTablesAfterOptionalFailure(
          'cloudFirst',
          ['usersettings', 'remotehosts', 'moonlightrecordv1'],
          ['moonlightrecordv1']).join(','))
          .assertEqual('usersettings,remotehosts');
        expect(cloudFirstCompatibleTablesAfterOptionalFailure(
          'cloudFirst', ['moonlightrecordv1'],
          ['moonlightrecordv1']).length).assertEqual(0);
        expect(cloudFirstCompatibleTablesAfterOptionalFailure(
          'nativeFirst',
          ['remotehosts', 'moonlightrecordv1'],
          ['moonlightrecordv1']).length).assertEqual(0);
        expect(cloudFirstCompatibleTablesAfterOptionalFailure(
          'cloudFirst',
          ['remotehosts', 'moonlightrecordv1'],
          ['remotehosts', 'moonlightrecordv1']).length)
          .assertEqual(0);
        expect(cloudFirstCompatibleTablesAfterOptionalFailure(
          'cloudFirst',
          ['remotehosts', 'moonlightrecordv1'],
          ['unknown']).length).assertEqual(0);
      });

    it('finalizes_established_barriers_for_core_tables_after_optional_failure',
      0, (): void => {
        expect(cloudFirstTablesForSelectionFinalization(
          false,
          ['usersettings', 'remotehosts', 'moonlightrecordv1'],
          ['moonlightrecordv1']).join(','))
          .assertEqual('usersettings,remotehosts');
        expect(cloudFirstTablesForSelectionFinalization(
          true, ['usersettings'], []).join(','))
          .assertEqual('usersettings');
        expect(cloudFirstTablesForSelectionFinalization(
          false, ['remotehosts'], ['remotehosts']).length)
          .assertEqual(0);
      });

    it('classifies_version_conflict_and_pauses_automatic_retries', 0, (): void => {
      expect(classifyCloudSyncFailure('code=0 msg=VERSION_CONFLICT')).assertEqual('version_conflict');
      expect(shouldBlockAutomaticRetry('version_conflict')).assertTrue();
      expect(shouldBlockAutomaticRetry('network')).assertFalse();
      expect(shouldBlockAutomaticRetry('no_selection')).assertFalse();
      expect(cloudSyncFailureMessage('version_conflict')).assertContain('版本冲突');
      expect(cloudSyncFailureMessage('no_selection')).assertContain('未启动云端传输');
    });

    it('keeps_unsafe_cloud_payloads_blocked_until_user_or_data_repair',
      0, (): void => {
        expect(classifyCloudSyncFailure(
          'unsafe_payload: plaintext secret in remotehosts'))
          .assertEqual('unsafe_payload');
        expect(shouldBlockAutomaticRetry('unsafe_payload')).assertTrue();
        expect(cloudSyncFailureMessage('unsafe_payload'))
          .assertContain('安全校验');
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
      expect(cloudLocalMutationAllowed(false, false, true, false)).assertTrue();
      expect(cloudLocalMutationAllowed(false, false, true, true)).assertTrue();
      expect(cloudLocalMutationAllowed(
        false, false, false, true, true, false)).assertFalse();
      expect(cloudLocalMutationAllowed(
        false, false, false, true, false, true)).assertFalse();
    });

    it('does_not_feed_a_cloud_first_materialization_event_back_into_the_queue',
      0, (): void => {
        expect(cloudDataChangeShouldRequestPull(false, false)).assertTrue();
        expect(cloudDataChangeShouldRequestPull(true, false)).assertFalse();
        expect(cloudDataChangeShouldRequestPull(false, true)).assertFalse();
        expect(cloudDataChangeShouldRequestPull(
          false, false, 1100, 1000, 3000)).assertFalse();
        expect(cloudDataChangeShouldRequestPull(
          false, false, 4000, 1000, 3000)).assertTrue();
      });

    it('forces_first_bootstrap_to_cloud_first_and_defers_automatic_uploads', 0, (): void => {
      expect(shouldUseCloudFirstForInitialBootstrap(false)).assertTrue();
      expect(shouldUseCloudFirstForInitialBootstrap(true)).assertFalse();
      expect(shouldDeferAutomaticPushDuringBootstrap('pending')).assertTrue();
      expect(shouldDeferAutomaticPushDuringBootstrap('ready')).assertFalse();
    });

    it('never_marks_a_restore_quarantine_as_a_successful_startup_pull',
      0, (): void => {
        const result =
          restoreQuarantinedStartupResult(
            ['remotehosts', 'vncrecordv2']);
        expect(result.ok).assertFalse();
        expect(result.source).assertEqual('startup');
        expect(result.tables.length).assertEqual(0);
        expect(result.failedTables.length)
          .assertEqual(2);
        expect(result.failureKind)
          .assertEqual('restore_pending');
        expect(shouldBlockAutomaticRetry(
          result.failureKind)).assertTrue();
        expect(cloudSyncFailureMessage(
          result.failureKind))
          .assertContain('恢复隔离');
      });

    it('does_not_treat_the_vnc_physical_table_as_an_ordinary_secret_table', 0, (): void => {
      const ordinary: string[] = snapshotCloudSyncTables(['vncrecordv2']);
      expect(ordinary.length).assertEqual(1);
      expect(ordinary[0]).assertEqual('vncrecordv2');
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

    it('uses_the_single_vncrecord_cloud_table_for_vnc_retries', 0, (): void => {
      const retained: string[] = retryVncTablesStillSelected(
        ['cryptoparams', 'vncrecordv2'], ['cryptoparams', 'vncrecordv2']);
      expect(retained.length).assertEqual(2);
      const dropped: string[] = retryVncTablesStillSelected(
        ['vncrecordv2'], []);
      expect(dropped.length).assertEqual(0);
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

    it('does_not_block_vncrecord_when_optional_crypto_sync_fails', 0, async (): Promise<void> => {
      const trace: string[] = [];
      const result = await executeCloudSyncRequest(
        { source: 'automaticPush', direction: 'nativeFirst', tables: ['cryptoparams', 'vncrecordv2'] },
        async (table: string): Promise<boolean> => {
          trace.push(table);
          return table !== 'cryptoparams';
        },
        null,
        (_tables: string[]): void => {}
      );
      expect(trace.length).assertEqual(2);
      expect(trace[0]).assertEqual('cryptoparams');
      expect(trace[1]).assertEqual('vncrecordv2');
      expect(result.ok).assertFalse();
      expect(result.failedTables.length).assertEqual(1);
      expect(result.failedTables[0]).assertEqual('cryptoparams');
    });

    it('keeps_crypto_fail_closed_for_mixed_protocol_downloads', 0, async (): Promise<void> => {
      const trace: string[] = [];
      const result = await executeCloudSyncRequest(
        { source: 'automaticPush', direction: 'nativeFirst', tables: ['cryptoparams', 'vncrecordv2', 'remotehosts'] },
        async (table: string): Promise<boolean> => {
          trace.push(table);
          return table !== 'cryptoparams';
        },
        null,
        (_tables: string[]): void => {}
      );
      expect(trace.length).assertEqual(1);
      expect(trace[0]).assertEqual('cryptoparams');
      expect(result.failedTables.length).assertEqual(3);
      expect(result.failedTables[1]).assertEqual('vncrecordv2');
      expect(result.failedTables[2]).assertEqual('remotehosts');
    });

    it('keeps_successful_vnc_manual_download_when_optional_crypto_sync_fails', 0,
      async (): Promise<void> => {
        let rolledBack: boolean = false;
        const completedTables: string[] = [];
        const result = await executeCloudSyncRequest(
          { source: 'manualDownload', direction: 'cloudFirst', tables: ['cryptoparams', 'vncrecordv2'] },
          async (table: string): Promise<boolean> => { return table !== 'cryptoparams'; },
          {
            beginManualDownload: (): boolean => true,
            rollbackManualDownload: async (): Promise<boolean> => { rolledBack = true; return true; },
            completeManualDownload: (tables: string[]): boolean => {
              return false;
            },
            completeManualDownloadPartial: async (
              tables: string[], _failedTables: string[]
            ): Promise<boolean> => {
              tables.forEach((table: string): void => { completedTables.push(table); });
              return true;
            },
            setRestorePending: (_pending: boolean): void => {}
          },
          (_tables: string[]): void => {}
        );
        expect(result.ok).assertFalse();
        expect(result.failedTables.length).assertEqual(1);
        expect(result.failedTables[0]).assertEqual('cryptoparams');
        expect(rolledBack).assertFalse();
        expect(completedTables.length).assertEqual(1);
        expect(completedTables[0]).assertEqual('vncrecordv2');
      });

    it('keeps_successful_legacy_manual_download_when_optional_moonlight_fails',
      0, async (): Promise<void> => {
        let rolledBack: boolean = false;
        const completedTables: string[] = [];
        const appliedTables: string[] = [];
        const result = await executeCloudSyncRequest(
          {
            source: 'manualDownload', direction: 'cloudFirst',
            tables: ['usersettings', 'moonlightrecordv1']
          },
          async (table: string): Promise<boolean> =>
            table !== 'moonlightrecordv1',
          {
            beginManualDownload: (): boolean => true,
            rollbackManualDownload: async (): Promise<boolean> => {
              rolledBack = true;
              return true;
            },
            completeManualDownload: (): boolean => false,
            completeManualDownloadPartial: async (
              tables: string[], failedTables: string[]
            ): Promise<boolean> => {
              tables.forEach((table: string): void =>
                completedTables.push(table));
              expect(failedTables.join(','))
                .assertEqual('moonlightrecordv1');
              return true;
            },
            setRestorePending: (_pending: boolean): void => {}
          },
          (tables: string[]): void => {
            tables.forEach((table: string): void =>
              appliedTables.push(table));
          }
        );
        expect(result.ok).assertFalse();
        expect(result.failedTables.join(','))
          .assertEqual('moonlightrecordv1');
        expect(rolledBack).assertFalse();
        expect(completedTables.join(','))
          .assertEqual('usersettings');
        expect(appliedTables.join(','))
          .assertEqual('usersettings');
      });

    it('keeps_moonlight_only_failure_on_the_full_rollback_path', 0,
      async (): Promise<void> => {
        let rolledBack: boolean = false;
        let partialCompleted: boolean = false;
        const result = await executeCloudSyncRequest(
          {
            source: 'manualDownload', direction: 'cloudFirst',
            tables: ['moonlightrecordv1']
          },
          async (): Promise<boolean> => false,
          {
            beginManualDownload: (): boolean => true,
            rollbackManualDownload: async (): Promise<boolean> => {
              rolledBack = true;
              return true;
            },
            completeManualDownload: (): boolean => false,
            completeManualDownloadPartial: async (): Promise<boolean> => {
              partialCompleted = true;
              return true;
            },
            setRestorePending: (_pending: boolean): void => {}
          },
          (_tables: string[]): void => {}
        );
        expect(result.ok).assertFalse();
        expect(rolledBack).assertTrue();
        expect(partialCompleted).assertFalse();
      });

    it('rolls_every_table_back_when_optional_partial_finalization_fails', 0,
      async (): Promise<void> => {
        let rolledBack: boolean = false;
        const result = await executeCloudSyncRequest(
          {
            source: 'manualDownload', direction: 'cloudFirst',
            tables: ['usersettings', 'moonlightrecordv1']
          },
          async (table: string): Promise<boolean> =>
            table !== 'moonlightrecordv1',
          {
            beginManualDownload: (): boolean => true,
            rollbackManualDownload: async (): Promise<boolean> => {
              rolledBack = true;
              return true;
            },
            completeManualDownload: (): boolean => false,
            completeManualDownloadPartial: async (): Promise<boolean> =>
              false,
            setRestorePending: (_pending: boolean): void => {}
          },
          (_tables: string[]): void => {}
        );
        expect(result.ok).assertFalse();
        expect(rolledBack).assertTrue();
        expect(result.failedTables.join(','))
          .assertEqual('usersettings,moonlightrecordv1');
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
