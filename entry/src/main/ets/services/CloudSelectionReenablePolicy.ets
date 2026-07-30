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
