import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from './AccountScopePolicy';
import {
  MOONLIGHT_CLOUD_SYNC_SELECTION_DEFAULT,
  MOONLIGHT_CLOUD_SYNC_SELECTION_KEY,
  MoonlightCloudSyncScope,
  moonlightCloudSyncSelectionEquals,
  normalizeMoonlightCloudSyncSelection
} from './MoonlightCloudSyncSelectionPolicy';

export const MOONLIGHT_CLOUD_SYNC_PREFERENCES_NAME: string =
  'RemoteDesktopMoonlightPrefs';

export type MoonlightSelectionStoreCode =
  'ok' | 'unchanged' | 'stale_lease' | 'invalid_owner' |
  'projection_failed' | 'persist_failed' | 'rollback_failed';

export interface MoonlightSelectionStoreResult {
  ok: boolean;
  code: MoonlightSelectionStoreCode;
  selected: MoonlightCloudSyncScope[];
  projectionChanged: boolean;
  durableChanged: boolean;
}

/**
 * D2 keeps Preferences and RDB behind a port so tests can prove transaction
 * ordering without opening global singletons. D3 supplies the owner-scoped
 * Preferences and CloudStore adapter after account lifecycle wiring exists.
 */
export interface MoonlightCloudSyncSelectionStorePort {
  currentAccountLease(): AccountSessionLease | null;
  isLeaseCurrent(lease: AccountSessionLease): boolean;
  readSelectionPreference(
    lease: AccountSessionLease, key: string
  ): string | null;
  writeSelectionPreference(
    lease: AccountSessionLease, key: string, value: string
  ): boolean;
  replaceMoonlightProjection(
    lease: AccountSessionLease,
    previous: MoonlightCloudSyncScope[],
    next: MoonlightCloudSyncScope[]
  ): boolean;
}

function result(ok: boolean, code: MoonlightSelectionStoreCode,
  selected: MoonlightCloudSyncScope[], projectionChanged: boolean,
  durableChanged: boolean): MoonlightSelectionStoreResult {
  return {
    ok: ok,
    code: code,
    selected: selected.slice(),
    projectionChanged: projectionChanged,
    durableChanged: durableChanged
  };
}

export function moonlightCloudSyncSelectionPreferenceKey(
  ownerScopeId: string
): string {
  const owner: string = ownerScopeId.trim();
  return owner === '' ? '' :
    MOONLIGHT_CLOUD_SYNC_SELECTION_KEY + ':' + owner;
}

export class MoonlightCloudSyncSelectionStore {
  private readonly port: MoonlightCloudSyncSelectionStorePort;
  private selected: MoonlightCloudSyncScope[] =
    MOONLIGHT_CLOUD_SYNC_SELECTION_DEFAULT.slice();
  private ownerScopeId: string = '';

  constructor(port: MoonlightCloudSyncSelectionStorePort) {
    this.port = port;
  }

  init(lease: AccountSessionLease,
    identityCapabilityReady: boolean = false): boolean {
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    if (!this.leaseIsCurrent(captured)) { return false; }
    const key: string =
      moonlightCloudSyncSelectionPreferenceKey(captured.ownerScopeId);
    if (key === '') { return false; }
    let next: MoonlightCloudSyncScope[] =
      MOONLIGHT_CLOUD_SYNC_SELECTION_DEFAULT.slice();
    const stored: string | null =
      this.port.readSelectionPreference(captured, key);
    if (stored !== null && stored !== '') {
      try {
        const parsed: string[] = JSON.parse(stored) as string[];
        if (Array.isArray(parsed)) {
          next = normalizeMoonlightCloudSyncSelection(
            parsed, identityCapabilityReady);
        }
      } catch (_error) {
        next = MOONLIGHT_CLOUD_SYNC_SELECTION_DEFAULT.slice();
      }
    }
    if (!this.leaseIsCurrent(captured)) { return false; }
    this.ownerScopeId = captured.ownerScopeId;
    this.selected = next;
    return true;
  }

  selectedScopes(): MoonlightCloudSyncScope[] {
    return this.selected.slice();
  }

  stageSelectedScopes(lease: AccountSessionLease, scopes: string[],
    identityCapabilityReady: boolean = false): boolean {
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    if (!this.leaseIsCurrent(captured) ||
        captured.ownerScopeId !== this.ownerScopeId) { return false; }
    this.selected = normalizeMoonlightCloudSyncSelection(
      scopes, identityCapabilityReady);
    return true;
  }

  replaceSelectedScopes(lease: AccountSessionLease, scopes: string[],
    identityCapabilityReady: boolean = false): MoonlightSelectionStoreResult {
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    if (!this.leaseIsCurrent(captured)) {
      return result(false, 'stale_lease', this.selected, false, false);
    }
    if (captured.ownerScopeId !== this.ownerScopeId ||
        moonlightCloudSyncSelectionPreferenceKey(
          captured.ownerScopeId) === '') {
      return result(false, 'invalid_owner', this.selected, false, false);
    }
    const previous: MoonlightCloudSyncScope[] = this.selected.slice();
    const next: MoonlightCloudSyncScope[] =
      normalizeMoonlightCloudSyncSelection(
        scopes, identityCapabilityReady);
    // Compare the complete known scope set so a previously persisted identity
    // scope is actively removed when capability becomes unavailable.
    if (moonlightCloudSyncSelectionEquals(previous, next, true)) {
      return result(true, 'unchanged', previous, false, false);
    }
    // Required order: stage memory -> RDB projection -> Preferences persist.
    this.selected = next;
    if (!this.port.replaceMoonlightProjection(
      captured, previous, next)) {
      this.selected = previous;
      return result(false, 'projection_failed', previous, false, false);
    }
    if (!this.leaseIsCurrent(captured)) {
      this.selected = previous;
      return result(false, 'stale_lease', previous, true, false);
    }
    const key: string =
      moonlightCloudSyncSelectionPreferenceKey(captured.ownerScopeId);
    if (this.port.writeSelectionPreference(
      captured, key, JSON.stringify(next))) {
      if (!this.leaseIsCurrent(captured)) {
        this.selected = previous;
        return result(false, 'stale_lease', previous, true, true);
      }
      return result(true, 'ok', next, true, true);
    }
    const projectionRolledBack: boolean =
      this.leaseIsCurrent(captured) &&
      this.port.replaceMoonlightProjection(captured, next, previous);
    this.selected = previous;
    const preferenceRolledBack: boolean =
      this.leaseIsCurrent(captured) &&
      this.port.writeSelectionPreference(
        captured, key, JSON.stringify(previous));
    return result(false,
      projectionRolledBack && preferenceRolledBack ?
        'persist_failed' : 'rollback_failed',
      previous, true, false);
  }

  private leaseIsCurrent(lease: AccountSessionLease): boolean {
    return accountSessionLeaseEquals(
      this.port.currentAccountLease(), lease) &&
      this.port.isLeaseCurrent(lease);
  }
}
