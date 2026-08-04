/**
 * SSH terminal PiP owner.
 *
 * SSH renders through ArkUI Canvas, so it cannot share the video PiP surface
 * owned by RemoteSessionPipService. This PiP deliberately exposes a compact
 * status/output summary through customUIController; the SSH socket remains
 * owned by the native detached session.
 */
import { PiPWindow, BuilderNode, FrameNode, NodeController, UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'SshTerminalPip';
const DOMAIN = 0x0017;
const PIP_STATE_TIMEOUT_MS = 5000;

export interface SshTerminalPipInfo {
  hostLabel: string;
  hostAddress: string;
  status: string;
  outputSummary: string;
}

type SshPipStoppedHandler = (reason: string) => void;

function sanitizeOutputSummary(value: string): string {
  let result: string = value.replace(/[\u0000-\u001F\u007F]/g, ' ')
    .replace(/\s+/g, ' ').trim();
  if (result.length > 96) {
    result = result.substring(result.length - 96);
  }
  return result;
}

@Builder
function SshTerminalPipContent(info: SshTerminalPipInfo): void {
  Column() {
    Row() {
      Text('SSH')
        .fontSize(13)
        .fontColor('#9BE7FF')
        .fontWeight(FontWeight.Bold)
      Blank()
      Text(info.status)
        .fontSize(11)
        .fontColor('#A7F3B1')
        .maxLines(1)
    }
    .width('100%')
    .height(24)

    Text(info.hostLabel.length > 0 ? info.hostLabel : info.hostAddress)
      .width('100%')
      .fontSize(16)
      .fontColor('#FFFFFF')
      .fontWeight(FontWeight.Medium)
      .maxLines(1)

    Text(info.hostAddress)
      .width('100%')
      .fontSize(11)
      .fontColor('#AAB4C0')
      .maxLines(1)

    Divider()
      .color('#34404D')
      .width('100%')
      .margin({ top: 8, bottom: 8 })

    Text(info.outputSummary.length > 0 ? info.outputSummary : 'SSH 会话已保留')
      .width('100%')
      .fontSize(12)
      .fontColor('#D7DEE8')
      .maxLines(2)
  }
  .width('100%')
  .height('100%')
  .padding({ left: 14, right: 14, top: 12, bottom: 12 })
  .backgroundColor('#111820')
}

/** Required PiP component owner; SSH does not attach a video surface. */
class SshTerminalPipComponentController extends XComponentController {
}

class SshTerminalPipUiController extends NodeController {
  private builderNode: BuilderNode<[SshTerminalPipInfo]> | null = null;
  private info: SshTerminalPipInfo;

  constructor(info: SshTerminalPipInfo) {
    super();
    this.info = info;
  }

  makeNode(uiContext: UIContext): FrameNode | null {
    const builder: BuilderNode<[SshTerminalPipInfo]> =
      new BuilderNode<[SshTerminalPipInfo]>(uiContext);
    builder.build(wrapBuilder(SshTerminalPipContent), this.info);
    this.builderNode = builder;
    return builder.getFrameNode();
  }

  update(info: SshTerminalPipInfo): void {
    this.info = info;
    if (this.builderNode !== null) {
      this.builderNode.update(this.info);
    }
  }

  dispose(): void {
    if (this.builderNode !== null) {
      try {
        this.builderNode.dispose();
      } catch (_err) {
        // Best effort; WMS may already own the node teardown.
      }
      this.builderNode = null;
    }
  }
}

export class SshTerminalPipService {
  private static instance: SshTerminalPipService | null = null;
  private controller: PiPWindow.PiPController | null = null;
  private componentController: SshTerminalPipComponentController | null = null;
  private customUiController: SshTerminalPipUiController | null = null;
  private prepared: boolean = false;
  private active: boolean = false;
  private lastState: PiPWindow.PiPState | null = null;
  private stateCallback: ((state: PiPWindow.PiPState, reason: string) => void) | null = null;
  private stoppedHandler: SshPipStoppedHandler | null = null;
  private operationGeneration: number = 0;
  private operationTail: Promise<void> = Promise.resolve();
  private prepareRequestCount: number = 0;

  static getInstance(): SshTerminalPipService {
    if (SshTerminalPipService.instance === null) {
      SshTerminalPipService.instance = new SshTerminalPipService();
    }
    return SshTerminalPipService.instance;
  }

  async prepare(context: common.UIAbilityContext, info: SshTerminalPipInfo,
    onStopped: SshPipStoppedHandler | null = null): Promise<boolean> {
    this.prepareRequestCount++;
    return this.enqueueOperation<boolean>(async (): Promise<boolean> => {
      try {
        return await this.prepareInternal(context, info, onStopped);
      } finally {
        this.prepareRequestCount = Math.max(0, this.prepareRequestCount - 1);
      }
    });
  }

  private async prepareInternal(context: common.UIAbilityContext,
    info: SshTerminalPipInfo, onStopped: SshPipStoppedHandler | null): Promise<boolean> {
    if (!PiPWindow.isPiPEnabled()) {
      hilog.info(DOMAIN, TAG, 'SSH PiP unsupported or disabled');
      return false;
    }
    const nextInfo: SshTerminalPipInfo = this.normalizedInfo(info);
    this.stoppedHandler = onStopped;
    if (this.prepared && this.controller !== null) {
      this.customUiController?.update(nextInfo);
      return true;
    }
    if (this.controller !== null) {
      if (!(await this.stopInternal())) {
        return false;
      }
      this.stoppedHandler = onStopped;
    }

    const generation: number = this.operationGeneration;
    let created: PiPWindow.PiPController | null = null;
    const component: SshTerminalPipComponentController =
      new SshTerminalPipComponentController();
    const customUi: SshTerminalPipUiController = new SshTerminalPipUiController(nextInfo);
    try {
      const config: PiPWindow.PiPConfiguration = {
        context: context,
        componentController: component,
        // API 23 exposes these PiP templates only. The actual SSH content is
        // custom UI; no video renderer or media session is claimed here.
        templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY,
        contentWidth: 800,
        contentHeight: 450,
        customUIController: customUi,
        defaultWindowSizeType: 1,
        cornerAdsorptionEnabled: true
      };
      created = await PiPWindow.create(config);
      if (generation !== this.operationGeneration) {
        this.disposeCreatedController(created, customUi);
        return false;
      }
      this.controller = created;
      this.componentController = component;
      this.customUiController = customUi;
      this.prepared = true;
      this.active = false;
      this.lastState = null;
      const callback: (state: PiPWindow.PiPState, reason: string) => void =
        (state: PiPWindow.PiPState, reason: string): void => {
          this.handleStateChange(created as PiPWindow.PiPController, state, reason);
        };
      this.stateCallback = callback;
      created.on('stateChange', callback);
      created.setAutoStartEnabled(true);
      hilog.info(DOMAIN, TAG, 'SSH PiP prepared for background auto-start');
      return true;
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'SSH PiP prepare failed code=' + this.errorCode(be) +
        ' message=' + this.errorMessage(be));
      if (created !== null) {
        this.disposeCreatedController(created, customUi);
      } else {
        customUi.dispose();
      }
      this.clearState();
      return false;
    }
  }

  async start(): Promise<boolean> {
    return this.enqueueOperation<boolean>(async (): Promise<boolean> => {
      if (!this.prepared || this.controller === null) {
        hilog.warn(DOMAIN, TAG, 'SSH PiP start skipped: no foreground controller');
        return false;
      }
      if (this.active || this.lastState === PiPWindow.PiPState.STARTED) {
        this.active = true;
        return true;
      }
      const owner: PiPWindow.PiPController = this.controller;
      const startedAt: number = Date.now();
      while (this.controller === owner && !this.active &&
        !this.isTerminalState(this.lastState) &&
        Date.now() - startedAt < PIP_STATE_TIMEOUT_MS) {
        await new Promise<void>((resolve: () => void): void => {
          setTimeout(resolve, 40);
        });
      }
      if (this.controller !== owner || this.active) {
        return this.active;
      }
      hilog.warn(DOMAIN, TAG, 'SSH PiP auto-start did not reach STARTED');
      await this.stopInternal();
      return false;
    });
  }

  update(info: SshTerminalPipInfo): void {
    if (!this.prepared || this.controller === null || this.customUiController === null) {
      return;
    }
    this.customUiController.update(this.normalizedInfo(info));
  }

  async stop(): Promise<boolean> {
    return this.enqueueOperation<boolean>(() => this.stopInternal());
  }

  isPrepared(): boolean {
    return this.prepared && this.controller !== null;
  }

  isPreparedOrPreparing(): boolean {
    return this.isPrepared() || this.prepareRequestCount > 0;
  }

  isActive(): boolean {
    return this.active && this.controller !== null;
  }

  private handleStateChange(owner: PiPWindow.PiPController,
    state: PiPWindow.PiPState, reason: string): void {
    if (this.controller !== owner) {
      return;
    }
    this.lastState = state;
    hilog.info(DOMAIN, TAG, 'SSH PiP state=' + state.toString() + ' reason=' + reason);
    if (state === PiPWindow.PiPState.STARTED) {
      this.active = true;
      return;
    }
    if (state === PiPWindow.PiPState.ABOUT_TO_START ||
      state === PiPWindow.PiPState.ABOUT_TO_STOP ||
      state === PiPWindow.PiPState.ABOUT_TO_RESTORE) {
      this.active = false;
      return;
    }
    if (this.isTerminalState(state)) {
      this.cleanupController(owner, reason, true);
    }
  }

  private async stopInternal(): Promise<boolean> {
    this.operationGeneration++;
    const owner: PiPWindow.PiPController | null = this.controller;
    if (owner === null) {
      this.clearState();
      return true;
    }
    this.stoppedHandler = null;
    try {
      owner.setAutoStartEnabled(false);
    } catch (_err) {
      // Continue with best-effort teardown.
    }
    if (this.lastState === null && !this.active) {
      this.cleanupController(owner, 'requestDelete', false);
      return true;
    }
    if (this.isTerminalState(this.lastState)) {
      this.cleanupController(owner, 'requestDelete', false);
      return true;
    }
    if (this.lastState === PiPWindow.PiPState.ABOUT_TO_START) {
      const settled: boolean = await this.waitForStart(owner);
      if (!settled) {
        return false;
      }
    }
    if (this.controller !== owner || this.isTerminalState(this.lastState)) {
      return true;
    }
    try {
      await owner.stopPiP();
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'SSH PiP stop failed code=' + this.errorCode(be) +
        ' message=' + this.errorMessage(be));
      return false;
    }
    const terminal: boolean = await this.waitForTerminal(owner);
    if (!terminal) {
      return false;
    }
    if (this.controller === owner) {
      this.cleanupController(owner, 'requestDelete', false);
    }
    return true;
  }

  private async waitForStart(owner: PiPWindow.PiPController): Promise<boolean> {
    const startedAt: number = Date.now();
    while (this.controller === owner &&
      this.lastState === PiPWindow.PiPState.ABOUT_TO_START &&
      Date.now() - startedAt < PIP_STATE_TIMEOUT_MS) {
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 40);
      });
    }
    return this.controller !== owner || this.lastState === PiPWindow.PiPState.STARTED ||
      this.isTerminalState(this.lastState);
  }

  private async waitForTerminal(owner: PiPWindow.PiPController): Promise<boolean> {
    const startedAt: number = Date.now();
    while (this.controller === owner && !this.isTerminalState(this.lastState) &&
      Date.now() - startedAt < PIP_STATE_TIMEOUT_MS) {
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 40);
      });
    }
    return this.controller !== owner || this.isTerminalState(this.lastState);
  }

  private cleanupController(owner: PiPWindow.PiPController,
    reason: string, notifyStopped: boolean): void {
    if (this.controller !== owner) {
      return;
    }
    const handler: SshPipStoppedHandler | null = notifyStopped ? this.stoppedHandler : null;
    const customUi: SshTerminalPipUiController | null = this.customUiController;
    this.clearState();
    try {
      owner.off('stateChange');
    } catch (_err) {
      // Best effort listener cleanup.
    }
    if (handler !== null) {
      handler(reason);
    }
    if (customUi !== null) {
      customUi.dispose();
    }
  }

  private disposeCreatedController(controller: PiPWindow.PiPController,
    customUi: SshTerminalPipUiController): void {
    try {
      controller.setAutoStartEnabled(false);
    } catch (_err) {
      // Best effort.
    }
    try {
      controller.off('stateChange');
    } catch (_err) {
      // Best effort.
    }
    customUi.dispose();
  }

  private clearState(): void {
    this.controller = null;
    this.componentController = null;
    this.customUiController = null;
    this.prepared = false;
    this.active = false;
    this.lastState = null;
    this.stateCallback = null;
    this.stoppedHandler = null;
  }

  private normalizedInfo(info: SshTerminalPipInfo): SshTerminalPipInfo {
    return {
      hostLabel: info.hostLabel.trim(),
      hostAddress: info.hostAddress.trim(),
      status: info.status.trim().length > 0 ? info.status.trim() : '已连接',
      outputSummary: sanitizeOutputSummary(info.outputSummary)
    };
  }

  private isTerminalState(state: PiPWindow.PiPState | null): boolean {
    return state === PiPWindow.PiPState.STOPPED || state === PiPWindow.PiPState.ERROR;
  }

  private enqueueOperation<T>(operation: () => Promise<T>): Promise<T> {
    const queued: Promise<T> = this.operationTail.then(operation, operation);
    this.operationTail = queued.then((): void => undefined, (): void => undefined);
    return queued;
  }

  private errorCode(error: BusinessError): string {
    return error.code === undefined ? 'unknown' : error.code.toString();
  }

  private errorMessage(error: BusinessError): string {
    return error.message === undefined ? JSON.stringify(error) : error.message;
  }
}
