import { MoonlightRecordType } from '../model/MoonlightRecord';

export type MoonlightCloudSyncScope =
  'settings' | 'hosts' | 'profiles' | 'trust' | 'identity';

export const MOONLIGHT_CLOUD_SYNC_SELECTION_KEY: string =
  'moonlightCloudSyncRecordScopes';

const MOONLIGHT_CLOUD_SYNC_SCOPES: MoonlightCloudSyncScope[] = [
  'settings', 'hosts', 'profiles', 'trust', 'identity'
];

// A new owner starts with no Moonlight logical records selected. Physical
// table registration is a separate D2-07 gate and is also disabled by default.
export const MOONLIGHT_CLOUD_SYNC_SELECTION_DEFAULT:
  MoonlightCloudSyncScope[] = [];

export function moonlightCloudSyncScopes(): MoonlightCloudSyncScope[] {
  return MOONLIGHT_CLOUD_SYNC_SCOPES.slice();
}

export function normalizeMoonlightCloudSyncSelection(
  selected: string[],
  identityCapabilityReady: boolean = false
): MoonlightCloudSyncScope[] {
  const result: MoonlightCloudSyncScope[] = [];
  for (let i = 0; i < MOONLIGHT_CLOUD_SYNC_SCOPES.length; i++) {
    const scope: MoonlightCloudSyncScope = MOONLIGHT_CLOUD_SYNC_SCOPES[i];
    if (scope === 'identity' && !identityCapabilityReady) { continue; }
    if (selected.indexOf(scope) >= 0) { result.push(scope); }
  }
  return result;
}

export function moonlightRecordTypeToSyncScope(
  recordType: MoonlightRecordType
): MoonlightCloudSyncScope {
  if (recordType === 'host') { return 'hosts'; }
  if (recordType === 'profile') { return 'profiles'; }
  if (recordType === 'trust') { return 'trust'; }
  if (recordType === 'secret') { return 'identity'; }
  return 'settings';
}

export function isMoonlightRecordTypeSelected(
  recordType: MoonlightRecordType,
  selected: string[],
  identityCapabilityReady: boolean = false
): boolean {
  const normalized: MoonlightCloudSyncScope[] =
    normalizeMoonlightCloudSyncSelection(
      selected, identityCapabilityReady);
  return normalized.indexOf(
    moonlightRecordTypeToSyncScope(recordType)) >= 0;
}

export function hasMoonlightCloudSyncBusinessSelection(
  selected: string[],
  identityCapabilityReady: boolean = false
): boolean {
  return normalizeMoonlightCloudSyncSelection(
    selected, identityCapabilityReady).length > 0;
}

export function moonlightIdentitySyncAllowed(
  selected: string[],
  identityCapabilityReady: boolean,
  cryptoConfigured: boolean
): boolean {
  return identityCapabilityReady && cryptoConfigured &&
    normalizeMoonlightCloudSyncSelection(selected, true)
      .indexOf('identity') >= 0;
}

export function moonlightCloudSyncSelectionEquals(
  left: string[], right: string[],
  identityCapabilityReady: boolean = false
): boolean {
  const normalizedLeft: MoonlightCloudSyncScope[] =
    normalizeMoonlightCloudSyncSelection(left, identityCapabilityReady);
  const normalizedRight: MoonlightCloudSyncScope[] =
    normalizeMoonlightCloudSyncSelection(right, identityCapabilityReady);
  if (normalizedLeft.length !== normalizedRight.length) { return false; }
  for (let i = 0; i < normalizedLeft.length; i++) {
    if (normalizedLeft[i] !== normalizedRight[i]) { return false; }
  }
  return true;
}
