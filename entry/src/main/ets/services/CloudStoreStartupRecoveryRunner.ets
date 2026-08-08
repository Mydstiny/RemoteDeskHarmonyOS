import {
  VNC_SELECTION_REENABLE_TRANSACTION_KEY,
  CloudStoreVncRollbackPort,
  VncSelectionBarrierPhaseRead,
  VncSelectionCheckpointIdentity,
  VncSelectionReenableCheckpoint,
  readVncSelectionBarrierPhase,
  recoverPendingVncSelectionReenable,
  rollbackVncSelectionCheckpoint
} from './CloudStoreVncLifecycleWiring';
import {
  CloudMetadataReadResult,
  cloudMetadataAbsentProven
} from './CloudMetadataSafetyPolicy';
import {
  CloudSelectionReenablePhase
} from './CloudSelectionReenablePolicy';
import {
  VNC_CLOUD_TABLE
} from './VncRecordPolicy';
import {
  CLOUD_BOOTSTRAP_COMPLETED_KEY
} from './CloudStoreRestoreResolutionWiring';

/**
 * Bottom-level startup persistence boundary. It deliberately exposes no
 * CloudStore singleton, RDB handle or arbitrary mutation method. Production
 * supplies closures over its private store; an isolated wiring test supplies
 * an in-memory implementation and still traverses CloudStore.init.
 */
export interface CloudStoreStartupRecoveryIo {
  checkpointIdentity:
    () => VncSelectionCheckpointIdentity;
  readMetadataState:
    (key: string) => CloudMetadataReadResult;
  recoveryMetadata:
    (checkpoint: VncSelectionReenableCheckpoint) =>
      Array<Record<string, string>>;
  restoreManualDownloadSnapshot: (
    snapshot:
      Record<string,
        Array<Record<string, string>>>,
    extensions:
      Array<Record<string, string>>,
    metadata:
      Array<Record<string, string>>,
    mutationJournal:
      Array<Record<string, string>>,
    localTables:
      Record<string,
        Array<Record<string, string>>>
  ) => Promise<boolean>;
  stageSelectedScopes:
    (scopes: string[]) => void;
  persistSelectedScopes: () => boolean;
  beginTransaction: () => boolean;
  settleRecoveryLifecycle: () => boolean;
  restoreSelectionReenableBarrier: (
    table: string,
    previousPhase:
      CloudSelectionReenablePhase | null,
    verify?: boolean
  ) => boolean;
  deleteLocalMetadata:
    (key: string) => boolean;
  commit: () => boolean;
  rollback: () => void;
  publishSnapshot: () => void;
  markRecoveryRequired: () => void;
  onRecovered: () => void;
}

/**
 * The one startup-only adapter from CloudStore's private persistence
 * primitives to the VNC recovery state machine. Keeping checkpoint payload
 * projection and metadata-key/table routing here makes the production wiring
 * itself executable by the initialization contract test.
 */
export class CloudStoreStartupRecoveryRunner {
  private readonly io:
    CloudStoreStartupRecoveryIo;

  constructor(io: CloudStoreStartupRecoveryIo) {
    this.io = io;
  }

  async recoverPending(): Promise<boolean> {
    return await recoverPendingVncSelectionReenable(
      this.io.checkpointIdentity(),
      this.rollbackPort(),
      (): void => {
        this.io.onRecovered();
      });
  }

