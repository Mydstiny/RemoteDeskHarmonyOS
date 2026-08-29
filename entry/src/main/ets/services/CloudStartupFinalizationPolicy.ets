export type CloudStartupFinalizationFailureStep =
  'none' | 'journal_reconcile' | 'checkpoint_clear';

export type CloudStartupSelectionDeferredStep =
  'none' | 'mark_pulled' | 'prepare_promotions' | 'release_barriers';

export interface CloudStartupFinalizationHooks {
  reconcileMutationJournal: () => boolean;
  markSelectionPulled: () => boolean;
  prepareSelectionPromotions: () => boolean;
  clearDownloadCheckpoint: () => boolean;
  releaseSelectionBarriers: () => boolean;
}

export interface CloudStartupFinalizationResult {
  ok: boolean;
  rollbackRequired: boolean;
  failureStep: CloudStartupFinalizationFailureStep;
  deferredSelectionStep: CloudStartupSelectionDeferredStep;
}

function failed(
  step: CloudStartupFinalizationFailureStep
): CloudStartupFinalizationResult {
  return {
    ok: false,
    rollbackRequired: true,
    failureStep: step,
    deferredSelectionStep: 'none'
  };
}

/**
 * Commit an authoritative startup download without letting auxiliary
 * selection metadata erase it. Journal reconciliation and checkpoint clear
 * are transaction boundaries: either failure still requires rollback.
 * Selection promotion is fail-closed instead; its upload barriers remain and
 * a foreground-stable caller can retry it after the downloaded rows commit.
 */
export function finalizeCloudStartupDownload(
  hooks: CloudStartupFinalizationHooks
): CloudStartupFinalizationResult {
  if (!hooks.reconcileMutationJournal()) {
    return failed('journal_reconcile');
  }
  let deferred: CloudStartupSelectionDeferredStep = 'none';
  if (!hooks.markSelectionPulled()) {
    deferred = 'mark_pulled';
  } else if (!hooks.prepareSelectionPromotions()) {
    deferred = 'prepare_promotions';
  }
  // Do not release any upload barrier until the before-image checkpoint is
  // durably cleared. If checkpoint clear fails, rollback remains fail-closed.
  if (!hooks.clearDownloadCheckpoint()) {
    return failed('checkpoint_clear');
  }
  if (deferred === 'none' &&
      !hooks.releaseSelectionBarriers()) {
    deferred = 'release_barriers';
  }
  return {
    ok: true,
    rollbackRequired: false,
    failureStep: 'none',
    deferredSelectionStep: deferred
  };
}
