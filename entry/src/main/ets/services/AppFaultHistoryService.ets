import { common, errorManager } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hiAppEvent, hilog } from '@kit.PerformanceAnalysisKit';
import { DiagnosticCaptureBoundary, DiagnosticCaptureRuntime, recordDiagnosticEvent } from './DiagnosticCaptureRuntime';

/** app_fault_history / app_exception kinds. */
export const APP_FAULT_JS_CRASH: number = 1;
export const APP_FAULT_NATIVE_CRASH: number = 2;
export const APP_FAULT_FREEZE: number = 3;

const STORE_NAME: string = 'RemoteDeskFaultHistory-v1';
const STORE_KEY: string = 'faults';
const KEEP: number = 30;
const WEEK_MS: number = 7 * 24 * 3600 * 1000;

class AppFault {
  kind: number;
  at: number;

  constructor(kind: number, at: number) {
    this.kind = kind;
    this.at = at;
  }
}

/**
 * Crashes and freezes of earlier runs, as the system reports them after a restart (hiAppEvent), kept on the device as
 * kind and time only — never a stack, a message or a path. When a diagnostic capture starts, a summary of the last
 * seven days goes into it (app_fault_history), so "打开就闪退" has evidence even though the crash happened before the
 * capture. Unhandled exceptions of this run are counted live (app_exception).
 */
export class AppFaultHistoryService {
  private static started: boolean = false;
  private static faults: AppFault[] = [];
  private static exceptions: number = 0;
  private static context: common.Context | null = null;

  static init(context: common.Context): void {
    if (AppFaultHistoryService.started) { return; }
    AppFaultHistoryService.started = true;
    AppFaultHistoryService.context = context;
    AppFaultHistoryService.load();
    try {
      hiAppEvent.addWatcher({
        name: 'rd_fault_watcher',
        appEventFilters: [{ domain: hiAppEvent.domain.OS, names: [hiAppEvent.event.APP_CRASH, hiAppEvent.event.APP_FREEZE] }],
        onReceive: (_domain: string, groups: Array<hiAppEvent.AppEventGroup>): void => {
          groups.forEach((group: hiAppEvent.AppEventGroup): void => {
            group.appEventInfos.forEach((info: hiAppEvent.AppEventInfo): void => {
              AppFaultHistoryService.add(AppFaultHistoryService.kindOf(group.name, info), AppFaultHistoryService.timeOf(info));
            });
          });
          AppFaultHistoryService.save();
        }
      });
    } catch (_error) { /* the system does not report faults here */ }
    try {
      errorManager.on('error', {
        onUnhandledException: (_message: string): void => {
          // Counted only; the message never leaves this callback.
          AppFaultHistoryService.exceptions++;
          recordDiagnosticEvent('core.app', 'app_exception', 'failed', 0, 0, 0, 0, AppFaultHistoryService.exceptions);
        }
      });
    } catch (_error) { /* no error observer */ }
    DiagnosticCaptureRuntime.getInstance().onBoundary((boundary: DiagnosticCaptureBoundary): void => {
      if (boundary === 'started') { AppFaultHistoryService.recordSummary(); }
    });
  }

  private static kindOf(name: string, info: hiAppEvent.AppEventInfo): number {
    if (name === hiAppEvent.event.APP_FREEZE) { return APP_FAULT_FREEZE; }
    const params = info.params as Record<string, Object>;
    const crashType: Object | undefined = params['crash_type'];
    return typeof crashType === 'string' && (crashType as string).toLowerCase().indexOf('native') >= 0 ?
      APP_FAULT_NATIVE_CRASH : APP_FAULT_JS_CRASH;
  }

  private static timeOf(info: hiAppEvent.AppEventInfo): number {
    const params = info.params as Record<string, Object>;
    const time: Object | undefined = params['time'];
    return typeof time === 'number' && (time as number) > 0 ? time as number : Date.now();
  }

  private static add(kind: number, at: number): void {
    AppFaultHistoryService.faults.push(new AppFault(kind, at));
    AppFaultHistoryService.faults = AppFaultHistoryService.faults.slice(-KEEP);
  }

  /** The last seven days as one event: count crashes, generation freezes, code the latest kind, durationMs its age. */
  private static recordSummary(): void {
    const now: number = Date.now();
    const recent: AppFault[] = AppFaultHistoryService.faults.filter((fault: AppFault): boolean => now - fault.at <= WEEK_MS);
    const crashes: number = recent.filter((fault: AppFault): boolean => fault.kind !== APP_FAULT_FREEZE).length;
    const freezes: number = recent.length - crashes;
    const latest: AppFault | undefined = recent.length > 0 ? recent[recent.length - 1] : undefined;
    recordDiagnosticEvent('core.app', 'app_fault_history', recent.length > 0 ? 'state' : 'succeeded', 0, freezes,
      latest !== undefined ? latest.kind : 0, latest !== undefined ? Math.max(0, now - latest.at) : 0, crashes,
      AppFaultHistoryService.exceptions);
  }

  private static load(): void {
    const context: common.Context | null = AppFaultHistoryService.context;
    if (context === null) { return; }
    try {
      const prefs = preferences.getPreferencesSync(context, { name: STORE_NAME });
      const raw: string = prefs.getSync(STORE_KEY, '[]') as string;
      const parsed: Object = JSON.parse(raw) as Object;
      if (!Array.isArray(parsed)) { return; }
      AppFaultHistoryService.faults = (parsed as Object[]).map((item: Object): AppFault => {
        const row = item as Record<string, Object>;
        return new AppFault(typeof row['kind'] === 'number' ? row['kind'] as number : 0,
          typeof row['at'] === 'number' ? row['at'] as number : 0);
      }).filter((fault: AppFault): boolean => fault.kind > 0 && fault.at > 0).slice(-KEEP);
    } catch (_error) { AppFaultHistoryService.faults = []; }
  }

  private static save(): void {
    const context: common.Context | null = AppFaultHistoryService.context;
    if (context === null) { return; }
    try {
      const prefs = preferences.getPreferencesSync(context, { name: STORE_NAME });
      prefs.putSync(STORE_KEY, JSON.stringify(AppFaultHistoryService.faults));
      prefs.flush();
      hilog.info(0x0000, 'AiTriage', 'fault history %{public}s entries', AppFaultHistoryService.faults.length.toString());
    } catch (_error) { /* kept in memory for this run */ }
  }
}
