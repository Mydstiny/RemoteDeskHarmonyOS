import {
  MOONLIGHT_APP_CACHE_MAX_BYTES,
  MOONLIGHT_APP_CACHE_MAX_ENTRIES,
  MoonlightAppCacheEntry,
  cloneMoonlightAppCacheEntry,
  moonlightAppCacheEntryIsValid
} from '../model/MoonlightAppCache';
import {
  AccountSessionLease,
  accountSessionLeaseEquals,
  cloneAccountSessionLease
} from './AccountScopePolicy';

export type MoonlightAppCacheCode =
  'ok' | 'stale_lease' | 'invalid_owner' | 'invalid_entry' |
  'duplicate_app' | 'read_failed' | 'write_failed';

export interface MoonlightAppCacheResult {
  ok: boolean;
  code: MoonlightAppCacheCode;
  visibleEntries: MoonlightAppCacheEntry[];
  evictedIds: string[];
  evictedArtworkPaths: string[];
}

export interface MoonlightAppCachePort {
  currentAccountLease(): AccountSessionLease | null;
  isLeaseCurrent(lease: AccountSessionLease): boolean;
  loadMoonlightAppCacheEntries(
    lease: AccountSessionLease, hostId?: string
  ): MoonlightAppCacheEntry[] | null;
  commitMoonlightAppCacheRefresh(
    lease: AccountSessionLease,
    hostId: string,
    hostRows: MoonlightAppCacheEntry[],
    evictedIds: string[]
  ): boolean;
}

export interface MoonlightAppCacheEvictionPlan {
  retained: MoonlightAppCacheEntry[];
  evictedIds: string[];
  evictedArtworkPaths: string[];
}

function result(ok: boolean, code: MoonlightAppCacheCode,
  visibleEntries: MoonlightAppCacheEntry[] = [],
  evictedIds: string[] = [],
  evictedArtworkPaths: string[] = []): MoonlightAppCacheResult {
  return {
    ok: ok,
    code: code,
    visibleEntries: visibleEntries,
    evictedIds: evictedIds,
    evictedArtworkPaths: evictedArtworkPaths
  };
}

function entryOrder(left: MoonlightAppCacheEntry,
  right: MoonlightAppCacheEntry): number {
  if (left.sortOrder !== right.sortOrder) {
    return left.sortOrder - right.sortOrder;
  }
  if (left.title !== right.title) { return left.title < right.title ? -1 : 1; }
  return left.id < right.id ? -1 : (left.id === right.id ? 0 : 1);
}

function evictionOrder(left: MoonlightAppCacheEntry,
  right: MoonlightAppCacheEntry, nowMs: number): number {
  const leftExpired: boolean = left.expiresAt <= nowMs;
  const rightExpired: boolean = right.expiresAt <= nowMs;
  if (leftExpired !== rightExpired) { return leftExpired ? -1 : 1; }
  if (left.lastAccessedAt !== right.lastAccessedAt) {
    return left.lastAccessedAt - right.lastAccessedAt;
  }
  if (left.lastCatalogAt !== right.lastCatalogAt) {
    return left.lastCatalogAt - right.lastCatalogAt;
  }
  return left.id < right.id ? -1 : (left.id === right.id ? 0 : 1);
}

function contains(values: string[], value: string): boolean {
  return values.indexOf(value) >= 0;
}

export function moonlightAppCacheEvictionPlan(
  entries: MoonlightAppCacheEntry[], nowMs: number,
  maxEntries: number = MOONLIGHT_APP_CACHE_MAX_ENTRIES,
  maxBytes: number = MOONLIGHT_APP_CACHE_MAX_BYTES
): MoonlightAppCacheEvictionPlan {
  const ordered: MoonlightAppCacheEntry[] = [];
  let totalBytes: number = 0;
  for (let i = 0; i < entries.length; i++) {
    const cloned: MoonlightAppCacheEntry = cloneMoonlightAppCacheEntry(entries[i]);
    ordered.push(cloned);
    totalBytes += cloned.sizeBytes;
  }
  ordered.sort((left: MoonlightAppCacheEntry,
    right: MoonlightAppCacheEntry): number =>
    evictionOrder(left, right, nowMs));
  let remainingCount: number = ordered.length;
  const evictedIds: string[] = [];
  const evictedArtworkPaths: string[] = [];
  let index: number = 0;
  while (index < ordered.length &&
    (remainingCount > Math.max(0, maxEntries) ||
     totalBytes > Math.max(0, maxBytes) ||
     ordered[index].expiresAt <= nowMs)) {
    const evicted: MoonlightAppCacheEntry = ordered[index];
    evictedIds.push(evicted.id);
    if (evicted.artworkLocalPath !== '') {
      evictedArtworkPaths.push(evicted.artworkLocalPath);
    }
    totalBytes -= evicted.sizeBytes;
    remainingCount--;
    index++;
  }
  const retained: MoonlightAppCacheEntry[] = [];
  for (let i = 0; i < entries.length; i++) {
    if (!contains(evictedIds, entries[i].id)) {
      retained.push(cloneMoonlightAppCacheEntry(entries[i]));
    }
  }
  return {
    retained: retained,
    evictedIds: evictedIds,
    evictedArtworkPaths: evictedArtworkPaths
  };
}

