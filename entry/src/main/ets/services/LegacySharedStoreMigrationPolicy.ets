import { AccountScopeKind } from './AccountScopePolicy';

export type LegacyRowOwnershipDecision =
  'target' | 'other_owner' | 'quarantine_missing_owner';

export type LegacyVncRowMigrationDecision =
  'migrate' | 'quarantine_owner_mismatch' |
  'quarantine_stale_epoch' | 'quarantine_invalid_payload';

export function legacyRowOwnershipDecision(
  legacyUserId: string,
  targetKind: AccountScopeKind,
  verifiedUnionId: string
): LegacyRowOwnershipDecision {
  const owner: string = legacyUserId.trim();
  if (owner.length === 0) { return 'quarantine_missing_owner'; }
  if (targetKind === 'device_local') {
    return owner === 'local' || owner === 'device-local'
      ? 'target' : 'other_owner';
  }
  const unionId: string = verifiedUnionId.trim();
  if (unionId.length === 0) { return 'other_owner'; }
  return owner === unionId ? 'target' : 'other_owner';
}

export function legacyCryptoParamsMayMigrate(
  distinctNonLocalOwners: string[],
  targetKind: AccountScopeKind,
  verifiedUnionId: string
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
  return unique.length === 1 && unique[0] === verifiedUnionId.trim();
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
