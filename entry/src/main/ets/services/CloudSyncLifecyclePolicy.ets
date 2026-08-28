import {
  CloudAccountBinding,
  cloudAccountBindingIsValid
} from './CloudLifecycleSafetyPolicy';
import {
  CloudSyncFailureKind,
  CloudSyncRetryRecord,
  CloudSyncSource,
  isAutomaticRetryRecord,
  shouldBlockAutomaticRetry
} from './CloudSyncCoordinatorPolicy';
import { CloudSyncDirection } from './CloudSyncPolicy';

export type CloudSyncLifecyclePhase =
  'disabled' | 'identity_validating' | 'registration_pending' |
  'bootstrap_required' | 'bootstrap_in_progress' | 'ready' |
  'upload_in_progress' | 'download_in_progress' | 'retry_wait' |
  'conflict_blocked' | 'restore_quarantine' | 'recovery_required' |
  'quiescing' | 'blocked';

export interface CloudSyncDurableState {
  schemaVersion: number;
  ownerScopeId: string;
  storeIdentity: string;
  generation: number;
  revision: number;
  phase: CloudSyncLifecyclePhase;
  bootstrapCompleted: boolean;
  dirtyTables: string[];
  conflictTables: string[];
  retryRecords: CloudSyncRetryRecord[];
  lastSource: string;
  lastDirection: string;
  lastFailureKind: CloudSyncFailureKind;
  failedTables: string[];
  updatedAt: number;
}

const CLOUD_SYNC_DURABLE_STATE_SCHEMA_VERSION: number = 1;

function isLifecyclePhase(value: string): boolean {
  return value === 'disabled' ||
    value === 'identity_validating' ||
    value === 'registration_pending' ||
    value === 'bootstrap_required' ||
    value === 'bootstrap_in_progress' ||
    value === 'ready' ||
    value === 'upload_in_progress' ||
    value === 'download_in_progress' ||
    value === 'retry_wait' ||
    value === 'conflict_blocked' ||
    value === 'restore_quarantine' ||
    value === 'recovery_required' ||
    value === 'quiescing' ||
    value === 'blocked';
}

function isFailureKind(value: string): boolean {
  return value === 'none' ||
    value === 'version_conflict' ||
    value === 'empty_snapshot' ||
    value === 'tombstone_cleanup' ||
    value === 'unsafe_payload' ||
    value === 'cloud_service' ||
    value === 'network' ||
    value === 'indeterminate' ||
    value === 'restore_pending' ||
    value === 'no_selection' ||
    value === 'local_finalize' ||
    value === 'unknown';
}

function safeFailureKind(value: string): CloudSyncFailureKind {
  return isFailureKind(value) ? value as CloudSyncFailureKind : 'unknown';
}

function safeRevision(value: number): number {
  if (!Number.isFinite(value) || value < 1) { return 1; }
  return Math.floor(value);
}

function cloneRetryRecord(record: CloudSyncRetryRecord): CloudSyncRetryRecord {
  return {
    source: record.source,
    direction: record.direction,
    tables: record.tables.slice(),
    failedTables: record.failedTables.slice(),
    attempt: record.attempt,
    nextRetryAt: record.nextRetryAt
  };
}

export function cloneCloudSyncDurableState(
  state: CloudSyncDurableState
): CloudSyncDurableState {
  return {
    schemaVersion: state.schemaVersion,
    ownerScopeId: state.ownerScopeId,
    storeIdentity: state.storeIdentity,
    generation: state.generation,
    revision: state.revision,
    phase: state.phase,
    bootstrapCompleted: state.bootstrapCompleted,
    dirtyTables: state.dirtyTables.slice(),
    conflictTables: state.conflictTables.slice(),
    retryRecords: state.retryRecords.map(
      (record: CloudSyncRetryRecord): CloudSyncRetryRecord =>
        cloneRetryRecord(record)),
    lastSource: state.lastSource,
    lastDirection: state.lastDirection,
    lastFailureKind: state.lastFailureKind,
    failedTables: state.failedTables.slice(),
    updatedAt: state.updatedAt
  };
}