  /**
   * Retire a checkpoint created by the removed per-record-type VNC selector.
   * No data snapshot is restored: the existing rows are preserved and a
   * physical-table `pending_pull` barrier requires one authoritative cloud
   * read before VNC upload can resume.
   *
   * Lifecycle settlement deliberately runs after the RDB commit. HarmonyOS
   * RDB does not expose transaction-local metadata to a synchronous read-back,
   * so the old ordering could falsely fail recovery and block account login.
   */
  retireLegacySelectionCheckpoint(): boolean {
    const checkpointBefore:
      CloudMetadataReadResult =
      this.io.readMetadataState(
        VNC_SELECTION_REENABLE_TRANSACTION_KEY);
    if (checkpointBefore.state === 'error') {
      this.io.markRecoveryRequired();
      return false;
    }
    if (checkpointBefore.state === 'absent') {
      // A previous process may have committed checkpoint retirement but died
      // before settling the VNC-only durable recovery marker.
      return this.io.settleRecoveryLifecycle();
    }

    let begun: boolean = false;
    try {
      if (!this.io.beginTransaction()) {
        throw new Error(
          'legacy VNC checkpoint retirement begin failed');
      }
      begun = true;
      if (!this.io.restoreSelectionReenableBarrier(
        VNC_CLOUD_TABLE, 'pending_pull', false) ||
        !this.io.deleteLocalMetadata(
          VNC_SELECTION_REENABLE_TRANSACTION_KEY) ||
        !this.io.deleteLocalMetadata(
          CLOUD_BOOTSTRAP_COMPLETED_KEY) ||
        !this.io.commit()) {
        throw new Error(
          'legacy VNC checkpoint retirement failed');
      }
      begun = false;

      const checkpointAfter:
        CloudMetadataReadResult =
        this.io.readMetadataState(
          VNC_SELECTION_REENABLE_TRANSACTION_KEY);
      const barrierAfter:
        VncSelectionBarrierPhaseRead =
        readVncSelectionBarrierPhase(
          (key: string): CloudMetadataReadResult =>
            this.io.readMetadataState(key));
      const bootstrapAfter:
        CloudMetadataReadResult =
        this.io.readMetadataState(
          CLOUD_BOOTSTRAP_COMPLETED_KEY);
      if (!cloudMetadataAbsentProven(
        checkpointAfter) ||
        !cloudMetadataAbsentProven(
          bootstrapAfter) ||
        !barrierAfter.readable ||
        barrierAfter.phase !== 'pending_pull' ||
        !this.io.settleRecoveryLifecycle()) {
        throw new Error(
          'legacy VNC checkpoint retirement verification failed');
      }
      this.io.publishSnapshot();
      this.io.onRecovered();
      return true;
    } catch (_error) {
      if (begun) {
        try { this.io.rollback(); } catch (_ignored) {}
      }
      this.io.markRecoveryRequired();
      return false;
    }
  }

  async rollbackCheckpoint(
    checkpoint: VncSelectionReenableCheckpoint
  ): Promise<boolean> {
    return await rollbackVncSelectionCheckpoint(
      checkpoint,
      this.rollbackPort());
  }

  private rollbackPort():
    CloudStoreVncRollbackPort {
    const io:
      CloudStoreStartupRecoveryIo =
      this.io;
    return {
      readMetadataState:
        (key: string):
          CloudMetadataReadResult =>
          io.readMetadataState(key),
      restoreSnapshot: async (
        checkpoint:
          VncSelectionReenableCheckpoint
      ): Promise<boolean> => {
        const payload = checkpoint.payload;
        return await io
          .restoreManualDownloadSnapshot(
            payload.snapshot,
            payload.extensions,
            io.recoveryMetadata(checkpoint),
            payload.mutationJournal,
            payload.localTables);
      },
      persistPreviousScopes:
        (scopes: string[]): boolean => {
          io.stageSelectedScopes(scopes);
          return io.persistSelectedScopes();
        },
      beginTransaction: (): boolean =>
        io.beginTransaction(),
      settleRecoveryLifecycle: (): boolean =>
        io.settleRecoveryLifecycle(),
      restoreBarrier: (
        previousPhase:
          CloudSelectionReenablePhase | null
      ): boolean =>
        io.restoreSelectionReenableBarrier(
          VNC_CLOUD_TABLE,
          previousPhase, false),
      deleteCheckpoint: (): boolean =>
        io.deleteLocalMetadata(
          VNC_SELECTION_REENABLE_TRANSACTION_KEY),
      commit: (): boolean =>
        io.commit(),
      rollback: (): void => {
        io.rollback();
      },
      publishSnapshot: (): void => {
        io.publishSnapshot();
      },
      markRecoveryRequired: (): void => {
        io.markRecoveryRequired();
      }
    };
  }
}
