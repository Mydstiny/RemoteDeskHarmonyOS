import { AccountScopeKind } from './AccountScopePolicy';

export type LegacyRowOwnershipDecision =
  'target' | 'other_owner' | 'quarantine_missing_owner';

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
