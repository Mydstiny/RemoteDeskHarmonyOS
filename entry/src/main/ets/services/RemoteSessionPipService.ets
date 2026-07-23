/**
 * RemoteSessionPipService — real remote-frame PIP output.
 *
 * AVSession supplies the system media identity and controls; PiPWindow owns
 * the actual XComponent surface shown in the floating video window. The
 * controller is prepared while the main window is visible and the system
 * performs the background auto-start transition.
 */
import { common } from '@kit.AbilityKit';
import { PiPWindow, typeNode, UIContext } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'RemoteSessionPip';
const DOMAIN = 0x0015;

export interface RemoteSessionPipSurface {
  surfaceId: string;
  surfaceWidth: number;
  surfaceHeight: number;
}

type PipSurfaceReadyHandler = (surface: RemoteSessionPipSurface) => Promise<boolean>;
type PipSurfaceChangedHandler = (surface: RemoteSessionPipSurface) => void;
type PipStateHandler = (state: PiPWindow.PiPState, reason: string) => void;

/** The free-node owns a surface independent from the page XComponent. */
class RemoteSessionPipXComponentController extends XComponentController {
  private currentSurfaceId: string = '';
  private currentSurfaceWidth: number = 0;
  private currentSurfaceHeight: number = 0;
  private surfaceChangedHandler: PipSurfaceChangedHandler | null = null;
  private publishedSurfaceId: string = '';
  private publishedSurfaceWidth: number = 0;
  private publishedSurfaceHeight: number = 0;

  setSurfaceChangedHandler(handler: PipSurfaceChangedHandler | null): void {
    this.surfaceChangedHandler = handler;
  }

  onSurfaceCreated(surfaceId: string): void {
    // PiP typeNode callbacks can be dispatched through a system wrapper on
    // API 23. Keep this callback self-contained: the creation callback only
    // guarantees the ID; the first dimensions arrive via onSurfaceChanged.
    this.currentSurfaceId = surfaceId;
    this.currentSurfaceWidth = 0;
    this.currentSurfaceHeight = 0;
    this.publishedSurfaceId = '';
    this.publishedSurfaceWidth = 0;
    this.publishedSurfaceHeight = 0;
    hilog.info(DOMAIN, TAG, 'PIP XComponent surface created id=' + surfaceId);
  }

  onSurfaceChanged(surfaceId: string, rect: SurfaceRect): void {
    this.currentSurfaceId = surfaceId;
    const width: number = Number.isFinite(rect.surfaceWidth) && rect.surfaceWidth > 0
      ? Math.round(rect.surfaceWidth) : 0;
    const height: number = Number.isFinite(rect.surfaceHeight) && rect.surfaceHeight > 0
      ? Math.round(rect.surfaceHeight) : 0;
    this.currentSurfaceWidth = width;
    this.currentSurfaceHeight = height;
    if (width > 0 && height > 0 &&
      (this.currentSurfaceId !== this.publishedSurfaceId ||
       width !== this.publishedSurfaceWidth || height !== this.publishedSurfaceHeight)) {
      this.publishedSurfaceId = this.currentSurfaceId;
      this.publishedSurfaceWidth = width;
      this.publishedSurfaceHeight = height;
      const handler: PipSurfaceChangedHandler | null = this.surfaceChangedHandler;
      if (handler !== null && typeof handler === 'function') {
        handler({ surfaceId: this.currentSurfaceId, surfaceWidth: width, surfaceHeight: height });
      }
    }
    hilog.info(DOMAIN, TAG, 'PIP XComponent surface changed id=' + surfaceId +
      ' surface=' + this.currentSurfaceWidth.toString() + 'x' +
      this.currentSurfaceHeight.toString());
  }

  onSurfaceDestroyed(surfaceId: string): void {
    if (this.currentSurfaceId === surfaceId) {
      this.currentSurfaceId = '';
      this.currentSurfaceWidth = 0;
      this.currentSurfaceHeight = 0;
      this.publishedSurfaceId = '';
      this.publishedSurfaceWidth = 0;
      this.publishedSurfaceHeight = 0;
    }
    hilog.info(DOMAIN, TAG, 'PIP XComponent surface destroyed id=' + surfaceId);
  }

