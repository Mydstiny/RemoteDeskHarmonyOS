import { AbilityConstant, bundleManager, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  RemoteSessionWindowCoordinator,
  RemoteSessionWindowRecord
} from '../services/RemoteSessionWindowCoordinator';

const DOMAIN: number = 0x0025;
const TAG: string = 'RemoteSessionAbility';

interface RemoteSessionWindowStorageState {
  sessionWindowId: string;
  sessionWindowBackground: boolean;
  sessionWindowFullscreen: boolean;
}

export default class RemoteSessionAbility extends UIAbility {
  private sessionWindowId: string = '';
  private windowStage: window.WindowStage | null = null;
  private uiStorage: LocalStorage | null = null;
  private released: boolean = false;

  onCreate(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
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
    RemoteSessionWindowCoordinator.getInstance().resolve(
      this.sessionWindowId)?.frameController.detach();
    this.windowStage = null;
    this.uiStorage = null;
    this.releaseRuntime();
  }

  onForeground(): void {
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
    this.uiStorage?.set<boolean>('sessionWindowBackground', true);
  }

  onBackground(): void {
    this.uiStorage?.set<boolean>('sessionWindowBackground', true);
  }

  onDestroy(): void { this.releaseRuntime(); }

  private releaseRuntime(): void {
    if (this.released || this.sessionWindowId.length === 0) { return; }
    this.released = true;
    RemoteSessionWindowCoordinator.getInstance().release(this.sessionWindowId);
    hilog.info(DOMAIN, TAG, 'released independent session window');
  }
}