function uniqueNonBlank(values: string[]): string[] {
  const result: string[] = [];
  for (let i = 0; i < values.length; i++) {
    const value: string = values[i].trim();
    if (value.length > 0 && result.indexOf(value) < 0) { result.push(value); }
  }
  return result;
}

function safeStrings(value: Object | undefined): string[] {
  if (!Array.isArray(value)) { return []; }
  const raw: Object[] = value as Object[];
  const values: string[] = [];
  for (let i = 0; i < raw.length; i++) {
    if (typeof raw[i] === 'string') { values.push(raw[i] as string); }
  }
  return uniqueNonBlank(values);
}

function safeRetries(value: Object | undefined): CloudSyncRetryRecord[] {
  if (!Array.isArray(value)) { return []; }
  const raw: Object[] = value as Object[];
  const result: CloudSyncRetryRecord[] = [];
  for (let i = 0; i < raw.length; i++) {
    if (raw[i] === null || typeof raw[i] !== 'object') { continue; }
    const record: CloudSyncRetryRecord = raw[i] as CloudSyncRetryRecord;
    const tables: string[] = safeStrings(record.tables as Object);
    const failedTables: string[] = safeStrings(record.failedTables as Object);
    if (record.source !== 'automaticPush' ||
      record.direction !== 'nativeFirst' ||
      !Number.isFinite(record.attempt) ||
      !Number.isFinite(record.nextRetryAt)) {
      continue;
    }
    const normalized: CloudSyncRetryRecord = {
      source: 'automaticPush',
      direction: 'nativeFirst',
      tables,
      failedTables,
      attempt: Math.floor(record.attempt),
      nextRetryAt: Math.max(0, Math.floor(record.nextRetryAt))
    };
    if (isAutomaticRetryRecord(normalized)) {
      result.push(normalized);
    }
  }
  return result;
}

function bindingPhase(binding: CloudAccountBinding, transferEnabled: boolean,
  bootstrapCompleted: boolean): CloudSyncLifecyclePhase {
  if (!transferEnabled) { return 'disabled'; }
  if (binding.state === 'validating') { return 'identity_validating'; }
  if (binding.state === 'blocked') { return 'blocked'; }
  if (!cloudAccountBindingIsValid(binding)) { return 'disabled'; }
  return bootstrapCompleted ? 'ready' : 'bootstrap_required';
}

function transientPhase(phase: CloudSyncLifecyclePhase): boolean {
  return phase === 'registration_pending' ||
    phase === 'bootstrap_in_progress' ||
    phase === 'upload_in_progress' ||
    phase === 'download_in_progress' ||
    phase === 'quiescing';
}

function intentUpdatePhase(state: CloudSyncDurableState): CloudSyncLifecyclePhase {
  if (state.phase !== 'ready' && state.phase !== 'retry_wait' &&
    state.phase !== 'conflict_blocked') {
    return state.phase;
  }
  return settledPhase(state);
}

function settledPhase(state: CloudSyncDurableState): CloudSyncLifecyclePhase {
  if (state.phase === 'disabled' || state.phase === 'identity_validating' ||
    state.phase === 'blocked' || state.phase === 'restore_quarantine') {
    return state.phase;
  }
  if (!state.bootstrapCompleted) { return 'bootstrap_required'; }
  if (state.conflictTables.length > 0) { return 'conflict_blocked'; }
  if (state.retryRecords.length > 0) { return 'retry_wait'; }
  return 'ready';
}

