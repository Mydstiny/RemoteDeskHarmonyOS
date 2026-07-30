export type CloudSelectionReenablePhase =
  'pending_pull' | 'pull_complete' |
  'promotion_complete';

export function normalizeCloudSelectionReenablePhase(
  value: Object | undefined
): CloudSelectionReenablePhase | null {
  if (value === 'pending_pull' ||
    value === 'pull_complete' ||
    value === 'promotion_complete') {
    return value as CloudSelectionReenablePhase;
  }
  return null;
}

export function cloudSelectionAfterAuthoritativePull(
  phase: CloudSelectionReenablePhase
): CloudSelectionReenablePhase {
  return phase === 'pending_pull'
    ? 'pull_complete' : phase;
}

export function cloudSelectionAfterLocalPromotion(
  phase: CloudSelectionReenablePhase
): CloudSelectionReenablePhase {
  return phase === 'pull_complete'
    ? 'promotion_complete' : phase;
}

export function cloudSelectionNativeFirstAllowed(
  phase: CloudSelectionReenablePhase | null
): boolean {
  return phase === null;
}

export function cloudSelectionLocalPromotionAllowed(
  allowBarrierPromotion: boolean,
  localMutationAllowed: boolean
): boolean {
  return allowBarrierPromotion ||
    localMutationAllowed;
}

export function cloudSelectionTransitionNeedsCloudFirst(
  previousSelection: string[],
  nextSelection: string[],
  physicalTableSelected: boolean
): boolean {
  if (!physicalTableSelected) { return false; }
  for (let i = 0; i < nextSelection.length; i++) {
    if (previousSelection.indexOf(
      nextSelection[i]) < 0) {
      return true;
    }
  }
  return false;
}

export function cloudSelectionBarrierAfterRollback(
  previousPhase: CloudSelectionReenablePhase | null
): CloudSelectionReenablePhase | null {
  return previousPhase;
}

export type VncSelectionFinalizeStep =
  'begin' | 'pull_phase' | 'promotion' |
  'promotion_phase' | 'release' |
  'checkpoint_delete' | 'commit' | 'none';

export interface VncSelectionFinalizeHooks {
  begin: () => boolean;
  persistPullComplete: () => boolean;
  promote: () => boolean;
  persistPromotionComplete: () => boolean;
  releaseBarrier: () => boolean;
  deleteCheckpoint: () => boolean;
  commit: () => boolean;
  rollback: () => void;
}

export interface VncSelectionFinalizeResult {
  ok: boolean;
  failedStep: VncSelectionFinalizeStep;
}

/**
 * Every durable finalization step executes inside one caller-owned RDB
 * transaction. No upload is part of this sequence; it is permitted only
 * after `commit` succeeds and the checkpoint/barrier are both absent.
 */
export function executeVncSelectionFinalize(
  hooks: VncSelectionFinalizeHooks
): VncSelectionFinalizeResult {
  let begun: boolean = false;
  let failedStep: VncSelectionFinalizeStep =
    'begin';
  try {
    if (!hooks.begin()) {
      return { ok: false, failedStep };
    }
    begun = true;
    failedStep = 'pull_phase';
    if (!hooks.persistPullComplete()) {
      throw new Error('pull phase persistence failed');
    }
    failedStep = 'promotion';
    if (!hooks.promote()) {
      throw new Error('promotion failed');
    }
    failedStep = 'promotion_phase';
    if (!hooks.persistPromotionComplete()) {
      throw new Error(
        'promotion phase persistence failed');
    }
    failedStep = 'release';
    if (!hooks.releaseBarrier()) {
      throw new Error('barrier release failed');
    }
    failedStep = 'checkpoint_delete';
    if (!hooks.deleteCheckpoint()) {
      throw new Error('checkpoint delete failed');
    }
    failedStep = 'commit';
    if (!hooks.commit()) {
      throw new Error('transaction commit failed');
    }
    return { ok: true, failedStep: 'none' };
  } catch (_error) {
    if (begun) {
      try { hooks.rollback(); } catch (_ignored) {}
    }
    return { ok: false, failedStep };
  }
}

export interface VncSettingsRollbackRows {
  cloudRows: Array<Record<string, string>>;
  localRows: Array<Record<string, string>>;
}

function cloneRows(
  rows: Array<Record<string, string>>
): Array<Record<string, string>> {
  const result: Array<Record<string, string>> = [];
  for (let i = 0; i < rows.length; i++) {
    const copy: Record<string, string> = {};
    const keys: string[] = Object.keys(rows[i]);
    for (let k = 0; k < keys.length; k++) {
      copy[keys[k]] = rows[i][keys[k]];
    }
    result.push(copy);
  }
  return result;
}

/**
 * A failed settings save keeps the cloud-first authoritative mirror exactly
 * as pulled. Only the device-local settings row is restored to its pre-save
 * image; a deterministic settings id is never guessed to be newly created.
 */
export function vncSettingsRollbackRows(
  authoritativeCloudRows:
    Array<Record<string, string>>,
  currentLocalRows:
    Array<Record<string, string>>,
  originalLocalRows:
    Array<Record<string, string>>,
  settingsId: string
): VncSettingsRollbackRows {
  const localRows: Array<Record<string, string>> =
    cloneRows(currentLocalRows).filter(
      (row: Record<string, string>): boolean =>
        row['id'] !== settingsId);
  const original = originalLocalRows.find(
    (row: Record<string, string>): boolean =>
      row['id'] === settingsId);
  if (original !== undefined) {
    localRows.push(cloneRows([original])[0]);
  }
  localRows.sort((
    left: Record<string, string>,
    right: Record<string, string>
  ): number =>
    (left['id'] || '').localeCompare(
      right['id'] || ''));
  return {
    cloudRows: cloneRows(
      authoritativeCloudRows),
    localRows
  };
}

export function vncSettingsRollbackJournal(
  currentRows: Array<Record<string, string>>,
  originalRows: Array<Record<string, string>>,
  settingsId: string,
  vncCloudTable: string,
  vncLocalTable: string
): Array<Record<string, string>> {
  const relevant = (
    row: Record<string, string>
  ): boolean =>
    row['recordid'] === settingsId &&
    (row['tablename'] === vncCloudTable ||
      row['tablename'] === vncLocalTable);
  const result: Array<Record<string, string>> =
    cloneRows(currentRows).filter(
      (row: Record<string, string>): boolean =>
        !relevant(row));
  const originals =
    cloneRows(originalRows).filter(relevant);
  for (let i = 0; i < originals.length; i++) {
    result.push(originals[i]);
  }
  result.sort((
    left: Record<string, string>,
    right: Record<string, string>
  ): number =>
    (left['id'] || '').localeCompare(
      right['id'] || ''));
  return result;
}

export function vncSelectionRecoveryBarrier(
  checkpointPresent: boolean,
  previousPhase: CloudSelectionReenablePhase | null
): CloudSelectionReenablePhase | null {
  return checkpointPresent
    ? 'pending_pull' : previousPhase;
}

export function vncSelectionPostCommitUploadAllowed(
  finalized: VncSelectionFinalizeResult,
  checkpointPresent: boolean,
  barrierPhase: CloudSelectionReenablePhase | null
): boolean {
  return finalized.ok &&
    !checkpointPresent &&
    barrierPhase === null;
}
