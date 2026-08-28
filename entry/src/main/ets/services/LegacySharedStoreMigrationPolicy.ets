import { AccountScopeKind } from './AccountScopePolicy';

export type LegacyRowOwnershipDecision =
  'target' | 'other_owner' | 'quarantine_missing_owner';

export type LegacyVncRowMigrationDecision =
  'migrate' | 'quarantine_owner_mismatch' |
  'quarantine_stale_epoch' | 'quarantine_invalid_payload';

export type AccountScopedMigrationReceiptDecision =
  'migrate' | 'skip_unchanged' | 'source_changed';

export type AccountScopedLocalOverlayRowDecision =
  'migrate' | 'other_owner' | 'quarantine_missing_owner' |
  'quarantine_invalid_local_only' | 'quarantine_invalid_payload';

export function accountScopedMigrationReceiptDecision(
  committedFingerprint: string | null,
  currentFingerprint: string,
  recoveryBaselineFingerprint: string | null = null
): AccountScopedMigrationReceiptDecision {
  if (committedFingerprint === null) { return 'migrate'; }
  if (committedFingerprint.indexOf('journal-v1:') === 0) {
    return committedFingerprint === currentFingerprint
      ? 'skip_unchanged' : 'source_changed';
  }
  // Older receipts used a volatile database-file mtime fingerprint. A local
  // recovery scope created by the fixed app records its journal baseline
  // before UI mutations are admitted, so that exact marker is authoritative.
  // Old installs without the marker retain their existing compatibility path;
  // they are not globally disconnected by a newly introduced heuristic.
  if (recoveryBaselineFingerprint === null) {
    return 'skip_unchanged';
  }
  return recoveryBaselineFingerprint === currentFingerprint
    ? 'skip_unchanged' : 'source_changed';
}

export function accountScopedMigrationReceiptNeedsUpgrade(
  committedFingerprint: string,
  decision: AccountScopedMigrationReceiptDecision,
  recoveryBaselineFingerprint: string | null
): boolean {
  return decision === 'skip_unchanged' &&
    committedFingerprint.indexOf('journal-v1:') !== 0 &&
    recoveryBaselineFingerprint !== null;
}

export function legacyRowOwnershipDecision(
  legacyUserId: string,
  targetKind: AccountScopeKind,
  verifiedUnionId: string,
  targetOwnerScopeId: string = ''
): LegacyRowOwnershipDecision {
  const owner: string = legacyUserId.trim();
  const unionId: string = verifiedUnionId.trim();
  const targetScope: string = targetOwnerScopeId.trim();
  // 1.0.7/1.0.8 wrote account rows into the single physical cloud store
  // before ownerScopeId existed.  A blank owner is therefore compatible only
  // when the active Huawei account has already supplied a stable UnionID.
  // Device-local data keeps the old fail-closed behavior.
  if (owner.length === 0) {
    return targetKind === 'huawei_account' && unionId.length > 0
      ? 'target' : 'quarantine_missing_owner';
  }
  if (targetKind === 'device_local') {
    return owner === 'local' || owner === 'device-local'
      ? 'target' : 'other_owner';
  }
  if (unionId.length === 0) { return 'other_owner'; }
  // Rows produced by the 1.0.9/1.0.10 account-scoped store may already carry
  // the canonical opaque owner. Accept that exact owner when the source is
  // being opened as a local compatibility store.
  return owner === unionId ||
    (targetScope.length > 0 && owner === targetScope)
    ? 'target' : 'other_owner';
}