export function newCloudSyncDurableState(
  binding: CloudAccountBinding,
  transferEnabled: boolean,
  bootstrapCompleted: boolean,
  now: number = Date.now()
): CloudSyncDurableState {
  return {
    schemaVersion: CLOUD_SYNC_DURABLE_STATE_SCHEMA_VERSION,
    ownerScopeId: binding.ownerScopeId,
    storeIdentity: binding.storeIdentity,
    generation: binding.generation,
    revision: 1,
    phase: bindingPhase(binding, transferEnabled, bootstrapCompleted),
    bootstrapCompleted,
    dirtyTables: [],
    conflictTables: [],
    retryRecords: [],
    lastSource: '',
    lastDirection: '',
    lastFailureKind: 'none',
    failedTables: [],
    updatedAt: now
  };
}

export function corruptedCloudSyncDurableState(
  binding: CloudAccountBinding,
  bootstrapCompleted: boolean,
  now: number = Date.now()
): CloudSyncDurableState {
  const state: CloudSyncDurableState = newCloudSyncDurableState(
    binding, false, bootstrapCompleted, now);
  state.phase = 'recovery_required';
  state.lastFailureKind = 'unknown';
  return state;
}

/**
 * A process death during a cloud transfer never resumes that transfer from
 * memory. The recovered state explicitly requires reconciliation before any
 * native-first upload can be attempted.
 */
export function recoverCloudSyncDurableState(
  candidate: CloudSyncDurableState | null,
  binding: CloudAccountBinding,
  transferEnabled: boolean,
  bootstrapCompleted: boolean,
  now: number = Date.now()
): CloudSyncDurableState {
  if (candidate === null ||
    candidate.schemaVersion !== CLOUD_SYNC_DURABLE_STATE_SCHEMA_VERSION ||
    candidate.ownerScopeId !== binding.ownerScopeId ||
    candidate.storeIdentity !== binding.storeIdentity) {
    return newCloudSyncDurableState(
      binding, transferEnabled, bootstrapCompleted, now);
  }
  const dirtyTables: string[] = safeStrings(candidate.dirtyTables as Object);
  const conflictTables: string[] = safeStrings(candidate.conflictTables as Object);
  const retryRecords: CloudSyncRetryRecord[] =
    safeRetries(candidate.retryRecords as Object);
  const candidatePhaseValid: boolean =
    typeof candidate.phase === 'string' && isLifecyclePhase(candidate.phase);
  const candidateIntegrityValid: boolean = candidatePhaseValid &&
    Number.isFinite(candidate.revision) &&
    candidate.revision >= 1 &&
    typeof candidate.lastFailureKind === 'string' &&
    isFailureKind(candidate.lastFailureKind);
  let phase: CloudSyncLifecyclePhase =
    bindingPhase(binding, transferEnabled, bootstrapCompleted);
  if (candidate.phase === 'restore_quarantine') {
    phase = candidate.phase;
  } else if (candidate.phase === 'blocked') {
    // `blocked` is a failure report from an older runtime, not authoritative
    // business data. Rebuild it from the current binding/bootstrap evidence
    // so an app upgrade or repaired platform service cannot leave cloud data
    // permanently sealed behind stale metadata. Explicit restore quarantine
    // remains durable because it represents an unresolved user direction.
    const currentPhase: CloudSyncLifecyclePhase =
      bindingPhase(
        binding, transferEnabled,
        bootstrapCompleted);
    phase = currentPhase === 'ready'
      ? 'recovery_required' : currentPhase;
  } else if (!candidateIntegrityValid ||
    transientPhase(candidate.phase) ||
    candidate.phase === 'recovery_required') {
    phase = 'recovery_required';
  } else if (transferEnabled && cloudAccountBindingIsValid(binding)) {
    if (!bootstrapCompleted) {
      phase = 'bootstrap_required';
    } else if (conflictTables.length > 0) {
      phase = 'conflict_blocked';
    } else if (retryRecords.length > 0) {
      phase = 'retry_wait';
    } else {
      phase = 'ready';
    }
  }
  return {
    schemaVersion: CLOUD_SYNC_DURABLE_STATE_SCHEMA_VERSION,
    ownerScopeId: binding.ownerScopeId,
    storeIdentity: binding.storeIdentity,
    generation: binding.generation,
    revision: safeRevision(candidate.revision) + 1,
    phase,
    bootstrapCompleted,
    dirtyTables,
    conflictTables,
    retryRecords,
    lastSource: typeof candidate.lastSource === 'string' ? candidate.lastSource : '',
    lastDirection: typeof candidate.lastDirection === 'string' ? candidate.lastDirection : '',
    lastFailureKind: safeFailureKind(candidate.lastFailureKind),
    failedTables: safeStrings(candidate.failedTables as Object),
    updatedAt: now
  };
}

