/** Per-ability PC window state. Maximized and immersive fullscreen are explicit. */
import { display, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0025;
const TAG: string = 'SessionWindowFrame';
const PRESENTATION_POLL_MS: number = 50;
const PRESENTATION_POLL_ATTEMPTS: number = 24;
const FULLSCREEN_GEOMETRY_TOLERANCE_PX: number = 4;
const SYSTEM_MAXIMIZE_PROMOTION_DELAY_MS: number = 700;

function waitForPresentation(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

export class RemoteSessionWindowFrameController {
  private mainWindow: window.Window | null = null;
  private fullscreen: boolean = false;
  private transitioning: boolean = false;
  private systemMaximizePromotionTimer: number = -1;
  private onFullscreenChange: ((fullscreen: boolean) => void) | null = null;
  private readonly statusCallback = (status: window.WindowStatusType): void => {
    hilog.info(DOMAIN, TAG, 'window status=%{public}d transitioning=%{public}s',
      status, this.transitioning ? 'true' : 'false');
    if (status === window.WindowStatusType.FULL_SCREEN) {
      this.cancelSystemMaximizePromotion();
      this.publishFullscreen(true);
      this.applyHoverPolicy(true, false);
    } else if (status === window.WindowStatusType.MAXIMIZE) {
      // API24 PC can ignore the app immersive preference for the system title
      // button and settle at work-area MAXIMIZE with ContainerModal still
      // visible. Promote only after that animation has settled; calling
      // maximize() from this callback synchronously causes an expand/shrink
      // race. Repeated MAXIMIZE callbacks share one delayed transaction.
      const immersive: boolean = this.readImmersiveLayout(false);
      this.publishFullscreen(immersive);
      this.applyHoverPolicy(true, !immersive);
      if (!immersive && !this.transitioning) { this.scheduleSystemMaximizePromotion(); }
    } else if (status === window.WindowStatusType.FLOATING) {
      this.cancelSystemMaximizePromotion();
      const leavingFullscreen: boolean = this.fullscreen;
      this.publishFullscreen(false);
      this.applyHoverPolicy(true, true);
      if (leavingFullscreen && !this.transitioning) { this.restoreWindowedPresentation(); }
    } else if (status === window.WindowStatusType.SPLIT_SCREEN) {
      this.cancelSystemMaximizePromotion();
      // Split geometry belongs to the system window manager. Restore only
      // decor/insets; never call recover() or apply floating geometry here.
      const leavingFullscreen: boolean = this.fullscreen;
      this.publishFullscreen(false);
      this.applyHoverPolicy(true, true);
      if (leavingFullscreen && !this.transitioning) { this.restoreWindowedPresentation(); }
    }
  };

  attach(mainWindow: window.Window,
    onFullscreenChange: (fullscreen: boolean) => void): void {
    this.detach();
    this.mainWindow = mainWindow;
    this.onFullscreenChange = onFullscreenChange;
    // HarmonyOS uses this preference when the system title-bar maximize action
    // begins. Set it while the window is still floating so maximize enters the
    // immersive presentation directly instead of requiring a recover/retry.
    try { mainWindow.setImmersiveModeEnabledState(true); } catch (err) {
      hilog.warn(DOMAIN, TAG,
        'initial immersive preference failed: %{public}s', JSON.stringify(err));
    }
    try { mainWindow.setWindowDecorVisible(true); } catch (err) {
      hilog.warn(DOMAIN, TAG,
        'initial window decor failed: %{public}s', JSON.stringify(err));
    }
    try {
      mainWindow.on('windowStatusChange', this.statusCallback);
      this.statusCallback(mainWindow.getWindowStatus());
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'frame attach failed: %{public}s', JSON.stringify(err));
      this.publishFullscreen(false);
    }
  }

  detach(): void {
    if (this.mainWindow !== null) {
      try { this.mainWindow.off('windowStatusChange', this.statusCallback); } catch (_err) {}
    }
    this.mainWindow = null;
    this.onFullscreenChange = null;
    this.fullscreen = false;
    this.transitioning = false;
    this.cancelSystemMaximizePromotion();
  }

  isFullscreen(): boolean { return this.fullscreen; }

  async promoteInteractive(): Promise<boolean> {
    const mainWindow: window.Window | null = this.mainWindow;
    if (mainWindow === null) { return false; }
    try {
      // `RemoteSessionAbility` owns an application main window, not a child
      // window. On PC the source ability can finish its router transaction
      // after the target reports content-ready, leaving both missions in the
      // foreground while the source window remains above the new session.
      // HarmonyOS documents showWindow() as the main-window API that moves an
      // already displayed window to the top; raiseToAppTop() is intentionally
      // limited to subwindows and returns 1300009 for this window type.
      await mainWindow.showWindow();
      await mainWindow.setWindowFocusable(true);
      await mainWindow.setWindowTouchable(true);
      hilog.info(DOMAIN, TAG, 'interactive flags applied focused=%{public}s',
        mainWindow.isFocused() ? 'true' : 'false');
      return true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG,
        'interactive promotion failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  async toggle(): Promise<boolean> {
    if (this.transitioning) { return false; }
    return this.fullscreen ? await this.exitFullscreen() : await this.enterFullscreen();
  }

  async enterFullscreen(): Promise<boolean> {
    return await this.enterFullscreenWithPresentation('app');
  }

  private async enterFullscreenWithPresentation(source: string): Promise<boolean> {
    const mainWindow: window.Window | null = this.mainWindow;
    if (mainWindow === null || this.transitioning) { return false; }
    this.cancelSystemMaximizePromotion();
    this.transitioning = true;
    try {
      mainWindow.setImmersiveModeEnabledState(true);
      // maximize(ENTER_IMMERSIVE) is the platform's single system-level
      // transition. Keep decor enabled so the title hot zone remains the
      // official mouse escape path; F11 provides the keyboard path.
      mainWindow.setWindowDecorVisible(true);
      await mainWindow.maximize(window.MaximizePresentation.ENTER_IMMERSIVE);
      try { await mainWindow.setTitleAndDockHoverShown(true, false); } catch (_err) {}
      const verified: boolean = await this.waitForFullDisplayGeometry(mainWindow);
      this.publishFullscreen(verified);
      hilog.info(DOMAIN, TAG,
        'fullscreen source=%{public}s verified=%{public}s status=%{public}d',
        source, verified ? 'true' : 'false', mainWindow.getWindowStatus());
      if (!verified) {
        // Keep the user's maximized window in place on a capability mismatch.
        // Restoring its normal chrome is a single, non-geometric fallback and
        // avoids the former expand/shrink retry animation.
        await this.restoreFloatingPresentationAsync(mainWindow);
      }
      return verified;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'enter fullscreen failed: %{public}s', JSON.stringify(err));
      await this.restoreFloatingPresentationAsync(mainWindow);
      this.publishFullscreen(false);
      return false;
    } finally {
      this.transitioning = false;
    }
  }

  async exitFullscreen(): Promise<boolean> {
    const mainWindow: window.Window | null = this.mainWindow;
    if (mainWindow === null || this.transitioning) { return false; }
    this.cancelSystemMaximizePromotion();
    this.transitioning = true;
    try {
      await mainWindow.recover();
      await this.restoreFloatingPresentationAsync(mainWindow);
      this.publishFullscreen(false);
      return true;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'exit fullscreen failed: %{public}s', JSON.stringify(err));
      return false;
    } finally {
      this.transitioning = false;
    }
  }

  private hasFullDisplayGeometry(mainWindow: window.Window): boolean {
    try {
      const properties: window.WindowProperties = mainWindow.getWindowProperties();
      const targetDisplay: display.Display = properties.displayId === undefined
        ? display.getDefaultDisplaySync()
        : display.getDisplayByIdSync(properties.displayId);
      const rect: window.Rect = properties.windowRect;
      const fullWidth: boolean = rect.width >=
        targetDisplay.width - FULLSCREEN_GEOMETRY_TOLERANCE_PX;
      const fullHeight: boolean = rect.height >=
        targetDisplay.height - FULLSCREEN_GEOMETRY_TOLERANCE_PX;
      hilog.info(DOMAIN, TAG,
        'geometry=%{public}dx%{public}d display=%{public}dx%{public}d',
        rect.width, rect.height, targetDisplay.width, targetDisplay.height);
      return fullWidth && fullHeight;
    } catch (err) {
      hilog.warn(DOMAIN, TAG,
        'fullscreen geometry verification failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  private async waitForFullDisplayGeometry(mainWindow: window.Window): Promise<boolean> {
    for (let attempt: number = 0; attempt < PRESENTATION_POLL_ATTEMPTS; attempt++) {
      if (this.hasFullDisplayGeometry(mainWindow)) { return true; }
      await waitForPresentation(PRESENTATION_POLL_MS);
    }
    return this.hasFullDisplayGeometry(mainWindow);
  }

  private readImmersiveLayout(fallback: boolean): boolean {
    const mainWindow: window.Window | null = this.mainWindow;
    if (mainWindow === null) { return fallback; }
    try { return mainWindow.isImmersiveLayout(); } catch (_err) { return fallback; }
  }

  private scheduleSystemMaximizePromotion(): void {
    if (this.mainWindow === null || this.systemMaximizePromotionTimer >= 0) { return; }
    this.systemMaximizePromotionTimer = setTimeout((): void => {
      this.systemMaximizePromotionTimer = -1;
      if (this.mainWindow === null || this.transitioning ||
        this.readImmersiveLayout(false)) { return; }
      void this.enterFullscreenWithPresentation('system-maximize');
    }, SYSTEM_MAXIMIZE_PROMOTION_DELAY_MS);
  }

  private cancelSystemMaximizePromotion(): void {
    if (this.systemMaximizePromotionTimer < 0) { return; }
    clearTimeout(this.systemMaximizePromotionTimer);
    this.systemMaximizePromotionTimer = -1;
  }

  private restoreWindowedPresentation(): void {
    const mainWindow: window.Window | null = this.mainWindow;
    if (mainWindow === null) { return; }
    void this.restoreFloatingPresentationAsync(mainWindow);
  }

  private async restoreFloatingPresentationAsync(mainWindow: window.Window): Promise<void> {
    try { await mainWindow.setWindowLayoutFullScreen(false); } catch (_err) {}
    try { mainWindow.setWindowDecorVisible(true); } catch (_err) {}
    try { await mainWindow.setTitleAndDockHoverShown(true, true); } catch (_err) {}
    // Keep the next system maximize immersive; this preference has no visual
    // effect while the window is floating.
    try { mainWindow.setImmersiveModeEnabledState(true); } catch (_err) {}
  }

  private publishFullscreen(fullscreen: boolean): void {
    this.fullscreen = fullscreen;
    if (this.onFullscreenChange !== null) { this.onFullscreenChange(fullscreen); }
  }

  private applyHoverPolicy(titleShown: boolean, dockShown: boolean): void {
    const mainWindow: window.Window | null = this.mainWindow;
    if (mainWindow === null) { return; }
    void mainWindow.setTitleAndDockHoverShown(titleShown, dockShown).catch((_err: Error): void => {
      // Some window managers deliver the status callback one frame before
      // the presentation transition finishes. The explicit F11 path retries
      // after maximize; system-title-button maximize remains immersive even
      // if this optional hover refinement is unavailable.
    });
  }
}
