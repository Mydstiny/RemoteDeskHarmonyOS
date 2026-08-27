import { AccountSessionLease } from './AccountScopePolicy';
import { MoonlightRecord } from '../model/MoonlightRecord';
import { MoonlightDeletionCommandType } from './MoonlightDeletionPolicy';
import {
  MoonlightRecordMeta,
  moonlightPayloadWithMeta,
  moonlightRecordBusinessPayload,
  moonlightRecordMeta,
  moonlightRecordPayloadHashSha256,
  moonlightValidateRecord
} from './MoonlightRecordPolicy';

export const MOONLIGHT_CLOUD_DELETION_CHECKPOINT_KEY: string =
  'moonlight_cloud_deletion_checkpoint_v1';

export type MoonlightCloudDeletionPhase =
  'pending_upload' | 'uploaded';

export interface MoonlightCloudDeletionCheckpoint {
  version: number;
  ownerScopeId: string;
  storeIdentity: string;
  command: MoonlightDeletionCommandType;
  phase: MoonlightCloudDeletionPhase;
  deletedPhysicalRowCount: number;
  disableSyncAfterUpload: boolean;
  createdAt: number;
  updatedAt: number;
}

export function moonlightRecordTypeIsPublicCloudData(record: MoonlightRecord): boolean {
  return record.recordType === 'settings' || record.recordType === 'host' ||
    record.recordType === 'profile';
}

function sameRecordScope(left: MoonlightRecord, right: MoonlightRecord): boolean {
  return left.id === right.id && left.userId === right.userId &&
    left.recordType === right.recordType && left.ownerId === right.ownerId &&
    left.ownerType === right.ownerType && left.secretKind === right.secretKind;
}

/** Build the public, payload-free row uploaded for a user-confirmed delete. */
export function moonlightCloudDeletionTombstone(
  local: MoonlightRecord | null,
  cloud: MoonlightRecord,
  nowMs: number
): MoonlightRecord | null {
  if (!moonlightValidateRecord(cloud).valid ||
      !moonlightRecordTypeIsPublicCloudData(cloud) ||
      (local !== null &&
       (!moonlightValidateRecord(local).valid ||
        !sameRecordScope(local, cloud))) ||
      !Number.isSafeInteger(nowMs) || nowMs <= 0) {
    return null;
  }
  if (cloud.deletedAt > 0 && local === null) {
    return MoonlightRecord.fromJSON(cloud.toJSON());
  }
  const maximumSyncVersion: number = local === null ? cloud.syncVersion :
    Math.max(local.syncVersion, cloud.syncVersion);
  if (maximumSyncVersion >= Number.MAX_SAFE_INTEGER) { return null; }
  const tombstone: MoonlightRecord = MoonlightRecord.fromJSON(cloud.toJSON());
  tombstone.payload = '{}';
  tombstone.ciphertext = '';
  tombstone.envelopeVersion = 0;
  tombstone.cryptoVersion = 0;
  tombstone.keyVersion = 0;
  tombstone.aadVersion = 0;
  tombstone.resetEpoch = local === null ? cloud.resetEpoch :
    Math.max(local.resetEpoch, cloud.resetEpoch);
  tombstone.syncVersion = maximumSyncVersion + 1;
  tombstone.createdAt = local === null ? cloud.createdAt :
    Math.min(local.createdAt, cloud.createdAt);
  tombstone.updatedAt = Math.max(
    nowMs, tombstone.createdAt, cloud.updatedAt,
    local === null ? 0 : local.updatedAt);
  tombstone.deletedAt = tombstone.updatedAt;
  tombstone.payloadHashSha256 =
    moonlightRecordPayloadHashSha256(tombstone);
  return moonlightValidateRecord(tombstone).valid ? tombstone : null;
}

/**
 * Persist an ordinary user delete without requiring a cloud projection.
 *
 * The local row is deliberately used as both sides of the deletion boundary:
 * a later cloud-first merge makes this payload-free tombstone win over any
 * live row in the same reset epoch, while an explicit re-add can still revive
 * the identity by advancing the reset epoch. The caller stores it as
 * `localonly=1` until optional cloud registration and transfer are healthy.
 */
export function moonlightLocalDeletionTombstone(
  current: MoonlightRecord,
  nowMs: number
): MoonlightRecord | null {
  return moonlightCloudDeletionTombstone(current, current, nowMs);
}

/**
 * A cloud-wide delete preserves the current device's business payload while
 * giving it a higher reset epoch. Other devices consume the uploaded
 * tombstone; this device can only republish its preserved copy after the user
 * explicitly re-enables Moonlight sync.
 */