export function cloudSyncDurableStateWithIntents(
  state: CloudSyncDurableState,
  dirtyTables: string[],
  conflictTables: string[],
  retryRecords: CloudSyncRetryRecord[],
  now: number = Date.now()
): CloudSyncDurableState {
  const next: CloudSyncDurableState = cloneCloudSyncDurableState(state);
  next.revision = state.revision + 1;
  next.dirtyTables = uniqueNonBlank(dirtyTables);
  next.conflictTables = uniqueNonBlank(conflictTables);
  next.retryRecords = retryRecords
    .filter((record: CloudSyncRetryRecord): boolean => isAutomaticRetryRecord(record))
    .map((record: CloudSyncRetryRecord): CloudSyncRetryRecord => cloneRetryRecord(record));
  next.updatedAt = now;
  next.phase = intentUpdatePhase(next);
  return next;
}

export function cloudSyncOperationStarted(
  state: CloudSyncDurableState,
  source: CloudSyncSource,
  direction: CloudSyncDirection,
  tables: string[],
  now: number = Date.now()
): CloudSyncDurableState {
  const next: CloudSyncDurableState = cloneCloudSyncDurableState(state);
  next.revision = state.revision + 1;
  next.phase = direction === 'nativeFirst'
    ? 'upload_in_progress'
    : state.bootstrapCompleted ? 'download_in_progress' : 'bootstrap_in_progress';
  next.lastSource = source;
  next.lastDirection = direction;
  next.lastFailureKind = 'none';
  next.failedTables = [];
  next.updatedAt = now;
  return next;
}

export function cloudSyncOperationFinished(
  state: CloudSyncDurableState,
  ok: boolean,
  failedTables: string[],
  rollbackFailed: boolean,
  failureKind: CloudSyncFailureKind,
  bootstrapCompleted: boolean,
  now: number = Date.now()
): CloudSyncDurableState {
  const conflicts: string[] = state.conflictTables.slice();
  if (!ok && shouldBlockAutomaticRetry(failureKind)) {
    const failed: string[] = uniqueNonBlank(failedTables);
    for (let i = 0; i < failed.length; i++) {
      if (conflicts.indexOf(failed[i]) < 0) { conflicts.push(failed[i]); }
    }
  }
  const next: CloudSyncDurableState = cloneCloudSyncDurableState(state);
  next.revision = state.revision + 1;
  next.bootstrapCompleted = bootstrapCompleted;
  next.conflictTables = conflicts;
  next.lastFailureKind = failureKind;
  next.failedTables = uniqueNonBlank(failedTables);
  next.updatedAt = now;
  if (rollbackFailed) {
    next.phase = 'blocked';
  } else if (!ok && failureKind === 'indeterminate') {
    next.phase = 'recovery_required';
  } else if (!ok && shouldBlockAutomaticRetry(failureKind)) {
    next.phase = 'conflict_blocked';
  } else if (!ok) {
    next.phase = bootstrapCompleted ? 'retry_wait' : 'bootstrap_required';
  } else {
    next.phase = settledPhase(next);
  }
  return next;
}

/**
 * A caller-owned durable transaction still has a checkpoint and fail-closed
 * barrier, but could not restore its before-image. Unlike a timed-out native
 * operation, this state must not be released by an unrelated late callback.
 */
