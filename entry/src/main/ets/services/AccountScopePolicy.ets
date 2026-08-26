import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import {
  CloudAccountBinding,
  CloudAccountBindingState
} from './CloudLifecycleSafetyPolicy';
import {
  PlatformCloudIdentityProof,
  platformCloudIdentityProofIsValid,
  unavailablePlatformCloudIdentityProof
} from './PlatformCloudIdentityPolicy';

export type AccountScopeKind = 'device_local' | 'huawei_account';
export type AccountSessionState =
  'offline' | 'authenticating' | 'switching' | 'bound' | 'ready' | 'locked' | 'blocked';

export interface AccountScopeToken {
  kind: AccountScopeKind;
  ownerScopeId: string;
  generation: number;
  sessionState: AccountSessionState;
  cloudBindingState: CloudAccountBindingState;
  storeIdentity: string;
  schemaRevision: number;
  selectionRevision: number;
  platformIdentityFingerprint: string;
}

/**
 * Immutable capability captured by every asynchronous store operation.
 * storeInstanceId distinguishes two opens of the same physical database,
 * while generation distinguishes account-session transitions.
 */
export interface AccountSessionLease {
  ownerScopeId: string;
  storeIdentity: string;
  generation: number;
  storeInstanceId: number;
}

const DEVICE_LOCAL_OWNER_SCOPE_ID: string = 'device-local';
const DEVICE_LOCAL_STORE_IDENTITY: string = 'remotedesktop_device_local.db';
/**
 * Platform cloud binding requires the RDB store id (StoreConfig.name without
 * the ".db" suffix) to equal the AGC cloud schema database.name. The AGC cloud
 * database for this bundle is deployed under the canonical name `remotedesktop`,
 * so every cloud-capable (verified) account scope must open exactly this store.
 * Per-account hashed store names (`remotedesktop_owner-<sha>.db`) are therefore
 * LOCAL-ONLY: they can never register distributed cloud tables (14800000) and
 * are used only while the platform cloud identity cannot be verified.
 */
export const ACCOUNT_CLOUD_STORE_IDENTITY: string = 'remotedesktop.db';

function sha256Hex(value: string): string {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: new util.TextEncoder().encode(value) });
  const bytes: Uint8Array = md.digestSync().data;
  let hex: string = '';
  for (let i = 0; i < bytes.length; i++) {
    hex += bytes[i].toString(16).padStart(2, '0');
  }
  return hex;
}

export function cryptoParamCloudRecordId(
  ownerScopeId: string,
  key: string
): string {
  const owner: string = ownerScopeId.trim();
  const logicalKey: string = key.trim();
  if (owner.length === 0 || logicalKey.length === 0) { return ''; }
  return sha256Hex(
    'RemoteDeskHarmonyOS:cryptoparams:v2:' + owner + ':' + logicalKey)
    .slice(0, 32);
}

export function legacyScopedCryptoParamRecordId(
  ownerScopeId: string,
  key: string
): string {
  const owner: string = ownerScopeId.trim();
  const logicalKey: string = key.trim();
  if (owner.length === 0 || logicalKey.length === 0) { return ''; }
  return 'crypto-param|' + owner + '|' + logicalKey;
}

export function stableAccountIdentifierIsValid(unionId: string): boolean {
  return unionId.trim().length > 0;
}

/**
 * A blank record owner represents a new, not-yet-persisted local draft and may
 * be claimed by the active scope. Once an owner is present it is immutable:
 * stale objects from another account must be rejected, never rebound.
 */
export function ownerRecordWriteAllowed(
  currentOwnerScopeId: string,
  recordOwnerScopeId: string
): boolean {
  const currentOwner: string = currentOwnerScopeId.trim();
  const recordOwner: string = recordOwnerScopeId.trim();
  return currentOwner.length > 0 &&
    (recordOwner.length === 0 || recordOwner === currentOwner);
}

export function ownerScopeIdForUnionId(unionId: string): string {
  const normalized: string = unionId.trim();
  if (normalized.length === 0) { return ''; }
  return 'owner-' + sha256Hex('RemoteDeskHarmonyOS:owner:v1:' + normalized);
}

export function accountStoreIdentity(ownerScopeId: string): string {
  const normalized: string = ownerScopeId.trim();
  if (normalized.length === 0 || normalized.indexOf('owner-') !== 0) { return ''; }
  return 'remotedesktop_' + normalized + '.db';
}

/** The single cloud-capable physical store name (matches AGC database.name). */
export function accountCloudStoreIdentity(): string {
  return ACCOUNT_CLOUD_STORE_IDENTITY;
}

export function deviceLocalScopeToken(generation: number): AccountScopeToken {
  return {
    kind: 'device_local',
    ownerScopeId: DEVICE_LOCAL_OWNER_SCOPE_ID,
    generation: Math.max(1, Math.floor(generation)),
    sessionState: 'offline',
    cloudBindingState: 'unbound',
    storeIdentity: DEVICE_LOCAL_STORE_IDENTITY,
    schemaRevision: 0,
    selectionRevision: 0,
    platformIdentityFingerprint: ''
  };
}

