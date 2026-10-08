import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { transferDiagnosticLine } from './TransferDiagnosticPolicy';
import { FileTransferLiveTaskService } from './FileTransferLiveTaskService';
import { createTransferSnapshot, FileTransferProgressSnapshot, TransferProtocol } from './FileTransferProgressModel';
import { ManagedTransferTaskStore } from './ManagedTransferTaskStore';
import { ManagedTransferOutcome, ManagedTransferRecord, ManagedTransferProgress,
  applyManagedTransferProgress, managedTransferCode,
  managedTransferEvidenceValid, managedTransferIdentifier } from './ManagedTransferTaskPolicy';

/** A persisted progress tick at most this often; stage changes and results persist at once. */
const PROGRESS_PERSIST_INTERVAL_MS: number = 5000;
/** A user's cancel waits this long for the remote to stop before the result is called unknown. */
const USER_CANCEL_GRACE_MS: number = 15000;

export interface ManagedTransferOptions {
  accountScopeId: string;
  hostId: string;
  protocol: TransferProtocol;
  direction: 'upload' | 'download';
  fileName: string;
  totalBytes: number;
  batchId?: string;
  sourceKind?: string;
  leaseId?: string;
  taskId?: string;
  attemptId?: number;
  isCurrent: () => boolean;
  onFinalize?: (outcome: ManagedTransferOutcome) => Promise<void> | void;
  /** Optional total deadline; no total deadline is imposed by default. */
  timeoutMs?: number;
  /** No byte/stage progress for this duration requests cancellation; default 5 minutes. */
  idleTimeoutMs?: number;
  cancelGraceMs?: number;
  /** Tasks with the same key (one remote session) run one at a time (two on PC); different keys run side by side. */
  queueKey?: string;
  /** A purely local task (saving a received copy): its own queue, never bound to the session, cancellable throughout. */
  local?: boolean;
  /** The session window the task belongs to; a tap on its notification brings that window forward. */
  windowId?: string;
}
export interface ManagedTransferControl {
  taskId: string;
  attemptId: number;
  isCurrent: () => boolean;
  isCancellationRequested: () => boolean;
  update: (progress: ManagedTransferProgress) => boolean;
  onCancel: (callback: () => Promise<void> | void) => void;
  enterCommit: () => Promise<boolean>;
}
export interface ManagedTransferHandle {
  accepted: boolean;
  taskId: string;
  attemptId: number;
  result: Promise<ManagedTransferOutcome>;
}
export type ManagedTransferRunner = (control: ManagedTransferControl) => Promise<ManagedTransferOutcome>;
export type ManagedTransferListener = (records: ManagedTransferRecord[]) => void;
class ManagedTransferSubscription {
  accountScopeId: string = '';
  listener: ManagedTransferListener = (): void => {};
}
class ManagedTransferRuntime {
  record: ManagedTransferRecord = new ManagedTransferRecord();
  options: ManagedTransferOptions;
  context: common.UIAbilityContext | null = null;
  resolve: (outcome: ManagedTransferOutcome) => void = (): void => {};
  cancelCallback: (() => Promise<void> | void) | null = null;
  cancelCalled: boolean = false;
  cancelRequested: boolean = false;
  commitEntered: boolean = false;
  resultSettled: boolean = false;
  runnerFinished: boolean = false;
  finalized: boolean = false;
  lastProgressAt: number = Date.now();
  startedAt: number = Date.now();
  cancelAt: number = 0;
  deadlineTimer: number = -1;
  outcome: ManagedTransferOutcome | null = null;
  settlementTail: Promise<void> = Promise.resolve();
  lastPublishedAt: number = 0;
  lastPersistedAt: number = 0;
  started: boolean = false;
  /** Between enterCommit and the next stage: received data is being saved locally and must not be torn down. */
  inCommit: boolean = false;
  cancelCode: string = '';
  constructor(options: ManagedTransferOptions) { this.options = options; }
  queueKey(): string { return this.options.local === true ? 'local' : 'net:' + (this.options.queueKey ?? ''); }
}

class ManagedTransferQueued {
  runtime: ManagedTransferRuntime;
  runner: ManagedTransferRunner;
  constructor(runtime: ManagedTransferRuntime, runner: ManagedTransferRunner) {
    this.runtime = runtime; this.runner = runner;
  }
}

