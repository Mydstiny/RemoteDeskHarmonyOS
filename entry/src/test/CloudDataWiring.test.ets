import { describe, expect, it } from '@ohos/hypium';
import {
  CloudSyncCoordinator,
  CloudSyncCoordinatorHooks,
  CloudSyncOperationResult,
  CloudSyncRetryClock,
  CloudSyncRetryTimerTask,
  CloudSyncSelectionSource
} from '../main/ets/services/CloudSyncCoordinator';
import {
  CloudStore,
  CloudStoreMetadataQueryPort,
  CloudStoreVncAuthoritativeCompletionPort,
  CloudStoreVncSelectionFinalizationPort
} from '../main/ets/services/CloudStore';
import { CloudSyncDirection } from '../main/ets/services/CloudSyncPolicy';
import {
  CloudSyncFailureKind
} from '../main/ets/services/CloudSyncCoordinatorPolicy';
import {
  CloudSyncDurableState
} from '../main/ets/services/CloudSyncLifecyclePolicy';
import {
  AccountSessionLease
} from '../main/ets/services/AccountScopePolicy';
import {
  CloudAccountBinding
} from '../main/ets/services/CloudLifecycleSafetyPolicy';
import {
  CloudMetadataReadResult
} from '../main/ets/services/CloudMetadataSafetyPolicy';
import {
  CloudDownloadTransactionOperation
} from '../main/ets/services/CloudDownloadTransactionPolicy';

class DeferredSignal {
  promise: Promise<void>;
  private resolveSignal:
    (() => void) | null = null;

  constructor() {
    this.promise = new Promise<void>(
      (resolve: () => void): void => {
        this.resolveSignal = resolve;
      });
  }

  release(): void {
    const resolve:
      (() => void) | null =
      this.resolveSignal;
    this.resolveSignal = null;
    if (resolve !== null) {
      resolve();
    }
  }
}

class FixedSelectionSource
  implements CloudSyncSelectionSource {
  private readonly tables: string[];

  constructor(tables: string[]) {
    this.tables = tables.slice();
  }

  selectedBusinessTables(): string[] {
    return this.tables.slice();
  }
}

class ControlledRetryClock
  implements CloudSyncRetryClock {
  private nowValue: number = 1000;
  private nextTimerId: number = 1;
  private timerId: number = -1;
  private task:
    CloudSyncRetryTimerTask | null = null;

  now(): number {
    return this.nowValue;
  }

  schedule(
    task: CloudSyncRetryTimerTask,
    _delayMs: number
  ): number {
    this.timerId = this.nextTimerId++;
    this.task = task;
    return this.timerId;
  }

  cancel(timerId: number): void {
    if (timerId === this.timerId) {
      this.timerId = -1;
      this.task = null;
    }
  }

  hasScheduledTask(): boolean {
    return this.task !== null;
  }

  advanceAndFire(deltaMs: number): void {
    this.nowValue += Math.max(0, deltaMs);
    const task:
      CloudSyncRetryTimerTask | null =
      this.task;
    this.task = null;
    this.timerId = -1;
    if (task !== null) {
      task();
    }
  }
}

class CoordinatorHooks
  implements CloudSyncCoordinatorHooks {
  failureKind: CloudSyncFailureKind =
    'network';
  restoredNotUploaded: boolean = false;
  restoredProbe:
    (() => boolean) | null = null;
  selectionBlocked:
    ((table: string) => boolean) | null =
    null;
  durableState:
    CloudSyncDurableState | null = null;

  beginManualDownload(): boolean {
    return true;
  }

  async rollbackManualDownload():
    Promise<boolean> {
    return true;
  }

  completeManualDownload(
    _tables: string[]
  ): boolean {
    return true;
  }

  setRestorePending(_pending: boolean): void {
  }

  failureKindForTable(
    _table: string
  ): CloudSyncFailureKind {
    return this.failureKind;
  }

  hasRestoredNotUploaded(): boolean {
    return this.restoredProbe !== null
      ? this.restoredProbe()
      : this.restoredNotUploaded;
  }

  hasCloudBootstrapCompleted(): boolean {
    return true;
  }

  loadDurableState():
    CloudSyncDurableState | null {
    return this.durableState;
  }

  persistDurableState(
    state: CloudSyncDurableState
  ): boolean {
    this.durableState = state;
    return true;
  }

  selectionReenableBlocked(
    table: string
  ): boolean {
    return this.selectionBlocked !== null &&
      this.selectionBlocked(table);
  }
}