/**
 * A complete refresh marks missing apps unavailable; a partial refresh leaves
 * missing rows untouched. Neither mode deletes a user profile.
 */
export function moonlightApplyCatalogRefresh(
  currentHostRows: MoonlightAppCacheEntry[],
  incomingRows: MoonlightAppCacheEntry[],
  complete: boolean,
  nowMs: number
): MoonlightAppCacheEntry[] {
  const byId: Map<string, MoonlightAppCacheEntry> =
    new Map<string, MoonlightAppCacheEntry>();
  for (let i = 0; i < currentHostRows.length; i++) {
    byId.set(currentHostRows[i].id,
      cloneMoonlightAppCacheEntry(currentHostRows[i]));
  }
  const incomingIds: string[] = [];
  for (let i = 0; i < incomingRows.length; i++) {
    const candidate: MoonlightAppCacheEntry =
      cloneMoonlightAppCacheEntry(incomingRows[i]);
    candidate.lastAccessedAt = Math.max(candidate.lastAccessedAt, nowMs);
    byId.set(candidate.id, candidate);
    incomingIds.push(candidate.id);
  }
  if (complete) {
    byId.forEach((entry: MoonlightAppCacheEntry, id: string): void => {
      if (!contains(incomingIds, id)) {
        entry.available = false;
        entry.lastCatalogAt = Math.max(entry.lastCatalogAt, nowMs);
        entry.lastAccessedAt = Math.max(entry.lastAccessedAt, nowMs);
      }
    });
  }
  const result: MoonlightAppCacheEntry[] = [];
  byId.forEach((entry: MoonlightAppCacheEntry): void => { result.push(entry); });
  result.sort(entryOrder);
  return result;
}

export class MoonlightAppCacheService {
  private readonly port: MoonlightAppCachePort;

  constructor(port: MoonlightAppCachePort) {
    this.port = port;
  }

