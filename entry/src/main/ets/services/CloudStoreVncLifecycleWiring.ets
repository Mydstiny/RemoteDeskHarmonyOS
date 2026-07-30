import {
  CloudDownloadTransactionEnvelope,
  CloudDownloadTransactionOperation,
  parseCloudDownloadTransactionEnvelope
} from './CloudDownloadTransactionPolicy';
import {
  CloudMetadataReadResult,
  cloudMetadataAbsentProven
} from './CloudMetadataSafetyPolicy';
import {
  CloudSelectionReenablePhase,
  VncAuthoritativeCompletionResult,
  VncSelectionFinalizeResult,
  executeVncAuthoritativeCompletion,
  executeVncSelectionFinalize,
  normalizeCloudSelectionReenablePhase,
  vncSelectionPostCommitUploadAllowed
} from './CloudSelectionReenablePolicy';
import { VNC_CLOUD_TABLE } from './VncRecordPolicy';

export const CLOUD_DOWNLOAD_TRANSACTION_KEY: string =
  'cloud_download_transaction_v1';
export const VNC_SELECTION_REENABLE_TRANSACTION_KEY:
  string = 'vnc_selection_reenable_transaction_v1';
export const CLOUD_SELECTION_REENABLE_BARRIERS_KEY:
  string = 'cloud_selection_reenable_barriers_v1';

export interface CloudDownloadTransactionPayload {
  snapshot:
    Record<string, Array<Record<string, string>>>;
  extensions: Array<Record<string, string>>;
  metadata: Array<Record<string, string>>;
  mutationJournal: Array<Record<string, string>>;
  localTables:
    Record<string, Array<Record<string, string>>>;
}

export interface VncSelectionReenableTransactionPayload
  extends CloudDownloadTransactionPayload {
  stage: string;
  previousScopes: string[];
  previousBarrier: string;
  settingsId: string;
}

export interface VncSelectionReenableCheckpoint {
  raw: string;
  envelope: CloudDownloadTransactionEnvelope;
  payload: VncSelectionReenableTransactionPayload;
}

export interface VncSelectionReenableCheckpointRead {
  metadata: CloudMetadataReadResult;
  checkpoint:
    VncSelectionReenableCheckpoint | null;
}

export interface VncSelectionCheckpointIdentity {
  ownerScopeId: string;
  storeIdentity: string;
  generation: number;
}

export type CloudStoreMetadataStateReader =
  (key: string) => CloudMetadataReadResult;

export interface VncSelectionBarrierPhaseRead {
  metadata: CloudMetadataReadResult;
  readable: boolean;
  phase: CloudSelectionReenablePhase | null;
}

/**
 * This parser is shared by startup recovery, cloud-first completion and
 * finalization. A metadata I/O error can therefore never be reinterpreted by
 * one adapter as an absent checkpoint.
 */
export function readVncSelectionReenableCheckpointState(
  readMetadataState: CloudStoreMetadataStateReader,
  identity: VncSelectionCheckpointIdentity
): VncSelectionReenableCheckpointRead {
  const metadata: CloudMetadataReadResult =
    readMetadataState(
      VNC_SELECTION_REENABLE_TRANSACTION_KEY);
  if (metadata.state !== 'present') {
    return { metadata, checkpoint: null };
  }
  const envelope:
    CloudDownloadTransactionEnvelope | null =
    parseCloudDownloadTransactionEnvelope(
      metadata.value,
      identity.ownerScopeId,
      identity.storeIdentity,
      identity.generation);
  if (envelope === null ||
    envelope.operation !==
      'vnc_scope_reenable') {
    return { metadata, checkpoint: null };
  }
  try {
    const payload:
      VncSelectionReenableTransactionPayload =
      JSON.parse(envelope.payloadJson) as
        VncSelectionReenableTransactionPayload;
    if ((payload.stage !== 'prepared' &&
      payload.stage !== 'authoritative') ||
      !Array.isArray(payload.previousScopes) ||
      payload.settingsId.trim() === '' ||
      (payload.previousBarrier !== '' &&
        normalizeCloudSelectionReenablePhase(
          payload.previousBarrier) === null)) {
      return { metadata, checkpoint: null };
    }
    for (let i = 0;
      i < payload.previousScopes.length; i++) {
      if (typeof payload.previousScopes[i] !==
        'string') {
        return { metadata, checkpoint: null };
      }
    }
    return {
      metadata,
      checkpoint: {
        raw: metadata.value,
        envelope,
        payload
      }
    };
  } catch (_error) {
    return { metadata, checkpoint: null };
  }
}

