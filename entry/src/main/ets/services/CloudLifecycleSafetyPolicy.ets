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
/**
 * Build-time deployment receipt for the optional Moonlight AGC table.
 *
 * Revision 1 is enabled only after the exact `moonlightrecordv1` schema was
 * created, inspected and explicitly confirmed deployed in the target cloud
 * environment. Local RDB readiness alone is deliberately insufficient:
 * attempting an unknown cloud table could disturb the already-deployed
 * eight-table registration on upgraded devices.
 */
export const MOONLIGHT_CLOUD_SCHEMA_REQUIRED_REVISION: number = 1;
export const MOONLIGHT_CLOUD_SCHEMA_DEPLOYED_REVISION: number = 1;

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

/**
 * A retry is successful only while it still owns the same store/lease and the
 * core cloud baseline remains admitted. Optional-table recovery is allowed to
 * fail independently, but it must never mask a failed legacy-table rebind.
 */
export function cloudRegistrationRetrySucceeded(
  sameStore: boolean,
  leaseCurrent: boolean,
  coreCloudAvailable: boolean
): boolean {
  return sameStore && leaseCurrent && coreCloudAvailable;
}

export function moonlightCloudSchemaProvisioned(
  deployedRevision: number = MOONLIGHT_CLOUD_SCHEMA_DEPLOYED_REVISION
): boolean {
  return Number.isSafeInteger(deployedRevision) &&
    deployedRevision >= MOONLIGHT_CLOUD_SCHEMA_REQUIRED_REVISION;
}

/**
 * An optional table can never be used as proof that the deployed cloud
 * baseline is healthy. Its local schema receipt must be durably readable
 * before the platform registration call is attempted.
 */
export function optionalCloudTableRegistrationAllowed(
  sameStore: boolean,
  leaseCurrent: boolean,
  coreCloudAvailable: boolean,
  schemaReceiptReady: boolean,
  remoteSchemaProvisioned: boolean,
  transferAllowed: boolean
): boolean {
  return sameStore && leaseCurrent && coreCloudAvailable &&
    schemaReceiptReady && remoteSchemaProvisioned && transferAllowed;
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
