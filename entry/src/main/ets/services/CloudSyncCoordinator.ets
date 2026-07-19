import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CloudSyncSelectionStore } from './CloudSyncSelectionStore';
import { CloudSyncDirection } from './CloudSyncPolicy';
import { ActiveRemoteSessionRegistry } from './ActiveRemoteSessionRegistry';
import {
  CLOUD_SYNC_MAX_RETRY_ATTEMPTS,
  CloudSyncRequest,
  CloudSyncRetryRecord,
  CloudSyncSource,
  automaticRetryKey,
  coalesceAutomaticPush,
  isAutomaticRetryRecord,
  nextCloudSyncRetryDelayMs,
  retryTablesStillSelected,
  shouldReplayAutomaticPush,
  snapshotCloudSyncTables,
  upsertAutomaticRetryRecord
} from './CloudSyncCoordinatorPolicy';

const DOMAIN = 0x0001;
const TAG = 'CloudSyncCoordinator';
const PREFS_NAME = 'RemoteDesktopAppPrefs';
const RETRY_PREFERENCE_KEY = 'cloudSyncRetryRecord';
const DIRTY_PREFERENCE_KEY = 'cloudSyncDirtyTables';

export interface CloudSyncOperationResult {
  ok: boolean;
  source: CloudSyncSource;
  tables: string[];
  failedTables: string[];
  rollbackFailed: boolean;
}

export type CloudSyncTableExecutor = (table: string, direction: CloudSyncDirection, label: string) => Promise<boolean>;

export interface CloudSyncCoordinatorHooks {
  beginManualDownload: () => boolean;
  rollbackManualDownload: () => Promise<boolean>;
  completeManualDownload: () => void;
  setRestorePending: (pending: boolean) => void;
}

/**
 * Runs one frozen request and turns every executor/hook failure into data the
 * queue can observe.  Exported for deterministic policy tests; the singleton
 * coordinator is its only production caller.
 */
export async function executeCloudSyncRequest(
  request: CloudSyncRequest,
  executor: CloudSyncTableExecutor | null,
  hooks: CloudSyncCoordinatorHooks | null,
  onCloudFirstApplied: (tables: string[]) => void
): Promise<CloudSyncOperationResult> {
  const failedTables: string[] = [];
  if (!executor || request.tables.length === 0) {
    return {
      ok: request.tables.length === 0, source: request.source, tables: request.tables.slice(),
      failedTables: request.tables.slice(), rollbackFailed: false
    };
  }
  if (request.source === 'manualDownload') {
    try {
      if (!hooks || !hooks.beginManualDownload()) {
        return {
          ok: false, source: request.source, tables: request.tables.slice(),
          failedTables: request.tables.slice(), rollbackFailed: false
        };
      }
    } catch (_e) {
      return {
        ok: false, source: request.source, tables: request.tables.slice(),
        failedTables: request.tables.slice(), rollbackFailed: false
      };
    }
  }
  for (let i = 0; i < request.tables.length; i++) {
    const table: string = request.tables[i];
    let ok: boolean = false;
    try {
      ok = await executor(table, request.direction, request.source);
    } catch (_e) {
      failedTables.push(table);
      if (table === 'cryptoparams') {
        for (let j = i + 1; j < request.tables.length; j++) { failedTables.push(request.tables[j]); }
      }
      break;
    }
    if (!ok) {
      failedTables.push(table);
      if (table === 'cryptoparams') {
        for (let j = i + 1; j < request.tables.length; j++) { failedTables.push(request.tables[j]); }
        break;
      }
    }
  }
  let rollbackFailed: boolean = false;
  if (request.source === 'manualDownload' && hooks) {
    try {
      if (failedTables.length === 0) { hooks.completeManualDownload(); }
      else { rollbackFailed = !(await hooks.rollbackManualDownload()); }
    } catch (_e) {
      rollbackFailed = true;
    }
  }
  const result: CloudSyncOperationResult = {
    ok: failedTables.length === 0 && !rollbackFailed,
    source: request.source,
    tables: request.tables.slice(),
    failedTables,
    rollbackFailed
  };
  if (result.ok && request.direction === 'cloudFirst') {
    try { onCloudFirstApplied(request.tables.slice()); } catch (_e) { /* listener failures do not stall sync */ }
  }
  return result;
}

