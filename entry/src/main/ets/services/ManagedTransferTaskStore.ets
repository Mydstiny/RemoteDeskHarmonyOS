import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { ManagedTransferRecord, copyManagedTransferRecord, managedTransferIdentifier,
  managedTransferSettled, normalizeManagedTransferRecord, recoverManagedTransferRecord } from './ManagedTransferTaskPolicy';

const MANAGED_TRANSFER_RECORD_LIMIT: number = 512;
/** Settled records older than this are dropped when an account's records load. */
const MANAGED_TRANSFER_SETTLED_RETENTION_MS: number = 14 * 24 * 60 * 60 * 1000;

/** Account-keyed minimal manifests. Persistence never resumes work or deletes files. */
export class ManagedTransferTaskStore {
  private context: common.Context | null = null;
  private loaded: Set<string> = new Set<string>();
  private records: Map<string, ManagedTransferRecord[]> = new Map<string, ManagedTransferRecord[]>();
  private pending: Set<string> = new Set<string>();
  private version: number = 0;
  private tail: Promise<boolean> = Promise.resolve(true);
  private timer: number = -1;
  /** Records a live runner still owns are never evicted; the service supplies the check. */
  private isActive: (record: ManagedTransferRecord) => boolean = (): boolean => false;

  setActivePredicate(isActive: (record: ManagedTransferRecord) => boolean): void { this.isActive = isActive; }

  init(context: common.Context): boolean {
    try {
      preferences.getPreferencesSync(context, { name: 'ManagedTransferTasksV1' });
      this.context = context; return true;
    } catch (error) { return false; }
  }

  ready(accountScopeId: string): boolean {
    this.load(accountScopeId);
    return this.loaded.has(accountScopeId);
  }

  list(accountScopeId: string): ManagedTransferRecord[] {
    this.load(accountScopeId);
    const values: ManagedTransferRecord[] = this.records.get(accountScopeId) ?? [];
    return values.map((record: ManagedTransferRecord): ManagedTransferRecord => copyManagedTransferRecord(record));
  }

  /** `persist` false keeps the change in memory until the next persisted change or flush (progress ticks). */
  upsert(record: ManagedTransferRecord, persist: boolean = true): boolean {
    const value: ManagedTransferRecord | null = normalizeManagedTransferRecord(record, record.accountScopeId);
    if (value === null || !managedTransferIdentifier(record.accountScopeId)) { return false; }
    this.load(record.accountScopeId);
    if (!this.loaded.has(record.accountScopeId)) { return false; }
    const values: ManagedTransferRecord[] = (this.records.get(record.accountScopeId) ?? []).slice();
    const index: number = values.findIndex((item: ManagedTransferRecord): boolean =>
      item.taskId === value.taskId && item.attemptId === value.attemptId);
    if (index >= 0) { values[index] = value; } else { values.push(value); }
    while (values.length > MANAGED_TRANSFER_RECORD_LIMIT) {
      // Evict the oldest settled record nobody runs any more; with none, the new record is refused.
      let removable: number = -1;
      for (let i: number = 0; i < values.length; i++) {
        const item: ManagedTransferRecord = values[i];
        if (!managedTransferSettled(item.stage) || this.isActive(item) ||
          (item.taskId === value.taskId && item.attemptId === value.attemptId)) { continue; }
        if (removable < 0 || item.updatedAt < values[removable].updatedAt) { removable = i; }
      }
      if (removable < 0) { return false; }
      values.splice(removable, 1);
    }
    this.records.set(record.accountScopeId, values);
    this.pending.add(record.accountScopeId);
    this.version++;
    if (persist) { this.scheduleFlush(); }
    return true;
  }

  /** Removes the settled records `matches` selects (never one a runner still owns); returns how many. */
  removeSettled(accountScopeId: string, matches: (record: ManagedTransferRecord) => boolean): number {
    this.load(accountScopeId);
    if (!this.loaded.has(accountScopeId)) { return 0; }
    const values: ManagedTransferRecord[] = this.records.get(accountScopeId) ?? [];
    const kept: ManagedTransferRecord[] = values.filter((item: ManagedTransferRecord): boolean => {
      try { return !managedTransferSettled(item.stage) || this.isActive(item) || !matches(item); }
      catch (_error) { return true; }
    });
    if (kept.length === values.length) { return 0; }
    this.records.set(accountScopeId, kept);
    this.pending.add(accountScopeId); this.version++; this.scheduleFlush();
    return values.length - kept.length;
  }

  private load(accountScopeId: string): void {
    if (!managedTransferIdentifier(accountScopeId) || this.loaded.has(accountScopeId) || this.context === null) { return; }
    const values: ManagedTransferRecord[] = [];
    let changed: boolean = false;
    try {
      const prefs: preferences.Preferences = preferences.getPreferencesSync(this.context, { name: 'ManagedTransferTasksV1' });
      const raw: Object = prefs.getSync('account:' + accountScopeId, '');
      if (typeof raw !== 'string' || raw.length > 2097152) { return; }
      if (raw.length > 0) {
        const parsed: ManagedTransferRecord[] = JSON.parse(raw) as ManagedTransferRecord[];
        if (!Array.isArray(parsed) || parsed.length > 1024) { return; }
        const now: number = Date.now();
        for (let i: number = 0; i < parsed.length; i++) {
          // One unreadable or duplicate record is dropped; it must not lock the whole account out of transfers.
          const value: ManagedTransferRecord | null = normalizeManagedTransferRecord(parsed[i], accountScopeId);
          if (value === null || values.some((existing: ManagedTransferRecord): boolean =>
            existing.taskId === value.taskId && existing.attemptId === value.attemptId)) { changed = true; continue; }
          const recovered: ManagedTransferRecord = recoverManagedTransferRecord(value);
          if (managedTransferSettled(recovered.stage) && now - recovered.updatedAt > MANAGED_TRANSFER_SETTLED_RETENTION_MS) {
            changed = true; continue;
          }
          values.push(recovered);
        }
      }
    } catch (error) {
      // Do not overwrite an unreadable manifest: leave the scope unloaded.
      return;
    }
    this.records.set(accountScopeId, values);
    this.loaded.add(accountScopeId);
    if (changed) { this.pending.add(accountScopeId); this.version++; this.scheduleFlush(); }
  }

  private scheduleFlush(): void {
    if (this.timer >= 0) { return; }
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.flush().catch(() => { /* Failed persistence remains pending for explicit retry. */ });
    }, 250);
  }

  flush(): Promise<boolean> {
    this.tail = this.tail.then(async (): Promise<boolean> => {
      if (this.context === null) { return false; }
      const scopes: string[] = Array.from(this.pending);
      const version: number = this.version;
      try {
        const prefs: preferences.Preferences = preferences.getPreferencesSync(this.context, { name: 'ManagedTransferTasksV1' });
        for (let i: number = 0; i < scopes.length; i++) {
          prefs.putSync('account:' + scopes[i], JSON.stringify(this.records.get(scopes[i]) ?? []));
        }
        await prefs.flush();
        if (this.version === version) { scopes.forEach((scope: string): void => { this.pending.delete(scope); }); }
        return true;
      } catch (error) { return false; }
    });
    return this.tail;
  }
}
