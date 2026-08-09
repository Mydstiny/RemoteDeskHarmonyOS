/**
 * Temporary rollout boundary for the account-scoped cloud/data lifecycle.
 *
 * These switches deliberately fail closed.  They may only be enabled after
 * the account session coordinator can prove the owner, physical store and
 * generation which will receive every cloud callback.
 */
export type CloudAccountBindingState = 'unbound' | 'validating' | 'bound' | 'blocked';

export interface CloudAccountBinding {
  state: CloudAccountBindingState;
  ownerScopeId: string;
  storeIdentity: string;
  generation: number;
  platformIdentityFingerprint: string;
}

export const CLOUD_LIFECYCLE_V2_ROLLOUT_ENABLED: boolean = true;
export const REMOTE_CRYPTO_LIFECYCLE_V2_ENABLED: boolean = false;
export const PORTABLE_BACKUP_V3_WRITE_ENABLED: boolean = true;
export const LEGACY_CLOUD_REST_TRANSFER_ENABLED: boolean = false;
export const CLOUD_REGISTRATION_RETRY_INTERVAL_MS: number = 15000;

export const CLOUD_LIFECYCLE_BLOCKED_REASON: string =
  'cloud_lifecycle_v2_account_binding_required';

export function unboundCloudAccountBinding(): CloudAccountBinding {
  return {
    state: 'unbound',
    ownerScopeId: '',
    storeIdentity: '',
    generation: 0,
    platformIdentityFingerprint: ''
  };
}

export function cloudAccountBindingIsValid(binding: CloudAccountBinding): boolean {
  return binding.state === 'bound' &&
    binding.ownerScopeId.trim().length > 0 &&
    binding.storeIdentity.trim().length > 0 &&
    binding.generation > 0 &&
    binding.platformIdentityFingerprint.trim().length === 64;
}

export function cloudDistributedRegistrationAllowed(
  binding: CloudAccountBinding,
  rolloutEnabled: boolean = CLOUD_LIFECYCLE_V2_ROLLOUT_ENABLED
): boolean {
  return rolloutEnabled && cloudAccountBindingIsValid(binding);
}

export function cloudTransferAllowed(
  binding: CloudAccountBinding,
  rolloutEnabled: boolean = CLOUD_LIFECYCLE_V2_ROLLOUT_ENABLED
): boolean {
  return cloudDistributedRegistrationAllowed(binding, rolloutEnabled);
}

/**
 * A transient setDistributedTables failure must not remain sticky until the
 * next process restart. Retry only for the same fully-bound account store,
 * never while another registration attempt is running or on every render.
 */
export function cloudRegistrationRetryAllowed(
  initialized: boolean,
  hasStore: boolean,
  hasLease: boolean,
  binding: CloudAccountBinding,
  cloudAvailable: boolean,
  retryInFlight: boolean,
  nowMs: number,
  lastAttemptAtMs: number,
  minimumIntervalMs: number = CLOUD_REGISTRATION_RETRY_INTERVAL_MS
): boolean {
  if (!initialized || !hasStore || !hasLease || cloudAvailable ||
    retryInFlight || !cloudDistributedRegistrationAllowed(binding)) {
    return false;
  }
  if (lastAttemptAtMs <= 0) { return true; }
  return nowMs >= lastAttemptAtMs &&
    nowMs - lastAttemptAtMs >= Math.max(0, minimumIntervalMs);
}

export function remoteCryptoLifecycleMutationAllowed(
  rolloutEnabled: boolean = REMOTE_CRYPTO_LIFECYCLE_V2_ENABLED
): boolean {
  return rolloutEnabled;
}

export function portableBackupExportAllowed(
  rolloutEnabled: boolean = PORTABLE_BACKUP_V3_WRITE_ENABLED
): boolean {
  return rolloutEnabled;
}

export function portableBackupRestoreAllowed(
  rolloutEnabled: boolean = PORTABLE_BACKUP_V3_WRITE_ENABLED
): boolean {
  return rolloutEnabled;
}

export function legacyCloudRestTransferAllowed(
  rolloutEnabled: boolean = LEGACY_CLOUD_REST_TRANSFER_ENABLED
): boolean {
  return rolloutEnabled;
}
