import { AbilityConstant, bundleManager, UIAbility, Want, wantConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  RemoteSessionWindowCoordinator,
  RemoteSessionWindowRecord
} from '../services/RemoteSessionWindowCoordinator';
import { ProContinuationService, PRO_CONTINUATION_PARAM,
  PRO_CONTINUATION_SECRET_PARAM } from '../services/pro/ProContinuationService';
import { ProFeatureVisibility } from '../services/pro/ProFeatureVisibility';
import { recordDiagnosticAppLifecycleEvent } from '../services/DiagnosticCaptureRuntime';

const DOMAIN: number = 0x0025;
const TAG: string = 'RemoteSessionAbility';

interface RemoteSessionWindowStorageState {
  sessionWindowId: string;
  sessionWindowBackground: boolean;
  sessionWindowFullscreen: boolean;
}

interface ProContinuationWindowStorageState {
  proContinuationBootstrapId: string;
  proContinuationForwarded: boolean;
}

export default class RemoteSessionAbility extends UIAbility {
  private sessionWindowId: string = '';
  private windowStage: window.WindowStage | null = null;
  private uiStorage: LocalStorage | null = null;
  private released: boolean = false;
  private nativeWindowId: number = 0;
  private continuationTransferId: string = '';
  private diagnosticLifecycleGeneration: number = 0;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // A continuation can cold-start this ability without EntryAbility; Pro gates fail closed until loaded.
    ProFeatureVisibility.getInstance().load(this.context);
    ProContinuationService.getInstance().initializeMission(this.context);
    if (launchParam.launchReason === AbilityConstant.LaunchReason.CONTINUATION) {
      this.acceptContinuationWant(want);
      return;
    }
    const raw: Object | undefined = want.parameters?.['sessionWindowId'];
    const id: string = typeof raw === 'string' ? raw.trim() : '';
    const record: RemoteSessionWindowRecord | null =
      RemoteSessionWindowCoordinator.getInstance().activate(id);
    if (record === null) {
      hilog.error(DOMAIN, TAG, 'missing or expired session window launch');
      void this.context.terminateSelf();
      return;
    }
    this.sessionWindowId = id;
    RemoteSessionWindowCoordinator.getInstance().registerTargetCloser(id, (): void => {
      if (this.released) { return; }
      this.released = true;
      void this.context.terminateSelf();
    });
    hilog.info(DOMAIN, TAG, 'created target=%{public}s protocol=%{public}s',
      record.request.target, record.request.protocol);
  }

  private acceptContinuationWant(want: Want): void {
    const value: Object | undefined = want.parameters?.[PRO_CONTINUATION_PARAM];
    const stack: Object | undefined = want.parameters?.[wantConstant.Params.SUPPORT_CONTINUE_PAGE_STACK_KEY];
    const sourceExit: Object | undefined = want.parameters?.[wantConstant.Params.SUPPORT_CONTINUE_SOURCE_EXIT_KEY];
    const service = ProContinuationService.getInstance();
    if (stack !== false || sourceExit !== false || typeof value !== 'string' ||
        !service.ingest(value, want.parameters?.[PRO_CONTINUATION_SECRET_PARAM] ?? null)) {
      void this.context.terminateSelf().catch((): void => {});
      return;
    }
    this.continuationTransferId = service.incomingId();
    try {
      // Official continuation must restore synchronously. The only restored
      // state is an unconfirmed offer; a foreign sessionWindowId is never activated.
      this.context.restoreWindowStage(new LocalStorage());
    } catch (_error) {
      service.cancelIncoming(this.continuationTransferId);
      this.continuationTransferId = '';
      void this.context.terminateSelf().catch((): void => {});
    }
  }

  async onContinue(parameters: Record<string, Object>): Promise<AbilityConstant.OnContinueResult> {
    try {
      const id: number = this.windowStage?.getMainWindowSync().getWindowProperties().id ?? 0;
      return await ProContinuationService.getInstance().onContinue(id, parameters);
    } catch (_error) { return AbilityConstant.OnContinueResult.REJECT; }
  }

  async onWindowStageRestore(stage: window.WindowStage): Promise<void> {
    const id = this.continuationTransferId;
    if (id === '' || this.windowStage !== null) { return; }
    if (ProContinuationService.getInstance().incomingId() !== id) {
      void this.context.terminateSelf().catch((): void => {});
      return;
    }
    this.windowStage = stage;
    const initial: ProContinuationWindowStorageState = {
      proContinuationBootstrapId: id, proContinuationForwarded: false
    };
    const storage = new LocalStorage(initial);
    this.uiStorage = storage;
    try {
      // A multiton target can start a cold process. EntryAbility owns account,
      // database and authentication initialization; this temporary window only opens it.
      await stage.loadContent('pages/RemoteSessionWindowBootstrap', storage);
    } catch (_error) {
      ProContinuationService.getInstance().cancelIncoming(id);
      void this.context.terminateSelf().catch((): void => {});
    }
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    this.windowStage = windowStage;
    const record: RemoteSessionWindowRecord | null =
      RemoteSessionWindowCoordinator.getInstance().resolve(this.sessionWindowId);
    if (record === null) {
      hilog.error(DOMAIN, TAG, 'window stage created after session launch expired');
      await this.context.terminateSelf();
      return;
    }
    const initialStorage: RemoteSessionWindowStorageState = {
      sessionWindowId: this.sessionWindowId,
      sessionWindowBackground: false,
      sessionWindowFullscreen: false
    };
    const storage: LocalStorage = new LocalStorage(initialStorage);
    this.uiStorage = storage;
    const mainWindow: window.Window = windowStage.getMainWindowSync();
    this.nativeWindowId = mainWindow.getWindowProperties().id;
    RemoteSessionWindowCoordinator.getInstance().registerNativeWindow(this.sessionWindowId, this.nativeWindowId);
    try {
      await windowStage.loadContent('pages/RemoteSessionWindowBootstrap', storage);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'bootstrap load failed: %{public}s', JSON.stringify(err));
      RemoteSessionWindowCoordinator.getInstance().failBeforeReady(
        this.sessionWindowId, 'bootstrap-load-failed');
      return;
    }
    // Window-mutating APIs can report 1300002 before content exists. Apply the
    // complete PC contract exactly once after loadContent; StartOptions owns
    // the initial rect and min constraints.
    try {
      await windowStage.setSupportedWindowModes([
        bundleManager.SupportWindowMode.FULL_SCREEN,
        bundleManager.SupportWindowMode.SPLIT,
        bundleManager.SupportWindowMode.FLOATING
      ], false);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'supported window modes failed: %{public}s', JSON.stringify(err));
    }
    try {
      mainWindow.setWindowTitleMoveEnabled(true);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'title move failed: %{public}s', JSON.stringify(err));
    }
    try {
      await mainWindow.setResizeByDragEnabled(true);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'resize by drag failed: %{public}s', JSON.stringify(err));
    }
    try {
      await mainWindow.setWindowFocusable(true);
      await mainWindow.setWindowTouchable(true);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'interactive window flags failed: %{public}s', JSON.stringify(err));
    }
    try {
      await mainWindow.setWindowLayoutFullScreen(false);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'initial non-immersive layout failed: %{public}s', JSON.stringify(err));
    }
    record.frameController.attach(mainWindow, (fullscreen: boolean): void => {
      storage.set<boolean>('sessionWindowFullscreen', fullscreen);
    });
    try {
      await mainWindow.setWindowTitle(record.request.title.length > 0
        ? record.request.title : '远程会话');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'window title failed: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    this.releaseContinuation();
    RemoteSessionWindowCoordinator.getInstance().resolve(
      this.sessionWindowId)?.frameController.detach();
    this.windowStage = null;
    this.uiStorage = null;
    this.releaseRuntime();
  }

  onForeground(): void {
    recordDiagnosticAppLifecycleEvent('state', 'foreground',
      ++this.diagnosticLifecycleGeneration, 11);
    this.uiStorage?.set<boolean>('sessionWindowBackground', false);
    // A PC mission can be restored through the system task/window switcher
    // after the primary EntryAbility has been brought to the front.  The
    // mission callback alone does not guarantee that an application main
    // window is the top WMS surface, so re-assert the same foreground
    // promotion used at content-ready.  The coordinator keeps this fenced to
    // a live, content-ready record and no-ops during early lifecycle turns.
    if (this.sessionWindowId.length > 0) {
      void RemoteSessionWindowCoordinator.getInstance().promoteTargetWindow(
        this.sessionWindowId);
    }
  }

  onWillBackground(): void {
    recordDiagnosticAppLifecycleEvent('state', 'background',
      ++this.diagnosticLifecycleGeneration, 12);
    this.uiStorage?.set<boolean>('sessionWindowBackground', true);
  }

  onBackground(): void {
    recordDiagnosticAppLifecycleEvent('state', 'background',
      ++this.diagnosticLifecycleGeneration, 13);
    this.uiStorage?.set<boolean>('sessionWindowBackground', true);
  }

  onDestroy(): void { this.releaseContinuation(); this.releaseRuntime(); }

  private releaseContinuation(): void {
    if (this.nativeWindowId > 0) {
      ProContinuationService.getInstance().cancelSource(this.nativeWindowId);
      this.nativeWindowId = 0;
    }
    if (this.continuationTransferId !== '') {
      if (this.uiStorage?.get<boolean>('proContinuationForwarded') !== true) {
        ProContinuationService.getInstance().cancelIncoming(this.continuationTransferId);
      }
      this.continuationTransferId = '';
    }
  }

  private releaseRuntime(): void {
    if (this.released || this.sessionWindowId.length === 0) { return; }
    this.released = true;
    RemoteSessionWindowCoordinator.getInstance().release(this.sessionWindowId);
    hilog.info(DOMAIN, TAG, 'released independent session window');
  }
}