function accountLease():
  AccountSessionLease {
  return {
    ownerScopeId: 'owner-wiring-test',
    storeIdentity:
      'remotedesktop_owner-wiring-test.db',
    generation: 7,
    storeInstanceId: 3
  };
}

function accountBinding():
  CloudAccountBinding {
  return {
    state: 'bound',
    ownerScopeId: 'owner-wiring-test',
    storeIdentity:
      'remotedesktop_owner-wiring-test.db',
    generation: 7,
    platformIdentityFingerprint:
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' +
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  };
}

async function flushPromiseQueue(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

type MetadataMode =
  'present' | 'absent' | 'error';

class MutableMetadataQueryPort
  implements CloudStoreMetadataQueryPort {
  mode: MetadataMode = 'absent';
  value: string = '';

  queryValue(_key: string):
    string | null {
    if (this.mode === 'error') {
      throw new Error(
        'injected querySync failure');
    }
    if (this.mode === 'absent') {
      return null;
    }
    return this.value;
  }
}

type CompletionFault =
  'none' | 'begin' | 'rebase' |
  'journal' | 'delete' | 'commit';

/**
 * Minimal transactional fake. Mutations are written only to working state
 * between begin/commit, so rollback and kill-point assertions exercise the
 * same port that CloudStore's production completion method drives.
 */
class FakeVncCompletionPort
  implements
  CloudStoreVncAuthoritativeCompletionPort {
  fault: CompletionFault = 'none';
  readBackError: boolean = false;
  events: string[] = [];
  generalCheckpointPresent:
    boolean = true;
  vncCheckpointStage: string =
    'prepared';
  journalState: string = 'captured';
  snapshotCleared: boolean = false;
  private transactionId: number = 0;
  private workingGeneral: boolean = true;
  private workingStage: string = 'prepared';
  private workingJournal: string =
    'captured';

  activeOperation():
    CloudDownloadTransactionOperation | null {
    return 'selection_reenable';
  }

  beginTransaction(): boolean {
    this.events.push('begin');
    if (this.fault === 'begin') {
      return false;
    }
    this.transactionId++;
    this.workingGeneral =
      this.generalCheckpointPresent;
    this.workingStage =
      this.vncCheckpointStage;
    this.workingJournal =
      this.journalState;
    return true;
  }

  rebaseAuthoritativeCheckpoint():
    boolean {
    this.events.push(
      this.transactionId.toString() +
      ':rebase');
    if (this.fault === 'rebase') {
      return false;
    }
    this.workingStage =
      'authoritative';
    return true;
  }

  reconcileJournal(
    tables: string[]
  ): boolean {
    this.events.push(
      this.transactionId.toString() +
      ':journal:' + tables.join('+'));
    if (this.fault === 'journal') {
      return false;
    }
    this.workingJournal = 'replayed';
    return true;
  }

  deleteDownloadCheckpoint(): boolean {
    this.events.push(
      this.transactionId.toString() +
      ':delete');
    if (this.fault === 'delete') {
      return false;
    }
    this.workingGeneral = false;
    return true;
  }

  commit(): boolean {
    this.events.push(
      this.transactionId.toString() +
      ':commit');
    if (this.fault === 'commit') {
      return false;
    }
    this.generalCheckpointPresent =
      this.workingGeneral;
    this.vncCheckpointStage =
      this.workingStage;
    this.journalState =
      this.workingJournal;
    return true;
  }

  rollback(): void {
    this.events.push(
      this.transactionId.toString() +
      ':rollback');
    this.workingGeneral =
      this.generalCheckpointPresent;
    this.workingStage =
      this.vncCheckpointStage;
    this.workingJournal =
      this.journalState;
  }

  readDownloadCheckpointState():
    CloudMetadataReadResult {
    if (this.readBackError) {
      return { state: 'error', value: '' };
    }
    return this.generalCheckpointPresent
      ? { state: 'present', value: 'general' }
      : { state: 'absent', value: '' };
  }

  readVncCheckpointStageState():
    CloudMetadataReadResult {
    if (this.readBackError) {
      return { state: 'error', value: '' };
    }
    return {
      state: 'present',
      value: this.vncCheckpointStage
    };
  }

  clearInMemorySnapshot(): void {
    this.events.push('publish');
    this.snapshotCleared = true;
  }
}

class FakeVncFinalizationPort
  implements
  CloudStoreVncSelectionFinalizationPort {
  checkpointStage:
    CloudMetadataReadResult = {
      state: 'present',
      value: 'authoritative'
    };
  checkpointAfter:
    CloudMetadataReadResult = {
      state: 'absent',
      value: ''
    };
  barrierAfter:
    CloudMetadataReadResult = {
      state: 'absent',
      value: ''
    };
  events: string[] = [];
  uploadRequested: boolean = false;

  readCheckpointStageState():
    CloudMetadataReadResult {
    this.events.push('read_stage');
    return this.checkpointStage;
  }

  preparePromotion(): boolean {
    this.events.push('prepare');
    return true;
  }

  beginTransaction(): boolean {
    this.events.push('begin');
    return true;
  }

  persistPullComplete(): boolean {
    this.events.push('pull_complete');
    return true;
  }

  promote(): boolean {
    this.events.push('promote');
    return true;
  }

  persistPromotionComplete():
    boolean {
    this.events.push(
      'promotion_complete');
    return true;
  }

  releaseBarrier(): boolean {
    this.events.push('release');
    return true;
  }

  deleteCheckpoint(): boolean {
    this.events.push('delete');
    return true;
  }

  commit(): boolean {
    this.events.push('commit');
    return true;
  }

  rollback(): void {
    this.events.push('rollback');
  }

  readCheckpointAfterCommitState():
    CloudMetadataReadResult {
    this.events.push(
      'read_checkpoint_after');
    return this.checkpointAfter;
  }

  readBarrierAfterCommitState():
    CloudMetadataReadResult {
    this.events.push(
      'read_barrier_after');
    return this.barrierAfter;
  }

  requestAutomaticUpload(): void {
    this.events.push('upload');
    this.uploadRequested = true;
  }
}

export default function cloudDataWiringTest():
  void {
  describe('CloudDataWiring', (): void => {
    it('serializes_live_sync_exclusive_restore_event_retry_and_upload',
      0, async (): Promise<void> => {
        const clock =
          new ControlledRetryClock();
        const coordinator =
          new CloudSyncCoordinator(
            new FixedSelectionSource(
              ['remotehosts', 'sshkeys']),
            clock);
        const hooks =
          new CoordinatorHooks();
        const lease = accountLease();
        const events: string[] = [];
        const cloudGate =
          new DeferredSignal();
        const restoreGate =
          new DeferredSignal();
        let mode: string = 'bootstrap';
        let blockedCloudEvent:
          boolean = false;
        const bound: boolean =
          coordinator.bind(
            lease,
            accountBinding(),
            async (
              table: string,
              _direction:
                CloudSyncDirection,
              label: string
            ): Promise<boolean> => {
              events.push(
                label + ':' + table +
                ':start');
              if (mode === 'seed_failure' &&
                label === 'automaticPush' &&
                table === 'remotehosts') {
                events.push(
                  'seed:failed');
                return false;
              }
              if (mode === 'queue_probe' &&
                label === 'cloudEvent' &&
                !blockedCloudEvent) {
                blockedCloudEvent = true;
                await cloudGate.promise;
              }
              events.push(
                label + ':' + table +
                ':done');
              return true;
            },
            (_tables: string[]): void => {
            },
            hooks);
        expect(bound).assertTrue();
        const startup:
          CloudSyncOperationResult =
          await coordinator
            .requestStartupPull();
        expect(startup.ok).assertTrue();

        mode = 'seed_failure';
        const seed:
          CloudSyncOperationResult =
          await coordinator
            .requestAutomaticPush(
              'remotehosts');
        expect(seed.ok).assertFalse();
        expect(clock.hasScheduledTask())
          .assertTrue();

        mode = 'queue_probe';
        const existingSync:
          Promise<CloudSyncOperationResult> =
          coordinator
            .requestCloudEventPull();
        await flushPromiseQueue();
        const exclusive:
          Promise<boolean> =
          coordinator
            .runExclusiveVncSelectionMutation(
              async (
                exclusiveLease:
                  AccountSessionLease
              ): Promise<void> => {
                events.push(
                  'exclusive:start');
                expect(coordinator
                  .isExclusiveVncSelectionLease(
                    exclusiveLease))
                  .assertTrue();
                await restoreGate.promise;
                events.push(
                  'exclusive:restore_done');
              });
        cloudGate.release();
        expect((await existingSync).ok)
          .assertTrue();
        await flushPromiseQueue();
        expect(events.indexOf(
          'exclusive:start') >= 0)
          .assertTrue();

        const startsBeforeRelease:
          number = events.filter(
            (event: string): boolean =>
              event.indexOf(':start') >= 0)
            .length;
        const queuedEvent =
          coordinator
            .requestCloudEventPull();
        const queuedUpload =
          coordinator
            .requestAutomaticPush(
              'sshkeys');
        clock.advanceAndFire(2000);
        await flushPromiseQueue();
        expect(events.filter(
          (event: string): boolean =>
            event.indexOf(':start') >= 0)
          .length)
          .assertEqual(
            startsBeforeRelease);

        restoreGate.release();
        expect(await exclusive).assertTrue();
        expect((await queuedEvent).ok)
          .assertTrue();
        expect((await queuedUpload).ok)
          .assertTrue();
        const drain =
          coordinator
            .runExclusiveVncSelectionMutation(
              async (): Promise<void> => {
                events.push('drain');
              });
        expect(await drain).assertTrue();

        const restoreDoneIndex:
          number = events.indexOf(
          'exclusive:restore_done');
        const secondCloudIndex:
          number = events.lastIndexOf(
          'cloudEvent:cryptoparams:start');
        const retryIndex:
          number = events.lastIndexOf(
          'automaticPush:remotehosts:start');
        const uploadIndex:
          number = events.lastIndexOf(
          'automaticPush:sshkeys:start');
        expect(restoreDoneIndex >= 0)
          .assertTrue();
        expect(secondCloudIndex >
          restoreDoneIndex).assertTrue();
        expect(retryIndex >
          restoreDoneIndex).assertTrue();
        expect(uploadIndex >
          restoreDoneIndex).assertTrue();
        expect(await coordinator.dispose(
          lease, 1000)).assertTrue();
      });

    it('invalidated_lease_fails_closed_before_queued_exclusive_work',
      0, async (): Promise<void> => {
        const coordinator =
          new CloudSyncCoordinator(
            new FixedSelectionSource(
              ['remotehosts']),
            new ControlledRetryClock());
        const hooks =
          new CoordinatorHooks();
        const lease = accountLease();
        const gate = new DeferredSignal();
        let block: boolean = false;
        let exclusiveStarted:
          boolean = false;
        expect(coordinator.bind(
          lease,
          accountBinding(),
          async (
            _table: string,
            _direction:
              CloudSyncDirection,
            label: string
          ): Promise<boolean> => {
            if (block &&
              label === 'cloudEvent') {
              await gate.promise;
            }
            return true;
          },
          (_tables: string[]): void => {
          },
          hooks)).assertTrue();
        expect((await coordinator
          .requestStartupPull()).ok)
          .assertTrue();
        block = true;
        const active =
          coordinator
            .requestCloudEventPull();
        await flushPromiseQueue();
        const queued =
          coordinator
            .runExclusiveVncSelectionMutation(
              async (): Promise<void> => {
                exclusiveStarted = true;
              });
        const disposing =
          coordinator.dispose(
            lease, 1000);
        gate.release();
        expect((await active).ok)
          .assertTrue();
        expect(await queued).assertFalse();
        expect(await disposing).assertTrue();
        expect(exclusiveStarted)
          .assertFalse();
      });

    it('uses_CloudStore_metadata_query_port_for_present_absent_and_error',
      0, (): void => {
        const metadata =
          new MutableMetadataQueryPort();
        const store =
          new CloudStore({
            metadataQuery: metadata
          });
        metadata.mode = 'absent';
        expect(store.readLocalMetadataState(
          'barrier').state)
          .assertEqual('absent');
        metadata.mode = 'present';
        metadata.value = 'pending_pull';
        const present =
          store.readLocalMetadataState(
            'barrier');
        expect(present.state)
          .assertEqual('present');
        expect(present.value)
          .assertEqual('pending_pull');
        metadata.mode = 'error';
        expect(store.readLocalMetadataState(
          'barrier').state)
          .assertEqual('error');
        expect(store
          .selectionReenableBlocked(
            'remotehosts'))
          .assertTrue();
        expect(store
          .hasRestoredNotUploaded())
          .assertTrue();
      });

    it('metadata_query_error_blocks_bootstrap_retry_and_native_first',
      0, async (): Promise<void> => {
        const metadata =
          new MutableMetadataQueryPort();
        const store =
          new CloudStore({
            metadataQuery: metadata
          });
        const clock =
          new ControlledRetryClock();
        const hooks =
          new CoordinatorHooks();
        hooks.selectionBlocked =
          (table: string): boolean =>
            store
              .selectionReenableBlocked(
                table);
        const coordinator =
          new CloudSyncCoordinator(
            new FixedSelectionSource(
              ['remotehosts']),
            clock);
        let executions: number = 0;
        let failUpload: boolean = false;
        expect(coordinator.bind(
          accountLease(),
          accountBinding(),
          async (
            table: string,
            _direction:
              CloudSyncDirection,
            label: string
          ): Promise<boolean> => {
            executions++;
            return !(failUpload &&
              label === 'automaticPush' &&
              table === 'remotehosts');
          },
          (_tables: string[]): void => {
          },
          hooks)).assertTrue();
        metadata.mode = 'absent';
        expect((await coordinator
          .requestStartupPull()).ok)
          .assertTrue();
        failUpload = true;
        expect((await coordinator
          .requestAutomaticPush(
            'remotehosts')).ok)
          .assertFalse();
        expect(clock.hasScheduledTask())
          .assertTrue();
        const beforeRetry: number =
          executions;
        metadata.mode = 'error';
        clock.advanceAndFire(2000);
        await flushPromiseQueue();
        expect(executions)
          .assertEqual(beforeRetry);
        expect((await coordinator
          .requestAutomaticPush(
            'remotehosts')).ok)
          .assertFalse();
        expect(executions)
          .assertEqual(beforeRetry);
        expect(await coordinator.dispose(
          accountLease(), 1000))
          .assertTrue();

        const bootstrapHooks =
          new CoordinatorHooks();
        bootstrapHooks.restoredProbe =
          (): boolean =>
            store.hasRestoredNotUploaded();
        const bootstrap =
          new CloudSyncCoordinator(
            new FixedSelectionSource(
              ['remotehosts']),
            new ControlledRetryClock());
        expect(bootstrap.bind(
          accountLease(),
          accountBinding(),
          async (): Promise<boolean> =>
            true,
          (_tables: string[]): void => {
          },
          bootstrapHooks)).assertTrue();
        const blocked =
          await bootstrap
            .requestStartupPull();
        expect(blocked.ok).assertFalse();
        expect(blocked.failureKind)
          .assertEqual(
            'restore_pending');
        expect(await bootstrap.dispose(
          accountLease(), 1000))
          .assertTrue();
      });

    it('drives_CloudStore_authoritative_completion_in_one_transaction',
      0, (): void => {
        const port =
          new FakeVncCompletionPort();
        const store =
          new CloudStore({
            vncAuthoritativeCompletion:
              port
          });
        expect(store
          .completeVncAuthoritativeCloudFirst(
            ['vncrecord']))
          .assertTrue();
        expect(port.events.join(','))
          .assertEqual(
            'begin,1:rebase,' +
            '1:journal:vncrecord,' +
            '1:delete,1:commit,publish');
        expect(port
          .generalCheckpointPresent)
          .assertFalse();
        expect(port.vncCheckpointStage)
          .assertEqual('authoritative');
        expect(port.journalState)
          .assertEqual('replayed');
        expect(port.snapshotCleared)
          .assertTrue();
      });

    it('rolls_back_every_precommit_fault_without_publishing_ready_state',
      0, (): void => {
        const faults:
          CompletionFault[] = [
          'begin', 'rebase', 'journal',
          'delete', 'commit'
        ];
        for (let i = 0;
          i < faults.length; i++) {
          const port =
            new FakeVncCompletionPort();
          port.fault = faults[i];
          const store =
            new CloudStore({
              vncAuthoritativeCompletion:
                port
            });
          expect(store
            .completeVncAuthoritativeCloudFirst(
              ['vncrecord']))
            .assertFalse();
          if (faults[i] === 'begin') {
            expect(port.events.indexOf(
              '1:rollback'))
              .assertEqual(-1);
          } else {
            expect(port.events.indexOf(
              '1:rollback') >= 0)
              .assertTrue();
          }
          expect(port
            .generalCheckpointPresent)
            .assertTrue();
          expect(port.vncCheckpointStage)
            .assertEqual('prepared');
          expect(port.journalState)
            .assertEqual('captured');
          expect(port.snapshotCleared)
            .assertFalse();
        }
      });

    it('keeps_committed_authoritative_recovery_model_when_postcommit_readback_errors',
      0, (): void => {
        const port =
          new FakeVncCompletionPort();
        port.readBackError = true;
        const store =
          new CloudStore({
            vncAuthoritativeCompletion:
              port
          });
        expect(store
          .completeVncAuthoritativeCloudFirst(
            ['vncrecord']))
          .assertFalse();
        expect(port.events.indexOf(
          '1:commit') >= 0)
          .assertTrue();
        expect(port.events.indexOf(
          '1:rollback'))
          .assertEqual(-1);
        expect(port
          .generalCheckpointPresent)
          .assertFalse();
        expect(port.vncCheckpointStage)
          .assertEqual('authoritative');
        expect(port.journalState)
          .assertEqual('replayed');
        expect(port.snapshotCleared)
          .assertFalse();
      });

    it('metadata_errors_block_actual_finalization_promotion_and_postcommit_upload',
      0, (): void => {
        const preReadError =
          new FakeVncFinalizationPort();
        preReadError.checkpointStage = {
          state: 'error', value: ''
        };
        const blockedBeforePromotion =
          new CloudStore({
            vncSelectionFinalization:
              preReadError
          });
        expect(blockedBeforePromotion
          .finalizeVncSelectionReenableTransaction())
          .assertFalse();
        expect(preReadError.events.join(','))
          .assertEqual('read_stage');
        expect(preReadError.uploadRequested)
          .assertFalse();

        const checkpointReadError =
          new FakeVncFinalizationPort();
        checkpointReadError
          .checkpointAfter = {
          state: 'error', value: ''
        };
        const blockedAfterCommit =
          new CloudStore({
            vncSelectionFinalization:
              checkpointReadError
          });
        expect(blockedAfterCommit
          .finalizeVncSelectionReenableTransaction())
          .assertFalse();
        expect(checkpointReadError.events
          .indexOf('promote') >= 0)
          .assertTrue();
        expect(checkpointReadError.events
          .indexOf('commit') >= 0)
          .assertTrue();
        expect(checkpointReadError
          .uploadRequested)
          .assertFalse();

        const barrierReadError =
          new FakeVncFinalizationPort();
        barrierReadError.barrierAfter = {
          state: 'error', value: ''
        };
        const blockedBarrierRead =
          new CloudStore({
            vncSelectionFinalization:
              barrierReadError
          });
        expect(blockedBarrierRead
          .finalizeVncSelectionReenableTransaction())
          .assertFalse();
        expect(barrierReadError
          .uploadRequested)
          .assertFalse();
      });
  });
}