/**
 * Owns the only synchronization queue in the app.  The RDB layer stays
 * ignorant of selection, foreground, retry, and restore policy so one source
 * cannot race another source with an opposite cloudSync direction.
 */
export class CloudSyncCoordinator {
  private static instance: CloudSyncCoordinator;
  private context: common.Context | null = null;
  private executor: CloudSyncTableExecutor | null = null;
  private readonly selection: CloudSyncSelectionStore = CloudSyncSelectionStore.getInstance();
  private queueTail: Promise<void> = Promise.resolve();
  private pendingAutomaticTables: string[] = [];
  private deferredAutomaticTables: string[] = [];
  private pendingPull: Promise<CloudSyncOperationResult> | null = null;
  private onCloudFirstApplied: ((tables: string[]) => void) | null = null;
  private hooks: CloudSyncCoordinatorHooks | null = null;
  private retryTimer: number = -1;
  private retryRecords: CloudSyncRetryRecord[] = [];
  private restorePending: boolean = false;
  private automaticRetryAttempts: Record<string, number> = {};
  private automaticMutationVersions: Record<string, number> = {};
  private dirtyAutomaticTables: string[] = [];

  static getInstance(): CloudSyncCoordinator {
    if (!CloudSyncCoordinator.instance) {
      CloudSyncCoordinator.instance = new CloudSyncCoordinator();
    }
    return CloudSyncCoordinator.instance;
  }

  init(
    context: common.Context,
    executor: CloudSyncTableExecutor,
    onCloudFirstApplied: (tables: string[]) => void,
    hooks: CloudSyncCoordinatorHooks
  ): void {
    this.context = context;
    this.executor = executor;
    this.onCloudFirstApplied = onCloudFirstApplied;
    this.hooks = hooks;
    this.restoreRetryRecord();
    this.restoreDirtyTables();
  }

  requestStartupPull(): Promise<CloudSyncOperationResult> {
    const selected: string[] = this.selectedTables();
    const dirty: string[] = this.dirtyAutomaticTables.filter((table: string): boolean =>
      selected.indexOf(table) >= 0);
    if (dirty.length === 0) { return this.requestCloudFirst('startup'); }
    const versions: Record<string, number> = {};
    dirty.forEach((table: string): void => {
      versions[table] = this.automaticMutationVersions[table] || 1;
    });
    const request: CloudSyncRequest = {
      source: 'automaticPush', direction: 'nativeFirst', tables: snapshotCloudSyncTables(dirty)
    };
    return this.enqueue(request).then((result: CloudSyncOperationResult): Promise<CloudSyncOperationResult> => {
      if (!result.ok) { return Promise.resolve(result); }
      dirty.forEach((table: string): void => {
        if ((this.automaticMutationVersions[table] || versions[table]) === versions[table]) {
          this.clearDirtyTable(table);
        }
      });
      return this.requestCloudFirst('startup');
    });
  }

  requestForegroundPull(): Promise<CloudSyncOperationResult> {
    return this.requestCloudFirst('foreground');
  }

  requestCloudEventPull(): Promise<CloudSyncOperationResult> {
    return this.requestCloudFirst('cloudEvent');
  }

  requestManualUpload(): Promise<CloudSyncOperationResult> {
    return this.enqueue(this.makeRequest('manualUpload', 'nativeFirst'));
  }

  requestManualDownload(): Promise<CloudSyncOperationResult> {
    return this.enqueue(this.makeRequest('manualDownload', 'cloudFirst'));
  }