export function accountScopeToken(
  unionId: string,
  generation: number,
  sessionState: AccountSessionState = 'bound',
  cloudBindingState: CloudAccountBindingState = 'validating',
  platformProof: PlatformCloudIdentityProof =
    unavailablePlatformCloudIdentityProof()
): AccountScopeToken | null {
  const ownerScopeId: string = ownerScopeIdForUnionId(unionId);
  // Only an independently verified platform cloud identity may target the
  // canonical cloud store. Any other account uses its local-only hashed store
  // and stays fail-closed for cloud registration/transfer.
  const storeIdentity: string =
    platformCloudIdentityProofIsValid(platformProof)
      ? ACCOUNT_CLOUD_STORE_IDENTITY
      : accountStoreIdentity(ownerScopeId);
  if (ownerScopeId.length === 0 || storeIdentity.length === 0) { return null; }
  return {
    kind: 'huawei_account',
    ownerScopeId,
    generation: Math.max(1, Math.floor(generation)),
    sessionState,
    cloudBindingState,
    storeIdentity,
    schemaRevision: 0,
    selectionRevision: 0,
    platformIdentityFingerprint:
      platformProof.fingerprint.trim()
  };
}

/**
 * Promotes an account scope to a cloud-capable binding only when the stable
 * UnionID returned by the current Account Kit authorization derives the exact
 * owner and physical store already carried by the scope token, and a fresh
 * independent platform distributed-account proof matches the token.
 *
 * The caller must pass both identities from current official API results,
 * never a cached preference or UI field. Device-local scopes can never become
 * cloud-bound.
 */
export function verifyAccountScopeCloudBinding(
  token: AccountScopeToken,
  verifiedUnionId: string,
  platformProof: PlatformCloudIdentityProof
): AccountScopeToken {
  const verifiedOwnerScopeId: string =
    ownerScopeIdForUnionId(verifiedUnionId);
  const verifiedStoreIdentity: string =
    accountCloudStoreIdentity();
  let cloudBindingState: CloudAccountBindingState = 'blocked';
  if (token.kind === 'device_local') {
    cloudBindingState = 'unbound';
  } else if (verifiedOwnerScopeId.length > 0 &&
    verifiedStoreIdentity.length > 0 &&
    token.ownerScopeId === verifiedOwnerScopeId &&
    token.storeIdentity === verifiedStoreIdentity &&
    token.generation > 0 &&
    platformCloudIdentityProofIsValid(platformProof) &&
    token.platformIdentityFingerprint ===
      platformProof.fingerprint) {
    cloudBindingState = 'bound';
  } else if (verifiedOwnerScopeId.length > 0 &&
    verifiedStoreIdentity.length > 0 &&
    token.ownerScopeId === verifiedOwnerScopeId &&
    (token.storeIdentity === verifiedStoreIdentity ||
      token.storeIdentity === accountStoreIdentity(verifiedOwnerScopeId)) &&
    token.generation > 0) {
    // A hashed local-only store (or a canonical store without a valid proof)
    // remains locally usable; only cloud transfer stays fail-closed.
    cloudBindingState = 'validating';
  }
  return {
    kind: token.kind,
    ownerScopeId: token.ownerScopeId,
    generation: token.generation,
    sessionState: token.sessionState,
    cloudBindingState,
    storeIdentity: token.storeIdentity,
    schemaRevision: token.schemaRevision,
    selectionRevision: token.selectionRevision,
    platformIdentityFingerprint:
      token.platformIdentityFingerprint
  };
}

/**
 * Confirm that a physical rebind reached the requested account generation.
 * A verified account may request the canonical AGC store and discover that it
 * is already owned by another account on this OS user. CloudStore then opens
 * the one deterministic per-owner hashed store and keeps cloud validating.
 * That compatibility fallback is a successful local bind, not an account
 * transition failure; every other identity/store substitution remains denied.
 */
export function accountScopeRebindSucceeded(
  requested: AccountScopeToken,
  active: AccountScopeToken
): boolean {
  if (requested.kind !== active.kind ||
    requested.ownerScopeId !== active.ownerScopeId ||
    requested.generation !== active.generation ||
    requested.platformIdentityFingerprint !==
      active.platformIdentityFingerprint) {
    return false;
  }
  if (requested.storeIdentity === active.storeIdentity) { return true; }
  return requested.kind === 'huawei_account' &&
    requested.storeIdentity === ACCOUNT_CLOUD_STORE_IDENTITY &&
    active.storeIdentity === accountStoreIdentity(requested.ownerScopeId) &&
    active.cloudBindingState === 'validating';
}

export function scopeTokenIsCurrent(token: AccountScopeToken, generation: number): boolean {
  return token.generation > 0 && token.generation === generation &&
    token.ownerScopeId.trim().length > 0 && token.storeIdentity.trim().length > 0;
}

export function accountSessionLease(
  token: AccountScopeToken,
  storeInstanceId: number
): AccountSessionLease {
  return {
    ownerScopeId: token.ownerScopeId,
    storeIdentity: token.storeIdentity,
    generation: token.generation,
    storeInstanceId: Math.max(1, Math.floor(storeInstanceId))
  };
}

export function accountSessionLeaseEquals(
  left: AccountSessionLease | null,
  right: AccountSessionLease | null
): boolean {
  if (left === null || right === null) { return left === right; }
  return left.ownerScopeId === right.ownerScopeId &&
    left.storeIdentity === right.storeIdentity &&
    left.generation === right.generation &&
    left.storeInstanceId === right.storeInstanceId;
}

export function cloneAccountSessionLease(lease: AccountSessionLease): AccountSessionLease {
  return {
    ownerScopeId: lease.ownerScopeId,
    storeIdentity: lease.storeIdentity,
    generation: lease.generation,
    storeInstanceId: lease.storeInstanceId
  };
}

export function cloudAccountBindingForScope(token: AccountScopeToken): CloudAccountBinding {
  return {
    state: token.cloudBindingState,
    ownerScopeId: token.ownerScopeId,
    storeIdentity: token.storeIdentity,
    generation: token.generation,
    platformIdentityFingerprint:
      token.platformIdentityFingerprint
  };
}