/** Owns each asynchronous runner until it drains, independently of page lifetime. */
export class ManagedTransferTaskService {
  private static instance: ManagedTransferTaskService | null = null;
  private context: common.UIAbilityContext | null = null;
  private store: ManagedTransferTaskStore = new ManagedTransferTaskStore();
  private active: Map<string, ManagedTransferRuntime> = new Map<string, ManagedTransferRuntime>();
  private listeners: ManagedTransferSubscription[] = [];
  private queue: ManagedTransferQueued[] = [];
  private running: number = 0;
  private runningByKey: Map<string, number> = new Map<string, number>();
  /** Per remote session; PC sessions get two lanes. */
  private concurrency: number = deviceInfo.deviceType === '2in1' ? 2 : 1;
  /** Across all sessions, so split screen and several windows each make progress. */
  private networkLimit: number = deviceInfo.deviceType === '2in1' ? 4 : 2;
  private appInBackground: boolean = false;
  private appStateObserved: boolean = false;

  constructor() {
    this.store.setActivePredicate((record: ManagedTransferRecord): boolean =>
      this.active.has(this.key(record.accountScopeId, record.taskId, record.attemptId)));
  }

  static getInstance(): ManagedTransferTaskService {
    if (ManagedTransferTaskService.instance === null) { ManagedTransferTaskService.instance = new ManagedTransferTaskService(); }
    return ManagedTransferTaskService.instance;
  }
  init(context: common.UIAbilityContext): boolean {
    if (!this.store.init(context)) { return false; }
    this.context = context; this.observeApplicationState(context); return true;
  }
  setConcurrency(limit: number): void { this.concurrency = limit <= 1 ? 1 : 2; this.drain(); }
  /** Whether the task is still waiting for a free lane. */
  isQueued(accountScopeId: string, taskId: string, attemptId: number): boolean {
    const runtime: ManagedTransferRuntime | undefined = this.active.get(this.key(accountScopeId, taskId, attemptId));
    return runtime !== undefined && !runtime.started && !runtime.resultSettled;
  }
  /** Whether 取消 can stop the task now: running or queued, and not saving received data (a local save can stop). */
  isCancellable(accountScopeId: string, taskId: string, attemptId: number): boolean {
    const runtime: ManagedTransferRuntime | undefined = this.active.get(this.key(accountScopeId, taskId, attemptId));
    return runtime !== undefined && !runtime.resultSettled && !runtime.runnerFinished && !runtime.cancelRequested &&
      (!runtime.inCommit || runtime.options.local === true);
  }
  /** Removes the host's finished records from the list; running tasks stay. */
  clearFinished(accountScopeId: string, hostId: string): number {
    const removed: number = this.store.removeSettled(accountScopeId,
      (record: ManagedTransferRecord): boolean => record.hostId === hostId);
    if (removed > 0) { this.notifyListeners(accountScopeId); }
    return removed;
  }
  /** While no window of the app is in the foreground the system may freeze it; idle time is not counted then. */
  setAppInBackground(value: boolean): void { this.appInBackground = value; }
  private observeApplicationState(context: common.UIAbilityContext): void {
    if (this.appStateObserved) { return; }
    try {
      context.getApplicationContext().on('applicationStateChange', {
        onApplicationForeground: (): void => { this.setAppInBackground(false); },
        onApplicationBackground: (): void => { this.setAppInBackground(true); }
      });
      this.appStateObserved = true;
    } catch (_error) { /* Without the observer the idle clock simply keeps running. */ }
  }
  list(accountScopeId: string): ManagedTransferRecord[] { return this.store.list(accountScopeId); }
  subscribe(accountScopeId: string, listener: ManagedTransferListener): () => void {
    const entry: ManagedTransferSubscription = new ManagedTransferSubscription();
    entry.accountScopeId = accountScopeId; entry.listener = listener; this.listeners.push(entry);
    try { listener(this.list(accountScopeId)); } catch (error) { /* Observer isolation. */ }
    return (): void => { this.listeners = this.listeners.filter((item: ManagedTransferSubscription): boolean => item !== entry); };
  }

