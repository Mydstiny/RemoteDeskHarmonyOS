/**
 * RemoteSessionPipService — real remote-frame PIP output.
 *
 * AVSession supplies the system media identity and controls; PiPWindow owns
 * the actual XComponent surface shown in the floating video window. The
 * The controller is prepared while the main window is visible and the system
 * performs the background auto-start transition.
 */
import { common } from '@kit.AbilityKit';
import { PiPWindow, typeNode, UIContext } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  RemoteSessionServiceLease,
  RemoteSessionServiceProtocol,
  cloneRemoteSessionServiceLease,
  remoteSessionServiceLeaseCanClaim,
  remoteSessionServiceLeaseEquals,
  remoteSessionServiceLeaseIsValid,
  remoteSessionServiceLeaseMatchesSession
} from './RemoteSessionServiceLeasePolicy';

const TAG = 'RemoteSessionPip';
const DOMAIN = 0x0015;
const PIP_TERMINAL_STATE_TIMEOUT_MS = 5000;
const PIP_SURFACE_WAIT_TIMEOUT_MS = 6000;

export interface RemoteSessionPipSurface {
  surfaceId: string;
  surfaceWidth: number;
  surfaceHeight: number;
}

/** Exact ArkUI page/navigation owner to restore when the user expands PIP. */
export interface RemoteSessionPipRestoreTarget {
  navigationId?: string;
  handleId?: number;
}

