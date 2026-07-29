import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import {
  CloudAccountBinding,
  CloudAccountBindingState
} from './CloudLifecycleSafetyPolicy';

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

export function deviceLocalScopeToken(generation: number): AccountScopeToken {
  return {
    kind: 'device_local',
    ownerScopeId: DEVICE_LOCAL_OWNER_SCOPE_ID,
    generation: Math.max(1, Math.floor(generation)),
    sessionState: 'offline',
    cloudBindingState: 'unbound',
    storeIdentity: DEVICE_LOCAL_STORE_IDENTITY,
    schemaRevision: 0,
    selectionRevision: 0
  };
}

export function accountScopeToken(
  unionId: string,
  generation: number,
  sessionState: AccountSessionState = 'bound',
  cloudBindingState: CloudAccountBindingState = 'validating'
): AccountScopeToken | null {
  const ownerScopeId: string = ownerScopeIdForUnionId(unionId);
  const storeIdentity: string = accountStoreIdentity(ownerScopeId);
  if (ownerScopeId.length === 0 || storeIdentity.length === 0) { return null; }
  return {
    kind: 'huawei_account',
    ownerScopeId,
    generation: Math.max(1, Math.floor(generation)),
    sessionState,
    cloudBindingState,
    storeIdentity,
    schemaRevision: 0,
    selectionRevision: 0
  };
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
    generation: token.generation
  };
}