  enqueue(options: ManagedTransferOptions, runner: ManagedTransferRunner): ManagedTransferHandle {
    const taskId: string = options.taskId ?? util.generateRandomUUID();
    const attemptId: number = options.attemptId ?? 1;
    const record: ManagedTransferRecord = new ManagedTransferRecord();
    record.taskId = taskId; record.attemptId = attemptId; record.batchId = options.batchId ?? '';
    record.sourceKind = options.sourceKind ?? ''; record.leaseId = options.leaseId ?? '';
    record.accountScopeId = options.accountScopeId; record.hostId = options.hostId;
    record.protocol = options.protocol; record.direction = options.direction; record.fileName = options.fileName;
    record.totalBytes = options.totalBytes; record.createdAt = Date.now(); record.updatedAt = record.createdAt;
    const key: string = this.key(options.accountScopeId, taskId, attemptId);
    const previous: ManagedTransferRecord[] = this.store.list(options.accountScopeId).filter(
      (item: ManagedTransferRecord): boolean => item.taskId === taskId);
    const activeTask: boolean = Array.from(this.active.values()).some((item: ManagedTransferRuntime): boolean =>
      item.record.accountScopeId === options.accountScopeId && item.record.taskId === taskId);
    if (this.context === null || !managedTransferIdentifier(options.accountScopeId) || !this.currentOptions(options) ||
      activeTask || previous.some((item: ManagedTransferRecord): boolean => item.attemptId >= attemptId ||
        item.stage === 'commitUnknown') ||
      !this.store.ready(options.accountScopeId) || !this.store.upsert(record)) {
      const rejected: ManagedTransferOutcome = { stage: 'failed', evidence: 'none',
        diagnosticCode: 'task_admission_rejected' };
      return { accepted: false, taskId, attemptId, result: Promise.resolve(rejected) };
    }
    const runtime: ManagedTransferRuntime = new ManagedTransferRuntime(options);
    runtime.record = record; runtime.context = this.context;
    const result: Promise<ManagedTransferOutcome> = new Promise<ManagedTransferOutcome>((resolve) => { runtime.resolve = resolve; });
    this.active.set(key, runtime); this.publish(runtime, true);
    this.queue.push(new ManagedTransferQueued(runtime, runner));
    this.drain();
    return { accepted: true, taskId, attemptId, result };
  }

  private drain(): void {
    let index: number = 0;
    while (index < this.queue.length) {
      const queued: ManagedTransferQueued = this.queue[index];
      const runtime: ManagedTransferRuntime = queued.runtime;
      if (runtime.resultSettled) { this.queue.splice(index, 1); continue; }
      const key: string = runtime.queueKey();
      const lane: number = this.runningByKey.get(key) ?? 0;
      const local: boolean = key === 'local';
      if (lane >= (local ? 1 : this.concurrency) || (!local && this.running >= this.networkLimit)) { index++; continue; }
      this.queue.splice(index, 1);
      if (!local) { this.running++; }
      this.runningByKey.set(key, lane + 1);
      runtime.started = true;
      runtime.startedAt = Date.now(); runtime.lastProgressAt = runtime.startedAt;
      runtime.deadlineTimer = setInterval(() => { this.checkDeadline(runtime); }, 1000);
      this.publish(runtime, true);
      this.run(runtime, queued.runner).catch(async (): Promise<void> => {
        runtime.runnerFinished = true;
        await this.settle(runtime, { stage: runtime.commitEntered ? 'commitUnknown' : 'failed', evidence: 'none',
          diagnosticCode: 'runner_failed' });
      }).finally(() => {
        if (!local) { this.running--; }
        const remaining: number = (this.runningByKey.get(key) ?? 1) - 1;
        if (remaining > 0) { this.runningByKey.set(key, remaining); } else { this.runningByKey.delete(key); }
        this.drain();
      });
    }
  }

  cancel(accountScopeId: string, taskId: string, attemptId: number): boolean {
    const runtime: ManagedTransferRuntime | undefined = this.active.get(this.key(accountScopeId, taskId, attemptId));
    if (runtime === undefined || runtime.resultSettled || runtime.runnerFinished) { return false; }
    // Received data being saved locally finishes; stopping halfway would leave an unusable copy behind.
    if (runtime.inCommit && runtime.options.local !== true) { return false; }
    this.requestCancel(runtime, 'cancelled_by_user');
    if (!runtime.started) {
      this.queue = this.queue.filter((item: ManagedTransferQueued): boolean => item.runtime !== runtime);
      runtime.runnerFinished = true;
      this.settle(runtime, { stage: 'cancelled', evidence: 'none', diagnosticCode: 'cancelled_before_start' }).catch(() => {});
    }
    return true;
  }