export function moonlightPreservedLocalAfterCloudDelete(
  current: MoonlightRecord,
  cloudBoundary: MoonlightRecord | null,
  lease: AccountSessionLease,
  nowMs: number,
  sequence: number
): MoonlightRecord | null {
  if (!moonlightValidateRecord(current).valid || current.deletedAt > 0 ||
      current.userId !== lease.ownerScopeId ||
      !moonlightRecordTypeIsPublicCloudData(current) ||
      (cloudBoundary !== null &&
       (!moonlightValidateRecord(cloudBoundary).valid ||
        !sameRecordScope(current, cloudBoundary))) ||
      !Number.isSafeInteger(nowMs) || nowMs <= 0 ||
      !Number.isSafeInteger(sequence) || sequence < 0 ||
      Math.max(current.resetEpoch,
        cloudBoundary === null ? 0 : cloudBoundary.resetEpoch) >=
          Number.MAX_SAFE_INTEGER ||
      Math.max(current.syncVersion,
        cloudBoundary === null ? 0 : cloudBoundary.syncVersion) >=
          Number.MAX_SAFE_INTEGER) {
    return null;
  }
  const business: Record<string, Object> | null =
    moonlightRecordBusinessPayload(current);
  const previousMeta: MoonlightRecordMeta | null =
    moonlightRecordMeta(current);
  if (business === null || previousMeta === null) { return null; }
  const versions: Record<string, number> = {};
  const paths: string[] = Object.keys(previousMeta.fieldVersions);
  for (let index: number = 0; index < paths.length; index++) {
    versions[paths[index]] = previousMeta.fieldVersions[paths[index]];
  }
  const baseSyncVersion: number = Math.max(
    current.syncVersion,
    cloudBoundary === null ? 0 : cloudBoundary.syncVersion);
  const nextVersion: number = baseSyncVersion + 1;
  const meta: MoonlightRecordMeta = {
    mutationId: ('cloud-delete-preserve-' + nowMs.toString() + '-' +
      sequence.toString()).substring(0, 128),
    originId: ('moonlight-cloud-delete|' + lease.storeIdentity)
      .substring(0, 128),
    baseSyncVersion,
    fieldVersions: versions
  };
  const payload = moonlightPayloadWithMeta(
    business, meta, current.recordType);
  if (!payload.ok) { return null; }
  const preserved: MoonlightRecord =
    MoonlightRecord.fromJSON(current.toJSON());
  preserved.payload = payload.canonical;
  preserved.resetEpoch = Math.max(
    current.resetEpoch,
    cloudBoundary === null ? 0 : cloudBoundary.resetEpoch) + 1;
  preserved.syncVersion = nextVersion;
  preserved.updatedAt = Math.max(
    nowMs, current.createdAt, current.updatedAt);
  preserved.payloadHashSha256 =
    moonlightRecordPayloadHashSha256(preserved);
  return moonlightValidateRecord(preserved).valid ? preserved : null;
}

function boundedIdentity(value: string): boolean {
  return typeof value === 'string' && value.trim() === value &&
    value.length > 0 && value.length <= 256;
}

function commandCanDeleteCloudRows(
  command: MoonlightDeletionCommandType
): boolean {
  return command === 'delete_cloud_data' || command === 'forget_host' ||
    command === 'delete_profile';
}

export function moonlightCloudDeletionCheckpointIsValid(
  value: MoonlightCloudDeletionCheckpoint
): boolean {
  if (value.version !== 1 || !boundedIdentity(value.ownerScopeId) ||
      !boundedIdentity(value.storeIdentity) ||
      !commandCanDeleteCloudRows(value.command) ||
      (value.phase !== 'pending_upload' && value.phase !== 'uploaded') ||
      !Number.isSafeInteger(value.deletedPhysicalRowCount) ||
      value.deletedPhysicalRowCount < 0 ||
      typeof value.disableSyncAfterUpload !== 'boolean' ||
      !Number.isSafeInteger(value.createdAt) || value.createdAt <= 0 ||
      !Number.isSafeInteger(value.updatedAt) ||
      value.updatedAt < value.createdAt) {
    return false;
  }
  if (value.command === 'delete_cloud_data' &&
      !value.disableSyncAfterUpload) {
    return false;
  }
  if (value.command !== 'delete_cloud_data' &&
      value.disableSyncAfterUpload) {
    return false;
  }
  return value.phase !== 'pending_upload' ||
    value.deletedPhysicalRowCount > 0;
}

export function newMoonlightCloudDeletionCheckpoint(
  lease: AccountSessionLease,
  command: MoonlightDeletionCommandType,
  deletedPhysicalRowCount: number,
  nowMs: number
): MoonlightCloudDeletionCheckpoint | null {
  const phase: MoonlightCloudDeletionPhase =
    deletedPhysicalRowCount > 0 ? 'pending_upload' : 'uploaded';
  const value: MoonlightCloudDeletionCheckpoint = {
    version: 1,
    ownerScopeId: lease.ownerScopeId,
    storeIdentity: lease.storeIdentity,
    command,
    phase,
    deletedPhysicalRowCount,
    disableSyncAfterUpload: command === 'delete_cloud_data',
    createdAt: nowMs,
    updatedAt: nowMs
  };
  return moonlightCloudDeletionCheckpointIsValid(value) ? value : null;
}

