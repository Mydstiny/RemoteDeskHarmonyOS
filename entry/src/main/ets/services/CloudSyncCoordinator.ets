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
  CloudSyncFailureKind,
  automaticRetryKey,
  coalesceAutomaticPush,
  shouldBlockAutomaticRetry,
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
const CONFLICT_PREFERENCE_KEY = 'cloudSyncConflictTables';

export interface CloudSyncOperationResult {
  ok: boolean;
  source: CloudSyncSource;
  tables: string[];
  failedTables: string[];
  rollbackFailed: boolean;
  failureKind: CloudSyncFailureKind;
}

export type CloudSyncTableExecutor = (table: string, direction: CloudSyncDirection, label: string) => Promise<boolean>;

export interface CloudSyncCoordinatorHooks {
  beginManualDownload: () => boolean;
  rollbackManualDownload: () => Promise<boolean>;
  /** Return false to roll the just-applied cloud download back to its snapshot. */
  completeManualDownload: (tables: string[]) => boolean | void;
  setRestorePending: (pending: boolean) => void;
  pendingMutationTableRevisions?: () => Record<string, number>;
  acknowledgeMutationJournal?: (table: string, coveredRevision: number) => boolean;
  failureKindForTable?: (table: string) => CloudSyncFailureKind;
  hasRestoredNotUploaded?: () => boolean;
  clearRestoredNotUploaded?: () => boolean;
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
  let failureKind: CloudSyncFailureKind = 'none';
  if (!executor || request.tables.length === 0) {
    return {
      ok: request.tables.length === 0, source: request.source, tables: request.tables.slice(),
      failedTables: request.tables.slice(), rollbackFailed: false,
      failureKind: request.tables.length === 0 ? 'none' : 'unknown'
    };
  }
  if (request.source === 'manualDownload') {
    try {
      if (!hooks || !hooks.beginManualDownload()) {
        return {
          ok: false, source: request.source, tables: request.tables.slice(),
          failedTables: request.tables.slice(), rollbackFailed: false, failureKind: 'unknown'
        };
      }
    } catch (_e) {
      return {
        ok: false, source: request.source, tables: request.tables.slice(),
        failedTables: request.tables.slice(), rollbackFailed: false, failureKind: 'unknown'
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
      failureKind = hooks && hooks.failureKindForTable ? hooks.failureKindForTable(table) : 'unknown';
      if (table === 'cryptoparams') {
        for (let j = i + 1; j < request.tables.length; j++) { failedTables.push(request.tables[j]); }
      }
      break;
    }
    if (!ok) {
      failedTables.push(table);
      failureKind = hooks && hooks.failureKindForTable ? hooks.failureKindForTable(table) : 'unknown';
      if (table === 'cryptoparams') {
        for (let j = i + 1; j < request.tables.length; j++) { failedTables.push(request.tables[j]); }
        break;
      }
    }
  }
  let rollbackFailed: boolean = false;
  if (request.source === 'manualDownload' && hooks) {
    try {
      if (failedTables.length === 0) {
        const completed: boolean | void = hooks.completeManualDownload(request.tables.slice());
        if (completed === false) {
          failedTables.push(request.tables.length > 0 ? request.tables[0] : '');
          if (failureKind === 'none') { failureKind = 'unknown'; }
          rollbackFailed = !(await hooks.rollbackManualDownload());
        }
      } else { rollbackFailed = !(await hooks.rollbackManualDownload()); }
    } catch (_e) {
      rollbackFailed = true;
    }
  }
  const result: CloudSyncOperationResult = {
    ok: failedTables.length === 0 && !rollbackFailed,
    source: request.source,
    tables: request.tables.slice(),
    failedTables,
    rollbackFailed,
    failureKind
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
  private blockedAutomaticTables: string[] = [];
  private journalMutationRevisions: Record<string, number> = {};

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
    this.restoreConflictTables();
    this.restoreMutationJournal();
  }

  requestStartupPull(): Promise<CloudSyncOperationResult> {
    if (this.restoreUploadBlocked()) { return Promise.resolve(this.skippedResult('startup')); }
    const selected: string[] = this.selectedTables();
    const dirty: string[] = this.dirtyAutomaticTables.filter((table: string): boolean =>
      selected.indexOf(table) >= 0);
    const pushable: string[] = dirty.filter((table: string): boolean => !this.isAutomaticSyncBlocked(table));
    if (pushable.length === 0) { return this.requestCloudFirst('startup'); }
    const versions: Record<string, number> = {};
    pushable.forEach((table: string): void => {
      versions[table] = this.automaticMutationVersions[table] || 1;
    });
    const journalRevisions: Record<string, number> = this.captureJournalRevisions(pushable);
    const request: CloudSyncRequest = {
      source: 'automaticPush', direction: 'nativeFirst', tables: snapshotCloudSyncTables(pushable)
    };
    return this.enqueue(request).then((result: CloudSyncOperationResult): Promise<CloudSyncOperationResult> => {
      if (!result.ok) { return Promise.resolve(result); }
      pushable.forEach((table: string): void => {
        this.acknowledgeJournal(table, journalRevisions[table] || 0);
        const currentJournalRevision: number = this.captureJournalRevisions([table])[table] || 0;
        if ((this.automaticMutationVersions[table] || versions[table]) === versions[table] &&
          currentJournalRevision <= 0) {
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
    const request: CloudSyncRequest = this.makeRequest('manualUpload', 'nativeFirst');
    const versions: Record<string, number> = {};
    for (let i = 0; i < request.tables.length; i++) {
      versions[request.tables[i]] = this.automaticMutationVersions[request.tables[i]] || 0;
    }
    const journalRevisions: Record<string, number> = this.captureJournalRevisions(request.tables);
    return this.enqueue(request).then((result: CloudSyncOperationResult): CloudSyncOperationResult => {
      if (!result.ok) { return result; }
      for (let i = 0; i < request.tables.length; i++) {
        const table: string = request.tables[i];
        this.clearAutomaticSyncBlock(table);
        this.acknowledgeJournal(table, journalRevisions[table] || 0);
        const currentJournalRevision: number = this.captureJournalRevisions([table])[table] || 0;
        if ((this.automaticMutationVersions[table] || 0) === versions[table] && currentJournalRevision <= 0) {
          this.clearDirtyTable(table);
        }
      }
      if (this.hooks && this.hooks.hasRestoredNotUploaded && this.hooks.hasRestoredNotUploaded() &&
        this.hooks.clearRestoredNotUploaded && !this.hooks.clearRestoredNotUploaded()) {
        hilog.warn(DOMAIN, TAG, 'manual upload completed but restored-state marker could not be cleared');
      }
      return result;
    });
  }

  requestManualDownload(): Promise<CloudSyncOperationResult> {
    const request: CloudSyncRequest = this.makeRequest('manualDownload', 'cloudFirst');
    const versions: Record<string, number> = {};
    for (let i = 0; i < request.tables.length; i++) {
      versions[request.tables[i]] = this.automaticMutationVersions[request.tables[i]] || 0;
    }
    return this.enqueue(request).then((result: CloudSyncOperationResult): CloudSyncOperationResult => {
      if (!result.ok) { return result; }
      for (let i = 0; i < request.tables.length; i++) {
        const table: string = request.tables[i];
        this.clearAutomaticSyncBlock(table);
        if ((this.automaticMutationVersions[table] || 0) === versions[table]) { this.clearDirtyTable(table); }
      }
      return result;
    });
  }

  requestAutomaticPush(table: string): Promise<CloudSyncOperationResult> {
    const selected: string[] = this.selectedTables();
    if (selected.indexOf(table) < 0 || this.restorePending || this.restoreUploadBlocked()) {
      return Promise.resolve(this.skippedResult('automaticPush'));
    }
    const version: number = (this.automaticMutationVersions[table] || 0) + 1;
    this.automaticMutationVersions[table] = version;
    this.markDirtyTable(table);
    if (this.isAutomaticSyncBlocked(table)) {
      hilog.warn(DOMAIN, TAG, 'automatic push blocked after cloud conflict table=' + table);
      return Promise.resolve(this.skippedResult('automaticPush'));
    }
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
    const journalRevision: number = this.captureJournalRevisions([table])[table] || 0;
    return this.enqueueAutomaticRequest({ source: 'automaticPush', direction: 'nativeFirst', tables },
      table, version, journalRevision);
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
    completedVersion: number = this.automaticMutationVersions[retryKey] || 1,
    coveredJournalRevision: number = this.captureJournalRevisions([retryKey])[retryKey] || 0): Promise<CloudSyncOperationResult> {
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
        this.acknowledgeJournal(retryKey, coveredJournalRevision);
        const latestVersion: number = this.automaticMutationVersions[retryKey] || completedVersion;
        if (shouldReplayAutomaticPush(completedVersion, latestVersion)) {
          const selected: string[] = this.selectedTables();
          const tables: string[] = selected.filter((candidate: string): boolean =>
            candidate === 'cryptoparams' || candidate === retryKey);
          this.enqueueAutomaticRequest({ source: 'automaticPush', direction: 'nativeFirst', tables },
            retryKey, latestVersion, this.captureJournalRevisions([retryKey])[retryKey] || 0);
        } else {
          const currentJournalRevision: number = this.captureJournalRevisions([retryKey])[retryKey] || 0;
          if (currentJournalRevision <= 0) { this.clearDirtyTable(retryKey); }
        }
      } else {
        if (shouldBlockAutomaticRetry(result.failureKind)) {
          this.blockAutomaticSyncTable(retryKey);
          this.removeAutomaticRetry(retryKey);
          hilog.warn(DOMAIN, TAG, 'automatic retry blocked table=' + retryKey +
            ' failure=' + result.failureKind);
        } else {
          const attempt: number = (this.automaticRetryAttempts[retryKey] || 0) + 1;
          this.automaticRetryAttempts[retryKey] = attempt;
          this.persistAutomaticRetry(request, result.failedTables, attempt);
        }
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
          const restored: boolean = await work();
          if (restored) { this.clearAllDirtyIntents(); }
          resolve(restored);
        } catch (_e) {
          resolve(false);
        } finally {
          this.restorePending = false;
          if (this.hooks) { this.hooks.setRestorePending(false); }
        }
      }, async (): Promise<void> => {
        try {
          const restored: boolean = await work();
          if (restored) { this.clearAllDirtyIntents(); }
          resolve(restored);
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
    if (source !== 'manualDownload' && this.restoreUploadBlocked()) {
      return Promise.resolve(this.skippedResult(source));
    }
    if (this.pendingPull) { return this.pendingPull; }
    const request: CloudSyncRequest = this.makeRequest(source, 'cloudFirst');
    this.pendingPull = this.enqueue(request).then((result: CloudSyncOperationResult): CloudSyncOperationResult => {
      this.pendingPull = null;
      return result;
    }, (): CloudSyncOperationResult => {
      this.pendingPull = null;
      return {
        ok: false, source, tables: request.tables, failedTables: request.tables.slice(),
        rollbackFailed: false, failureKind: 'unknown'
      };
    });
    return this.pendingPull;
  }

  private makeRequest(source: CloudSyncSource, direction: CloudSyncDirection): CloudSyncRequest {
    let tables: string[] = this.selectedTables();
    // A conflict-blocked table must not be pulled automatically either.  An
    // explicit manual upload/download is the only operation allowed to
    // resolve that table and clear its durable block.
    if (direction === 'cloudFirst' && source !== 'manualDownload') {
      tables = tables.filter((table: string): boolean => !this.isAutomaticSyncBlocked(table));
    }
    return { source, direction, tables };
  }

  private selectedTables(): string[] {
    return snapshotCloudSyncTables(this.selection.selectedBusinessTables());
  }

  private skippedResult(source: CloudSyncSource): CloudSyncOperationResult {
    return { ok: true, source, tables: [], failedTables: [], rollbackFailed: false, failureKind: 'none' };
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

  private restoreConflictTables(): void {
    if (!this.context) { return; }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: PREFS_NAME });
      const raw: string = prefs.getSync(CONFLICT_PREFERENCE_KEY, '[]') as string;
      const parsed = JSON.parse(raw) as Object;
      if (!Array.isArray(parsed)) { return; }
      const values = parsed as string[];
      for (let i = 0; i < values.length; i++) {
        if (values[i] !== '' && this.blockedAutomaticTables.indexOf(values[i]) < 0) {
          this.blockedAutomaticTables.push(values[i]);
        }
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'restore conflict tables ignored: ' + JSON.stringify(err));
    }
  }

  private writeConflictTables(): void {
    if (!this.context) { return; }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: PREFS_NAME });
      if (this.blockedAutomaticTables.length === 0) {
        prefs.deleteSync(CONFLICT_PREFERENCE_KEY);
      } else {
        prefs.putSync(CONFLICT_PREFERENCE_KEY, JSON.stringify(this.blockedAutomaticTables));
      }
      prefs.flushSync();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'write conflict tables failed: ' + JSON.stringify(err));
    }
  }