  async waitForSurface(timeoutMs: number): Promise<RemoteSessionPipSurface | null> {
    const startedAtMs: number = Date.now();
    while (Date.now() - startedAtMs < timeoutMs) {
      if (this.currentSurfaceId.length > 0) {
        this.refreshSurfaceRect();
        if (this.hasSurfaceRect()) {
          return this.surfaceInfo();
        }
      }
      try {
        const surfaceId: string = this.getXComponentSurfaceId();
        if (surfaceId.length > 0) {
          this.currentSurfaceId = surfaceId;
          this.refreshSurfaceRect();
          if (this.hasSurfaceRect()) {
            return this.surfaceInfo();
          }
        }
      } catch (_e) {
        // The free node may not have been mounted yet.
      }
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 50);
      });
    }
    return null;
  }

  private validSurfaceDimension(value: number): number {
    return Number.isFinite(value) && value > 0 ? Math.round(value) : 0;
  }

  private refreshSurfaceRect(): void {
    try {
      const rect: SurfaceRect = this.getXComponentSurfaceRect();
      const width: number = this.validSurfaceDimension(rect.surfaceWidth);
      const height: number = this.validSurfaceDimension(rect.surfaceHeight);
      if (width > 0 && height > 0) {
        this.currentSurfaceWidth = width;
        this.currentSurfaceHeight = height;
      }
    } catch (_e) {
      // SurfaceRect can be unavailable between node creation and first layout.
    }
  }

  private hasSurfaceRect(): boolean {
    return this.currentSurfaceWidth > 0 && this.currentSurfaceHeight > 0;
  }

  private surfaceInfo(): RemoteSessionPipSurface {
    return {
      surfaceId: this.currentSurfaceId,
      surfaceWidth: this.currentSurfaceWidth,
      surfaceHeight: this.currentSurfaceHeight
    };
  }

  private publishSurfaceInfo(): void {
    if (!this.hasSurfaceRect() || this.currentSurfaceId.length === 0 ||
      (this.currentSurfaceId === this.publishedSurfaceId &&
       this.currentSurfaceWidth === this.publishedSurfaceWidth &&
       this.currentSurfaceHeight === this.publishedSurfaceHeight)) {
      return;
    }
    this.publishedSurfaceId = this.currentSurfaceId;
    this.publishedSurfaceWidth = this.currentSurfaceWidth;
    this.publishedSurfaceHeight = this.currentSurfaceHeight;
    const handler: PipSurfaceChangedHandler | null = this.surfaceChangedHandler;
    if (handler !== null) {
      handler(this.surfaceInfo());
    }
  }
}

export class RemoteSessionPipService {
  private static instance: RemoteSessionPipService | null = null;
  private controller: PiPWindow.PiPController | null = null;
  private contentNode: typeNode.XComponent | null = null;
  private pipComponentController: RemoteSessionPipXComponentController | null = null;
  private prepared: boolean = false;
  private active: boolean = false;
  private windowStarted: boolean = false;
  private contentWidth: number = 1920;
  private contentHeight: number = 1080;
  private lastState: PiPWindow.PiPState | null = null;
  /** Invalidates every in-flight create/wait when stop() is requested. */
  private operationGeneration: number = 0;
  private stoppedHandler: ((reason: string) => void) | null = null;
  private surfaceChangedHandler: PipSurfaceChangedHandler | null = null;
  private stateCallback: PipStateHandler | null = null;
  private stopInFlight: Promise<void> | null = null;

  static getInstance(): RemoteSessionPipService {
    if (RemoteSessionPipService.instance === null) {
      RemoteSessionPipService.instance = new RemoteSessionPipService();
    }
    return RemoteSessionPipService.instance;
  }