/**
 * Read the exact persisted VNC barrier through the same metadata reader used
 * by CloudStore. Invalid JSON and query errors are distinct from an absent
 * barrier and both fail closed.
 */
export function readVncSelectionBarrierPhase(
  readMetadataState: CloudStoreMetadataStateReader
): VncSelectionBarrierPhaseRead {
  const metadata: CloudMetadataReadResult =
    readMetadataState(
      CLOUD_SELECTION_REENABLE_BARRIERS_KEY);
  if (metadata.state === 'error') {
    return {
      metadata,
      readable: false,
      phase: 'pending_pull'
    };
  }
  if (metadata.state === 'absent') {
    return {
      metadata,
      readable: true,
      phase: null
    };
  }
  try {
    const parsed: Record<string, Object> =
      JSON.parse(metadata.value) as
        Record<string, Object>;
    return {
      metadata,
      readable: true,
      phase:
        normalizeCloudSelectionReenablePhase(
          parsed[VNC_CLOUD_TABLE])
    };
  } catch (_error) {
    return {
      metadata,
      readable: false,
      phase: 'pending_pull'
    };
  }
}

/**
 * Pure orchestration boundary. It owns no CloudStore singleton or RDB handle;
 * the private CloudStore entry supplies the live transactional closures.
 */
export interface CloudStoreVncAuthoritativeCompletionPort {
  activeOperation:
    () => CloudDownloadTransactionOperation | null;
  checkpointIdentity:
    () => VncSelectionCheckpointIdentity;
  readMetadataState:
    CloudStoreMetadataStateReader;
  beginTransaction: () => boolean;
  rebaseAuthoritativeCheckpoint:
    () => boolean;
  reconcileJournal:
    (tables: string[]) => boolean;
  deleteDownloadCheckpoint:
    () => boolean;
  commit: () => boolean;
  rollback: () => void;
  clearInMemorySnapshot: () => void;
}

export interface VncAuthoritativeCompletionWiringResult {
  ok: boolean;
  transaction: VncAuthoritativeCompletionResult;
}

export function completeVncAuthoritativeCloudFirst(
  tables: string[],
  port: CloudStoreVncAuthoritativeCompletionPort
): VncAuthoritativeCompletionWiringResult {
  const rejected:
    VncAuthoritativeCompletionWiringResult = {
    ok: false,
    transaction: {
      ok: false,
      failedStep: 'begin'
    }
  };
  if (port.activeOperation() !==
      'selection_reenable' ||
    tables.indexOf(VNC_CLOUD_TABLE) < 0) {
    return rejected;
  }
  const completed:
    VncAuthoritativeCompletionResult =
    executeVncAuthoritativeCompletion({
      begin: (): boolean =>
        port.beginTransaction(),
      rebaseAuthoritativeCheckpoint:
        (): boolean =>
          port
            .rebaseAuthoritativeCheckpoint(),
      reconcileJournal: (): boolean =>
        port.reconcileJournal(tables),
      deleteDownloadCheckpoint: (): boolean =>
        port.deleteDownloadCheckpoint(),
      commit: (): boolean =>
        port.commit(),
      rollback: (): void =>
        port.rollback()
    });
  if (!completed.ok) {
    return {
      ok: false,
      transaction: completed
    };
  }
  const downloadCheckpoint:
    CloudMetadataReadResult =
    port.readMetadataState(
      CLOUD_DOWNLOAD_TRANSACTION_KEY);
  const vncCheckpoint:
    VncSelectionReenableCheckpointRead =
    readVncSelectionReenableCheckpointState(
      port.readMetadataState,
      port.checkpointIdentity());
  if (!cloudMetadataAbsentProven(
    downloadCheckpoint) ||
    vncCheckpoint.metadata.state !==
      'present' ||
    vncCheckpoint.checkpoint === null ||
    vncCheckpoint.checkpoint.payload.stage !==
      'authoritative') {
    return {
      ok: false,
      transaction: completed
    };
  }
  port.clearInMemorySnapshot();
  return {
    ok: true,
    transaction: completed
  };
}

