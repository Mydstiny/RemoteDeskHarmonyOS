export type MoonlightDeletionCommandType =
  'cancel_sync' | 'delete_cloud_data' | 'delete_local_data' |
  'forget_host' | 'unpair_host' | 'delete_profile';

export interface MoonlightDeletionContext {
  ownerScopeId: string;
  hostId: string;
  profileId: string;
  physicalCloudSelected: boolean;
  selectedLogicalScopeCount: number;
  settingsRecordCount: number;
  hostRecordCount: number;
  profileRecordCount: number;
  trustRecordCount: number;
  identityRecordCount: number;
  appCacheCount: number;
  localRuntimeStateCount: number;
  secureIdentityCount: number;
}

export interface MoonlightDeletionImpact {
  valid: boolean;
  command: MoonlightDeletionCommandType;
  localRowsRemoved: number;
  cacheRowsRemoved: number;
  localRuntimeStatesRemoved: number;
  secureIdentitiesRemoved: number;
  cloudTombstonesRequired: number;
  selectionChanged: boolean;
  hostRequestBestEffort: boolean;
  localDataPreserved: boolean;
  cloudDataPreserved: boolean;
  identityPreserved: boolean;
  waitForCloudTerminal: boolean;
  confirmationLevel: 'none' | 'normal' | 'danger';
}

export function moonlightDeletionCommandTypeIsKnown(value: string): boolean {
  return value === 'cancel_sync' || value === 'delete_cloud_data' ||
    value === 'delete_local_data' || value === 'forget_host' ||
    value === 'unpair_host' || value === 'delete_profile';
}

function countsAreValid(context: MoonlightDeletionContext): boolean {
  const values: number[] = [
    context.selectedLogicalScopeCount, context.settingsRecordCount,
    context.hostRecordCount, context.profileRecordCount,
    context.trustRecordCount, context.identityRecordCount,
    context.appCacheCount, context.localRuntimeStateCount,
    context.secureIdentityCount
  ];
  for (let i = 0; i < values.length; i++) {
    if (!Number.isSafeInteger(values[i]) || values[i] < 0) { return false; }
  }
  return context.ownerScopeId.trim() !== '';
}

export function resolveMoonlightDeletionImpact(
  command: MoonlightDeletionCommandType,
  context: MoonlightDeletionContext
): MoonlightDeletionImpact {
  const base: MoonlightDeletionImpact = {
    valid: countsAreValid(context) &&
      moonlightDeletionCommandTypeIsKnown(command),
    command: command,
    localRowsRemoved: 0,
    cacheRowsRemoved: 0,
    localRuntimeStatesRemoved: 0,
    secureIdentitiesRemoved: 0,
    cloudTombstonesRequired: 0,
    selectionChanged: false,
    hostRequestBestEffort: false,
    localDataPreserved: true,
    cloudDataPreserved: true,
    identityPreserved: true,
    waitForCloudTerminal: false,
    confirmationLevel: 'normal'
  };
  if (!base.valid) { return base; }
  if (command === 'cancel_sync') {
    // The logical portable set is now a fixed projection invariant. Only the
    // physical Moonlight table represents an active upload/download choice.
    base.selectionChanged = context.physicalCloudSelected;
    base.confirmationLevel = 'none';
    return base;
  }
  if (command === 'delete_cloud_data') {
    // Only public, re-pairable records are cloud eligible in Moonlight V1.
    // Pairing trust and client identity are device-bound local state, so they
    // must never be counted as cloud work or used to gate a cloud deletion.
    base.cloudTombstonesRequired = context.settingsRecordCount +
      context.hostRecordCount +
      context.profileRecordCount;
    base.cloudDataPreserved = base.cloudTombstonesRequired === 0;
    base.waitForCloudTerminal = base.cloudTombstonesRequired > 0;
    // Completing a cloud-wide deletion disables the physical table so the
    // preserved local rows cannot be republished. The fixed logical set stays
    // canonical for any later explicit re-enable.
    base.selectionChanged = context.physicalCloudSelected;
    base.confirmationLevel = 'danger';
    return base;
  }
  if (command === 'delete_local_data') {
    base.localRowsRemoved = context.settingsRecordCount +
      context.hostRecordCount +
      context.profileRecordCount + context.trustRecordCount +
      context.identityRecordCount;
    base.cacheRowsRemoved = context.appCacheCount;
    base.localRuntimeStatesRemoved = context.localRuntimeStateCount;
    base.secureIdentitiesRemoved = context.secureIdentityCount;
    base.localDataPreserved = base.localRowsRemoved === 0 &&
      base.cacheRowsRemoved === 0 &&
      base.localRuntimeStatesRemoved === 0 &&
      base.secureIdentitiesRemoved === 0;
    base.identityPreserved = context.identityRecordCount === 0 &&
      context.secureIdentityCount === 0;
    // A local-only wipe must also stop this device's Moonlight selection.
    // Leaving it enabled would allow the next cloud pull to recreate the
    // rows the user just deleted, which is both surprising and unsafe.
    base.selectionChanged = context.physicalCloudSelected;
    base.confirmationLevel = 'danger';
    return base;
  }
  if (command === 'forget_host') {
    if (context.hostId.trim() === '') { base.valid = false; return base; }
    base.localRowsRemoved = context.hostRecordCount +
      context.profileRecordCount + context.trustRecordCount;
    base.cacheRowsRemoved = context.appCacheCount;
    base.localRuntimeStatesRemoved = context.localRuntimeStateCount;
    base.cloudTombstonesRequired = context.physicalCloudSelected ?
      context.hostRecordCount + context.profileRecordCount : 0;
    base.localDataPreserved = false;
    base.cloudDataPreserved = base.cloudTombstonesRequired === 0;
    // Ordinary host deletion commits locally and lets the durable tombstone
    // converge later; it never waits for an online cloud terminal.
    base.waitForCloudTerminal = false;
    base.confirmationLevel = 'danger';
    return base;
  }
  if (command === 'unpair_host') {
    if (context.hostId.trim() === '') { base.valid = false; return base; }
    base.localRowsRemoved = context.trustRecordCount;
    base.localRuntimeStatesRemoved = context.localRuntimeStateCount;
    base.localDataPreserved = base.localRowsRemoved === 0 &&
      base.localRuntimeStatesRemoved === 0;
    // Unpair removes only device-local trust. It must never mutate the cloud
    // table, even when public host/profile synchronization is enabled.
    base.cloudTombstonesRequired = 0;
    base.hostRequestBestEffort = true;
    base.cloudDataPreserved = base.cloudTombstonesRequired === 0;
    base.waitForCloudTerminal = base.cloudTombstonesRequired > 0;
    return base;
  }
  if (context.profileId.trim() === '') { base.valid = false; return base; }
  base.localRowsRemoved = context.profileRecordCount;
  base.localRuntimeStatesRemoved = context.localRuntimeStateCount;
  base.cloudTombstonesRequired = context.physicalCloudSelected ?
    context.profileRecordCount : 0;
  base.localDataPreserved = base.localRowsRemoved === 0 &&
    base.localRuntimeStatesRemoved === 0;
  base.cloudDataPreserved = base.cloudTombstonesRequired === 0;
  base.waitForCloudTerminal = false;
  return base;
}
