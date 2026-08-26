import { MoonlightRecord } from '../model/MoonlightRecord';
import {
  MoonlightRecordMeta,
  moonlightPayloadWithMeta,
  moonlightRecordBusinessPayload,
  moonlightRecordMeta,
  moonlightRecordPayloadHashSha256,
  moonlightValidateRecord
} from './MoonlightRecordPolicy';

export type MoonlightConflictAction =
  'keep_current' | 'accept_candidate' | 'write_merged' |
  'quarantine_candidate' | 'quarantine_both';

export type MoonlightConflictReason =
  'identical_retry' | 'newer_envelope' | 'stale_envelope' |
  'tombstone_wins' | 'explicit_revival' | 'concurrent_fields_merged' |
  'mutation_reuse_corruption' | 'same_envelope_content_mismatch' |
  'scope_mismatch' | 'host_identity_conflict' | 'profile_identity_conflict' |
  'trust_conflict' | 'secret_conflict' | 'invalid_current' |
  'invalid_candidate' | 'invalid_merge_context' | 'merged_row_invalid';

export interface MoonlightConflictMergeContext {
  mutationId: string;
  originId: string;
  updatedAt: number;
}

export interface MoonlightConflictDecision {
  action: MoonlightConflictAction;
  reason: MoonlightConflictReason;
  record: MoonlightRecord | null;
  conflictedPaths: string[];
}

function cloneRecord(source: MoonlightRecord): MoonlightRecord {
  return MoonlightRecord.fromJSON(source.toJSON());
}

function decision(action: MoonlightConflictAction, reason: MoonlightConflictReason,
  record: MoonlightRecord | null, conflictedPaths: string[] = []): MoonlightConflictDecision {
  return { action: action, reason: reason, record: record, conflictedPaths: conflictedPaths };
}

/** resetEpoch > syncVersion > updatedAt. Equal means no safe row-level tie-break exists. */
export function compareMoonlightRecordEnvelope(
  left: MoonlightRecord, right: MoonlightRecord
): number {
  if (left.resetEpoch !== right.resetEpoch) { return left.resetEpoch > right.resetEpoch ? 1 : -1; }
  if (left.syncVersion !== right.syncVersion) { return left.syncVersion > right.syncVersion ? 1 : -1; }
  if (left.updatedAt !== right.updatedAt) { return left.updatedAt > right.updatedAt ? 1 : -1; }
  return 0;
}

function sameScope(left: MoonlightRecord, right: MoonlightRecord): boolean {
  return left.id === right.id && left.userId === right.userId &&
    left.recordType === right.recordType && left.ownerId === right.ownerId &&
    left.ownerType === right.ownerType && left.secretKind === right.secretKind;
}

function sameContent(left: MoonlightRecord, right: MoonlightRecord): boolean {
  return left.payload === right.payload && left.ciphertext === right.ciphertext &&
    left.payloadHashSha256 === right.payloadHashSha256 &&
    left.deletedAt === right.deletedAt && left.schemaVersion === right.schemaVersion &&
    left.envelopeVersion === right.envelopeVersion && left.cryptoVersion === right.cryptoVersion &&
    left.keyVersion === right.keyVersion && left.aadVersion === right.aadVersion;
}

function recordForEnvelopeOrder(
  current: MoonlightRecord, candidate: MoonlightRecord, reasonWhenCandidate: MoonlightConflictReason,
  reasonWhenCurrent: MoonlightConflictReason
): MoonlightConflictDecision {
  const order: number = compareMoonlightRecordEnvelope(candidate, current);
  if (order > 0) {
    return decision('accept_candidate', reasonWhenCandidate, cloneRecord(candidate));
  }
  if (order < 0) {
    return decision('keep_current', reasonWhenCurrent, cloneRecord(current));
  }
  return decision('quarantine_both', 'same_envelope_content_mismatch', null);
}

function parsedPayload(record: MoonlightRecord): Record<string, Object> | null {
  return moonlightRecordBusinessPayload(record);
}

