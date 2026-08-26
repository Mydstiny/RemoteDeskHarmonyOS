import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from './AccountScopePolicy';
import {
  MOONLIGHT_CLOUD_SYNC_SELECTION_DEFAULT,
  MOONLIGHT_CLOUD_SYNC_SELECTION_KEY,
  MoonlightCloudSyncScope,
  moonlightForcedCloudSyncSelection,
  moonlightCloudSyncSelectionEquals
} from './MoonlightCloudSyncSelectionPolicy';

export const MOONLIGHT_CLOUD_SYNC_PREFERENCES_NAME: string =
  'RemoteDesktopMoonlightPrefs';

export type MoonlightSelectionStoreCode =
  'ok' | 'unchanged' | 'stale_lease' | 'invalid_owner' |
  'projection_failed' | 'persist_failed' | 'rollback_failed' |
  'reconcile_pending';

export interface MoonlightSelectionStoreResult {
  ok: boolean;
  code: MoonlightSelectionStoreCode;
  selected: MoonlightCloudSyncScope[];
  projectionChanged: boolean;
  durableChanged: boolean;
}

/**
 * Preferences and RDB stay behind a port so tests can prove transaction
 * ordering without opening global singletons. The live CloudStore adapter
 * binds both surfaces to the same account lease.
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
    _identityCapabilityReady: boolean = false): boolean {
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    if (!this.leaseIsCurrent(captured)) { return false; }
    const key: string =
      moonlightCloudSyncSelectionPreferenceKey(captured.ownerScopeId);
    if (key === '') { return false; }
    const next: MoonlightCloudSyncScope[] =
      moonlightForcedCloudSyncSelection();
    const stored: string | null =
      this.port.readSelectionPreference(captured, key);
    if (!this.leaseIsCurrent(captured)) { return false; }
    this.ownerScopeId = captured.ownerScopeId;
    this.selected = next;
    // Old builds persisted empty, partial or malformed scope arrays. Runtime
    // behavior must not depend on repairing Preferences successfully: use the
    // complete set immediately and rewrite the legacy value on a best-effort
    // basis. A later activation retries when the preference service recovers.
    const canonical: string = JSON.stringify(next);
    if (stored !== canonical) {
      this.port.writeSelectionPreference(captured, key, canonical);
    }
    if (!this.leaseIsCurrent(captured)) {
      this.ownerScopeId = '';
      this.selected = MOONLIGHT_CLOUD_SYNC_SELECTION_DEFAULT.slice();
      return false;
    }
    return true;
  }

  selectedScopes(): MoonlightCloudSyncScope[] {
    return this.selected.slice();
  }

  /**
   * Preferences are the durable user intent. Re-apply that intent after an
   * authoritative cloud-first operation so a process/account switch between
   * projection and preference persistence cannot leave stale localonly bits.
   */
  reconcileProjection(lease: AccountSessionLease): boolean {
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    if (!this.leaseIsCurrent(captured) ||
        captured.ownerScopeId !== this.ownerScopeId) {
      return false;
    }
    const selected: MoonlightCloudSyncScope[] = this.selected.slice();
    return this.port.replaceMoonlightProjection(
      captured, selected, selected) && this.leaseIsCurrent(captured);
  }

  stageSelectedScopes(lease: AccountSessionLease, _scopes: string[],
    _identityCapabilityReady: boolean = false): boolean {
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    if (!this.leaseIsCurrent(captured) ||
        captured.ownerScopeId !== this.ownerScopeId) { return false; }
    // Recovery code may replay a legacy partial/empty snapshot. The current
    // contract has no logical subtype switch, so every staged state converges
    // to the dependency-complete portable set.
    this.selected = moonlightForcedCloudSyncSelection();
    return true;
  }

  replaceSelectedScopes(lease: AccountSessionLease, _scopes: string[],
    _identityCapabilityReady: boolean = false): MoonlightSelectionStoreResult {
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
      moonlightForcedCloudSyncSelection();
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
      // Projection belongs to the captured owner, but Preferences still hold
      // the previous intent. The next activation always reloads Preferences
      // and reconciles that owner's projection before reopening mutations.
      return result(false, 'reconcile_pending', previous, true, false);
    }
    const key: string =
      moonlightCloudSyncSelectionPreferenceKey(captured.ownerScopeId);
    if (this.port.writeSelectionPreference(
      captured, key, JSON.stringify(next))) {
      if (!this.leaseIsCurrent(captured)) {
        // Both durable surfaces accepted `next`; only the lease changed before
        // the caller could observe completion. Keep the committed truth in the
        // result and let the next activation verify/reconcile it.
        this.selected = next;
        return result(false, 'reconcile_pending', next, true, true);
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