export interface CloudStoreVncSelectionFinalizationPort {
  checkpointIdentity:
    () => VncSelectionCheckpointIdentity;
  readMetadataState:
    CloudStoreMetadataStateReader;
  preparePromotion: () => boolean;
  beginTransaction: () => boolean;
  persistPullComplete: () => boolean;
  promote: () => boolean;
  persistPromotionComplete:
    () => boolean;
  releaseBarrier: () => boolean;
  deleteCheckpoint: () => boolean;
  commit: () => boolean;
  rollback: () => void;
  requestAutomaticUpload: () => void;
}

export interface VncSelectionFinalizationWiringResult {
  ok: boolean;
  transaction: VncSelectionFinalizeResult;
}

export function finalizeVncSelectionReenable(
  port: CloudStoreVncSelectionFinalizationPort
): VncSelectionFinalizationWiringResult {
  const rejected:
    VncSelectionFinalizationWiringResult = {
    ok: false,
    transaction: {
      ok: false,
      failedStep: 'begin'
    }
  };
  const checkpoint:
    VncSelectionReenableCheckpointRead =
    readVncSelectionReenableCheckpointState(
      port.readMetadataState,
      port.checkpointIdentity());
  if (checkpoint.metadata.state !==
      'present' ||
    checkpoint.checkpoint === null ||
    checkpoint.checkpoint.payload.stage !==
      'authoritative') {
    return rejected;
  }
  const barrierBefore:
    VncSelectionBarrierPhaseRead =
    readVncSelectionBarrierPhase(
      port.readMetadataState);
  if (!barrierBefore.readable ||
    barrierBefore.phase !== 'pending_pull' ||
    !port.preparePromotion()) {
    return rejected;
  }
  const finalized: VncSelectionFinalizeResult =
    executeVncSelectionFinalize({
      begin: (): boolean =>
        port.beginTransaction(),
      persistPullComplete: (): boolean =>
        port.persistPullComplete(),
      promote: (): boolean =>
        port.promote(),
      persistPromotionComplete: (): boolean =>
        port.persistPromotionComplete(),
      releaseBarrier: (): boolean =>
        port.releaseBarrier(),
      deleteCheckpoint: (): boolean =>
        port.deleteCheckpoint(),
      commit: (): boolean =>
        port.commit(),
      rollback: (): void =>
        port.rollback()
    });
  const checkpointAfter:
    VncSelectionReenableCheckpointRead =
    readVncSelectionReenableCheckpointState(
      port.readMetadataState,
      port.checkpointIdentity());
  const barrierAfter:
    VncSelectionBarrierPhaseRead =
    readVncSelectionBarrierPhase(
      port.readMetadataState);
  const uploadAllowed: boolean =
    vncSelectionPostCommitUploadAllowed(
      finalized,
      !cloudMetadataAbsentProven(
        checkpointAfter.metadata),
      barrierAfter.readable
        ? barrierAfter.phase
        : 'pending_pull');
  if (uploadAllowed) {
    port.requestAutomaticUpload();
  }
  return {
    ok: uploadAllowed,
    transaction: finalized
  };
}

export interface CloudStoreVncPendingRecoveryPort {
  checkpointIdentity:
    () => VncSelectionCheckpointIdentity;
  readMetadataState:
    CloudStoreMetadataStateReader;
  rollbackCheckpoint:
    (checkpoint:
      VncSelectionReenableCheckpoint) =>
      Promise<boolean>;
  recovered: () => void;
}

/**
 * Startup calls this collaborator before cloud registration. A committed
 * authoritative checkpoint is treated as pending recovery, not as a completed
 * finalization, and is passed to the real rollback path.
 */
export async function recoverPendingVncSelectionReenable(
  port: CloudStoreVncPendingRecoveryPort
): Promise<boolean> {
  const checkpointRead:
    VncSelectionReenableCheckpointRead =
    readVncSelectionReenableCheckpointState(
      port.readMetadataState,
      port.checkpointIdentity());
  if (checkpointRead.metadata.state ===
    'absent') {
    return true;
  }
  if (checkpointRead.metadata.state ===
      'error' ||
    checkpointRead.checkpoint === null) {
    return false;
  }
  const recovered: boolean =
    await port.rollbackCheckpoint(
      checkpointRead.checkpoint);
  if (recovered) {
    port.recovered();
  }
  return recovered;
}
