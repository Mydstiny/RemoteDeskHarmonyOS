import { AccountSessionLease } from './AccountScopePolicy';

export type CryptoLifecyclePhase =
  'disabled' | 'configuring' | 'active_locked' | 'active_unlocked' |
  'migrating' | 'disabling' | 'reset_pending' | 'reset_committed' |
  'recovery_required' | 'blocked';

export interface CryptoCommittedState {
  status: string;
  configured: boolean;
  kdfVersion: number;
  kdfIterations: number;
  keyVersion: number;
  verifierVersion: number;
  envelopeVersion: number;
}

export interface CryptoLifecycleDurableState {
  schemaVersion: number;
  ownerScopeId: string;
  storeIdentity: string;
  generation: number;
  revision: number;
  phase: CryptoLifecyclePhase;
  transactionId: string;
  kdfVersion: number;
  kdfIterations: number;
  keyVersion: number;
  verifierVersion: number;
  envelopeVersion: number;
  lastFailure: string;
  updatedAt: number;
}

const CRYPTO_LIFECYCLE_SCHEMA_VERSION: number = 1;

function phaseIsKnown(value: string): boolean {
  return value === 'disabled' ||
    value === 'configuring' ||
    value === 'active_locked' ||
    value === 'active_unlocked' ||
    value === 'migrating' ||
    value === 'disabling' ||
    value === 'reset_pending' ||
    value === 'reset_committed' ||
    value === 'recovery_required' ||
    value === 'blocked';
}

function phaseIsTransient(value: CryptoLifecyclePhase): boolean {
  return value === 'configuring' ||
    value === 'migrating' ||
    value === 'disabling' ||
    value === 'reset_pending';
}

function safeVersion(value: number): number {
  return Number.isFinite(value) && value >= 0 ? Math.floor(value) : 0;
}

function safeRevision(value: number): number {
  return Number.isFinite(value) && value >= 1 ? Math.floor(value) : 1;
}

function committedPhase(
  committed: CryptoCommittedState
): CryptoLifecyclePhase {
  if (committed.configured && committed.status === 'active') {
    return 'active_locked';
  }
  if (!committed.configured &&
    (committed.status === '' || committed.status === 'disabled')) {
    return 'disabled';
  }
  if (!committed.configured && committed.status === 'reset') {
    return 'reset_committed';
  }
  return 'recovery_required';
}

function cloneCryptoLifecycleDurableState(
  state: CryptoLifecycleDurableState
): CryptoLifecycleDurableState {
  return {
    schemaVersion: state.schemaVersion,
    ownerScopeId: state.ownerScopeId,
    storeIdentity: state.storeIdentity,
    generation: state.generation,
    revision: state.revision,
    phase: state.phase,
    transactionId: state.transactionId,
    kdfVersion: state.kdfVersion,
    kdfIterations: state.kdfIterations,
    keyVersion: state.keyVersion,
    verifierVersion: state.verifierVersion,
    envelopeVersion: state.envelopeVersion,
    lastFailure: state.lastFailure,
    updatedAt: state.updatedAt
  };
}

export function newCryptoLifecycleDurableState(
  lease: AccountSessionLease,
  committed: CryptoCommittedState,
  now: number = Date.now()
): CryptoLifecycleDurableState {
  return {
    schemaVersion: CRYPTO_LIFECYCLE_SCHEMA_VERSION,
    ownerScopeId: lease.ownerScopeId,
    storeIdentity: lease.storeIdentity,
    generation: lease.generation,
    revision: 1,
    phase: committedPhase(committed),
    transactionId: '',
    kdfVersion: safeVersion(committed.kdfVersion),
    kdfIterations: safeVersion(committed.kdfIterations),
    keyVersion: safeVersion(committed.keyVersion),
    verifierVersion: safeVersion(committed.verifierVersion),
    envelopeVersion: safeVersion(committed.envelopeVersion),
    lastFailure: '',
    updatedAt: now
  };
}

