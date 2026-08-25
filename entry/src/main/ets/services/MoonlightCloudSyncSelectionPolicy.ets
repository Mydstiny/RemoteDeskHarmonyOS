import { MoonlightRecordType } from '../model/MoonlightRecord';

export type MoonlightCloudSyncScope =
  'settings' | 'hosts' | 'profiles' | 'trust' | 'identity';

export const MOONLIGHT_CLOUD_SYNC_SELECTION_KEY: string =
  'moonlightCloudSyncRecordScopes';

const MOONLIGHT_CLOUD_SYNC_SCOPES: MoonlightCloudSyncScope[] = [
  'settings', 'hosts', 'profiles', 'trust', 'identity'
];

// Trust proves a pairing made by one device identity and therefore cannot be
// activated on another device. Client private identity material is kept in
// Asset Store and is never exported. V1 cloud sync deliberately supports only
// public, re-pairable records.
const MOONLIGHT_CLOUD_SYNC_SELECTABLE_SCOPES: MoonlightCloudSyncScope[] = [
  'settings', 'hosts', 'profiles'
];

// Moonlight exposes one physical cloud category, not three independently
// configurable record scopes. Keeping every portable record type selected as
// one dependency-complete unit avoids host/profile skew and upgrades old
// partial preferences without changing the separate physical table switch.
export const MOONLIGHT_CLOUD_SYNC_SELECTION_DEFAULT:
  MoonlightCloudSyncScope[] = [
    'settings', 'hosts', 'profiles'
  ];

export function moonlightCloudSyncScopes(): MoonlightCloudSyncScope[] {
  return MOONLIGHT_CLOUD_SYNC_SCOPES.slice();
}

export function moonlightCloudSyncSelectableScopes(): MoonlightCloudSyncScope[] {
  return MOONLIGHT_CLOUD_SYNC_SELECTABLE_SCOPES.slice();
}

/** Canonical runtime selection for the single Moonlight cloud category. */
export function moonlightForcedCloudSyncSelection():
  MoonlightCloudSyncScope[] {
  return MOONLIGHT_CLOUD_SYNC_SELECTION_DEFAULT.slice();
}

export function normalizeMoonlightCloudSyncSelection(
  selected: string[],
  _identityCapabilityReady: boolean = false
): MoonlightCloudSyncScope[] {
  const result: MoonlightCloudSyncScope[] = [];
  for (let i = 0; i < MOONLIGHT_CLOUD_SYNC_SELECTABLE_SCOPES.length; i++) {
    const scope: MoonlightCloudSyncScope = MOONLIGHT_CLOUD_SYNC_SELECTABLE_SCOPES[i];
    // Profiles are host-owned and cannot be interpreted on a device that did
    // not also select the host directory. Drop an orphaned persisted profile
    // scope instead of silently broadening consent by auto-selecting hosts.
    if (scope === 'profiles' && selected.indexOf('hosts') < 0) {
      continue;
    }
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

/**
 * Consent expansion needs a registered physical table and a cloud-first
 * barrier. Consent reduction is always local-only and must remain available
 * while the optional table, account service or network is unavailable.
 */
export function moonlightCloudSyncSelectionExpands(
  previous: string[], next: string[],
  identityCapabilityReady: boolean = false
): boolean {
  const normalizedPrevious: MoonlightCloudSyncScope[] =
    normalizeMoonlightCloudSyncSelection(
      previous, identityCapabilityReady);
  const normalizedNext: MoonlightCloudSyncScope[] =
    normalizeMoonlightCloudSyncSelection(
      next, identityCapabilityReady);
  for (let i = 0; i < normalizedNext.length; i++) {
    if (normalizedPrevious.indexOf(normalizedNext[i]) < 0) { return true; }
  }
  return false;
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

/**
 * `localOnly` is durable mutation provenance, not a cache-difference bit.
 * Reconciliation may clear a pending local bit after proving an exact cloud
 * mirror, but absence/difference must never manufacture a new local mutation:
 * doing so could resurrect a deletion received from another device.
 */
export function moonlightProjectionLocalOnlyAfterReconcile(
  currentLocalOnly: number,
  selected: boolean,
  cloudRecordMatches: boolean
): number {
  if (currentLocalOnly !== 0 && currentLocalOnly !== 1) { return -1; }
  return selected && cloudRecordMatches ? 0 : currentLocalOnly;
}