export function cloudSyncExternalRecoveryRequired(
  state: CloudSyncDurableState,
  failedTables: string[],
  now: number = Date.now()
): CloudSyncDurableState {
  const next: CloudSyncDurableState =
    cloneCloudSyncDurableState(state);
  next.revision = state.revision + 1;
  next.phase = 'recovery_required';
  next.lastFailureKind = 'unknown';
  next.failedTables = uniqueNonBlank(failedTables);
  next.updatedAt = now;
  return next;
}

/**
 * Release only the exact external recovery tables that were durably restored.
 * Unknown/corrupt recovery states and unrelated failures remain fail-closed.
 */
export function cloudSyncExternalRecoverySettled(
  state: CloudSyncDurableState,
  binding: CloudAccountBinding,
  transferEnabled: boolean,
  restoredTables: string[],
  now: number = Date.now()
): CloudSyncDurableState {
  const next: CloudSyncDurableState =
    cloneCloudSyncDurableState(state);
  const restored: string[] =
    uniqueNonBlank(restoredTables);
  if (state.phase !== 'recovery_required' ||
    state.lastFailureKind !== 'unknown' ||
    state.failedTables.length === 0) {
    return next;
  }
  const remaining: string[] = [];
  let matched: boolean = false;
  for (let i = 0; i < state.failedTables.length; i++) {
    if (restored.indexOf(state.failedTables[i]) >= 0) {
      matched = true;
    } else {
      remaining.push(state.failedTables[i]);
    }
  }
  if (!matched) { return next; }
  next.revision = state.revision + 1;
  next.failedTables = remaining;
  next.updatedAt = now;
  if (remaining.length === 0) {
    next.lastFailureKind = 'none';
    next.phase =
      transferEnabled &&
      cloudAccountBindingIsValid(binding)
        ? settledPhase(next)
        : bindingPhase(
          binding, transferEnabled,
          state.bootstrapCompleted);
  }
  return next;
}

/**
 * A watchdog timeout is only recoverable after the exact native operation
 * later reaches a terminal callback. This transition does not claim that the
 * timed-out transfer succeeded; it merely permits the serialized coordinator
 * to reconcile or retry from its already persisted intents.
 */
export function cloudSyncIndeterminateSettled(
  state: CloudSyncDurableState,
  binding: CloudAccountBinding,
  transferEnabled: boolean,
  now: number = Date.now()
): CloudSyncDurableState {
  const next: CloudSyncDurableState = cloneCloudSyncDurableState(state);
  next.revision = state.revision + 1;
  next.updatedAt = now;
  next.phase = transferEnabled && cloudAccountBindingIsValid(binding)
    ? settledPhase(next)
    : bindingPhase(binding, transferEnabled, state.bootstrapCompleted);
  return next;
}

export function cloudSyncBootstrapCompleted(
  state: CloudSyncDurableState,
  now: number = Date.now()
): CloudSyncDurableState {
  const next: CloudSyncDurableState = cloneCloudSyncDurableState(state);
  next.revision = state.revision + 1;
  next.bootstrapCompleted = true;
  next.failedTables = [];
  next.lastFailureKind = 'none';
  next.updatedAt = now;
  next.phase = settledPhase(next);
  return next;
}

export function cloudSyncRestoreQuarantined(
  state: CloudSyncDurableState,
  now: number = Date.now()
): CloudSyncDurableState {
  const next: CloudSyncDurableState = cloneCloudSyncDurableState(state);
  next.revision = state.revision + 1;
  next.phase = 'restore_quarantine';
  next.updatedAt = now;
  return next;
}

export function cloudSyncRestoreReleased(
  quarantinedState: CloudSyncDurableState,
  stateBeforeRestore: CloudSyncDurableState,
  now: number = Date.now()
): CloudSyncDurableState {
  const next: CloudSyncDurableState =
    cloneCloudSyncDurableState(stateBeforeRestore);
  next.revision = quarantinedState.revision + 1;
  next.updatedAt = now;
  return next;
}