export function recoverCryptoLifecycleDurableState(
  candidate: CryptoLifecycleDurableState | null,
  lease: AccountSessionLease,
  committed: CryptoCommittedState,
  now: number = Date.now()
): CryptoLifecycleDurableState {
  if (candidate === null ||
    candidate.ownerScopeId !== lease.ownerScopeId ||
    candidate.storeIdentity !== lease.storeIdentity) {
    return newCryptoLifecycleDurableState(lease, committed, now);
  }
  const valid: boolean =
    candidate.schemaVersion === CRYPTO_LIFECYCLE_SCHEMA_VERSION &&
    typeof candidate.phase === 'string' &&
    phaseIsKnown(candidate.phase) &&
    Number.isFinite(candidate.revision) &&
    candidate.revision >= 1;
  let phase: CryptoLifecyclePhase = 'recovery_required';
  if (valid) {
    const authoritative: CryptoLifecyclePhase = committedPhase(committed);
    if (phaseIsTransient(candidate.phase) ||
      candidate.phase === 'recovery_required') {
      // Every crypto data mutation is one RDB transaction. After process
      // death, committed cryptoparams therefore determine which side won.
      phase = authoritative;
    } else if (candidate.phase === 'active_unlocked') {
      phase = authoritative === 'active_locked'
        ? 'active_locked' : 'recovery_required';
    } else if (candidate.phase === 'active_locked') {
      phase = authoritative === 'active_locked'
        ? 'active_locked' : 'recovery_required';
    } else if (candidate.phase === 'disabled' ||
      candidate.phase === 'reset_committed') {
      phase = authoritative;
    } else {
      phase = candidate.phase;
    }
  }
  return {
    schemaVersion: CRYPTO_LIFECYCLE_SCHEMA_VERSION,
    ownerScopeId: lease.ownerScopeId,
    storeIdentity: lease.storeIdentity,
    generation: lease.generation,
    revision: safeRevision(candidate.revision) + 1,
    phase,
    transactionId: '',
    kdfVersion: safeVersion(committed.kdfVersion),
    kdfIterations: safeVersion(committed.kdfIterations),
    keyVersion: safeVersion(committed.keyVersion),
    verifierVersion: safeVersion(committed.verifierVersion),
    envelopeVersion: safeVersion(committed.envelopeVersion),
    lastFailure: valid && typeof candidate.lastFailure === 'string'
      ? candidate.lastFailure : 'crypto_lifecycle_state_invalid',
    updatedAt: now
  };
}

export function cryptoLifecycleOperationStarted(
  state: CryptoLifecycleDurableState,
  phase: 'configuring' | 'migrating' | 'disabling' | 'reset_pending',
  transactionId: string,
  now: number = Date.now()
): CryptoLifecycleDurableState {
  const result: CryptoLifecycleDurableState =
    cloneCryptoLifecycleDurableState(state);
  result.revision = state.revision + 1;
  result.phase = phase;
  result.transactionId = transactionId;
  result.lastFailure = '';
  result.updatedAt = now;
  return result;
}

export function cryptoLifecycleOperationCommitted(
  state: CryptoLifecycleDurableState,
  phase: 'disabled' | 'active_locked' | 'active_unlocked' |
    'reset_committed',
  committed: CryptoCommittedState,
  now: number = Date.now()
): CryptoLifecycleDurableState {
  const result: CryptoLifecycleDurableState =
    cloneCryptoLifecycleDurableState(state);
  result.revision = state.revision + 1;
  result.phase = phase;
  result.transactionId = '';
  result.kdfVersion = safeVersion(committed.kdfVersion);
  result.kdfIterations = safeVersion(committed.kdfIterations);
  result.keyVersion = safeVersion(committed.keyVersion);
  result.verifierVersion = safeVersion(committed.verifierVersion);
  result.envelopeVersion = safeVersion(committed.envelopeVersion);
  result.lastFailure = '';
  result.updatedAt = now;
  return result;
}

export function cryptoLifecycleOperationFailed(
  state: CryptoLifecycleDurableState,
  transactionId: string,
  failure: string,
  now: number = Date.now()
): CryptoLifecycleDurableState {
  if (state.transactionId !== transactionId || transactionId === '') {
    return state;
  }
  const result: CryptoLifecycleDurableState =
    cloneCryptoLifecycleDurableState(state);
  result.revision = state.revision + 1;
  result.phase = 'recovery_required';
  result.transactionId = '';
  result.lastFailure = failure;
  result.updatedAt = now;
  return result;
}

export function cryptoLifecycleMemoryStateChanged(
  state: CryptoLifecycleDurableState,
  unlocked: boolean,
  now: number = Date.now()
): CryptoLifecycleDurableState {
  if (state.phase !== 'active_locked' &&
    state.phase !== 'active_unlocked') {
    return state;
  }
  const result: CryptoLifecycleDurableState =
    cloneCryptoLifecycleDurableState(state);
  result.revision = state.revision + 1;
  result.phase = unlocked ? 'active_unlocked' : 'active_locked';
  result.updatedAt = now;
  return result;
}

export function cryptoLifecycleCanConfigure(
  state: CryptoLifecycleDurableState
): boolean {
  return state.phase === 'disabled' ||
    state.phase === 'reset_committed';
}

export function cryptoLifecycleCanMigrate(
  state: CryptoLifecycleDurableState
): boolean {
  return state.phase === 'active_unlocked';
}

export function cryptoLifecycleCanDisable(
  state: CryptoLifecycleDurableState
): boolean {
  return state.phase === 'active_unlocked';
}

export function cryptoLifecycleCanReset(
  state: CryptoLifecycleDurableState
): boolean {
  return state.phase === 'active_locked' ||
    state.phase === 'active_unlocked' ||
    state.phase === 'recovery_required' ||
    state.phase === 'blocked';
}

export function cryptoLifecycleSensitiveWriteAllowed(
  state: CryptoLifecycleDurableState,
  configured: boolean,
  unlocked: boolean
): boolean {
  if (!configured) {
    return state.phase === 'disabled' ||
      state.phase === 'reset_committed';
  }
  return unlocked && state.phase === 'active_unlocked';
}
