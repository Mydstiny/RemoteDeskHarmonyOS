import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  SshSftpTaskRecord,
  normalizeSshSftpTaskRecord,
  upsertSshSftpTask
} from './SshSftpTaskPolicy';

const PREFS_NAME: string = 'RemoteDesktopSshSftpPrefs';
const TASKS_KEY: string = 'ssh.sftp.tasks.v1';
const FLUSH_DELAY_MS: number = 300;

/**
 * SSH-only durable metadata owner. It never persists credentials, Picker
 * grants, local URI values or payload bytes. Metadata writes are coalesced so
 * transfer checkpoints cannot block terminal input on every chunk.
 */
export class SshSftpTaskStore {
  private static instance: SshSftpTaskStore | null = null;
  private context: common.Context | null = null;
  private records: SshSftpTaskRecord[] = [];
  private flushTimer: number = -1;
  private dirty: boolean = false;
  private mutationVersion: number = 0;
  private flushInFlight: Promise<boolean> | null = null;

  static getInstance(): SshSftpTaskStore {
    if (SshSftpTaskStore.instance === null) {
      SshSftpTaskStore.instance = new SshSftpTaskStore();
    }
    return SshSftpTaskStore.instance;
  }

  init(context: common.Context): void {
    if (this.flushTimer !== -1) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
    this.context = context;
    this.records = [];
    this.dirty = false;
    this.mutationVersion++;
    try {
      const prefs = preferences.getPreferencesSync(context, { name: PREFS_NAME });
      const stored: Object = prefs.getSync(TASKS_KEY, '');
      if (typeof stored === 'string' && (stored as string).length > 0) {
        const parsed: Object = JSON.parse(stored as string) as Object;
        if (Array.isArray(parsed)) {
          for (let index = 0; index < parsed.length; index++) {
            const normalized: SshSftpTaskRecord | null =
              normalizeSshSftpTaskRecord(parsed[index] as Object);
            if (normalized !== null) { this.records = upsertSshSftpTask(this.records, normalized); }
          }
        }
      }
    } catch (_err) {
      this.records = [];
    }
    this.dirty = false;
  }

  list(hostId: string = ''): SshSftpTaskRecord[] {
    const filter: string = hostId.trim();
    return this.records.filter((record: SshSftpTaskRecord): boolean =>
      filter.length === 0 || record.hostId === filter);
  }

  upsert(record: SshSftpTaskRecord): void {
    const normalized: SshSftpTaskRecord | null = normalizeSshSftpTaskRecord(record as Object);
    if (normalized === null) { return; }
    this.records = upsertSshSftpTask(this.records, normalized);
    this.mutationVersion++;
    this.dirty = true;
    this.scheduleFlush();
  }

  remove(taskId: string): void {
    const id: string = taskId.trim();
    if (id.length === 0) { return; }
    const next: SshSftpTaskRecord[] = this.records.filter(
      (record: SshSftpTaskRecord): boolean => record.taskId !== id);
    if (next.length === this.records.length) { return; }
    this.records = next;
    this.mutationVersion++;
    this.dirty = true;
    this.scheduleFlush();
  }

  async flushNow(): Promise<boolean> {
    if (this.flushTimer !== -1) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
    // A mutation can arrive while the provider flush is awaiting. Keep
    // draining until the snapshot that includes the newest mutation lands.
    if (this.context === null && this.dirty) { return false; }
    while (this.dirty) {
      if (!await this.flush()) { return false; }
    }
    return true;
  }

  private scheduleFlush(): void {
    if (this.flushTimer !== -1) { return; }
    this.flushTimer = setTimeout((): void => {
      this.flushTimer = -1;
      this.flush().catch((_err: Error): void => { /* next mutation retries persistence */ });
    }, FLUSH_DELAY_MS);
  }

  private async flush(): Promise<boolean> {
    if (this.flushInFlight !== null) { return await this.flushInFlight; }
    const context: common.Context | null = this.context;
    if (!this.dirty || context === null) { return true; }
    const version: number = this.mutationVersion;
    const snapshot: string = JSON.stringify(this.records);
    const operation: Promise<boolean> = (async (): Promise<boolean> => {
      try {
        const prefs = preferences.getPreferencesSync(context, { name: PREFS_NAME });
        prefs.putSync(TASKS_KEY, snapshot);
        await prefs.flush();
        if (version === this.mutationVersion) {
          this.dirty = false;
        } else {
          // A checkpoint arrived while the provider flush was in flight. Keep
          // it dirty and schedule a second write instead of losing that state.
          this.dirty = true;
        }
        return true;
      } catch (_err) {
        return false;
      } finally {
        this.flushInFlight = null;
        if (this.dirty && version !== this.mutationVersion) { this.scheduleFlush(); }
      }
    })();
    this.flushInFlight = operation;
    return await operation;
  }
}