export function legacyCryptoParamsMayMigrate(
  distinctNonLocalOwners: string[],
  targetKind: AccountScopeKind,
  verifiedUnionId: string,
  targetOwnerScopeId: string = ''
): boolean {
  const owners: string[] = distinctNonLocalOwners
    .map((value: string): string => value.trim())
    .filter((value: string): boolean =>
      value.length > 0 && value !== 'local' && value !== 'device-local');
  const unique: string[] = [];
  for (let i = 0; i < owners.length; i++) {
    if (unique.indexOf(owners[i]) < 0) { unique.push(owners[i]); }
  }
  if (targetKind === 'device_local') { return unique.length === 0; }
  const unionId: string = verifiedUnionId.trim();
  const targetScope: string = targetOwnerScopeId.trim();
  if (unionId.length === 0) { return false; }
  // cryptoparams has no userid column. In the legacy physical cloud store an
  // empty owner set is the only safe proof available for rows written before
  // owner scoping; a single exact UnionID/ownerScopeId is equally unambiguous.
  return unique.length === 0 ||
    (unique.length === 1 &&
      (unique[0] === unionId ||
        (targetScope.length > 0 && unique[0] === targetScope)));
}

/**
 * Rows in the 1.0.9/1.0.10 account-scoped physical store carry
 * userid == ownerScopeId ("owner-<sha256>"). Migration into the canonical
 * cloud store must only take rows owned by the exact target owner scope;
 * blank owners are quarantined and foreign owners are skipped.
 */
export function accountScopedRowOwnershipDecision(
  recordOwnerScopeId: string,
  targetOwnerScopeId: string
): LegacyRowOwnershipDecision {
  const owner: string = recordOwnerScopeId.trim();
  const target: string = targetOwnerScopeId.trim();
  if (owner.length === 0) { return 'quarantine_missing_owner'; }
  return owner === target ? 'target' : 'other_owner';
}

/**
 * Local VNC/Moonlight overlay rows are account data even though they are not
 * distributed tables. Admit only an exact owner, an exact 0/1 local-only flag
 * and a payload already validated by the protocol policy.
 */
export function accountScopedLocalOverlayRowDecision(
  recordOwnerScopeId: string,
  targetOwnerScopeId: string,
  localOnly: number,
  payloadValid: boolean
): AccountScopedLocalOverlayRowDecision {
  const ownership: LegacyRowOwnershipDecision =
    accountScopedRowOwnershipDecision(
      recordOwnerScopeId, targetOwnerScopeId);
  if (ownership === 'quarantine_missing_owner') {
    return 'quarantine_missing_owner';
  }
  if (ownership !== 'target') { return 'other_owner'; }
  if (!Number.isInteger(localOnly) ||
      (localOnly !== 0 && localOnly !== 1)) {
    return 'quarantine_invalid_local_only';
  }
  return payloadValid ? 'migrate' :
    'quarantine_invalid_payload';
}

/**
 * Crypto parameters from the account-scoped store may only migrate when the
 * source contains exactly one non-local owner and it is the target owner scope.
 */
export function accountScopedCryptoParamsMayMigrate(
  distinctNonLocalOwners: string[],
  targetOwnerScopeId: string
): boolean {
  const owners: string[] = distinctNonLocalOwners
    .map((value: string): string => value.trim())
    .filter((value: string): boolean =>
      value.length > 0 && value !== 'local' && value !== 'device-local');
  const unique: string[] = [];
  for (let i = 0; i < owners.length; i++) {
    if (unique.indexOf(owners[i]) < 0) { unique.push(owners[i]); }
  }
  return unique.length === 1 && unique[0] === targetOwnerScopeId.trim();
}

/**
 * A legacy VNC row is never silently dropped and then covered by a completed
 * migration marker. The caller keeps the source table untouched and records a
 * redacted quarantine entry for every non-migratable row.
 */
export function legacyVncRowMigrationDecision(
  legacyUserId: string,
  targetOwnerScopeId: string,
  rowResetEpoch: number,
  currentResetEpoch: number,
  payloadValid: boolean
): LegacyVncRowMigrationDecision {
  if (legacyUserId.trim() === '' ||
    legacyUserId.trim() !== targetOwnerScopeId.trim()) {
    return 'quarantine_owner_mismatch';
  }
  if (!Number.isFinite(rowResetEpoch) ||
    !Number.isInteger(rowResetEpoch) ||
    rowResetEpoch < 0 ||
    rowResetEpoch !== currentResetEpoch) {
    return 'quarantine_stale_epoch';
  }
  return payloadValid ? 'migrate' : 'quarantine_invalid_payload';
}