  refreshCatalog(lease: AccountSessionLease, hostId: string,
    incomingRows: MoonlightAppCacheEntry[], complete: boolean,
    nowMs: number): MoonlightAppCacheResult {
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    if (!this.leaseIsCurrent(captured)) {
      return result(false, 'stale_lease');
    }
    const owner: string = captured.ownerScopeId.trim();
    const host: string = hostId.trim();
    if (owner === '' || host === '') { return result(false, 'invalid_owner'); }
    const incomingIds: string[] = [];
    for (let i = 0; i < incomingRows.length; i++) {
      const entry: MoonlightAppCacheEntry = incomingRows[i];
      if (entry.userId !== owner || entry.hostId !== host) {
        return result(false, 'invalid_owner');
      }
      if (!moonlightAppCacheEntryIsValid(entry)) {
        return result(false, 'invalid_entry');
      }
      if (contains(incomingIds, entry.id)) {
        return result(false, 'duplicate_app');
      }
      incomingIds.push(entry.id);
    }
    const allRows: MoonlightAppCacheEntry[] | null =
      this.port.loadMoonlightAppCacheEntries(captured);
    if (allRows === null || !this.leaseIsCurrent(captured)) {
      return result(false, allRows === null ? 'read_failed' : 'stale_lease');
    }
    const currentHostRows: MoonlightAppCacheEntry[] = [];
    const otherRows: MoonlightAppCacheEntry[] = [];
    for (let i = 0; i < allRows.length; i++) {
      if (!moonlightAppCacheEntryIsValid(allRows[i]) ||
          allRows[i].userId !== owner) {
        return result(false, 'read_failed');
      }
      if (allRows[i].hostId === host) {
        currentHostRows.push(allRows[i]);
      } else {
        otherRows.push(allRows[i]);
      }
    }
    const refreshed: MoonlightAppCacheEntry[] = moonlightApplyCatalogRefresh(
      currentHostRows, incomingRows, complete, nowMs);
    const candidateRows: MoonlightAppCacheEntry[] = otherRows.concat(refreshed);
    const eviction: MoonlightAppCacheEvictionPlan =
      moonlightAppCacheEvictionPlan(candidateRows, nowMs);
    const committedHostRows: MoonlightAppCacheEntry[] = [];
    for (let i = 0; i < refreshed.length; i++) {
      if (!contains(eviction.evictedIds, refreshed[i].id)) {
        committedHostRows.push(refreshed[i]);
      }
    }
    if (!this.port.commitMoonlightAppCacheRefresh(
      captured, host, committedHostRows, eviction.evictedIds) ||
      !this.leaseIsCurrent(captured)) {
      return result(false, this.leaseIsCurrent(captured) ?
        'write_failed' : 'stale_lease');
    }
    const visible: MoonlightAppCacheEntry[] = [];
    for (let i = 0; i < committedHostRows.length; i++) {
      if (committedHostRows[i].available &&
          committedHostRows[i].expiresAt > nowMs) {
        visible.push(cloneMoonlightAppCacheEntry(committedHostRows[i]));
      }
    }
    visible.sort(entryOrder);
    return result(true, 'ok', visible,
      eviction.evictedIds, eviction.evictedArtworkPaths);
  }

  loadVisible(lease: AccountSessionLease, hostId: string,
    nowMs: number): MoonlightAppCacheResult {
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    if (!this.leaseIsCurrent(captured)) {
      return result(false, 'stale_lease');
    }
    const rows: MoonlightAppCacheEntry[] | null =
      this.port.loadMoonlightAppCacheEntries(captured, hostId);
    if (rows === null || !this.leaseIsCurrent(captured)) {
      return result(false, rows === null ? 'read_failed' : 'stale_lease');
    }
    const visible: MoonlightAppCacheEntry[] = [];
    for (let i = 0; i < rows.length; i++) {
      if (!moonlightAppCacheEntryIsValid(rows[i]) ||
          rows[i].userId !== captured.ownerScopeId ||
          rows[i].hostId !== hostId) {
        return result(false, 'read_failed');
      }
      if (rows[i].available && rows[i].expiresAt > nowMs) {
        visible.push(cloneMoonlightAppCacheEntry(rows[i]));
      }
    }
    visible.sort(entryOrder);
    return result(true, 'ok', visible);
  }

  /**
   * Read-only UI snapshot. Unlike loadVisible(), this deliberately retains
   * expired and unavailable rows so an offline refresh never erases the last
   * usable catalog or its associated profile presentation.
   */
  loadSnapshot(lease: AccountSessionLease,
    hostId: string): MoonlightAppCacheResult {
    const captured: AccountSessionLease = cloneAccountSessionLease(lease);
    if (!this.leaseIsCurrent(captured)) {
      return result(false, 'stale_lease');
    }
    const host: string = hostId.trim();
    if (captured.ownerScopeId.trim() === '' || host === '') {
      return result(false, 'invalid_owner');
    }
    const rows: MoonlightAppCacheEntry[] | null =
      this.port.loadMoonlightAppCacheEntries(captured, host);
    if (rows === null || !this.leaseIsCurrent(captured)) {
      return result(false, rows === null ? 'read_failed' : 'stale_lease');
    }
    const snapshot: MoonlightAppCacheEntry[] = [];
    for (let i = 0; i < rows.length; i++) {
      if (!moonlightAppCacheEntryIsValid(rows[i]) ||
          rows[i].userId !== captured.ownerScopeId ||
          rows[i].hostId !== host) {
        return result(false, 'read_failed');
      }
      snapshot.push(cloneMoonlightAppCacheEntry(rows[i]));
    }
    snapshot.sort(entryOrder);
    return result(true, 'ok', snapshot);
  }

  private leaseIsCurrent(lease: AccountSessionLease): boolean {
    return accountSessionLeaseEquals(
      this.port.currentAccountLease(), lease) &&
      this.port.isLeaseCurrent(lease);
  }
}
