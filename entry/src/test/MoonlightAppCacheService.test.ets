import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  MoonlightAppCacheEntry,
  cloneMoonlightAppCacheEntry,
  moonlightAppCacheEntryIsValid,
  moonlightAppCacheIdentity
} from '../main/ets/model/MoonlightAppCache';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from '../main/ets/services/AccountScopePolicy';
import {
  MoonlightAppCachePort,
  MoonlightAppCacheService,
  moonlightAppCacheEvictionPlan,
  moonlightApplyCatalogRefresh
} from '../main/ets/services/MoonlightAppCacheService';

function lease(owner: string, generation: number = 1): AccountSessionLease {
  return {
    ownerScopeId: owner,
    storeIdentity: 'store-' + owner,
    generation: generation,
    storeInstanceId: generation
  };
}

function entry(owner: string, host: string, app: string,
  title: string, lastAccessedAt: number = 100,
  expiresAt: number = 1000, sizeBytes: number = 10): MoonlightAppCacheEntry {
  const value = new MoonlightAppCacheEntry();
  value.id = moonlightAppCacheIdentity(owner, host, app);
  value.userId = owner;
  value.hostId = host;
  value.appId = app;
  value.title = title;
  value.available = true;
  value.lastCatalogAt = 100;
  value.lastAccessedAt = lastAccessedAt;
  value.expiresAt = expiresAt;
  value.sizeBytes = sizeBytes;
  return value;
}

class MemoryMoonlightAppCachePort implements MoonlightAppCachePort {
  activeLease: AccountSessionLease | null = lease('owner-a');
  rows: Map<string, MoonlightAppCacheEntry> =
    new Map<string, MoonlightAppCacheEntry>();
  writeFailure: boolean = false;
  commitCount: number = 0;

  currentAccountLease(): AccountSessionLease | null {
    return this.activeLease === null ? null :
      cloneAccountSessionLease(this.activeLease);
  }

  isLeaseCurrent(candidate: AccountSessionLease): boolean {
    return accountSessionLeaseEquals(this.activeLease, candidate);
  }

  loadMoonlightAppCacheEntries(candidate: AccountSessionLease,
    hostId: string = ''): MoonlightAppCacheEntry[] | null {
    if (!this.isLeaseCurrent(candidate)) { return null; }
    const result: MoonlightAppCacheEntry[] = [];
    this.rows.forEach((row: MoonlightAppCacheEntry): void => {
      if (row.userId === candidate.ownerScopeId &&
          (hostId === '' || row.hostId === hostId)) {
        result.push(cloneMoonlightAppCacheEntry(row));
      }
    });
    return result;
  }

  commitMoonlightAppCacheRefresh(candidate: AccountSessionLease,
    hostId: string, hostRows: MoonlightAppCacheEntry[],
    evictedIds: string[]): boolean {
    if (this.writeFailure || !this.isLeaseCurrent(candidate)) { return false; }
    const remove: string[] = [];
    this.rows.forEach((row: MoonlightAppCacheEntry, id: string): void => {
      if (row.userId === candidate.ownerScopeId && row.hostId === hostId) {
        remove.push(id);
      }
    });
    for (let i = 0; i < remove.length; i++) { this.rows.delete(remove[i]); }
    for (let i = 0; i < hostRows.length; i++) {
      this.rows.set(hostRows[i].id, cloneMoonlightAppCacheEntry(hostRows[i]));
    }
    for (let i = 0; i < evictedIds.length; i++) {
      const current: MoonlightAppCacheEntry | undefined =
        this.rows.get(evictedIds[i]);
      if (current !== undefined && current.userId === candidate.ownerScopeId) {
        this.rows.delete(evictedIds[i]);
      }
    }
    this.commitCount++;
    return true;
  }
}

