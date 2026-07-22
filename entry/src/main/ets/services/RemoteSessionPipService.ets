/**
 * RemoteSessionPipService — real remote-frame PIP output.
 *
 * AVSession supplies the system media identity and controls; PiPWindow owns
 * the actual XComponent surface shown in the floating video window. The
 * caller moves the native renderer to that surface before start() succeeds.
 */
import { common } from '@kit.AbilityKit';
import { PiPWindow, typeNode, UIContext } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'RemoteSessionPip';
const DOMAIN = 0x0015;

type PipSurfaceReadyHandler = (surfaceId: string) => Promise<boolean>;

/**
 * The PIP free-node needs its own XComponentController.  Reusing the page
 * controller leaves the native renderer bound to the page surface, which
 * produces a valid-looking but frozen PIP window after the page moves to the
 * background.
 */
class RemoteSessionPipXComponentController extends XComponentController {
  private currentSurfaceId: string = '';

  onSurfaceCreated(surfaceId: string): void {
    this.currentSurfaceId = surfaceId;
    hilog.info(DOMAIN, TAG, 'PIP XComponent surface created id=' + surfaceId);
  }

  onSurfaceDestroyed(surfaceId: string): void {
    if (this.currentSurfaceId === surfaceId) {
      this.currentSurfaceId = '';
    }
    hilog.info(DOMAIN, TAG, 'PIP XComponent surface destroyed id=' + surfaceId);
  }

  async waitForSurface(timeoutMs: number): Promise<string> {
    const startedAtMs: number = Date.now();
    while (Date.now() - startedAtMs < timeoutMs) {
      if (this.currentSurfaceId.length > 0) {
        return this.currentSurfaceId;
      }
      try {
        const surfaceId: string = this.getXComponentSurfaceId();
        if (surfaceId.length > 0) {
          this.currentSurfaceId = surfaceId;
          return surfaceId;
        }
      } catch (_e) {
        // The free node may not have been mounted yet; keep polling briefly.
      }
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 50);
      });
    }
    return '';
  }
}

export class RemoteSessionPipService {
  private static instance: RemoteSessionPipService | null = null;
  private controller: PiPWindow.PiPController | null = null;
  private contentNode: typeNode.XComponent | null = null;
  private pipComponentController: RemoteSessionPipXComponentController | null = null;
  private active: boolean = false;
  private stoppedHandler: ((reason: string) => void) | null = null;
  private stateCallback: ((state: PiPWindow.PiPState, reason: string) => void) =
    (state: PiPWindow.PiPState, reason: string): void => {
      hilog.info(DOMAIN, TAG, 'PIP state=' + state.toString() + ' reason=' + reason);
      if (state === PiPWindow.PiPState.STOPPED || state === PiPWindow.PiPState.ERROR) {
        const handler: ((reason: string) => void) | null = this.stoppedHandler;
        const current: PiPWindow.PiPController | null = this.controller;
        const currentNode: typeNode.XComponent | null = this.contentNode;
        this.stoppedHandler = null;
        this.active = false;
        this.controller = null;
        this.contentNode = null;
        this.pipComponentController = null;
        if (current !== null) {
          try {
            current.off('stateChange');
          } catch (_e) {
            // The controller is already stopping; listener cleanup is best effort.
          }
        }
        if (handler !== null) {
          handler(reason);
        }
        if (currentNode !== null) {
          try {
            currentNode.dispose();
          } catch (_e) {
            // Node disposal is best effort after the system has stopped PIP.
          }
        }
      }
    };

  static getInstance(): RemoteSessionPipService {
    if (RemoteSessionPipService.instance === null) {
      RemoteSessionPipService.instance = new RemoteSessionPipService();
    }
    return RemoteSessionPipService.instance;
  }

