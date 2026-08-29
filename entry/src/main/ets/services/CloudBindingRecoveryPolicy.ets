import { PlatformCloudIdentityProofState } from './PlatformCloudIdentityPolicy';

export const CLOUD_BINDING_RECOVERY_PREFERENCES_NAME: string =
  'RemoteDesktopAppPrefs';

export type CloudBindingRecoveryState =
  'idle' | 'permission_pending' | 'binding_pending' | 'blocked';

export type CloudBindingRecoverySourceAuthorityState =
  'absent' | 'recoverable_source' | 'local_source' | 'uncertain';

export interface CloudBindingRecoverySourceAuthority {
  state: CloudBindingRecoverySourceAuthorityState;
  persistedValue: string;
  baselineFingerprint: string;
}

/**
 * Preferences keys are capped, so keep the fixed prefix short while retaining
 * the complete 256-bit owner digest. The stored value is the exact local
 * physical store identity, making the marker owner- and store-scoped.
 */
export function cloudBindingRecoverySourceAuthorityKey(
  ownerScopeId: string
): string {
  const owner: string = ownerScopeId.trim();
  return owner.length === 70 && owner.indexOf('owner-') === 0
    ? 'crsa1:' + owner.substring(6) : '';
}

export function cloudBindingRecoverySourceAuthorityValue(
  localStoreIdentity: string,
  baselineFingerprint: string
): string {
  const store: string = localStoreIdentity.trim();
  return store === '' ? '' : store + '\n' + baselineFingerprint.trim();
}

export function cloudBindingRecoverySourceAuthorityInspect(
  storedValue: string,
  expectedLocalStoreIdentity: string,
  readSucceeded: boolean
): CloudBindingRecoverySourceAuthority {
  if (!readSucceeded) {
    return {
      state: 'uncertain', persistedValue: '', baselineFingerprint: ''
    };
  }
  const stored: string = storedValue.trim();
  if (stored === '') {
    return {
      state: 'absent', persistedValue: '', baselineFingerprint: ''
    };
  }
  const expected: string = expectedLocalStoreIdentity.trim();
  const separator: number = stored.indexOf('\n');
  const storedStore: string = separator < 0
    ? stored : stored.substring(0, separator).trim();
  const baseline: string = separator < 0
    ? '' : stored.substring(separator + 1).trim();
  if (expected === '' || storedStore !== expected) {
    return {
      state: 'uncertain', persistedValue: '', baselineFingerprint: ''
    };
  }
  if (baseline === '') {
    return {
      state: 'local_source',
      persistedValue: cloudBindingRecoverySourceAuthorityValue(expected, ''),
      baselineFingerprint: ''
    };
  }
  if (!/^journal-v[12]:[0-9a-f]{64}$/.test(baseline)) {
    return {
      state: 'uncertain', persistedValue: '', baselineFingerprint: ''
    };
  }
  return {
    state: 'recoverable_source',
    persistedValue:
      cloudBindingRecoverySourceAuthorityValue(expected, baseline),
    baselineFingerprint: baseline
  };
}

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