export function moonlightCloudDeletionCheckpointForLease(
  value: MoonlightCloudDeletionCheckpoint,
  lease: AccountSessionLease
): boolean {
  return moonlightCloudDeletionCheckpointIsValid(value) &&
    value.ownerScopeId === lease.ownerScopeId &&
    value.storeIdentity === lease.storeIdentity;
}

export function moonlightCloudDeletionCheckpointUploaded(
  value: MoonlightCloudDeletionCheckpoint,
  nowMs: number
): MoonlightCloudDeletionCheckpoint | null {
  if (!moonlightCloudDeletionCheckpointIsValid(value) ||
      !Number.isSafeInteger(nowMs) || nowMs < value.updatedAt) {
    return null;
  }
  const uploaded: MoonlightCloudDeletionCheckpoint = {
    version: value.version,
    ownerScopeId: value.ownerScopeId,
    storeIdentity: value.storeIdentity,
    command: value.command,
    phase: 'uploaded',
    deletedPhysicalRowCount: value.deletedPhysicalRowCount,
    disableSyncAfterUpload: value.disableSyncAfterUpload,
    createdAt: value.createdAt,
    updatedAt: nowMs
  };
  return moonlightCloudDeletionCheckpointIsValid(uploaded) ? uploaded : null;
}

/**
 * Scope and physical-table choices are frozen until a durable cloud deletion
 * has either uploaded and completed its cleanup or has no checkpoint. Turning
 * the table off mid-upload would strand the delete; turning a scope on could
 * recreate rows that the same checkpoint is trying to remove. An unreadable
 * boundary therefore fails closed as well.
 */
export function moonlightCloudSelectionMutationAllowed(
  checkpointReadable: boolean,
  checkpoint: MoonlightCloudDeletionCheckpoint | null
): boolean {
  return checkpointReadable && checkpoint === null;
}

/**
 * Any durable deletion checkpoint blocks local-to-cloud promotion. A
 * checkpoint for another owner/store is not permission to continue: it is an
 * account-boundary inconsistency that must remain fail-closed until startup
 * recovery or an explicit repair removes it.
 */
export function moonlightCloudPromotionBlocked(
  checkpointReadable: boolean,
  checkpoint: MoonlightCloudDeletionCheckpoint | null,
  lease: AccountSessionLease
): boolean {
  if (!checkpointReadable) { return true; }
  if (checkpoint === null) { return false; }
  if (!moonlightCloudDeletionCheckpointForLease(checkpoint, lease)) {
    return true;
  }
  return checkpoint.phase === 'pending_upload' ||
    checkpoint.phase === 'uploaded';
}

export function encodeMoonlightCloudDeletionCheckpoint(
  value: MoonlightCloudDeletionCheckpoint
): string {
  return moonlightCloudDeletionCheckpointIsValid(value) ?
    JSON.stringify(value) : '';
}

export function parseMoonlightCloudDeletionCheckpoint(
  raw: string
): MoonlightCloudDeletionCheckpoint | null {
  if (typeof raw !== 'string' || raw.length === 0 || raw.length > 4096) {
    return null;
  }
  try {
    const parsed: Record<string, Object> =
      JSON.parse(raw) as Record<string, Object>;
    const expected: string[] = [
      'version', 'ownerScopeId', 'storeIdentity', 'command', 'phase',
      'deletedPhysicalRowCount', 'disableSyncAfterUpload', 'createdAt',
      'updatedAt'
    ];
    const keys: string[] = Object.keys(parsed);
    for (let i = 0; i < expected.length; i++) {
      if (keys.indexOf(expected[i]) < 0) { return null; }
    }
    const value: MoonlightCloudDeletionCheckpoint = {
      version: parsed['version'] as number,
      ownerScopeId: parsed['ownerScopeId'] as string,
      storeIdentity: parsed['storeIdentity'] as string,
      command: parsed['command'] as MoonlightDeletionCommandType,
      phase: parsed['phase'] as MoonlightCloudDeletionPhase,
      deletedPhysicalRowCount: parsed['deletedPhysicalRowCount'] as number,
      disableSyncAfterUpload: parsed['disableSyncAfterUpload'] as boolean,
      createdAt: parsed['createdAt'] as number,
      updatedAt: parsed['updatedAt'] as number
    };
    return moonlightCloudDeletionCheckpointIsValid(value) ? value : null;
  } catch (_error) {
    return null;
  }
}
