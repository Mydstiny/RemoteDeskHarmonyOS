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