type PipSurfaceReadyHandler = (surface: RemoteSessionPipSurface,
  operationGeneration: number) => Promise<boolean>;
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
    // API 23 may invoke this override through an XComponent callback proxy
    // that carries the fields but not subclass helper methods. Keep the
    // framework callback self-contained; the real controller instance does
    // the full reconciliation after the renderer is attached.
    if (width > 0 && height > 0 &&
      (this.currentSurfaceId !== this.publishedSurfaceId ||
       width !== this.publishedSurfaceWidth || height !== this.publishedSurfaceHeight)) {
      this.publishedSurfaceId = this.currentSurfaceId;
      this.publishedSurfaceWidth = width;
      this.publishedSurfaceHeight = height;
      const handler: PipSurfaceChangedHandler | null = this.surfaceChangedHandler;
      if (handler !== null && typeof handler === 'function') {
        handler({
          surfaceId: this.currentSurfaceId,
          surfaceWidth: width,
          surfaceHeight: height
        });
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
          this.publishSurfaceInfo();
          return this.surfaceInfo();
        }
      }
      try {
        const surfaceId: string = this.getXComponentSurfaceId();
        if (surfaceId.length > 0) {
          this.currentSurfaceId = surfaceId;
          this.refreshSurfaceRect();
          if (this.hasSurfaceRect()) {
            this.publishSurfaceInfo();
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
    if (handler !== null && typeof handler === 'function') {
      handler(this.surfaceInfo());
    }
  }

  /**
   * Reconcile the dimensions after the native renderer has moved to this
   * surface. WMS may publish a placeholder physical size before the final
   * PIP window layout; that callback can otherwise be consumed while the page
   * renderer is still the owner and never reach the PIP renderer.
   */
  notifyCurrentSurface(): void {
    this.refreshSurfaceRect();
    if (!this.hasSurfaceRect() || this.currentSurfaceId.length === 0) {
      return;
    }
    this.publishedSurfaceId = this.currentSurfaceId;
    this.publishedSurfaceWidth = this.currentSurfaceWidth;
    this.publishedSurfaceHeight = this.currentSurfaceHeight;
    const handler: PipSurfaceChangedHandler | null = this.surfaceChangedHandler;
    if (handler !== null && typeof handler === 'function') {
      handler(this.surfaceInfo());
    }
    hilog.info(DOMAIN, TAG, 'PIP XComponent final surface reconciliation id=' +
      this.currentSurfaceId + ' surface=' + this.currentSurfaceWidth.toString() + 'x' +
      this.currentSurfaceHeight.toString());
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
  /** All WMS-facing operations must run in one order. */
  private operationTail: Promise<void> = Promise.resolve();
  /** Includes a prepare queued behind another PIP operation. */
  private prepareRequestCount: number = 0;
  private currentLease: RemoteSessionServiceLease | null = null;

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
    lease: RemoteSessionServiceLease,
    onStopped: ((reason: string) => void) | null = null,
    onSurfaceChanged: PipSurfaceChangedHandler | null = null,
    restoreTarget: RemoteSessionPipRestoreTarget | null = null): Promise<boolean> {
    if (!this.claimLease(lease)) {
      hilog.warn(DOMAIN, TAG, '[PIP-LEASE] prepare rejected for non-owner');
      return false;
    }
    const captured: RemoteSessionServiceLease = cloneRemoteSessionServiceLease(lease);
    this.prepareRequestCount += 1;
    return this.enqueueOperation<boolean>(async (): Promise<boolean> => {
      try {
        if (!remoteSessionServiceLeaseEquals(this.currentLease, captured)) { return false; }
        return await this.prepareInternal(
          context, uiContext, contentWidth, contentHeight, captured,
          onStopped, onSurfaceChanged, restoreTarget);
      } finally {
        this.prepareRequestCount = Math.max(0, this.prepareRequestCount - 1);
      }
    });
  }

  private async prepareInternal(context: common.UIAbilityContext, uiContext: UIContext,
    contentWidth: number, contentHeight: number,
    lease: RemoteSessionServiceLease,
    onStopped: ((reason: string) => void) | null,
    onSurfaceChanged: PipSurfaceChangedHandler | null,
    restoreTarget: RemoteSessionPipRestoreTarget | null): Promise<boolean> {
    if (!remoteSessionServiceLeaseEquals(this.currentLease, lease)) { return false; }
    if (!PiPWindow.isPiPEnabled()) {
      hilog.info(DOMAIN, TAG, 'PIP unsupported or disabled by system');
      await this.stopInternal();
      return false;
    }
    this.stoppedHandler = onStopped;
    this.surfaceChangedHandler = onSurfaceChanged;
    if (this.prepared && this.controller !== null) {
      this.updateContentSize(contentWidth, contentHeight, lease);
      if (this.pipComponentController !== null) {
        this.pipComponentController.setSurfaceChangedHandler(onSurfaceChanged);
      }
      return true;
    }
    if (this.controller !== null) {
      const stopped: boolean = await this.stopInternal();
      if (!stopped) {
        hilog.warn(DOMAIN, TAG, '[PIP-PREPARE] previous controller did not reach terminal state');
        return false;
      }
      this.currentLease = cloneRemoteSessionServiceLease(lease);
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
      if (restoreTarget !== null) {
        if (typeof restoreTarget.navigationId === 'string' &&
            restoreTarget.navigationId.trim() !== '') {
          config.navigationId = restoreTarget.navigationId.trim();
        }
        const handleId: number | undefined = restoreTarget.handleId;
        if (typeof handleId === 'number' && Number.isSafeInteger(handleId) &&
            handleId > 0) {
          config.handleId = handleId;
        }
      }
      createdNode = typeNode.createNode(uiContext, 'XComponent', {
        type: XComponentType.SURFACE,
        controller: pipController
      });
      created = await PiPWindow.create(config, createdNode);
      if (generation !== this.operationGeneration ||
          !remoteSessionServiceLeaseEquals(this.currentLease, lease)) {
        await this.disposeCreatedController(created, createdNode, null);
        return false;
      }

      this.controller = created;
      this.contentNode = createdNode;
      this.pipComponentController = pipController;
      this.prepared = true;
      this.active = false;
      this.windowStarted = false;
      this.lastState = null;
      callback = (state: PiPWindow.PiPState, reason: string): void => {
        this.handleStateChange(created as PiPWindow.PiPController, lease, state, reason);
      };
      this.stateCallback = callback;
      created.on('stateChange', callback);
      // Arm this while the foreground main window is valid. The system will
      // create the PIP window on the next Home/background transition.
      created.setAutoStartEnabled(true);
      if (generation !== this.operationGeneration ||
          !remoteSessionServiceLeaseEquals(this.currentLease, lease)) {
        if (this.controller === created) {
          await this.stopInternal();
        }
        return false;
      }
      if (this.controller !== created || !this.prepared ||
          !remoteSessionServiceLeaseEquals(this.currentLease, lease)) {
        return false;
      }
      hilog.info(DOMAIN, TAG, 'PIP VIDEO_PLAY prepared for system autoStart size=' +
        width.toString() + 'x' + height.toString());
      return true;
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '[PIP-PREPARE] failed code=' + this.errorCode(be) +
        ' message=' + this.errorMessage(be));
      if (created !== null && this.controller === created) {
        await this.stopInternal();
      } else if (created !== null) {
        await this.disposeCreatedController(created, createdNode, callback);
      } else if (createdNode !== null) {
        try {
          createdNode.dispose();
        } catch (_e) {
          // Best-effort node cleanup.
        }
      }
      if (remoteSessionServiceLeaseEquals(this.currentLease, lease)) {
        this.clearState();
      }
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
    lease: RemoteSessionServiceLease,
    onSurfaceReady: PipSurfaceReadyHandler | null = null,
    onStopped: ((reason: string) => void) | null = null,
    onSurfaceChanged: PipSurfaceChangedHandler | null = null): Promise<boolean> {
    if (!remoteSessionServiceLeaseIsValid(lease)) { return false; }
    const captured: RemoteSessionServiceLease = cloneRemoteSessionServiceLease(lease);
    return this.enqueueOperation<boolean>(() => this.startInternal(
      context, uiContext, contentWidth, contentHeight,
      captured, onSurfaceReady, onStopped, onSurfaceChanged));
  }

  private async startInternal(context: common.UIAbilityContext, uiContext: UIContext,
    contentWidth: number, contentHeight: number,
    lease: RemoteSessionServiceLease,
    onSurfaceReady: PipSurfaceReadyHandler | null,
    onStopped: ((reason: string) => void) | null,
    onSurfaceChanged: PipSurfaceChangedHandler | null): Promise<boolean> {
    if (!remoteSessionServiceLeaseEquals(this.currentLease, lease)) {
      hilog.warn(DOMAIN, TAG, '[PIP-LEASE] start rejected for non-owner');
      return false;
    }
    if (!PiPWindow.isPiPEnabled()) {
      hilog.info(DOMAIN, TAG, 'PIP unsupported or disabled by system');
      await this.stopInternal();
      return false;
    }
    this.stoppedHandler = onStopped;
    this.surfaceChangedHandler = onSurfaceChanged;
    // A background call may be queued immediately after the foreground
    // prepare request. The queue lets that prepare finish, but start must
    // never create a new controller after the main window is hidden.
    if (!this.prepared || this.controller === null || this.pipComponentController === null) {
      hilog.warn(DOMAIN, TAG, '[PIP-AUTOSTART] no foreground-prepared controller');
      return false;
    }
    const generation: number = this.operationGeneration;
    const owner: PiPWindow.PiPController | null = this.controller;
    const pipController: RemoteSessionPipXComponentController | null = this.pipComponentController;
    if (owner === null || pipController === null || !this.prepared) {
      return false;
    }
    pipController.setSurfaceChangedHandler(onSurfaceChanged);
    this.updateContentSize(contentWidth, contentHeight, lease);

    try {
      hilog.info(DOMAIN, TAG, 'PIP waiting for system autoStart after background transition');
      const surface: RemoteSessionPipSurface | null = await pipController.waitForSurface(
        PIP_SURFACE_WAIT_TIMEOUT_MS);
      if (generation !== this.operationGeneration || this.controller !== owner || !this.prepared ||
          !remoteSessionServiceLeaseEquals(this.currentLease, lease)) {
        return false;
      }
      if (surface === null || surface.surfaceId.length === 0 ||
        surface.surfaceWidth <= 0 || surface.surfaceHeight <= 0) {
        throw new Error('PIP XComponent surface was not created by system autoStart');
      }
      if (onSurfaceReady !== null && !(await onSurfaceReady(surface, generation))) {
        throw new Error('native renderer could not attach to PIP surface');
      }
      if (generation !== this.operationGeneration || this.controller !== owner || !this.prepared ||
          !remoteSessionServiceLeaseEquals(this.currentLease, lease)) {
        return false;
      }
      // The first SurfaceRect can be the full-display placeholder. Re-read
      // after renderer attach so the real PIP window size is not lost in the
      // handoff race.
      pipController.notifyCurrentSurface();
      this.active = true;
      this.windowStarted = true;
      hilog.info(DOMAIN, TAG, 'PIP VIDEO_PLAY autoStart attached size=' +
        Math.max(1, Math.round(contentWidth)).toString() + 'x' +
        Math.max(1, Math.round(contentHeight)).toString() +
        ' surface=' + surface.surfaceWidth.toString() + 'x' +
        surface.surfaceHeight.toString());
      return this.isActive(lease);
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '[PIP-AUTOSTART] failed code=' + this.errorCode(be) +
        ' message=' + this.errorMessage(be));
      const stopped: boolean = await this.stopInternal();
      if (!stopped) {
        hilog.warn(DOMAIN, TAG, '[PIP-AUTOSTART] controller teardown is still pending');
      }
      return false;
    }
  }

  /**
   * Stop the controller without destroying its node while WMS is still in a
   * transitional state. The caller may release the native renderer only after
   * this promise returns true; false means the controller is still owned by
   * the system and its state callback remains responsible for final cleanup.
   */
  async stop(lease?: RemoteSessionServiceLease): Promise<boolean> {
    const captured: RemoteSessionServiceLease | null = lease === undefined ? null :
      cloneRemoteSessionServiceLease(lease);
    if (captured !== null && !remoteSessionServiceLeaseEquals(this.currentLease, captured)) {
      return true;
    }
    // Invalidate create/surface waits immediately; the serialized teardown
    // below may be queued behind the operation that is currently awaiting WMS.
    this.operationGeneration += 1;
    return this.enqueueOperation<boolean>(() => {
      if (captured !== null &&
          !remoteSessionServiceLeaseEquals(this.currentLease, captured)) { return Promise.resolve(true); }
      return this.stopInternal();
    });
  }

  /** Snapshot the exact predecessor owner for a registry restore CAS. */
  leaseForMatchingSession(protocol: RemoteSessionServiceProtocol,
    hostId: string, sessionId: number): RemoteSessionServiceLease | null {
    if (!remoteSessionServiceLeaseMatchesSession(
        this.currentLease, protocol, hostId, sessionId)) {
      return null;
    }
    return cloneRemoteSessionServiceLease(
      this.currentLease as RemoteSessionServiceLease);
  }

  updateContentSize(width: number, height: number,
    lease: RemoteSessionServiceLease): void {
    if (!remoteSessionServiceLeaseEquals(this.currentLease, lease)) { return; }
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

  isActive(lease: RemoteSessionServiceLease): boolean {
    return this.active && this.controller !== null &&
      remoteSessionServiceLeaseEquals(this.currentLease, lease);
  }

  /** True while a foreground-prepared controller is armed for auto-start. */
  isPrepared(lease: RemoteSessionServiceLease): boolean {
    return this.prepared && this.controller !== null &&
      remoteSessionServiceLeaseEquals(this.currentLease, lease);
  }

  /** True when prepare is already armed or queued from the foreground. */
  isPreparedOrPreparing(lease: RemoteSessionServiceLease): boolean {
    if (!remoteSessionServiceLeaseEquals(this.currentLease, lease)) { return false; }
    return this.isPrepared(lease) || this.prepareRequestCount > 0;
  }

  /**
   * A surface attach can await a decoded frame while stop/restore is already
   * revoking the controller. Page code must reject the stale callback before
   * it moves a native renderer to the free-node surface.
   */
  isOperationCurrent(operationGeneration: number,
    lease: RemoteSessionServiceLease): boolean {
    return operationGeneration === this.operationGeneration &&
      this.prepared && this.controller !== null &&
      remoteSessionServiceLeaseEquals(this.currentLease, lease);
  }

  private handleStateChange(owner: PiPWindow.PiPController,
    lease: RemoteSessionServiceLease,
    state: PiPWindow.PiPState, reason: string): void {
    hilog.info(DOMAIN, TAG, 'PIP state=' + state.toString() + ' reason=' + reason);
    if (this.controller !== owner ||
        !remoteSessionServiceLeaseEquals(this.currentLease, lease)) {
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

  private async stopInternal(): Promise<boolean> {
    this.operationGeneration++;
    const current: PiPWindow.PiPController | null = this.controller;
    if (current === null) {
      this.clearState();
      return true;
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
    // A controller which has not emitted a lifecycle transition has no visible
    // PIP window. Dispose it directly so a no-session app exit cannot animate
    // an empty PIP window. ABOUT_TO_START is different: WMS already owns the
    // transition, so disposing the node here races the system and can leave a
    // late window/renderer callback behind.
    if (state === null && !this.windowStarted) {
      this.cleanupController(current, 'requestDelete', false);
      return true;
    }
    if (this.isTerminalState(state)) {
      this.cleanupController(current, 'requestDelete', false);
      return true;
    }

    // Every ABOUT_TO_* state means WMS already owns the transition. Wait for a
    // terminal callback before disposing the node or allowing native teardown.
    // ABOUT_TO_START is allowed to settle to STARTED first; the helper then
    // sends the single stopPiP request. The stop/restore transitions are only
    // observed until WMS emits their terminal callback.
    if (state === PiPWindow.PiPState.ABOUT_TO_START) {
      const terminal: boolean = await this.finishAutoStartTransition(
        current, PIP_TERMINAL_STATE_TIMEOUT_MS);
      if (!terminal) {
        hilog.error(DOMAIN, TAG, '[PIP-STOP] autoStart transition did not reach terminal state');
        return false;
      }
      if (this.controller === current) {
        this.cleanupController(current, 'requestDelete', false);
      }
      return true;
    }
    if (state === PiPWindow.PiPState.ABOUT_TO_STOP ||
      state === PiPWindow.PiPState.ABOUT_TO_RESTORE) {
      const terminal: boolean = await this.waitForTerminalState(
        current, PIP_TERMINAL_STATE_TIMEOUT_MS);
      if (!terminal) {
        hilog.error(DOMAIN, TAG, '[PIP-STOP] terminal state timeout state=' +
          (this.lastState === null ? 'null' : this.lastState.toString()));
        return false;
      }
      if (this.controller === current) {
        this.cleanupController(current, 'requestDelete', false);
      }
      return true;
    }

    try {
      await current.stopPiP();
      hilog.info(DOMAIN, TAG, 'PIP stopped');
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '[PIP-STOP] failed code=' + this.errorCode(be) +
        ' message=' + this.errorMessage(be));
      return false;
    }
    if (this.controller !== current) {
      return true;
    }
    const terminal: boolean = await this.waitForTerminalState(
      current, PIP_TERMINAL_STATE_TIMEOUT_MS);
    if (!terminal) {
      hilog.error(DOMAIN, TAG, '[PIP-STOP] terminal state timeout after stopPiP state=' +
        (this.lastState === null ? 'null' : this.lastState.toString()));
      return false;
    }
    if (this.controller === current) {
      this.cleanupController(current, 'requestDelete', false);
    }
    return true;
  }

  private async waitForTerminalState(owner: PiPWindow.PiPController,
    timeoutMs: number): Promise<boolean> {
    const startedAtMs: number = Date.now();
    while (this.controller === owner &&
      this.lastState !== PiPWindow.PiPState.STOPPED &&
      this.lastState !== PiPWindow.PiPState.ERROR &&
      Date.now() - startedAtMs < timeoutMs) {
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 40);
      });
    }
    return this.controller !== owner || this.isTerminalState(this.lastState);
  }

  /**
   * ABOUT_TO_START normally becomes STARTED, not STOPPED. If teardown arrives
   * during that transition, wait for STARTED and then issue the one legal
   * stopPiP request; waiting for a terminal state without that request would
   * leave auto-start armed until the timeout.
   */
  private async finishAutoStartTransition(owner: PiPWindow.PiPController,
    timeoutMs: number): Promise<boolean> {
    const startedAtMs: number = Date.now();
    while (this.controller === owner &&
      this.lastState === PiPWindow.PiPState.ABOUT_TO_START &&
      Date.now() - startedAtMs < timeoutMs) {
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 40);
      });
    }
    if (this.controller !== owner || this.isTerminalState(this.lastState)) {
      return true;
    }
    if (this.lastState !== PiPWindow.PiPState.STARTED) {
      return false;
    }
    try {
      await owner.stopPiP();
      hilog.info(DOMAIN, TAG, 'PIP stopped after autoStart transition');
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '[PIP-STOP] autoStart transition stop failed code=' +
        this.errorCode(be) + ' message=' + this.errorMessage(be));
      return false;
    }
    if (this.controller !== owner) {
      return true;
    }
    const remainingMs: number = Math.max(1, timeoutMs - (Date.now() - startedAtMs));
    return this.waitForTerminalState(owner, remainingMs);
  }

  private isTerminalState(state: PiPWindow.PiPState | null): boolean {
    return state === PiPWindow.PiPState.STOPPED || state === PiPWindow.PiPState.ERROR;
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
    this.currentLease = null;
  }

  private claimLease(lease: RemoteSessionServiceLease): boolean {
    if (!remoteSessionServiceLeaseCanClaim(this.currentLease, lease)) { return false; }
    if (this.currentLease === null) {
      this.currentLease = cloneRemoteSessionServiceLease(lease);
    }
    return true;
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

  private enqueueOperation<T>(operation: () => Promise<T>): Promise<T> {
    const queued: Promise<T> = this.operationTail.then(
      (): Promise<T> => operation(),
      (): Promise<T> => operation());
    this.operationTail = queued.then(
      (): void => { return; },
      (): void => { return; });
    return queued;
  }
}