  private isAutomaticSyncBlocked(table: string): boolean {
    return this.blockedAutomaticTables.indexOf(table) >= 0;
  }

  private blockAutomaticSyncTable(table: string): void {
    if (table === '' || this.isAutomaticSyncBlocked(table)) { return; }
    this.blockedAutomaticTables.push(table);
    this.writeConflictTables();
  }

  private clearAutomaticSyncBlock(table: string): void {
    const index: number = this.blockedAutomaticTables.indexOf(table);
    if (index < 0) { return; }
    this.blockedAutomaticTables.splice(index, 1);
    this.writeConflictTables();
  }

  /** Journal rows survive a process death even if Preferences could not flush. */
  private restoreMutationJournal(): void {
    if (!this.hooks || !this.hooks.pendingMutationTableRevisions) { return; }
    try {
      const revisions: Record<string, number> = this.hooks.pendingMutationTableRevisions();
      const tables: string[] = Object.keys(revisions);
      for (let i = 0; i < tables.length; i++) {
        const table: string = tables[i];
        const revision: number = revisions[table];
        if (!Number.isFinite(revision) || revision <= 0) { continue; }
        this.journalMutationRevisions[table] = Math.max(this.journalMutationRevisions[table] || 0, revision);
        if (this.dirtyAutomaticTables.indexOf(table) < 0) { this.dirtyAutomaticTables.push(table); }
        this.automaticMutationVersions[table] = Math.max(this.automaticMutationVersions[table] || 0, 1);
      }
      this.writeDirtyTables();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'restore mutation journal ignored: ' + JSON.stringify(err));
    }
  }

  private captureJournalRevisions(tables: string[]): Record<string, number> {
    const result: Record<string, number> = {};
    if (!this.hooks || !this.hooks.pendingMutationTableRevisions) { return result; }
    try {
      const current: Record<string, number> = this.hooks.pendingMutationTableRevisions();
      for (let i = 0; i < tables.length; i++) {
        const table: string = tables[i];
        const revision: number = current[table] || 0;
        if (revision > 0) {
          this.journalMutationRevisions[table] = revision;
          result[table] = revision;
        } else {
          this.journalMutationRevisions[table] = 0;
        }
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'read mutation journal failed: ' + JSON.stringify(err));
    }
    return result;
  }

  private acknowledgeJournal(table: string, revision: number): void {
    if (revision <= 0 || !this.hooks || !this.hooks.acknowledgeMutationJournal) { return; }
    try {
      if (!this.hooks.acknowledgeMutationJournal(table, revision)) {
        hilog.warn(DOMAIN, TAG, 'journal acknowledgement deferred table=' + table);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'journal acknowledgement failed table=' + table + ' err=' + JSON.stringify(err));
    }
  }

  private restoreUploadBlocked(): boolean {
    if (!this.hooks || !this.hooks.hasRestoredNotUploaded) { return false; }
    try { return this.hooks.hasRestoredNotUploaded(); } catch (_e) { return false; }
  }

  private clearAllDirtyIntents(): void {
    this.dirtyAutomaticTables = [];
    this.automaticMutationVersions = {};
    this.journalMutationRevisions = {};
    this.blockedAutomaticTables = [];
    this.deferredAutomaticTables = [];
    this.retryRecords = [];
    this.automaticRetryAttempts = {};
    this.writeDirtyTables();
    this.writeConflictTables();
    this.writeRetryRecords();
    this.scheduleRetryTimer();
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
        const retryKey: string = automaticRetryKey(retry);
        if (this.isAutomaticSyncBlocked(retryKey)) {
          this.automaticRetryAttempts[retryKey] = 0;
          continue;
        }
        const tables: string[] = retryTablesStillSelected(retry.tables, this.selectedTables());
        if (tables.length === 0) {
          this.automaticRetryAttempts[retryKey] = 0;
          continue;
        }
        this.enqueueAutomaticRequest(
          { source: 'automaticPush', direction: retry.direction, tables },
          retryKey
        );
      }
    }, delay) as number;
  }
}
