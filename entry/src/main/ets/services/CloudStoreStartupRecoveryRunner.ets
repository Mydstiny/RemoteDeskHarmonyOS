import {
  VNC_SELECTION_REENABLE_TRANSACTION_KEY,
  CloudStoreVncRollbackPort,
  VncSelectionCheckpointIdentity,
  VncSelectionReenableCheckpoint,
  recoverPendingVncSelectionReenable,
  rollbackVncSelectionCheckpoint
} from './CloudStoreVncLifecycleWiring';
import {
  CloudMetadataReadResult
} from './CloudMetadataSafetyPolicy';
import {
  CloudSelectionReenablePhase
} from './CloudSelectionReenablePolicy';
import {
  VNC_CLOUD_TABLE
} from './VncRecordPolicy';

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