  /**
   * Prepare a VIDEO_PLAY controller while the main window is still shown.
   * Calling setAutoStartEnabled from the background callback is too late:
   * WMS rejects an explicit start after the main window is hidden.
   */
  async prepare(context: common.UIAbilityContext, uiContext: UIContext,
    contentWidth: number, contentHeight: number,
    onStopped: ((reason: string) => void) | null = null,
    onSurfaceChanged: PipSurfaceChangedHandler | null = null): Promise<boolean> {
    if (!PiPWindow.isPiPEnabled()) {
      hilog.info(DOMAIN, TAG, 'PIP unsupported or disabled by system');
      return false;
    }
    this.stoppedHandler = onStopped;
    this.surfaceChangedHandler = onSurfaceChanged;
    if (this.prepared && this.controller !== null) {
      this.updateContentSize(contentWidth, contentHeight);
      if (this.pipComponentController !== null) {
        this.pipComponentController.setSurfaceChangedHandler(onSurfaceChanged);
      }
      return true;
    }
    if (this.controller !== null) {
      await this.stop();
      this.stoppedHandler = onStopped;
    }

    const generation: number = this.operationGeneration;
    let created: PiPWindow.PiPController | null = null;
    let createdNode: typeNode.XComponent | null = null;
    let callback: PipStateHandler | null = null;
    try {
      const width: number = Math.max(1, Math.round(contentWidth));
      const height: number = Math.max(1, Math.round(contentHeight));
      this.contentWidth = width;
      this.contentHeight = height;
      const pipController: RemoteSessionPipXComponentController =
        new RemoteSessionPipXComponentController();
      pipController.setSurfaceChangedHandler(onSurfaceChanged);
      const config: PiPWindow.PiPConfiguration = {
        context: context,
        componentController: pipController,
        templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY,
        contentWidth: width,
        contentHeight: height,
        defaultWindowSizeType: 1,
        cornerAdsorptionEnabled: true
      };
      createdNode = typeNode.createNode(uiContext, 'XComponent', {
        type: XComponentType.SURFACE,
        controller: pipController
      });
      created = await PiPWindow.create(config, createdNode);
      if (generation !== this.operationGeneration) {
        await this.disposeCreatedController(created, createdNode, null);
        return false;
      }

      this.controller = created;
      this.contentNode = createdNode;
      this.pipComponentController = pipController;
      callback = (state: PiPWindow.PiPState, reason: string): void => {
        this.handleStateChange(created as PiPWindow.PiPController, state, reason);
      };
      this.stateCallback = callback;
      created.on('stateChange', callback);
      // Arm this while the foreground main window is valid. The system will
      // create the PIP window on the next Home/background transition.
      created.setAutoStartEnabled(true);
      if (generation !== this.operationGeneration) {
        await this.stop();
        return false;
      }
      this.prepared = true;
      this.active = false;
      this.windowStarted = false;
      this.lastState = null;
      hilog.info(DOMAIN, TAG, 'PIP VIDEO_PLAY prepared for system autoStart size=' +
        width.toString() + 'x' + height.toString());
      return true;
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '[PIP-PREPARE] failed code=' + this.errorCode(be) +
        ' message=' + this.errorMessage(be));
      if (created !== null) {
        await this.disposeCreatedController(created, createdNode, callback);
      } else if (createdNode !== null) {
        try {
          createdNode.dispose();
        } catch (_e) {
          // Best-effort node cleanup.
        }
      }
      this.clearState();
      return false;
    }
  }

  /**
   * Wait for the system-created PIP surface after the app enters background.
   * This method never calls startPiP(): doing so after the main window is
   * hidden is rejected by WMS with 1300013 and leaves auto-start armed.
   */
  async start(context: common.UIAbilityContext, uiContext: UIContext,
    contentWidth: number, contentHeight: number,
    onSurfaceReady: PipSurfaceReadyHandler | null = null,
    onStopped: ((reason: string) => void) | null = null,
    onSurfaceChanged: PipSurfaceChangedHandler | null = null): Promise<boolean> {
    if (!PiPWindow.isPiPEnabled()) {
      hilog.info(DOMAIN, TAG, 'PIP unsupported or disabled by system');
      return false;
    }
    this.stoppedHandler = onStopped;
    this.surfaceChangedHandler = onSurfaceChanged;
    if (!this.prepared || this.controller === null || this.pipComponentController === null) {
      const preparedOk: boolean = await this.prepare(
        context, uiContext, contentWidth, contentHeight, onStopped, onSurfaceChanged);
      if (!preparedOk) {
        return false;
      }
    }

    const generation: number = this.operationGeneration;
    const owner: PiPWindow.PiPController | null = this.controller;
    const pipController: RemoteSessionPipXComponentController | null = this.pipComponentController;
    if (owner === null || pipController === null || !this.prepared) {
      return false;
    }
    pipController.setSurfaceChangedHandler(onSurfaceChanged);
    this.updateContentSize(contentWidth, contentHeight);

    try {
      hilog.info(DOMAIN, TAG, 'PIP waiting for system autoStart after background transition');
      const surface: RemoteSessionPipSurface | null = await pipController.waitForSurface(4000);
      if (generation !== this.operationGeneration || this.controller !== owner || !this.prepared) {
        return false;
      }
      if (surface === null || surface.surfaceId.length === 0 ||
        surface.surfaceWidth <= 0 || surface.surfaceHeight <= 0) {
        throw new Error('PIP XComponent surface was not created by system autoStart');
      }
      if (onSurfaceReady !== null && !(await onSurfaceReady(surface))) {
        throw new Error('native renderer could not attach to PIP surface');
      }
      if (generation !== this.operationGeneration || this.controller !== owner || !this.prepared) {
        return false;
      }
      this.active = true;
      this.windowStarted = true;
      hilog.info(DOMAIN, TAG, 'PIP VIDEO_PLAY autoStart attached size=' +
        Math.max(1, Math.round(contentWidth)).toString() + 'x' +
        Math.max(1, Math.round(contentHeight)).toString() +
        ' surface=' + surface.surfaceWidth.toString() + 'x' +
        surface.surfaceHeight.toString());
      return this.isActive();
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '[PIP-AUTOSTART] failed code=' + this.errorCode(be) +
        ' message=' + this.errorMessage(be));
      await this.stop();
      return false;
    }
  }

  async stop(): Promise<void> {
    if (this.stopInFlight !== null) {
      await this.stopInFlight;
      return;
    }
    const operation: Promise<void> = this.stopInternal();
    this.stopInFlight = operation;
    try {
      await operation;
    } finally {
      if (this.stopInFlight === operation) {
        this.stopInFlight = null;
      }
    }
  }

  updateContentSize(width: number, height: number): void {
    this.contentWidth = Math.max(1, Math.round(width));
    this.contentHeight = Math.max(1, Math.round(height));
    if (this.controller === null) {
      return;
    }
    try {
      this.controller.updateContentSize(this.contentWidth, this.contentHeight);
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '[PIP-RESIZE] failed code=' + this.errorCode(be) +
        ' message=' + this.errorMessage(be));
    }
  }

  isActive(): boolean {
    return this.active && this.controller !== null;
  }

  private handleStateChange(owner: PiPWindow.PiPController,
    state: PiPWindow.PiPState, reason: string): void {
    hilog.info(DOMAIN, TAG, 'PIP state=' + state.toString() + ' reason=' + reason);
    if (this.controller !== owner) {
      return;
    }
    this.lastState = state;
    if (state === PiPWindow.PiPState.STARTED) {
      this.active = true;
      this.windowStarted = true;
      return;
    }
    if (state === PiPWindow.PiPState.ABOUT_TO_START) {
      this.active = false;
      return;
    }
    if (state === PiPWindow.PiPState.ABOUT_TO_STOP ||
      state === PiPWindow.PiPState.ABOUT_TO_RESTORE) {
      this.active = false;
      return;
    }
    if (state === PiPWindow.PiPState.STOPPED || state === PiPWindow.PiPState.ERROR) {
      this.cleanupController(owner, reason, true);
    }
  }

  private async stopInternal(): Promise<void> {
    this.operationGeneration++;
    const current: PiPWindow.PiPController | null = this.controller;
    if (current === null) {
      this.clearState();
      return;
    }

    // Explicit teardown owns cleanup. A system state callback for this stop
    // must not call the page's background fallback a second time.
    this.stoppedHandler = null;
    try {
      // Revoke pending home-gesture auto-start before any await.
      current.setAutoStartEnabled(false);
      hilog.info(DOMAIN, TAG, 'PIP autoStart disabled');
    } catch (_e) {
      // Continue with controller cleanup.
    }

    const state: PiPWindow.PiPState | null = this.lastState;
    // A controller which has not reached STARTED has no visible PIP window.
    // Calling stopPiP() in this state can produce a late exit animation during
    // app shutdown or while an auto-start transition is being cancelled.
    if (!this.windowStarted) {
      this.cleanupController(current, 'requestDelete', false);
      return;
    }
    if (state === PiPWindow.PiPState.STOPPED || state === PiPWindow.PiPState.ERROR) {
      this.cleanupController(current, 'requestDelete', false);
      return;
    }

    // ABOUT_TO_STOP and ABOUT_TO_RESTORE mean WMS already owns the transition.
    // Calling stopPiP again is explicitly documented as a repeated operation.
    if (state === PiPWindow.PiPState.ABOUT_TO_STOP ||
      state === PiPWindow.PiPState.ABOUT_TO_RESTORE) {
      await this.waitForTerminalState(current, 1200);
      if (this.controller === current) {
        this.cleanupController(current, 'requestDelete', false);
      }
      return;
    }

    try {
      await current.stopPiP();
      hilog.info(DOMAIN, TAG, 'PIP stopped');
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '[PIP-STOP] failed code=' + this.errorCode(be) +
        ' message=' + this.errorMessage(be));
    }
    if (this.controller === current &&
      (this.lastState === PiPWindow.PiPState.ABOUT_TO_STOP ||
       this.lastState === PiPWindow.PiPState.ABOUT_TO_RESTORE)) {
      await this.waitForTerminalState(current, 1200);
    }
    if (this.controller === current) {
      this.cleanupController(current, 'requestDelete', false);
    }
  }

  private async waitForTerminalState(owner: PiPWindow.PiPController,
    timeoutMs: number): Promise<void> {
    const startedAtMs: number = Date.now();
    while (this.controller === owner &&
      this.lastState !== PiPWindow.PiPState.STOPPED &&
      this.lastState !== PiPWindow.PiPState.ERROR &&
      Date.now() - startedAtMs < timeoutMs) {
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 40);
      });
    }
  }

  private cleanupController(owner: PiPWindow.PiPController,
    reason: string, notifyStopped: boolean): void {
    if (this.controller !== owner) {
      return;
    }
    const currentNode: typeNode.XComponent | null = this.contentNode;
    const currentComponent: RemoteSessionPipXComponentController | null = this.pipComponentController;
    const handler: ((reason: string) => void) | null = notifyStopped ? this.stoppedHandler : null;
    if (currentComponent !== null) {
      currentComponent.setSurfaceChangedHandler(null);
    }
    this.clearState();
    try {
      owner.setAutoStartEnabled(false);
    } catch (_e) {
      // The system may already have destroyed the controller.
    }
    try {
      owner.off('stateChange');
    } catch (_e) {
      // Listener cleanup is best effort.
    }
    if (handler !== null) {
      handler(reason);
    }
    if (currentNode !== null) {
      try {
        currentNode.dispose();
      } catch (_e) {
        // Node disposal is best effort.
      }
    }
  }

  private clearState(): void {
    this.stoppedHandler = null;
    this.surfaceChangedHandler = null;
    this.controller = null;
    this.contentNode = null;
    this.pipComponentController = null;
    this.prepared = false;
    this.active = false;
    this.windowStarted = false;
    this.lastState = null;
    this.stateCallback = null;
  }

  private async disposeCreatedController(controller: PiPWindow.PiPController,
    node: typeNode.XComponent | null,
    callback: PipStateHandler | null): Promise<void> {
    try {
      if (callback !== null) {
        controller.off('stateChange');
      }
    } catch (_e) {
      // Best-effort listener cleanup.
    }
    try {
      controller.setAutoStartEnabled(false);
    } catch (_e) {
      // Best-effort auto-start cancellation.
    }
    if (node !== null) {
      try {
        node.dispose();
      } catch (_e) {
        // Best-effort node cleanup.
      }
    }
  }

  private errorCode(error: BusinessError): string {
    return error.code === undefined ? 'unknown' : error.code.toString();
  }

  private errorMessage(error: BusinessError): string {
    return error.message === undefined ? JSON.stringify(error) : error.message;
  }
}