  requestAutomaticPush(table: string): Promise<CloudSyncOperationResult> {
    const selected: string[] = this.selectedTables();
    if (selected.indexOf(table) < 0 || this.restorePending) {
      return Promise.resolve(this.skippedResult('automaticPush'));
    }
    const version: number = (this.automaticMutationVersions[table] || 0) + 1;
    this.automaticMutationVersions[table] = version;
    this.markDirtyTable(table);
    const activeSession = ActiveRemoteSessionRegistry.getInstance().getActive();
    if (activeSession !== null && activeSession.protocolConnected) {
      if (this.deferredAutomaticTables.indexOf(table) < 0) {
        this.deferredAutomaticTables.push(table);
      }
      hilog.info(DOMAIN, TAG, 'defer automatic push during remote session table=' + table);
      return Promise.resolve(this.skippedResult('automaticPush'));
    }
    for (let i = 0; i < this.pendingAutomaticTables.length; i++) {
      if (coalesceAutomaticPush(this.pendingAutomaticTables[i], table)) {
        hilog.info(DOMAIN, TAG, 'coalesce latest mutation for table=' + table);
        return Promise.resolve(this.skippedResult('automaticPush'));
      }
    }
    // Sensitive selected tables always carry their cryptographic parameters first.
    // The snapshot is fixed now, so later selection changes cannot split this pair.
    const tables: string[] = selected.filter((candidate: string): boolean =>
      candidate === 'cryptoparams' || candidate === table
    );
    return this.enqueueAutomaticRequest({ source: 'automaticPush', direction: 'nativeFirst', tables }, table, version);
  }

  /** Flushes mutations collected while audio/video had priority. */
  flushDeferredAutomaticPushes(): void {
    const activeSession = ActiveRemoteSessionRegistry.getInstance().getActive();
    if (activeSession !== null && activeSession.protocolConnected) { return; }
    const tables: string[] = this.deferredAutomaticTables.slice();
    this.deferredAutomaticTables = [];
    for (let i = 0; i < tables.length; i++) {
      this.requestAutomaticPush(tables[i]);
    }
  }

  private enqueueAutomaticRequest(request: CloudSyncRequest, retryKey: string,
    completedVersion: number = this.automaticMutationVersions[retryKey] || 1): Promise<CloudSyncOperationResult> {
    for (let i = 0; i < this.pendingAutomaticTables.length; i++) {
      if (coalesceAutomaticPush(this.pendingAutomaticTables[i], retryKey)) {
        return Promise.resolve(this.skippedResult('automaticPush'));
      }
    }
    this.pendingAutomaticTables.push(retryKey);
    return this.enqueue(request).then((result: CloudSyncOperationResult): CloudSyncOperationResult => {
      const index: number = this.pendingAutomaticTables.indexOf(retryKey);
      if (index >= 0) { this.pendingAutomaticTables.splice(index, 1); }
      if (result.ok) {
        this.automaticRetryAttempts[retryKey] = 0;
        this.removeAutomaticRetry(retryKey);
        const latestVersion: number = this.automaticMutationVersions[retryKey] || completedVersion;
        if (shouldReplayAutomaticPush(completedVersion, latestVersion)) {
          const selected: string[] = this.selectedTables();
          const tables: string[] = selected.filter((candidate: string): boolean =>
            candidate === 'cryptoparams' || candidate === retryKey);
          this.enqueueAutomaticRequest({ source: 'automaticPush', direction: 'nativeFirst', tables },
            retryKey, latestVersion);
        } else {
          this.clearDirtyTable(retryKey);
        }
      } else {
        const attempt: number = (this.automaticRetryAttempts[retryKey] || 0) + 1;
        this.automaticRetryAttempts[retryKey] = attempt;
        this.persistAutomaticRetry(request, result.failedTables, attempt);
      }
      return result;
    });
  }

  /** Queue a database restore without allowing a concurrent cloud operation. */
  runExclusiveRestore(work: () => Promise<boolean>): Promise<boolean> {
    if (this.restorePending) { return Promise.resolve(false); }
    this.restorePending = true;
    if (this.hooks) { this.hooks.setRestorePending(true); }
    return new Promise<boolean>((resolve: (value: boolean) => void): void => {
      this.queueTail = this.queueTail.then(async (): Promise<void> => {
        try {
          resolve(await work());
        } catch (_e) {
          resolve(false);
        } finally {
          this.restorePending = false;
          if (this.hooks) { this.hooks.setRestorePending(false); }
        }
      }, async (): Promise<void> => {
        try {
          resolve(await work());
        } catch (_e) {
          resolve(false);
        } finally {
          this.restorePending = false;
          if (this.hooks) { this.hooks.setRestorePending(false); }
        }
      });
    });
  }