function textField(values: Record<string, Object> | null, key: string): string {
  if (values === null || typeof values[key] !== 'string') { return ''; }
  return values[key] as string;
}

function identityConflict(
  current: MoonlightRecord, candidate: MoonlightRecord,
  currentPayload: Record<string, Object>, candidatePayload: Record<string, Object>
): MoonlightConflictReason | null {
  if (current.recordType === 'host' &&
      textField(currentPayload, 'serverUuid') !== textField(candidatePayload, 'serverUuid')) {
    return 'host_identity_conflict';
  }
  if (current.recordType === 'profile' &&
      (textField(currentPayload, 'hostId') !== textField(candidatePayload, 'hostId') ||
       textField(currentPayload, 'appId') !== textField(candidatePayload, 'appId'))) {
    return 'profile_identity_conflict';
  }
  if (current.recordType === 'trust' &&
      textField(currentPayload, 'serverCertificateSha256') !==
      textField(candidatePayload, 'serverCertificateSha256')) {
    return 'trust_conflict';
  }
  if (current.recordType === 'secret' && !sameContent(current, candidate)) {
    return 'secret_conflict';
  }
  return null;
}

function cloneObject(source: Record<string, Object>): Record<string, Object> {
  return JSON.parse(JSON.stringify(source)) as Record<string, Object>;
}

function valueAtPath(source: Record<string, Object>, path: string): Object | undefined {
  const segments: string[] = path.split('.');
  let current: Object = source;
  for (let i = 0; i < segments.length; i++) {
    if (current === null || typeof current !== 'object' || Array.isArray(current)) { return undefined; }
    const values: Record<string, Object> = current as Record<string, Object>;
    if (typeof values[segments[i]] === 'undefined') { return undefined; }
    current = values[segments[i]];
  }
  return current;
}

/** Project additive settings fields when one concurrent writer predates them. */
function compatibilityValueAtPath(
  source: Record<string, Object>, path: string, recordType: string
): Object | undefined {
  const direct: Object | undefined = valueAtPath(source, path);
  if (direct !== undefined || recordType !== 'settings') { return direct; }
  if (path === 'input.controlMode') {
    const legacyTouchMode: Object | undefined = valueAtPath(source, 'input.touchMode');
    return legacyTouchMode === 'absoluteMouse' || legacyTouchMode === 'relativeMouse' ?
      'trackpad' : 'adaptive';
  }
  if (path === 'video.adaptiveResolution') {
    const legacyResolutionMode: Object | undefined = valueAtPath(source, 'video.resolutionMode');
    return legacyResolutionMode === 'host' ? 'host' : 'off';
  }
  return undefined;
}

function setValueAtPath(target: Record<string, Object>, path: string, value: Object): boolean {
  const segments: string[] = path.split('.');
  let current: Record<string, Object> = target;
  for (let i = 0; i < segments.length - 1; i++) {
    const child: Object | undefined = current[segments[i]];
    if (child === undefined || child === null || typeof child !== 'object' || Array.isArray(child)) {
      return false;
    }
    current = child as Record<string, Object>;
  }
  current[segments[segments.length - 1]] = JSON.parse(JSON.stringify(value)) as Object;
  return true;
}

function valuesEqual(left: Object | undefined, right: Object | undefined): boolean {
  if (left === undefined || right === undefined) { return left === right; }
  return JSON.stringify(left) === JSON.stringify(right);
}

function fieldVersion(meta: MoonlightRecordMeta, path: string): number {
  const value: number | undefined = meta.fieldVersions[path];
  return value === undefined ? 0 : value;
}

function unionFieldPaths(left: MoonlightRecordMeta, right: MoonlightRecordMeta): string[] {
  const result: string[] = Object.keys(left.fieldVersions);
  const rightKeys: string[] = Object.keys(right.fieldVersions);
  for (let i = 0; i < rightKeys.length; i++) {
    if (result.indexOf(rightKeys[i]) < 0) { result.push(rightKeys[i]); }
  }
  result.sort();
  return result;
}

