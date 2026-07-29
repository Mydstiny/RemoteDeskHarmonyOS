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
}

export const CLOUD_LIFECYCLE_V2_ROLLOUT_ENABLED: boolean = true;
export const REMOTE_CRYPTO_LIFECYCLE_V2_ENABLED: boolean = false;
export const PORTABLE_BACKUP_V3_WRITE_ENABLED: boolean = true;
export const LEGACY_CLOUD_REST_TRANSFER_ENABLED: boolean = false;

export const CLOUD_LIFECYCLE_BLOCKED_REASON: string =
  'cloud_lifecycle_v2_account_binding_required';

export function unboundCloudAccountBinding(): CloudAccountBinding {
  return {
    state: 'unbound',
    ownerScopeId: '',
    storeIdentity: '',
    generation: 0
  };
}

export function cloudAccountBindingIsValid(binding: CloudAccountBinding): boolean {
  return binding.state === 'bound' &&
    binding.ownerScopeId.trim().length > 0 &&
    binding.storeIdentity.trim().length > 0 &&
    binding.generation > 0;
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
