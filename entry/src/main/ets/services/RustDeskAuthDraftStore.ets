export type RustDeskAuthDraftChoice = 'password' | 'request_approval';

export interface RustDeskAuthDraft {
  ownerScopeId: string
  accountGeneration: number
  hostId: string
  authChoice: RustDeskAuthDraftChoice
  password: string
  passwordMode: number
  /** Explicitly preserves the stored secret; false survives mode changes/background restore. */
  keepsStoredPassword: boolean
  /** True only while the field mirrors storage; mirrored secrets are never retained in drafts. */
  passwordFromStoredProjection: boolean
  rememberPassword: boolean
  updatedAt: number
}

function normalized(value: string): string {
  return value.trim();
}

function normalizedPasswordMode(value: number): number {
  return value === 1 ? 1 : 0;
}

export function rustDeskDraftKeepsStoredPassword(keepsStoredPassword: boolean,
  storedMode: number, selectedMode: number): boolean {
  return keepsStoredPassword &&
    normalizedPasswordMode(storedMode) === normalizedPasswordMode(selectedMode);
}

export function rustDeskDraftPasswordForConnection(draftPassword: string,
  keepsStoredPassword: boolean, storedPassword: string,
  storedMode: number, selectedMode: number): string {
  if (draftPassword.length > 0) { return draftPassword; }
  return rustDeskDraftKeepsStoredPassword(
    keepsStoredPassword, storedMode, selectedMode) ? storedPassword : '';
}

/** Re-project stored secrets against the current policy instead of reviving an old UI snapshot. */
export function rustDeskDraftPasswordForPresentation(draft: RustDeskAuthDraft | null,
  storedPassword: string, hidden: boolean): string {
  if (draft === null) { return hidden ? '' : storedPassword; }
  if (draft.passwordFromStoredProjection) { return hidden ? '' : storedPassword; }
  return draft.password;
}

function draftKey(ownerScopeId: string, accountGeneration: number,
  hostId: string): string {
  return normalized(ownerScopeId) + '\u001f' + accountGeneration.toString() +
    '\u001f' + normalized(hostId);
}

function cloneDraft(draft: RustDeskAuthDraft): RustDeskAuthDraft {
  return {
    ownerScopeId: draft.ownerScopeId,
    accountGeneration: draft.accountGeneration,
    hostId: draft.hostId,
    authChoice: draft.authChoice,
    password: draft.password,
    passwordMode: draft.passwordMode,
    keepsStoredPassword: draft.keepsStoredPassword,
    passwordFromStoredProjection: draft.passwordFromStoredProjection,
    rememberPassword: draft.rememberPassword,
    updatedAt: draft.updatedAt
  };
}

/**
 * Process-memory-only RustDesk authentication draft storage.
 *
 * Passwords deliberately never enter Preferences, RemoteHost JSON, cloud
 * extensions, backup payloads, or AppStorage. The owner/generation fence also
 * prevents a draft from becoming visible after an account transition.
 */
export class RustDeskAuthDraftStore {
  private static instance: RustDeskAuthDraftStore | null = null;
  private drafts: Map<string, RustDeskAuthDraft> = new Map();

  static getInstance(): RustDeskAuthDraftStore {
    if (RustDeskAuthDraftStore.instance === null) {
      RustDeskAuthDraftStore.instance = new RustDeskAuthDraftStore();
    }
    return RustDeskAuthDraftStore.instance;
  }

  save(draft: RustDeskAuthDraft): boolean {
    const ownerScopeId: string = normalized(draft.ownerScopeId);
    const hostId: string = normalized(draft.hostId);
    if (ownerScopeId === '' || hostId === '' ||
      !Number.isFinite(draft.accountGeneration) || draft.accountGeneration < 0) {
      return false;
    }
    const next: RustDeskAuthDraft = cloneDraft(draft);
    next.ownerScopeId = ownerScopeId;
    next.hostId = hostId;
    next.accountGeneration = Math.floor(draft.accountGeneration);
    next.authChoice = draft.authChoice === 'request_approval' ?
      'request_approval' : 'password';
    next.passwordMode = draft.passwordMode === 1 ? 1 : 0;
    next.keepsStoredPassword = draft.keepsStoredPassword === true;
    next.passwordFromStoredProjection = draft.passwordFromStoredProjection === true;
    if (next.passwordFromStoredProjection) { next.password = ''; }
    next.updatedAt = Date.now();
    this.drafts.set(draftKey(ownerScopeId, next.accountGeneration, hostId), next);
    return true;
  }

  load(ownerScopeId: string, accountGeneration: number,
    hostId: string): RustDeskAuthDraft | null {
    const key: string = draftKey(ownerScopeId, accountGeneration, hostId);
    const draft: RustDeskAuthDraft | undefined = this.drafts.get(key);
    return draft === undefined ? null : cloneDraft(draft);
  }

  clear(ownerScopeId: string, accountGeneration: number, hostId: string): void {
    this.drafts.delete(draftKey(ownerScopeId, accountGeneration, hostId));
  }

  clearHost(hostId: string): void {
    const normalizedHostId: string = normalized(hostId);
    if (normalizedHostId === '') { return; }
    const keys: string[] = [];
    this.drafts.forEach((draft: RustDeskAuthDraft, key: string): void => {
      if (draft.hostId === normalizedHostId) { keys.push(key); }
    });
    keys.forEach((key: string): void => { this.drafts.delete(key); });
  }

  clearAll(): void {
    this.drafts.clear();
  }
}
