import {
  MoonlightCloudSyncScope,
  moonlightForcedCloudSyncSelection,
  normalizeMoonlightCloudSyncSelection
} from './MoonlightCloudSyncSelectionPolicy';

export type MoonlightCloudDisplayState =
  'off' | 'unavailable' | 'bootstrap' | 'ready' | 'pending' |
  'partial_failure' | 'quarantined' | 'crypto_locked';

export interface MoonlightCloudStatusInput {
  accountOnline: boolean;
  platformIdentityVerified: boolean;
  cloudSchemaReady: boolean;
  physicalSelected: boolean;
  selectedScopes: string[];
  identityCapabilityReady: boolean;
  cryptoConfigured: boolean;
  cryptoUnlocked: boolean;
  bootstrapComplete: boolean;
  pendingUploadCount: number;
  quarantineCount: number;
  lastSuccessAt: number;
  lastErrorCode: string;
}

export interface MoonlightCloudStatusSnapshot {
  state: MoonlightCloudDisplayState;
  physicalSelected: boolean;
  scopes: MoonlightCloudSyncScope[];
  bootstrapComplete: boolean;
  pendingUploadCount: number;
  quarantineCount: number;
  lastSuccessAt: number;
  lastErrorCode: string;
  canUpload: boolean;
  identityScopeLocked: boolean;
}

function boundedCount(value: number): number {
  return Number.isSafeInteger(value) && value >= 0 ? value : 0;
}

export function resolveMoonlightCloudStatus(
  input: MoonlightCloudStatusInput
): MoonlightCloudStatusSnapshot {
  // Empty/partial values are legacy persistence artifacts, not a runtime
  // subtype choice. Report the fixed public set while the physical switch
  // alone decides whether transfer is active.
  const normalizedLegacy: MoonlightCloudSyncScope[] =
    normalizeMoonlightCloudSyncSelection(
      input.selectedScopes, input.identityCapabilityReady);
  const scopes: MoonlightCloudSyncScope[] =
    normalizedLegacy.join(',') === 'settings,hosts,profiles'
      ? normalizedLegacy : moonlightForcedCloudSyncSelection();
  const pending: number = boundedCount(input.pendingUploadCount);
  const quarantine: number = boundedCount(input.quarantineCount);
  const identitySelected: boolean = scopes.indexOf('identity') >= 0;
  const identityLocked: boolean = identitySelected &&
    (!input.cryptoConfigured || !input.cryptoUnlocked);
  let state: MoonlightCloudDisplayState = 'ready';
  if (!input.physicalSelected) { state = 'off'; }
  else if (!input.accountOnline || !input.platformIdentityVerified ||
      !input.cloudSchemaReady) { state = 'unavailable'; }
  else if (!input.bootstrapComplete) { state = 'bootstrap'; }
  else if (quarantine > 0) { state = 'quarantined'; }
  else if (input.lastErrorCode.trim() !== '') { state = 'partial_failure'; }
  else if (identityLocked) { state = 'crypto_locked'; }
  else if (pending > 0) { state = 'pending'; }
  return {
    state: state,
    physicalSelected: input.physicalSelected,
    scopes: scopes,
    bootstrapComplete: input.bootstrapComplete,
    pendingUploadCount: pending,
    quarantineCount: quarantine,
    lastSuccessAt: Number.isSafeInteger(input.lastSuccessAt) &&
      input.lastSuccessAt > 0 ? input.lastSuccessAt : 0,
    lastErrorCode: input.lastErrorCode,
    canUpload: state === 'ready' || state === 'pending',
    identityScopeLocked: identityLocked
  };
}
