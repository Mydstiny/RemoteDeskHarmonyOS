/**
 * Runtime capability contract for the SSH local-file side.
 *
 * Device names are deliberately absent. The caller must pass the APIs that
 * are available in the current window/runtime and keep provider I/O outside
 * ArkUI callbacks.
 */
export type SshLocalProviderKind = 'directory' | 'transferBox' | 'none';
export type SshLocalProviderState = 'ready' | 'needsAuthorization' | 'unavailable';
export type SshLocalProviderAuthorization = 'unknown' | 'granted' | 'revoked';
export type SshLocalProviderAction = 'browse' | 'import' | 'export' | 'persistAuthorization' | 'externalDrag';

export interface SshLocalProviderCapabilities {
  folderSelection: boolean;
  folderAuthorization: boolean;
  folderObtain: boolean;
  pickerImport: boolean;
  pickerExport: boolean;
  share: boolean;
  externalDrag: boolean;
}

export interface SshLocalProviderPlan {
  kind: SshLocalProviderKind;
  state: SshLocalProviderState;
  canBrowse: boolean;
  canImport: boolean;
  canExport: boolean;
  canPersistAuthorization: boolean;
  supportsRandomAccess: boolean;
  supportsAtomicReplace: boolean;
  supportsExternalDrag: boolean;
  supportsShare: boolean;
}

function unavailablePlan(): SshLocalProviderPlan {
  return {
    kind: 'none', state: 'unavailable', canBrowse: false, canImport: false,
    canExport: false, canPersistAuthorization: false, supportsRandomAccess: false,
    supportsAtomicReplace: false, supportsExternalDrag: false, supportsShare: false
  };
}

/** Choose the strongest provider contract that the runtime actually exposes. */
export function resolveSshLocalProviderPlan(
  capabilities: SshLocalProviderCapabilities): SshLocalProviderPlan {
  const hasFolderProvider: boolean = capabilities.folderSelection &&
    capabilities.folderAuthorization && capabilities.folderObtain;
  if (hasFolderProvider) {
    return {
      kind: 'directory', state: 'needsAuthorization', canBrowse: true, canImport: true,
      canExport: true, canPersistAuthorization: true, supportsRandomAccess: true,
      supportsAtomicReplace: false, supportsExternalDrag: capabilities.externalDrag,
      supportsShare: capabilities.share
    };
  }
  if (capabilities.pickerImport || capabilities.pickerExport) {
    return {
      kind: 'transferBox', state: 'ready', canBrowse: true,
      canImport: capabilities.pickerImport, canExport: capabilities.pickerExport,
      canPersistAuthorization: false, supportsRandomAccess: true,
      supportsAtomicReplace: true,
      supportsExternalDrag: capabilities.externalDrag && capabilities.pickerImport &&
        capabilities.pickerExport,
      supportsShare: capabilities.share
    };
  }
  return unavailablePlan();
}

/** Resolve authorization after restart, revocation, or account transition. */
export function resolveSshLocalProviderState(plan: SshLocalProviderPlan,
  authorization: SshLocalProviderAuthorization): SshLocalProviderState {
  if (plan.kind === 'none') { return 'unavailable'; }
  if (plan.kind === 'directory' && authorization !== 'granted') {
    return 'needsAuthorization';
  }
  return 'ready';
}

export function canUseSshLocalProviderAction(plan: SshLocalProviderPlan,
  state: SshLocalProviderState, action: SshLocalProviderAction): boolean {
  if (action === 'persistAuthorization') {
    return plan.canPersistAuthorization && plan.kind === 'directory';
  }
  if (state !== 'ready') { return false; }
  if (action === 'browse') { return plan.canBrowse; }
  if (action === 'import') { return plan.canImport; }
  if (action === 'export') { return plan.canExport; }
  return plan.supportsExternalDrag;
}
