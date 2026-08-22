import { RustDeskTargetDevice } from './RemoteOrientationPolicy';

/**
 * Process-memory-only RustDesk host draft used while the user temporarily
 * leaves the add-host Sheet to create or edit a relay. Passwords in this
 * object must never be persisted, routed, synchronized, or logged.
 */
export class RustDeskHostAddDraft {
  step: number = 1;
  direct: boolean = false;
  useLan: boolean = false;
  selectedLanPeerId: string = '';
  lanAddressMode: string = '';
  label: string = '';
  controlId: string = '';
  directHost: string = '';
  directPortText: string = '21118';
  relayId: string = '';
  password: string = '';
  passwordMode: number = 0;
  // 只保存本机验证器条目 ID，不包含 TOTP secret。
  totpEntryId: string = '';
  totpAutoSubmit: boolean = false;
  targetDevice: RustDeskTargetDevice = 'computer';
  adaptiveOrientation: boolean = false;
}

interface PendingRustDeskHostAddDraft {
  ownerScopeId: string;
  storeIdentity: string;
  generation: number;
  draft: RustDeskHostAddDraft;
  createdAt: number;
}

export const RUSTDESK_HOST_ADD_HANDOFF_TTL_MS: number = 5 * 60 * 1000;

export function cloneRustDeskHostAddDraft(
  source: RustDeskHostAddDraft
): RustDeskHostAddDraft {
  const result = new RustDeskHostAddDraft();
  result.step = source.step === 2 ? 2 : 1;
  result.direct = source.direct;
  result.useLan = source.useLan;
  result.selectedLanPeerId = source.selectedLanPeerId;
  result.lanAddressMode = source.lanAddressMode === 'static' || source.lanAddressMode === 'dynamic'
    ? source.lanAddressMode : '';
  result.label = source.label;
  result.controlId = source.controlId;
  result.directHost = source.directHost;
  result.directPortText = source.directPortText;
  result.relayId = source.relayId;
  result.password = source.password;
  result.passwordMode = source.passwordMode === 1 ? 1 : 0;
  result.totpEntryId = source.totpEntryId;
  result.totpAutoSubmit = source.totpAutoSubmit && result.totpEntryId !== '';
  result.targetDevice = source.targetDevice;
  result.adaptiveOrientation =
    source.targetDevice === 'phone' && source.adaptiveOrientation;
  return result;
}

/**
 * One-shot, owner/generation-bound handoff. A scope mismatch destroys the
 * pending plaintext immediately instead of attempting to rebind it.
 */
export class RustDeskHostAddHandoff {
  private static instance: RustDeskHostAddHandoff;
  private pending: PendingRustDeskHostAddDraft | null = null;

  static getInstance(): RustDeskHostAddHandoff {
    if (!RustDeskHostAddHandoff.instance) {
      RustDeskHostAddHandoff.instance =
        new RustDeskHostAddHandoff();
    }
    return RustDeskHostAddHandoff.instance;
  }

  put(ownerScopeId: string, storeIdentity: string, generation: number,
    draft: RustDeskHostAddDraft): boolean {
    const owner: string = ownerScopeId.trim();
    const store: string = storeIdentity.trim();
    if (owner === '' || store === '' || generation < 1) {
      this.clearAll();
      return false;
    }
    this.pending = {
      ownerScopeId: owner,
      storeIdentity: store,
      generation,
      draft: cloneRustDeskHostAddDraft(draft),
      createdAt: Date.now()
    };
    return true;
  }

  has(ownerScopeId: string, storeIdentity: string,
    generation: number): boolean {
    this.removeExpired();
    if (!this.scopeMatches(ownerScopeId, storeIdentity, generation)) {
      if (this.pending !== null) { this.clearAll(); }
      return false;
    }
    return this.pending !== null;
  }

  selectRelay(ownerScopeId: string, storeIdentity: string,
    generation: number, relayId: string): boolean {
    this.removeExpired();
    if (!this.scopeMatches(ownerScopeId, storeIdentity, generation)) {
      if (this.pending !== null) { this.clearAll(); }
      return false;
    }
    if (this.pending === null) { return false; }
    const normalizedRelayId: string = relayId.trim();
    if (normalizedRelayId !== '') {
      this.pending.draft.relayId = normalizedRelayId;
      this.pending.draft.direct = false;
      this.pending.draft.useLan = false;
      this.pending.draft.lanAddressMode = '';
    }
    return true;
  }

  take(ownerScopeId: string, storeIdentity: string,
    generation: number): RustDeskHostAddDraft | null {
    this.removeExpired();
    if (!this.scopeMatches(ownerScopeId, storeIdentity, generation)) {
      if (this.pending !== null) { this.clearAll(); }
      return null;
    }
    if (this.pending === null) { return null; }
    const result: RustDeskHostAddDraft =
      cloneRustDeskHostAddDraft(this.pending.draft);
    this.clearAll();
    return result;
  }

  clearAll(): void {
    this.pending = null;
  }

  private scopeMatches(ownerScopeId: string, storeIdentity: string,
    generation: number): boolean {
    return this.pending !== null &&
      this.pending.ownerScopeId === ownerScopeId.trim() &&
      this.pending.storeIdentity === storeIdentity.trim() &&
      this.pending.generation === generation;
  }

  private removeExpired(): void {
    if (this.pending !== null &&
      Date.now() - this.pending.createdAt >
      RUSTDESK_HOST_ADD_HANDOFF_TTL_MS) {
      this.clearAll();
    }
  }
}