  pendingTableCount(): number {
    return this.pendingAutomaticTables.length;
  }

  private requestCloudFirst(source: CloudSyncSource): Promise<CloudSyncOperationResult> {
    if (this.pendingPull) { return this.pendingPull; }
    const request: CloudSyncRequest = this.makeRequest(source, 'cloudFirst');
    this.pendingPull = this.enqueue(request).then((result: CloudSyncOperationResult): CloudSyncOperationResult => {
      this.pendingPull = null;
      return result;
    }, (): CloudSyncOperationResult => {
      this.pendingPull = null;
      return { ok: false, source, tables: request.tables, failedTables: request.tables.slice(), rollbackFailed: false };
    });
    return this.pendingPull;
  }

  private makeRequest(source: CloudSyncSource, direction: CloudSyncDirection): CloudSyncRequest {
    return { source, direction, tables: this.selectedTables() };
  }

  private selectedTables(): string[] {
    return snapshotCloudSyncTables(this.selection.selectedBusinessTables());
  }

  private skippedResult(source: CloudSyncSource): CloudSyncOperationResult {
    return { ok: true, source, tables: [], failedTables: [], rollbackFailed: false };
  }

  private enqueue(request: CloudSyncRequest): Promise<CloudSyncOperationResult> {
    return new Promise<CloudSyncOperationResult>((resolve: (result: CloudSyncOperationResult) => void): void => {
      const run = async (): Promise<void> => {
        resolve(await this.execute(request));
      };
      this.queueTail = this.queueTail.then(run, run);
    });
  }

  private async execute(request: CloudSyncRequest): Promise<CloudSyncOperationResult> {
    return await executeCloudSyncRequest(
      request,
      this.executor,
      this.hooks,
      (tables: string[]): void => {
        if (this.onCloudFirstApplied) { this.onCloudFirstApplied(tables); }
      }
    );
  }

