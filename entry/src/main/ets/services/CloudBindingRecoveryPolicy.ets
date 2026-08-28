import { PlatformCloudIdentityProofState } from './PlatformCloudIdentityPolicy';

export type CloudBindingRecoveryState =
  'idle' | 'permission_pending' | 'binding_pending' | 'blocked';

export function cloudBindingRecoveryRequested(
  proofState: PlatformCloudIdentityProofState,
  cloudBound: boolean
): CloudBindingRecoveryState {
  return !cloudBound &&
    (proofState === 'permission_dialog_blocked' ||
      proofState === 'permission_unavailable')
    ? 'permission_pending' : 'idle';
}

export function cloudBindingRecoveryAfterProof(
  proofState: PlatformCloudIdentityProofState
): CloudBindingRecoveryState {
  if (proofState === 'verified') { return 'binding_pending'; }
  if (proofState === 'permission_unavailable') {
    return 'permission_pending';
  }
  if (proofState === 'permission_dialog_blocked') {
    return 'permission_pending';
  }
  return 'blocked';
}

export function cloudBindingRecoveryAfterRollback(
  restored: boolean,
  retryable: boolean
): CloudBindingRecoveryState {
  return restored && retryable ? 'binding_pending' : 'blocked';
}

export function cloudBindingRecoveryIsPending(
  state: CloudBindingRecoveryState
): boolean {
  return state === 'permission_pending' ||
    state === 'binding_pending';
}

export function cloudBindingRecoveryRepeatedDialogBlocked(
  previousProofState: PlatformCloudIdentityProofState,
  nextProofState: PlatformCloudIdentityProofState
): boolean {
  return previousProofState === 'permission_dialog_blocked' &&
    nextProofState === 'permission_dialog_blocked';
}