  /**
   * Create and start a VIDEO_PLAY PIP using the documented free typeNode path.
   * The PIP node owns a separate surface and the caller moves the native
   * renderer to that surface before this method reports success. Returns false
   * for unsupported devices or any failed lifecycle operation.
   */
  async start(context: common.UIAbilityContext, uiContext: UIContext,
    contentWidth: number, contentHeight: number,
    onSurfaceReady: PipSurfaceReadyHandler | null = null,
    onStopped: ((reason: string) => void) | null = null): Promise<boolean> {
    if (!PiPWindow.isPiPEnabled()) {
      hilog.info(DOMAIN, TAG, 'PIP unsupported or disabled by system');
      return false;
    }
    this.stoppedHandler = onStopped;
    if (this.active && this.controller !== null) {
      return true;
    }
    if (this.controller !== null) {
      await this.stop();
      this.stoppedHandler = onStopped;
    }

    let created: PiPWindow.PiPController | null = null;
    let createdNode: typeNode.XComponent | null = null;
    try {
      const width: number = Math.max(1, Math.round(contentWidth));
      const height: number = Math.max(1, Math.round(contentHeight));
      const pipController: RemoteSessionPipXComponentController =
        new RemoteSessionPipXComponentController();
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
      this.controller = created;
      this.contentNode = createdNode;
      this.pipComponentController = pipController;
      created.on('stateChange', this.stateCallback);
      // Let the system enter PIP on a Home gesture as well as the explicit
      // start below. This keeps the behavior aligned with video players.
      created.setAutoStartEnabled(true);
      this.active = true;
      await created.startPiP();

      const surfaceId: string = await pipController.waitForSurface(2500);
      if (surfaceId.length === 0) {
        throw new Error('PIP XComponent surface was not created');
      }
      if (onSurfaceReady !== null && !(await onSurfaceReady(surfaceId))) {
        throw new Error('native renderer could not attach to PIP surface');
      }
      hilog.info(DOMAIN, TAG, 'PIP VIDEO_PLAY started size=' + width.toString() + 'x' + height.toString());
      return this.isActive();
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '[PIP-START] failed code=' + this.errorCode(be) +
        ' message=' + this.errorMessage(be));
      if (created !== null) {
        try {
          created.off('stateChange');
          await created.stopPiP();
        } catch (_e) {
          // Best-effort cleanup after a failed create/start.
        }
      }
      if (createdNode !== null) {
        try {
          createdNode.dispose();
        } catch (_e) {
          // Best-effort cleanup after a failed create/start.
        }
      }
      this.controller = null;
      this.contentNode = null;
      this.pipComponentController = null;
      this.active = false;
      this.stoppedHandler = null;
      return false;
    }
  }

  async stop(): Promise<void> {
    const current: PiPWindow.PiPController | null = this.controller;
    const currentNode: typeNode.XComponent | null = this.contentNode;
    this.controller = null;
    this.contentNode = null;
    this.pipComponentController = null;
    this.active = false;
    this.stoppedHandler = null;
    if (current === null) {
      return;
    }
    try {
      current.off('stateChange');
    } catch (_e) {
      // Continue with the stop operation.
    }
    try {
      await current.stopPiP();
      hilog.info(DOMAIN, TAG, 'PIP stopped');
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '[PIP-STOP] failed code=' + this.errorCode(be) +
        ' message=' + this.errorMessage(be));
    }
    if (currentNode !== null) {
      try {
        currentNode.dispose();
      } catch (_e) {
        // Best-effort node cleanup after stopping PIP.
      }
    }
  }

  updateContentSize(width: number, height: number): void {
    if (this.controller === null) {
      return;
    }
    try {
      this.controller.updateContentSize(Math.max(1, Math.round(width)), Math.max(1, Math.round(height)));
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '[PIP-RESIZE] failed code=' + this.errorCode(be) +
        ' message=' + this.errorMessage(be));
    }
  }

  isActive(): boolean {
    return this.active && this.controller !== null;
  }

  private errorCode(error: BusinessError): string {
    return error.code === undefined ? 'unknown' : error.code.toString();
  }

  private errorMessage(error: BusinessError): string {
    return error.message === undefined ? JSON.stringify(error) : error.message;
  }
}
