export type MoonlightDeletionCommandType =
  'cancel_sync' | 'delete_cloud_data' | 'delete_local_data' |
  'forget_host' | 'unpair_host' | 'delete_profile';

export interface MoonlightDeletionContext {
  ownerScopeId: string;
  hostId: string;
  profileId: string;
  physicalCloudSelected: boolean;
  hostRecordCount: number;
  profileRecordCount: number;
  trustRecordCount: number;
  identityRecordCount: number;
  appCacheCount: number;
}

export interface MoonlightDeletionImpact {
  valid: boolean;
  command: MoonlightDeletionCommandType;
  localRowsRemoved: number;
  cacheRowsRemoved: number;
  cloudTombstonesRequired: number;
  selectionChanged: boolean;
  hostRequestBestEffort: boolean;
  localDataPreserved: boolean;
  cloudDataPreserved: boolean;
  identityPreserved: boolean;
  waitForCloudTerminal: boolean;
  confirmationLevel: 'none' | 'normal' | 'danger';
}

function countsAreValid(context: MoonlightDeletionContext): boolean {
  const values: number[] = [
    context.hostRecordCount, context.profileRecordCount,
    context.trustRecordCount, context.identityRecordCount,
    context.appCacheCount
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
    valid: countsAreValid(context),
    command: command,
    localRowsRemoved: 0,
    cacheRowsRemoved: 0,
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
    base.selectionChanged = true;
    base.confirmationLevel = 'none';
    return base;
  }
  if (command === 'delete_cloud_data') {
    base.cloudTombstonesRequired = context.hostRecordCount +
      context.profileRecordCount + context.trustRecordCount +
      context.identityRecordCount;
    base.cloudDataPreserved = false;
    base.waitForCloudTerminal = base.cloudTombstonesRequired > 0;
    base.confirmationLevel = 'danger';
    return base;
  }
  if (command === 'delete_local_data') {
    base.localRowsRemoved = context.hostRecordCount +
      context.profileRecordCount + context.trustRecordCount +
      context.identityRecordCount;
    base.cacheRowsRemoved = context.appCacheCount;
    base.localDataPreserved = false;
    base.confirmationLevel = 'danger';
    return base;
  }
  if (command === 'forget_host') {
    if (context.hostId.trim() === '') { base.valid = false; return base; }
    base.localRowsRemoved = context.hostRecordCount +
      context.profileRecordCount + context.trustRecordCount;
    base.cacheRowsRemoved = context.appCacheCount;
    base.cloudTombstonesRequired = context.physicalCloudSelected ?
      base.localRowsRemoved : 0;
    base.localDataPreserved = false;
    base.cloudDataPreserved = base.cloudTombstonesRequired === 0;
    base.waitForCloudTerminal = base.cloudTombstonesRequired > 0;
    base.confirmationLevel = 'danger';
    return base;
  }
  if (command === 'unpair_host') {
    if (context.hostId.trim() === '') { base.valid = false; return base; }
    base.localRowsRemoved = context.trustRecordCount;
    base.cloudTombstonesRequired = context.physicalCloudSelected ?
      context.trustRecordCount : 0;
    base.hostRequestBestEffort = true;
    base.cloudDataPreserved = base.cloudTombstonesRequired === 0;
    base.waitForCloudTerminal = base.cloudTombstonesRequired > 0;
    return base;
  }
  if (context.profileId.trim() === '') { base.valid = false; return base; }
  base.localRowsRemoved = context.profileRecordCount;
  base.cloudTombstonesRequired = context.physicalCloudSelected ?
    context.profileRecordCount : 0;
  base.localDataPreserved = context.profileRecordCount === 0;
  base.cloudDataPreserved = base.cloudTombstonesRequired === 0;
  base.waitForCloudTerminal = base.cloudTombstonesRequired > 0;
  return base;
}