export default function moonlightAppCacheServiceTest(): void {
  describe('MoonlightAppCacheService', (): void => {
    it('derives_identity_from_owner_host_and_app', 0, (): void => {
      const first: string = moonlightAppCacheIdentity('owner-a', 'host-1', 'app-1');
      expect(first.length).assertEqual(64);
      expect(first === moonlightAppCacheIdentity(
        'owner-b', 'host-1', 'app-1')).assertFalse();
      expect(first === moonlightAppCacheIdentity(
        'owner-a', 'host-2', 'app-1')).assertFalse();
      expect(first === moonlightAppCacheIdentity(
        'owner-a', 'host-1', 'app-2')).assertFalse();
    });

    it('validates_bounds_hashes_expiry_and_composite_identity', 0, (): void => {
      const valid: MoonlightAppCacheEntry =
        entry('owner-a', 'host-1', 'app-1', 'Desktop');
      expect(moonlightAppCacheEntryIsValid(valid)).assertTrue();
      valid.iconHashSha256 = 'bad';
      expect(moonlightAppCacheEntryIsValid(valid)).assertFalse();
      valid.iconHashSha256 = '';
      valid.expiresAt = 99;
      expect(moonlightAppCacheEntryIsValid(valid)).assertFalse();
    });

    it('preserves_missing_rows_during_a_partial_refresh', 0, (): void => {
      const first = entry('owner-a', 'host-1', 'app-1', 'Old A');
      const second = entry('owner-a', 'host-1', 'app-2', 'B');
      const refreshed = entry('owner-a', 'host-1', 'app-1', 'New A');
      const rows = moonlightApplyCatalogRefresh(
        [first, second], [refreshed], false, 200);
      expect(rows.length).assertEqual(2);
      expect(rows[0].title).assertEqual('New A');
      expect(rows[1].available).assertTrue();
    });

    it('marks_missing_rows_unavailable_on_a_complete_empty_catalog', 0, (): void => {
      const rows = moonlightApplyCatalogRefresh([
        entry('owner-a', 'host-1', 'app-1', 'A')
      ], [], true, 200);
      expect(rows.length).assertEqual(1);
      expect(rows[0].available).assertFalse();
      expect(rows[0].lastCatalogAt).assertEqual(200);
    });

    it('evicts_expired_entries_before_live_LRU_entries', 0, (): void => {
      const expired = entry('owner-a', 'host-1', 'old', 'Old', 90, 99);
      expired.artworkLocalPath = '/sandbox/moonlight/old.png';
      const live = entry('owner-a', 'host-1', 'live', 'Live', 10, 1000);
      const plan = moonlightAppCacheEvictionPlan([live, expired], 100);
      expect(plan.evictedIds.length).assertEqual(1);
      expect(plan.evictedIds[0]).assertEqual(expired.id);
      expect(plan.evictedArtworkPaths[0])
        .assertEqual('/sandbox/moonlight/old.png');
      expect(plan.retained[0].id).assertEqual(live.id);
    });

    it('enforces_count_and_byte_budgets_with_stable_LRU_order', 0, (): void => {
      const oldest = entry('owner-a', 'host-1', 'a', 'A', 1, 1000, 10);
      const middle = entry('owner-a', 'host-1', 'b', 'B', 2, 1000, 10);
      const newest = entry('owner-a', 'host-1', 'c', 'C', 3, 1000, 10);
      const plan = moonlightAppCacheEvictionPlan(
        [newest, oldest, middle], 100, 2, 20);
      expect(plan.evictedIds.length).assertEqual(1);
      expect(plan.evictedIds[0]).assertEqual(oldest.id);
      expect(plan.retained.length).assertEqual(2);
    });

    it('commits_refresh_and_never_touches_profiles', 0, (): void => {
      const port = new MemoryMoonlightAppCachePort();
      const service = new MoonlightAppCacheService(port);
      const refreshed = service.refreshCatalog(lease('owner-a'), 'host-1', [
        entry('owner-a', 'host-1', 'app-1', 'Desktop', 100, 1000)
      ], true, 200);
      expect(refreshed.ok).assertTrue();
      expect(refreshed.visibleEntries.length).assertEqual(1);
      expect(port.commitCount).assertEqual(1);
      expect(port.rows.size).assertEqual(1);
    });

    it('fails_closed_on_owner_switch_and_disk_write_failure', 0, (): void => {
      const port = new MemoryMoonlightAppCachePort();
      const service = new MoonlightAppCacheService(port);
      port.activeLease = lease('owner-b', 2);
      const stale = service.refreshCatalog(lease('owner-a'), 'host-1', [], true, 200);
      expect(stale.code).assertEqual('stale_lease');
      port.activeLease = lease('owner-a');
      port.writeFailure = true;
      const failed = service.refreshCatalog(lease('owner-a'), 'host-1', [
        entry('owner-a', 'host-1', 'app-1', 'Desktop')
      ], true, 200);
      expect(failed.code).assertEqual('write_failed');
      expect(port.rows.size).assertEqual(0);
    });

    it('loads_expired_and_unavailable_rows_for_offline_ui_without_writing', 0, (): void => {
      const port = new MemoryMoonlightAppCachePort();
      const stale: MoonlightAppCacheEntry =
        entry('owner-a', 'host-1', 'stale', 'Old Game', 100, 100);
      const vanished: MoonlightAppCacheEntry =
        entry('owner-a', 'host-1', 'gone', 'Vanished Game', 100, 1000);
      vanished.available = false;
      port.rows.set(stale.id, stale);
      port.rows.set(vanished.id, vanished);
      const snapshot = new MoonlightAppCacheService(port)
        .loadSnapshot(lease('owner-a'), 'host-1');
      expect(snapshot.ok).assertTrue();
      expect(snapshot.visibleEntries.length).assertEqual(2);
      expect(port.commitCount).assertEqual(0);
    });
  });
}