export function cloudSyncQuiescing(
  state: CloudSyncDurableState,
  now: number = Date.now()
): CloudSyncDurableState {
  const next: CloudSyncDurableState = cloneCloudSyncDurableState(state);
  next.revision = state.revision + 1;
  next.phase = 'quiescing';
  next.updatedAt = now;
  return next;
}

export function cloudSyncQuiesced(
  state: CloudSyncDurableState,
  binding: CloudAccountBinding,
  transferEnabled: boolean,
  now: number = Date.now()
): CloudSyncDurableState {
  const next: CloudSyncDurableState = cloneCloudSyncDurableState(state);
  next.revision = state.revision + 1;
  next.updatedAt = now;
  next.phase = transferEnabled && cloudAccountBindingIsValid(binding)
    ? settledPhase(next)
    : bindingPhase(binding, transferEnabled, state.bootstrapCompleted);
  return next;
}

export function cloudSyncAutomaticUploadAllowed(
  state: CloudSyncDurableState
): boolean {
  return state.bootstrapCompleted &&
    (state.phase === 'ready' ||
      state.phase === 'retry_wait' ||
      state.phase === 'conflict_blocked');
}

/**
 * A portable restore is intentionally fail-closed for every background path,
 * but the user's explicit local-first decision must remain reachable or the
 * quarantine can never be resolved. Recovery/blocked phases are excluded:
 * an indeterminate transfer or failed rollback still needs reconciliation.
 */
export function cloudSyncManualUploadAllowed(
  state: CloudSyncDurableState,
  resolvingRestore: boolean
): boolean {
  return cloudSyncAutomaticUploadAllowed(state) ||
    (resolvingRestore && state.phase === 'restore_quarantine');
}

export function cloudSyncDownloadAllowed(
  state: CloudSyncDurableState
): boolean {
  return state.phase === 'bootstrap_required' ||
    state.phase === 'ready' ||
    state.phase === 'retry_wait' ||
    state.phase === 'conflict_blocked' ||
    state.phase === 'recovery_required';
}

/** Cloud-first is the only safe explicit escape from an interrupted upload. */
export function cloudSyncManualDownloadAllowed(
  state: CloudSyncDurableState,
  resolvingRestore: boolean
): boolean {
  return cloudSyncDownloadAllowed(state) ||
    (resolvingRestore && state.phase === 'restore_quarantine');
}

/**
 * One ordinary/VNC leg has reached a terminal result while a restored backup
 * is still quarantined. Definite success or failure returns to quarantine so
 * the remaining leg can run, while indeterminate and rollback failures retain
 * their stronger recovery/blocked state.
 */
export function cloudSyncRestoreResolutionAttemptFinished(
  state: CloudSyncDurableState,
  ok: boolean,
  failedTables: string[],
  rollbackFailed: boolean,
  failureKind: CloudSyncFailureKind,
  bootstrapCompleted: boolean,
  now: number = Date.now()
): CloudSyncDurableState {
  const finished: CloudSyncDurableState = cloudSyncOperationFinished(
    state, ok, failedTables, rollbackFailed,
    failureKind, bootstrapCompleted, now);
  if (finished.phase === 'blocked' ||
    finished.phase === 'recovery_required') {
    return finished;
  }
  return cloudSyncRestoreQuarantined(finished, now);
}

/** All restored tables reached the user's chosen terminal direction. */
export function cloudSyncRestoreResolutionCompleted(
  state: CloudSyncDurableState,
  now: number = Date.now()
): CloudSyncDurableState {
  const next: CloudSyncDurableState =
    cloneCloudSyncDurableState(state);
  next.revision = state.revision + 1;
  next.bootstrapCompleted = true;
  next.lastFailureKind = 'none';
  next.failedTables = [];
  next.updatedAt = now;
  // settledPhase deliberately preserves restore_quarantine. Move to the
  // neutral ready candidate only after CloudStore atomically commits marker
  // deletion and this lifecycle candidate.
  next.phase = 'ready';
  next.phase = settledPhase(next);
  return next;
}