  private key(scope: string, taskId: string, attemptId: number): string {
    return JSON.stringify([scope, taskId, attemptId.toString()]);
  }
  private currentOptions(options: ManagedTransferOptions): boolean {
    try { return options.isCurrent(); } catch (error) { return false; }
  }
  private current(runtime: ManagedTransferRuntime): boolean {
    if (runtime.resultSettled || runtime.cancelRequested || runtime.runnerFinished) { return false; }
    // Saving received data is local work: a disconnect or reconnect of the session does not interrupt it.
    if (runtime.inCommit && runtime.options.local !== true) { return true; }
    return this.currentOptions(runtime.options);
  }
  private control(runtime: ManagedTransferRuntime): ManagedTransferControl {
    return {
      taskId: runtime.record.taskId, attemptId: runtime.record.attemptId,
      isCurrent: (): boolean => this.current(runtime),
      isCancellationRequested: (): boolean => runtime.cancelRequested || runtime.resultSettled,
      update: (progress: ManagedTransferProgress): boolean => this.update(runtime, progress),
      onCancel: (callback: () => Promise<void> | void): void => {
        runtime.cancelCallback = callback;
        if (runtime.cancelRequested) { this.invokeCancel(runtime); }
      },
      enterCommit: async (): Promise<boolean> => {
        if (!this.current(runtime)) { return false; }
        runtime.commitEntered = true; runtime.inCommit = true;
        runtime.record.commitStarted = true;
        runtime.record.stage = 'committing'; runtime.record.updatedAt = Date.now();
        this.store.upsert(runtime.record); this.publish(runtime, true);
        if (!await this.store.flush() || !this.current(runtime)) { return false; }
        return true;
      }
    };
  }
  private async run(runtime: ManagedTransferRuntime, runner: ManagedTransferRunner): Promise<void> {
    if (!await this.store.flush()) {
      runtime.runnerFinished = true;
      await this.settle(runtime, { stage: 'failed', evidence: 'none', diagnosticCode: 'manifest_write_failed' }); return;
    }
    if (!this.current(runtime)) {
      runtime.runnerFinished = true;
      await this.settle(runtime, { stage: 'cancelled', evidence: 'none', diagnosticCode: 'lease_or_cancel_before_start' }); return;
    }
    const context: common.UIAbilityContext | null = runtime.context;
    if (context !== null) {
      try { await FileTransferLiveTaskService.getInstance().begin(context, this.snapshot(runtime.record),
        runtime.options.windowId ?? ''); }
      catch (error) { /* Notifications cannot prevent an authorized transfer. */ }
    }
    if (!this.current(runtime)) {
      runtime.runnerFinished = true;
      await this.settle(runtime, { stage: 'cancelled', evidence: 'none', diagnosticCode: 'lease_or_cancel_before_start' }); return;
    }
    const outcome: ManagedTransferOutcome = await runner(this.control(runtime));
    runtime.runnerFinished = true;
    await this.settle(runtime, outcome);
  }
  private update(runtime: ManagedTransferRuntime, progress: ManagedTransferProgress): boolean {
    if (!this.current(runtime)) { return false; }
    let effective: ManagedTransferProgress = progress;
    if (runtime.inCommit && runtime.options.local !== true && progress.stage === undefined &&
      ((progress.readBytes ?? 0) > runtime.record.readBytes || (progress.sentBytes ?? 0) > runtime.record.sentBytes ||
        (progress.writtenBytes ?? 0) > runtime.record.writtenBytes)) {
      // New network bytes after a file was saved: the task moved on to its next file.
      effective = { stage: 'transferring', readBytes: progress.readBytes, sentBytes: progress.sentBytes,
        writtenBytes: progress.writtenBytes, verifiedBytes: progress.verifiedBytes, totalBytes: progress.totalBytes };
    }
    const next: ManagedTransferRecord | null = applyManagedTransferProgress(runtime.record, effective);
    if (next === null) { return false; }
    const stageChanged: boolean = next.stage !== runtime.record.stage;
    if (stageChanged || next.readBytes !== runtime.record.readBytes ||
      next.sentBytes !== runtime.record.sentBytes || next.writtenBytes !== runtime.record.writtenBytes ||
      next.verifiedBytes !== runtime.record.verifiedBytes) { runtime.lastProgressAt = Date.now(); }
    if (stageChanged && next.stage !== 'committing') { runtime.inCommit = false; }
    const persist: boolean = stageChanged || Date.now() - runtime.lastPersistedAt >= PROGRESS_PERSIST_INTERVAL_MS;
    if (persist) { runtime.lastPersistedAt = Date.now(); }
    runtime.record = next; this.store.upsert(next, persist); this.publish(runtime, stageChanged); return true;
  }
  private requestCancel(runtime: ManagedTransferRuntime, code: string): void {
    if (runtime.cancelRequested) { return; }
    runtime.cancelRequested = true; runtime.cancelAt = Date.now(); runtime.cancelCode = code;
    runtime.record.stage = 'cancelling'; runtime.record.diagnosticCode = code;
    this.store.upsert(runtime.record); this.publish(runtime, true); this.invokeCancel(runtime);
  }
  private invokeCancel(runtime: ManagedTransferRuntime): void {
    if (runtime.cancelCalled || runtime.cancelCallback === null) { return; }
    runtime.cancelCalled = true;
    try { Promise.resolve(runtime.cancelCallback()).catch(() => { /* Runner owns actual completion. */ }); }
    catch (error) { /* Retain the runner and deadline; never claim successful cancellation. */ }
  }
  private duration(value: number | undefined, fallback: number): number {
    return value !== undefined && Number.isFinite(value) && value > 0 ?
      Math.max(1000, Math.min(86400000, value)) : fallback;
  }
  private checkDeadline(runtime: ManagedTransferRuntime): void {
    if (runtime.resultSettled) { return; }
    const now: number = Date.now();
    // While saving locally, or while the app is in the background, the session and the idle clock do not count.
    if (runtime.inCommit && runtime.options.local !== true) { runtime.lastProgressAt = now; return; }
    if (this.appInBackground) { runtime.lastProgressAt = now; }
    if (!this.currentOptions(runtime.options)) { this.requestCancel(runtime, 'lease_revoked'); }
    const idleMs: number = this.duration(runtime.options.idleTimeoutMs, 300000);
    const totalMs: number = this.duration(runtime.options.timeoutMs, 0);
    if (!runtime.cancelRequested && ((totalMs > 0 && now - runtime.startedAt >= totalMs) ||
      now - runtime.lastProgressAt >= idleMs)) { this.requestCancel(runtime, 'transfer_deadline'); }
    const graceMs: number = this.duration(runtime.options.cancelGraceMs,
      runtime.cancelCode === 'cancelled_by_user' ? USER_CANCEL_GRACE_MS : 5000);
    if (runtime.cancelRequested && now - runtime.cancelAt >= graceMs) {
      // Still retain runner/cancel closures until it drains. No early artifact cleanup.
      this.settle(runtime, { stage: runtime.commitEntered || runtime.record.sentBytes > 0 ||
        runtime.record.writtenBytes > 0 ? 'commitUnknown' : 'paused', evidence: 'none', diagnosticCode: 'cancel_drain_pending' }).catch(() => {});
    }
  }
  private settle(runtime: ManagedTransferRuntime, outcome: ManagedTransferOutcome): Promise<void> {
    runtime.settlementTail = runtime.settlementTail.then(async (): Promise<void> => {
      await this.settleOnce(runtime, outcome);
    });
    return runtime.settlementTail;
  }
  private async settleOnce(runtime: ManagedTransferRuntime, outcome: ManagedTransferOutcome): Promise<void> {
    if (!runtime.resultSettled) {
      const stages: string[] = ['completed', 'failed', 'cancelled', 'paused', 'commitUnknown', 'handedOff', 'interrupted'];
      let accepted: ManagedTransferOutcome = { stage: outcome.stage, evidence: outcome.evidence,
        diagnosticCode: managedTransferCode(outcome.diagnosticCode) };
      if (stages.indexOf(outcome.stage) < 0 || !managedTransferEvidenceValid(outcome.evidence) ||
        (outcome.stage === 'completed' && (outcome.evidence === 'none' || outcome.evidence === 'offered'))) {
        accepted = { stage: runtime.commitEntered ? 'commitUnknown' : 'failed', evidence: 'none', diagnosticCode: 'invalid_completion_evidence' };
      }
      runtime.resultSettled = true; runtime.outcome = accepted; runtime.inCommit = false;
      if (runtime.deadlineTimer >= 0) { clearInterval(runtime.deadlineTimer); runtime.deadlineTimer = -1; }
      runtime.record.stage = accepted.stage; runtime.record.evidence = accepted.evidence;
      runtime.record.diagnosticCode = managedTransferCode(accepted.diagnosticCode); runtime.record.updatedAt = Date.now();
      this.store.upsert(runtime.record); this.publish(runtime, true); await this.store.flush();
      const context: common.UIAbilityContext | null = runtime.context;
      if (context !== null) {
        try { await FileTransferLiveTaskService.getInstance().complete(context, this.snapshot(runtime.record)); }
        catch (error) { /* Task result is independent of notification availability. */ }
      }
    }
    if (runtime.resultSettled && runtime.runnerFinished && runtime.outcome !== null &&
      (runtime.outcome.stage === 'commitUnknown' || runtime.outcome.stage === 'paused' ||
        runtime.outcome.stage === 'interrupted') &&
      outcome.stage === 'completed' && managedTransferEvidenceValid(outcome.evidence) &&
      outcome.evidence !== 'none' && outcome.evidence !== 'offered') {
      // A late actual success refines the retained unknown result; no retry or deletion is inferred.
      runtime.outcome = { stage: outcome.stage, evidence: outcome.evidence,
        diagnosticCode: managedTransferCode(outcome.diagnosticCode) }; runtime.record.stage = outcome.stage; runtime.record.evidence = outcome.evidence;
      runtime.record.diagnosticCode = managedTransferCode(outcome.diagnosticCode);
      runtime.record.updatedAt = Date.now(); this.store.upsert(runtime.record); this.publish(runtime, true);
      await this.store.flush();
    }
    if (runtime.runnerFinished && !runtime.finalized) {
      runtime.finalized = true;
      if (runtime.options.onFinalize !== undefined && runtime.outcome !== null) {
        try { await runtime.options.onFinalize(runtime.outcome); } catch (error) {
          runtime.record.diagnosticCode = 'finalize_cleanup_failed';
          this.store.upsert(runtime.record); this.publish(runtime, true); await this.store.flush();
        }
      }
      this.active.delete(this.key(runtime.record.accountScopeId, runtime.record.taskId, runtime.record.attemptId));
    }
    if (runtime.outcome !== null) { runtime.resolve(runtime.outcome); }
  }
  private snapshot(record: ManagedTransferRecord): FileTransferProgressSnapshot {
    // An RDP upload only reads and stages locally; its progress is the larger of read, sent and written bytes.
    const transferred: number = record.direction === 'upload' ?
      Math.max(record.readBytes, record.sentBytes, record.writtenBytes) : record.writtenBytes;
    const text: string = record.evidence === 'senderCompleted' && record.stage === 'completed' ?
      '发送结束，尚未验证远端保存结果' : '';
    const result: FileTransferProgressSnapshot = createTransferSnapshot(record.taskId, record.protocol,
      record.fileName, transferred, record.totalBytes, record.stage, text);
    result.attemptId = record.attemptId; result.accountScopeId = record.accountScopeId; return result;
  }
  private publish(runtime: ManagedTransferRuntime, immediate: boolean): void {
    const now: number = Date.now();
    if (!immediate && now - runtime.lastPublishedAt < 250) { return; }
    runtime.lastPublishedAt = now;
    try {
      const diagnostic: string = transferDiagnosticLine(runtime.record);
      if (immediate) { hilog.info(0x0001, 'TransferTask', '%{public}s', diagnostic); }
      else { hilog.debug(0x0001, 'TransferTask', '%{public}s', diagnostic); }
    } catch (_error) { /* Diagnostics must never change task or notification outcomes. */ }
    this.notifyListeners(runtime.record.accountScopeId);
    // Progress ticks and stage changes of a running task reach the notification; start and result have their own calls.
    if (!immediate || (runtime.started && !runtime.resultSettled)) {
      FileTransferLiveTaskService.getInstance().update(this.snapshot(runtime.record)).catch(() => {});
    }
  }
  private notifyListeners(accountScopeId: string): void {
    for (let i: number = 0; i < this.listeners.length; i++) {
      const entry: ManagedTransferSubscription = this.listeners[i];
      if (entry.accountScopeId === accountScopeId) {
        try { entry.listener(this.list(entry.accountScopeId)); } catch (error) { /* Observer isolation. */ }
      }
    }
  }
}