  private restoreRetryRecord(): void {
    if (!this.context || this.retryTimer >= 0) { return; }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: PREFS_NAME });
      const stored: string = prefs.getSync(RETRY_PREFERENCE_KEY, '') as string;
      if (stored.length === 0) { return; }
      const parsed = JSON.parse(stored) as Object;
      const records: CloudSyncRetryRecord[] = Array.isArray(parsed)
        ? parsed as CloudSyncRetryRecord[] : [parsed as CloudSyncRetryRecord];
      for (let i = 0; i < records.length; i++) {
        if (!isAutomaticRetryRecord(records[i])) { continue; }
        this.retryRecords = upsertAutomaticRetryRecord(this.retryRecords, records[i]);
        this.automaticRetryAttempts[automaticRetryKey(records[i])] = records[i].attempt;
      }
      this.writeRetryRecords();
      this.scheduleRetryTimer();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'restore retry ignored: ' + JSON.stringify(err));
    }
  }

  private restoreDirtyTables(): void {
    if (!this.context) { return; }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: PREFS_NAME });
      const raw: string = prefs.getSync(DIRTY_PREFERENCE_KEY, '[]') as string;
      const parsed = JSON.parse(raw) as Object;
      if (!Array.isArray(parsed)) { return; }
      const values = parsed as string[];
      for (let i = 0; i < values.length; i++) {
        if (this.dirtyAutomaticTables.indexOf(values[i]) < 0) {
          this.dirtyAutomaticTables.push(values[i]);
          this.automaticMutationVersions[values[i]] = 1;
        }
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'restore dirty tables ignored: ' + JSON.stringify(err));
    }
  }

  private writeDirtyTables(): void {
    if (!this.context) { return; }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: PREFS_NAME });
      if (this.dirtyAutomaticTables.length === 0) {
        prefs.deleteSync(DIRTY_PREFERENCE_KEY);
      } else {
        prefs.putSync(DIRTY_PREFERENCE_KEY, JSON.stringify(this.dirtyAutomaticTables));
      }
      prefs.flushSync();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'write dirty tables failed: ' + JSON.stringify(err));
    }
  }

  private markDirtyTable(table: string): void {
    if (this.dirtyAutomaticTables.indexOf(table) < 0) {
      this.dirtyAutomaticTables.push(table);
      this.writeDirtyTables();
    }
  }

  private clearDirtyTable(table: string): void {
    const index: number = this.dirtyAutomaticTables.indexOf(table);
    if (index >= 0) {
      this.dirtyAutomaticTables.splice(index, 1);
      this.writeDirtyTables();
    }
  }

  private persistAutomaticRetry(request: CloudSyncRequest, failedTables: string[], attempt: number): void {
    const retryKey: string = automaticRetryKey({
      source: request.source, direction: request.direction, tables: request.tables,
      failedTables, attempt, nextRetryAt: 0
    });
    if (failedTables.length === 0 || attempt > CLOUD_SYNC_MAX_RETRY_ATTEMPTS) {
      this.removeAutomaticRetry(retryKey);
      return;
    }
    const delay: number = nextCloudSyncRetryDelayMs(attempt);
    if (delay < 0) { return; }
    const record: CloudSyncRetryRecord = {
      source: request.source,
      direction: request.direction,
      tables: request.tables.slice(),
      failedTables: failedTables.slice(),
      attempt,
      nextRetryAt: Date.now() + delay
    };
    this.retryRecords = upsertAutomaticRetryRecord(this.retryRecords, record);
    this.writeRetryRecords();
    this.scheduleRetryTimer();
  }

  private removeAutomaticRetry(retryKey: string): void {
    const remaining: CloudSyncRetryRecord[] = [];
    for (let i = 0; i < this.retryRecords.length; i++) {
      if (automaticRetryKey(this.retryRecords[i]) !== retryKey) { remaining.push(this.retryRecords[i]); }
    }
    this.retryRecords = remaining;
    this.writeRetryRecords();
    this.scheduleRetryTimer();
  }

  private writeRetryRecords(): void {
    if (!this.context) { return; }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: PREFS_NAME });
      if (this.retryRecords.length === 0) { prefs.deleteSync(RETRY_PREFERENCE_KEY); }
      else { prefs.putSync(RETRY_PREFERENCE_KEY, JSON.stringify(this.retryRecords)); }
      prefs.flushSync();
    } catch (err) { hilog.warn(DOMAIN, TAG, 'persist retry failed: ' + JSON.stringify(err)); }
  }

  private scheduleRetryTimer(): void {
    if (this.retryTimer >= 0) { clearTimeout(this.retryTimer); this.retryTimer = -1; }
    if (this.retryRecords.length === 0) { return; }
    let earliest: CloudSyncRetryRecord = this.retryRecords[0];
    for (let i = 1; i < this.retryRecords.length; i++) {
      if (this.retryRecords[i].nextRetryAt < earliest.nextRetryAt) { earliest = this.retryRecords[i]; }
    }
    const delay: number = Math.max(0, earliest.nextRetryAt - Date.now());
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      const now: number = Date.now();
      const due: CloudSyncRetryRecord[] = [];
      const remaining: CloudSyncRetryRecord[] = [];
      for (let i = 0; i < this.retryRecords.length; i++) {
        if (this.retryRecords[i].nextRetryAt <= now) { due.push(this.retryRecords[i]); }
        else { remaining.push(this.retryRecords[i]); }
      }
      this.retryRecords = remaining;
      this.writeRetryRecords();
      this.scheduleRetryTimer();
      for (let i = 0; i < due.length; i++) {
        const retry: CloudSyncRetryRecord = due[i];
        const tables: string[] = retryTablesStillSelected(retry.tables, this.selectedTables());
        if (tables.length === 0) {
          this.automaticRetryAttempts[automaticRetryKey(retry)] = 0;
          continue;
        }
        this.enqueueAutomaticRequest(
          { source: 'automaticPush', direction: retry.direction, tables },
          automaticRetryKey(retry)
        );
      }
    }, delay) as number;
  }
}