function mergeConcurrentMutableRecord(
  current: MoonlightRecord, candidate: MoonlightRecord,
  currentPayload: Record<string, Object>, candidatePayload: Record<string, Object>,
  currentMeta: MoonlightRecordMeta, candidateMeta: MoonlightRecordMeta,
  context: MoonlightConflictMergeContext | null
): MoonlightConflictDecision {
  if (context === null || !Number.isSafeInteger(context.updatedAt) ||
      context.updatedAt < current.updatedAt || context.updatedAt < candidate.updatedAt ||
      Math.max(current.syncVersion, candidate.syncVersion) >= Number.MAX_SAFE_INTEGER) {
    return decision('quarantine_both', 'invalid_merge_context', null);
  }
  const order: number = compareMoonlightRecordEnvelope(candidate, current);
  if (order === 0) {
    return decision('quarantine_both', 'same_envelope_content_mismatch', null);
  }
  const winnerPayload: Record<string, Object> = order > 0 ? candidatePayload : currentPayload;
  const mergedPayload: Record<string, Object> = cloneObject(winnerPayload);
  const mergedVersions: Record<string, number> = {};
  const paths: string[] = unionFieldPaths(currentMeta, candidateMeta);
  const conflicts: string[] = [];
  for (let i = 0; i < paths.length; i++) {
    const path: string = paths[i];
    const currentVersion: number = fieldVersion(currentMeta, path);
    const candidateVersion: number = fieldVersion(candidateMeta, path);
    mergedVersions[path] = Math.max(currentVersion, candidateVersion);
    const currentValue: Object | undefined = compatibilityValueAtPath(
      currentPayload, path, current.recordType);
    const candidateValue: Object | undefined = compatibilityValueAtPath(
      candidatePayload, path, candidate.recordType);
    if (currentValue === undefined || candidateValue === undefined) {
      return decision('quarantine_both', 'merged_row_invalid', null);
    }
    if (!valuesEqual(currentValue, candidateValue) &&
        currentVersion > currentMeta.baseSyncVersion &&
        candidateVersion > candidateMeta.baseSyncVersion) {
      conflicts.push(path);
    }
    const useCandidate: boolean = candidateVersion > currentVersion ||
      (candidateVersion === currentVersion && order > 0);
    if (!setValueAtPath(mergedPayload, path, useCandidate ? candidateValue : currentValue)) {
      return decision('quarantine_both', 'merged_row_invalid', null);
    }
  }
  const mergedMeta: MoonlightRecordMeta = {
    mutationId: context.mutationId,
    originId: context.originId,
    baseSyncVersion: Math.max(current.syncVersion, candidate.syncVersion),
    fieldVersions: mergedVersions
  };
  const canonical = moonlightPayloadWithMeta(mergedPayload, mergedMeta, current.recordType);
  if (!canonical.ok) { return decision('quarantine_both', 'invalid_merge_context', null); }
  const merged: MoonlightRecord = cloneRecord(order > 0 ? candidate : current);
  merged.payload = canonical.canonical;
  merged.ciphertext = '';
  merged.resetEpoch = current.resetEpoch;
  merged.syncVersion = Math.max(current.syncVersion, candidate.syncVersion) + 1;
  merged.createdAt = Math.min(current.createdAt, candidate.createdAt);
  merged.updatedAt = context.updatedAt;
  merged.deletedAt = 0;
  merged.payloadHashSha256 = moonlightRecordPayloadHashSha256(merged);
  if (!moonlightValidateRecord(merged).valid) {
    return decision('quarantine_both', 'merged_row_invalid', null);
  }
  return decision('write_merged', 'concurrent_fields_merged', merged, conflicts);
}

/**
 * Reconciles two already materialized rows without wall-clock tie breaking.
 * Any new merge identity and timestamp are explicit caller inputs.
 */
