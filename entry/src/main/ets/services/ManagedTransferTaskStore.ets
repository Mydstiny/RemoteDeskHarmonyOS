import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { ManagedTransferRecord, copyManagedTransferRecord, managedTransferIdentifier,
  managedTransferTerminal, normalizeManagedTransferRecord, recoverManagedTransferRecord } from './ManagedTransferTaskPolicy';

/** Account-keyed minimal manifests. Persistence never resumes work or deletes files. */
export class ManagedTransferTaskStore {
  private context: common.Context | null = null;
  private loaded: Set<string> = new Set<string>();
  private records: Map<string, ManagedTransferRecord[]> = new Map<string, ManagedTransferRecord[]>();
  private pending: Set<string> = new Set<string>();
  private version: number = 0;
  private tail: Promise<boolean> = Promise.resolve(true);
  private timer: number = -1;

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

  upsert(record: ManagedTransferRecord): boolean {
    const value: ManagedTransferRecord | null = normalizeManagedTransferRecord(record, record.accountScopeId);
    if (value === null || !managedTransferIdentifier(record.accountScopeId)) { return false; }
    this.load(record.accountScopeId);
    if (!this.loaded.has(record.accountScopeId)) { return false; }
    const values: ManagedTransferRecord[] = (this.records.get(record.accountScopeId) ?? []).slice();
    const index: number = values.findIndex((item: ManagedTransferRecord): boolean =>
      item.taskId === value.taskId && item.attemptId === value.attemptId);
    if (index >= 0) { values[index] = value; } else { values.push(value); }
    while (values.length > 512) {
      const removable: number = values.findIndex((item: ManagedTransferRecord): boolean =>
        managedTransferTerminal(item.stage) && !(item.taskId === value.taskId && item.attemptId === value.attemptId));
      if (removable < 0) { return false; }
      values.splice(removable, 1);
    }
    this.records.set(record.accountScopeId, values);
    this.pending.add(record.accountScopeId);
    this.version++;
    this.scheduleFlush();
    return true;
  }

  private load(accountScopeId: string): void {
    if (!managedTransferIdentifier(accountScopeId) || this.loaded.has(accountScopeId) || this.context === null) { return; }
    const values: ManagedTransferRecord[] = [];
    try {
      const prefs: preferences.Preferences = preferences.getPreferencesSync(this.context, { name: 'ManagedTransferTasksV1' });
      const raw: Object = prefs.getSync('account:' + accountScopeId, '');
      if (typeof raw !== 'string' || raw.length > 2097152) { return; }
      if (raw.length > 0) {
        const parsed: ManagedTransferRecord[] = JSON.parse(raw) as ManagedTransferRecord[];
        if (!Array.isArray(parsed) || parsed.length > 1024) { return; }
        if (Array.isArray(parsed)) {
          for (let i: number = 0; i < parsed.length; i++) {
            const value: ManagedTransferRecord | null = normalizeManagedTransferRecord(parsed[i], accountScopeId);
            if (value === null || values.some((existing: ManagedTransferRecord): boolean =>
              existing.taskId === value.taskId && existing.attemptId === value.attemptId)) { return; }
            values.push(recoverManagedTransferRecord(value));
          }
        }
      }
    } catch (error) {
      // Do not overwrite an unreadable manifest: leave the scope unloaded.
      return;
    }
    this.records.set(accountScopeId, values);
    this.loaded.add(accountScopeId);
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