export function resolveMoonlightRecordConflict(
  current: MoonlightRecord, candidate: MoonlightRecord,
  mergeContext: MoonlightConflictMergeContext | null = null
): MoonlightConflictDecision {
  if (!moonlightValidateRecord(current).valid) {
    return moonlightValidateRecord(candidate).valid ?
      decision('accept_candidate', 'invalid_current', cloneRecord(candidate)) :
      decision('quarantine_both', 'invalid_current', null);
  }
  if (!moonlightValidateRecord(candidate).valid) {
    return decision('quarantine_candidate', 'invalid_candidate', cloneRecord(current));
  }
  if (!sameScope(current, candidate)) {
    return decision('quarantine_both', 'scope_mismatch', null);
  }
  if (sameContent(current, candidate) &&
      current.resetEpoch === candidate.resetEpoch &&
      current.syncVersion === candidate.syncVersion &&
      current.updatedAt === candidate.updatedAt) {
    return decision('keep_current', 'identical_retry', cloneRecord(current));
  }

  const currentMeta: MoonlightRecordMeta | null = moonlightRecordMeta(current);
  const candidateMeta: MoonlightRecordMeta | null = moonlightRecordMeta(candidate);
  if (currentMeta !== null && candidateMeta !== null &&
      currentMeta.mutationId === candidateMeta.mutationId) {
    if (!sameContent(current, candidate)) {
      return decision('quarantine_both', 'mutation_reuse_corruption', null);
    }
    return recordForEnvelopeOrder(current, candidate, 'identical_retry', 'identical_retry');
  }

  if (current.resetEpoch !== candidate.resetEpoch) {
    const candidateWins: boolean = candidate.resetEpoch > current.resetEpoch;
    const revival: boolean = candidateWins ? current.deletedAt > 0 && candidate.deletedAt === 0 :
      candidate.deletedAt > 0 && current.deletedAt === 0;
    return decision(candidateWins ? 'accept_candidate' : 'keep_current',
      revival ? 'explicit_revival' : (candidateWins ? 'newer_envelope' : 'stale_envelope'),
      cloneRecord(candidateWins ? candidate : current));
  }
  if ((current.deletedAt > 0) !== (candidate.deletedAt > 0)) {
    const tombstone: MoonlightRecord = current.deletedAt > 0 ? current : candidate;
    return decision(tombstone === candidate ? 'accept_candidate' : 'keep_current',
      'tombstone_wins', cloneRecord(tombstone));
  }
  if (current.deletedAt > 0 && candidate.deletedAt > 0) {
    if (sameContent(current, candidate)) {
      return recordForEnvelopeOrder(current, candidate, 'newer_envelope', 'stale_envelope');
    }
    return recordForEnvelopeOrder(current, candidate, 'newer_envelope', 'stale_envelope');
  }

  const currentPayload: Record<string, Object> | null = parsedPayload(current);
  const candidatePayload: Record<string, Object> | null = parsedPayload(candidate);
  if (currentPayload === null || candidatePayload === null ||
      currentMeta === null || candidateMeta === null) {
    return decision('quarantine_both', 'same_envelope_content_mismatch', null);
  }
  const identityReason: MoonlightConflictReason | null =
    identityConflict(current, candidate, currentPayload, candidatePayload);
  if (identityReason !== null) {
    return decision('quarantine_both', identityReason, null);
  }
  if (sameContent(current, candidate)) {
    return recordForEnvelopeOrder(current, candidate, 'newer_envelope', 'stale_envelope');
  }
  const concurrent: boolean = currentMeta.mutationId !== candidateMeta.mutationId &&
    currentMeta.baseSyncVersion === candidateMeta.baseSyncVersion;
  if (concurrent && (current.recordType === 'settings' || current.recordType === 'profile')) {
    return mergeConcurrentMutableRecord(current, candidate, currentPayload, candidatePayload,
      currentMeta, candidateMeta, mergeContext);
  }
  return recordForEnvelopeOrder(current, candidate, 'newer_envelope', 'stale_envelope');
}
